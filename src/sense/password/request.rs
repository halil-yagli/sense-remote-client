//! Sense Remote (permanent password plan §3.2): the unlock request the privileged process signs
//! with the device key (`report_sig` key, `PASSWORD_REQUEST_PREFIX`). U9: payload only; U10
//! signs it.

use serde_derive::{Deserialize, Serialize};

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

/// The signed request `{k,p,s}` as JSON. U9: `Err("unsupported")`.
pub fn sign_request(payload: &PasswordRequestPayload) -> Result<String, &'static str> {
    let _ = payload;
    Err(super::UNSUPPORTED)
}
