//! Sense Remote (permanent password plan §3.5): the access status the privileged process reports
//! (`StatusQuery`, heartbeat `sense.access`). Display only, outside the signed report; the ack
//! carries its own signature. U9: no `access` in the heartbeat; U11 fills it.

use serde_derive::{Deserialize, Serialize};
use serde_json::Value;

/// `SenseAccessStatus` (§3.5).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccessStatus {
    pub perm_set: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed_at: Option<i64>,
    /// Signed `PasswordAckPayload` envelope, for 24 hours after a change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ack: Option<Value>,
}

impl AccessStatus {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// `sense.access` for this heartbeat; `None` = the field is left out. U9: always `None`.
pub fn heartbeat_ext() -> Option<AccessStatus> {
    None
}

/// Adds `access` to the heartbeat's `sense` part (after signing, like `update`).
pub fn extend_heartbeat(sense: &mut Value) {
    put_access(sense, heartbeat_ext());
}

fn put_access(sense: &mut Value, access: Option<AccessStatus>) {
    let Some(access) = access else {
        return;
    };
    if let Ok(access) = serde_json::to_value(&access) {
        sense["access"] = access;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn no_access_field_while_off() {
        assert_eq!(heartbeat_ext(), None);
        let mut sense = json!({"v": 1});
        extend_heartbeat(&mut sense);
        assert_eq!(sense, json!({"v": 1}));
    }

    #[test]
    fn access_field_shape() {
        let mut sense = json!({"v": 1});
        put_access(
            &mut sense,
            Some(AccessStatus {
                perm_set: true,
                changed_at: Some(1_700_000_000),
                ack: None,
            }),
        );
        assert_eq!(
            sense["access"],
            json!({"perm_set": true, "changed_at": 1_700_000_000})
        );
    }
}
