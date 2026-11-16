// Sense Remote: envelope verification tests. Keys are generated at run time; no private key is
// stored in the repository.

use super::*;
use crate::sense::envelope_keys::{key_id, TrustedKey};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::crypto::sign,
};
use serde_json::json;

const ISS: &str = "remote.snsdpt.com";
const DID: &str = "123456789";
const DUUID: &str = "dGVzdC11dWlk";
const NOW: i64 = 1_800_000_000;

struct Signer {
    sk: sign::SecretKey,
    trusted: TrustedKey,
}

fn signer() -> Signer {
    assert!(sodium_ready());
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
    fn keys(&self) -> Vec<TrustedKey> {
        vec![self.trusted.clone()]
    }

    fn sign_bytes(&self, payload: &[u8]) -> Value {
        let mut data = SIGNING_PREFIX.to_vec();
        data.extend_from_slice(payload);
        // Combined mode = signature (64 bytes) ‖ message.
        let signature = &sign::sign(&data, &self.sk)[..64];
        json!({
            "k": self.trusted.k,
            "p": URL_SAFE_NO_PAD.encode(payload),
            "s": URL_SAFE_NO_PAD.encode(signature),
        })
    }

    fn sign(&self, payload: &Value) -> Value {
        self.sign_bytes(&serde_json::to_vec(payload).unwrap())
    }
}

fn full_set() -> Value {
    json!({
        "access-mode": "",
        "enable-keyboard": "Y",
        "enable-clipboard": "Y",
        "enable-file-transfer": "Y",
        "enable-audio": "Y",
        "enable-remote-restart": "Y",
        "enable-record-session": "Y",
        "enable-block-input": "Y",
        "enable-privacy-mode": "Y",
        "enable-terminal": "N",
        "enable-tunnel": "N",
        "enable-camera": "N",
        "enable-remote-printer": "N",
        "allow-remove-wallpaper": "N",
        "allow-auto-disconnect": "N",
        "auto-disconnect-timeout": "",
    })
}

fn strategy(seq: u64) -> Value {
    json!({
        "v": 1,
        "typ": "strategy",
        "iss": ISS,
        "did": DID,
        "duuid": DUUID,
        "seq": seq,
        "nonce": "AAECAwQFBgcICQoLDA0ODw",
        "iat": NOW,
        "nbf": NOW,
        "exp": NOW + 7 * 24 * 3600,
        "body": { "config_options": full_set(), "revision": 3 },
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

fn reason(result: Result<Verified, Rejection>) -> Reason {
    result.expect_err("expected a rejection").reason
}

fn check(s: &Signer, payload: &Value) -> Result<Verified, Rejection> {
    verify(&s.sign(payload), &s.keys(), &expect(4))
}

#[test]
fn valid_full_set_is_accepted() {
    let s = signer();
    let verified = check(&s, &strategy(5)).unwrap();
    assert_eq!(verified.seq, 5);
    assert_eq!(verified.k, s.trusted.k);
    assert_eq!(verified.body.revision, 3);
    assert_eq!(verified.body.config_options.len(), ALLOWED_OPTIONS.len());
    assert_eq!(verified.body.sense_role, None);
    assert_eq!(verified.body.disconnect, None);
}

#[test]
fn valid_role_maps_to_sense_role() {
    let s = signer();
    for (role, expected) in [("host", SenseRole::Host), ("host_controller", SenseRole::Both)] {
        let mut payload = strategy(5);
        payload["body"]["sense_role"] = json!(role);
        let verified = check(&s, &payload).unwrap();
        assert_eq!(verified.body.sense_role.map(PanelRole::sense_role), Some(expected));
    }
    for role in ["controller", "both", "", "Host"] {
        let mut payload = strategy(5);
        payload["body"]["sense_role"] = json!(role);
        assert_eq!(reason(check(&s, &payload)), Reason::BadPayload, "{role}");
    }
}

#[test]
fn signature_must_cover_the_exact_bytes() {
    let s = signer();
    let mut env = s.sign(&strategy(5));
    let mut bytes = URL_SAFE_NO_PAD.decode(env["p"].as_str().unwrap()).unwrap();
    let last = bytes.len() - 2;
    bytes[last] ^= 1;
    env["p"] = json!(URL_SAFE_NO_PAD.encode(&bytes));
    let rejected = verify(&env, &s.keys(), &expect(4)).unwrap_err();
    assert_eq!(rejected.reason, Reason::BadSignature);
    assert_eq!(rejected.k.as_deref(), Some(s.trusted.k.as_str()));
    assert_eq!(rejected.seq, None);
    // Same payload signed without the domain prefix.
    let payload = serde_json::to_vec(&strategy(5)).unwrap();
    let signature = &sign::sign(&payload, &s.sk)[..64];
    let env = json!({
        "k": s.trusted.k,
        "p": URL_SAFE_NO_PAD.encode(&payload),
        "s": URL_SAFE_NO_PAD.encode(signature),
    });
    assert_eq!(reason(verify(&env, &s.keys(), &expect(4))), Reason::BadSignature);
}

#[test]
fn unknown_or_missing_keys_reject_everything() {
    let (s, other) = (signer(), signer());
    let env = s.sign(&strategy(5));
    assert_eq!(reason(verify(&env, &[], &expect(4))), Reason::UnknownKey);
    assert_eq!(reason(verify(&env, &other.keys(), &expect(4))), Reason::UnknownKey);
    // A trusted id with another key's bytes still fails the signature.
    let swapped = vec![TrustedKey {
        k: s.trusted.k.clone(),
        public_key: other.trusted.public_key,
    }];
    assert_eq!(reason(verify(&env, &swapped, &expect(4))), Reason::BadSignature);
}

#[test]
fn malformed_envelopes() {
    let s = signer();
    let good = s.sign(&strategy(5));
    let p = good["p"].as_str().unwrap().to_owned();
    let sig = good["s"].as_str().unwrap().to_owned();
    let k = s.trusted.k.clone();
    let cases = [
        json!(null),
        json!([]),
        json!("text"),
        json!({ "k": k, "p": p }),
        json!({ "k": k, "p": p, "s": sig, "x": 1 }),
        json!({ "k": k.to_uppercase(), "p": p, "s": sig }),
        json!({ "k": 1, "p": p, "s": sig }),
        json!({ "k": k, "p": "", "s": sig }),
        json!({ "k": k, "p": format!("{p}="), "s": sig }),
        json!({ "k": k, "p": format!("+{p}"), "s": sig }),
        json!({ "k": k, "p": p, "s": format!("/{}", &sig[1..]) }),
        json!({ "k": k, "p": p, "s": format!("{sig}A") }),
        json!({ "k": k, "p": p, "s": &sig[..85] }),
        json!({ "k": k, "p": "A".repeat(MAX_PAYLOAD_CHARS + 1), "s": sig }),
    ];
    for env in cases {
        let rejected = verify(&env, &s.keys(), &expect(4)).unwrap_err();
        assert_eq!(rejected.reason, Reason::Malformed, "{env}");
        assert_eq!(rejected.seq, None);
    }
    // Right alphabet and length but not decodable as strict base64url → malformed after the key
    // lookup, so `k` is known:
    // - the 86th character of a 64-byte value carries 4 unused bits that must be zero (valid
    //   last characters are A, Q, g, w; `B` sets one of those bits);
    // - 5 characters (length % 4 == 1) cannot be a base64 value.
    let non_canonical = format!("{}B", &sig[..85]);
    for env in [
        json!({ "k": k, "p": p, "s": non_canonical }),
        json!({ "k": k, "p": "AAAAA", "s": sig }),
    ] {
        let rejected = verify(&env, &s.keys(), &expect(4)).unwrap_err();
        assert_eq!(rejected.reason, Reason::Malformed, "{env}");
        assert_eq!(rejected.k.as_deref(), Some(k.as_str()));
    }
}

#[test]
fn bad_payloads_are_rejected_even_when_signed() {
    let s = signer();
    let mut cases: Vec<Value> = Vec::new();
    let mut edit = |f: &dyn Fn(&mut Value)| {
        let mut payload = strategy(5);
        f(&mut payload);
        cases.push(payload);
    };
    edit(&|p| p["v"] = json!(2));
    edit(&|p| p["v"] = json!("1"));
    edit(&|p| p["typ"] = json!("other"));
    edit(&|p| p["extra"] = json!(true));
    edit(&|p| p["body"]["extra"] = json!(true));
    edit(&|p| p["body"]["sense_role"] = json!(null));
    edit(&|p| p["body"]["disconnect"] = json!(null));
    edit(&|p| p["body"]["disconnect"] = json!((0..65).collect::<Vec<i32>>()));
    edit(&|p| p["body"]["config_options"]["enable-audio"] = json!(true));
    edit(&|p| p["seq"] = json!(0));
    edit(&|p| p["seq"] = json!(-1));
    edit(&|p| p["seq"] = json!(1.5));
    edit(&|p| p["seq"] = json!(9_007_199_254_740_992u64));
    edit(&|p| p["iss"] = json!(""));
    edit(&|p| p["nonce"] = json!(""));
    edit(&|p| {
        p.as_object_mut().unwrap().remove("exp");
    });
    edit(&|p| {
        p["body"].as_object_mut().unwrap().remove("revision");
    });
    for payload in &cases {
        assert_eq!(reason(check(&s, payload)), Reason::BadPayload, "{payload}");
    }
    let raw: [&[u8]; 5] = [b"not json", b"[]", b"{}", b"\xff\xfe", b""];
    for bytes in raw {
        let env = s.sign_bytes(bytes);
        if bytes.is_empty() {
            // Empty `p` fails the envelope shape first.
            assert_eq!(reason(verify(&env, &s.keys(), &expect(4))), Reason::Malformed);
        } else {
            assert_eq!(reason(verify(&env, &s.keys(), &expect(4))), Reason::BadPayload);
        }
    }
}

#[test]
fn issuer_and_device_binding() {
    let s = signer();
    for (field, value, expected) in [
        ("iss", "evil.test", Reason::WrongIssuer),
        ("iss", "REMOTE.snsdpt.com", Reason::WrongIssuer),
        ("did", "987654321", Reason::WrongDevice),
        ("duuid", "b3RoZXI", Reason::WrongDevice),
    ] {
        let mut payload = strategy(5);
        payload[field] = json!(value);
        let rejected = check(&s, &payload).unwrap_err();
        assert_eq!(rejected.reason, expected, "{field}={value}");
        assert_eq!(rejected.seq, Some(5));
    }
}

#[test]
fn validity_window_allows_five_minutes_of_skew() {
    let s = signer();
    let env = s.sign(&strategy(5));
    let exp = NOW + 7 * 24 * 3600;
    let at = |now_s| {
        verify(
            &env,
            &s.keys(),
            &Expect {
                now_s,
                ..expect(4)
            },
        )
    };
    assert!(at(NOW - CLOCK_SKEW_S).is_ok());
    assert_eq!(reason(at(NOW - CLOCK_SKEW_S - 1)), Reason::NotYetValid);
    assert!(at(exp + CLOCK_SKEW_S).is_ok());
    assert_eq!(reason(at(exp + CLOCK_SKEW_S + 1)), Reason::Expired);
    assert_eq!(reason(at(i64::MAX)), Reason::Expired);
    assert_eq!(reason(at(i64::MIN)), Reason::NotYetValid);
}

#[test]
fn replayed_seq_is_rejected() {
    let s = signer();
    let env = s.sign(&strategy(5));
    let with_last = |last_seq| verify(&env, &s.keys(), &expect(last_seq));
    assert!(with_last(0).is_ok());
    assert!(with_last(4).is_ok());
    assert_eq!(reason(with_last(5)), Reason::Replayed);
    assert_eq!(reason(with_last(6)), Reason::Replayed);
}

#[test]
fn signed_update_is_not_supported_yet() {
    let s = signer();
    let mut payload = strategy(5);
    payload["typ"] = json!("update");
    payload["body"] = json!({
        "app_version": 2,
        "platform": "windows-x64",
        "url": "https://remote.snsdpt.com/indir/SenseRemote-Kurulum-2.exe",
        "sha256": "0".repeat(64),
        "size": 1024,
        "install_window": "idle",
    });
    let rejected = check(&s, &payload).unwrap_err();
    assert_eq!(rejected.reason, Reason::UnsupportedType);
    assert_eq!(rejected.seq, Some(5));
    // A strategy body under `typ: update` does not even pass the schema.
    let mut payload = strategy(5);
    payload["typ"] = json!("update");
    assert_eq!(reason(check(&s, &payload)), Reason::BadPayload);
    let mut payload = strategy(5);
    payload["typ"] = json!("update");
    payload["body"] = json!({
        "app_version": 2, "platform": "windows-x64", "url": "http://remote.snsdpt.com/x.exe",
        "sha256": "0".repeat(64), "size": 1024, "install_window": "idle",
    });
    assert_eq!(reason(check(&s, &payload)), Reason::BadPayload);
}

#[test]
fn options_outside_the_allow_list_reject_the_whole_envelope() {
    let s = signer();
    for (key, value) in [
        ("api-server", "https://evil.test"),
        ("custom-rendezvous-server", "evil.test"),
        ("approve-mode", "click"),
        ("verification-method", "use-temporary-password"),
        ("whitelist", "1.2.3.4"),
        ("allow-hide-cm", "Y"),
        ("enable-keyboard", "yes"),
        ("enable-keyboard", "y"),
        ("enable-keyboard", ""),
        ("access-mode", "full"),
        ("access-mode", "view"),
        ("auto-disconnect-timeout", "4"),
        ("auto-disconnect-timeout", "1441"),
        ("auto-disconnect-timeout", "10000"),
        ("auto-disconnect-timeout", " 10"),
        ("auto-disconnect-timeout", "+10"),
    ] {
        let mut payload = strategy(5);
        payload["body"]["config_options"][key] = json!(value);
        let rejected = check(&s, &payload).unwrap_err();
        assert_eq!(rejected.reason, Reason::NotAllowed, "{key}={value}");
        assert_eq!(rejected.seq, Some(5));
    }
}

#[test]
fn allow_list_rules() {
    let allowed = |pairs: &[(&str, &str)]| {
        check_allowed(
            &pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        )
    };
    assert!(allowed(&[]));
    assert!(allowed(&[("access-mode", "")]));
    assert!(allowed(&[("allow-auto-disconnect", "Y"), ("auto-disconnect-timeout", "5")]));
    assert!(allowed(&[("auto-disconnect-timeout", "1440")]));
    assert!(allowed(&[("auto-disconnect-timeout", "")]));
    assert!(!allowed(&[("enable-keyboard", "Y"), ("api-server", "")]));
    // No duplicates, and every key is a real RustDesk option name.
    let names: std::collections::BTreeSet<_> = ALLOWED_OPTIONS.iter().map(|(k, _)| *k).collect();
    assert_eq!(names.len(), ALLOWED_OPTIONS.len());
    let full = full_set();
    let full: std::collections::BTreeSet<_> =
        full.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(full, names);
}

#[test]
fn reason_names_match_the_panel() {
    let names: Vec<_> = Reason::ALL.iter().map(|r| r.as_str()).collect();
    assert_eq!(
        names,
        [
            "malformed",
            "unknown_key",
            "bad_signature",
            "bad_payload",
            "wrong_issuer",
            "wrong_device",
            "not_yet_valid",
            "expired",
            "replayed",
            "not_allowed",
            "unsupported_type",
            "unsupported_platform",
            "apply_failed",
        ]
    );
    for r in Reason::ALL {
        assert_eq!(Reason::parse(r.as_str()), Some(r));
    }
    assert_eq!(Reason::parse("ok"), None);
}

#[test]
fn issuer_is_the_panel_host() {
    assert_eq!(issuer_of("https://remote.snsdpt.com"), "remote.snsdpt.com");
    assert_eq!(issuer_of("https://Remote.Snsdpt.com:443"), "remote.snsdpt.com");
    assert_eq!(issuer_of("https://remote.snsdpt.com:8443"), "remote.snsdpt.com:8443");
    assert_eq!(issuer_of("https://remote.snsdpt.com:4430"), "remote.snsdpt.com:4430");
    assert_eq!(issuer_of("http://localhost:3000"), "localhost:3000");
    assert_eq!(issuer_of("http://127.0.0.1:80"), "127.0.0.1");
    assert_eq!(expected_issuer(), issuer_of(crate::sense::API_SERVER));
    if option_env!("SENSE_API_SERVER").is_none() {
        assert_eq!(expected_issuer(), "remote.snsdpt.com");
    }
}

#[test]
fn build_without_keys_rejects_every_envelope() {
    if crate::sense::envelope_keys::BUILD_KEYS.is_none() {
        let s = signer();
        let env = s.sign(&strategy(5));
        assert_eq!(reason(verify_with_build_keys(&env, &expect(4))), Reason::UnknownKey);
    }
}
