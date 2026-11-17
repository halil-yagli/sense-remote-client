//! Sense Remote: the panel's public signing keys, fixed at build time.
//!
//! `SENSE_ENVELOPE_KEYS` = `<k>=<public key>,<k>=<public key>...` where `<public key>` is the raw
//! 32-byte Ed25519 key in unpadded base64url and `<k>` is its id (first 8 bytes of SHA-256 of the
//! raw key, lowercase hex; the panel puts the same id in every envelope). Two keys during a key
//! rotation; revoking a key = removing it and shipping a new build.
//!
//! Public keys are not secret, but nothing here has a default: a build without the variable trusts
//! no key and rejects every envelope (`unknown_key`), so a test key can never reach a release.

use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    log,
};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedKey {
    /// Key id, 16 lowercase hex characters.
    pub k: String,
    pub public_key: [u8; 32],
}

/// The value given to the build, `None` when the variable was not set.
pub const BUILD_KEYS: Option<&str> = option_env!("SENSE_ENVELOPE_KEYS");

/// Key id the panel uses: SHA-256(raw public key), first 8 bytes, lowercase hex.
pub fn key_id(public_key: &[u8; 32]) -> String {
    hex::encode(&Sha256::digest(public_key)[..8])
}

pub(crate) fn is_key_id(value: &str) -> bool {
    value.len() == 16 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Parses the `SENSE_ENVELOPE_KEYS` format. Empty (or only spaces) = no trusted key. Any malformed
/// entry fails the whole list: a half-read list would silently drop a key.
pub fn parse_keys(value: &str) -> Result<Vec<TrustedKey>, String> {
    let mut keys: Vec<TrustedKey> = Vec::new();
    if value.trim().is_empty() {
        return Ok(keys);
    }
    for (i, entry) in value.split(',').enumerate() {
        let entry = entry.trim();
        let (k, encoded) = entry
            .split_once('=')
            .ok_or_else(|| format!("entry {}: expected <k>=<public key>", i + 1))?;
        let (k, encoded) = (k.trim(), encoded.trim());
        if !is_key_id(k) {
            return Err(format!("entry {}: key id must be 16 lowercase hex characters", i + 1));
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(encoded)
            .map_err(|_| format!("entry {}: public key is not unpadded base64url", i + 1))?;
        let public_key: [u8; 32] = bytes
            .try_into()
            .map_err(|_| format!("entry {}: public key must be 32 bytes", i + 1))?;
        if key_id(&public_key) != k {
            return Err(format!("entry {}: key id does not match the public key", i + 1));
        }
        if keys.iter().any(|key| key.k == k) {
            return Err(format!("entry {}: duplicate key id", i + 1));
        }
        keys.push(TrustedKey {
            k: k.to_owned(),
            public_key,
        });
    }
    Ok(keys)
}

/// Keys this build trusts. A malformed build value is logged once and trusts nothing (fail
/// closed); the `build_keys_parse` test stops such a build in CI before it ships.
pub fn trusted_keys() -> &'static [TrustedKey] {
    static KEYS: OnceLock<Vec<TrustedKey>> = OnceLock::new();
    KEYS.get_or_init(|| match parse_keys(BUILD_KEYS.unwrap_or("")) {
        Ok(keys) => {
            if keys.is_empty() {
                log::warn!("Sense Remote: no envelope keys in this build, every envelope is rejected");
            }
            keys
        }
        Err(err) => {
            log::error!("Sense Remote: SENSE_ENVELOPE_KEYS is invalid ({err}), every envelope is rejected");
            Vec::new()
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::base64::{engine::general_purpose::STANDARD, Engine as _};

    fn sample_key(seed: u8) -> [u8; 32] {
        [seed; 32]
    }

    fn entry(public_key: &[u8; 32]) -> String {
        format!("{}={}", key_id(public_key), URL_SAFE_NO_PAD.encode(public_key))
    }

    #[test]
    fn build_keys_parse() {
        // A broken CI variable must fail the build here, not ship a client that trusts nothing.
        if let Some(value) = BUILD_KEYS {
            assert!(parse_keys(value).is_ok(), "SENSE_ENVELOPE_KEYS is invalid");
        } else {
            assert!(trusted_keys().is_empty());
        }
    }

    #[test]
    fn empty_value_trusts_nothing() {
        assert_eq!(parse_keys(""), Ok(vec![]));
        assert_eq!(parse_keys("  "), Ok(vec![]));
    }

    #[test]
    fn key_id_is_sha256_prefix_hex() {
        let id = key_id(&sample_key(7));
        assert!(is_key_id(&id));
        assert_eq!(id, hex::encode(&Sha256::digest([7u8; 32])[..8]));
    }

    #[test]
    fn parses_one_and_two_keys() {
        let (a, b) = (sample_key(1), sample_key(2));
        let keys = parse_keys(&entry(&a)).unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].public_key, a);
        assert_eq!(keys[0].k, key_id(&a));
        let keys = parse_keys(&format!(" {} , {} ", entry(&a), entry(&b))).unwrap();
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[1].public_key, b);
    }

    #[test]
    fn rejects_malformed_entries() {
        let a = sample_key(1);
        let good = entry(&a);
        let encoded = URL_SAFE_NO_PAD.encode(a);
        let id = key_id(&a);
        for bad in [
            encoded.clone(),                                // no id
            format!("{}={encoded}", id.to_uppercase()),     // id not lowercase
            format!("{}={encoded}", &id[..15]),             // id too short
            format!("{}={encoded}", key_id(&sample_key(2))), // id of another key
            format!("{id}={encoded}="),                     // padding
            format!("{id}={}", URL_SAFE_NO_PAD.encode([1u8; 31])), // 31 bytes
            format!("{id}={}", STANDARD.encode([0xfbu8; 32])), // not url-safe
            format!("{good},{good}"),                       // duplicate
            format!("{good},"),                             // empty entry
        ] {
            assert!(parse_keys(&bad).is_err(), "{bad}");
        }
    }
}
