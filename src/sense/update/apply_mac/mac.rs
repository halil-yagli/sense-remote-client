//! Sense Remote (update plan 2026-11-21, package U4): the macOS-only part of `apply_mac`.

use super::*;
use crate::sense::update::{current_version, store, store_mac};
use hbb_common::{config::Config, libc, log};

fn app_name() -> String {
    crate::get_app_name()
}

fn app_bundle() -> PathBuf {
    PathBuf::from(format!("/Applications/{}.app", app_name()))
}

fn prev_app() -> PathBuf {
    Path::new(UPDATE_DIR)
        .join(PREV_DIR_NAME)
        .join(format!("{}.app", app_name()))
}

fn guard_plist_path() -> String {
    format!("/Library/LaunchDaemons/{GUARD_LABEL}.plist")
}

fn now_s() -> i64 {
    hbb_common::get_time() / 1000
}

fn is_root() -> bool {
    // SAFETY: geteuid has no arguments and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

pub fn install(job: &InstallJob) -> Result<(), UpdateError> {
    if !is_root() {
        return Err(UpdateError::InstallFailed);
    }
    // The engine checked; checked again right before anything changes (§3.6).
    if !crate::updater::has_no_active_conns_ipc() {
        return Err(UpdateError::Busy);
    }
    let stored = store::read().map_err(|err| {
        log::error!("Sense Remote: update state not readable, not installing: {err}");
        UpdateError::InstallFailed
    })?;
    let (_, public_key) = Config::get_key_pair();
    let record = installing_record(
        job,
        stored.as_ref(),
        current_version(),
        Config::get_id(),
        store::key_hash(&public_key),
        now_s(),
    );
    store::write(&record).map_err(|err| {
        log::error!("Sense Remote: update state not written: {err}");
        UpdateError::InstallFailed
    })?;
    let started = backup_and_guard().and_then(|()| {
        let file = job.file.to_string_lossy();
        let version = job.version;
        crate::platform::macos::sense_update_from_dmg_as_root(
            &file,
            &job.sha256,
            job.size,
            |found| store_mac::parse_plist_version(found) == Some(version),
        )
        .map_err(|err| {
            log::error!("Sense Remote: installation not started: {err}");
            UpdateError::InstallFailed
        })
        .and_then(|accepted| {
            if accepted {
                Ok(())
            } else {
                log::error!("Sense Remote: bundle version is not {version}");
                Err(UpdateError::VersionMismatch)
            }
        })
    });
    if let Err(error) = started {
        // Nothing was swapped: no guard, no `installing` left for it to roll back.
        let _ = remove_guard();
        let mut failed = record;
        failed.state = StoredState::Failed;
        failed.last_error = Some(error);
        if let Err(err) = store::write(&failed) {
            log::error!("Sense Remote: update state not written: {err}");
        }
        return Err(error);
    }
    log::info!("Sense Remote: installing version {}", job.version);
    Ok(())
}

/// Steps 2 and 3: the old version's copy and the guard that runs from it.
fn backup_and_guard() -> Result<(), UpdateError> {
    let failed = |err: String| {
        log::error!("Sense Remote: backup or guard failed: {err}");
        UpdateError::InstallFailed
    };
    let update = Path::new(UPDATE_DIR);
    private_dir(update, 0o755).map_err(failed)?;
    let prev = update.join(PREV_DIR_NAME);
    if std::fs::symlink_metadata(&prev).is_ok() {
        std::fs::remove_dir_all(&prev).map_err(|err| failed(format!("old prev: {err}")))?;
    }
    private_dir(&prev, 0o755).map_err(failed)?;
    let prev_app = prev_app();
    run(
        "/usr/bin/ditto",
        &[&*app_bundle().to_string_lossy(), &*prev_app.to_string_lossy()],
    )
    .map_err(failed)?;
    let prev_app = prev_app.to_string_lossy();
    run("/usr/sbin/chown", &["-R", "root:wheel", &*prev_app]).map_err(failed)?;
    run("/bin/chmod", &["-R", "go-w", &*prev_app]).map_err(failed)?;

    let service = prev_service(update, &app_name());
    let plist = guard_plist_path();
    // A job left by an earlier update is replaced.
    let _ = remove_guard();
    write_root_file(&plist, guard_plist(&service.to_string_lossy()).as_bytes())
        .map_err(failed)?;
    if !crate::platform::macos::sense_launchctl_ok(&["bootstrap", "system", plist.as_str()]) {
        return Err(failed("guard job not loaded".to_owned()));
    }
    Ok(())
}

/// A new root:wheel 0644 file (the plist); an existing one is replaced, never followed.
fn write_root_file(path: &str, bytes: &[u8]) -> Result<(), String> {
    use std::{
        io::Write,
        os::unix::fs::{OpenOptionsExt, PermissionsExt},
        os::unix::io::AsRawFd,
    };
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => return Err(format!("remove: {err}")),
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|err| format!("create: {err}"))?;
    file.write_all(bytes).map_err(|err| format!("write: {err}"))?;
    file.set_permissions(std::fs::Permissions::from_mode(0o644))
        .map_err(|err| format!("chmod: {err}"))?;
    // SAFETY: the descriptor belongs to `file`, open for the whole call.
    if unsafe { libc::fchown(file.as_raw_fd(), 0, 0) } != 0 {
        return Err(format!("chown: {}", std::io::Error::last_os_error()));
    }
    file.sync_all().map_err(|err| format!("sync: {err}"))
}

pub fn roll_back() -> Result<(), UpdateError> {
    if !is_root() {
        return Err(UpdateError::RollbackFailed);
    }
    let stored = store::read().ok().flatten();
    let app = app_bundle();
    let swapped = swap_back(&app, &prev_app()).and_then(|()| {
        let app = app.to_string_lossy();
        run("/usr/sbin/chown", &["-R", "root:wheel", &*app])?;
        run("/bin/chmod", &["-R", "go-w", &*app])
    });
    let ok = match &swapped {
        Ok(()) => true,
        Err(err) => {
            log::error!("Sense Remote: rollback failed: {err}");
            false
        }
    };
    if let Err(err) = store::write(&rolled_back_record(stored.as_ref(), ok)) {
        log::error!("Sense Remote: update state not written after rollback: {err}");
    }
    if !ok {
        return Err(UpdateError::RollbackFailed);
    }
    restart_services();
    log::info!("Sense Remote: old version put back");
    Ok(())
}

/// Daemon and every session agent start again from the bundle now in `/Applications`.
fn restart_services() {
    let name = app_name();
    let daemon = format!("system/com.carriez.{name}_service");
    if !crate::platform::macos::sense_launchctl_ok(&["kickstart", "-k", daemon.as_str()]) {
        log::error!("Sense Remote: daemon not restarted after rollback");
    }
    for uid in crate::platform::macos::get_logged_in_uids() {
        if uid == 0 {
            continue;
        }
        let agent = format!("gui/{uid}/com.carriez.{name}_server");
        if !crate::platform::macos::sense_launchctl_ok(&["kickstart", "-k", agent.as_str()]) {
            log::warn!("Sense Remote: agent of uid {uid} not restarted after rollback");
        }
    }
}

pub fn remove_guard() -> Result<(), UpdateError> {
    let plist = guard_plist_path();
    match std::fs::remove_file(&plist) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            log::error!("Sense Remote: guard plist not removed: {err}");
            return Err(UpdateError::InstallFailed);
        }
    }
    // Last: when the guard removes itself, this ends its own process.
    let target = format!("system/{GUARD_LABEL}");
    let _ = crate::platform::macos::sense_launchctl_ok(&["bootout", target.as_str()]);
    Ok(())
}

pub fn self_check() -> Result<(), UpdateError> {
    let stored = match store::read() {
        Ok(Some(stored)) => stored,
        Ok(None) => return Ok(()),
        Err(err) => {
            // The guard does nothing on an unreadable store either (§5.2).
            log::error!("Sense Remote: update state not readable at start: {err}");
            return Ok(());
        }
    };
    let (_, public_key) = Config::get_key_pair();
    let facts = SelfFacts {
        role_installed: crate::sense::installed_role().is_some(),
        id: Config::get_id(),
        key_hash: store::key_hash(&public_key),
        api_server_ok: crate::sense::api_server() == crate::sense::API_SERVER,
        state_json_ok: matches!(crate::sense::mac_state::read(), Ok(Some(_))),
    };
    let Some(next) = self_check_verdict(&stored, current_version(), &facts, now_s()) else {
        return Ok(());
    };
    let healthy = next.state == StoredState::Installed;
    store::write(&next).map_err(|err| {
        log::error!("Sense Remote: self-check result not written: {err}");
        UpdateError::InstallFailed
    })?;
    if healthy {
        log::info!("Sense Remote: version {} is healthy", current_version());
        Ok(())
    } else {
        log::error!("Sense Remote: self-check failed, the guard rolls back");
        Err(UpdateError::IdentityChanged)
    }
}
