//! Sense Remote (update plan 2026-11-21, §3.6): what an update keeps across restarts.
//! Package U2 owns this file (types, rules); the platform stores are `store_win` (U3) and
//! `store_mac` (U4), reached as `super::store_os`.
//!
//! - Windows: `HKLM\SOFTWARE\SenseRemote\Update`, values `State`, `Target`, `From`, `FromId`,
//!   `FromKeyHash`, `Oid`, `Source`, `Attempts`, `LastError`, `StartedAt`, `HealthyAt`; ACL as
//!   for `Role` / `Setup`.
//! - macOS: `/Library/Application Support/SenseRemote/update.json`, root:wheel 0644, read and
//!   written with the `state.json` rules (`lstat`, uid 0, `mode & 022`, `flock`, temp file →
//!   `rename`).
//! - The installed version number is separate: Windows HKLM `Version` (written at installation
//!   and at update), macOS `SenseRemoteVersion` in the bundle's `Info.plist` (packaging). A
//!   missing value means version 2 or older.
//!
//! Only the privileged process writes. Nothing here is secret: `from_key_hash` is the SHA-256
//! of the device's public key, kept to compare in the self-check (§5.3).

use super::{UpdateError, UpdateSource, UpdateState};
use serde_derive::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

wire_enum!(
    /// `State` in the store: the reported states plus `unhealthy`, which the new version writes
    /// when its self-check fails (§5.3) and the guard rolls back on (§5.2).
    StoredState {
        Idle => "idle",
        Available => "available",
        Scheduled => "scheduled",
        WaitingIdle => "waiting_idle",
        Downloading => "downloading",
        Verifying => "verifying",
        Installing => "installing",
        Unhealthy => "unhealthy",
        Installed => "installed",
        Failed => "failed",
        RolledBack => "rolled_back",
    }
);

impl StoredState {
    /// The state as the heartbeat reports it; `unhealthy` is still `installing` for the panel
    /// (the guard decides what it becomes).
    // Sense Remote (U8): read by the Windows runner; the macOS daemon reports its own way.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    pub fn reported(self) -> UpdateState {
        match self {
            Self::Unhealthy => UpdateState::Installing,
            other => UpdateState::parse(other.as_str()).unwrap_or(UpdateState::Idle),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Persisted {
    pub state: StoredState,
    /// Version being installed.
    #[serde(default)]
    pub target: Option<u32>,
    /// Version, RustDesk ID and device key hash before the installation.
    #[serde(default)]
    pub from: Option<u32>,
    #[serde(default)]
    pub from_id: Option<String>,
    #[serde(default)]
    pub from_key_hash: Option<String>,
    #[serde(default)]
    pub oid: Option<String>,
    #[serde(default)]
    pub source: Option<UpdateSource>,
    #[serde(default)]
    pub attempts: u8,
    #[serde(default)]
    pub last_error: Option<UpdateError>,
    /// Unix seconds: the installation started / the new version declared itself healthy.
    #[serde(default)]
    pub started_at: Option<i64>,
    #[serde(default)]
    pub healthy_at: Option<i64>,
}

/// `Ok(None)` = nothing stored. `Err` = unreadable or breaking the rules (owner, mode, type):
/// the caller then does nothing (the guard too, §5.2). U0: always `Err("unsupported")`.
pub fn read() -> Result<Option<Persisted>, String> {
    super::store_os::read()
}

/// Privileged process only.
pub fn write(state: &Persisted) -> Result<(), String> {
    super::store_os::write(state)
}

/// Installed Sense version; 0 when the value is missing (version 2 or older, or not installed).
pub fn installed_version() -> u32 {
    super::store_os::installed_version()
}

/// `FromKeyHash`: SHA-256 of the device's public Ed25519 key, lowercase hex.
pub fn key_hash(public_key: &[u8]) -> String {
    hex::encode(Sha256::digest(public_key))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_states_are_the_reported_ones_plus_unhealthy() {
        for state in StoredState::ALL.iter().copied() {
            match state {
                StoredState::Unhealthy => {
                    assert_eq!(UpdateState::parse(state.as_str()), None);
                    assert_eq!(state.reported(), UpdateState::Installing);
                }
                _ => assert_eq!(state.reported().as_str(), state.as_str()),
            }
        }
        assert_eq!(StoredState::ALL.len(), UpdateState::ALL.len() + 1);
    }

    #[test]
    fn persisted_json_is_strict() {
        let minimal: Persisted = serde_json::from_str(r#"{"state":"installing"}"#).unwrap();
        assert_eq!(minimal.state, StoredState::Installing);
        assert_eq!((minimal.target, minimal.attempts), (None, 0));
        assert!(serde_json::from_str::<Persisted>(r#"{"state":"installing","x":1}"#).is_err());
        assert!(serde_json::from_str::<Persisted>(r#"{"state":"paused"}"#).is_err());
        let text = serde_json::to_string(&minimal).unwrap();
        assert_eq!(serde_json::from_str::<Persisted>(&text).unwrap(), minimal);
    }

    #[test]
    fn key_hash_is_sha256_hex() {
        assert_eq!(
            key_hash(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    // U0: no store yet. Sense Remote: Windows (U3, `store_win`) and macOS (U4, `store_mac`)
    // have their stores now, tested there.
    #[cfg(not(any(windows, target_os = "macos")))]
    #[test]
    fn skeleton_has_no_store() {
        assert_eq!(read(), Err("unsupported".to_owned()));
    }
}
