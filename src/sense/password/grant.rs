//! Sense Remote (permanent password plan §3.2, §3.3): the panel-signed grant that unlocks the
//! permanent password for 5 minutes. U9: payload and error codes only; U10 implements the
//! check in the order of §3.3 (until then every grant is refused).

use serde_derive::{Deserialize, Serialize};

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
}

/// The device a grant must name (§3.3 step 7) and the local time of the check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantContext {
    pub rid: String,
    pub duuid: String,
    pub now: i64,
}

/// Steps 1–8 of §3.3 (format, panel key, signature, payload, issuer, device, time). The nonce
/// (step 9) is matched by `pending`. U9: refuses everything.
pub fn verify_grant(grant_json: &str, ctx: &GrantContext) -> Result<PasswordGrantPayload, GrantError> {
    let _ = (grant_json, ctx);
    Err(GrantError::Unsupported)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grant_is_refused_while_off() {
        let ctx = GrantContext {
            rid: "123456789".to_owned(),
            duuid: "dXVpZA==".to_owned(),
            now: 0,
        };
        assert_eq!(verify_grant("{}", &ctx), Err(GrantError::Unsupported));
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
}
