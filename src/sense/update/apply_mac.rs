//! Sense Remote (update plan 2026-11-21, §4.4, §5): installing and rolling back on macOS.
//! Package U4. Runs as root only (the daemon, the guard).
//!
//! `install` (§4.4):
//! 1. `update.json`: `State=installing`, `Target`, `From`, `FromId`, `FromKeyHash`, `StartedAt`.
//! 2. `/Applications/SenseRemote.app` → `/Library/Application Support/SenseRemote/update/prev/`
//!    (`ditto`), handed to root (`chown -R root:wheel`, `chmod -R go-w`): root runs the guard
//!    from it.
//! 3. Guard launchd job `GUARD_LABEL`: root, `RunAtLoad` + `StartInterval 60`,
//!    `prev/.../MacOS/service --sense-update-guard`.
//! 4. `platform::macos::sense_update_from_dmg_as_root`: upstream's `copy_and_verify_dmg_file`,
//!    the mounted bundle's `SenseRemoteVersion` must equal the job's version (otherwise
//!    `version_mismatch`), then upstream's transactional `update_from_dmg_as_root`, which also
//!    puts the bundle under root ownership (G4-1). Upstream code is called, not copied.
//!
//! A failure before step 4 started the swap undoes 1–3 (guard removed, `State=failed`), so the
//! guard never rolls back an installation that did not happen.
//!
//! `roll_back` (§5.2): new bundle → `*.failed-update`, `prev` → `/Applications` (`ditto`),
//! `chown -R root:wheel` + `chmod -R go-w`, daemon and agents `kickstart -k`,
//! `State=rolled_back`. The `*.failed-update` copy is removed after a good rollback: upstream
//! refuses every later update while it exists. A rollback that fails writes `State=failed` +
//! `rollback_failed` (the guard then stops instead of trying again every minute).
//!
//! `self_check` (§5.3), at the start of the daemon when `State=installing` and `Target` is this
//! build's version: a role is installed, the RustDesk ID equals `FromId`, the device key hash
//! equals `FromKeyHash`, `API_SERVER` is the build's, `state.json` is readable. All good →
//! `HealthyAt`, `State=installed`; otherwise `State=unhealthy` + `identity_changed`.
//!
//! The decisions and texts (`self_check_verdict`, `guard_plist`, `swap_back`) are plain functions
//! over values and paths, tested on every platform (`swap_back` on macOS, it uses `ditto`).
//! MAC-SONRA: permissions after an update and App Management (macOS 13+ may refuse the change
//! of `/Applications`; then `install_failed`, §7.4) are checked on a device (§14, M-U6).

use super::{
    store::{Persisted, StoredState},
    InstallJob, UpdateError,
};
use std::path::{Path, PathBuf};

/// Label of the guard's launchd job.
pub const GUARD_LABEL: &str = "com.sensedepartment.remote.update-guard";
/// Everything the updater keeps (root 0755 inside the root-owned state directory).
pub const UPDATE_DIR: &str = "/Library/Application Support/SenseRemote/update";
/// Copy of the old version, inside `UPDATE_DIR`.
pub const PREV_DIR_NAME: &str = "prev";
/// Download folder inside `UPDATE_DIR`, root 0700.
pub const DOWNLOAD_DIR_NAME: &str = "dl";
/// Suffix of the bundle that failed (upstream's name for the same thing).
pub const FAILED_SUFFIX: &str = ".failed-update";

/// Where downloads go (the privileged folder), path only: no file system work. `None` outside
/// macOS.
pub fn download_dir_path() -> Option<PathBuf> {
    if cfg!(target_os = "macos") {
        Some(Path::new(UPDATE_DIR).join(DOWNLOAD_DIR_NAME))
    } else {
        None
    }
}

/// Makes `download_dir_path()` safe (root 0755 `update`, root 0700 `dl`, no symlink, checked
/// with `folder_ok`) and returns it; called once per download. `None` when it can not be made
/// safe.
pub fn prepare_download_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let update = Path::new(UPDATE_DIR);
        match private_dir(update, 0o755).and_then(|()| {
            let dl = update.join(DOWNLOAD_DIR_NAME);
            private_dir(&dl, 0o700).map(|()| dl)
        }) {
            Ok(dir) => Some(dir),
            Err(err) => {
                hbb_common::log::error!("Sense Remote: update folder not usable: {err}");
                None
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Pure rule for the updater's folders: a real directory (no symlink), root's, and nobody but
/// root may write (`dl` also nobody may read: `max_mode` 0700).
pub fn folder_ok(is_symlink: bool, is_dir: bool, uid: u32, mode: u32, max_mode: u32) -> bool {
    !is_symlink && is_dir && uid == 0 && mode & 0o777 & !max_mode == 0
}

/// Creates `dir` with `mode` when missing, then checks it with `folder_ok`.
#[cfg(target_os = "macos")]
fn private_dir(dir: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    match std::fs::symlink_metadata(dir) {
        Ok(_) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new()
                .mode(mode)
                .create(dir)
                .map_err(|err| format!("create {}: {err}", dir.display()))?;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(mode))
                .map_err(|err| format!("chmod: {err}"))?;
            run("/usr/sbin/chown", &["-h", "root:wheel", &*dir.to_string_lossy()])?;
        }
        Err(err) => return Err(format!("stat: {err}")),
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|err| format!("stat: {err}"))?;
    let kind = meta.file_type();
    if folder_ok(kind.is_symlink(), kind.is_dir(), meta.uid(), meta.mode(), mode) {
        Ok(())
    } else {
        Err(format!("{} breaks the folder rule", dir.display()))
    }
}

/// The guard's launchd job (`/Library/LaunchDaemons/<GUARD_LABEL>.plist`): runs the old
/// version's `service` as root at load and every 60 s. `service` is a constant path inside
/// `UPDATE_DIR`; it is escaped anyway.
pub fn guard_plist(service: &str) -> String {
    let service = service
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{GUARD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{service}</string>
    <string>{}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>UserName</key>
  <string>root</string>
</dict>
</plist>
"#,
        super::ARG_GUARD
    )
}

/// Path of the old version's `service` inside the copy.
pub fn prev_service(update_dir: &Path, app_name: &str) -> PathBuf {
    update_dir
        .join(PREV_DIR_NAME)
        .join(format!("{app_name}.app"))
        .join("Contents/MacOS/service")
}

/// What the store holds once the installation starts.
pub fn installing_record(
    job: &InstallJob,
    stored: Option<&Persisted>,
    from: u32,
    from_id: String,
    from_key_hash: String,
    now_s: i64,
) -> Persisted {
    Persisted {
        state: StoredState::Installing,
        target: Some(job.version),
        from: Some(from),
        from_id: Some(from_id),
        from_key_hash: Some(from_key_hash),
        oid: job.oid.clone(),
        source: Some(job.source),
        // The engine counts attempts; the platform side only keeps them.
        attempts: stored.map_or(0, |stored| stored.attempts),
        last_error: None,
        started_at: Some(now_s),
        healthy_at: None,
    }
}

/// What the new version finds out about itself at start (§5.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelfFacts {
    pub role_installed: bool,
    pub id: String,
    pub key_hash: String,
    pub api_server_ok: bool,
    pub state_json_ok: bool,
}

/// Pure (§5.3): `None` = nothing to check (no installation of this version waiting); otherwise
/// the record to store.
pub fn self_check_verdict(
    stored: &Persisted,
    current: u32,
    facts: &SelfFacts,
    now_s: i64,
) -> Option<Persisted> {
    if stored.state != StoredState::Installing || current == 0 || stored.target != Some(current) {
        return None;
    }
    let healthy = facts.role_installed
        && facts.api_server_ok
        && facts.state_json_ok
        && stored.from_id.as_deref() == Some(facts.id.as_str())
        && !facts.id.is_empty()
        && stored.from_key_hash.as_deref() == Some(facts.key_hash.as_str());
    let mut next = stored.clone();
    if healthy {
        next.state = StoredState::Installed;
        next.healthy_at = Some(now_s);
        next.last_error = None;
    } else {
        next.state = StoredState::Unhealthy;
        next.last_error = Some(UpdateError::IdentityChanged);
    }
    Some(next)
}

/// The record after a rollback: `rolled_back` with the reason the new version failed, or
/// `failed` + `rollback_failed`.
pub fn rolled_back_record(stored: Option<&Persisted>, ok: bool) -> Persisted {
    let mut next = stored.cloned().unwrap_or(Persisted {
        state: StoredState::Idle,
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
    });
    if ok {
        next.state = StoredState::RolledBack;
        if next.last_error.is_none() {
            next.last_error = Some(UpdateError::HealthTimeout);
        }
    } else {
        next.state = StoredState::Failed;
        next.last_error = Some(UpdateError::RollbackFailed);
    }
    next
}

/// File part of the rollback: `app` → `app.failed-update`, `prev_app` → `app` (`ditto`), the
/// failed copy removed. When the copy back fails the failed bundle is put back, so the
/// computer keeps a whole app. `prev_app` stays for a later try.
#[cfg(target_os = "macos")]
pub fn swap_back(app: &Path, prev_app: &Path) -> Result<(), String> {
    let failed = PathBuf::from(format!("{}{FAILED_SUFFIX}", app.display()));
    let prev_meta = std::fs::symlink_metadata(prev_app).map_err(|err| format!("prev: {err}"))?;
    if !prev_meta.is_dir() {
        return Err("prev is not a directory".to_owned());
    }
    // Left by an earlier failed rollback.
    if std::fs::symlink_metadata(&failed).is_ok() {
        std::fs::remove_dir_all(&failed).map_err(|err| format!("remove failed: {err}"))?;
    }
    let moved = match std::fs::symlink_metadata(app) {
        Ok(_) => {
            std::fs::rename(app, &failed).map_err(|err| format!("move new: {err}"))?;
            true
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => false,
        Err(err) => return Err(format!("stat app: {err}")),
    };
    let copied = run(
        "/usr/bin/ditto",
        &[&*prev_app.to_string_lossy(), &*app.to_string_lossy()],
    );
    if let Err(err) = copied {
        let _ = std::fs::remove_dir_all(app);
        if moved {
            let _ = std::fs::rename(&failed, app);
        }
        return Err(err);
    }
    if moved {
        if let Err(err) = std::fs::remove_dir_all(&failed) {
            hbb_common::log::warn!("Sense Remote: failed bundle not removed: {err}");
        }
    }
    Ok(())
}

/// Backup, guard, then the installation. Returns once the installation was started: this
/// process is about to be restarted by it.
pub fn install(job: &InstallJob) -> Result<(), UpdateError> {
    #[cfg(target_os = "macos")]
    {
        mac::install(job)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = job;
        Err(UpdateError::Unsupported)
    }
}

/// Puts the old version back (guard only).
pub fn roll_back() -> Result<(), UpdateError> {
    #[cfg(target_os = "macos")]
    {
        mac::roll_back()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(UpdateError::Unsupported)
    }
}

/// Unregisters the guard; the copy of the old version stays.
pub fn remove_guard() -> Result<(), UpdateError> {
    #[cfg(target_os = "macos")]
    {
        mac::remove_guard()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(UpdateError::Unsupported)
    }
}

/// The new version's check at start (§5.3). `Ok` also when there was nothing to check.
pub fn self_check() -> Result<(), UpdateError> {
    #[cfg(target_os = "macos")]
    {
        mac::self_check()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(())
    }
}

/// Runs a fixed program with arguments (no shell); `Err` with the exit status only.
#[cfg(target_os = "macos")]
fn run(program: &str, args: &[&str]) -> Result<(), String> {
    match std::process::Command::new(program).args(args).output() {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => Err(format!("{program}: {}", output.status)),
        Err(err) => Err(format!("{program}: {err}")),
    }
}

#[cfg(target_os = "macos")]
mod mac;

#[cfg(test)]
mod tests;
