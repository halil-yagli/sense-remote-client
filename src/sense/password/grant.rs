//! Sense Remote (permanent password plan §3.2, §3.3): the panel-signed grant that unlocks the
//! permanent password for 5 minutes, checked in the order of §3.3:
//!
//! 1. shape `{k,p,s}` (`k` 16 hex, `p` 1..=2048 base64url, `s` 86 base64url) → `malformed`
//! 2. `k` is one of the panel keys built into this client (`SENSE_ENVELOPE_KEYS`) → `unknown_key`
//! 3. strict unpadded base64url, 64-byte signature → `malformed`
//! 4. Ed25519 over `"sense-remote/password-grant/v1\n" ‖ p bytes` → `bad_signature`
//! 5. `p` is JCS-canonical JSON of the schema, no unknown field, `1 <= exp - iat <= 600`
//!    → `bad_payload`
//! 6. `iss` is our panel (`envelope::expected_issuer`) → `wrong_issuer`
//! 7. `rid` and `duuid` are this computer → `wrong_device`
//! 8. `iat - 300 <= now <= exp + 60` (local clock) → `not_yet_valid` / `expired`
//!
//! Step 9 (pending nonce) is `pending`, 10 (rule) `rule`; `check_for_set` runs 1–10 in order.
//! Everything here is pure: keys, identity and time come from the caller. Same order and
//! results as the panel's `verifyPasswordGrant` (`packages/shared/src/password-node.ts`); the
//! shared vector (`testdata/password-v1.json`) proves both agree.

use super::{
    pending::Pending, MAX_PASSWORD_SIGNED_P_CHARS, PASSWORD_GRANT_PREFIX,
};
use crate::sense::envelope_keys::TrustedKey;
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Instant;

/// Schema rule for request and grant: `1 <= exp - iat <= MAX_TTL_S`.
pub const MAX_TTL_S: i64 = 600;
/// Time window around the grant: `iat - BEFORE <= now <= exp + AFTER` (deliberately asymmetric).
pub const CLOCK_SKEW_BEFORE_S: i64 = 300;
pub const CLOCK_SKEW_AFTER_S: i64 = 60;
/// Unix seconds in the payloads: `0..=MAX_UNIX_SECONDS` (milliseconds fail).
pub const MAX_UNIX_SECONDS: i64 = 9_999_999_999;
const SIGNATURE_CHARS: usize = 86;

/// `PasswordGrantPayload` (§3.2), field for field; unknown fields are refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasswordGrantPayload {
    pub v: u8,
    pub typ: String,
    pub iss: String,
    pub rid: String,
    pub duuid: String,
    pub nonce: String,
    pub gid: String,
    pub iat: i64,
    pub exp: i64,
}

/// Why a grant was refused (§3.3, in check order). `Set` answers `grant_invalid:<code>` for
/// these, `no_pending` / `nonce_mismatch` as they are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrantError {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongIssuer,
    WrongDevice,
    NotYetValid,
    Expired,
    NoPending,
    NonceMismatch,
    Unsupported,
}

impl GrantError {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::UnknownKey => "unknown_key",
            Self::BadSignature => "bad_signature",
            Self::BadPayload => "bad_payload",
            Self::WrongIssuer => "wrong_issuer",
            Self::WrongDevice => "wrong_device",
            Self::NotYetValid => "not_yet_valid",
            Self::Expired => "expired",
            Self::NoPending => "no_pending",
            Self::NonceMismatch => "nonce_mismatch",
            Self::Unsupported => super::UNSUPPORTED,
        }
    }

    /// The `Set` answer code (§3.7): steps 1–8 as `grant_invalid:<reason>`.
    pub fn set_code(self) -> String {
        match self {
            Self::NoPending | Self::NonceMismatch | Self::Unsupported => self.as_str().to_owned(),
            other => format!("grant_invalid:{}", other.as_str()),
        }
    }
}

/// What the grant must name (§3.3 steps 6–8): our panel, this computer, the local time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantContext {
    /// `envelope::expected_issuer()`.
    pub iss: String,
    pub rid: String,
    /// Heartbeat form: base64 of `hbb_common::get_uuid()`.
    pub duuid: String,
    /// Unix seconds, local clock.
    pub now: i64,
}

// ---------------------------------------------------------------------------------------------
// Field rules shared by the three payloads (`password.ts`).
// ---------------------------------------------------------------------------------------------

fn printable(value: &str, max: usize) -> bool {
    (1..=max).contains(&value.len()) && value.bytes().all(|b| (0x21..=0x7e).contains(&b))
}

fn is_b64url_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'-' || b == b'_'
}

pub(super) fn is_rid(value: &str) -> bool {
    printable(value, 64)
}

pub(super) fn is_duuid(value: &str) -> bool {
    printable(value, 128)
}

pub(super) fn is_issuer(value: &str) -> bool {
    printable(value, 255)
}

/// 16 bytes as canonical unpadded base64url: 22 characters, the last one A/Q/g/w.
pub fn is_nonce(value: &str) -> bool {
    let b = value.as_bytes();
    b.len() == 22 && b[..21].iter().all(|c| is_b64url_char(*c)) && b"AQgw".contains(&b[21])
}

pub(super) fn is_gid(value: &str) -> bool {
    value
        .strip_prefix("pwg_")
        .is_some_and(|rest| (16..=32).contains(&rest.len()) && rest.bytes().all(is_b64url_char))
}

pub(super) fn is_unix(value: i64) -> bool {
    (0..=MAX_UNIX_SECONDS).contains(&value)
}

pub(super) fn ttl_ok(iat: i64, exp: i64) -> bool {
    is_unix(iat) && is_unix(exp) && (1..=MAX_TTL_S).contains(&(exp - iat))
}

impl PasswordGrantPayload {
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "password_grant"
            && is_issuer(&self.iss)
            && is_rid(&self.rid)
            && is_duuid(&self.duuid)
            && is_nonce(&self.nonce)
            && is_gid(&self.gid)
            && ttl_ok(self.iat, self.exp)
    }
}

/// JCS bytes of a payload (RFC 8785; our payloads are flat objects of ASCII keys, strings and
/// integers, where `report::canonical_json` is exact).
pub(super) fn canonical_bytes<T: serde::Serialize>(payload: &T) -> Option<Vec<u8>> {
    let value = serde_json::to_value(payload).ok()?;
    Some(crate::sense::report::canonical_json(&value).into_bytes())
}

/// Step 5: the payload must parse into the schema AND its bytes must be exactly the canonical
/// form of what was parsed. So BOM, duplicate keys, key order, whitespace, `1.0` / `1e0` / `-0`,
/// needless escapes and lone surrogates all fail, as on the panel.
pub(super) fn parse_canonical<T>(bytes: &[u8]) -> Option<T>
where
    T: serde::de::DeserializeOwned + serde::Serialize,
{
    let parsed: T = serde_json::from_slice(bytes).ok()?;
    (canonical_bytes(&parsed)? == bytes).then_some(parsed)
}

fn signature_ok(prefix: &[u8], public_key: &[u8; 32], payload: &[u8], signature: &[u8; 64]) -> bool {
    if sodiumoxide::init().is_err() {
        return false;
    }
    let Ok(signature) = Signature::from_bytes(signature) else {
        return false;
    };
    let mut signed = Vec::with_capacity(prefix.len() + payload.len());
    signed.extend_from_slice(prefix);
    signed.extend_from_slice(payload);
    verify_detached(&signature, &signed, &PublicKey(*public_key))
}

/// Steps 1–4: shape, key, strict decoding, signature. Returns the signed payload bytes.
pub(super) fn open_signed(
    blob: &Value,
    keys: &[TrustedKey],
    prefix: &[u8],
) -> Result<Vec<u8>, GrantError> {
    let object = blob.as_object().ok_or(GrantError::Malformed)?;
    let field = |name: &str| object.get(name).and_then(Value::as_str);
    let (Some(k), Some(p), Some(s)) = (field("k"), field("p"), field("s")) else {
        return Err(GrantError::Malformed);
    };
    if object.len() != 3
        || !crate::sense::envelope_keys::is_key_id(k)
        || p.is_empty()
        || p.len() > MAX_PASSWORD_SIGNED_P_CHARS
        || !p.bytes().all(is_b64url_char)
        || s.len() != SIGNATURE_CHARS
        || !s.bytes().all(is_b64url_char)
    {
        return Err(GrantError::Malformed);
    }
    let key = keys.iter().find(|key| key.k == k).ok_or(GrantError::UnknownKey)?;
    let payload = URL_SAFE_NO_PAD.decode(p).map_err(|_| GrantError::Malformed)?;
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(s)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(GrantError::Malformed)?;
    if !signature_ok(prefix, &key.public_key, &payload, &signature) {
        return Err(GrantError::BadSignature);
    }
    Ok(payload)
}

/// Steps 1–8. Not enough on its own to accept a grant: `check_for_set` adds the nonce.
pub fn verify_grant_value(
    grant: &Value,
    keys: &[TrustedKey],
    ctx: &GrantContext,
) -> Result<PasswordGrantPayload, GrantError> {
    let bytes = open_signed(grant, keys, PASSWORD_GRANT_PREFIX)?;
    let payload: PasswordGrantPayload = parse_canonical(&bytes)
        .filter(PasswordGrantPayload::is_valid)
        .ok_or(GrantError::BadPayload)?;
    if payload.iss != ctx.iss {
        return Err(GrantError::WrongIssuer);
    }
    if payload.rid != ctx.rid || payload.duuid != ctx.duuid {
        return Err(GrantError::WrongDevice);
    }
    if ctx.now < payload.iat - CLOCK_SKEW_BEFORE_S {
        return Err(GrantError::NotYetValid);
    }
    if ctx.now > payload.exp + CLOCK_SKEW_AFTER_S {
        return Err(GrantError::Expired);
    }
    Ok(payload)
}

/// `verify_grant_value` on the JSON text the UI sent (not JSON → `malformed`).
pub fn verify_grant(
    grant_json: &str,
    keys: &[TrustedKey],
    ctx: &GrantContext,
) -> Result<PasswordGrantPayload, GrantError> {
    let value: Value = serde_json::from_str(grant_json).map_err(|_| GrantError::Malformed)?;
    verify_grant_value(&value, keys, ctx)
}

/// Steps 1–10 for the privileged process's `Set`; `Err` is the `Set` answer code. A grant
/// that fails steps 1–9 counts against the pending nonce (dropped after
/// `pending::MAX_FAILED_CHECKS`); a weak password does not burn the grant. On success the
/// nonce is used up: the caller writes the password (step 11) and the ack (12). Nothing of
/// the grant or the password is logged here.
pub fn check_for_set(
    grant_json: &str,
    password: &super::SensePasswordSecret,
    keys: &[TrustedKey],
    ctx: &GrantContext,
    pending: &mut Pending,
    now: Instant,
) -> Result<PasswordGrantPayload, String> {
    let payload = match verify_grant(grant_json, keys, ctx) {
        Ok(payload) => payload,
        Err(err) => {
            pending.record_failure(now);
            return Err(err.set_code());
        }
    };
    pending.matches(&payload.nonce, now).map_err(GrantError::set_code)?;
    if let Err(rule) = super::rule::check(password.expose(), &ctx.rid) {
        return Err(format!("weak_password:{rule}"));
    }
    pending.consume();
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_codes() {
        assert_eq!(GrantError::Expired.set_code(), "grant_invalid:expired");
        assert_eq!(GrantError::Malformed.set_code(), "grant_invalid:malformed");
        assert_eq!(GrantError::NoPending.set_code(), "no_pending");
        assert_eq!(GrantError::NonceMismatch.set_code(), "nonce_mismatch");
    }

    #[test]
    fn payload_refuses_unknown_fields() {
        let ok = serde_json::json!({"v": 1, "typ": "password_grant", "iss": "i", "rid": "1",
            "duuid": "u", "nonce": "n", "gid": "pwg_x", "iat": 1, "exp": 2});
        assert!(serde_json::from_value::<PasswordGrantPayload>(ok.clone()).is_ok());
        let mut extra = ok;
        extra["email"] = "x".into();
        assert!(serde_json::from_value::<PasswordGrantPayload>(extra).is_err());
    }

    #[test]
    fn field_rules() {
        assert!(is_nonce("c2Vuc2UtdGVzdC1ub25jZQ"));
        assert!(!is_nonce("c2Vuc2UtdGVzdC1ub25jZR")); // stray bits: not canonical
        assert!(!is_nonce("c2Vuc2UtdGVzdC1ub25jZ"));
        assert!(is_gid("pwg_VGVzdEdyYW50MDAwMDAx"));
        assert!(!is_gid("pwg_short"));
        assert!(!is_gid("pwx_VGVzdEdyYW50MDAwMDAx"));
        assert!(ttl_ok(0, 1) && ttl_ok(0, 600));
        assert!(!ttl_ok(5, 5) && !ttl_ok(0, 601) && !ttl_ok(-1, 10));
        assert!(!is_rid("") && !is_rid("a b") && is_rid(&"x".repeat(64)) && !is_rid(&"x".repeat(65)));
    }

    #[test]
    fn non_json_grant_is_malformed() {
        let ctx = GrantContext {
            iss: "remote.example.test".to_owned(),
            rid: "1".to_owned(),
            duuid: "u".to_owned(),
            now: 0,
        };
        assert_eq!(verify_grant("not json", &[], &ctx), Err(GrantError::Malformed));
        assert_eq!(verify_grant("{}", &[], &ctx), Err(GrantError::Malformed));
    }
}
