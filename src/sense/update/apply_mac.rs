//! Sense Remote (update plan 2026-11-21, §4.4, §5): installing and rolling back on macOS.
//! Package U4. Runs as root only (the daemon, the guard).
//!
//! `install` (§4.4):
//! 1. `/Applications/SenseRemote.app` → `/Library/Application Support/SenseRemote/update/prev/`
//!    (`ditto`).
//! 2. Guard launchd job `GUARD_LABEL`: root, `RunAtLoad` + `StartInterval 60`,
//!    `prev/.../MacOS/service --sense-update-guard`.
//! 3. The dmg is verified (`copy_and_verify_dmg_file`); `SenseRemoteVersion` of the mounted
//!    bundle must equal the release's version, otherwise `version_mismatch`.
//! 4. Upstream's transactional `update_from_dmg_as_root` (`platform/macos.rs`), which also puts
//!    the bundle under root ownership (G4-1). Upstream code is called, not copied.
//!
//! `roll_back` (§5.2): new bundle → `*.failed-update`, `prev` → `/Applications` (`ditto`),
//! `chown -R root:wheel` + `chmod -R go-w`, daemon and agent `kickstart -k`,
//! `State=rolled_back`.
//!
//! `self_check` (§5.3), at the start of the daemon when `State=installing` and `Target` is this
//! build's version: as on Windows, plus `state.json` must be readable.
//!
//! App Management (macOS 13+) may refuse the change of `/Applications`: reported as
//! `install_failed` with `error_detail = app_management` (§7.4).
//!
//! Compiled on every platform; the macOS code is `cfg(target_os = "macos")` (U4).
//! MAC-SONRA: permissions after an update and App Management are checked on a device (§14).

use super::{InstallJob, UpdateError};
use std::path::PathBuf;

/// Label of the guard's launchd job.
pub const GUARD_LABEL: &str = "com.sensedepartment.remote.update-guard";

/// The privileged folder downloads go to (root 0700); `None` when it can not be made safe.
/// U0: none.
pub fn download_dir() -> Option<PathBuf> {
    None
}

/// Backup, guard, then the installation. Returns once the installation was started: this
/// process is about to be restarted by it. U0: nothing is installed.
pub fn install(job: &InstallJob) -> Result<(), UpdateError> {
    let _ = job;
    Err(UpdateError::Unsupported)
}

/// Puts the old version back (guard only). U0: nothing.
pub fn roll_back() -> Result<(), UpdateError> {
    Err(UpdateError::Unsupported)
}

/// Unregisters the guard; the copy of the old version stays. U0: nothing.
pub fn remove_guard() -> Result<(), UpdateError> {
    Err(UpdateError::Unsupported)
}

/// The new version's check at start (§5.3). `Ok` also when there was nothing to check.
/// U0: nothing is checked or written.
pub fn self_check() -> Result<(), UpdateError> {
    Ok(())
}
