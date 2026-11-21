//! Sense Remote (update plan 2026-11-21, §3.1): the two key lists an update needs.
//!
//! - Panel keys sign the release notice and the order: the existing `SENSE_ENVELOPE_KEYS`.
//! - Build keys sign the build statement: `SENSE_RELEASE_KEYS`, same `k=pub[,k=pub]` format,
//!   fixed at build time (`option_env!`). Only public keys; the private build key is a GitHub
//!   environment secret and never in the repository.
//!
//! Both lists are parsed once; a malformed value trusts nothing and is logged, and the
//! `build_key_lists_are_usable` test stops such a build in CI. Beyond the envelope format,
//! `SENSE_RELEASE_KEYS` refuses control characters (a line break or tab pasted into the secret
//! must fail, not be trimmed away; security review U5, D1) and the ids of the shared test vector's
//! keys (their private halves can be derived from public labels).

use crate::sense::envelope_keys::{self, TrustedKey};
use hbb_common::log;
use std::sync::OnceLock;

/// The value given to the build, `None` when the variable was not set.
pub const BUILD_KEYS: Option<&str> = option_env!("SENSE_RELEASE_KEYS");

/// `TEST_VECTOR_KEY_IDS` of the panel (`packages/shared/src/release.ts`): the test keys of
/// `release-v1.json`. Never a panel or build key in any environment.
pub const TEST_VECTOR_KEY_IDS: [&str; 4] = [
    "94d01a580be13482", // panel-1
    "b0d12b9f71aebc1f", // panel-2
    "04d80c49ccad4b4c", // build-1
    "15797e90d15b0a59", // outsider
];

pub fn is_test_vector_key_id(k: &str) -> bool {
    TEST_VECTOR_KEY_IDS.contains(&k)
}

/// Parses `SENSE_RELEASE_KEYS`. Empty = no trusted key (no release can pass).
pub fn parse_release_keys(value: &str) -> Result<Vec<TrustedKey>, String> {
    if value.chars().any(char::is_control) {
        return Err("contains a line break, tab or other control character".to_owned());
    }
    let keys = envelope_keys::parse_keys(value)?;
    if let Some(key) = keys.iter().find(|key| is_test_vector_key_id(&key.k)) {
        return Err(format!("{} is a test vector key", key.k));
    }
    Ok(keys)
}

/// Step 0 of §3.3: the lists share a key id or a public key, so one key could sign both the
/// notice and the build statement.
pub fn lists_overlap(panel: &[TrustedKey], build: &[TrustedKey]) -> bool {
    build
        .iter()
        .any(|b| panel.iter().any(|p| p.k == b.k || p.public_key == b.public_key))
}

/// Keys that may sign a release notice or an order: the envelope keys, unless one of them is a
/// test vector key (then updates trust nothing; envelopes are not affected here).
pub fn panel_keys() -> &'static [TrustedKey] {
    static CLEAN: OnceLock<bool> = OnceLock::new();
    let keys = envelope_keys::trusted_keys();
    let clean = *CLEAN.get_or_init(|| {
        let test_key = keys.iter().find(|key| is_test_vector_key_id(&key.k));
        if let Some(key) = test_key {
            log::error!("Sense Remote: envelope key {} is a test vector key, updates are refused", key.k);
        }
        test_key.is_none()
    });
    if clean {
        keys
    } else {
        &[]
    }
}

/// Keys that may sign a build statement (`SENSE_RELEASE_KEYS`).
pub fn release_keys() -> &'static [TrustedKey] {
    static KEYS: OnceLock<Vec<TrustedKey>> = OnceLock::new();
    KEYS.get_or_init(|| match parse_release_keys(BUILD_KEYS.unwrap_or("")) {
        Ok(keys) => {
            if keys.is_empty() {
                log::warn!("Sense Remote: no release keys in this build, every update is refused");
            }
            keys
        }
        Err(err) => {
            log::error!("Sense Remote: SENSE_RELEASE_KEYS is invalid ({err}), every update is refused");
            Vec::new()
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::envelope_keys::key_id;
    use hbb_common::base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

    fn key(seed: u8) -> TrustedKey {
        let public_key = [seed; 32];
        TrustedKey {
            k: key_id(&public_key),
            public_key,
        }
    }

    fn entry(key: &TrustedKey) -> String {
        format!("{}={}", key.k, URL_SAFE_NO_PAD.encode(key.public_key))
    }

    // A broken CI value must fail here, not ship a client that refuses every update.
    #[test]
    fn build_key_lists_are_usable() {
        let release = BUILD_KEYS.map(parse_release_keys);
        if let Some(parsed) = &release {
            assert!(parsed.is_ok(), "SENSE_RELEASE_KEYS is invalid: {parsed:?}");
        }
        let panel = envelope_keys::BUILD_KEYS.map(envelope_keys::parse_keys);
        if let Some(Ok(panel)) = &panel {
            assert!(
                panel.iter().all(|key| !is_test_vector_key_id(&key.k)),
                "SENSE_ENVELOPE_KEYS holds a test vector key"
            );
            if let Some(Ok(release)) = &release {
                assert!(!lists_overlap(panel, release), "panel and release keys overlap");
            }
        }
    }

    #[test]
    fn parses_like_envelope_keys() {
        let (a, b) = (key(1), key(2));
        assert_eq!(parse_release_keys(""), Ok(vec![]));
        assert_eq!(parse_release_keys(&entry(&a)), Ok(vec![a.clone()]));
        assert_eq!(
            parse_release_keys(&format!("{} , {}", entry(&a), entry(&b))),
            Ok(vec![a, b])
        );
    }

    #[test]
    fn refuses_control_characters() {
        let good = entry(&key(1));
        for bad in [
            format!("{good}\n"),
            format!("{good}\r\n"),
            format!("\t{good}"),
            format!("{good},\n{}", entry(&key(2))),
            format!("{good}\u{0}"),
        ] {
            assert!(parse_release_keys(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn refuses_test_vector_keys() {
        let vector: serde_json::Value =
            serde_json::from_str(include_str!("../testdata/release-v1.json")).unwrap();
        let ids: Vec<&str> = ["panel_keys", "build_keys"]
            .iter()
            .flat_map(|list| vector[*list].as_array().unwrap())
            .map(|key| key["k"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), 3);
        for k in &ids {
            assert!(is_test_vector_key_id(k), "{k}");
        }
        for list in ["panel_keys", "build_keys"] {
            for key in vector[list].as_array().unwrap() {
                let value = format!("{}={}", key["k"].as_str().unwrap(), key["public_key"].as_str().unwrap());
                assert!(envelope_keys::parse_keys(&value).is_ok());
                assert!(parse_release_keys(&value).is_err(), "{value}");
            }
        }
    }

    #[test]
    fn overlap_by_id_or_public_key() {
        let (a, b, c) = (key(1), key(2), key(3));
        assert!(!lists_overlap(&[a.clone(), b.clone()], &[c.clone()]));
        assert!(!lists_overlap(&[], &[c.clone()]));
        assert!(lists_overlap(&[a.clone(), b.clone()], &[c.clone(), b.clone()]));
        let same_key_other_id = TrustedKey {
            k: c.k.clone(),
            public_key: a.public_key,
        };
        assert!(lists_overlap(&[a.clone()], &[same_key_other_id]));
        let same_id_other_key = TrustedKey {
            k: a.k.clone(),
            public_key: c.public_key,
        };
        assert!(lists_overlap(&[a], &[same_id_other_key]));
    }

    #[test]
    fn unset_build_trusts_no_build_key() {
        if BUILD_KEYS.is_none() {
            assert!(release_keys().is_empty());
        }
    }
}
