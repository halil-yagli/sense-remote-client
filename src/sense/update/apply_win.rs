//! Sense Remote (update plan 2026-11-21, §4.4, §5, §8): installing and rolling back on Windows.
//! Package U3. Runs as SYSTEM (`--server`, the guard) or elevated (`--sense-upgrade-local`).
//!
//! `install` (§4.4):
//! 1. HKLM `Update`: `State=installing`, `From`, `FromId`, `FromKeyHash`, `StartedAt`.
//! 2. Installation folder → `C:\ProgramData\SenseRemote\update\prev\` (robocopy).
//! 3. Guard task `GUARD_TASK`: SYSTEM, at start-up and every minute,
//!    `prev\SenseRemote.exe --sense-update-guard`.
//! 4. Upstream's path: copy and verify the file once more
//!    (`copy_and_verify_update_file_sha256`), then
//!    `launch_privileged_process(session, "\"<verified copy>\" --update")` (`updater.rs`),
//!    which ends in `update_me`. The installed exe stays `SenseRemote.exe`, so the setup wizard
//!    does not open. Upstream code is called, not copied.
//!
//! `roll_back` (§5.2): `sc stop`, `taskkill` (only `SenseRemote.exe`), `prev\` → installation
//! folder (robocopy `/MIR`, program files only), `sc start`, `State=rolled_back`, `LastError`.
//!
//! `self_check` (§5.3), at the start of `--server` when `State=installing` and `Target` is this
//! build's version: a role is installed, the RustDesk ID equals `FromId`, the device key hash
//! equals `FromKeyHash`, `API_SERVER` is the build's. All good → `HealthyAt`, `State=installed`,
//! HKLM `Version`; otherwise `State=unhealthy` + `identity_changed`. An update never calls
//! `enroll`.
//!
//! Rules: every path in a command line is a constant or a verified path, quoted; the update
//! folder has an ACL for SYSTEM + Administrators only and reparse points are refused; never
//! during an active connection (the engine checks, `install` checks again).
//!
//! Compiled on every platform; the Windows code is `cfg(windows)` (U3), elsewhere and in U0
//! the functions answer "unsupported".

use super::{InstallJob, UpdateError};
use std::path::PathBuf;

/// Name of the guard's scheduled task.
pub const GUARD_TASK: &str = "SenseRemoteUpdateGuard";

/// The privileged folder downloads go to; `None` when it can not be made safe. U0: none.
pub fn download_dir() -> Option<PathBuf> {
    None
}

/// Backup, guard, then the installation. Returns once the installer was started: this process
/// is about to be stopped by it. U0: nothing is installed.
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

/// `--sense-upgrade-local` (§8): the elevated step of the manual move from version 2, started
/// by `manual::upgrade_in_place` from the new setup file. Same backup + guard + `update_me`
/// path with `source = manual`; no sign-in, no registration. `args` are the arguments after
/// the flag. Returns the exit code (0 = started). Outside Windows it returns 1 at once,
/// whatever the arguments (`core_main` routes the flag here on every platform).
/// U0: 1 on Windows too, nothing is done.
pub fn upgrade_local(args: &[String]) -> i32 {
    if !cfg!(windows) {
        return 1;
    }
    let _ = args;
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    // Outside Windows the flag never does anything (U3 keeps this when it fills in Windows).
    #[cfg(not(windows))]
    #[test]
    fn upgrade_local_is_windows_only() {
        let args = |list: &[&str]| list.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>();
        assert_eq!(upgrade_local(&[]), 1);
        assert_eq!(upgrade_local(&args(&["SenseRemote-Kurulum-3.exe"])), 1);
        let cli = args(&[crate::sense::update::ARG_UPGRADE_LOCAL, "x"]);
        assert_eq!(crate::sense::update::run_cli(&cli), Some(1));
    }

    // U0: the platform side does nothing.
    #[test]
    fn skeleton_installs_nothing() {
        let job = InstallJob {
            file: PathBuf::from("SenseRemote-Kurulum-4.exe"),
            version: 4,
            sha256: "00".repeat(32),
            size: 1,
            source: crate::sense::update::UpdateSource::Local,
            oid: None,
        };
        assert_eq!(install(&job), Err(UpdateError::Unsupported));
        assert_eq!(roll_back(), Err(UpdateError::Unsupported));
        assert_eq!(download_dir(), None);
        assert_eq!(upgrade_local(&[]), 1);
    }
}
