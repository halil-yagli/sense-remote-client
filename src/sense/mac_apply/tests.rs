// Sense Remote (Mac M5): the daemon's decisions and the user process's reading of its answer,
// tested without root and without macOS (`DaemonStore` is faked). Keys are generated at run
// time; no private key is stored in the repository.

use super::*;
use crate::sense::envelope::{OptionRule, ALLOWED_OPTIONS, SIGNING_PREFIX};
use crate::sense::envelope_keys::{key_id, parse_keys};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{self, crypto::sign},
};
use serde_json::{json, Map};

const ISS: &str = "remote.snsdpt.com";
const DID: &str = "123456789";
const DUUID: &str = "dGVzdC11dWlk";
const NOW: i64 = 1_800_000_000;

struct Signer {
    sk: sign::SecretKey,
    trusted: TrustedKey,
}

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
    fn sign_bytes(&self, payload: &[u8]) -> Value {
        let mut data = SIGNING_PREFIX.to_vec();
        data.extend_from_slice(payload);
        let signature = &sign::sign(&data, &self.sk)[..64];
        json!({
            "k": self.trusted.k,
            "p": URL_SAFE_NO_PAD.encode(payload),
            "s": URL_SAFE_NO_PAD.encode(signature),
        })
    }

    /// The envelope as the user process forwards it: text.
    fn sign(&self, payload: &Value) -> String {
        self.sign_bytes(&serde_json::to_vec(payload).unwrap())
            .to_string()
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

fn ctx(keys: &[TrustedKey]) -> DaemonContext<'_> {
    DaemonContext {
        keys,
        iss: ISS,
        did: DID,
        duuid: DUUID,
        now_s: NOW,
        applies: true,
        macos: true,
    }
}

/// The daemon's state, with every call recorded. `fail_at` makes one write fail once.
#[derive(Debug, Clone, PartialEq)]
struct FakeStore {
    role: Option<SenseRole>,
    seq: u64,
    options: HashMap<String, String>,
    readable: bool,
    fail_at: Option<&'static str>,
    log: Vec<&'static str>,
}

impl FakeStore {
    fn new(seq: u64) -> Self {
        Self {
            role: Some(SenseRole::Host),
            seq,
            options: HashMap::from([("enable-terminal".to_owned(), "N".to_owned())]),
            readable: true,
            fail_at: None,
            log: Vec::new(),
        }
    }

    fn step(&mut self, name: &'static str) -> Result<(), String> {
        self.log.push(name);
        if self.fail_at == Some(name) {
            self.fail_at = None;
            return Err(format!("{name} failed"));
        }
        Ok(())
    }

    /// Nothing was written and no write was even tried.
    fn untouched_since(&self, before: &FakeStore) -> bool {
        (self.role, self.seq, &self.options) == (before.role, before.seq, &before.options)
            && self.log.iter().all(|step| *step == "read")
    }
}

impl DaemonStore for FakeStore {
    fn read_state(&mut self) -> Result<(Option<SenseRole>, u64), String> {
        self.log.push("read");
        if self.readable {
            Ok((self.role, self.seq))
        } else {
            Err("state not readable".to_owned())
        }
    }
    fn check_writable(&mut self) -> Result<(), String> {
        self.step("check")
    }
    fn options(&mut self) -> HashMap<String, String> {
        self.options.clone()
    }
    fn set_options(&mut self, options: &BTreeMap<String, String>) -> Result<(), String> {
        self.step("options")?;
        self.options
            .extend(options.iter().map(|(k, v)| (k.clone(), v.clone())));
        Ok(())
    }
    fn restore_options(&mut self, snapshot: HashMap<String, String>) {
        self.log.push("restore options");
        self.options = snapshot;
    }
    fn store_role(&mut self, role: SenseRole) -> Result<(), String> {
        self.step("role")?;
        self.role = Some(role);
        Ok(())
    }
    fn store_seq(&mut self, seq: u64) -> Result<(), String> {
        self.step("seq")?;
        self.seq = seq;
        Ok(())
    }
}

fn reason_of(outcome: &SenseApplyOutcome) -> &str {
    match outcome {
        SenseApplyOutcome::Applied { .. } => "ok",
        SenseApplyOutcome::Rejected { reason } => reason,
    }
}

// The wire format between the user process and the daemon (an agent can outlive a daemon
// update): keep the tags stable.
#[test]
fn ipc_wire_format() {
    let apply = SenseEnvelopeIpc::Apply {
        envelopes: vec!["{}".to_owned()],
        server_time: Some(7),
    };
    let json = serde_json::to_string(&apply).unwrap();
    assert_eq!(
        json,
        r#"{"t":"Apply","c":{"envelopes":["{}"],"server_time":7}}"#
    );
    assert_eq!(serde_json::from_str::<SenseEnvelopeIpc>(&json).unwrap(), apply);

    let result = SenseEnvelopeIpc::Result(vec![
        SenseApplyOutcome::Applied {
            seq: 42,
            role: Some("both".to_owned()),
            disconnect: vec![3],
        },
        SenseApplyOutcome::Rejected {
            reason: "replayed".to_owned(),
        },
    ]);
    let json = serde_json::to_string(&result).unwrap();
    assert_eq!(
        json,
        r#"{"t":"Result","c":[{"t":"Applied","c":{"seq":42,"role":"both","disconnect":[3]}},{"t":"Rejected","c":{"reason":"replayed"}}]}"#
    );
    assert_eq!(serde_json::from_str::<SenseEnvelopeIpc>(&json).unwrap(), result);
}

#[test]
fn limits_count_and_size() {
    assert!(within_limits(&[]));
    assert!(within_limits(&vec!["x".repeat(10); MAX_ENVELOPES]));
    assert!(!within_limits(&vec!["x".to_owned(); MAX_ENVELOPES + 1]));
    assert!(within_limits(&["x".repeat(MAX_TOTAL_BYTES)]));
    assert!(!within_limits(&["x".repeat(MAX_TOTAL_BYTES), "x".to_owned()]));
}

#[test]
fn one_call_per_second() {
    assert!(call_allowed(None));
    assert!(!call_allowed(Some(0)));
    assert!(!call_allowed(Some(MIN_CALL_INTERVAL_MS - 1)));
    assert!(call_allowed(Some(MIN_CALL_INTERVAL_MS)));
}

#[test]
fn valid_envelope_is_applied_and_its_seq_stored() {
    let s = signer();
    let keys = vec![s.trusted.clone()];
    let raw = s.sign(&strategy(
        5,
        json!({ "sense_role": "host_controller", "disconnect": [3, 9_000_000_000i64] }),
    ));
    let mut store = FakeStore::new(4);
    let outcome = apply_one(&raw, &ctx(&keys), &mut store);
    assert_eq!(
        outcome,
        SenseApplyOutcome::Applied {
            seq: 5,
            role: Some("both".to_owned()),
            // An id that is no connection id (beyond i32) is dropped, not truncated.
            disconnect: vec![3],
        }
    );
    // Windows order: writable check, settings, role, seq last.
    assert_eq!(store.log, ["read", "check", "options", "role", "seq"]);
    assert_eq!((store.role, store.seq), (Some(SenseRole::Both), 5));
    assert_eq!(store.options["enable-terminal"], "Y");
    assert_eq!(store.options["enable-keyboard"], "Y");
    // macOS has no curtain: the privacy mode permission is not written.
    assert!(!store.options.contains_key("enable-privacy-mode"));

    // Same role as installed: nothing to report, the role is not rewritten.
    let raw = s.sign(&strategy(6, json!({ "sense_role": "host_controller" })));
    let outcome = apply_one(&raw, &ctx(&keys), &mut store);
    assert_eq!(
        outcome,
        SenseApplyOutcome::Applied {
            seq: 6,
            role: None,
            disconnect: vec![],
        }
    );
    assert_eq!(store.seq, 6);
}

#[test]
fn unsupported_options_are_dropped_only_on_macos() {
    let full: BTreeMap<String, String> = serde_json::from_value(full_set()).unwrap();
    let mac = applicable_options(&full, true);
    assert_eq!(mac.len(), full.len() - MAC_UNSUPPORTED_OPTIONS.len());
    for key in MAC_UNSUPPORTED_OPTIONS {
        assert!(full.contains_key(key), "{key} is part of the full set");
        assert!(!mac.contains_key(key), "{key}");
    }
    assert_eq!(applicable_options(&full, false), full);
}

// The heart of M5: whatever the user process sends, the daemon only acts on an envelope that
// passes its own verification. Every forgery below leaves the state exactly as it was, without
// a single write attempt.
#[test]
fn forged_envelopes_from_the_user_process_change_nothing() {
    let s = signer();
    let stranger = signer();
    let keys = vec![s.trusted.clone()];
    let valid = strategy(5, json!({ "sense_role": "controller" }));

    // Signature does not fit the payload: the payload of one envelope under the signature of
    // another (e.g. a user raising its own permissions inside a genuine envelope).
    let genuine: Value = serde_json::from_str(&s.sign(&valid)).unwrap();
    let mut wanted = valid.clone();
    wanted["body"]["config_options"]["enable-terminal"] = json!("N");
    let other: Value = serde_json::from_str(&s.sign(&wanted)).unwrap();
    let swapped = json!({ "k": genuine["k"], "p": other["p"], "s": genuine["s"] }).to_string();

    let mut other_device = valid.clone();
    other_device["did"] = json!("987654321");
    let mut other_uuid = valid.clone();
    other_uuid["duuid"] = json!("YmFza2EtdXVpZA");
    let mut other_panel = valid.clone();
    other_panel["iss"] = json!("evil.example.test");
    let mut expired = valid.clone();
    expired["nbf"] = json!(NOW - 30 * 86_400);
    expired["exp"] = json!(NOW - 20 * 86_400);
    let mut future = valid.clone();
    future["nbf"] = json!(NOW + 86_400);
    let mut partial = valid.clone();
    partial["body"]["config_options"] = json!({ "enable-terminal": "Y" });
    let mut not_listed = valid.clone();
    not_listed["body"]["config_options"]["allow-hide-cm"] = json!("Y");
    let mut unknown_field = valid.clone();
    unknown_field["body"]["api_server"] = json!("https://evil.example.test");

    let cases: Vec<(&str, String, &str)> = vec![
        ("payload swapped under a genuine signature", swapped, "bad_signature"),
        ("signed by a key this build does not trust", stranger.sign(&valid), "unknown_key"),
        ("for another computer (id)", s.sign(&other_device), "wrong_device"),
        ("for another computer (uuid)", s.sign(&other_uuid), "wrong_device"),
        ("from another panel", s.sign(&other_panel), "wrong_issuer"),
        ("old seq", s.sign(&strategy(3, json!({}))), "replayed"),
        ("the seq already applied", s.sign(&strategy(4, json!({}))), "replayed"),
        ("expired", s.sign(&expired), "expired"),
        ("not valid yet", s.sign(&future), "not_yet_valid"),
        ("partial set", s.sign(&partial), "not_allowed"),
        ("setting outside the allow list", s.sign(&not_listed), "not_allowed"),
        ("unknown signed field", s.sign(&unknown_field), "bad_payload"),
        ("plain unsigned strategy", valid["body"].to_string(), "malformed"),
        ("the bare payload without signature", valid.to_string(), "malformed"),
        ("not JSON", "apply this".to_owned(), "malformed"),
        ("empty", String::new(), "malformed"),
        ("an IPC result instead of an envelope", r#"{"t":"Result","c":[]}"#.to_owned(), "malformed"),
    ];
    for (name, raw, wanted) in cases {
        let before = FakeStore::new(4);
        let mut store = before.clone();
        let outcome = apply_one(&raw, &ctx(&keys), &mut store);
        assert_eq!(reason_of(&outcome), wanted, "{name}");
        assert!(store.untouched_since(&before), "{name}: {:?}", store.log);
    }

    // The same genuine envelope is applied when it is sent untouched.
    let mut store = FakeStore::new(4);
    assert_eq!(reason_of(&apply_one(&s.sign(&valid), &ctx(&keys), &mut store)), "ok");
    assert_eq!((store.role, store.seq), (Some(SenseRole::Controller), 5));
}

#[test]
fn daemon_uses_its_own_identity_keys_and_clock() {
    let s = signer();
    let keys = vec![s.trusted.clone()];
    let raw = s.sign(&strategy(5, json!({})));
    let before = FakeStore::new(4);
    let rejects = |ctx: DaemonContext, wanted: &str| {
        let mut store = before.clone();
        assert_eq!(reason_of(&apply_one(&raw, &ctx, &mut store)), wanted);
        assert!(store.untouched_since(&before), "{wanted}: {:?}", store.log);
    };
    // A build without panel keys applies nothing.
    rejects(ctx(&[]), "unknown_key");
    // The daemon's id / uuid decide, not what the sender claims to be.
    rejects(DaemonContext { did: "111111111", ..ctx(&keys) }, "wrong_device");
    rejects(DaemonContext { duuid: "YmFza2E", ..ctx(&keys) }, "wrong_device");
    // A daemon without an id (empty root config) matches no envelope.
    rejects(DaemonContext { did: "", ..ctx(&keys) }, "wrong_device");
    rejects(DaemonContext { duuid: "", ..ctx(&keys) }, "wrong_device");
    rejects(DaemonContext { iss: "other.example.test", ..ctx(&keys) }, "wrong_issuer");
    rejects(DaemonContext { now_s: NOW + 30 * 86_400, ..ctx(&keys) }, "expired");
    // A platform that only verifies.
    rejects(DaemonContext { applies: false, ..ctx(&keys) }, "unsupported_platform");
}

#[test]
fn unreadable_or_unwritable_state_applies_nothing() {
    let s = signer();
    let keys = vec![s.trusted.clone()];
    let raw = s.sign(&strategy(5, json!({ "sense_role": "host_controller" })));

    // G2-5: a state file that can not be read is not seq 0.
    let mut before = FakeStore::new(4);
    before.readable = false;
    let mut store = before.clone();
    assert_eq!(reason_of(&apply_one(&raw, &ctx(&keys), &mut store)), "apply_failed");
    assert!(store.untouched_since(&before));

    // G2-6: not writable (e.g. the process is not root) -> refused before anything changes.
    let before = FakeStore::new(4);
    let mut store = before.clone();
    store.fail_at = Some("check");
    assert_eq!(reason_of(&apply_one(&raw, &ctx(&keys), &mut store)), "apply_failed");
    assert_eq!(store.log, ["read", "check"]);
    assert_eq!((store.role, store.seq, &store.options), (before.role, 4, &before.options));

    // K2-2: a later write fails -> role and settings are put back, the seq stays.
    for fail_at in ["options", "role", "seq"] {
        let mut store = before.clone();
        store.fail_at = Some(fail_at);
        assert_eq!(
            reason_of(&apply_one(&raw, &ctx(&keys), &mut store)),
            "apply_failed",
            "{fail_at}"
        );
        assert_eq!(
            (store.role, store.seq, &store.options),
            (before.role, 4, &before.options),
            "{fail_at}"
        );
    }

    // A role for a computer without an installed role (no Sense install) is refused.
    let mut before = FakeStore::new(0);
    before.role = None;
    let mut store = before.clone();
    assert_eq!(reason_of(&apply_one(&raw, &ctx(&keys), &mut store)), "not_allowed");
    assert!(store.untouched_since(&before));
}

#[test]
fn calls_over_the_limits_are_ignored_whole() {
    let s = signer();
    let keys = vec![s.trusted.clone()];
    let before = FakeStore::new(0);
    let valid: Vec<String> = (1..=MAX_ENVELOPES as u64 + 1)
        .map(|seq| s.sign(&strategy(seq, json!({}))))
        .collect();

    // Nine valid envelopes: none is verified, none applied.
    let mut store = before.clone();
    assert_eq!(apply_call(&valid, None, &ctx(&keys), &mut store), None);
    assert_eq!(store, before);

    // More than 64 KB in total, even with a valid envelope first.
    let mut store = before.clone();
    let large = vec![valid[0].clone(), "x".repeat(MAX_TOTAL_BYTES)];
    assert_eq!(apply_call(&large, None, &ctx(&keys), &mut store), None);
    assert_eq!(store, before);

    // A second call within the second.
    let mut store = before.clone();
    let one = &valid[..1];
    assert_eq!(apply_call(one, Some(MIN_CALL_INTERVAL_MS - 1), &ctx(&keys), &mut store), None);
    assert_eq!(store, before);

    // Eight are taken in order; each sees the seq the previous one stored.
    let mut store = before.clone();
    let outcomes = apply_call(&valid[..MAX_ENVELOPES], Some(MIN_CALL_INTERVAL_MS), &ctx(&keys), &mut store)
        .unwrap();
    assert_eq!(outcomes.len(), MAX_ENVELOPES);
    assert!(outcomes.iter().all(|outcome| reason_of(outcome) == "ok"));
    assert_eq!(store.seq, MAX_ENVELOPES as u64);

    // An empty call is answered with an empty result.
    assert_eq!(apply_call(&[], None, &ctx(&keys), &mut store), Some(vec![]));
}

#[test]
fn replay_inside_one_call_is_rejected() {
    let s = signer();
    let keys = vec![s.trusted.clone()];
    let raw = s.sign(&strategy(5, json!({})));
    let forged = "{}".to_owned();
    let mut store = FakeStore::new(4);
    let outcomes =
        apply_call(&[raw.clone(), forged, raw], None, &ctx(&keys), &mut store).unwrap();
    let reasons: Vec<&str> = outcomes.iter().map(reason_of).collect();
    assert_eq!(reasons, ["ok", "malformed", "replayed"]);
    assert_eq!(store.seq, 5);
}

// The panel's shared vector: the daemon gives the same verdict as the client check for every
// case, and nothing but an accepted full set changes the state.
#[test]
fn shared_vector_cases_through_the_daemon() {
    let vector: Value =
        serde_json::from_str(include_str!("../testdata/envelope-v1.json")).unwrap();
    let entries: Vec<String> = vector["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|key| {
            format!(
                "{}={}",
                key["k"].as_str().unwrap(),
                key["public_key"].as_str().unwrap()
            )
        })
        .collect();
    let keys = parse_keys(&entries.join(",")).unwrap();
    let cases = vector["cases"].as_array().unwrap();
    let (mut applied, mut refused) = (0, 0);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let e = &case["expect"];
        let ctx = DaemonContext {
            keys: &keys,
            iss: e["iss"].as_str().unwrap(),
            did: e["did"].as_str().unwrap(),
            duuid: e["duuid"].as_str().unwrap(),
            now_s: e["now_s"].as_i64().unwrap(),
            applies: true,
            macos: true,
        };
        let before = FakeStore::new(e["last_seq"].as_u64().unwrap());
        let mut store = before.clone();
        let outcome = apply_one(&case["envelope"].to_string(), &ctx, &mut store);
        let client = case["result_client"].as_str().unwrap();
        let full = case.get("config_options").is_some_and(|options| {
            let options: BTreeMap<String, String> =
                serde_json::from_value(options.clone()).unwrap();
            envelope_apply::is_full_set(&options)
        });
        // G2-7: a verified but partial set is refused by the applier.
        let wanted = if client == "ok" && !full { "not_allowed" } else { client };
        assert_eq!(reason_of(&outcome), wanted, "{name}");
        if wanted == "ok" {
            applied += 1;
            assert_eq!(Some(store.seq), case["seq"].as_u64(), "{name}");
        } else {
            refused += 1;
            assert!(store.untouched_since(&before), "{name}: {:?}", store.log);
        }
    }
    assert!(applied >= 5 && refused >= 15, "applied {applied}, refused {refused}");
}

#[test]
fn user_process_reads_the_daemon_answer() {
    let forwarded: Vec<(String, u64)> =
        vec![("0123456789abcdef".to_owned(), 5), ("0123456789abcdef".to_owned(), 6)];
    let empty: Vec<SenseApplyOutcome> = Vec::new();
    let failed = |seq: u64| -> Result<AppliedByDaemon, Rejection> {
        Err(Rejection {
            reason: Reason::ApplyFailed,
            k: Some("0123456789abcdef".to_owned()),
            seq: Some(seq),
        })
    };
    // Daemon not running / not root / no answer: nothing is applied.
    assert_eq!(settle(&forwarded, None), vec![failed(5), failed(6)]);
    // An ignored call (limits) answers with an empty list.
    assert_eq!(settle(&forwarded, Some(empty.as_slice())), vec![failed(5), failed(6)]);

    let answer = [
        SenseApplyOutcome::Applied {
            seq: 5,
            role: Some("controller".to_owned()),
            disconnect: vec![7],
        },
        SenseApplyOutcome::Rejected {
            reason: "replayed".to_owned(),
        },
    ];
    assert_eq!(
        settle(&forwarded, Some(answer.as_slice())),
        vec![
            Ok(AppliedByDaemon {
                seq: 5,
                role: Some(SenseRole::Controller),
                disconnect: vec![7],
            }),
            Err(Rejection {
                reason: Reason::Replayed,
                k: Some("0123456789abcdef".to_owned()),
                seq: Some(6),
            }),
        ]
    );

    // "Applied" for another seq than the one forwarded is not taken as applied; an unknown
    // reason name is reported as `apply_failed`; an unknown role name is no role.
    let answer = [
        SenseApplyOutcome::Applied {
            seq: 9,
            role: None,
            disconnect: vec![],
        },
        SenseApplyOutcome::Rejected {
            reason: "something new".to_owned(),
        },
    ];
    assert_eq!(settle(&forwarded, Some(answer.as_slice())), vec![failed(5), failed(6)]);
    let answer = [SenseApplyOutcome::Applied {
        seq: 5,
        role: Some("admin".to_owned()),
        disconnect: vec![],
    }];
    assert_eq!(
        settle(&forwarded[..1], Some(answer.as_slice())),
        vec![Ok(AppliedByDaemon {
            seq: 5,
            role: None,
            disconnect: vec![],
        })]
    );
    assert!(settle(&[], Some(answer.as_slice())).is_empty());
}

// Windows and Linux have no daemon that applies envelopes.
#[cfg(not(target_os = "macos"))]
#[test]
fn other_platforms_reject_in_the_daemon_entry() {
    let out = apply_in_daemon(&["{}".to_owned(), "{}".to_owned()], None);
    let rejected = SenseApplyOutcome::Rejected {
        reason: "unsupported_platform".to_owned(),
    };
    assert_eq!(out, vec![rejected.clone(), rejected]);
}
