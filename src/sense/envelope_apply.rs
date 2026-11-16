//! Sense Remote: the heartbeat side of signed panel envelopes (wave 2, task I4; plan §3.7).
//!
//! The heartbeat answer may carry `sense_envelopes` (signed permission sets) and
//! `sense_server_time`. Upstream also acted on plain `strategy`, `disconnect` and `modified_at`;
//! those are unsigned, so Sense never applies them any more: `parse_answer` keeps only the keys
//! below and lists the rest as ignored (logged, nothing else).
//!
//! For every envelope: `envelope::verify` (signature, issuer, device, time, seq, allow list) →
//! platform gate (only Windows applies; macOS verifies and reports `unsupported_platform`,
//! MAC-SONRA-9) → the sync loop applies it (role, settings, disconnect, then `EnvelopeSeq`) →
//! `Report` remembers the last rejection and the clock skew for the next heartbeat's `sense`
//! (`applied_seq`, `envelope_error`, `clock_skew_s`).
//!
//! The server time is never used to verify: it is only compared with the local clock and the
//! difference reported (plan R8).

use super::{
    envelope::{self, Expect, PanelRole, Reason, Rejection, Verified},
    envelope_keys::TrustedKey,
    SenseRole,
};
use serde_json::{json, Map, Value};

/// Same limit as the panel's `HeartbeatResponse.sense_envelopes`.
pub const MAX_ENVELOPES: usize = 8;
/// A larger difference between panel and local clock is reported (`clock_skew_s`).
pub const SKEW_REPORT_S: i64 = 300;
/// Windows applies verified envelopes; other platforms only verify them (MAC-SONRA-9).
pub const APPLIES: bool = cfg!(windows);

const KEY_SYSINFO: &str = "sysinfo";
const KEY_ENVELOPES: &str = "sense_envelopes";
const KEY_SERVER_TIME: &str = "sense_server_time";

/// What the sync loop takes from a heartbeat answer. There is deliberately no field for the
/// upstream `strategy`, `disconnect` or `modified_at`.
#[derive(Debug, Default, PartialEq)]
pub struct HeartbeatAnswer {
    /// Panel asks for a new sysinfo upload (upstream: presence of the key is enough).
    pub sysinfo: bool,
    pub envelopes: Vec<Value>,
    pub server_time: Option<i64>,
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
            _ => answer.ignored.push(key),
        }
    }
    answer.ignored.sort();
    Some(answer)
}

/// Verification plus the platform gate. `Ok` = apply it now.
pub fn check(
    item: &Value,
    keys: &[TrustedKey],
    expect: &Expect,
    applies: bool,
) -> Result<Verified, Rejection> {
    let verified = envelope::verify(item, keys, expect)?;
    if !applies {
        return Err(Rejection {
            reason: Reason::UnsupportedPlatform,
            k: Some(verified.k),
            seq: Some(verified.seq),
        });
    }
    Ok(verified)
}

/// Role to store, `None` when it stays the same. The panel may only switch between Host and
/// Host + Controller (plan K-ROL): a Controller-only or uninstalled computer is refused.
pub fn role_change(
    installed: Option<SenseRole>,
    wanted: Option<PanelRole>,
) -> Result<Option<SenseRole>, Reason> {
    let Some(wanted) = wanted else {
        return Ok(None);
    };
    match installed {
        Some(current @ (SenseRole::Host | SenseRole::Both)) => {
            let next = wanted.sense_role();
            Ok((next != current).then_some(next))
        }
        Some(SenseRole::Controller) | None => Err(Reason::NotAllowed),
    }
}

/// Difference panel − local clock when it is larger than `SKEW_REPORT_S`.
pub fn clock_skew(server_s: i64, local_s: i64) -> Option<i64> {
    let diff = server_s.saturating_sub(local_s);
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
        }
    }

    /// Adds `applied_seq` (always, 0 included), `envelope_error` and `clock_skew_s` to the
    /// heartbeat's `sense` object.
    pub fn extend(&self, sense: &mut Value, applied_seq: u64) {
        let Some(object) = sense.as_object_mut() else {
            return;
        };
        object.insert("applied_seq".to_owned(), json!(applied_seq));
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
        assert_eq!(APPLIES, cfg!(windows));
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
        let item = s.sign(&strategy(7, json!({ "sense_role": "controller" })));
        assert_eq!(
            check(&item, &keys, &expect(0), true).unwrap_err().reason,
            Reason::BadPayload
        );
    }

    #[test]
    fn role_change_only_between_host_and_both() {
        let (host, both, controller) = (SenseRole::Host, SenseRole::Both, SenseRole::Controller);
        let (p_host, p_both) = (PanelRole::Host, PanelRole::HostController);
        assert_eq!(role_change(Some(host), None), Ok(None));
        assert_eq!(role_change(None, None), Ok(None));
        assert_eq!(role_change(Some(host), Some(p_host)), Ok(None));
        assert_eq!(role_change(Some(host), Some(p_both)), Ok(Some(both)));
        assert_eq!(role_change(Some(both), Some(p_host)), Ok(Some(host)));
        assert_eq!(role_change(Some(both), Some(p_both)), Ok(None));
        assert_eq!(role_change(Some(controller), Some(p_both)), Err(Reason::NotAllowed));
        assert_eq!(role_change(None, Some(p_host)), Err(Reason::NotAllowed));
    }

    #[test]
    fn clock_skew_is_reported_beyond_five_minutes() {
        assert_eq!(clock_skew(NOW, NOW), None);
        assert_eq!(clock_skew(NOW + 300, NOW), None);
        assert_eq!(clock_skew(NOW - 300, NOW), None);
        assert_eq!(clock_skew(NOW + 301, NOW), Some(301));
        assert_eq!(clock_skew(NOW - 3_600, NOW), Some(-3_600));
        let mut report = Report::default();
        report.server_time(Some(NOW + 900), NOW);
        assert_eq!(report.clock_skew_s, Some(900));
        report.server_time(None, NOW);
        assert_eq!(report.clock_skew_s, Some(900));
        report.server_time(Some(NOW), NOW);
        assert_eq!(report.clock_skew_s, None);
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
        Report::default().extend(&mut sense, 0);
        assert_eq!(sense["applied_seq"], json!(0));
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
        report.server_time(Some(NOW - 600), NOW);
        let mut sense = json!({ "v": 1, "role": "host_controller", "app_version": 1 });
        report.extend(&mut sense, 3);
        assert_eq!(
            sense,
            json!({
                "v": 1, "role": "host_controller", "app_version": 1, "applied_seq": 3,
                "envelope_error": { "seq": 9, "k": "0123456789abcdef", "reason": "expired", "at": NOW },
                "clock_skew_s": -600,
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
}
