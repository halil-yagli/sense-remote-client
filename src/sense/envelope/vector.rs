// Sense Remote: the panel and the client must agree on the same bytes. `envelope-v1.json` is made
// by the panel (`packages/shared/scripts/make-envelope-vector.ts`) with keys that existed only in
// memory; it holds public data only. Copied verbatim: update both repositories in the same change.

use super::*;
use crate::sense::envelope_keys::{key_id, parse_keys, TrustedKey};
use hbb_common::base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use std::collections::BTreeSet;

const VECTOR: &str = include_str!("../testdata/envelope-v1.json");

fn vector() -> Value {
    serde_json::from_str(VECTOR).expect("envelope-v1.json is valid JSON")
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
    // Same format as `SENSE_ENVELOPE_KEYS`: this also proves both sides derive `k` alike.
    parse_keys(&entries.join(",")).expect("vector keys parse as SENSE_ENVELOPE_KEYS")
}

#[test]
fn vector_constants_match() {
    let v = vector();
    assert_eq!(v["v"], 1);
    assert_eq!(str_of(&v, "prefix").as_bytes(), SIGNING_PREFIX);
    assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
    let keys = vector_keys(&v);
    assert_eq!(keys.len(), 2);
    for key in &keys {
        assert_eq!(key.k, key_id(&key.public_key));
        assert_eq!(URL_SAFE_NO_PAD.encode(key.public_key).len(), 43);
    }
}

#[test]
fn vector_allow_list_matches() {
    let v = vector();
    let rules = v["allowed_options"].as_object().unwrap();
    let theirs: BTreeSet<&str> = rules.keys().map(String::as_str).collect();
    let ours: BTreeSet<&str> = ALLOWED_OPTIONS.iter().map(|(k, _)| *k).collect();
    assert_eq!(theirs, ours);
    for (key, rule) in ALLOWED_OPTIONS {
        let theirs = &rules[key];
        match rule {
            OptionRule::Empty => {
                assert_eq!(theirs["kind"], "enum", "{key}");
                assert_eq!(theirs["values"], serde_json::json!([""]), "{key}");
            }
            OptionRule::YesNo => {
                assert_eq!(theirs["kind"], "enum", "{key}");
                assert_eq!(theirs["values"], serde_json::json!(["Y", "N"]), "{key}");
            }
            OptionRule::Minutes => {
                assert_eq!(theirs["kind"], "int_or_empty", "{key}");
                assert_eq!(theirs["min"].as_u64(), Some(MIN_MINUTES as u64), "{key}");
                assert_eq!(theirs["max"].as_u64(), Some(MAX_MINUTES as u64), "{key}");
            }
        }
    }
}

#[test]
fn vector_cases_match_result_client() {
    let v = vector();
    let keys = vector_keys(&v);
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 15, "the plan asks for at least 15 cases");
    let mut failures = Vec::new();
    for case in cases {
        let name = str_of(case, "name");
        let e = &case["expect"];
        let expect = Expect {
            iss: str_of(e, "iss"),
            did: str_of(e, "did"),
            duuid: str_of(e, "duuid"),
            now_s: e["now_s"].as_i64().unwrap(),
            last_seq: e["last_seq"].as_u64().unwrap(),
        };
        let wanted = str_of(case, "result_client");
        let got = verify(&case["envelope"], &keys, &expect);
        let got_name = match &got {
            Ok(_) => "ok",
            Err(rejection) => rejection.reason.as_str(),
        };
        if got_name != wanted {
            failures.push(format!("{name}: expected {wanted}, got {got_name}"));
            continue;
        }
        let Ok(verified) = got else { continue };
        if let Some(seq) = case["seq"].as_u64() {
            assert_eq!(verified.seq, seq, "{name}");
        }
        if let Some(options) = case.get("config_options") {
            let options: BTreeMap<String, String> =
                serde_json::from_value(options.clone()).unwrap();
            assert_eq!(verified.body.config_options, options, "{name}");
        }
        let role = verified.body.sense_role.map(|role| match role {
            PanelRole::Host => "host",
            PanelRole::Controller => "controller",
            PanelRole::HostController => "host_controller",
        });
        assert_eq!(role, case.get("sense_role").and_then(Value::as_str), "{name}");
    }
    assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
}
