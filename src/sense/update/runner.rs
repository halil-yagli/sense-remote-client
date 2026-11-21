//! Sense Remote (update plan 2026-11-21, §3.6, §3.7): the runner around the pure engine.
//! Package U2.
//!
//! Lives in the privileged process that holds the engine: Windows `--server` (SYSTEM). On
//! macOS the root daemon holds it (`daemon_mac`, U4, may reuse these functions); the agent
//! only forwards (`super::on_answer`, `super::on_ipc`). Nothing starts while
//! `super::SUPPORTED` is false.
//!
//! - One engine state behind a mutex. Every event goes through `engine::next` under the lock;
//!   the resulting actions become jobs, performed outside the lock on the runner's own thread
//!   (a current-thread tokio runtime): download task, verification and installation off the
//!   loop (`spawn_blocking`), store writes in order.
//! - Idle time is measured here: `updater::has_no_active_conns()` at every step; a connection
//!   resets it. The engine asks for `IDLE_S` without a break and the installation job asks
//!   once more right before `apply::install`.
//! - The heartbeat answer's release and order are verified here (`manifest::verify`,
//!   `order::verify`) with this build's keys, the local clock, own id and uuid.

use super::{
    apply, download,
    engine::{self, Action, Ctx, Event, State, MAX_JITTER_S},
    keys,
    manifest::{self, Reason, Release},
    order, store, Answer, GuiStatus, InstallJob, SenseUpdateIpc, SignKind, UpdateError,
    UpdateSource, UpdateState, UpdateStatus,
};
use hbb_common::{config::Config, log, tokio};
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, MutexGuard,
    },
    time::Duration,
};

/// Timer of the engine.
pub const TICK_S: u64 = 5;

struct Runner {
    state: State,
    /// Since when no connection is active (Unix s).
    idle_since: Option<i64>,
    /// Last successful heartbeat answer.
    checked_at: Option<i64>,
    /// The phase the last heartbeat carried (for `Event::Reported`).
    reported: Option<UpdateState>,
    jobs: tokio::sync::mpsc::UnboundedSender<Job>,
}

enum Job {
    Persist(State),
    Download(download::Request),
    Verify {
        file: PathBuf,
        sha256: String,
        size: u64,
    },
    Install(InstallJob),
    DropFile(PathBuf),
    Fail(UpdateError),
}

static RUNNER: Mutex<Option<Runner>> = Mutex::new(None);
static STARTED: AtomicBool = AtomicBool::new(false);

fn lock() -> MutexGuard<'static, Option<Runner>> {
    RUNNER.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn local_hour() -> u8 {
    use chrono::Timelike;
    chrono::Local::now().hour() as u8
}

/// Starts the engine once, on its own thread: the new version's self-check (§5.3, the
/// platform side), then the state from the store, then the timer.
pub fn start() {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        if let Err(err) = apply::self_check() {
            log::error!("Sense Remote: update self-check failed: {}", err.as_str());
        }
        let state = State::restore(&store::read(), now_s());
        let (jobs, receiver) = tokio::sync::mpsc::unbounded_channel();
        *lock() = Some(Runner {
            state,
            idle_since: None,
            checked_at: None,
            reported: None,
            jobs,
        });
        match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime.block_on(run(receiver)),
            Err(err) => log::error!("Sense Remote: update runner not started: {err}"),
        }
    });
}

async fn run(mut jobs: tokio::sync::mpsc::UnboundedReceiver<Job>) {
    let mut timer = tokio::time::interval(Duration::from_secs(TICK_S));
    loop {
        tokio::select! {
            _ = timer.tick() => step(Event::Tick),
            job = jobs.recv() => match job {
                Some(job) => perform(job),
                None => return,
            },
        }
    }
}

impl Runner {
    fn ctx(&mut self, with_disk: bool) -> Ctx {
        let now = now_s();
        if crate::updater::has_no_active_conns() {
            self.idle_since.get_or_insert(now);
        } else {
            self.idle_since = None;
        }
        let free_bytes = if with_disk {
            apply::download_dir().and_then(|dir| download::free_bytes(&dir))
        } else {
            None
        };
        Ctx {
            now_s: now,
            local_hour: local_hour(),
            installed: super::current_version(),
            idle_s: self.idle_since.map_or(0, |t| (now - t).max(0) as u64),
            free_bytes,
            jitter_s: hbb_common::rand::random::<u64>() % (MAX_JITTER_S + 1),
        }
    }

    /// Disk space is read only when a download may start.
    fn needs_disk(&self, event: &Event) -> bool {
        matches!(event, Event::InstallRequested { .. } | Event::Order(Ok(_)))
            || matches!(
                self.state.phase,
                UpdateState::Available | UpdateState::Scheduled | UpdateState::WaitingIdle
            ) && self.state.source.is_some()
    }

    fn advance(&mut self, event: Event, ctx: &Ctx) {
        let state = std::mem::take(&mut self.state);
        let (state, actions) = engine::next(state, event, ctx);
        self.state = state;
        for action in actions {
            if let Some(job) = self.job_for(action) {
                let _ = self.jobs.send(job);
            }
        }
    }

    fn job_for(&self, action: Action) -> Option<Job> {
        if let Action::Persist = action {
            return Some(Job::Persist(self.state.clone()));
        }
        let Some(dir) = apply::download_dir() else {
            return match action {
                Action::DropFile { .. } => None,
                _ => Some(Job::Fail(UpdateError::Unsupported)),
            };
        };
        if let Action::DropFile { file } = action {
            return download::is_plain_file_name(&file).then(|| Job::DropFile(dir.join(file)));
        }
        let release = self.state.release.as_ref()?;
        let file = dir.join(&release.file);
        Some(match action {
            Action::Download => Job::Download(download::Request {
                url: release.url.clone(),
                sha256: release.sha256.clone(),
                size: release.size,
                dir,
                file: release.file.clone(),
            }),
            Action::Verify => Job::Verify {
                file,
                sha256: release.sha256.clone(),
                size: release.size,
            },
            _ => Job::Install(InstallJob {
                file,
                version: release.version,
                sha256: release.sha256.clone(),
                size: release.size,
                source: self.state.source.unwrap_or(UpdateSource::Local),
                oid: self.state.order.as_ref().map(|o| o.oid.clone()),
            }),
        })
    }
}

fn step(event: Event) {
    let mut guard = lock();
    let Some(runner) = guard.as_mut() else {
        return;
    };
    let with_disk = runner.needs_disk(&event);
    let ctx = runner.ctx(with_disk);
    runner.advance(event, &ctx);
}

fn perform(job: Job) {
    match job {
        Job::Persist(state) => {
            let old = match store::read() {
                Ok(old) => old,
                Err(err) => {
                    log::warn!("Sense Remote: update store not written, unreadable: {err}");
                    return;
                }
            };
            if let Some(record) = state.persisted(old) {
                if let Err(err) = store::write(&record) {
                    log::error!("Sense Remote: update store not written: {err}");
                }
            }
        }
        Job::Download(request) => {
            tokio::spawn(async move {
                let progress = |pct: u8| step(Event::DownloadProgress(pct));
                let event = match download::fetch(&request, &progress).await {
                    Ok(_) => Event::Downloaded,
                    Err(err) => Event::Failed(err),
                };
                step(event);
            });
        }
        Job::Verify { file, sha256, size } => {
            tokio::task::spawn_blocking(move || {
                step(match download::verify_file(&file, size, &sha256) {
                    Ok(()) => Event::Verified,
                    Err(err) => Event::Failed(err),
                });
            });
        }
        Job::Install(job) => {
            tokio::task::spawn_blocking(move || {
                // Never during a connection: asked once more right before the installer.
                if !crate::updater::has_no_active_conns() {
                    step(Event::Failed(UpdateError::Busy));
                    return;
                }
                log::info!("Sense Remote: installing update {}", job.version);
                if let Err(err) = apply::install(&job) {
                    step(Event::Failed(err));
                }
            });
        }
        Job::DropFile(path) => {
            let _ = std::fs::remove_file(path);
        }
        Job::Fail(err) => step(Event::Failed(err)),
    }
}

fn verify_release(value: &Value, now: i64) -> Result<Release, Reason> {
    let platform = crate::sense::report::platform().ok_or(Reason::WrongPlatform)?;
    let iss = crate::sense::envelope::expected_issuer();
    let expect = manifest::Expect {
        iss: &iss,
        api_server: crate::sense::API_SERVER.trim_end_matches('/'),
        platform,
        now_s: now,
    };
    let result = manifest::verify(value, keys::panel_keys(), keys::release_keys(), &expect);
    if let Err(reason) = &result {
        log::warn!("Sense Remote: release notice refused: {}", reason.as_str());
    }
    result
}

fn verify_order(value: &Value, release: Option<&Release>, now: i64) -> Result<order::Order, Reason> {
    let iss = crate::sense::envelope::expected_issuer();
    let did = Config::get_id();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let expect = order::Expect {
        iss: &iss,
        did: &did,
        duuid: &duuid,
        now_s: now,
        release,
        installed: super::current_version(),
    };
    let result = order::verify(value, keys::panel_keys(), &expect);
    if let Err(reason) = &result {
        log::warn!("Sense Remote: update order refused: {}", reason.as_str());
    }
    result
}

/// One successful heartbeat answer. Release first, then the order (it needs the release),
/// then the hint (§3.3, §3.4). Blocking work is small (two signature checks).
pub fn on_answer(answer: Answer) {
    let now = now_s();
    let reported = {
        let mut guard = lock();
        let Some(runner) = guard.as_mut() else {
            return;
        };
        runner.checked_at = Some(now);
        runner.reported.take()
    };
    if matches!(
        reported,
        Some(UpdateState::Installed) | Some(UpdateState::RolledBack)
    ) {
        step(Event::Reported);
    }
    if let Some(release) = answer.release {
        step(Event::Release(verify_release(&release, now)));
    }
    if let Some(order) = answer.order {
        let held = lock().as_ref().and_then(|r| r.state.release.clone());
        step(Event::Order(verify_order(&order, held.as_ref(), now)));
    }
    if let Some(hint) = answer.hint {
        step(Event::Hint(hint));
    }
}

/// `sense.update` for the next heartbeat; `None` while the engine is not running.
pub fn heartbeat_status() -> Option<UpdateStatus> {
    let mut guard = lock();
    let runner = guard.as_mut()?;
    runner.reported = Some(runner.state.phase);
    let sign = cfg!(windows).then_some(SignKind::Unsigned);
    Some(runner.state.status(now_s(), sign))
}

pub fn gui_status() -> Option<GuiStatus> {
    let guard = lock();
    let runner = guard.as_ref()?;
    Some(runner.state.gui_status(super::current_version(), runner.checked_at))
}

/// "Güncelle": checked and started under one lock, so the answer matches what happens.
pub fn request_install(version: u32) -> String {
    let mut guard = lock();
    let Some(runner) = guard.as_mut() else {
        return super::UNSUPPORTED.to_owned();
    };
    let ctx = runner.ctx(true);
    if let Err(code) = engine::check_install(&runner.state, version, &ctx) {
        return code.to_owned();
    }
    runner.advance(Event::InstallRequested { version }, &ctx);
    engine::INSTALL_ACCEPTED.to_owned()
}

/// Main IPC channel in the process that holds the engine.
pub fn on_ipc(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    match message {
        SenseUpdateIpc::StatusQuery => {
            let status = gui_status()?;
            serde_json::to_string(&status)
                .ok()
                .map(SenseUpdateIpc::Status)
        }
        SenseUpdateIpc::InstallRequest { version } => {
            Some(SenseUpdateIpc::InstallAnswer(request_install(version)))
        }
        _ => None,
    }
}
