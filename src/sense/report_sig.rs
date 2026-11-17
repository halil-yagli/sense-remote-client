//! Sense Remote: the signed device report in the heartbeat (wave 3, task I7; plan K-R2-3,
//! security review G2-1).
//!
//! Without a signature anyone who knows a computer's `id` + `uuid` could send a heartbeat that
//! says "applied" (`applied_seq`) or "rejected" (`envelope_error`) and so stop the delivery of a
//! permission change. The computer therefore signs the state fields of `sense` with its own
//! Ed25519 key (RustDesk's key pair, `Config::get_key_pair()`); the panel knows the public key
//! only from the authenticated enrolment (`enroll.device_pk`) and ignores unsigned, invalid or
//! replayed reports.
//!
//! Contract (panel `packages/shared`, test vector `testdata/hb-report-v1.json`):
//! - signed bytes = `"sense-remote/hb-report/v1\n"` ‖ JCS (RFC 8785) of
//!   `{ id, uuid, ts, applied_seq }` plus those of `SIGNED_FIELDS` that are present in `sense`
//!   (a missing field is left out, never written as `null`); nothing else is signed.
//! - `sense.report = { ts, sig }`: `ts` local Unix seconds, strictly increasing per report;
//!   `sig` the 64-byte detached signature, unpadded base64url.
//! - `applied_seq` is required: without it (the stored seq could not be read, G2-5) no report
//!   is sent.
//!
//! Pure functions only; the sync loop (`hbbs_http/sync.rs`) reads the key and calls `sign_into`
//! as the very last change to `sense`. The secret key never leaves this call (no log, no body).

use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{self, crypto::sign},
};
use serde_json::{json, Map, Value};

/// Domain separation, same bytes as the panel.
pub const PREFIX: &[u8] = b"sense-remote/hb-report/v1\n";
/// The `sense` fields that are signed when present (besides the required `applied_seq`).
pub const SIGNED_FIELDS: [&str; 5] = [
    "applied_seq",
    "envelope_error",
    "clock_skew_s",
    "caps",
    "maintenance_curtain",
];
const KEY_REPORT: &str = "report";
const KEY_APPLIED_SEQ: &str = "applied_seq";

/// `ts` of the next report: the local clock, but always above the last one sent, so the panel's
/// replay check (`ts > last report_ts`) never drops a report of this process because two
/// heartbeats fell into the same second.
pub fn next_ts(last: Option<i64>, now_s: i64) -> i64 {
    match last {
        Some(last) if now_s <= last => last.saturating_add(1),
        _ => now_s,
    }
}

/// Sense Remote (panel A7): `ts` must also increase across restarts. The sync loop persists a
/// reservation (an upper bound of every `ts` it has sent) and starts a new process above it.
/// Persisting `RESERVE_S` ahead keeps the writes to about one a minute; after a restart `ts` is
/// at most `RESERVE_S + 1` s ahead of the clock, inside the panel's 300 s future limit.
pub const RESERVE_S: i64 = 60;

/// `ts` of the next report and, when it passes the stored reservation, the new reservation to
/// store **before** the report is sent. `last`: last `ts` of this process; `reserved`: the stored
/// reservation (read at start, then the last value stored).
pub fn next_ts_reserved(last: Option<i64>, reserved: Option<i64>, now_s: i64) -> (i64, Option<i64>) {
    // In a running process `last` is the floor; the reservation only matters for the first
    // report after a start (it is above every `ts` sent before).
    let ts = next_ts(last.or(reserved), now_s);
    let new_reservation = reserved
        .map_or(true, |reserved| ts > reserved)
        .then(|| ts.saturating_add(RESERVE_S));
    (ts, new_reservation)
}

/// Stored reservation as written by the sync loop; anything else counts as none.
pub fn parse_reservation(value: &str) -> Option<i64> {
    value.trim().parse::<i64>().ok().filter(|ts| *ts > 0)
}

/// The bytes the device signs. `None` when `sense` is not an object or has no `applied_seq`.
pub fn signed_bytes(id: &str, uuid: &str, ts: i64, sense: &Value) -> Option<Vec<u8>> {
    let sense = sense.as_object()?;
    sense.get(KEY_APPLIED_SEQ)?;
    let mut object = Map::new();
    object.insert("id".to_owned(), json!(id));
    object.insert("uuid".to_owned(), json!(uuid));
    object.insert("ts".to_owned(), json!(ts));
    for field in SIGNED_FIELDS {
        if let Some(value) = sense.get(field) {
            object.insert(field.to_owned(), value.clone());
        }
    }
    let mut bytes = PREFIX.to_vec();
    bytes.extend_from_slice(super::report::canonical_json(&Value::Object(object)).as_bytes());
    Some(bytes)
}

/// Signs the current `sense` fields and adds `sense.report = { ts, sig }`. `secret_key` is
/// RustDesk's 64-byte Ed25519 secret key. Returns false (and adds nothing) when there is no
/// usable key or no `applied_seq`; the heartbeat is then sent unsigned and the panel ignores its
/// state fields. Call it after every other change to `sense`.
pub fn sign_into(sense: &mut Value, id: &str, uuid: &str, ts: i64, secret_key: &[u8]) -> bool {
    let Some(secret_key) = sign::SecretKey::from_slice(secret_key) else {
        return false;
    };
    let Some(bytes) = signed_bytes(id, uuid, ts, sense) else {
        return false;
    };
    if sodiumoxide::init().is_err() {
        return false;
    }
    let signature = sign::sign_detached(&bytes, &secret_key);
    let Some(object) = sense.as_object_mut() else {
        return false;
    };
    object.insert(
        KEY_REPORT.to_owned(),
        json!({ "ts": ts, "sig": URL_SAFE_NO_PAD.encode(signature.to_bytes()) }),
    );
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    const VECTOR: &str = include_str!("testdata/hb-report-v1.json");

    fn vector() -> Value {
        serde_json::from_str(VECTOR).expect("hb-report-v1.json is valid JSON")
    }

    /// The panel's `verifyDeviceReport`, written down from the vector's description, so that the
    /// whole vector (21 cases) is checked here and the client's bytes are proven against it.
    fn panel_verify(
        heartbeat: &Value,
        device_pk: Option<&str>,
        last_report_ts: Option<i64>,
        now_s: i64,
        future_skew_s: i64,
    ) -> &'static str {
        let Some(device_pk) = device_pk else {
            return "no_key";
        };
        let sense = &heartbeat["sense"];
        let Some(report) = sense.get(KEY_REPORT) else {
            return "unsigned";
        };
        let bad = "bad_signature";
        let Some(report) = report.as_object() else {
            return bad;
        };
        if report.len() != 2 {
            return bad;
        }
        let (Some(ts), Some(sig)) = (
            report.get("ts").and_then(Value::as_i64).filter(|ts| *ts > 0),
            report.get("sig").and_then(Value::as_str),
        ) else {
            return bad;
        };
        let sig_alphabet = sig
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if sig.len() != 86 || !sig_alphabet {
            return bad;
        }
        let Some(signature) = URL_SAFE_NO_PAD
            .decode(sig)
            .ok()
            .and_then(|bytes| sign::Signature::from_bytes(&bytes).ok())
        else {
            return bad;
        };
        let Some(public_key) = URL_SAFE_NO_PAD
            .decode(device_pk)
            .ok()
            .and_then(|bytes| sign::PublicKey::from_slice(&bytes))
        else {
            return bad;
        };
        let id = heartbeat["id"].as_str().unwrap();
        let uuid = heartbeat["uuid"].as_str().unwrap();
        let Some(bytes) = signed_bytes(id, uuid, ts, sense) else {
            return bad;
        };
        sodiumoxide::init().unwrap();
        if !sign::verify_detached(&signature, &bytes, &public_key) {
            return bad;
        }
        if ts > now_s + future_skew_s {
            return "future";
        }
        if last_report_ts.is_some_and(|last| ts <= last) {
            return "replayed";
        }
        "ok"
    }

    #[test]
    fn vector_constants_match() {
        let v = vector();
        assert_eq!(v["v"], 1);
        assert_eq!(v["prefix"].as_str().unwrap().as_bytes(), PREFIX);
        let theirs: Vec<&str> = v["signed_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f.as_str().unwrap())
            .collect();
        assert_eq!(theirs, SIGNED_FIELDS);
    }

    #[test]
    fn vector_cases_match_and_signed_text_is_byte_identical() {
        let v = vector();
        let future_skew_s = v["future_skew_s"].as_i64().unwrap();
        let cases = v["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 21, "panel vector hb-report-v1 has 21 cases");
        let mut failures = Vec::new();
        let mut with_text = 0;
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let heartbeat = &case["heartbeat"];
            let got = panel_verify(
                heartbeat,
                case["device_pk"].as_str(),
                case["last_report_ts"].as_i64(),
                case["now_s"].as_i64().unwrap(),
                future_skew_s,
            );
            let wanted = case["result"].as_str().unwrap();
            if got != wanted {
                failures.push(format!("{name}: expected {wanted}, got {got}"));
            }
            // Every case whose signature is valid carries the exact text: ours must be equal.
            if let Some(text) = case.get("signed_text").and_then(Value::as_str) {
                with_text += 1;
                let sense = &heartbeat["sense"];
                let ours = signed_bytes(
                    heartbeat["id"].as_str().unwrap(),
                    heartbeat["uuid"].as_str().unwrap(),
                    sense["report"]["ts"].as_i64().unwrap(),
                    sense,
                )
                .unwrap();
                if ours != text.as_bytes() {
                    failures.push(format!(
                        "{name}: signed text differs\n ours:   {}\n theirs: {text}",
                        String::from_utf8_lossy(&ours)
                    ));
                }
            }
        }
        assert!(with_text >= 9, "valid-signature cases carry signed_text");
        assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
    }

    // Key made at run time; nothing secret is stored in the repository.
    fn device_key() -> (sign::PublicKey, sign::SecretKey) {
        sodiumoxide::init().unwrap();
        sign::gen_keypair()
    }

    fn sense_sample() -> Value {
        json!({
            "v": 1, "role": "controller", "app_version": 1,
            "displays_hash": "0".repeat(64),
            "health": { "at": 1_800_000_000, "cpu_pct": 3.5 },
            "applied_seq": 4,
            "envelope_error": { "seq": 5, "k": "0123456789abcdef", "reason": "expired", "at": 1_799_999_990 },
            "clock_skew_s": 600,
            "caps": ["role_all"],
        })
    }

    #[test]
    fn signed_report_passes_the_panel_check() {
        let (pk, sk) = device_key();
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let mut sense = sense_sample();
        assert!(sign_into(&mut sense, "123456789", "dGVzdC11dWlk", 1_800_000_000, &sk.0));
        let heartbeat = json!({ "id": "123456789", "uuid": "dGVzdC11dWlk", "sense": sense });
        assert_eq!(panel_verify(&heartbeat, Some(pk.as_str()), None, 1_800_000_000, 300), "ok");
        assert_eq!(
            panel_verify(&heartbeat, Some(pk.as_str()), Some(1_800_000_000), 1_800_000_000, 300),
            "replayed"
        );
        let report = heartbeat["sense"]["report"].as_object().unwrap();
        let keys: BTreeSet<&str> = report.keys().map(String::as_str).collect();
        assert_eq!(keys, BTreeSet::from(["sig", "ts"]));
        assert_eq!(report["sig"].as_str().unwrap().len(), 86);
        // The secret key is nowhere in the body.
        let body = heartbeat.to_string();
        assert!(!body.contains(&URL_SAFE_NO_PAD.encode(&sk.0[..32])));
        assert!(!body.contains(&hbb_common::base64::engine::general_purpose::STANDARD.encode(&sk.0)));
    }

    #[test]
    fn unsigned_fields_are_free_signed_fields_are_bound() {
        let (pk, sk) = device_key();
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let mut sense = sense_sample();
        assert!(sign_into(&mut sense, "123456789", "dGVzdC11dWlk", 1_800_000_000, &sk.0));
        let heartbeat = json!({ "id": "123456789", "uuid": "dGVzdC11dWlk", "sense": sense });
        let check = |hb: &Value| panel_verify(hb, Some(pk.as_str()), None, 1_800_000_000, 300);
        // health / role / displays_hash are not signed.
        let mut other = heartbeat.clone();
        other["sense"]["health"]["cpu_pct"] = json!(99.0);
        other["sense"]["role"] = json!("host");
        assert_eq!(check(&other), "ok");
        // G2-1: a forged "applied" or a forged rejection is detected.
        let mut forged = heartbeat.clone();
        forged["sense"]["applied_seq"] = json!(5);
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = heartbeat.clone();
        forged["sense"]["envelope_error"]["seq"] = json!(6);
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = heartbeat.clone();
        forged["sense"]["maintenance_curtain"] = json!(true);
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = heartbeat.clone();
        forged["id"] = json!("987654321");
        assert_eq!(check(&forged), "bad_signature");
    }

    #[test]
    fn no_report_without_key_or_applied_seq() {
        let (_, sk) = device_key();
        // G2-5: unreadable seq -> no applied_seq -> no report.
        let mut sense = sense_sample();
        sense.as_object_mut().unwrap().remove("applied_seq");
        let before = sense.clone();
        assert!(!sign_into(&mut sense, "1", "u", 1, &sk.0));
        assert_eq!(sense, before);
        // No usable key (empty or wrong length).
        let mut sense = sense_sample();
        assert!(!sign_into(&mut sense, "1", "u", 1, &[]));
        assert!(!sign_into(&mut sense, "1", "u", 1, &sk.0[..32]));
        assert!(sense.get("report").is_none());
        assert_eq!(signed_bytes("1", "u", 1, &json!([])), None);
    }

    #[test]
    fn ts_increases_across_restarts() {
        // First report ever: reserve ahead.
        assert_eq!(next_ts_reserved(None, None, 1_000), (1_000, Some(1_060)));
        // Same process, inside the reservation: no write.
        assert_eq!(next_ts_reserved(Some(1_000), Some(1_060), 1_000), (1_001, None));
        assert_eq!(next_ts_reserved(Some(1_001), Some(1_060), 1_015), (1_015, None));
        // Passing the reservation: write a new one first.
        assert_eq!(next_ts_reserved(Some(1_059), Some(1_060), 1_061), (1_061, Some(1_121)));
        // Restart within the same second (last is gone): above every ts sent before.
        let (ts, reservation) = next_ts_reserved(None, Some(1_060), 1_001);
        assert_eq!((ts, reservation), (1_061, Some(1_121)));
        // Restart with the clock set back an hour: still increasing.
        let (ts, _) = next_ts_reserved(None, Some(1_121), 1_121 - 3_600);
        assert_eq!(ts, 1_122);
        // Normal restart later on: the clock wins, at most RESERVE_S + 1 ahead otherwise.
        assert_eq!(next_ts_reserved(None, Some(1_121), 5_000), (5_000, Some(5_060)));
        // Simulated run: every ts strictly above the previous one, whatever the restarts.
        let mut stored: Option<i64> = None;
        let mut last: Option<i64> = None;
        let mut previous = i64::MIN;
        for (step, now) in [10, 10, 10, 11, 75, 75, 12, 12, 200, 199].into_iter().enumerate() {
            if step == 3 || step == 6 || step == 9 {
                last = None; // process restart
            }
            let (ts, reservation) = next_ts_reserved(last, stored, now);
            if let Some(r) = reservation {
                stored = Some(r);
            }
            assert!(ts > previous, "step {step}: {ts} <= {previous}");
            assert!(stored.unwrap() >= ts);
            previous = ts;
            last = Some(ts);
        }
        assert_eq!(parse_reservation("1121"), Some(1_121));
        assert_eq!(parse_reservation(""), None);
        assert_eq!(parse_reservation("-5"), None);
        assert_eq!(parse_reservation("x"), None);
    }

    #[test]
    fn ts_is_strictly_increasing() {
        assert_eq!(next_ts(None, 100), 100);
        assert_eq!(next_ts(Some(99), 100), 100);
        assert_eq!(next_ts(Some(100), 100), 101);
        // The clock went back: still above the last report.
        assert_eq!(next_ts(Some(500), 100), 501);
        assert_eq!(next_ts(Some(i64::MAX), 100), i64::MAX);
    }
}
