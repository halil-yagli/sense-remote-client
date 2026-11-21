//! Sense Remote (update plan 2026-11-21, §3.4, §3.6): the update state machine. Package U2.
//!
//! `next` is pure: `(state, event, ctx) -> (state, actions)`. The runner around it (timer,
//! heartbeat answers, IPC, the download task) lives in the privileged process (Windows:
//! `--server` as SYSTEM; macOS: the root daemon) and performs the actions.
//!
//! Rules `next` has to keep (§3.6):
//! - Never install during a connection: "idle" = no active connection for at least `IDLE_S`
//!   without a break, checked again after the download and right before the installation.
//!   Neither the user nor the panel can make an exception.
//! - Window: `idle` = as soon as idle; `night` = local hour in
//!   `NIGHT_START_HOUR..NIGHT_END_HOUR` and idle. "Güncelle" in the app is always `idle`.
//! - A panel order waits a random 0..=`MAX_JITTER_S` before downloading; a local request does
//!   not.
//! - At most `MAX_ATTEMPTS` per version in 24 h, waiting `RETRY_AFTER_S` in between, then
//!   `failed` stays; a new `oid` resets the counter.
//! - Disk: `DISK_FACTOR × size` free before downloading, otherwise `disk_space`.
//! - A connection that starts after the download: back to `scheduled`, the file is kept.
//! - Hint (§3.4): `release == null` in `HINT_NULLS_TO_DROP` successful answers in a row drops
//!   "available"; an `oid` that differs from the held order (or `null`) drops the order while
//!   the installation has not started. After `downloading` began a cancel has no effect.
//! - A rejected notice or order changes nothing but `error` / `error_detail`.
//!
//! The types below are U2's starting point; U2 may add variants and fields. Only the shape of
//! `next` and what the other packages call (`super::on_answer`, `on_ipc`, `heartbeat_status`,
//! `gui_status_json`, `request_install`) is fixed.

use super::{
    manifest::{Reason, Release},
    order::Order,
    Hint, UpdateError, UpdateSource, UpdateState,
};

/// No active connection for this long, without a break, counts as idle.
pub const IDLE_S: u64 = 120;
/// `night` window, local time: 03:00 up to (not including) 05:00.
pub const NIGHT_START_HOUR: u8 = 3;
pub const NIGHT_END_HOUR: u8 = 5;
/// Random delay of a panel order before downloading, so a bulk update does not hit the server
/// at once.
pub const MAX_JITTER_S: u64 = 15 * 60;
pub const MAX_ATTEMPTS: u8 = 3;
/// Wait after the first, second and third failed attempt.
pub const RETRY_AFTER_S: [i64; 3] = [30 * 60, 2 * 3600, 6 * 3600];
/// Downloaded file + verified copy + backup.
pub const DISK_FACTOR: u64 = 3;
pub const HINT_NULLS_TO_DROP: u8 = 2;

/// What the machine remembers between events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct State {
    pub phase: UpdateState,
    /// The valid release held (also reported as `have.release` / `have.release_exp`).
    pub release: Option<Release>,
    /// The valid panel order held (`have.oid`).
    pub order: Option<Order>,
    pub source: Option<UpdateSource>,
    pub attempts: u8,
    pub error: Option<UpdateError>,
    /// What `update.error_detail` reports: a `manifest::Reason` name, or a platform detail
    /// such as `app_management` (§7.4). Always passes `super::is_error_detail`.
    pub error_detail: Option<String>,
    pub progress_pct: Option<u8>,
    /// Successful answers in a row whose hint had `release == null`.
    pub null_hints: u8,
}

impl Default for State {
    fn default() -> Self {
        Self {
            phase: UpdateState::Idle,
            release: None,
            order: None,
            source: None,
            attempts: 0,
            error: None,
            error_detail: None,
            progress_pct: None,
            null_hints: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Timer.
    Tick,
    /// A heartbeat answer's verified parts, or why they were refused.
    Release(Result<Release, Reason>),
    Order(Result<Order, Reason>),
    Hint(Hint),
    /// "Güncelle" in the app (`InstallRequest` / macOS `Install`).
    InstallRequested { version: u32 },
    DownloadProgress(u8),
    Downloaded,
    Verified,
    /// Download, verification or the platform installation failed.
    Failed(UpdateError),
}

/// The surroundings of one step; all supplied by the runner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ctx {
    /// Local clock, Unix seconds.
    pub now_s: i64,
    /// Local hour 0–23, for the `night` window.
    pub local_hour: u8,
    /// Installed Sense version.
    pub installed: u32,
    /// Seconds without any active connection (0 while one is active).
    pub idle_s: u64,
    /// Free bytes on the download volume; `None` when it could not be read.
    pub free_bytes: Option<u64>,
    /// This step's random delay for a panel order, 0..=`MAX_JITTER_S`.
    pub jitter_s: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Start `download::fetch` for the held release.
    Download,
    /// Size and SHA-256 of the downloaded file once more.
    Verify,
    /// Hand the verified file to `super::apply::install`.
    Install,
    /// Remove a downloaded file that is no longer wanted.
    DropFile,
    /// Write `store::Persisted`.
    Persist,
}

/// U0: nothing moves.
pub fn next(state: State, event: Event, ctx: &Ctx) -> (State, Vec<Action>) {
    let _ = (event, ctx);
    (state, Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    // U0: the machine stays where it is and asks for nothing.
    #[test]
    fn skeleton_does_not_move() {
        let ctx = Ctx {
            now_s: 1_795_000_000,
            local_hour: 4,
            installed: 3,
            idle_s: 600,
            free_bytes: Some(u64::MAX),
            jitter_s: 0,
        };
        for event in [
            Event::Tick,
            Event::InstallRequested { version: 4 },
            Event::Hint(Hint {
                release: Some(4),
                oid: None,
            }),
        ] {
            assert_eq!(next(State::default(), event, &ctx), (State::default(), vec![]));
        }
    }
}
