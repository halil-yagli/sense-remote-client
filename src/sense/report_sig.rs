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
//! Sense Remote (Sürüm 4 security review S4-4, panel PR #89; vector `testdata/signed-ingest-v1.json`):
//! when the heartbeat answer's `sense_panel_caps` carries `signed_ingest` the client sends
//! - report v2: `"sense-remote/hb-report/v2\n"` ‖ JCS of the v1 object plus `health` and
//!   `mac_permissions` when present and `conn_count` (number of `conns` in the heartbeat body, 0
//!   without) always; `caps` gains `signed_ingest`; `sense.report = { v: 2, ts, sig }`.
//! - the signed sysinfo: `"sense-remote/sysinfo/v1\n"` ‖ JCS of `{ id, uuid, ts, sense }` where
//!   `sense` is the whole sysinfo extension without `report`; `sense.report = { ts, sig }`.
//!
//! Without the panel capability nothing changes (v1, unsigned sysinfo). The capability is kept
//! across restarts, so the first heartbeat after a restart does not fall back to v1.
//!
//! Pure functions only, apart from the panel capability state at the end; the sync loop
//! (`hbbs_http/sync.rs`) reads the key and calls `sign_into` / `sign_into_v2` as the very last
//! change to `sense`. The secret key never leaves this call (no log, no body).

use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{self, crypto::sign},
};
use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicU8, Ordering};

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
const KEY_CAPS: &str = "caps";

/// Sense Remote (S4-4): report v2, same bytes as the panel (`DEVICE_REPORT_V2_SIGNING_PREFIX`).
pub const PREFIX_V2: &[u8] = b"sense-remote/hb-report/v2\n";
/// Report v2 signs these `sense` fields when present (panel `DEVICE_REPORT_V2_FIELDS`), plus
/// `conn_count` always.
pub const SIGNED_FIELDS_V2: [&str; 7] = [
    "applied_seq",
    "envelope_error",
    "clock_skew_s",
    "caps",
    "maintenance_curtain",
    "health",
    "mac_permissions",
];
/// Sense Remote (S4-4): signed sysinfo extension (panel `SYSINFO_REPORT_SIGNING_PREFIX`).
pub const SYSINFO_PREFIX: &[u8] = b"sense-remote/sysinfo/v1\n";
/// Sense Remote (S4-4): the panel capability (`PANEL_CAPS.signedIngest`) and the client
/// capability in the signed `caps` (`SENSE_CAPS.signedIngest`) carry the same name.
pub const CAP_SIGNED_INGEST: &str = "signed_ingest";

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

/// Panel A7: a report `ts` more than this ahead of the panel clock is refused (`future`).
pub const PANEL_FUTURE_S: i64 = 300;

/// Sense Remote (G3-6): `next_ts_reserved`, but a floor (last `ts` or stored reservation) the
/// panel can never have accepted (beyond its `future` limit, by the panel clock from the last
/// answer) is dropped: after a clock that ran ahead is corrected, reports resume at once
/// instead of after the clock catches up. Without a known panel clock nothing changes (a clock
/// set back must not lower `ts`). The panel's own replay check still protects.
pub fn next_ts_checked(
    last: Option<i64>,
    reserved: Option<i64>,
    now_s: i64,
    server_offset_s: Option<i64>,
) -> (i64, Option<i64>) {
    if let Some(offset) = server_offset_s {
        let limit = now_s.saturating_add(offset).saturating_add(PANEL_FUTURE_S);
        if last.or(reserved).is_some_and(|floor| floor > limit) {
            return (now_s, Some(now_s.saturating_add(RESERVE_S)));
        }
    }
    next_ts_reserved(last, reserved, now_s)
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

/// Sense Remote (S4-4): the bytes of report v2. `conn_count`: the number of `conns` in the
/// heartbeat body (0 when the body has none). `None` like `signed_bytes`.
pub fn signed_bytes_v2(
    id: &str,
    uuid: &str,
    ts: i64,
    sense: &Value,
    conn_count: usize,
) -> Option<Vec<u8>> {
    let sense = sense.as_object()?;
    sense.get(KEY_APPLIED_SEQ)?;
    let mut object = Map::new();
    object.insert("id".to_owned(), json!(id));
    object.insert("uuid".to_owned(), json!(uuid));
    object.insert("ts".to_owned(), json!(ts));
    for field in SIGNED_FIELDS_V2 {
        if let Some(value) = sense.get(field) {
            object.insert(field.to_owned(), value.clone());
        }
    }
    object.insert("conn_count".to_owned(), json!(conn_count));
    let mut bytes = PREFIX_V2.to_vec();
    bytes.extend_from_slice(super::report::canonical_json(&Value::Object(object)).as_bytes());
    Some(bytes)
}

/// Sense Remote (S4-4): the bytes of the signed sysinfo: the whole extension except `report`
/// (unknown fields included). `None` when `sense` is not an object.
pub fn sysinfo_signed_bytes(id: &str, uuid: &str, ts: i64, sense: &Value) -> Option<Vec<u8>> {
    let mut sense = sense.as_object()?.clone();
    sense.remove(KEY_REPORT);
    let object = json!({ "id": id, "uuid": uuid, "ts": ts, "sense": Value::Object(sense) });
    let mut bytes = SYSINFO_PREFIX.to_vec();
    bytes.extend_from_slice(super::report::canonical_json(&object).as_bytes());
    Some(bytes)
}

/// Detached signature, unpadded base64url; `None` without a usable 64-byte secret key.
fn detached(bytes: &[u8], secret_key: &[u8]) -> Option<String> {
    let secret_key = sign::SecretKey::from_slice(secret_key)?;
    sodiumoxide::init().ok()?;
    Some(URL_SAFE_NO_PAD.encode(sign::sign_detached(bytes, &secret_key).to_bytes()))
}

/// Adds `signed_ingest` to `caps` (creates `caps` when missing).
fn add_signed_ingest_cap(sense: &mut Map<String, Value>) {
    let caps = sense
        .entry(KEY_CAPS.to_owned())
        .or_insert_with(|| Value::Array(Vec::new()));
    if let Some(caps) = caps.as_array_mut() {
        if !caps.iter().any(|cap| cap == CAP_SIGNED_INGEST) {
            caps.push(json!(CAP_SIGNED_INGEST));
        }
    }
}

/// Sense Remote (S4-4): report v2. Adds `signed_ingest` to `caps`, signs (health, macOS
/// permissions and `conn_count` included) and adds `sense.report = { v: 2, ts, sig }`. Returns
/// false and changes nothing without a usable key or without `applied_seq`. Call it after every
/// other change to the signed fields.
pub fn sign_into_v2(
    sense: &mut Value,
    id: &str,
    uuid: &str,
    ts: i64,
    conn_count: usize,
    secret_key: &[u8],
) -> bool {
    if sign::SecretKey::from_slice(secret_key).is_none() {
        return false;
    }
    let Some(object) = sense.as_object_mut() else {
        return false;
    };
    if !object.contains_key(KEY_APPLIED_SEQ) {
        return false;
    }
    add_signed_ingest_cap(object);
    let signature = signed_bytes_v2(id, uuid, ts, sense, conn_count)
        .and_then(|bytes| detached(&bytes, secret_key));
    let (Some(signature), Some(object)) = (signature, sense.as_object_mut()) else {
        return false;
    };
    object.insert(KEY_REPORT.to_owned(), json!({ "v": 2, "ts": ts, "sig": signature }));
    true
}

/// Sense Remote (S4-4): signs the sysinfo extension (`sense.report = { ts, sig }`, no `v`). Call
/// it after every other change to `sense`. Returns false and adds nothing without a usable key.
pub fn sign_sysinfo_into(
    sense: &mut Value,
    id: &str,
    uuid: &str,
    ts: i64,
    secret_key: &[u8],
) -> bool {
    let Some(signature) =
        sysinfo_signed_bytes(id, uuid, ts, sense).and_then(|bytes| detached(&bytes, secret_key))
    else {
        return false;
    };
    let Some(object) = sense.as_object_mut() else {
        return false;
    };
    object.insert(KEY_REPORT.to_owned(), json!({ "ts": ts, "sig": signature }));
    true
}

/// Sense Remote (S4-4): whether the heartbeat answer's `sense_panel_caps` asks for signed
/// ingest. Missing caps (older panel, `{}` answer) -> no.
pub fn panel_takes_signed_ingest(caps: Option<&[String]>) -> bool {
    caps.is_some_and(|caps| caps.iter().any(|cap| cap == CAP_SIGNED_INGEST))
}

/// Stored panel capability (LocalConfig of the process that sends the heartbeat).
const OPTION_PANEL_SIGNED_INGEST: &str = "sense-panel-signed-ingest";
/// 0 = not read yet, 1 = off, 2 = on.
static PANEL_SIGNED_INGEST: AtomicU8 = AtomicU8::new(0);

/// Sense Remote (S4-4): the capability of the last parsed heartbeat answer. Stored when it
/// changes, so the heartbeat and sysinfo right after a restart are signed the same way (a v1
/// report would make the panel drop `signed_ingest` from this computer until the next v2).
pub fn set_panel_caps(caps: Option<&[String]>) {
    let on = panel_takes_signed_ingest(caps);
    if panel_signed_ingest() != on {
        hbb_common::config::LocalConfig::set_option(
            OPTION_PANEL_SIGNED_INGEST.to_owned(),
            if on { "Y" } else { "" }.to_owned(),
        );
        hbb_common::log::info!(
            "Sense Remote: panel signed ingest {}",
            if on { "on" } else { "off" }
        );
    }
    PANEL_SIGNED_INGEST.store(if on { 2 } else { 1 }, Ordering::Relaxed);
}

/// Sense Remote (S4-4): sign report v2 and the sysinfo extension (capability of the last answer,
/// or the stored one before the first answer of this run).
pub fn panel_signed_ingest() -> bool {
    match PANEL_SIGNED_INGEST.load(Ordering::Relaxed) {
        0 => {
            let on =
                hbb_common::config::LocalConfig::get_option(OPTION_PANEL_SIGNED_INGEST) == "Y";
            PANEL_SIGNED_INGEST.store(if on { 2 } else { 1 }, Ordering::Relaxed);
            on
        }
        state => state == 2,
    }
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
    fn a_reservation_from_a_clock_that_ran_ahead_is_dropped() {
        let year = 365 * 24 * 3_600;
        // Clock ran a year ahead: reservation stored at now + 1 year. The panel refused those
        // reports (`future`). Clock corrected; the last answer said panel = local.
        let reserved = Some(1_000 + year + RESERVE_S);
        assert_eq!(next_ts_checked(None, reserved, 1_000, Some(0)), (1_000, Some(1_060)));
        assert_eq!(next_ts_checked(Some(1_000 + year), reserved, 1_000, Some(0)), (1_000, Some(1_060)));
        // Within the panel's limit: unchanged (strictly increasing, no lowering).
        assert_eq!(next_ts_checked(Some(1_200), Some(1_260), 1_000, Some(0)), (1_201, None));
        // Panel clock unknown (no answer yet): unchanged, as `next_ts_reserved`.
        assert_eq!(next_ts_checked(None, reserved, 1_000, None), next_ts_reserved(None, reserved, 1_000));
        // Clock set back an hour, panel agrees with the old clock: keep increasing.
        assert_eq!(next_ts_checked(None, Some(1_121), 1_121 - 3_600, Some(3_600)), (1_122, Some(1_182)));
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

    // --- Sense Remote (S4-4): report v2 and signed sysinfo, shared vector signed-ingest-v1 ---

    const INGEST_VECTOR: &str = include_str!("testdata/signed-ingest-v1.json");

    fn ingest_vector() -> Value {
        serde_json::from_str(INGEST_VECTOR).expect("signed-ingest-v1.json is valid JSON")
    }

    /// What is signed for one vector case: report v2 of a heartbeat or the sysinfo extension.
    #[derive(Clone, Copy)]
    enum Kind {
        Heartbeat { conn_count: usize },
        Sysinfo,
    }

    fn ingest_bytes(kind: Kind, id: &str, uuid: &str, ts: i64, sense: &Value) -> Option<Vec<u8>> {
        match kind {
            Kind::Heartbeat { conn_count } => signed_bytes_v2(id, uuid, ts, sense, conn_count),
            Kind::Sysinfo => sysinfo_signed_bytes(id, uuid, ts, sense),
        }
    }

    /// The panel's `verifyDeviceReport` (v2) / `verifySysinfoReport`, written down from
    /// `packages/shared/src/device-report.ts` (main 1789600). A heartbeat report without `v: 2`
    /// is checked as v1 (its own prefix), a sysinfo report with `v` is refused.
    fn panel_verify_ingest(
        kind: Kind,
        body: &Value,
        device_pk: &str,
        last_ts: Option<i64>,
        now_s: i64,
        future_skew_s: i64,
    ) -> &'static str {
        let bad = "bad_signature";
        let sense = &body["sense"];
        let Some(report) = sense.get(KEY_REPORT) else {
            return "unsigned";
        };
        let Some(report) = report.as_object() else {
            return bad;
        };
        let v2 = match (kind, report.get("v")) {
            (_, None) => false,
            (Kind::Heartbeat { .. }, Some(v)) if v == 2 => true,
            _ => return bad,
        };
        if report.len() != 2 + usize::from(v2) {
            return bad;
        }
        let (Some(ts), Some(sig)) = (
            report.get("ts").and_then(Value::as_i64).filter(|ts| *ts > 0),
            report.get("sig").and_then(Value::as_str),
        ) else {
            return bad;
        };
        let Some(signature) = URL_SAFE_NO_PAD
            .decode(sig)
            .ok()
            .and_then(|bytes| sign::Signature::from_bytes(&bytes).ok())
        else {
            return bad;
        };
        let public_key = URL_SAFE_NO_PAD
            .decode(device_pk)
            .ok()
            .and_then(|bytes| sign::PublicKey::from_slice(&bytes))
            .expect("vector device_pk");
        let id = body["id"].as_str().unwrap();
        let uuid = body["uuid"].as_str().unwrap();
        let bytes = match kind {
            Kind::Heartbeat { .. } if !v2 => signed_bytes(id, uuid, ts, sense),
            _ => ingest_bytes(kind, id, uuid, ts, sense),
        };
        let Some(bytes) = bytes else {
            return bad;
        };
        sodiumoxide::init().unwrap();
        if !sign::verify_detached(&signature, &bytes, &public_key) {
            return bad;
        }
        if ts > now_s + future_skew_s {
            return "future";
        }
        if last_ts.is_some_and(|last| ts <= last) {
            return "replayed";
        }
        "ok"
    }

    #[test]
    fn ingest_vector_constants_match() {
        let v = ingest_vector();
        assert_eq!(v["v"], 1);
        assert_eq!(v["hb_v2_prefix"].as_str().unwrap().as_bytes(), PREFIX_V2);
        assert_eq!(v["sysinfo_prefix"].as_str().unwrap().as_bytes(), SYSINFO_PREFIX);
        let theirs: Vec<&str> = v["hb_v2_signed_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f.as_str().unwrap())
            .collect();
        assert_eq!(theirs, SIGNED_FIELDS_V2);
        assert_eq!(v["future_skew_s"].as_i64(), Some(PANEL_FUTURE_S));
    }

    /// Every case gives the panel's result, and the client's bytes equal the panel's signed text
    /// byte for byte (floats, escapes, Turkish text, unknown sysinfo fields included).
    #[test]
    fn ingest_vector_cases_match_and_signed_text_is_byte_identical() {
        let v = ingest_vector();
        let skew = v["future_skew_s"].as_i64().unwrap();
        let mut failures = Vec::new();
        let mut checked = (0, 0);
        for (list, body_key) in [("heartbeat_cases", "heartbeat"), ("sysinfo_cases", "sysinfo")] {
            for case in v[list].as_array().unwrap() {
                let name = case["name"].as_str().unwrap();
                let body = &case[body_key];
                let kind = if body_key == "heartbeat" {
                    Kind::Heartbeat {
                        conn_count: body["conn_count"].as_u64().unwrap() as usize,
                    }
                } else {
                    Kind::Sysinfo
                };
                let got = panel_verify_ingest(
                    kind,
                    body,
                    case["device_pk"].as_str().unwrap(),
                    case["last_report_ts"].as_i64(),
                    case["now_s"].as_i64().unwrap(),
                    skew,
                );
                let wanted = case["result"].as_str().unwrap();
                if got != wanted {
                    failures.push(format!("{name}: expected {wanted}, got {got}"));
                }
                checked.0 += 1;
                if let Some(text) = case.get("signed_text").and_then(Value::as_str) {
                    checked.1 += 1;
                    let ours = ingest_bytes(
                        kind,
                        body["id"].as_str().unwrap(),
                        body["uuid"].as_str().unwrap(),
                        body["sense"]["report"]["ts"].as_i64().unwrap(),
                        &body["sense"],
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
        }
        assert_eq!(checked, (17, 7), "vector signed-ingest-v1: 17 cases, 7 with signed_text");
        assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
    }

    #[test]
    fn report_v2_signs_health_connections_and_adds_the_cap() {
        let (pk, sk) = device_key();
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let mut sense = sense_sample();
        assert!(sign_into_v2(&mut sense, "123456789", "dGVzdC11dWlk", 1_800_000_000, 2, &sk.0));
        assert_eq!(sense["caps"], json!(["role_all", CAP_SIGNED_INGEST]));
        let report = sense["report"].as_object().unwrap();
        let keys: BTreeSet<&str> = report.keys().map(String::as_str).collect();
        assert_eq!(keys, BTreeSet::from(["sig", "ts", "v"]));
        assert_eq!(report["v"], 2);
        let body = json!({ "id": "123456789", "uuid": "dGVzdC11dWlk", "sense": sense });
        let check = |body: &Value, conn_count: usize| {
            let kind = Kind::Heartbeat { conn_count };
            panel_verify_ingest(kind, body, &pk, None, 1_800_000_000, PANEL_FUTURE_S)
        };
        assert_eq!(check(&body, 2), "ok");
        // Connection count, health and the new cap are bound; role is not.
        assert_eq!(check(&body, 0), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["health"]["cpu_pct"] = json!(99.0);
        assert_eq!(check(&forged, 2), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["health"].as_object_mut().unwrap().remove("cpu_pct");
        assert_eq!(check(&forged, 2), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["caps"] = json!(["role_all"]);
        assert_eq!(check(&forged, 2), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["mac_permissions"] =
            json!({ "screen_recording": true, "accessibility": true, "input_monitoring": true });
        assert_eq!(check(&forged, 2), "bad_signature");
        let mut other = body.clone();
        other["sense"]["role"] = json!("host");
        other["sense"]["loc_rev"] = json!(3);
        assert_eq!(check(&other, 2), "ok");
        // Signing twice does not add the cap twice.
        let mut again = sense_sample();
        again["caps"] = json!(["role_all", CAP_SIGNED_INGEST]);
        assert!(sign_into_v2(&mut again, "1", "u", 1, 0, &sk.0));
        assert_eq!(again["caps"], json!(["role_all", CAP_SIGNED_INGEST]));
        // No caps yet: created with the cap.
        let mut bare = json!({ "applied_seq": 0 });
        assert!(sign_into_v2(&mut bare, "1", "u", 1, 0, &sk.0));
        assert_eq!(bare["caps"], json!([CAP_SIGNED_INGEST]));
    }

    #[test]
    fn report_v2_changes_nothing_without_key_or_applied_seq() {
        let (_, sk) = device_key();
        let mut sense = sense_sample();
        sense.as_object_mut().unwrap().remove("applied_seq");
        let before = sense.clone();
        assert!(!sign_into_v2(&mut sense, "1", "u", 1, 0, &sk.0));
        assert_eq!(sense, before);
        let mut sense = sense_sample();
        let before = sense.clone();
        assert!(!sign_into_v2(&mut sense, "1", "u", 1, 0, &[]));
        assert!(!sign_into_v2(&mut sense, "1", "u", 1, 0, &sk.0[..32]));
        assert_eq!(sense, before);
        assert_eq!(signed_bytes_v2("1", "u", 1, &json!([]), 0), None);
        // The v1 and v2 bytes of the same fields never collide.
        let sense = sense_sample();
        assert_ne!(signed_bytes("1", "u", 1, &sense), signed_bytes_v2("1", "u", 1, &sense, 0));
    }

    #[test]
    fn signed_sysinfo_passes_the_panel_check() {
        let (pk, sk) = device_key();
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let mut sense = json!({
            "v": 1, "role": "host", "app_version": 4, "platform": "windows-x64",
            "displays": [{ "index": 0, "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.25 }],
            "network": [{ "name": "Ethernet", "kind": "ethernet", "ipv4": ["192.168.1.20"] }],
            "inventory": { "at": 1_800_000_000, "serial": "ABC-123" },
        });
        assert!(sign_sysinfo_into(&mut sense, "123456789", "dGVzdC11dWlk", 1_800_000_000, &sk.0));
        let report = sense["report"].as_object().unwrap();
        let keys: BTreeSet<&str> = report.keys().map(String::as_str).collect();
        assert_eq!(keys, BTreeSet::from(["sig", "ts"]));
        let body = json!({ "id": "123456789", "uuid": "dGVzdC11dWlk", "sense": sense });
        let check = |body: &Value| {
            panel_verify_ingest(Kind::Sysinfo, body, &pk, None, 1_800_000_000, PANEL_FUTURE_S)
        };
        assert_eq!(check(&body), "ok");
        // Every field is bound, unknown ones too.
        let mut forged = body.clone();
        forged["sense"]["network"][0]["ipv4"] = json!(["10.0.0.9"]);
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["inventory"]["serial"] = json!("XYZ");
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = body.clone();
        forged["sense"]["extra"] = json!(1);
        assert_eq!(check(&forged), "bad_signature");
        let mut forged = body.clone();
        forged["uuid"] = json!("b3RoZXI");
        assert_eq!(check(&forged), "bad_signature");
        // No usable key: nothing added.
        let mut unsigned = json!({ "v": 1 });
        assert!(!sign_sysinfo_into(&mut unsigned, "1", "u", 1, &[]));
        assert_eq!(unsigned, json!({ "v": 1 }));
        assert_eq!(sysinfo_signed_bytes("1", "u", 1, &json!(null)), None);
        // Re-signing replaces the old report instead of signing it.
        let mut resigned = body["sense"].clone();
        assert!(sign_sysinfo_into(&mut resigned, "123456789", "dGVzdC11dWlk", 1_800_000_001, &sk.0));
        let body = json!({ "id": "123456789", "uuid": "dGVzdC11dWlk", "sense": resigned });
        assert_eq!(check(&body), "ok");
    }

    #[test]
    fn signed_ingest_only_when_the_panel_asks() {
        assert!(!panel_takes_signed_ingest(None));
        assert!(!panel_takes_signed_ingest(Some(&[][..])));
        assert!(!panel_takes_signed_ingest(Some(&["health_v2".to_owned()][..])));
        assert!(panel_takes_signed_ingest(Some(
            &["health_v2".to_owned(), CAP_SIGNED_INGEST.to_owned()][..]
        )));
    }
}
