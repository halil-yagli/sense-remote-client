//! Sense Remote (permanent password plan §3.2, §3.5): the device-signed "password changed"
//! acknowledgement the heartbeat carries for 24 hours. The panel accepts it only when `at` lies
//! in the grant's window `[iat - 300, exp + 60]` (`ack_too_late`); `at` is therefore the same
//! local time the grant was checked with (`for_grant`).

use super::grant::{is_duuid, is_gid, is_rid, is_unix, PasswordGrantPayload};
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

impl PasswordAckPayload {
    /// The ack for a grant that passed `grant::check_for_set` at local time `checked_at`.
    pub fn for_grant(grant: &PasswordGrantPayload, first: bool, checked_at: i64) -> Self {
        Self {
            v: 1,
            typ: "password_ack".to_owned(),
            rid: grant.rid.clone(),
            duuid: grant.duuid.clone(),
            gid: grant.gid.clone(),
            first,
            at: checked_at,
        }
    }

    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "password_ack"
            && is_rid(&self.rid)
            && is_duuid(&self.duuid)
            && is_gid(&self.gid)
            && is_unix(self.at)
    }
}

/// The signed ack `{k,p,s}` as JSON (device key). `Err`: `bad_payload` or `no_key`.
pub fn sign_ack(payload: &PasswordAckPayload, secret_key: &[u8]) -> Result<String, &'static str> {
    if !payload.is_valid() {
        return Err("bad_payload");
    }
    super::request::sign_canonical(super::PASSWORD_ACK_PREFIX, payload, secret_key)
}
