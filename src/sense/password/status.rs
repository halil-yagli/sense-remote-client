//! Sense Remote (permanent password plan §3.5): the access status the privileged process reports
//! (`StatusQuery`, heartbeat `sense.access`). Display only, outside the signed report; the ack
//! carries its own signature. U11 (Windows): the SYSTEM `--server` builds it from
//! `Config::has_permanent_password()` and the local record (`store_win`); it reaches the
//! heartbeat only while `SUPPORTED` (U14).

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

/// Sense Remote (permanent password plan §3.9, U11): what the privileged process keeps after a
/// change (Windows: HKLM `Access`; macOS: `access.json`). Never the password or its hash.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AccessRecord {
    /// Unix seconds, device clock.
    pub changed_at: i64,
    /// Signed ack `{k,p,s}` JSON of that change, if it could be signed.
    pub ack: Option<String>,
    pub ack_at: Option<i64>,
}

impl AccessRecord {
    /// The record right after a change at `now` (the ack carries the same time).
    pub fn after_change(now: i64, ack: Option<String>) -> Self {
        let ack_at = ack.is_some().then_some(now);
        Self {
            changed_at: now,
            ack,
            ack_at,
        }
    }
}

/// Whether an ack made at `ack_at` still goes into the heartbeat at `now`: for
/// `PASSWORD_ACK_REPORT_S` after it was made, and not when its time lies in the future by more
/// than the grant's clock skew (`grant::CLOCK_SKEW_BEFORE_S`).
pub fn ack_is_reported(ack_at: i64, now: i64) -> bool {
    now.checked_sub(ack_at).is_some_and(|age| {
        (-super::grant::CLOCK_SKEW_BEFORE_S..super::PASSWORD_ACK_REPORT_S).contains(&age)
    })
}

/// The one place that builds the status from what a platform store keeps (Windows:
/// `status_from`; macOS `access.json` can call it the same way). `ack` is the signed `{k,p,s}`;
/// anything that is not an object is left out.
pub fn access_status(
    perm_set: bool,
    changed_at: Option<i64>,
    ack: Option<Value>,
    ack_at: Option<i64>,
    now: i64,
) -> AccessStatus {
    let ack = ack
        .filter(Value::is_object)
        .filter(|_| ack_at.is_some_and(|at| ack_is_reported(at, now)));
    AccessStatus {
        perm_set,
        changed_at,
        ack,
    }
}

/// `access_status` from the Windows record (the ack is stored as JSON text).
pub fn status_from(perm_set: bool, record: Option<&AccessRecord>, now: i64) -> AccessStatus {
    access_status(
        perm_set,
        record.map(|record| record.changed_at),
        record
            .and_then(|record| record.ack.as_deref())
            .and_then(|ack| serde_json::from_str(ack).ok()),
        record.and_then(|record| record.ack_at),
        now,
    )
}

/// The status as the privileged process sees it now. Elsewhere (and off Windows until U12) the
/// default: nothing known.
pub fn current() -> AccessStatus {
    #[cfg(windows)]
    {
        let now = hbb_common::get_time() / 1000;
        let record = super::store_win::read();
        status_from(
            hbb_common::config::Config::has_permanent_password(),
            record.as_ref(),
            now,
        )
    }
    #[cfg(not(windows))]
    AccessStatus::default()
}

/// Whether this heartbeat carries `access`: the feature is on, this is the privileged process
/// and the role takes incoming connections.
fn reports_access(supported: bool, privileged: bool, incoming: bool) -> bool {
    supported && privileged && incoming
}

/// `sense.access` for this heartbeat; `None` = the field is left out.
pub fn heartbeat_ext() -> Option<AccessStatus> {
    #[cfg(windows)]
    let (privileged, incoming) = (
        super::ipc_win::is_service_process(),
        super::ipc_win::incoming(&crate::sense::installed_role_state()).is_some(),
    );
    #[cfg(not(windows))]
    let (privileged, incoming) = (false, false);
    reports_access(super::SUPPORTED, privileged, incoming).then(current)
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
    fn access_only_from_the_privileged_process_of_an_incoming_role() {
        assert!(reports_access(true, true, true));
        assert!(!reports_access(false, true, true));
        assert!(!reports_access(true, false, true));
        assert!(!reports_access(true, true, false));
    }

    #[test]
    fn status_carries_the_ack_for_a_day() {
        let ack = r#"{"k":"0011223344556677","p":"e30","s":"x"}"#.to_owned();
        let record = AccessRecord::after_change(1_800_000_000, Some(ack));
        assert_eq!(record.ack_at, Some(1_800_000_000));
        let fresh = status_from(true, Some(&record), 1_800_000_000 + 86_399);
        assert_eq!(fresh.changed_at, Some(1_800_000_000));
        assert_eq!(fresh.ack.as_ref().unwrap()["k"], "0011223344556677");
        let old = status_from(true, Some(&record), 1_800_000_000 + 86_400);
        assert_eq!(old.ack, None);
        assert_eq!(old.changed_at, Some(1_800_000_000));
        assert_eq!(
            serde_json::to_value(&old).unwrap(),
            json!({"perm_set": true, "changed_at": 1_800_000_000})
        );
    }

    #[test]
    fn ack_from_the_future_is_bounded_by_the_grant_skew() {
        let ack = r#"{"k":"0011223344556677","p":"e30","s":"x"}"#.to_owned();
        let record = AccessRecord::after_change(1_800_000_000, Some(ack));
        assert!(status_from(true, Some(&record), 1_800_000_000 - 300).ack.is_some());
        assert_eq!(status_from(true, Some(&record), 1_800_000_000 - 301).ack, None);
        assert!(ack_is_reported(0, 86_399) && !ack_is_reported(0, 86_400));
        assert!(!ack_is_reported(i64::MAX, -10)); // no overflow
    }

    #[test]
    fn status_without_record_or_with_a_broken_ack() {
        assert_eq!(status_from(false, None, 5), AccessStatus::default());
        let unsigned = AccessRecord::after_change(10, None);
        assert_eq!(unsigned.ack_at, None);
        assert_eq!(status_from(true, Some(&unsigned), 10).ack, None);
        let broken = AccessRecord {
            changed_at: 10,
            ack: Some("not json".to_owned()),
            ack_at: Some(10),
        };
        assert_eq!(status_from(true, Some(&broken), 10).ack, None);
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
