//! Sense Remote (permanent password plan §3.1, §3.2): the unlock request the privileged process
//! signs with the device key (RustDesk's key pair, as `report_sig`) under
//! `PASSWORD_REQUEST_PREFIX`. The panel checks it against the device key it got at enrolment.
//! The secret key only passes through `sign_canonical`; it is never logged or returned.

use super::grant::{canonical_bytes, is_duuid, is_nonce, is_rid, ttl_ok};
use crate::sense::{envelope_keys::key_id, SenseRole};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{self, crypto::sign},
};
use serde_derive::{Deserialize, Serialize};
use serde_json::json;

/// `PasswordRequestPayload` (§3.2), field for field; unknown fields are refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasswordRequestPayload {
    pub v: u8,
    pub typ: String,
    pub rid: String,
    pub duuid: String,
    pub nonce: String,
    /// `host` or `host_controller`.
    pub role: String,
    pub platform: String,
    pub app_version: u32,
    pub iat: i64,
    pub exp: i64,
}

/// The panel's name for a role that takes incoming connections; `None` for Controller (no
/// permanent password there, plan §2.3).
pub fn incoming_role(role: SenseRole) -> Option<&'static str> {
    match role {
        SenseRole::Host => Some("host"),
        SenseRole::Both => Some("host_controller"),
        SenseRole::Controller => None,
    }
}

impl PasswordRequestPayload {
    /// The request for a fresh nonce; `exp = iat + PASSWORD_REQUEST_TTL_S`.
    pub fn new(
        rid: &str,
        duuid: &str,
        nonce: &str,
        role: &str,
        platform: &str,
        app_version: u32,
        now: i64,
    ) -> Self {
        Self {
            v: 1,
            typ: "password_request".to_owned(),
            rid: rid.to_owned(),
            duuid: duuid.to_owned(),
            nonce: nonce.to_owned(),
            role: role.to_owned(),
            platform: platform.to_owned(),
            app_version,
            iat: now,
            exp: now.saturating_add(super::PASSWORD_REQUEST_TTL_S),
        }
    }

    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "password_request"
            && is_rid(&self.rid)
            && is_duuid(&self.duuid)
            && is_nonce(&self.nonce)
            && matches!(self.role.as_str(), "host" | "host_controller")
            && matches!(self.platform.as_str(), "windows-x64" | "macos-arm64")
            && (1..=999_999).contains(&self.app_version)
            && ttl_ok(self.iat, self.exp)
    }
}

/// `{k,p,s}` JSON: `p` = JCS bytes, `s` = Ed25519 over `prefix ‖ p bytes`, `k` = key id of the
/// device public key. `secret_key` is RustDesk's 64-byte Ed25519 secret key.
pub(super) fn sign_canonical<T: serde::Serialize>(
    prefix: &[u8],
    payload: &T,
    secret_key: &[u8],
) -> Result<String, &'static str> {
    let secret_key = sign::SecretKey::from_slice(secret_key).ok_or("no_key")?;
    let bytes = canonical_bytes(payload).ok_or("bad_payload")?;
    let p = URL_SAFE_NO_PAD.encode(&bytes);
    if p.len() > super::MAX_PASSWORD_SIGNED_P_CHARS {
        return Err("bad_payload");
    }
    if sodiumoxide::init().is_err() {
        return Err("no_key");
    }
    let mut signed = Vec::with_capacity(prefix.len() + bytes.len());
    signed.extend_from_slice(prefix);
    signed.extend_from_slice(&bytes);
    let signature = sign::sign_detached(&signed, &secret_key);
    // An Ed25519 secret key in libsodium's form is seed ‖ public key.
    let public_key: [u8; 32] = secret_key.0[32..].try_into().map_err(|_| "no_key")?;
    Ok(json!({
        "k": key_id(&public_key),
        "p": p,
        "s": URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    })
    .to_string())
}

/// The signed request `{k,p,s}` as JSON. `Err`: `bad_payload` (the payload breaks the schema,
/// e.g. no build version) or `no_key`.
pub fn sign_request(payload: &PasswordRequestPayload, secret_key: &[u8]) -> Result<String, &'static str> {
    if !payload.is_valid() {
        return Err("bad_payload");
    }
    sign_canonical(super::PASSWORD_REQUEST_PREFIX, payload, secret_key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roles() {
        assert_eq!(incoming_role(SenseRole::Host), Some("host"));
        assert_eq!(incoming_role(SenseRole::Both), Some("host_controller"));
        assert_eq!(incoming_role(SenseRole::Controller), None);
    }

    #[test]
    fn invalid_payload_is_not_signed() {
        let (_, secret) = sign::gen_keypair();
        let ok = PasswordRequestPayload::new(
            "123456789", "dGVzdC11dWlk", "c2Vuc2UtdGVzdC1ub25jZQ", "host", "windows-x64", 3, 1_800_000_000,
        );
        assert!(sign_request(&ok, &secret.0).is_ok());
        let mut bad = ok.clone();
        bad.role = "controller".to_owned();
        assert_eq!(sign_request(&bad, &secret.0), Err("bad_payload"));
        let mut bad = ok.clone();
        bad.app_version = 0;
        assert_eq!(sign_request(&bad, &secret.0), Err("bad_payload"));
        assert_eq!(sign_request(&ok, &[0u8; 10]), Err("no_key"));
    }
}
