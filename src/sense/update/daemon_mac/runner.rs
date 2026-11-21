//! Sense Remote (update plan 2026-11-21, package U4): the macOS-only part of `daemon_mac`.

use super::*;
use crate::sense::update::{
    apply, current_version, download, engine::{Action, Ctx}, keys, sign_mac, store,
    InstallJob, UpdateError, UpdateSource, UpdateState,
};
use crate::sense::mac_apply::CallLimiter;
use hbb_common::{libc, log};
use std::{
    path::PathBuf,
    sync::{mpsc, Mutex, OnceLock},
    time::{Duration, Instant},
};

struct Daemon {
    held: Held,
    state: engine::State,
    limiter: CallLimiter,
    clock: Instant,
    checked_at: Option<i64>,
    /// The downloaded installer, once `download::fetch` returned it.
    file: Option<PathBuf>,
    events: Option<mpsc::Sender<Event>>,
}

fn daemon() -> std::sync::MutexGuard<'static, Daemon> {
    static DAEMON: OnceLock<Mutex<Daemon>> = OnceLock::new();
    DAEMON
        .get_or_init(|| {
            Mutex::new(Daemon {
                held: Held::default(),
                state: engine::State::default(),
                limiter: CallLimiter::default(),
                clock: Instant::now(),
                checked_at: None,
                file: None,
                events: None,
            })
        })
        .lock()
        .unwrap_or_else(|err| err.into_inner())
}

fn now_s() -> i64 {
    hbb_common::get_time() / 1000
}

fn is_root() -> bool {
    // SAFETY: geteuid has no arguments and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

fn send(event: Event) {
    if let Some(events) = &daemon().events {
        let _ = events.send(event);
    }
}

pub fn start() {
    if !is_root() {
        return;
    }
    let (tx, rx) = mpsc::channel();
    daemon().events = Some(tx);
    let spawned = std::thread::Builder::new()
        .name("sense-update".to_owned())
        .spawn(move || work(rx));
    if let Err(err) = spawned {
        log::error!("Sense Remote: update worker not started: {err}");
    }
}

pub fn on_service_ipc(message: SenseUpdateIpc, peer_pid: Option<u32>) -> Option<SenseUpdateIpc> {
    if !is_root() {
        return None;
    }
    let iss = crate::sense::envelope::expected_issuer();
    let did = hbb_common::config::Config::get_id();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let installed = store::installed_version();
    let ctx = DaemonCtx {
        panel_keys: keys::panel_keys(),
        build_keys: keys::release_keys(),
        iss: &iss,
        api_server: crate::sense::API_SERVER,
        platform: crate::sense::report::platform(),
        did: &did,
        duuid: &duuid,
        now_s: now_s(),
        installed,
    };
    let mut daemon = daemon();
    let now_ms = daemon.clock.elapsed().as_millis().min(u64::MAX as u128) as u64;
    // A peer without a readable pid shares one slot.
    let allowed = daemon.limiter.allow(peer_pid.unwrap_or(0), now_ms);
    let events = handle(&message, allowed, &ctx, &mut daemon.held)?;
    if matches!(message, SenseUpdateIpc::Offer { .. }) {
        daemon.checked_at = Some(ctx.now_s);
    }
    if let Some(sender) = &daemon.events {
        for event in events {
            let _ = sender.send(event);
        }
    }
    Some(SenseUpdateIpc::DaemonStatus(status_json(&daemon)))
}

fn status_json(daemon: &Daemon) -> String {
    let stored = store::read().ok().flatten();
    let warning = permission_warning(crate::sense::installed_role(), sign_mac::sign_kind());
    let status = gui_status(
        &daemon.state,
        current_version(),
        daemon.checked_at,
        warning,
        stored.as_ref(),
    );
    serde_json::to_string(&status).unwrap_or_default()
}

/// Phases in which the engine asks whether the computer is idle.
fn needs_idle(phase: UpdateState) -> bool {
    matches!(
        phase,
        UpdateState::Scheduled
            | UpdateState::WaitingIdle
            | UpdateState::Downloading
            | UpdateState::Verifying
    )
}

fn work(rx: mpsc::Receiver<Event>) {
    if let Err(err) = apply::self_check() {
        log::error!("Sense Remote: self-check: {}", err.as_str());
    }
    let mut idle_since: Option<Instant> = None;
    loop {
        let event = match rx.recv_timeout(Duration::from_millis(TICK_MS)) {
            Ok(event) => event,
            Err(mpsc::RecvTimeoutError::Timeout) => Event::Tick,
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        };
        let phase = daemon().state.phase;
        // Asked only when it matters: the check talks to every session's agent.
        if event == Event::Tick {
            idle_since = if needs_idle(phase) && crate::updater::has_no_active_conns_ipc() {
                idle_since.or_else(|| Some(Instant::now()))
            } else {
                None
            };
        }
        let ctx = Ctx {
            now_s: now_s(),
            local_hour: local_hour(),
            installed: store::installed_version(),
            idle_s: idle_since.map_or(0, |since| since.elapsed().as_secs()),
            // Only once there is something to download (the call creates the folder).
            free_bytes: if phase == UpdateState::Idle {
                None
            } else {
                apply::download_dir().and_then(|dir| free_bytes(&dir))
            },
            jitter_s: jitter(),
        };
        let actions = {
            let mut daemon = daemon();
            let state = std::mem::take(&mut daemon.state);
            let (state, actions) = engine::next(state, event, &ctx);
            daemon.state = state;
            actions
        };
        for action in actions {
            perform(action);
        }
    }
}

fn local_hour() -> u8 {
    use hbb_common::chrono::Timelike;
    hbb_common::chrono::Local::now().hour() as u8
}

fn jitter() -> u64 {
    use hbb_common::rand::Rng;
    hbb_common::rand::thread_rng().gen_range(0..=engine::MAX_JITTER_S)
}

fn free_bytes(dir: &std::path::Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    // SAFETY: `path` is NUL-terminated and lives across the call; `stat` is plain data.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    Some((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
}

fn perform(action: Action) {
    match action {
        Action::Download => run_download(),
        Action::Verify => run_verify(),
        Action::Install => run_install(),
        Action::DropFile => {
            if let Some(file) = daemon().file.take() {
                let _ = std::fs::remove_file(file);
            }
        }
        Action::Persist => run_persist(),
    }
}

fn run_download() {
    let release = daemon().state.release.clone();
    let (Some(release), Some(dir)) = (release, apply::download_dir()) else {
        send(Event::Failed(UpdateError::DownloadFailed));
        return;
    };
    let request = download::Request {
        url: release.url.clone(),
        sha256: release.sha256.clone(),
        size: release.size,
        dir,
        file: release.file.clone(),
    };
    let progress = |pct: u8| daemon().state.progress_pct = Some(pct);
    let result = match hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime.block_on(download::fetch(&request, &progress)),
        Err(_) => Err(UpdateError::DownloadFailed),
    };
    match result {
        Ok(file) => {
            daemon().file = Some(file);
            send(Event::Downloaded);
        }
        Err(error) => send(Event::Failed(error)),
    }
}

/// Size and SHA-256 once more, on the file in the root folder.
fn run_verify() {
    let release = daemon().state.release.clone();
    let file = daemon().file.clone();
    let (Some(release), Some(file)) = (release, file) else {
        send(Event::Failed(UpdateError::DownloadFailed));
        return;
    };
    send(match file_matches(&file, release.size, &release.sha256) {
        Ok(()) => Event::Verified,
        Err(error) => Event::Failed(error),
    });
}

fn file_matches(file: &std::path::Path, size: u64, sha256: &str) -> Result<(), UpdateError> {
    use hbb_common::sha2::{Digest, Sha256};
    use std::io::Read;
    let meta = std::fs::symlink_metadata(file).map_err(|_| UpdateError::DownloadFailed)?;
    if !meta.is_file() || meta.len() != size {
        return Err(UpdateError::SizeMismatch);
    }
    let mut reader = std::fs::File::open(file).map_err(|_| UpdateError::DownloadFailed)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|_| UpdateError::DownloadFailed)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    if hex::encode(hasher.finalize()) == sha256.to_ascii_lowercase() {
        Ok(())
    } else {
        Err(UpdateError::HashMismatch)
    }
}

fn run_install() {
    let (release, order, source, file) = {
        let daemon = daemon();
        (
            daemon.state.release.clone(),
            daemon.state.order.clone(),
            daemon.state.source,
            daemon.file.clone(),
        )
    };
    let (Some(release), Some(file)) = (release, file) else {
        send(Event::Failed(UpdateError::InstallFailed));
        return;
    };
    let job = InstallJob {
        file,
        version: release.version,
        sha256: release.sha256.clone(),
        size: release.size,
        source: source.unwrap_or(UpdateSource::Local),
        oid: order.map(|order| order.oid),
    };
    if let Err(error) = apply::install(&job) {
        send(Event::Failed(error));
    }
}

/// The engine's state into `update.json`. A record the guard is watching (`installing`,
/// `unhealthy`) is never overwritten from here.
fn run_persist() {
    let stored = match store::read() {
        Ok(stored) => stored,
        Err(err) => {
            log::error!("Sense Remote: update state not readable: {err}");
            return;
        }
    };
    if let Some(stored) = &stored {
        if matches!(stored.state, StoredState::Installing | StoredState::Unhealthy) {
            return;
        }
    }
    let state = daemon().state.clone();
    let Some(mut record) = stored.or_else(|| {
        serde_json::from_str::<Persisted>(r#"{"state":"idle"}"#).ok()
    }) else {
        return;
    };
    record.state = match StoredState::parse(state.phase.as_str()) {
        Some(phase) => phase,
        None => return,
    };
    record.target = state.release.as_ref().map(|release| release.version);
    record.source = state.source;
    record.oid = state.order.as_ref().map(|order| order.oid.clone());
    record.attempts = state.attempts;
    record.last_error = state.error;
    if let Err(err) = store::write(&record) {
        log::error!("Sense Remote: update state not written: {err}");
    }
}
