//! Sense Remote (permanent password plan §3.2, §3.5): the device-signed "password changed"
//! acknowledgement the heartbeat carries for 24 hours. U9: payload only; U10 signs it.

use serde_derive::{Deserialize, Serialize};

/// `PasswordAckPayload` (§3.2), field for field; unknown fields are refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasswordAckPayload {
    pub v: u8,
    pub typ: String,
    pub rid: String,
    pub duuid: String,
    pub gid: String,
    /// No permanent password before this change.
    pub first: bool,
    /// Device clock.
    pub at: i64,
}

/// The signed ack `{k,p,s}` as JSON. U9: `Err("unsupported")`.
pub fn sign_ack(payload: &PasswordAckPayload) -> Result<String, &'static str> {
    let _ = payload;
    Err(super::UNSUPPORTED)
}
