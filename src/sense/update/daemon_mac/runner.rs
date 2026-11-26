//! Sense Remote (update plan 2026-11-21, package U4): the daemon's runner, the macOS counterpart
//! of `update/runner.rs` (same engine, same jobs, same store rules).
//!
//! - One engine state behind a mutex; every event goes through `engine::next` under the lock
//!   (`step`), the resulting actions become jobs for the runner thread.
//! - The runner thread keeps a deadline for the timer: jobs and events never postpone a tick.
//!   Idle time is measured only there (`has_no_active_conns_ipc` starts its own runtime and
//!   asks every session's agent), and only while the engine waits for an idle computer.
//! - Download, verification and installation run on threads of their own, outside any
//!   runtime; the installation asks once more for an idle computer right before
//!   `apply::install`, which asks again before it changes anything.

use super::*;
use crate::sense::update::{
    apply, current_version, download,
    engine::{self, Action, Ctx, State, MAX_JITTER_S},
    keys, sign_mac, store, InstallJob, UpdateError, UpdateSource, UpdateState,
};
use hbb_common::{config::Config, libc, log};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Mutex, MutexGuard,
    },
    time::{Duration, Instant},
};

/// Timer of the engine (as `runner::TICK_S`).
const TICK: Duration = Duration::from_secs(crate::sense::update::runner::TICK_S);

struct Daemon {
    state: State,
    limiter: PeerLimiter,
    clock: Instant,
    /// Since when no connection is active (Unix s), measured on the timer thread.
    idle_since: Option<i64>,
    /// Last `Offer` (= last heartbeat answer).
    checked_at: Option<i64>,
    /// The phase the last `Offer` answer gave the agent for its heartbeat.
    reported: Option<UpdateState>,
    jobs: mpsc::Sender<Job>,
}

enum Job {
    Persist(State),
    Download(download::Request),
    /// Sense Remote (#68): stop the running download, then remove its `.part` file.
    AbortDownload(PathBuf),
    Verify {
        file: PathBuf,
        sha256: String,
        size: u64,
    },
    Install(InstallJob),
    DropFile(PathBuf),
    Fail(UpdateError),
}

static DAEMON: Mutex<Option<Daemon>> = Mutex::new(None);
/// Sense Remote (#68): number of the current download; a running download stops as soon as it
/// changes ("Vazgeç"), and its thread, so `AbortDownload` can wait for it.
static DOWNLOAD_RUN: AtomicU64 = AtomicU64::new(0);
static DOWNLOAD_THREAD: Mutex<Option<std::thread::JoinHandle<()>>> = Mutex::new(None);
/// How often a running download looks at `DOWNLOAD_RUN`.
const CANCEL_POLL: Duration = Duration::from_millis(200);

fn download_thread() -> MutexGuard<'static, Option<std::thread::JoinHandle<()>>> {
    DOWNLOAD_THREAD.lock().unwrap_or_else(|err| err.into_inner())
}

/// Resolves once download `run` is no longer the current one.
async fn superseded(run: u64) {
    while DOWNLOAD_RUN.load(Ordering::SeqCst) == run {
        hbb_common::tokio::time::sleep(CANCEL_POLL).await;
    }
}

fn lock() -> MutexGuard<'static, Option<Daemon>> {
    DAEMON.lock().unwrap_or_else(|err| err.into_inner())
}

fn now_s() -> i64 {
    crate::sense::update::runner::now_s()
}

fn is_root() -> bool {
    // SAFETY: geteuid has no arguments and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

fn local_hour() -> u8 {
    use hbb_common::chrono::Timelike;
    hbb_common::chrono::Local::now().hour() as u8
}

/// Phases in which the engine waits for an idle computer.
fn needs_idle(phase: UpdateState) -> bool {
    matches!(
        phase,
        UpdateState::Scheduled
            | UpdateState::WaitingIdle
            | UpdateState::Downloading
            | UpdateState::Verifying
    )
}

pub fn start() {
    if !is_root() || !crate::sense::update::SUPPORTED {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("sense-update".to_owned())
        .spawn(|| {
            if let Err(err) = apply::self_check() {
                log::error!("Sense Remote: update self-check failed: {}", err.as_str());
            }
            let (jobs, receiver) = mpsc::channel();
            *lock() = Some(Daemon {
                state: State::restore(&store::read(), now_s()),
                limiter: PeerLimiter::default(),
                clock: Instant::now(),
                idle_since: None,
                checked_at: None,
                reported: None,
                jobs,
            });
            work(receiver);
        });
    if let Err(err) = spawned {
        log::error!("Sense Remote: update runner not started: {err}");
    }
}

fn work(receiver: mpsc::Receiver<Job>) {
    let mut next_tick = Instant::now();
    loop {
        let now = Instant::now();
        if now >= next_tick {
            next_tick = now + TICK;
            measure_idle();
            step(Event::Tick);
            continue;
        }
        match receiver.recv_timeout(next_tick - now) {
            Ok(job) => perform(job),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

/// Outside the lock: the check talks to every session's agent.
fn measure_idle() {
    let phase = match lock().as_ref() {
        Some(daemon) => daemon.state.phase,
        None => return,
    };
    let idle = needs_idle(phase) && crate::updater::has_no_active_conns_ipc();
    if let Some(daemon) = lock().as_mut() {
        if idle {
            daemon.idle_since.get_or_insert(now_s());
        } else {
            daemon.idle_since = None;
        }
    }
}

impl Daemon {
    fn ctx(&self, with_disk: bool) -> Ctx {
        let now = now_s();
        let free_bytes = if with_disk {
            apply::download_dir_path().and_then(|dir| download::free_bytes(&dir))
        } else {
            None
        };
        Ctx {
            now_s: now,
            local_hour: local_hour(),
            installed: current_version(),
            idle_s: self.idle_since.map_or(0, |t| (now - t).max(0) as u64),
            free_bytes,
            jitter_s: hbb_common::rand::random::<u64>() % (MAX_JITTER_S + 1),
        }
    }

    /// Disk space is read only when a download may start (as `runner.rs`).
    fn needs_disk(&self, event: &Event) -> bool {
        matches!(event, Event::InstallRequested { .. } | Event::Order(Ok(_)))
            || matches!(
                self.state.phase,
                UpdateState::Available | UpdateState::Scheduled | UpdateState::WaitingIdle
            ) && self.state.source.is_some()
    }

    fn advance(&mut self, event: Event, ctx: &Ctx) {
        let state = std::mem::take(&mut self.state);
        let before = state.phase;
        let (state, actions) = engine::next(state, event, ctx);
        self.state = state;
        // Sense Remote (S9 P5): phase changes and the reason an update waits, to the log.
        crate::sense::update::wait_log::observe(before, &self.state, ctx.now_s, ctx.idle_s);
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
        let Some(dir) = apply::download_dir_path() else {
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
        // Sense Remote (#68): "Vazgeç", as `runner.rs`.
        if let Action::AbortDownload = action {
            let part = format!("{}{}", release.file, download::PART_SUFFIX);
            return Some(Job::AbortDownload(dir.join(part)));
        }
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
                now: self.state.order.as_ref().is_some_and(|o| o.window == crate::sense::update::order::Window::Now),
            }),
        })
    }
}

fn step(event: Event) {
    let mut guard = lock();
    let Some(daemon) = guard.as_mut() else {
        return;
    };
    let ctx = daemon.ctx(daemon.needs_disk(&event));
    daemon.advance(event, &ctx);
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
        Job::Download(mut request) => {
            // Sense Remote (#68): a new number; an older download (already stopped) ends.
            let run = DOWNLOAD_RUN.fetch_add(1, Ordering::SeqCst) + 1;
            let thread = spawn_thread("sense-update-dl", move || {
                // The folder is made safe (root 0700, no symlink) once per download.
                match apply::prepare_download_dir() {
                    Some(dir) => request.dir = dir,
                    None => {
                        log::error!("Sense Remote: update download folder not safe");
                        step(Event::Failed(UpdateError::DownloadFailed));
                        return;
                    }
                }
                let progress = |pct: u8| step(Event::DownloadProgress(pct));
                let runtime = match hbb_common::tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(_) => {
                        step(Event::Failed(UpdateError::DownloadFailed));
                        return;
                    }
                };
                // Sense Remote (#68): "Vazgeç" drops the download; the engine already went back to
                // "Yeni sürüm hazır", so nothing is reported.
                let result = runtime.block_on(async {
                    hbb_common::tokio::select! {
                        result = download::fetch(&request, &progress) => Some(result),
                        _ = superseded(run) => None,
                    }
                });
                match result {
                    Some(Ok(_)) => step(Event::Downloaded),
                    Some(Err(err)) => step(Event::Failed(err)),
                    None => {}
                }
            });
            *download_thread() = thread;
        }
        // Sense Remote (#68): stop the download and wait for its thread (here, so a new
        // download cannot start before the old `.part` file is gone), then remove the file.
        Job::AbortDownload(part) => {
            DOWNLOAD_RUN.fetch_add(1, Ordering::SeqCst);
            if let Some(thread) = download_thread().take() {
                let _ = thread.join();
            }
            crate::sense::update::cancel_log::removed(std::fs::remove_file(&part));
        }
        Job::Verify { file, sha256, size } => spawn("sense-update-verify", move || {
            step(match download::verify_file(&file, size, &sha256) {
                Ok(()) => Event::Verified,
                Err(err) => Event::Failed(err),
            });
        }),
        Job::Install(job) => spawn("sense-update-install", move || {
            // Sense Remote: a `now` order tells the open sessions, then lifts the check.
            if job.now {
                crate::sense::update::now::prepare();
            }
            // Never during a connection: asked once more right before the installer.
            if !crate::updater::has_no_active_conns_ipc() {
                step(Event::Failed(UpdateError::Busy));
                return;
            }
            log::info!("Sense Remote: installing update {}", job.version);
            if let Err(err) = apply::install(&job) {
                step(Event::Failed(err));
            }
        }),
        Job::DropFile(path) => {
            let _ = std::fs::remove_file(path);
        }
        Job::Fail(err) => step(Event::Failed(err)),
    }
}

fn spawn(name: &str, work: impl FnOnce() + Send + 'static) {
    let _ = spawn_thread(name, work);
}

fn spawn_thread(
    name: &str,
    work: impl FnOnce() + Send + 'static,
) -> Option<std::thread::JoinHandle<()>> {
    match std::thread::Builder::new().name(name.to_owned()).spawn(work) {
        Ok(thread) => Some(thread),
        Err(err) => {
            log::error!("Sense Remote: {name} not started: {err}");
            step(Event::Failed(UpdateError::InstallFailed));
            None
        }
    }
}

pub fn on_service_ipc(
    message: SenseUpdateIpc,
    peer_pid: Option<u32>,
    peer_uid: Option<u32>,
) -> Option<SenseUpdateIpc> {
    if !is_root() {
        return None;
    }
    let iss = crate::sense::envelope::expected_issuer();
    let did = Config::get_id();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let now = now_s();
    let mut guard = lock();
    let daemon = guard.as_mut()?;
    let now_ms = daemon.clock.elapsed().as_millis().min(u64::MAX as u128) as u64;
    let allowed = daemon.limiter.allow(peer_pid, peer_uid, now_ms);
    let ctx = DaemonCtx {
        panel_keys: keys::panel_keys(),
        build_keys: keys::release_keys(),
        iss: &iss,
        api_server: crate::sense::API_SERVER,
        platform: crate::sense::report::platform(),
        did: &did,
        duuid: &duuid,
        now_s: now,
        installed: current_version(),
    };
    let held = daemon.state.release.clone();
    match classify(&message, allowed, &ctx, held.as_ref())? {
        Call::Offer(events) => {
            daemon.checked_at = Some(now);
            // The status given with the previous answer went out with the heartbeat that
            // brought this one.
            if matches!(
                daemon.reported.take(),
                Some(UpdateState::Installed | UpdateState::RolledBack)
            ) {
                let ctx = daemon.ctx(false);
                daemon.advance(Event::Reported, &ctx);
            }
            for event in events {
                let ctx = daemon.ctx(daemon.needs_disk(&event));
                daemon.advance(event, &ctx);
            }
            daemon.reported = Some(daemon.state.phase);
            let status = daemon.state.status(now, Some(sign_mac::sign_kind()));
            serde_json::to_string(&status)
                .ok()
                .map(SenseUpdateIpc::DaemonStatus)
        }
        Call::Install(version) => {
            let ctx = daemon.ctx(true);
            let code = match engine::check_install(&daemon.state, version, &ctx) {
                Ok(()) => {
                    daemon.advance(Event::InstallRequested { version }, &ctx);
                    engine::INSTALL_ACCEPTED
                }
                Err(code) => code,
            };
            Some(SenseUpdateIpc::InstallAnswer(code.to_owned()))
        }
        // Sense Remote (#68): checked and done under one lock, as `runner::request_cancel`.
        Call::Cancel => {
            let code = match engine::check_cancel(&daemon.state) {
                Ok(()) => {
                    let ctx = daemon.ctx(false);
                    daemon.advance(Event::CancelRequested, &ctx);
                    engine::CANCEL_ACCEPTED
                }
                Err(code) => code,
            };
            Some(SenseUpdateIpc::CancelAnswer(code.to_owned()))
        }
        Call::Status => {
            let warning =
                permission_warning(crate::sense::installed_role(), sign_mac::sign_kind());
            let status = daemon
                .state
                .gui_status(current_version(), daemon.checked_at);
            serde_json::to_string(&with_warning(status, warning))
                .ok()
                .map(SenseUpdateIpc::DaemonStatus)
        }
    }
}
