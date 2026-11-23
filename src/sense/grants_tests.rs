// Sense Remote: grants verification against the panel's shared vector (`grants-v1.json`, made by
// `packages/shared/scripts/make-grants-vector.ts` with keys that existed only in memory; public
// data only). Copied verbatim: update both repositories in the same change.

use super::*;
use crate::sense::envelope_keys::{key_id, parse_keys};

const VECTOR: &str = include_str!("testdata/grants-v1.json");

fn vector() -> Value {
    serde_json::from_str(VECTOR).expect("grants-v1.json is valid JSON")
}

fn str_of<'a>(value: &'a Value, field: &str) -> &'a str {
    value[field]
        .as_str()
        .unwrap_or_else(|| panic!("{field} is a string"))
}

fn vector_keys(v: &Value) -> Vec<TrustedKey> {
    let entries: Vec<String> = v["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|key| format!("{}={}", str_of(key, "k"), str_of(key, "public_key")))
        .collect();
    parse_keys(&entries.join(",")).expect("vector keys parse as SENSE_ENVELOPE_KEYS")
}

fn expect_of(case: &Value) -> Expect<'_> {
    let e = &case["expect"];
    Expect {
        iss: str_of(e, "iss"),
        did: str_of(e, "did"),
        duuid: str_of(e, "duuid"),
        email: str_of(e, "email"),
        now_s: e["now_s"].as_i64().unwrap(),
        last_rev: e["last_rev"].as_u64().unwrap(),
    }
}

fn case<'a>(v: &'a Value, name: &str) -> &'a Value {
    v["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == name)
        .unwrap_or_else(|| panic!("case {name}"))
}

#[test]
fn vector_constants_match() {
    let v = vector();
    assert_eq!(v["v"], 1);
    assert_eq!(str_of(&v, "prefix").as_bytes(), SIGNING_PREFIX);
    assert_ne!(SIGNING_PREFIX, crate::sense::envelope::SIGNING_PREFIX);
    assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
    assert_eq!(v["max_lifetime_s"].as_i64(), Some(MAX_LIFETIME_S));
    let catalogue: Vec<&str> = v["app_permissions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap())
        .collect();
    assert_eq!(catalogue, APP_PERMISSIONS);
    let keys = vector_keys(&v);
    assert_eq!(keys.len(), 2);
    for key in &keys {
        assert_eq!(key.k, key_id(&key.public_key));
    }
}

#[test]
fn vector_cases_match() {
    let v = vector();
    let keys = vector_keys(&v);
    let cases = v["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 29);
    let mut failures = Vec::new();
    for case in cases {
        let name = str_of(case, "name");
        let wanted = str_of(case, "result");
        let got = verify(&case["envelope"], &keys, &expect_of(case));
        let got_name = match &got {
            Ok(_) => "ok",
            Err(reason) => reason.as_str(),
        };
        if got_name != wanted {
            failures.push(format!("{name}: expected {wanted}, got {got_name}"));
            continue;
        }
        if let Ok(grants) = got {
            let perms: Vec<String> = serde_json::from_value(case["perms"].clone()).unwrap();
            assert_eq!(grants.perms, perms, "{name}");
            assert_eq!(Some(grants.rev), case["rev"].as_u64(), "{name}");
            assert!(grants.exp > grants.iat, "{name}");
        }
    }
    assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
}

#[test]
fn no_trusted_key_refuses_everything() {
    let v = vector();
    let ok = case(&v, "ok_technical");
    assert_eq!(
        verify(&ok["envelope"], &[], &expect_of(ok)),
        Err(Reason::UnknownKey)
    );
}

#[test]
fn a_strategy_signature_is_not_grants() {
    // The same payload signed with the strategy prefix fails, whatever else is right.
    let v = vector();
    let keys = vector_keys(&v);
    let c = case(&v, "bad_signature_envelope_prefix");
    assert_eq!(verify(&c["envelope"], &keys, &expect_of(c)), Err(Reason::BadSignature));
}

#[test]
fn rev_never_goes_back_but_may_stay() {
    let v = vector();
    let keys = vector_keys(&v);
    let ok = case(&v, "ok_technical");
    let mut expect = expect_of(ok);
    for (last_rev, result) in [(0, true), (7, true), (8, false)] {
        expect.last_rev = last_rev;
        let got = verify(&ok["envelope"], &keys, &expect);
        assert_eq!(got.is_ok(), result, "last_rev {last_rev}");
        if !result {
            assert_eq!(got, Err(Reason::Replayed));
        }
    }
}

#[test]
fn answer_is_closed_unless_ok() {
    let grants = Grants {
        perms: vec!["connect".to_owned(), "control".to_owned()],
        email: "calisan@example.test".to_owned(),
        rev: 7,
        iat: 1,
        exp: 2,
    };
    let ok = answer(Some(Ok(&grants)), None);
    assert_eq!(ok["state"], "ok");
    assert_eq!(ok["perms"], json!(["connect", "control"]));
    assert_eq!(ok["email"], "calisan@example.test");
    assert_eq!(ok["rev"], 7);
    // A refused newer envelope does not close a stored valid one.
    assert_eq!(answer(Some(Ok(&grants)), Some(Reason::Replayed))["state"], "ok");
    for (checked, rejected, state) in [
        (None, None, "missing"),
        (None, Some(Reason::Expired), "expired"),
        (None, Some(Reason::BadSignature), "invalid"),
        (Some(Err(Reason::Expired)), None, "expired"),
        (Some(Err(Reason::WrongUser)), None, "invalid"),
        (Some(Err(Reason::UnknownKey)), None, "invalid"),
    ] {
        let value = answer(checked, rejected);
        assert_eq!(value["state"], state);
        assert_eq!(value["perms"], json!([]), "{state}");
        assert_eq!(value["email"], "", "{state}");
        assert_eq!(value["rev"], 0, "{state}");
    }
}

#[test]
fn panel_answers() {
    let envelope = json!({ "k": "a", "p": "b", "s": "c" });
    let body = json!({ "grants": envelope }).to_string();
    assert_eq!(outcome(200, &body), Outcome::Envelope(envelope));
    assert_eq!(outcome(200, "{}"), Outcome::Retry);
    assert_eq!(outcome(200, "not json"), Outcome::Retry);
    assert_eq!(outcome(200, r#"{"grants":{},"x":1}"#), Outcome::Retry);
    assert_eq!(outcome(304, ""), Outcome::NotModified);
    assert_eq!(outcome(401, r#"{"error":"token_invalid"}"#), Outcome::Revoked);
    assert_eq!(outcome(403, r#"{"error":"token_purpose"}"#), Outcome::Revoked);
    for status in [409, 429, 500, 0] {
        assert_eq!(outcome(status, ""), Outcome::Retry, "{status}");
    }
}

#[test]
fn etag_is_the_panels_form() {
    assert_eq!(etag(7, 1800028800), "\"7-1800028800\"");
}

#[test]
fn session_email_reads_email_then_name() {
    assert_eq!(
        session_email(r#"{"name":"a@example.test","email":"b@example.test"}"#).as_deref(),
        Some("b@example.test")
    );
    assert_eq!(
        session_email(r#"{"name":"a@example.test","email":""}"#).as_deref(),
        Some("a@example.test")
    );
    assert_eq!(session_email(r#"{"name":" "}"#), None);
    assert_eq!(session_email(""), None);
}

#[test]
fn email_check_follows_zod() {
    for good in ["calisan@example.test", "a.b+c@sub.example.com", "x@a-b.io", "o'neil@ex.org"] {
        assert!(is_email(good), "{good}");
    }
    for bad in [
        "",
        "plain",
        "@example.test",
        ".a@example.test",
        "a..b@example.test",
        "a.@example.test",
        "a@example",
        "a@-x.test",
        "a@example.t",
        "a@example.t3st",
        "a b@example.test",
    ] {
        assert!(!is_email(bad), "{bad}");
    }
}
