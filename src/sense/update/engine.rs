//! Sense Remote (update plan 2026-11-21, §3.4, §3.6): the update state machine. Package U2.
//!
//! `next` is pure: `(state, event, ctx) -> (state, actions)`. The runner around it (timer,
//! heartbeat answers, IPC, the download task; `super::runner`) lives in the privileged process
//! (Windows: `--server` as SYSTEM; macOS: the root daemon) and performs the actions.
//!
//! Rules `next` has to keep (§3.6):
//! - Never install during a connection: "idle" = no active connection for at least `IDLE_S`
//!   without a break, checked again after the download and right before the installation.
//!   Neither the user nor the panel can make an exception.
//! - Sense Remote: window `now` (panel order only, no user confirmation) skips idle time, the
//!   night window and the random delay; the platform side closes open sessions first
//!   (`update::now`).
//! - Window: `idle` = as soon as idle; `night` = local hour in
//!   `NIGHT_START_HOUR..NIGHT_END_HOUR` and idle.
//! - Sense Remote (#134): "Güncelle" in the app is the person at the computer asking, so a
//!   local job waits only while a connection is open right now (`Ctx::connected`), not for
//!   `IDLE_S` without a break and not for a held order's night window. "Kapat ve kur" (the
//!   user confirmed in the strip, `InstallNowRequested`) waits for nothing, like a `now`
//!   order: the open sessions are told and closed first (`update::now`).
//! - A panel order waits a random 0..=`MAX_JITTER_S` before downloading; a local request does
//!   not.
//! - At most `MAX_ATTEMPTS` per version in 24 h, waiting `RETRY_AFTER_S` in between, then
//!   `failed` stays; a new `oid` resets the counter, and so does the user's own "Güncelle" /
//!   "Tekrar dene" (#134: the automatic retries stay limited, a press always tries again).
//! - Disk: `DISK_FACTOR × size` free before downloading, otherwise `disk_space`.
//! - A connection that starts after the download: back to `scheduled`, the file is kept.
//! - Hint (§3.4): `release == null` in `HINT_NULLS_TO_DROP` successful answers in a row drops
//!   "available"; an `oid` that differs from the held order (or `null`) drops the order while
//!   the installation has not started. After `downloading` began a cancel has no effect.
//! - A rejected notice or order changes nothing but `error` / `error_detail`.
//! - Only a signed, verified release makes a target: the unsigned hint alone never shows
//!   "version N ready" (`target` comes from the held release, never from `Hint::release`).

use super::{
    is_error_detail,
    manifest::{Reason, Release, CLOCK_SKEW_S},
    order::{Order, Window},
    store::{Persisted, StoredState},
    Blocked, GuiStatus, Have, Hint, LastResult, SignKind, UpdateError, UpdateSource, UpdateState,
    UpdateStatus,
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
/// `MAX_ATTEMPTS` count within this period, from the first attempt.
pub const ATTEMPT_PERIOD_S: i64 = 24 * 3600;
/// Downloaded file + verified copy + backup.
pub const DISK_FACTOR: u64 = 3;
pub const HINT_NULLS_TO_DROP: u8 = 2;

/// Answers of an install request (`request_install`, FFI `main_sense_update_install`).
pub const INSTALL_ACCEPTED: &str = "";
pub const NO_RELEASE: &str = "no_release";
pub const NOT_NEWER: &str = "not_newer";
pub const BUSY: &str = "busy";

/// Answers of "Vazgeç" while downloading (`check_cancel`, FFI `main_sense_update_cancel`).
pub const CANCEL_ACCEPTED: &str = "";
pub const NOT_DOWNLOADING: &str = "not_downloading";
/// A panel order's download is not stopped from the computer (the panel's choice stands).
pub const PANEL_ORDER: &str = "panel_order";

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
    /// Nothing starts before this (Unix s): a panel order's random delay or the wait after a
    /// failed attempt.
    pub not_before_s: Option<i64>,
    /// Start of the current attempt period (`ATTEMPT_PERIOD_S`).
    pub first_attempt_s: Option<i64>,
    /// The order id `attempts` belongs to; an order with another id starts again from 0.
    pub counted_oid: Option<String>,
    /// The version `attempts` belongs to; another version starts again from 0.
    pub counted_version: Option<u32>,
    /// The complete download is in the download folder (kept while a connection waits).
    pub downloaded: bool,
    /// Why `waiting_idle` waits.
    pub blocked: Option<Blocked>,
    /// From the store at start, when no release is in memory: the version being installed (or
    /// installed, or rolled back) and the one before it, and the order id.
    pub target: Option<u32>,
    pub from: Option<u32>,
    pub stored_oid: Option<String>,
    pub last_result: Option<LastResult>,
    /// Sense Remote (#134): the user confirmed "Kapat ve kur": this job waits for nothing and
    /// closes the open sessions before the installer. Memory only; ends with the job.
    pub local_now: bool,
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
            not_before_s: None,
            first_attempt_s: None,
            counted_oid: None,
            counted_version: None,
            downloaded: false,
            blocked: None,
            target: None,
            from: None,
            stored_oid: None,
            last_result: None,
            local_now: false,
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
    /// Sense Remote (#134): "Kapat ve kur" in the app, after the user confirmed that the open
    /// connections close (`InstallNowRequest` / macOS `InstallNow`).
    InstallNowRequested { version: u32 },
    /// "Vazgeç" in the app while downloading (`CancelRequest`, macOS `Cancel`).
    CancelRequested,
    DownloadProgress(u8),
    Downloaded,
    Verified,
    /// Download, verification or the platform installation failed. `Busy` from verification
    /// or installation means a connection started: back to `scheduled`, the file is kept.
    Failed(UpdateError),
    /// A heartbeat carrying `installed` / `rolled_back` was answered (§3.6).
    Reported,
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
    /// Sense Remote (#134): a connection (incoming, or this computer's own Controller session)
    /// is open right now, as far as the runner measured. What a local job waits for.
    pub connected: bool,
    /// Free bytes on the download volume; `None` when it could not be read.
    pub free_bytes: Option<u64>,
    /// This step's random delay for a panel order, 0..=`MAX_JITTER_S`.
    pub jitter_s: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Start `download::fetch` for the held release.
    Download,
    /// Stop the running `download::fetch`; its `.part` file is removed.
    AbortDownload,
    /// Size and SHA-256 of the downloaded file once more.
    Verify,
    /// Hand the verified file to `super::apply::install`.
    Install,
    /// Remove a downloaded file that is no longer wanted (`Release::file`).
    DropFile { file: String },
    /// Write `store::Persisted` (`State::persisted`). Always first in the list.
    Persist,
}

pub fn next(mut state: State, event: Event, ctx: &Ctx) -> (State, Vec<Action>) {
    let before = Persistent::of(&state);
    let mut actions = Vec::new();
    let s = &mut state;
    match event {
        Event::Tick => tick(s, ctx, &mut actions),
        Event::Release(Ok(release)) => on_release(s, release, ctx, &mut actions),
        Event::Release(Err(reason)) => refused(s, UpdateError::ManifestInvalid, reason),
        Event::Order(Ok(order)) => on_order(s, order, ctx, &mut actions),
        Event::Order(Err(reason)) => refused(s, UpdateError::OrderInvalid, reason),
        Event::Hint(hint) => on_hint(s, hint, &mut actions),
        Event::InstallRequested { version } => on_install(s, version, false, ctx, &mut actions),
        Event::InstallNowRequested { version } => on_install(s, version, true, ctx, &mut actions),
        Event::CancelRequested => {
            if check_cancel(s).is_ok() {
                // Back to "Yeni sürüm hazır": the user's own download, so the cancelled attempt
                // does not count and nothing waits before "Güncelle" works again.
                s.phase = UpdateState::Available;
                s.source = None;
                s.local_now = false;
                s.progress_pct = None;
                s.not_before_s = None;
                s.attempts = s.attempts.saturating_sub(1);
                if s.attempts == 0 {
                    s.first_attempt_s = None;
                }
                actions.push(Action::AbortDownload);
            }
        }
        Event::DownloadProgress(pct) => {
            if s.phase == UpdateState::Downloading {
                s.progress_pct = Some(pct.min(100));
            }
        }
        Event::Downloaded => {
            if s.phase == UpdateState::Downloading {
                s.phase = UpdateState::Verifying;
                s.downloaded = true;
                s.progress_pct = None;
                actions.push(Action::Verify);
            }
        }
        Event::Verified => {
            if s.phase == UpdateState::Verifying {
                if blocked_by(s, ctx).is_some() {
                    // A connection started after the download: wait again, keep the file.
                    s.phase = UpdateState::Scheduled;
                } else {
                    s.phase = UpdateState::Installing;
                    actions.push(Action::Install);
                }
            }
        }
        Event::Failed(error) => match s.phase {
            UpdateState::Verifying | UpdateState::Installing if error == UpdateError::Busy => {
                s.phase = UpdateState::Scheduled;
            }
            UpdateState::Downloading | UpdateState::Verifying | UpdateState::Installing => {
                fail(s, error, ctx, &mut actions)
            }
            _ => {}
        },
        Event::Reported => match s.phase {
            UpdateState::Installed => {
                s.phase = UpdateState::Idle;
                s.target = None;
                s.from = None;
                s.stored_oid = None;
                s.source = None;
                s.local_now = false;
                s.attempts = 0;
                s.first_attempt_s = None;
            }
            UpdateState::RolledBack => {
                s.phase = UpdateState::Failed;
                s.error.get_or_insert(UpdateError::RolledBack);
            }
            _ => {}
        },
    }
    if Persistent::of(&state) != before {
        actions.insert(0, Action::Persist);
    }
    (state, actions)
}

/// Whether "Güncelle" for `version` is taken now; `Err` is the FFI's answer.
/// Sense Remote (#134): `failed` always takes it: the user's press opens a new attempt period
/// (as a new `oid` does for the panel). Before, three failures answered `busy` ("Güncelleme
/// zaten sürüyor") for 24 h while "Tekrar dene" was still shown. `busy` now only means a job
/// really runs (downloading, verifying, installing) or just ended.
pub fn check_install(state: &State, version: u32, ctx: &Ctx) -> Result<(), &'static str> {
    let Some(release) = state.release.as_ref().filter(|r| r.version == version) else {
        return Err(NO_RELEASE);
    };
    if !release.is_newer_than(ctx.installed) {
        return Err(NOT_NEWER);
    }
    match state.phase {
        UpdateState::Available
        | UpdateState::Scheduled
        | UpdateState::WaitingIdle
        | UpdateState::Failed => Ok(()),
        _ => Err(BUSY),
    }
}

/// Sense Remote (#134): whether "Kapat ve kur" is taken now. As `check_install`, and also while
/// the job downloads or verifies (it then installs at once when the file is ready).
pub fn check_install_now(state: &State, version: u32, ctx: &Ctx) -> Result<(), &'static str> {
    match check_install(state, version, ctx) {
        Err(BUSY)
            if matches!(
                state.phase,
                UpdateState::Downloading | UpdateState::Verifying
            ) =>
        {
            Ok(())
        }
        other => other,
    }
}

/// Sense Remote (#134): the user's own request. A new attempt period, the panel's random delay
/// and the wait after a failure skipped; `now` = the user confirmed closing the open sessions.
fn on_install(s: &mut State, version: u32, now: bool, ctx: &Ctx, actions: &mut Vec<Action>) {
    let checked = if now {
        check_install_now(s, version, ctx)
    } else {
        check_install(s, version, ctx)
    };
    if checked.is_err() {
        return;
    }
    if s.started() {
        // Only "Kapat ve kur" gets here (downloading / verifying): installed once verified.
        s.local_now = true;
        return;
    }
    s.attempts = 0;
    s.first_attempt_s = None;
    s.source = Some(UpdateSource::Local);
    s.local_now = now;
    s.not_before_s = None;
    s.phase = UpdateState::Scheduled;
    clear_error(s);
    try_start(s, ctx, actions);
}

/// Whether "Vazgeç" is taken now; `Err` is the FFI's answer. Only the user's own download
/// (`source == local`) is stopped; verification and installation are never interrupted.
pub fn check_cancel(state: &State) -> Result<(), &'static str> {
    if state.phase != UpdateState::Downloading {
        return Err(NOT_DOWNLOADING);
    }
    if state.source != Some(UpdateSource::Local) {
        return Err(PANEL_ORDER);
    }
    Ok(())
}

/// What a change has to be written for (the rest is memory only).
#[derive(PartialEq)]
struct Persistent(UpdateState, Option<u32>, Option<String>, Option<UpdateSource>, u8);

impl Persistent {
    fn of(s: &State) -> Self {
        Self(
            s.phase,
            s.target_version(),
            s.order.as_ref().map(|o| o.oid.clone()),
            s.source,
            s.attempts,
        )
    }
}

impl State {
    /// The version worked on: the held (signed) release, else what the store said.
    pub fn target_version(&self) -> Option<u32> {
        self.release.as_ref().map(|r| r.version).or(self.target)
    }

    fn started(&self) -> bool {
        matches!(
            self.phase,
            UpdateState::Downloading
                | UpdateState::Verifying
                | UpdateState::Installing
                | UpdateState::Installed
                | UpdateState::RolledBack
        )
    }

    /// A held panel order's window, whoever started the job; `idle` without an order.
    fn window(&self) -> Window {
        self.order.as_ref().map_or(Window::Idle, |order| order.window)
    }

    /// `sense.update` of the heartbeat (§3.5).
    pub fn status(&self, now_s: i64, sign: Option<SignKind>) -> UpdateStatus {
        let have = Have {
            release: self.release.as_ref().map(|r| r.version),
            release_exp: self.release.as_ref().map(|r| r.exp),
            oid: self.order.as_ref().map(|o| o.oid.clone()),
        };
        let done = matches!(self.phase, UpdateState::Installed | UpdateState::RolledBack);
        UpdateStatus {
            state: self.phase,
            target: self.target_version(),
            from: if done { self.from } else { None },
            source: self.source,
            oid: self
                .order
                .as_ref()
                .map(|o| o.oid.clone())
                .or_else(|| self.stored_oid.clone()),
            progress_pct: self.shown_progress(),
            error: self.error,
            error_detail: self.shown_detail(),
            attempts: (self.attempts > 0).then_some(self.attempts.min(10)),
            have: (have != Have::default()).then_some(have),
            sign,
            at: now_s,
        }
    }

    /// GuiStatus (§3.7) as the privileged process sees it.
    pub fn gui_status(&self, current: u32, checked_at: Option<i64>) -> GuiStatus {
        GuiStatus {
            current,
            supported: super::SUPPORTED,
            state: self.phase,
            target: self.target_version(),
            source: self.source,
            progress_pct: self.shown_progress(),
            error: self.error,
            error_detail: self.shown_detail(),
            blocked: if self.phase == UpdateState::WaitingIdle {
                self.blocked
            } else {
                None
            },
            notes_url: self.release.as_ref().and_then(|r| r.notes_url.clone()),
            checked_at,
            mac_permission_warning: false,
            last_result: self.last_result.clone(),
            attempts: (self.attempts > 0).then_some(self.attempts.min(10)),
            retry_at: self.retry_at(),
        }
    }

    /// Sense Remote (#134): when the next automatic attempt starts, while a failed attempt's
    /// wait runs (`available` with a job and a start time ahead).
    fn retry_at(&self) -> Option<i64> {
        if self.phase == UpdateState::Available && self.source.is_some() {
            self.not_before_s
        } else {
            None
        }
    }

    fn shown_progress(&self) -> Option<u8> {
        if self.phase == UpdateState::Downloading {
            self.progress_pct
        } else {
            None
        }
    }

    fn shown_detail(&self) -> Option<String> {
        self.error_detail.clone().filter(|d| is_error_detail(d))
    }

    /// The machine after a start, from `store::read()`. Releases and orders are not stored:
    /// `have` is empty, so the panel sends them again.
    pub fn restore(stored: &Result<Option<Persisted>, String>, now_s: i64) -> Self {
        let mut s = Self::default();
        let Ok(Some(p)) = stored else {
            return s;
        };
        s.attempts = p.attempts.min(10);
        s.first_attempt_s = (p.attempts > 0).then_some(now_s);
        s.counted_oid = p.oid.clone();
        s.counted_version = p.target;
        let result = |state| match (p.from, p.target) {
            (Some(from), Some(to)) => Some(LastResult {
                state,
                from,
                to,
                at: p.healthy_at.or(p.started_at).unwrap_or(now_s),
            }),
            _ => None,
        };
        match p.state {
            StoredState::Installing | StoredState::Unhealthy => {
                s.phase = UpdateState::Installing;
            }
            StoredState::Installed => {
                s.phase = UpdateState::Installed;
                s.last_result = result(UpdateState::Installed);
            }
            StoredState::RolledBack => {
                s.phase = UpdateState::RolledBack;
                s.error = Some(p.last_error.unwrap_or(UpdateError::RolledBack));
                s.last_result = result(UpdateState::RolledBack);
            }
            StoredState::Failed => {
                s.phase = UpdateState::Failed;
                s.error = p.last_error;
            }
            _ => return s,
        }
        s.target = p.target;
        s.from = p.from;
        s.source = p.source;
        s.stored_oid = p.oid.clone();
        s
    }

    /// What to write, merged into the stored record `old`; `None` = leave the store alone.
    /// An installation the platform side started (`started_at`) belongs to the self-check and
    /// the guard until it ends; `installed` / `rolled_back` stay until new work starts, so the
    /// guard still sees them.
    pub fn persisted(&self, old: Option<Persisted>) -> Option<Persisted> {
        let state = StoredState::parse(self.phase.as_str())?;
        if let Some(old) = &old {
            let installing = matches!(old.state, StoredState::Installing | StoredState::Unhealthy);
            if installing && old.started_at.is_some() {
                return None;
            }
            let finished = matches!(old.state, StoredState::Installed | StoredState::RolledBack);
            let quiet = matches!(
                self.phase,
                UpdateState::Idle | UpdateState::Available | UpdateState::Failed
            );
            if finished && quiet {
                return None;
            }
        }
        let target = self.target_version();
        let mut p = match old {
            Some(old) if target.is_some() && old.target == target => old,
            _ => Persisted {
                state,
                target: None,
                from: None,
                from_id: None,
                from_key_hash: None,
                oid: None,
                source: None,
                attempts: 0,
                last_error: None,
                started_at: None,
                healthy_at: None,
            },
        };
        p.state = state;
        p.target = target;
        p.oid = self
            .order
            .as_ref()
            .map(|o| o.oid.clone())
            .or_else(|| self.stored_oid.clone());
        p.source = self.source;
        p.attempts = self.attempts;
        p.last_error = self.error;
        Some(p)
    }
}

fn clear_error(s: &mut State) {
    s.error = None;
    s.error_detail = None;
}

fn refused(s: &mut State, error: UpdateError, reason: Reason) {
    s.error = Some(error);
    s.error_detail = Some(reason.as_str().to_owned());
}

fn same_file(a: &Release, b: &Release) -> bool {
    a.version == b.version && a.platform == b.platform && a.sha256 == b.sha256 && a.size == b.size
}

fn on_release(s: &mut State, release: Release, ctx: &Ctx, actions: &mut Vec<Action>) {
    if !release.is_newer_than(ctx.installed) {
        return; // step 12: silently ignored
    }
    if s.error == Some(UpdateError::ManifestInvalid) {
        clear_error(s);
    }
    if s.release.as_ref().is_some_and(|held| release.version < held.version) {
        return; // an older notice never replaces a newer one
    }
    if let Some(held) = &s.release {
        if same_file(held, &release) {
            if release.exp > held.exp {
                s.release = Some(release); // the panel signed it again
            }
            return;
        }
    }
    if s.started() {
        return; // the job under way is finished first
    }
    // Another version or another file: what was held for the old one goes. The attempt
    // counter stays with its version, also across a restart (`counted_version`).
    let version_changed = s.counted_version != Some(release.version);
    drop_file(s, actions);
    s.release = Some(release);
    s.order = None;
    s.source = None;
    s.not_before_s = None;
    s.blocked = None;
    if version_changed {
        s.attempts = 0;
        s.first_attempt_s = None;
        s.counted_oid = None;
        s.counted_version = s.release.as_ref().map(|r| r.version);
    }
    s.phase = UpdateState::Available;
}

fn on_order(s: &mut State, order: Order, ctx: &Ctx, actions: &mut Vec<Action>) {
    if s.error == Some(UpdateError::OrderInvalid) {
        clear_error(s);
    }
    if s.started() {
        return;
    }
    // `order::verify` checked this already; kept so the machine never installs a file it
    // was not ordered for.
    let fits = s.release.as_ref().is_some_and(|r| {
        r.version == order.version
            && r.platform == order.platform
            && r.sha256 == order.sha256
            && r.is_newer_than(ctx.installed)
    });
    if !fits {
        return;
    }
    if s.order.as_ref().map(|o| o.oid.as_str()) == Some(order.oid.as_str()) {
        s.order = Some(order);
        return;
    }
    if s.counted_oid.as_deref() != Some(order.oid.as_str()) {
        // "Tekrar dene" in the panel makes a new oid: the counter starts again.
        s.attempts = 0;
        s.first_attempt_s = None;
        s.counted_oid = Some(order.oid.clone());
    }
    s.order = Some(order);
    let local_running = s.source == Some(UpdateSource::Local)
        && matches!(s.phase, UpdateState::Scheduled | UpdateState::WaitingIdle);
    if local_running {
        return; // the user's request already runs, without the delay
    }
    s.source = Some(UpdateSource::Panel);
    s.local_now = false;
    clear_error(s);
    // Sense Remote (`now`): the operator wants it at once, no random delay.
    let jitter = if s.window() == Window::Now {
        0
    } else {
        i64::try_from(ctx.jitter_s.min(MAX_JITTER_S)).unwrap_or(0)
    };
    s.not_before_s = Some(ctx.now_s + jitter);
    s.phase = UpdateState::Scheduled;
    try_start(s, ctx, actions);
}

fn on_hint(s: &mut State, hint: Hint, actions: &mut Vec<Action>) {
    s.null_hints = if hint.release.is_none() {
        s.null_hints.saturating_add(1)
    } else {
        0
    };
    if s.started() {
        return; // no half-done installation is left behind
    }
    let cancelled = s
        .order
        .as_ref()
        .is_some_and(|o| hint.oid.as_deref() != Some(o.oid.as_str()));
    if cancelled {
        drop_order(s, actions);
    }
    if s.null_hints >= HINT_NULLS_TO_DROP && s.release.is_some() {
        drop_release(s, actions);
    }
}

fn drop_file(s: &mut State, actions: &mut Vec<Action>) {
    if s.downloaded {
        s.downloaded = false;
        if let Some(release) = &s.release {
            actions.push(Action::DropFile {
                file: release.file.clone(),
            });
        }
    }
}

fn drop_order(s: &mut State, actions: &mut Vec<Action>) {
    s.order = None;
    if s.source == Some(UpdateSource::Panel) {
        s.source = None;
        s.not_before_s = None;
        s.blocked = None;
        drop_file(s, actions);
        if matches!(s.phase, UpdateState::Scheduled | UpdateState::WaitingIdle) {
            s.phase = UpdateState::Available;
        }
    }
}

fn drop_release(s: &mut State, actions: &mut Vec<Action>) {
    drop_file(s, actions);
    s.release = None;
    s.order = None;
    s.source = None;
    s.local_now = false;
    s.not_before_s = None;
    s.blocked = None;
    if s.phase != UpdateState::Failed {
        s.phase = UpdateState::Idle;
    }
}

fn due(s: &State, now_s: i64) -> bool {
    s.not_before_s.map_or(true, |t| now_s >= t)
}

fn blocked_by(s: &State, ctx: &Ctx) -> Option<Blocked> {
    // Sense Remote (`now`): an order signed by the panel for "now" waits for nothing; the
    // runner closes the open sessions (with a notice) right before the installer. The same
    // for the user's confirmed "Kapat ve kur" (#134).
    if s.window() == Window::Now || s.local_now {
        return None;
    }
    // Sense Remote (#134): the person at the computer asked; only an open connection waits.
    if s.source == Some(UpdateSource::Local) {
        return ctx.connected.then_some(Blocked::SessionActive);
    }
    if ctx.idle_s < IDLE_S {
        return Some(Blocked::SessionActive);
    }
    let in_night = (NIGHT_START_HOUR..NIGHT_END_HOUR).contains(&ctx.local_hour);
    if s.window() == Window::Night && !in_night {
        return Some(Blocked::NightWindow);
    }
    None
}

fn tick(s: &mut State, ctx: &Ctx, actions: &mut Vec<Action>) {
    if !s.started() {
        let skewed = |exp: i64| ctx.now_s > exp + CLOCK_SKEW_S;
        if s.order.as_ref().is_some_and(|o| skewed(o.exp)) {
            drop_order(s, actions);
        }
        if s.release.as_ref().is_some_and(|r| skewed(r.exp)) {
            drop_release(s, actions);
        }
    }
    if s.phase == UpdateState::Available && s.source.is_some() && due(s, ctx.now_s) {
        s.phase = UpdateState::Scheduled; // the wait after a failed attempt is over
    }
    if matches!(s.phase, UpdateState::Scheduled | UpdateState::WaitingIdle) {
        try_start(s, ctx, actions);
    }
}

fn try_start(s: &mut State, ctx: &Ctx, actions: &mut Vec<Action>) {
    let Some((newer, size)) = s
        .release
        .as_ref()
        .map(|r| (r.is_newer_than(ctx.installed), r.size))
    else {
        s.phase = UpdateState::Idle;
        s.source = None;
        return;
    };
    if !newer {
        drop_release(s, actions); // installed in the meantime (by hand)
        return;
    }
    if !due(s, ctx.now_s) {
        s.phase = UpdateState::Scheduled;
        s.blocked = None;
        return;
    }
    if let Some(blocked) = blocked_by(s, ctx) {
        s.phase = UpdateState::WaitingIdle;
        s.blocked = Some(blocked);
        return;
    }
    s.blocked = None;
    s.not_before_s = None;
    if s.downloaded {
        s.phase = UpdateState::Verifying; // checked again before it is installed
        actions.push(Action::Verify);
        return;
    }
    if s.first_attempt_s.is_some_and(|t| ctx.now_s - t >= ATTEMPT_PERIOD_S) {
        s.attempts = 0;
        s.first_attempt_s = None;
    }
    if s.attempts >= MAX_ATTEMPTS {
        s.phase = UpdateState::Failed;
        return;
    }
    s.attempts += 1;
    s.first_attempt_s.get_or_insert(ctx.now_s);
    if !ctx
        .free_bytes
        .is_some_and(|free| super::download::enough_disk(free, size))
    {
        fail(s, UpdateError::DiskSpace, ctx, actions);
        return;
    }
    clear_error(s);
    s.phase = UpdateState::Downloading;
    s.progress_pct = Some(0);
    actions.push(Action::Download);
}

fn fail(s: &mut State, error: UpdateError, ctx: &Ctx, actions: &mut Vec<Action>) {
    s.error = Some(error);
    s.error_detail = None;
    s.progress_pct = None;
    s.blocked = None;
    // A confirmed "Kapat ve kur" was for this attempt only; the automatic retry waits again.
    s.local_now = false;
    drop_file(s, actions);
    if s.attempts < MAX_ATTEMPTS {
        let index = usize::from(s.attempts.saturating_sub(1)).min(RETRY_AFTER_S.len() - 1);
        s.not_before_s = Some(ctx.now_s + RETRY_AFTER_S[index]);
        s.phase = UpdateState::Available;
    } else {
        s.not_before_s = None;
        s.phase = UpdateState::Failed;
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
