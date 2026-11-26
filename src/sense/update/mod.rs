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
//! `service.rs`). Sense Remote (U8): `SUPPORTED` is now true on Windows and macOS; on other
//! platforms every entry point stays a no-op or answers "unsupported" and `caps` does not carry
//! `update`.
//!
//! Who fills what (plan §11.1; the shared files above are not touched again):
//! - U1 `manifest`, `order`, `keys`: verification (§3.3) and `SENSE_RELEASE_KEYS`.
//! - U2 this file, `engine`, `store`, `download`, `guard`: state machine (§3.6), hint rules
//!   (§3.4), download, guard decision (§5.2), GuiStatus (§3.7).
//! - U3 `store_win`, `apply_win`; U4 `store_mac`, `apply_mac`, `daemon_mac`, `sign_mac`:
//!   the platform side (§4.4, §5, §7).
//! - U7 `manual`: the one-time manual move from version 2 (§8).
//! - U8 flips `SUPPORTED` (Windows and macOS on, other platforms off).
//!
//! U2 fills the engine and adds the runner (`runner.rs`: the thread, IPC and heartbeat glue
//! around the pure `engine::next`). All of it stays off where `SUPPORTED` is false: no timer
//! starts, the heartbeat carries no `update`, the UI gets the idle status.
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

// Sense Remote (U8): every module is compiled everywhere; only the other platform's modules are
// allowed to be unused there (macOS runs the daemon, Windows the runner in `--server`).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod apply_mac;
#[cfg_attr(not(windows), allow(dead_code))]
pub mod apply_win;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod daemon_mac;
pub mod cancel_log;
// Sense Remote (S9 P5, #96): own Controller session count that expires when not refreshed.
#[allow(dead_code)]
pub mod controlling;
pub mod download;
pub mod engine;
pub mod guard;
// Sense Remote (#77): a session without an IPC listener has no connection (macOS updater).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod idle_ipc;
pub mod keys;
pub mod manifest;
pub mod manual;
// Sense Remote: window `now`, sessions closed with a notice before the installer.
pub mod now;
pub mod order;
// Sense Remote (B1): open Controller session marker for the macOS root updater.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod outgoing;
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub mod runner;
// Sense Remote (S9 P5, #96): why an accepted update waits, to the log.
pub mod wait_log;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod sign_mac;
pub mod store;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod store_mac;
#[cfg_attr(not(windows), allow(dead_code))]
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
/// Sense Remote (U8): on for Windows and macOS (U1–U4, U6, U7 merged); off elsewhere (Linux has
/// no installer side).
pub const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));
/// `SENSE_CAPS.update` (§3.5).
pub const CAP_UPDATE: &str = "update";
/// Sense Remote: this build knows the update window `now` (heartbeat `caps`, after `password`).
pub const CAP_UPDATE_NOW: &str = "update_now";
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
// Sense Remote (U4): `Deserialize` too, the macOS agent reads it from the daemon's answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// A §3.3 reason name (`manifest::Reason::as_str`) or a platform detail such as
    /// `app_management`; must pass `is_error_detail`.
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
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
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
    /// `SUPPORTED`: this build installs updates; when false the UI only informs.
    #[serde(default)]
    pub supported: bool,
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
            supported: SUPPORTED,
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
    /// `--server` -> UI (and on macOS daemon -> agent): the answer to `InstallRequest` /
    /// `Install`, one of `request_install`'s codes (`""` = accepted).
    InstallAnswer(String),
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
    /// The daemon limits the three `_service` calls to one per second per peer PROCESS
    /// (`peer_pid`, as for envelopes, G4-4), not per connection: a new connection must not
    /// reset the limit.
    Install { version: u32 },
    /// macOS only, daemon → agent: the daemon's status JSON.
    DaemonStatus(String),
    /// Sense Remote (D3e, #68): UI → `--server`: "Vazgeç" while downloading. On the macOS
    /// `_service` channel: agent → daemon, answered with `CancelAnswer`.
    CancelRequest,
    /// Sense Remote (`now` window), macOS: daemon -> `--server` on the main channel: tell every
    /// incoming connection of this session to close ([`now::NOTICE`]). No answer. Acts only in
    /// the `--server` process; the `_service` channel does not accept it.
    CloseSessions,
    /// `--server` → UI: the answer to `CancelRequest`, one of `request_cancel`'s codes.
    CancelAnswer(String),
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

/// `error_detail` of the contract: `^[a-z_]{1,32}$`. Anything else is not reported (the panel's
/// strict schema would refuse the whole heartbeat extension).
pub fn is_error_detail(value: &str) -> bool {
    (1..=32).contains(&value.len())
        && value.bytes().all(|b| b == b'_' || b.is_ascii_lowercase())
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
    /// Sense Remote: the order's window is `now`: sessions are closed with a notice first.
    pub now: bool,
}

/// Sense version of this build as the UI shows it; 0 without `SENSE_VERSION`.
pub fn current_version() -> u32 {
    crate::sense::report::app_version().unwrap_or(0)
}

/// Called once by the heartbeat loop (`hbbs_http/sync.rs`) when it starts, in the `--server`
/// process: starts the engine (`runner::start`, its own thread), which first runs the new
/// version's self-check (§5.3, `apply::self_check`, U3). On macOS the engine and the
/// self-check belong to the daemon (`daemon_mac::start`).
pub fn on_server_start() {
    if SUPPORTED && !cfg!(target_os = "macos") {
        runner::start();
    }
}

/// Called by the heartbeat loop for every successful answer, after the envelopes: verifies
/// `release` / `order` and feeds the engine with them and the hint (`runner::on_answer`); on
/// macOS forwards them raw to the daemon as `Offer`, which verifies again. The future stays
/// `Send`; the engine work is short (two signature checks, a lock).
pub async fn on_answer(answer: Answer) {
    if !SUPPORTED || answer == Answer::default() {
        return;
    }
    #[cfg(target_os = "macos")]
    {
        let offer = SenseUpdateIpc::Offer {
            // `""` = this answer carried no notice (the daemon keeps the one it holds).
            release: answer.release.map(|v| v.to_string()).unwrap_or_default(),
            order: answer.order.map(|v| v.to_string()),
            hint_release: answer.hint.as_ref().and_then(|h| h.release),
            hint_oid: answer.hint.and_then(|h| h.oid),
        };
        // The daemon answers with its `sense.update` for the next heartbeat.
        daemon_mac::forward_offer(offer).await;
    }
    #[cfg(not(target_os = "macos"))]
    runner::on_answer(answer);
}

/// `sense.update` for the next heartbeat; `None` leaves the field out (switched off, engine not
/// running, macOS agent). From the engine's memory, without blocking.
pub fn heartbeat_status() -> Option<UpdateStatus> {
    if !SUPPORTED {
        return None;
    }
    // macOS agent: what the daemon gave with its last `Offer` answer.
    #[cfg(target_os = "macos")]
    return daemon_mac::agent_heartbeat_status();
    #[cfg(not(target_os = "macos"))]
    return runner::heartbeat_status();
}

/// Adds `sense.update` to a heartbeat's `sense`. Called after the report was signed: the field
/// is outside the signed report (§3.5).
pub fn extend_heartbeat(sense: &mut Value) {
    let Some(status) = heartbeat_status() else {
        return;
    };
    // Sense Remote (karar #84): an update that turns `failed` sends the logs to the panel (once
    // per failure; the hourly limit is in `log_upload`).
    super::log_upload::on_update_state(status.state == UpdateState::Failed);
    match serde_json::to_value(&status) {
        Ok(status) => sense["update"] = status,
        Err(err) => log::error!("Sense Remote: update status not serialized: {err}"),
    }
}

/// Main IPC channel, `--server` side: answers `StatusQuery` with `Status` and
/// `InstallRequest` with `InstallAnswer`; every other variant is ignored here (`None` = no
/// answer). The future stays `Send`.
/// The main channel's handler also runs in other processes that listen on it; this function
/// only acts in the `--server` process (the one that holds the engine, or on macOS talks to
/// the daemon) and answers `None` everywhere else.
pub async fn on_ipc(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    if !SUPPORTED || !crate::is_server() {
        return None;
    }
    // Sense Remote (`now` window): the daemon asks this session's connections to close.
    if message == SenseUpdateIpc::CloseSessions {
        let told = crate::server::sense_close_incoming(now::NOTICE);
        log::info!("Sense Remote: update now, {told} connection(s) told to close");
        return None;
    }
    #[cfg(target_os = "macos")]
    return forward_to_daemon(message).await;
    #[cfg(not(target_os = "macos"))]
    return runner::on_ipc(message);
}

/// macOS agent: the engine is the daemon's; status and install requests go there.
#[cfg(target_os = "macos")]
async fn forward_to_daemon(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    match message {
        SenseUpdateIpc::StatusQuery => {
            match daemon_mac::request_daemon(SenseUpdateIpc::StatusQuery).await {
                Some(SenseUpdateIpc::DaemonStatus(json)) => Some(SenseUpdateIpc::Status(json)),
                _ => None,
            }
        }
        // Sense Remote (#68): "Vazgeç" goes to the daemon, which holds the download.
        SenseUpdateIpc::CancelRequest => {
            match daemon_mac::request_daemon(SenseUpdateIpc::CancelRequest).await {
                Some(SenseUpdateIpc::CancelAnswer(code)) => Some(SenseUpdateIpc::CancelAnswer(code)),
                _ => Some(SenseUpdateIpc::CancelAnswer(IPC_FAILED.to_owned())),
            }
        }
        SenseUpdateIpc::InstallRequest { version } => {
            let asked = daemon_mac::request_daemon(SenseUpdateIpc::Install { version }).await;
            let code = match asked {
                Some(SenseUpdateIpc::InstallAnswer(code)) => code,
                _ => IPC_FAILED.to_owned(),
            };
            Some(SenseUpdateIpc::InstallAnswer(code))
        }
        _ => None,
    }
}

/// `request_install` when the privileged process did not answer.
pub const IPC_FAILED: &str = "ipc_failed";
/// How long the UI waits for `--server`.
pub const IPC_TIMEOUT_MS: u64 = 3000;

/// UI side: one message to `--server` on the main channel and its answer; `None` on any
/// failure. Blocking (FFI threads are not on a tokio runtime).
fn ask_server(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .ok()?;
    runtime.block_on(async move {
        let mut conn = crate::ipc::connect(1000, "").await.ok()?;
        conn.send(&crate::ipc::Data::SenseUpdate(message))
            .await
            .ok()?;
        match conn.next_timeout(IPC_TIMEOUT_MS).await {
            Ok(Some(crate::ipc::Data::SenseUpdate(reply))) => Some(reply),
            _ => None,
        }
    })
}

/// FFI `main_sense_update_status`: GuiStatus JSON, asked from `--server` (`StatusQuery`); on
/// any failure (and while switched off) the idle status. What comes back is parsed and written
/// again, so the UI only ever gets the contract's shape.
pub fn gui_status_json() -> String {
    let asked = if SUPPORTED {
        match ask_server(SenseUpdateIpc::StatusQuery) {
            Some(SenseUpdateIpc::Status(json)) => serde_json::from_str::<GuiStatus>(&json).ok(),
            _ => None,
        }
    } else {
        None
    };
    let status = asked.unwrap_or_else(|| GuiStatus::idle(current_version()));
    serde_json::to_string(&status).unwrap_or_default()
}

/// FFI `main_sense_update_install`: `""` (accepted), `no_release`, `not_newer`, `busy`,
/// `ipc_failed` or `unsupported`; sends `InstallRequest` to `--server`.
pub fn request_install(version: i32) -> String {
    if !SUPPORTED {
        return UNSUPPORTED.to_owned();
    }
    let Some(version) = u32::try_from(version)
        .ok()
        .filter(|v| (1..=MAX_VERSION).contains(v))
    else {
        return engine::NO_RELEASE.to_owned();
    };
    match ask_server(SenseUpdateIpc::InstallRequest { version }) {
        Some(SenseUpdateIpc::InstallAnswer(code)) if is_install_code(&code) => code,
        _ => IPC_FAILED.to_owned(),
    }
}

/// FFI `main_sense_update_cancel` ("Vazgeç" while downloading): `""` (stopped),
/// `not_downloading`, `panel_order`, `ipc_failed` or `unsupported`; sends `CancelRequest` to
/// `--server`.
pub fn request_cancel() -> String {
    if !SUPPORTED {
        return UNSUPPORTED.to_owned();
    }
    match ask_server(SenseUpdateIpc::CancelRequest) {
        Some(SenseUpdateIpc::CancelAnswer(code)) if is_cancel_code(&code) => code,
        _ => IPC_FAILED.to_owned(),
    }
}

/// The codes `request_cancel` may return.
pub fn is_cancel_code(code: &str) -> bool {
    [
        engine::CANCEL_ACCEPTED,
        engine::NOT_DOWNLOADING,
        engine::PANEL_ORDER,
        UNSUPPORTED,
    ]
    .contains(&code)
}

/// The codes `request_install` may return.
pub fn is_install_code(code: &str) -> bool {
    [
        engine::INSTALL_ACCEPTED,
        engine::NO_RELEASE,
        engine::NOT_NEWER,
        engine::BUSY,
        IPC_FAILED,
        UNSUPPORTED,
    ]
    .contains(&code)
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

    // Sense Remote (U8): the switch is on exactly on Windows and macOS.
    #[test]
    fn switch_is_on_for_windows_and_macos_only() {
        assert_eq!(SUPPORTED, cfg!(any(windows, target_os = "macos")));
        #[cfg(any(windows, target_os = "macos"))]
        assert!(SUPPORTED);
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            assert!(!SUPPORTED);
            assert_eq!(heartbeat_status(), None);
            let mut sense = json!({ "v": 1 });
            extend_heartbeat(&mut sense);
            assert_eq!(sense, json!({ "v": 1 }));
            assert_eq!(request_install(4), "unsupported");
            // Sense Remote (U7): the manual move is real on Windows and macOS; elsewhere it fails.
            assert_eq!(manual::upgrade_in_place(), "failed");
        }
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
        // §3.3: the panel's `ReleaseRejectReason`, then the names only orders have.
        let reasons: Vec<_> = manifest::Reason::ALL.iter().map(|r| r.as_str()).collect();
        assert_eq!(
            reasons.join(" "),
            "keys_overlap malformed unknown_key bad_signature bad_payload wrong_issuer \
             not_yet_valid expired wrong_platform bad_url build_unknown_key \
             build_bad_signature build_bad_payload build_mismatch wrong_device \
             version_mismatch release_mismatch downgrade"
        );
        assert!(reasons.iter().all(|name| is_error_detail(name)));
        let windows: Vec<_> = order::Window::ALL.iter().map(|w| w.as_str()).collect();
        assert_eq!(windows.join(" "), "idle night now");
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
                "supported", "target",
            ]
        );
        assert_eq!(status["state"], "idle");
        assert_eq!(status["current"], current_version());
        assert_eq!(status["target"], Value::Null);
        assert_eq!(status["supported"], SUPPORTED);
        // The plan's example reads back.
        let example = json!({
            "current": 3, "supported": true, "state": "available", "target": 4, "source": null,
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
    fn error_detail_shape() {
        assert!(is_error_detail("app_management"));
        assert!(is_error_detail(&"a".repeat(32)));
        for bad in ["", "App", "bad-url", "bad url", "x1", "ğ"] {
            assert!(!is_error_detail(bad), "{bad}");
        }
        assert!(!is_error_detail(&"a".repeat(33)));
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
            SenseUpdateIpc::InstallAnswer("busy".to_owned()),
            offer,
            SenseUpdateIpc::Install { version: 4 },
            SenseUpdateIpc::DaemonStatus("{}".to_owned()),
            SenseUpdateIpc::CancelRequest,
            SenseUpdateIpc::CancelAnswer("panel_order".to_owned()),
            SenseUpdateIpc::CloseSessions,
        ] {
            let text = serde_json::to_string(&message).unwrap();
            assert_eq!(serde_json::from_str::<SenseUpdateIpc>(&text).unwrap(), message);
        }
    }

    #[test]
    fn install_codes() {
        for code in ["", "no_release", "not_newer", "busy", "ipc_failed", "unsupported"] {
            assert!(is_install_code(code), "{code}");
        }
        for code in ["ok", "BUSY", " ", "installed"] {
            assert!(!is_install_code(code), "{code}");
        }
    }

    #[test]
    fn cancel_codes() {
        for code in ["", "not_downloading", "panel_order", "unsupported"] {
            assert!(is_cancel_code(code), "{code}");
        }
        for code in ["ok", "busy", " ", "cancelled"] {
            assert!(!is_cancel_code(code), "{code}");
        }
    }

    // While switched off (Linux) nothing reaches `--server` and no engine runs.
    #[cfg(not(any(windows, target_os = "macos")))]
    #[test]
    fn switched_off_asks_nobody() {
        assert!(!SUPPORTED);
        on_server_start();
        assert_eq!(heartbeat_status(), None);
        assert_eq!(runner::heartbeat_status(), None);
        let status: GuiStatus = serde_json::from_str(&gui_status_json()).unwrap();
        assert_eq!(status, GuiStatus::idle(current_version()));
    }

    // Sense Remote (U8): switched on, the UI is told this build installs updates even when
    // `--server` is not there to ask (the test process is not `--server`).
    #[cfg(any(windows, target_os = "macos"))]
    #[test]
    fn switched_on_reports_supported() {
        let status: GuiStatus = serde_json::from_str(&gui_status_json()).unwrap();
        assert!(status.supported);
        assert_eq!(status.current, current_version());
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
