//! Sense Remote (update plan 2026-11-21, §3): signed self-update, skeleton (package U0).
//!
//! The panel announces a version in the heartbeat answer (`sense_release`, signed with the panel
//! key and carrying a build statement signed with the build key), optionally orders this computer
//! to install it (`sense_update_order`), and withdraws either with an unsigned hint
//! (`sense_update`, which can only drop or hide, never install). The privileged process
//! (Windows: `--server` as SYSTEM; macOS: the root daemon) verifies both signatures and the
//! SHA-256, installs only while no connection is active and keeps the old version as a guard
//! that rolls back when the new one does not report itself healthy.
//!
//! U0 only fixes the signatures and wires the shared files (`sense.rs`, `ipc.rs`,
//! `flutter_ffi.rs`, `hbbs_http/sync.rs`, `envelope_apply.rs`, `report.rs`, `core_main.rs`,
//! `service.rs`). Nothing here acts yet: `SUPPORTED` is false, every entry point is a no-op or
//! answers "unsupported", and `caps` does not carry `update`.
//!
//! Who fills what (plan §11.1; the shared files above are not touched again):
//! - U1 `manifest`, `order`, `keys`: verification (§3.3) and `SENSE_RELEASE_KEYS`.
//! - U2 this file, `engine`, `store`, `download`, `guard`: state machine (§3.6), hint rules
//!   (§3.4), download, guard decision (§5.2), GuiStatus (§3.7).
//! - U3 `store_win`, `apply_win`; U4 `store_mac`, `apply_mac`, `daemon_mac`, `sign_mac`:
//!   the platform side (§4.4, §5, §7).
//! - U7 `manual`: the one-time manual move from version 2 (§8).
//! - U8 flips `SUPPORTED`.
//!
//! Every module is compiled on every platform (the shared files call them without `cfg`); a
//! module gates its own platform-only parts, like `mac_apply` does.

use hbb_common::log;
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

/// A contract enum sent as its lowercase name (`as_str`), both in JSON and in the stores.
macro_rules! wire_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident => $text:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum $name {
            $($variant),+
        }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            pub fn as_str(self) -> &'static str {
                match self {
                    $($name::$variant => $text),+
                }
            }

            pub fn parse(value: &str) -> Option<Self> {
                Self::ALL.iter().copied().find(|item| item.as_str() == value)
            }
        }

        impl serde::Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.as_str())
            }
        }

        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = <String as serde::Deserialize>::deserialize(deserializer)?;
                Self::parse(&value).ok_or_else(|| serde::de::Error::custom("unknown value"))
            }
        }
    };
}

pub mod apply_mac;
pub mod apply_win;
pub mod daemon_mac;
pub mod download;
pub mod engine;
pub mod guard;
pub mod keys;
pub mod manifest;
pub mod manual;
pub mod order;
pub mod sign_mac;
pub mod store;
pub mod store_mac;
pub mod store_win;

/// Platform side of the engine: the same function set in both modules. Other platforms get the
/// Windows module, which does nothing outside Windows.
#[cfg(target_os = "macos")]
pub use apply_mac as apply;
#[cfg(not(target_os = "macos"))]
pub use apply_win as apply;
#[cfg(target_os = "macos")]
pub use store_mac as store_os;
#[cfg(not(target_os = "macos"))]
pub use store_win as store_os;

/// This build installs signed updates. The one switch: `caps` carries `update` only when it is
/// true (`report.rs`), and the panel gives releases and orders only to computers reporting it.
/// U8 turns it on per platform, after U1–U4, U6 and U7.
pub const SUPPORTED: bool = false;
/// `SENSE_CAPS.update` (§3.5).
pub const CAP_UPDATE: &str = "update";
/// Largest version number of the contract (`Version`, §3.2).
pub const MAX_VERSION: u32 = 999_999;
/// What the skeleton and unsupported platforms answer.
pub const UNSUPPORTED: &str = "unsupported";

/// Guard run from the copy of the old version (§5.2). Windows: scheduled task as SYSTEM
/// (`prev\SenseRemote.exe --sense-update-guard`); macOS: launchd job as root
/// (`prev/.../MacOS/service --sense-update-guard`).
pub const ARG_GUARD: &str = "--sense-update-guard";
/// Elevated step of the manual move from version 2 on Windows (§8).
pub const ARG_UPGRADE_LOCAL: &str = "--sense-upgrade-local";

wire_enum!(
    /// `SenseUpdateState` (§3.5, §3.6).
    UpdateState {
        Idle => "idle",
        Available => "available",
        Scheduled => "scheduled",
        WaitingIdle => "waiting_idle",
        Downloading => "downloading",
        Verifying => "verifying",
        Installing => "installing",
        Installed => "installed",
        Failed => "failed",
        RolledBack => "rolled_back",
    }
);

wire_enum!(
    /// `SenseUpdateError` (§3.5).
    UpdateError {
        ManifestInvalid => "manifest_invalid",
        OrderInvalid => "order_invalid",
        Downgrade => "downgrade",
        DownloadFailed => "download_failed",
        SizeMismatch => "size_mismatch",
        HashMismatch => "hash_mismatch",
        DiskSpace => "disk_space",
        InstallFailed => "install_failed",
        VersionMismatch => "version_mismatch",
        HealthTimeout => "health_timeout",
        IdentityChanged => "identity_changed",
        RolledBack => "rolled_back",
        RollbackFailed => "rollback_failed",
        Busy => "busy",
        Unsupported => "unsupported",
    }
);

wire_enum!(
    /// Who started the update: a panel order, "Güncelle" in the app, or the setup file run by
    /// hand (version 2 → 3).
    UpdateSource {
        Panel => "panel",
        Local => "local",
        Manual => "manual",
    }
);

wire_enum!(
    /// How the installed app is signed (`sign`, §3.5, §7). Windows always reports `none`.
    SignKind {
        Adhoc => "adhoc",
        Cert => "cert",
        Unsigned => "none",
        Unknown => "unknown",
    }
);

wire_enum!(
    /// GuiStatus `blocked` (§3.7): why an accepted update has not started yet.
    Blocked {
        SessionActive => "session_active",
        NightWindow => "night_window",
    }
);

/// `sense.update` of the heartbeat (`SenseUpdateStatus`, §3.5). Display only: it is NOT part of
/// the signed report, and the panel decides "installed" from `app_version`, never from this.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UpdateStatus {
    pub state: UpdateState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<UpdateSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oid: Option<String>,
    /// 0–100.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress_pct: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<UpdateError>,
    /// A §3.3 reason name (`manifest::Reason::as_str`), `^[a-z_]{1,32}$`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_detail: Option<String>,
    /// 0–10.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attempts: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub have: Option<Have>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sign: Option<SignKind>,
    /// Local clock, Unix seconds; information only.
    pub at: i64,
}

/// What this computer already holds, so the panel does not send it again (§3.4).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Have {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_exp: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oid: Option<String>,
}

/// GuiStatus (§3.7): what `main_sense_update_status` returns as JSON; the UI asks every 5 s.
/// Every key is always present (`null` when there is nothing), as in the plan's example.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuiStatus {
    /// Sense version of this build; 0 without `SENSE_VERSION` (local builds).
    pub current: u32,
    pub state: UpdateState,
    pub target: Option<u32>,
    pub source: Option<UpdateSource>,
    pub progress_pct: Option<u8>,
    pub error: Option<UpdateError>,
    pub error_detail: Option<String>,
    pub blocked: Option<Blocked>,
    pub notes_url: Option<String>,
    /// Last successful heartbeat answer, Unix seconds.
    pub checked_at: Option<i64>,
    /// macOS, Host or Host + Controller, `sign != "cert"` (§7).
    pub mac_permission_warning: bool,
    pub last_result: Option<LastResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastResult {
    /// `installed`, `failed` or `rolled_back`.
    pub state: UpdateState,
    pub from: u32,
    pub to: u32,
    pub at: i64,
}

impl GuiStatus {
    /// Nothing known: what the UI gets from the skeleton, an unsupported platform, or when the
    /// privileged process does not answer.
    pub fn idle(current: u32) -> Self {
        Self {
            current,
            state: UpdateState::Idle,
            target: None,
            source: None,
            progress_pct: None,
            error: None,
            error_detail: None,
            blocked: None,
            notes_url: None,
            checked_at: None,
            mac_permission_warning: false,
            last_result: None,
        }
    }
}

/// Payload of `ipc::Data::SenseUpdate` (§3.7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseUpdateIpc {
    /// UI → `--server`. On the macOS `_service` channel: agent → daemon.
    StatusQuery,
    /// `--server` → UI: GuiStatus JSON.
    Status(String),
    /// UI → `--server`: the user pressed "Güncelle".
    InstallRequest { version: u32 },
    /// macOS only, agent (`--server`, session user) → daemon (root), `_service` channel: the raw
    /// signed release and order as received from the panel, plus the unsigned hint. The daemon
    /// verifies all of it again with its own keys and identity; the agent is not trusted (M5).
    Offer {
        release: String,
        order: Option<String>,
        hint_release: Option<u32>,
        hint_oid: Option<String>,
    },
    /// macOS only, agent → daemon: the user's install request. Only handled against the valid
    /// release the daemon itself holds.
    Install { version: u32 },
    /// macOS only, daemon → agent: the daemon's status JSON.
    DaemonStatus(String),
}

/// The unsigned hint of every heartbeat answer (`sense_update`, §3.4). It can only drop a
/// waiting job or hide the notice, never start an installation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hint {
    /// Newest published version for this platform, when newer than the installed one.
    pub release: Option<u32>,
    /// Id of the open order for this computer.
    pub oid: Option<String>,
}

impl Hint {
    /// Strict like the panel's `strictObject`: exactly `release` and `oid`, each `null` or valid.
    pub fn parse(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        if object.len() != 2 {
            return None;
        }
        let release = match object.get("release")? {
            Value::Null => None,
            other => Some(version_of(other)?),
        };
        let oid = match object.get("oid")? {
            Value::Null => None,
            Value::String(oid) if order::is_order_id(oid) => Some(oid.clone()),
            _ => return None,
        };
        Some(Self { release, oid })
    }
}

/// A contract `Version`: integer 1..=999_999.
pub fn version_of(value: &Value) -> Option<u32> {
    let number = value.as_u64()?;
    (1..=u64::from(MAX_VERSION))
        .contains(&number)
        .then_some(number as u32)
}

/// The update part of one heartbeat answer, as split off by `envelope_apply::parse_answer`.
/// `release` and `order` are the raw `{k,p,s}` objects: nothing is verified at this point.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Answer {
    pub hint: Option<Hint>,
    pub release: Option<Value>,
    pub order: Option<Value>,
}

/// One installation handed to the platform side (`apply::install`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallJob {
    /// The downloaded installer in the privileged download folder; size and SHA-256 were
    /// checked once, the platform side copies and checks it again right before running it.
    pub file: PathBuf,
    pub version: u32,
    pub sha256: String,
    pub size: u64,
    pub source: UpdateSource,
    pub oid: Option<String>,
}

/// Sense version of this build as the UI shows it; 0 without `SENSE_VERSION`.
pub fn current_version() -> u32 {
    crate::sense::report::app_version().unwrap_or(0)
}

/// Called once by the heartbeat loop (`hbbs_http/sync.rs`) when it starts, in the `--server`
/// process. U2: start the engine's timer; U3 (Windows, SYSTEM): the new version's self-check
/// (§5.3). On macOS the self-check belongs to the daemon (`daemon_mac::start`).
pub fn on_server_start() {}

/// Called by the heartbeat loop for every successful answer, after the envelopes.
/// U2: verify `release` / `order` (`manifest::verify`, `order::verify`), apply the hint rules
/// (§3.4) and feed the engine; on macOS forward them to the daemon as `Offer` instead. The
/// future must stay `Send` and must not block (registry and file work in `spawn_blocking`).
pub async fn on_answer(answer: Answer) {
    let _ = answer;
}

/// `sense.update` for the next heartbeat; `None` leaves the field out (skeleton, no installed
/// role, unsupported platform). U2: from the engine's memory, without blocking.
pub fn heartbeat_status() -> Option<UpdateStatus> {
    None
}

/// Adds `sense.update` to a heartbeat's `sense`. Called after the report was signed: the field
/// is outside the signed report (§3.5).
pub fn extend_heartbeat(sense: &mut Value) {
    let Some(status) = heartbeat_status() else {
        return;
    };
    match serde_json::to_value(&status) {
        Ok(status) => sense["update"] = status,
        Err(err) => log::error!("Sense Remote: update status not serialized: {err}"),
    }
}

/// Main IPC channel, `--server` side: answers `StatusQuery` with `Status` and takes
/// `InstallRequest`; every other variant is ignored here (`None` = no answer). U2 implements;
/// the future must stay `Send`.
pub async fn on_ipc(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    let _ = message;
    None
}

/// FFI `main_sense_update_status`: GuiStatus JSON. U2: ask `--server` over IPC (`StatusQuery`);
/// on any failure this same idle status.
pub fn gui_status_json() -> String {
    serde_json::to_string(&GuiStatus::idle(current_version())).unwrap_or_default()
}

/// FFI `main_sense_update_install`: `""` (accepted), `no_release`, `not_newer`, `busy`,
/// `ipc_failed` or `unsupported`. U2: send `InstallRequest` to `--server`.
pub fn request_install(version: i32) -> String {
    let _ = version;
    UNSUPPORTED.to_owned()
}

/// FFI `main_sense_installed_version`: the installed Sense version (Windows: HKLM `Version`;
/// macOS: `SenseRemoteVersion` of `/Applications/SenseRemote.app`); 0 when there is none, which
/// also means version 2 or older.
pub fn installed_version() -> i32 {
    i32::try_from(store::installed_version()).unwrap_or(0)
}

/// `core_main.rs` and (macOS) `service.rs`: `Some(exit code)` when `args` is one of the update
/// command lines, `None` for every other call. `args` starts at the first argument.
pub fn run_cli(args: &[String]) -> Option<i32> {
    match args.first().map(String::as_str) {
        Some(ARG_GUARD) => Some(guard::run()),
        Some(ARG_UPGRADE_LOCAL) => Some(apply_win::upgrade_local(&args[1..])),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // U0: the skeleton changes no behaviour. U8 replaces this test when it turns the switch on.
    #[test]
    fn skeleton_is_switched_off() {
        assert!(!SUPPORTED);
        assert_eq!(heartbeat_status(), None);
        let mut sense = json!({ "v": 1 });
        extend_heartbeat(&mut sense);
        assert_eq!(sense, json!({ "v": 1 }));
        assert_eq!(request_install(4), "unsupported");
        assert_eq!(manual::upgrade_in_place(), "failed");
    }

    // Names are the panel's (`sense-ext.ts`), in the contract's order.
    #[test]
    fn wire_names_match_the_contract() {
        let states: Vec<_> = UpdateState::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(
            states.join(" "),
            "idle available scheduled waiting_idle downloading verifying installing installed \
             failed rolled_back"
        );
        let errors: Vec<_> = UpdateError::ALL.iter().map(|e| e.as_str()).collect();
        assert_eq!(
            errors.join(" "),
            "manifest_invalid order_invalid downgrade download_failed size_mismatch \
             hash_mismatch disk_space install_failed version_mismatch health_timeout \
             identity_changed rolled_back rollback_failed busy unsupported"
        );
        let sources: Vec<_> = UpdateSource::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(sources.join(" "), "panel local manual");
        let signs: Vec<_> = SignKind::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(signs.join(" "), "adhoc cert none unknown");
        assert_eq!(UpdateState::parse("rolled_back"), Some(UpdateState::RolledBack));
        assert_eq!(UpdateState::parse("Idle"), None);
        assert_eq!(json!(UpdateError::HashMismatch), json!("hash_mismatch"));
        assert_eq!(
            serde_json::from_value::<SignKind>(json!("none")).ok(),
            Some(SignKind::Unsigned)
        );
        assert!(serde_json::from_value::<SignKind>(json!("self")).is_err());
    }

    #[test]
    fn status_leaves_out_what_it_does_not_know() {
        let status = UpdateStatus {
            state: UpdateState::Downloading,
            target: Some(4),
            from: None,
            source: Some(UpdateSource::Panel),
            oid: Some("upd_0123456789abcdef".to_owned()),
            progress_pct: Some(40),
            error: None,
            error_detail: None,
            attempts: Some(1),
            have: Some(Have {
                release: Some(4),
                release_exp: Some(1_795_000_000),
                oid: None,
            }),
            sign: Some(SignKind::Unsigned),
            at: 1_794_000_000,
        };
        assert_eq!(
            serde_json::to_value(&status).unwrap(),
            json!({
                "state": "downloading", "target": 4, "source": "panel",
                "oid": "upd_0123456789abcdef", "progress_pct": 40, "attempts": 1,
                "have": { "release": 4, "release_exp": 1_795_000_000 },
                "sign": "none", "at": 1_794_000_000,
            })
        );
    }

    #[test]
    fn gui_status_always_has_every_key() {
        let status: Value = serde_json::from_str(&gui_status_json()).unwrap();
        let mut keys: Vec<_> = status.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        assert_eq!(
            keys,
            [
                "blocked", "checked_at", "current", "error", "error_detail", "last_result",
                "mac_permission_warning", "notes_url", "progress_pct", "source", "state",
                "target",
            ]
        );
        assert_eq!(status["state"], "idle");
        assert_eq!(status["current"], current_version());
        assert_eq!(status["target"], Value::Null);
        // The plan's example reads back.
        let example = json!({
            "current": 3, "state": "available", "target": 4, "source": null,
            "progress_pct": null, "error": null, "error_detail": null,
            "blocked": "session_active", "notes_url": "https://panel.example/#surum-4",
            "checked_at": 1_795_000_000, "mac_permission_warning": false,
            "last_result": { "state": "installed", "from": 3, "to": 4, "at": 1_795_000_000 },
        });
        let parsed: GuiStatus = serde_json::from_value(example.clone()).unwrap();
        assert_eq!(parsed.blocked, Some(Blocked::SessionActive));
        assert_eq!(serde_json::to_value(&parsed).unwrap(), example);
    }

    #[test]
    fn hint_is_strict() {
        let oid = "upd_0123456789abcdef";
        assert_eq!(
            Hint::parse(&json!({ "release": null, "oid": null })),
            Some(Hint { release: None, oid: None })
        );
        assert_eq!(
            Hint::parse(&json!({ "release": 4, "oid": oid })),
            Some(Hint { release: Some(4), oid: Some(oid.to_owned()) })
        );
        for bad in [
            json!(null),
            json!([]),
            json!({}),
            json!({ "release": 4 }),
            json!({ "release": 0, "oid": null }),
            json!({ "release": 1_000_000, "oid": null }),
            json!({ "release": "4", "oid": null }),
            json!({ "release": 4.5, "oid": null }),
            json!({ "release": -1, "oid": null }),
            json!({ "release": 4, "oid": "upd_short" }),
            json!({ "release": 4, "oid": 7 }),
            json!({ "release": 4, "oid": null, "install": true }),
        ] {
            assert_eq!(Hint::parse(&bad), None, "{bad}");
        }
    }

    #[test]
    fn ipc_messages_keep_their_shape() {
        let offer = SenseUpdateIpc::Offer {
            release: "{}".to_owned(),
            order: None,
            hint_release: Some(4),
            hint_oid: None,
        };
        assert_eq!(
            serde_json::to_value(&offer).unwrap(),
            json!({ "t": "Offer", "c": {
                "release": "{}", "order": null, "hint_release": 4, "hint_oid": null } })
        );
        for message in [
            SenseUpdateIpc::StatusQuery,
            SenseUpdateIpc::Status("{}".to_owned()),
            SenseUpdateIpc::InstallRequest { version: 4 },
            offer,
            SenseUpdateIpc::Install { version: 4 },
            SenseUpdateIpc::DaemonStatus("{}".to_owned()),
        ] {
            let text = serde_json::to_string(&message).unwrap();
            assert_eq!(serde_json::from_str::<SenseUpdateIpc>(&text).unwrap(), message);
        }
    }

    #[test]
    fn only_the_two_update_command_lines_are_taken() {
        let args = |list: &[&str]| list.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>();
        assert_eq!(run_cli(&[]), None);
        for other in ["--server", "--update", "--service", "--install", "--sense-update"] {
            assert_eq!(run_cli(&args(&[other])), None, "{other}");
        }
        // Not as a later argument either.
        assert_eq!(run_cli(&args(&["--server", ARG_GUARD])), None);
        assert_eq!(ARG_GUARD, "--sense-update-guard");
        assert_eq!(ARG_UPGRADE_LOCAL, "--sense-upgrade-local");
    }
}
