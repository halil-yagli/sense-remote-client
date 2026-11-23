//! Sense Remote: the heartbeat side of signed panel envelopes (wave 2, task I4; plan §3.7).
//!
//! The heartbeat answer may carry `sense_envelopes` (signed permission sets) and
//! `sense_server_time`. Upstream also acted on plain `strategy`, `disconnect` and `modified_at`;
//! those are unsigned, so Sense never applies them any more: `parse_answer` keeps only the keys
//! below and lists the rest as ignored (logged, nothing else).
//!
//! For every envelope: `envelope::verify` (signature, issuer, device, time, seq, allow list) →
//! platform gate (Windows and macOS apply; elsewhere `unsupported_platform`) → the sync loop
//! applies it (role, settings, disconnect, then `EnvelopeSeq`; on macOS through the root daemon,
//! `mac_apply`, which verifies it again) →
//! `Report` remembers the last rejection and the clock skew for the next heartbeat's `sense`
//! (`applied_seq`, `envelope_error`, `clock_skew_s`).
//!
//! The server time is never used to verify: it is only compared with the local clock and the
//! difference reported (plan R8).
//!
//! Sense Remote (wave 2 review): `clock_skew_s` is local − panel as the contract says (K2-1); an
//! envelope must carry the whole allow-listed set (G2-7); `apply_steps` fixes the order of the
//! registry / settings writes and undoes them when a later one fails (K2-2, G2-6).

use hbb_common::log;
use super::{
    envelope::{self, Expect, PanelRole, Reason, Rejection, Verified},
    envelope_keys::TrustedKey,
    update, SenseRole,
};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

/// Same limit as the panel's `HeartbeatResponse.sense_envelopes`.
pub const MAX_ENVELOPES: usize = 8;
/// A larger difference between panel and local clock is reported (`clock_skew_s`).
pub const SKEW_REPORT_S: i64 = 300;
/// Windows applies verified envelopes in the `--server` process (SYSTEM). Sense Remote (Mac M5,
/// plan 2026-11-21 §3.3): macOS applies them too, in the root daemon (`mac_apply`); MAC-SONRA-9
/// is closed. Other platforms only verify them.
pub const APPLIES: bool = cfg!(any(windows, target_os = "macos"));

const KEY_SYSINFO: &str = "sysinfo";
const KEY_ENVELOPES: &str = "sense_envelopes";
const KEY_SERVER_TIME: &str = "sense_server_time";
// Sense Remote (update plan 2026-11-21, §3.4): the unsigned hint and the two signed objects of an
// update. Only split off here; `update` verifies them (`update::on_answer`).
const KEY_UPDATE_HINT: &str = "sense_update";
const KEY_RELEASE: &str = "sense_release";
const KEY_UPDATE_ORDER: &str = "sense_update_order";
/// Sense Remote (S6): capabilities of the panel (`health_v2`), information only.
const KEY_PANEL_CAPS: &str = "sense_panel_caps";

/// What the sync loop takes from a heartbeat answer. There is deliberately no field for the
/// upstream `strategy`, `disconnect` or `modified_at`.
#[derive(Debug, Default, PartialEq)]
pub struct HeartbeatAnswer {
    /// Panel asks for a new sysinfo upload (upstream: presence of the key is enough).
    pub sysinfo: bool,
    pub envelopes: Vec<Value>,
    pub server_time: Option<i64>,
    /// Sense Remote (update plan 2026-11-21, §3.4): `sense_update`, `sense_release` and
    /// `sense_update_order`, unverified.
    pub update: update::Answer,
    /// Sense Remote (S6): `sense_panel_caps` (strings); `None` when missing or of another shape.
    pub panel_caps: Option<Vec<String>>,
    /// Keys that are not acted on (sorted), for the log.
    pub ignored: Vec<String>,
}

/// `None` when the answer is not a JSON object.
pub fn parse_answer(body: &str) -> Option<HeartbeatAnswer> {
    let object: Map<String, Value> = serde_json::from_str(body).ok()?;
    let mut answer = HeartbeatAnswer::default();
    for (key, value) in object {
        match key.as_str() {
            KEY_SYSINFO => answer.sysinfo = true,
            KEY_ENVELOPES => match value {
                Value::Array(items) => {
                    answer.envelopes = items.into_iter().take(MAX_ENVELOPES).collect()
                }
                _ => answer.ignored.push(key),
            },
            KEY_SERVER_TIME => match value.as_i64() {
                Some(t) => answer.server_time = Some(t),
                None => answer.ignored.push(key),
            },
            // Sense Remote (update plan 2026-11-21, §3.4): a value of the wrong shape is ignored
            // like an unknown key.
            KEY_UPDATE_HINT => match update::Hint::parse(&value) {
                Some(hint) => answer.update.hint = Some(hint),
                None => answer.ignored.push(key),
            },
            KEY_RELEASE if value.is_object() => answer.update.release = Some(value),
            KEY_UPDATE_ORDER if value.is_object() => answer.update.order = Some(value),
            KEY_PANEL_CAPS => match panel_caps(&value) {
                Some(caps) => answer.panel_caps = Some(caps),
                None => answer.ignored.push(key),
            },
            _ => answer.ignored.push(key),
        }
    }
    answer.ignored.sort();
    Some(answer)
}

/// Sense Remote (S6): at most 16 strings of at most 32 characters, like `caps`.
fn panel_caps(value: &Value) -> Option<Vec<String>> {
    let items = value.as_array()?;
    let caps: Vec<String> = items
        .iter()
        .take(16)
        .filter_map(Value::as_str)
        .filter(|c| !c.is_empty() && c.len() <= 32)
        .map(str::to_owned)
        .collect();
    (caps.len() == items.len().min(16)).then_some(caps)
}

/// Sense Remote (G2-7): the envelope sets every allow-listed key. A partial set would leave the
/// other permissions as they happen to be on this computer (e.g. an old `access-mode=full`
/// overriding them all), so it is refused here, before anything is applied. `verify` alone still
/// accepts it, to stay identical to the panel's `verifyEnvelope` and the shared test vector.
pub fn is_full_set(config_options: &BTreeMap<String, String>) -> bool {
    config_options.len() == envelope::ALLOWED_OPTIONS.len()
        && envelope::ALLOWED_OPTIONS
            .iter()
            .all(|(key, _)| config_options.contains_key(*key))
}

/// Verification, the full-set rule and the platform gate. `Ok` = apply it now.
pub fn check(
    item: &Value,
    keys: &[TrustedKey],
    expect: &Expect,
    applies: bool,
) -> Result<Verified, Rejection> {
    let verified = envelope::verify(item, keys, expect)?;
    if !is_full_set(&verified.body.config_options) {
        return Err(Rejection {
            reason: Reason::NotAllowed,
            k: Some(verified.k),
            seq: Some(verified.seq),
        });
    }
    if !applies {
        return Err(Rejection {
            reason: Reason::UnsupportedPlatform,
            k: Some(verified.k),
            seq: Some(verified.seq),
        });
    }
    Ok(verified)
}

/// Sense Remote (G2-5): `check` with the stored seq as read from the registry. When it could not
/// be read, `expect.last_seq` is only a placeholder: a verified envelope is then refused
/// (`apply_failed`, with its seq) instead of being checked against a counter of 0.
pub fn check_stored(
    item: &Value,
    keys: &[TrustedKey],
    expect: &Expect,
    applies: bool,
    seq_readable: bool,
) -> Result<Verified, Rejection> {
    let verified = check(item, keys, expect, applies)?;
    if !seq_readable {
        return Err(Rejection {
            reason: Reason::ApplyFailed,
            k: Some(verified.k),
            seq: Some(verified.seq),
        });
    }
    Ok(verified)
}

/// Sense Remote (K2-2, G2-6): the writes of one apply, injected so that their order and the undo
/// are tested without the registry. The sync loop implements them with HKLM and `Config`.
pub trait ApplySteps {
    /// Settings as they are now, to put back when a later step fails.
    type Snapshot;
    /// Fails when the seq could not be stored at the end (nothing has changed yet).
    fn check_writable(&mut self) -> Result<(), String>;
    fn snapshot(&mut self) -> Self::Snapshot;
    fn set_options(&mut self) -> Result<(), String>;
    fn restore_options(&mut self, snapshot: Self::Snapshot);
    fn store_role(&mut self, role: SenseRole) -> Result<(), String>;
    fn store_seq(&mut self) -> Result<(), String>;
}

/// Applies settings -> role -> seq. Either all three are written or, as far as the platform lets
/// us, none: a failed role write puts the settings back, a failed seq write puts the old role and
/// the settings back. So the panel's "rejected" (`apply_failed`) never sits next to a computer
/// that changed anyway. `old_role` is the installed role (`role_change` only returns a new role
/// when there is one).
pub fn apply_steps<S: ApplySteps>(
    steps: &mut S,
    old_role: Option<SenseRole>,
    new_role: Option<SenseRole>,
) -> Result<(), Reason> {
    let failed = |step: &str, err: String| {
        log::error!("Sense Remote: envelope apply failed at {step}: {err}");
        Reason::ApplyFailed
    };
    steps
        .check_writable()
        .map_err(|err| failed("write check", err))?;
    let snapshot = steps.snapshot();
    if let Err(err) = steps.set_options() {
        steps.restore_options(snapshot);
        return Err(failed("settings", err));
    }
    if let Some(role) = new_role {
        if let Err(err) = steps.store_role(role) {
            steps.restore_options(snapshot);
            return Err(failed("role", err));
        }
    }
    if let Err(err) = steps.store_seq() {
        if let (Some(_), Some(old)) = (new_role, old_role) {
            if let Err(undo) = steps.store_role(old) {
                log::error!("Sense Remote: restoring role {} failed: {undo}", old.as_str());
            }
        }
        steps.restore_options(snapshot);
        return Err(failed("seq", err));
    }
    Ok(())
}

/// Role to store, `None` when it stays the same. Sense Remote (wave 3, K-ROL-2): every switch
/// between Host, Controller and Host + Controller is allowed (the service runs in every role, so
/// the way back reaches a Controller too). A computer without an installed role is refused.
pub fn role_change(
    installed: Option<SenseRole>,
    wanted: Option<PanelRole>,
) -> Result<Option<SenseRole>, Reason> {
    let Some(wanted) = wanted else {
        return Ok(None);
    };
    let Some(current) = installed else {
        return Err(Reason::NotAllowed);
    };
    let next = wanted.sense_role();
    Ok((next != current).then_some(next))
}

/// Sense Remote (K-ROL-2): the `--server` process decides once at start whether it listens
/// (Controller: sync loop only, `rendezvous_mediator.rs`). A change into or out of Controller
/// therefore restarts it; the Windows service starts it again with the stored role. Host <->
/// Host + Controller keeps listening and is applied in-process.
pub fn restart_needed(old: Option<SenseRole>, new: SenseRole) -> bool {
    old.map_or(true, |old| (old == SenseRole::Controller) != (new == SenseRole::Controller))
}

/// Sense Remote (Mac M5): exit code of the `--server` process when it ends for such a restart.
/// Windows: the service starts it again whatever the code (0, as before). macOS: the LaunchAgent
/// has `KeepAlive` → `SuccessfulExit = false` (`agent.plist`), launchd starts it again only
/// after an exit that is not 0.
pub fn restart_exit_code(macos: bool) -> i32 {
    if macos {
        1
    } else {
        0
    }
}

/// Sense Remote (wave 3, K-CTRL): an outgoing-only (Controller) computer still installs the
/// service, imports the config and runs the panel sync loop, as long as it is a Sense install
/// (role in HKLM, or the setup screen is installing one now). Otherwise upstream's
/// outgoing-only behaviour (no service, no sync) stays.
pub fn service_when_outgoing_only(installed: Option<SenseRole>, installing: bool) -> bool {
    installed.is_some() || installing
}

/// Sense Remote (K2-1): local − panel clock (contract `clock_skew_s`: positive = this computer is
/// ahead) when it is larger than `SKEW_REPORT_S`.
pub fn clock_skew(server_s: i64, local_s: i64) -> Option<i64> {
    let diff = local_s.saturating_sub(server_s);
    (diff.abs() > SKEW_REPORT_S).then_some(diff)
}

/// Last rejection, as sent in `sense.envelope_error`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeError {
    pub seq: Option<u64>,
    pub k: Option<String>,
    pub reason: Reason,
    /// Local clock, Unix seconds (information only).
    pub at: i64,
}

/// Envelope state reported in every heartbeat. Lives in the sync loop.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Report {
    pub error: Option<EnvelopeError>,
    pub clock_skew_s: Option<i64>,
    /// Sense Remote (G3-6): panel − local clock from the last answer that had it (`None`
    /// until then); lets the report `ts` drop a reservation the panel can never have accepted.
    pub server_offset_s: Option<i64>,
}

impl Report {
    /// A successful apply clears the last error (the panel then shows "applied").
    pub fn applied(&mut self) {
        self.error = None;
    }

    /// Records a rejection; returns false when it is not worth reporting: the panel resending
    /// the envelope that was just applied (its seq equals `last_seq`) before it saw
    /// `applied_seq`.
    pub fn rejected(&mut self, rejection: Rejection, last_seq: u64, now_s: i64) -> bool {
        if rejection.reason == Reason::Replayed && rejection.seq == Some(last_seq) {
            return false;
        }
        self.error = Some(EnvelopeError {
            seq: rejection.seq,
            k: rejection.k,
            reason: rejection.reason,
            at: now_s,
        });
        true
    }

    /// Updates the skew from `sense_server_time` (an answer without it keeps the last value).
    pub fn server_time(&mut self, server_s: Option<i64>, local_s: i64) {
        if let Some(server_s) = server_s {
            self.clock_skew_s = clock_skew(server_s, local_s);
            self.server_offset_s = Some(server_s.saturating_sub(local_s));
        }
    }

    /// Adds `applied_seq` (0 included), `envelope_error` and `clock_skew_s` to the heartbeat's
    /// `sense` object. Sense Remote (G2-5): `applied_seq` is `None` when the stored seq could
    /// not be read; it is then left out (the field is optional) rather than reported as 0.
    pub fn extend(&self, sense: &mut Value, applied_seq: Option<u64>) {
        let Some(object) = sense.as_object_mut() else {
            return;
        };
        if let Some(applied_seq) = applied_seq {
            object.insert("applied_seq".to_owned(), json!(applied_seq));
        }
        if let Some(error) = &self.error {
            let mut value = json!({ "reason": error.reason.as_str(), "at": error.at });
            if let Some(seq) = error.seq {
                value["seq"] = json!(seq);
            }
            if let Some(k) = &error.k {
                value["k"] = json!(k);
            }
            object.insert("envelope_error".to_owned(), value);
        }
        if let Some(skew) = self.clock_skew_s {
            object.insert("clock_skew_s".to_owned(), json!(skew));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::envelope::{OptionRule, ALLOWED_OPTIONS, SIGNING_PREFIX};
    use crate::sense::envelope_keys::key_id;
    use hbb_common::{
        base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
        sodiumoxide::{self, crypto::sign},
    };
    use std::collections::BTreeSet;

    const ISS: &str = "remote.snsdpt.com";
    const DID: &str = "123456789";
    const DUUID: &str = "dGVzdC11dWlk";
    const NOW: i64 = 1_800_000_000;

    struct Signer {
        sk: sign::SecretKey,
        trusted: TrustedKey,
    }

    // Key made at run time; nothing secret is stored in the repository.
    fn signer() -> Signer {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        Signer {
            sk,
            trusted: TrustedKey {
                k: key_id(&pk.0),
                public_key: pk.0,
            },
        }
    }

    impl Signer {
        fn sign(&self, payload: &Value) -> Value {
            let payload = serde_json::to_vec(payload).unwrap();
            let mut data = SIGNING_PREFIX.to_vec();
            data.extend_from_slice(&payload);
            let signature = &sign::sign(&data, &self.sk)[..64];
            json!({
                "k": self.trusted.k,
                "p": URL_SAFE_NO_PAD.encode(&payload),
                "s": URL_SAFE_NO_PAD.encode(signature),
            })
        }
    }

    fn full_set() -> Value {
        let mut set = Map::new();
        for (key, rule) in ALLOWED_OPTIONS {
            let value = match rule {
                OptionRule::YesNo => "Y",
                OptionRule::Empty | OptionRule::Minutes => "",
            };
            set.insert(key.to_owned(), json!(value));
        }
        Value::Object(set)
    }

    fn strategy(seq: u64, body_extra: Value) -> Value {
        let mut body = json!({ "config_options": full_set(), "revision": 1 });
        if let (Some(body), Some(extra)) = (body.as_object_mut(), body_extra.as_object()) {
            body.extend(extra.clone());
        }
        json!({
            "v": 1, "typ": "strategy", "iss": ISS, "did": DID, "duuid": DUUID, "seq": seq,
            "nonce": "AAECAwQFBgcICQoLDA0ODw", "iat": NOW, "nbf": NOW, "exp": NOW + 7 * 86_400,
            "body": body,
        })
    }

    fn expect(last_seq: u64) -> Expect<'static> {
        Expect {
            iss: ISS,
            did: DID,
            duuid: DUUID,
            now_s: NOW,
            last_seq,
        }
    }

    #[test]
    fn plain_strategy_disconnect_and_modified_at_are_ignored() {
        let body = json!({
            "strategy": { "config_options": { "enable-terminal": "Y", "api-server": "x" } },
            "disconnect": [1, 2],
            "modified_at": 1_800_000_000,
            "sysinfo": true,
            "sense_envelopes": [{ "k": "0000000000000000", "p": "e30", "s": "x" }],
            "sense_server_time": 1_800_000_123,
        })
        .to_string();
        let answer = parse_answer(&body).unwrap();
        assert!(answer.sysinfo);
        assert_eq!(answer.envelopes.len(), 1);
        assert_eq!(answer.server_time, Some(1_800_000_123));
        assert_eq!(answer.ignored, vec!["disconnect", "modified_at", "strategy"]);
    }

    /// Sense Remote (S6): `sense_panel_caps` is read; a wrong shape is ignored and logged.
    #[test]
    fn panel_caps_are_read() {
        let answer = parse_answer(&json!({ "sense_panel_caps": ["health_v2"] }).to_string()).unwrap();
        assert_eq!(answer.panel_caps, Some(vec!["health_v2".to_owned()]));
        assert!(answer.ignored.is_empty());
        for bad in [json!("health_v2"), json!([1]), json!(["x".repeat(40)])] {
            let answer = parse_answer(&json!({ "sense_panel_caps": bad }).to_string()).unwrap();
            assert_eq!(answer.panel_caps, None);
            assert_eq!(answer.ignored, vec!["sense_panel_caps"]);
        }
        assert_eq!(parse_answer("{}").unwrap().panel_caps, None);
    }

    // Update plan 2026-11-21 §3.4 (U0): the three update keys are split off, everything else is
    // ignored as before.
    #[test]
    fn update_keys_are_split_off() {
        let release = json!({ "k": "0000000000000000", "p": "e30", "s": "x" });
        let order = json!({ "k": "0000000000000000", "p": "e30", "s": "y" });
        let body = json!({
            "sense_update": { "release": 4, "oid": "upd_0123456789abcdef" },
            "sense_release": release,
            "sense_update_order": order,
            "strategy": { "config_options": {} },
            "disconnect": [1],
            "modified_at": 1,
            "sense_update_now": true,
        })
        .to_string();
        let answer = parse_answer(&body).unwrap();
        assert_eq!(
            answer.update,
            update::Answer {
                hint: Some(update::Hint {
                    release: Some(4),
                    oid: Some("upd_0123456789abcdef".to_owned()),
                }),
                release: Some(release),
                order: Some(order),
            }
        );
        assert_eq!(
            answer.ignored,
            vec!["disconnect", "modified_at", "sense_update_now", "strategy"]
        );
        assert!(!answer.sysinfo && answer.envelopes.is_empty() && answer.server_time.is_none());

        // The usual answer: only the hint, both parts `null`.
        let answer = parse_answer(r#"{"sense_update":{"release":null,"oid":null}}"#).unwrap();
        assert_eq!(
            answer.update.hint,
            Some(update::Hint { release: None, oid: None })
        );
        assert!(answer.update.release.is_none() && answer.update.order.is_none());
        assert!(answer.ignored.is_empty());

        // Wrong shapes are ignored and logged, nothing is taken from them.
        let answer = parse_answer(
            r#"{"sense_update":{"release":4,"oid":null,"install":true},
                "sense_release":"e30","sense_update_order":[{}]}"#,
        )
        .unwrap();
        assert_eq!(answer.update, update::Answer::default());
        assert_eq!(
            answer.ignored,
            vec!["sense_release", "sense_update", "sense_update_order"]
        );
    }

    #[test]
    fn answer_shapes() {
        assert_eq!(parse_answer("[]"), None);
        assert_eq!(parse_answer("not json"), None);
        assert_eq!(parse_answer("{}"), Some(HeartbeatAnswer::default()));
        let answer = parse_answer(r#"{"sense_envelopes":{"k":"x"},"sense_server_time":"1"}"#)
            .unwrap();
        assert!(answer.envelopes.is_empty());
        assert_eq!(answer.server_time, None);
        assert_eq!(answer.ignored, vec!["sense_envelopes", "sense_server_time"]);
        let many = json!({ "sense_envelopes": vec![json!({}); MAX_ENVELOPES + 3] }).to_string();
        assert_eq!(parse_answer(&many).unwrap().envelopes.len(), MAX_ENVELOPES);
    }

    #[test]
    fn verified_envelope_is_applied_only_where_supported() {
        let s = signer();
        let keys = vec![s.trusted.clone()];
        let item = s.sign(&strategy(5, json!({})));
        let verified = check(&item, &keys, &expect(4), true).unwrap();
        assert_eq!(verified.seq, 5);
        assert_eq!(verified.body.config_options.len(), ALLOWED_OPTIONS.len());
        assert_eq!(
            check(&item, &keys, &expect(4), false),
            Err(Rejection {
                reason: Reason::UnsupportedPlatform,
                k: Some(s.trusted.k.clone()),
                seq: Some(5),
            })
        );
        // Mac M5: macOS applies too (through the root daemon).
        assert_eq!(APPLIES, cfg!(any(windows, target_os = "macos")));
    }

    #[test]
    fn rejections_come_from_verification_first() {
        let s = signer();
        let keys = vec![s.trusted.clone()];
        let item = s.sign(&strategy(5, json!({})));
        // No trusted key (a build without SENSE_ENVELOPE_KEYS): nothing is applied.
        assert_eq!(check(&item, &[], &expect(4), true).unwrap_err().reason, Reason::UnknownKey);
        assert_eq!(check(&item, &keys, &expect(5), true).unwrap_err().reason, Reason::Replayed);
        // A plain strategy object in the envelope list is not an envelope.
        let plain = json!({ "config_options": { "enable-terminal": "Y" } });
        assert_eq!(check(&plain, &keys, &expect(0), true).unwrap_err().reason, Reason::Malformed);
        // Signed, but a key outside the allow list.
        let mut bad = strategy(6, json!({}));
        bad["body"]["config_options"]["allow-hide-cm"] = json!("Y");
        assert_eq!(
            check(&s.sign(&bad), &keys, &expect(4), true).unwrap_err().reason,
            Reason::NotAllowed
        );
        // Verification errors win over the platform gate.
        let other = signer();
        assert_eq!(
            check(&other.sign(&strategy(5, json!({}))), &keys, &expect(4), false)
                .unwrap_err()
                .reason,
            Reason::UnknownKey
        );
    }

    #[test]
    fn role_comes_through_verification() {
        let s = signer();
        let keys = vec![s.trusted.clone()];
        let item = s.sign(&strategy(7, json!({ "sense_role": "host_controller" })));
        let verified = check(&item, &keys, &expect(0), true).unwrap();
        assert_eq!(verified.body.sense_role, Some(PanelRole::HostController));
        // Sense Remote (K-ROL-2): Controller is accepted from wave 3 on.
        let item = s.sign(&strategy(7, json!({ "sense_role": "controller" })));
        let verified = check(&item, &keys, &expect(0), true).unwrap();
        assert_eq!(verified.body.sense_role, Some(PanelRole::Controller));
        let item = s.sign(&strategy(7, json!({ "sense_role": "both" })));
        assert_eq!(
            check(&item, &keys, &expect(0), true).unwrap_err().reason,
            Reason::BadPayload
        );
    }

    #[test]
    fn role_change_between_all_three_roles() {
        // K-ROL-2: every switch is allowed, the same role changes nothing.
        let roles = [
            (SenseRole::Host, PanelRole::Host),
            (SenseRole::Controller, PanelRole::Controller),
            (SenseRole::Both, PanelRole::HostController),
        ];
        for (installed, _) in roles {
            assert_eq!(role_change(Some(installed), None), Ok(None));
            for (target, wanted) in roles {
                let expected = (target != installed).then_some(target);
                assert_eq!(
                    role_change(Some(installed), Some(wanted)),
                    Ok(expected),
                    "{installed:?} -> {wanted:?}"
                );
            }
        }
        assert_eq!(role_change(None, None), Ok(None));
        assert_eq!(role_change(None, Some(PanelRole::Host)), Err(Reason::NotAllowed));
        assert_eq!(role_change(None, Some(PanelRole::Controller)), Err(Reason::NotAllowed));
    }

    #[test]
    fn controller_gets_service_and_sync_only_as_sense_install() {
        // K-CTRL: every installed Sense role, and the setup screen's install, get the service.
        for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
            assert!(service_when_outgoing_only(Some(role), false));
        }
        assert!(service_when_outgoing_only(None, true));
        // Portable / not installed: upstream behaviour (no service, no sync loop).
        assert!(!service_when_outgoing_only(None, false));
    }

    #[test]
    fn controller_server_branch_runs_sync_only() {
        // K-CTRL code path: in `start_all`, the outgoing-only branch starts the sync loop and
        // then only sleeps; ID server registration, direct server and LAN listening come after
        // it and are never reached by a Controller.
        let source = include_str!("../rendezvous_mediator.rs");
        let start = source.find("pub async fn start_all()").unwrap();
        let branch_start = start + source[start..].find("if config::is_outgoing_only() {").unwrap();
        let branch_end = branch_start + source[branch_start..].find("loop {").unwrap();
        let branch = &source[branch_start..branch_end];
        assert!(branch.contains("service_when_outgoing_only("), "{branch}");
        assert!(branch.contains("crate::hbbs_http::sync::start();"), "{branch}");
        for listening in ["direct_server", "start_listening", "Self::start(", "new_server()"] {
            assert!(!branch.contains(listening), "{listening} in the Controller branch");
        }
        let after = &source[branch_end..];
        let sleep_loop = &after[..after.find('}').unwrap()];
        assert!(sleep_loop.contains("sleep(1.).await;"), "{sleep_loop}");
    }

    #[test]
    fn server_restarts_only_when_listening_changes() {
        let (host, both, controller) = (SenseRole::Host, SenseRole::Both, SenseRole::Controller);
        assert!(restart_needed(Some(host), controller));
        assert!(restart_needed(Some(both), controller));
        assert!(restart_needed(Some(controller), host));
        assert!(restart_needed(Some(controller), both));
        assert!(!restart_needed(Some(host), both));
        assert!(!restart_needed(Some(both), host));
        assert!(restart_needed(None, host));
        // Mac M5: launchd restarts the agent only after a failing exit; Windows keeps 0.
        assert_eq!(restart_exit_code(false), 0);
        assert_ne!(restart_exit_code(true), 0);
    }

    #[test]
    fn controller_apply_writes_the_role_like_any_other() {
        // A Controller-only computer now takes a role envelope (K-CTRL: it runs the sync loop).
        let (controller, host) = (Some(SenseRole::Controller), Some(SenseRole::Host));
        let mut steps = FakeSteps::new(None);
        steps.role = controller;
        let new_role = role_change(controller, Some(PanelRole::Host)).unwrap();
        assert_eq!(new_role, host);
        assert_eq!(apply_steps(&mut steps, controller, new_role), Ok(()));
        assert_eq!(steps.log, ["check", "options", "role", "seq"]);
        assert_eq!(steps.role, host);
    }

    #[test]
    fn clock_skew_is_reported_beyond_five_minutes() {
        assert_eq!(clock_skew(NOW, NOW), None);
        assert_eq!(clock_skew(NOW + 300, NOW), None);
        assert_eq!(clock_skew(NOW - 300, NOW), None);
        // K2-1, contract: local − panel. Panel 301 s ahead = this computer behind -> negative.
        assert_eq!(clock_skew(NOW + 301, NOW), Some(-301));
        // Panel an hour behind = this computer ahead -> positive.
        assert_eq!(clock_skew(NOW - 3_600, NOW), Some(3_600));
        let mut report = Report::default();
        assert_eq!(report.server_offset_s, None);
        report.server_time(Some(NOW + 900), NOW);
        assert_eq!(report.clock_skew_s, Some(-900));
        assert_eq!(report.server_offset_s, Some(900));
        report.server_time(None, NOW);
        assert_eq!(report.clock_skew_s, Some(-900));
        assert_eq!(report.server_offset_s, Some(900));
        report.server_time(Some(NOW), NOW);
        assert_eq!(report.clock_skew_s, None);
        // G3-6: a small difference is not reported, but the panel clock is known.
        assert_eq!(report.server_offset_s, Some(0));
    }

    #[test]
    fn report_keeps_last_error_until_an_apply() {
        let mut report = Report::default();
        let rejection = |reason, seq| Rejection {
            reason,
            k: Some("0123456789abcdef".to_owned()),
            seq,
        };
        // The envelope just applied, resent by a panel that has not seen applied_seq yet.
        assert!(!report.rejected(rejection(Reason::Replayed, Some(4)), 4, NOW));
        assert_eq!(report.error, None);
        assert!(report.rejected(rejection(Reason::Replayed, Some(2)), 4, NOW));
        assert!(report.rejected(rejection(Reason::BadSignature, None), 4, NOW + 1));
        assert_eq!(
            report.error,
            Some(EnvelopeError {
                seq: None,
                k: Some("0123456789abcdef".to_owned()),
                reason: Reason::BadSignature,
                at: NOW + 1,
            })
        );
        report.applied();
        assert_eq!(report.error, None);
    }

    #[test]
    fn heartbeat_sense_fields_match_the_contract() {
        // SenseHeartbeatExt keys (panel packages/shared client-api/sense-ext.ts, wave 2).
        let schema: BTreeSet<&str> = [
            "v", "role", "app_version", "displays_hash", "health", "applied_seq",
            "maintenance_curtain", "envelope_error", "clock_skew_s",
        ]
        .into();
        let error_keys: BTreeSet<&str> = ["seq", "k", "reason", "at"].into();

        let mut sense = json!({ "v": 1, "role": "host", "app_version": 1 });
        Report::default().extend(&mut sense, Some(0));
        assert_eq!(sense["applied_seq"], json!(0));
        // G2-5: an unreadable seq is not reported as 0.
        let mut unread = json!({ "v": 1, "role": "host", "app_version": 1 });
        Report::default().extend(&mut unread, None);
        assert!(unread.get("applied_seq").is_none());
        assert!(sense.get("envelope_error").is_none());
        assert!(sense.get("clock_skew_s").is_none());

        let mut report = Report::default();
        report.rejected(
            Rejection {
                reason: Reason::Expired,
                k: Some("0123456789abcdef".to_owned()),
                seq: Some(9),
            },
            3,
            NOW,
        );
        // The panel's clock is 10 min behind: this computer is ahead -> +600 (K2-1).
        report.server_time(Some(NOW - 600), NOW);
        let mut sense = json!({ "v": 1, "role": "host_controller", "app_version": 1 });
        report.extend(&mut sense, Some(3));
        assert_eq!(
            sense,
            json!({
                "v": 1, "role": "host_controller", "app_version": 1, "applied_seq": 3,
                "envelope_error": { "seq": 9, "k": "0123456789abcdef", "reason": "expired", "at": NOW },
                "clock_skew_s": 600,
            })
        );
        for key in sense.as_object().unwrap().keys() {
            assert!(schema.contains(key.as_str()), "{key}");
        }
        for key in sense["envelope_error"].as_object().unwrap().keys() {
            assert!(error_keys.contains(key.as_str()), "{key}");
        }
        // Every reason name is one the panel knows.
        for reason in Reason::ALL {
            assert_eq!(Reason::parse(reason.as_str()), Some(reason));
        }
    }

    #[test]
    fn partial_set_is_refused_before_apply() {
        // G2-7: signed and verified, but only one key -> nothing is applied.
        let s = signer();
        let keys = vec![s.trusted.clone()];
        let mut partial = strategy(5, json!({}));
        partial["body"]["config_options"] = json!({ "enable-terminal": "Y" });
        let item = s.sign(&partial);
        assert!(envelope::verify(&item, &keys, &expect(4)).is_ok());
        assert_eq!(
            check(&item, &keys, &expect(4), true),
            Err(Rejection {
                reason: Reason::NotAllowed,
                k: Some(s.trusted.k.clone()),
                seq: Some(5),
            })
        );
        // One key missing out of the sixteen.
        let mut fifteen = strategy(5, json!({}));
        fifteen["body"]["config_options"]
            .as_object_mut()
            .unwrap()
            .remove("enable-tunnel");
        assert_eq!(
            check(&s.sign(&fifteen), &keys, &expect(4), true)
                .unwrap_err()
                .reason,
            Reason::NotAllowed
        );
        let full: BTreeMap<String, String> = serde_json::from_value(full_set()).unwrap();
        assert!(is_full_set(&full));
    }

    #[test]
    fn unreadable_seq_refuses_a_verified_envelope() {
        // G2-5: the stored seq could not be read -> not applied, reported with its seq.
        let s = signer();
        let keys = vec![s.trusted.clone()];
        let item = s.sign(&strategy(5, json!({})));
        assert!(check_stored(&item, &keys, &expect(0), true, true).is_ok());
        assert_eq!(
            check_stored(&item, &keys, &expect(0), true, false),
            Err(Rejection {
                reason: Reason::ApplyFailed,
                k: Some(s.trusted.k.clone()),
                seq: Some(5),
            })
        );
        // Verification errors still come first.
        assert_eq!(
            check_stored(&item, &[], &expect(0), true, false)
                .unwrap_err()
                .reason,
            Reason::UnknownKey
        );
    }

    /// Records every write; `fail_at` makes one step fail (the first time it runs).
    #[derive(Default)]
    struct FakeSteps {
        fail_at: Option<&'static str>,
        options: &'static str,
        role: Option<SenseRole>,
        seq: u64,
        log: Vec<String>,
    }

    impl FakeSteps {
        fn new(fail_at: Option<&'static str>) -> Self {
            Self {
                fail_at,
                options: "old",
                role: Some(SenseRole::Host),
                ..Default::default()
            }
        }

        fn step(&mut self, name: &'static str) -> Result<(), String> {
            self.log.push(name.to_owned());
            if self.fail_at == Some(name) {
                self.fail_at = None;
                return Err(format!("{name} failed"));
            }
            Ok(())
        }
    }

    impl ApplySteps for FakeSteps {
        type Snapshot = &'static str;
        fn check_writable(&mut self) -> Result<(), String> {
            self.step("check")
        }
        fn snapshot(&mut self) -> &'static str {
            self.options
        }
        fn set_options(&mut self) -> Result<(), String> {
            self.step("options")?;
            self.options = "new";
            Ok(())
        }
        fn restore_options(&mut self, snapshot: &'static str) {
            self.log.push("restore options".to_owned());
            self.options = snapshot;
        }
        fn store_role(&mut self, role: SenseRole) -> Result<(), String> {
            self.step("role")?;
            self.role = Some(role);
            Ok(())
        }
        fn store_seq(&mut self) -> Result<(), String> {
            self.step("seq")?;
            self.seq = 7;
            Ok(())
        }
    }

    #[test]
    fn apply_writes_settings_then_role_then_seq() {
        let (host, both) = (Some(SenseRole::Host), Some(SenseRole::Both));
        let mut steps = FakeSteps::new(None);
        assert_eq!(apply_steps(&mut steps, host, both), Ok(()));
        assert_eq!(steps.log, ["check", "options", "role", "seq"]);
        assert_eq!((steps.options, steps.role, steps.seq), ("new", both, 7));
        // No role change: the role is not written.
        let mut steps = FakeSteps::new(None);
        assert_eq!(apply_steps(&mut steps, host, None), Ok(()));
        assert_eq!(steps.log, ["check", "options", "seq"]);
        assert_eq!((steps.options, steps.role, steps.seq), ("new", host, 7));
    }

    #[test]
    fn failed_apply_leaves_the_computer_as_it_was() {
        let (host, both) = (Some(SenseRole::Host), Some(SenseRole::Both));
        // G2-6: the registry is not writable -> nothing is touched.
        let mut steps = FakeSteps::new(Some("check"));
        assert_eq!(apply_steps(&mut steps, host, both), Err(Reason::ApplyFailed));
        assert_eq!(steps.log, ["check"]);
        assert_eq!((steps.options, steps.role, steps.seq), ("old", host, 0));
        // K2-2: role write fails -> settings restored, seq not stored.
        let mut steps = FakeSteps::new(Some("role"));
        assert_eq!(apply_steps(&mut steps, host, both), Err(Reason::ApplyFailed));
        assert_eq!(steps.log, ["check", "options", "role", "restore options"]);
        assert_eq!((steps.options, steps.role, steps.seq), ("old", host, 0));
        // K2-2: seq write fails -> old role and settings restored.
        let mut steps = FakeSteps::new(Some("seq"));
        assert_eq!(apply_steps(&mut steps, host, both), Err(Reason::ApplyFailed));
        assert_eq!(
            steps.log,
            ["check", "options", "role", "seq", "role", "restore options"]
        );
        assert_eq!((steps.options, steps.role, steps.seq), ("old", host, 0));
        // Settings fail -> restored, role never written.
        let mut steps = FakeSteps::new(Some("options"));
        assert_eq!(apply_steps(&mut steps, host, both), Err(Reason::ApplyFailed));
        assert_eq!(steps.log, ["check", "options", "restore options"]);
        assert_eq!((steps.options, steps.role, steps.seq), ("old", host, 0));
    }
}
