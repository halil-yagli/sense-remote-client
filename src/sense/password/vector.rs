//! Sense Remote (permanent password plan §3.11): the shared test vector made by the panel
//! (`packages/shared/test-vectors/password-v1.json`, copied byte for byte; both copies have the
//! same SHA-256). Every `grant` and `rule` case must give the panel's `expect`; for `request`
//! and `ack` this client is the signer: its schema (steps 1–5) must agree, and the valid cases
//! must be reproduced byte for byte by `sign_request` / `sign_ack` with the vector's TEST device
//! key (derived from a public label, like the panel's generator). `envelope` cases are the
//! envelope verifier's (`envelope/vector.rs`, `envelope-v1.json`).

use super::{
    ack::{sign_ack, PasswordAckPayload},
    grant::{self, open_signed, parse_canonical, GrantContext},
    pending::Pending,
    request::{sign_request, PasswordRequestPayload},
    rule,
};
use crate::sense::envelope_keys::TrustedKey;
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sha2::{Digest, Sha256},
    sodiumoxide::crypto::sign,
};
use serde_json::Value;
use std::time::Instant;

const VECTOR: &str = include_str!("../testdata/password-v1.json");
const DEVICE_LABEL: &str = "sense-remote/test-vector/password-v1/";

fn vector() -> Value {
    serde_json::from_str(VECTOR).expect("password-v1.json is JSON")
}

fn keys(list: &Value) -> Vec<TrustedKey> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|key| TrustedKey {
            k: key["k"].as_str().unwrap().to_owned(),
            public_key: URL_SAFE_NO_PAD
                .decode(key["public_key"].as_str().unwrap())
                .unwrap()
                .try_into()
                .unwrap(),
        })
        .collect()
}

fn s(value: &Value, field: &str) -> String {
    value[field].as_str().unwrap_or_else(|| panic!("{field}")).to_owned()
}

/// The vector's TEST device key: seed = SHA-256(label + name).
fn test_device_keypair(name: &str) -> (sign::PublicKey, sign::SecretKey) {
    let seed: [u8; 32] = Sha256::digest(format!("{DEVICE_LABEL}{name}").as_bytes()).into();
    sign::keypair_from_seed(&sign::Seed(seed))
}

fn test_device_secret(name: &str) -> sign::SecretKey {
    test_device_keypair(name).1
}

/// Steps 1–5 of a device-signed object, with the panel's registered device key.
fn device_schema<T>(blob: &Value, device_pk: &Value, prefix: &[u8], valid: fn(&T) -> bool) -> &'static str
where
    T: serde::de::DeserializeOwned + serde::Serialize,
{
    let keys = match device_pk.as_str().and_then(|pk| URL_SAFE_NO_PAD.decode(pk).ok()) {
        Some(raw) => {
            let public_key: [u8; 32] = raw.try_into().unwrap();
            vec![TrustedKey {
                k: crate::sense::envelope_keys::key_id(&public_key),
                public_key,
            }]
        }
        None => vec![],
    };
    match open_signed(blob, &keys, prefix) {
        Err(err) => err.as_str(),
        Ok(bytes) => match parse_canonical::<T>(&bytes) {
            Some(payload) if valid(&payload) => "ok",
            _ => "bad_payload",
        },
    }
}

const SCHEMA_REASONS: [&str; 4] = ["malformed", "unknown_key", "bad_signature", "bad_payload"];

#[test]
fn constants_match() {
    let v = vector();
    assert_eq!(v["v"], 1);
    assert_eq!(s(&v["prefixes"], "request").as_bytes(), super::PASSWORD_REQUEST_PREFIX);
    assert_eq!(s(&v["prefixes"], "grant").as_bytes(), super::PASSWORD_GRANT_PREFIX);
    assert_eq!(s(&v["prefixes"], "ack").as_bytes(), super::PASSWORD_ACK_PREFIX);
    assert_eq!(v["request_ttl_s"], super::PASSWORD_REQUEST_TTL_S);
    assert_eq!(v["grant_ttl_s"], super::PASSWORD_GRANT_TTL_S);
    assert_eq!(v["max_ttl_s"], grant::MAX_TTL_S);
    assert_eq!(v["clock_skew_before_s"], grant::CLOCK_SKEW_BEFORE_S);
    assert_eq!(v["clock_skew_after_s"], grant::CLOCK_SKEW_AFTER_S);
    assert_eq!(v["max_signed_p_chars"], super::MAX_PASSWORD_SIGNED_P_CHARS);
    let r = &v["rule"];
    assert_eq!(r["min_length"], rule::MIN_LENGTH);
    assert_eq!(r["max_length"], rule::MAX_LENGTH);
    assert_eq!(r["min_distinct"], rule::MIN_DISTINCT);
    assert_eq!(r["order"], serde_json::json!(rule::ORDER));
    assert_eq!(r["common"], serde_json::json!(rule::COMMON));
    // The test device keys are the ones the label gives.
    for (i, name) in ["device-1", "device-2"].iter().enumerate() {
        let public_key = test_device_keypair(name).0 .0;
        assert_eq!(URL_SAFE_NO_PAD.encode(public_key), s(&v["device_keys"][i], "public_key"));
        assert_eq!(crate::sense::envelope_keys::key_id(&public_key), s(&v["device_keys"][i], "k"));
    }
}

fn case_verdict(panel_keys: &[TrustedKey], case: &Value) -> Option<String> {
    let input = &case["input"];
    let verdict = match input["kind"].as_str().unwrap() {
        "grant" => {
            let ctx = GrantContext {
                iss: s(input, "iss"),
                rid: s(input, "rid"),
                duuid: s(input, "duuid"),
                now: input["now_s"].as_i64().unwrap(),
            };
            let now = Instant::now();
            let mut pending = Pending::default();
            if let Some(nonce) = input["pending_nonce"].as_str() {
                let bytes: [u8; 16] = URL_SAFE_NO_PAD.decode(nonce).unwrap().try_into().unwrap();
                assert_eq!(pending.begin_with(bytes, now), nonce);
            }
            match grant::verify_grant_value(&input["grant"], panel_keys, &ctx) {
                Err(err) => err.as_str(),
                Ok(payload) => match pending.matches(&payload.nonce, now) {
                    Ok(()) => "ok",
                    Err(err) => err.as_str(),
                },
            }
            .to_owned()
        }
        "rule" => match rule::check(&s(input, "candidate"), &s(input, "rid")) {
            Ok(()) => "ok".to_owned(),
            Err(code) => code.to_owned(),
        },
        "request" => {
            let schema = device_schema::<PasswordRequestPayload>(
                &input["request"],
                &input["device_pk"],
                super::PASSWORD_REQUEST_PREFIX,
                |p| sign_request(p, &test_device_secret("device-1").0).is_ok(),
            );
            schema_verdict(case, schema)
        }
        "ack" => {
            let schema = device_schema::<PasswordAckPayload>(
                &input["ack"],
                &input["device_pk"],
                super::PASSWORD_ACK_PREFIX,
                |p| sign_ack(p, &test_device_secret("device-1").0).is_ok(),
            );
            schema_verdict(case, schema)
        }
        "envelope" => return None,
        other => panic!("unknown kind {other}"),
    };
    Some(verdict)
}

/// Steps 1–5 only: a later reason means "passes 1–5" here.
fn schema_verdict(case: &Value, schema: &str) -> String {
    let expect = case["expect"].as_str().unwrap();
    if SCHEMA_REASONS.contains(&expect) {
        schema.to_owned()
    } else {
        assert_eq!(schema, "ok", "{}: steps 1–5 must pass", case["name"]);
        expect.to_owned()
    }
}

#[test]
fn every_case_matches() {
    let v = vector();
    let panel_keys = keys(&v["panel_keys"]);
    let mut checked = 0;
    for case in v["cases"].as_array().unwrap() {
        let Some(verdict) = case_verdict(&panel_keys, case) else {
            continue;
        };
        assert_eq!(verdict, s(case, "expect"), "{}", case["name"]);
        checked += 1;
    }
    assert!(checked > 200, "{checked}");
}

/// The client is the signer of requests and acks: the valid cases are reproduced exactly
/// (Ed25519 is deterministic, so `s` too).
#[test]
fn signers_reproduce_valid_cases() {
    let v = vector();
    let device_1 = s(&v["device_keys"][0], "k");
    let secret = test_device_secret("device-1");
    let mut reproduced = 0;
    for case in v["cases"].as_array().unwrap() {
        let input = &case["input"];
        if case["expect"] != "ok" {
            continue;
        }
        let (blob, signed) = match input["kind"].as_str().unwrap() {
            "request" => {
                let blob = &input["request"];
                let bytes = URL_SAFE_NO_PAD.decode(s(blob, "p")).unwrap();
                let payload: PasswordRequestPayload = parse_canonical(&bytes).unwrap();
                (blob, sign_request(&payload, &secret.0))
            }
            "ack" => {
                let blob = &input["ack"];
                let bytes = URL_SAFE_NO_PAD.decode(s(blob, "p")).unwrap();
                let payload: PasswordAckPayload = parse_canonical(&bytes).unwrap();
                (blob, sign_ack(&payload, &secret.0))
            }
            _ => continue,
        };
        if s(blob, "k") != device_1 {
            continue;
        }
        let signed: Value = serde_json::from_str(&signed.unwrap()).unwrap();
        assert_eq!(&signed, blob, "{}", case["name"]);
        reproduced += 1;
    }
    assert!(reproduced >= 2, "{reproduced}");
}

/// `request_ok` built from scratch (not parsed back) gives the same bytes.
#[test]
fn request_ok_from_fields() {
    let v = vector();
    let case = v["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "request_ok")
        .unwrap();
    let payload = PasswordRequestPayload::new(
        "123456789",
        "dGVzdC11dWlk",
        "c2Vuc2UtdGVzdC1ub25jZQ",
        "host",
        "windows-x64",
        3,
        1_800_000_000,
    );
    let signed: Value =
        serde_json::from_str(&sign_request(&payload, &test_device_secret("device-1").0).unwrap())
            .unwrap();
    assert_eq!(signed, case["input"]["request"]);
}

/// `ack_ok` from the grant it acknowledges.
#[test]
fn ack_ok_from_grant() {
    let v = vector();
    let find = |name: &str| {
        v["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == name)
            .unwrap()
            .clone()
    };
    let grant_case = find("grant_ok");
    let input = &grant_case["input"];
    let ctx = GrantContext {
        iss: s(input, "iss"),
        rid: s(input, "rid"),
        duuid: s(input, "duuid"),
        now: input["now_s"].as_i64().unwrap(),
    };
    let grant = grant::verify_grant_value(&input["grant"], &keys(&v["panel_keys"]), &ctx).unwrap();
    let ack_case = find("ack_ok");
    let at = {
        let bytes = URL_SAFE_NO_PAD.decode(s(&ack_case["input"]["ack"], "p")).unwrap();
        parse_canonical::<PasswordAckPayload>(&bytes).unwrap().at
    };
    let ack = PasswordAckPayload::for_grant(&grant, true, at);
    let signed: Value =
        serde_json::from_str(&sign_ack(&ack, &test_device_secret("device-1").0).unwrap()).unwrap();
    assert_eq!(signed, ack_case["input"]["ack"]);
}

/// Steps 1–10 together, as the privileged process's `Set` runs them.
#[test]
fn check_for_set_runs_the_whole_order() {
    let v = vector();
    let panel_keys = keys(&v["panel_keys"]);
    let grant_case = v["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "grant_ok")
        .unwrap();
    let input = &grant_case["input"];
    let grant_json = input["grant"].to_string();
    let ctx = GrantContext {
        iss: s(input, "iss"),
        rid: s(input, "rid"),
        duuid: s(input, "duuid"),
        now: input["now_s"].as_i64().unwrap(),
    };
    let now = Instant::now();
    let good = super::SensePasswordSecret::new("Mavi-Kapi_47!tuz".to_owned());
    let weak = super::SensePasswordSecret::new("aaaaaaaaaaaa".to_owned());
    let check = |pending: &mut Pending, password: &super::SensePasswordSecret, ctx: &GrantContext| {
        grant::check_for_set(&grant_json, password, &panel_keys, ctx, pending, now)
    };

    // No pending nonce.
    let mut pending = Pending::default();
    assert_eq!(check(&mut pending, &good, &ctx), Err("no_pending".to_owned()));

    // Weak password: refused, the grant is not burnt.
    pending.begin_with(*b"sense-test-nonce", now);
    assert_eq!(check(&mut pending, &weak, &ctx), Err("weak_password:repeated".to_owned()));
    let payload = check(&mut pending, &good, &ctx).unwrap();
    assert_eq!(payload.gid, "pwg_VGVzdEdyYW50MDAwMDAx");
    // Single use.
    assert_eq!(check(&mut pending, &good, &ctx), Err("no_pending".to_owned()));

    // A grant for another computer counts as a failed check; five drop the nonce.
    pending.begin_with(*b"sense-test-nonce", now);
    let other = GrantContext {
        rid: "987654321".to_owned(),
        ..ctx.clone()
    };
    for _ in 0..super::pending::MAX_FAILED_CHECKS {
        assert_eq!(
            check(&mut pending, &good, &other),
            Err("grant_invalid:wrong_device".to_owned())
        );
    }
    assert_eq!(check(&mut pending, &good, &ctx), Err("no_pending".to_owned()));

    // Another pending nonce.
    pending.begin_with(*b"other-test-nonce", now);
    assert_eq!(check(&mut pending, &good, &ctx), Err("nonce_mismatch".to_owned()));
}
