//! Sense Remote (update plan 2026-11-21, §4.4, §5, §8): installing and rolling back on Windows.
//! Package U3. Runs as SYSTEM (`--server`, the guard) or elevated (`--sense-upgrade-local`).
//!
//! `install` (§4.4):
//! 1. HKLM `Update`: `State=installing`, `Target`, `From`, `FromId`, `FromKeyHash`, `StartedAt`.
//! 2. Installation folder → `C:\ProgramData\SenseRemote\update\prev\` (robocopy `/MIR /XJ`).
//! 3. Guard task `GUARD_TASK`: SYSTEM, at start-up and every minute,
//!    `prev\SenseRemote.exe --sense-update-guard`.
//! 4. Upstream's path: copy and verify the file once more
//!    (`copy_and_verify_update_file_sha256`), then
//!    `launch_privileged_process(session, "\"<verified copy>\" --update")` (as `updater.rs`),
//!    which ends in `update_me`. `update_me` renames the program to `SenseRemote.exe`, so the
//!    setup wizard does not open, and it never calls `enroll`: ID, device key and role (HKLM,
//!    the service profile) are outside the copied folder. Upstream code is called, not copied.
//!
//! `roll_back` (§5.2): `sc stop`, `taskkill` (only `SenseRemote.exe`, never the guard itself),
//! `prev\` → installation folder (robocopy `/MIR /XJ`, program files only), HKLM `Version` back to
//! `From`, `State=rolled_back`, `sc start`. When the copy fails the state stays and the guard
//! tries again a minute later (`LastError=rollback_failed`).
//!
//! `self_check` (§5.3), at the start of `--server` when `State=installing` and `Target` is this
//! build's version: a role is installed, the RustDesk ID equals `FromId`, the device key hash
//! equals `FromKeyHash`, `API_SERVER` is the build's. All good → `HealthyAt`, `State=installed`,
//! HKLM `Version`; otherwise `State=unhealthy` + `identity_changed` and the guard rolls back.
//!
//! Rules: every path in a command line is a constant or a checked path (absolute, none of
//! `" % CR LF NUL`), passed as its own argument or quoted; `C:\ProgramData\SenseRemote` gets an
//! ACL for SYSTEM + Administrators only (owner Administrators, inheritance cut) and reparse
//! points are refused on every level; never during an active connection (the engine checks,
//! `install` checks again right before the installer starts).
//!
//! The command lines, the task XML and the self-check decision are pure and tested on every
//! platform; what runs them is `cfg(windows)`. Elsewhere the functions answer "unsupported".

use super::{
    store::{Persisted, StoredState},
    InstallJob, UpdateError, ARG_GUARD,
};
use std::path::{Path, PathBuf};

/// Name of the guard's scheduled task.
pub const GUARD_TASK: &str = "SenseRemoteUpdateGuard";
/// The installed program's file name (`update_me` renames to it; not a setup name, §4.4).
pub const INSTALLED_EXE: &str = "SenseRemote.exe";
/// Service name (`crate::get_app_name()` of the installed program).
pub const SERVICE: &str = "SenseRemote";

/// `upgrade_local` exit codes (U7 maps them to `manual::*`).
pub const UPGRADE_OK: i32 = 0;
pub const UPGRADE_FAILED: i32 = 1;
pub const UPGRADE_NOT_INSTALLED: i32 = 2;
pub const UPGRADE_NOT_NEWER: i32 = 3;
pub const UPGRADE_NOT_ELEVATED: i32 = 4;

/// Characters a path in a command line, a quoted command or the task XML must not hold.
const UNSAFE_PATH_CHARS: &[char] = &['"', '%', '\r', '\n', '\0'];

/// `<ProgramData>\SenseRemote`: the folder whose ACL `secure_tree` sets.
pub fn sense_data_dir(program_data: &Path) -> PathBuf {
    program_data.join("SenseRemote")
}

/// `<ProgramData>\SenseRemote\update`.
pub fn update_dir(program_data: &Path) -> PathBuf {
    sense_data_dir(program_data).join("update")
}

/// Copy of the old installation (what a rollback restores; the guard runs from it).
pub fn prev_dir(program_data: &Path) -> PathBuf {
    update_dir(program_data).join("prev")
}

/// Downloads (`download.rs`).
pub fn dl_dir(program_data: &Path) -> PathBuf {
    update_dir(program_data).join("dl")
}

/// Manual move from version 2 only: copy of the NEW program the guard runs from, because the
/// old version 2 has no `--sense-update-guard`.
pub fn guard_dir(program_data: &Path) -> PathBuf {
    update_dir(program_data).join("guard")
}

/// Absolute, valid UTF-8 and none of `UNSAFE_PATH_CHARS`.
pub fn is_safe_path(path: &Path) -> bool {
    let absolute = path.is_absolute() || path.to_str().is_some_and(|p| p.starts_with("C:\\"));
    absolute
        && path
            .to_str()
            .is_some_and(|p| !p.is_empty() && !p.contains(UNSAFE_PATH_CHARS))
}

/// The command `launch_privileged_process` gets: `"<verified copy>" --update`.
pub fn update_command_line(exe: &Path) -> Option<String> {
    is_safe_path(exe).then(|| format!("\"{}\" --update", exe.to_str().unwrap_or_default()))
}

/// robocopy mirror of program files: junctions are not followed (`/XJ`), a few retries for
/// files still closing.
pub fn robocopy_args(from: &Path, to: &Path) -> Vec<String> {
    let path = |p: &Path| p.to_string_lossy().trim_end_matches('\\').to_owned();
    [
        path(from),
        path(to),
        "/MIR".to_owned(),
        "/XJ".to_owned(),
        "/R:5".to_owned(),
        "/W:2".to_owned(),
        "/NP".to_owned(),
        "/NFL".to_owned(),
        "/NDL".to_owned(),
    ]
    .to_vec()
}

/// robocopy exit codes 0–7 mean the copy is complete; 8 and up are failures.
pub fn robocopy_succeeded(code: Option<i32>) -> bool {
    matches!(code, Some(0..=7))
}

/// icacls runs, in order, for `<ProgramData>\SenseRemote`: owner Administrators (whole tree),
/// drop explicit entries (whole tree), cut inheritance and allow only SYSTEM and Administrators.
/// `/L` acts on a link itself, never on its target.
pub fn icacls_runs(dir: &Path) -> Vec<Vec<String>> {
    let dir = dir.to_string_lossy().trim_end_matches('\\').to_owned();
    let run = |args: &[&str]| {
        std::iter::once(dir.clone())
            .chain(args.iter().map(|a| (*a).to_owned()))
            .collect::<Vec<_>>()
    };
    vec![
        run(&["/setowner", "*S-1-5-32-544", "/T", "/L", "/Q"]),
        run(&["/reset", "/T", "/L", "/Q"]),
        run(&[
            "/inheritance:r",
            "/grant:r",
            "*S-1-5-18:(OI)(CI)F",
            "*S-1-5-32-544:(OI)(CI)F",
            "/L",
            "/Q",
        ]),
    ]
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\'', "&apos;")
}

/// Task Scheduler XML of the guard: SYSTEM, at start-up and every minute (no end), runs even on
/// battery, one instance at a time, at most 10 minutes.
pub fn guard_task_xml(exe: &Path) -> Option<String> {
    if !is_safe_path(exe) {
        return None;
    }
    let exe = xml_escape(exe.to_str()?);
    Some(format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Sense Remote update guard</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>{exe}</Command><Arguments>{ARG_GUARD}</Arguments></Exec></Actions>
</Task>
"#
    ))
}

pub fn schtasks_create_args(xml_file: &Path) -> Vec<String> {
    ["/Create", "/TN", GUARD_TASK, "/XML"]
        .iter()
        .map(|a| (*a).to_owned())
        .chain([xml_file.to_string_lossy().into_owned(), "/F".to_owned()])
        .collect()
}

pub fn schtasks_delete_args() -> Vec<String> {
    ["/Delete", "/TN", GUARD_TASK, "/F"].map(str::to_owned).to_vec()
}

/// Kills the installed program's processes by image name, never the calling process (the guard
/// runs as `SenseRemote.exe` itself).
pub fn taskkill_args(self_pid: u32) -> Vec<String> {
    vec![
        "/F".to_owned(),
        "/IM".to_owned(),
        INSTALLED_EXE.to_owned(),
        "/FI".to_owned(),
        format!("PID ne {self_pid}"),
    ]
}

/// What the new version sees about itself at start (§5.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observed {
    pub role_installed: bool,
    pub id: String,
    pub key_hash: String,
    pub api_server_is_builtin: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelfCheck {
    /// No installation of this version waits for a verdict.
    NotMine,
    Healthy,
    Unhealthy,
}

/// Pure §5.3 decision. `FromId` / `FromKeyHash` are compared when stored (the manual move from
/// version 2 runs as the administrator, who can not read the service's identity: there only the
/// role and the API address are checked).
pub fn check_self(state: Option<&Persisted>, my_version: u32, observed: &Observed) -> SelfCheck {
    let Some(state) = state else {
        return SelfCheck::NotMine;
    };
    if my_version == 0 || state.state != StoredState::Installing || state.target != Some(my_version)
    {
        return SelfCheck::NotMine;
    }
    let same = |stored: &Option<String>, now: &str| stored.as_deref().map_or(true, |s| s == now);
    if observed.role_installed
        && observed.api_server_is_builtin
        && same(&state.from_id, &observed.id)
        && same(&state.from_key_hash, &observed.key_hash)
    {
        SelfCheck::Healthy
    } else {
        SelfCheck::Unhealthy
    }
}

/// Step 1 of `install`: what the store says while installing. Keeps `attempts` (the engine
/// counts them), clears the old verdict.
pub fn installing_state(
    before: Option<&Persisted>,
    job: &InstallJob,
    from: u32,
    from_id: Option<String>,
    from_key_hash: Option<String>,
    now: i64,
) -> Persisted {
    Persisted {
        state: StoredState::Installing,
        target: Some(job.version),
        from: (from > 0).then_some(from),
        from_id,
        from_key_hash,
        oid: job.oid.clone(),
        source: Some(job.source),
        attempts: before.map_or(0, |b| b.attempts),
        last_error: None,
        started_at: Some(now),
        healthy_at: None,
    }
}

/// After a rollback: `rolled_back`; the reason stays (`identity_changed` from the self-check),
/// otherwise the new version never declared itself healthy (`health_timeout`).
pub fn rolled_back_state(before: &Persisted) -> Persisted {
    Persisted {
        state: StoredState::RolledBack,
        last_error: Some(before.last_error.unwrap_or(UpdateError::HealthTimeout)),
        ..before.clone()
    }
}

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(windows)]
pub use win::{download_dir, install, remove_guard, roll_back, self_check, upgrade_local};

/// The privileged folder downloads go to; `None` when it can not be made safe.
#[cfg(not(windows))]
pub fn download_dir() -> Option<PathBuf> {
    None
}

/// Backup, guard, then the installation. Returns once the installer was started: this process
/// is about to be stopped by it.
#[cfg(not(windows))]
pub fn install(job: &InstallJob) -> Result<(), UpdateError> {
    let _ = job;
    Err(UpdateError::Unsupported)
}

/// Puts the old version back (guard only).
#[cfg(not(windows))]
pub fn roll_back() -> Result<(), UpdateError> {
    Err(UpdateError::Unsupported)
}

/// Unregisters the guard; the copy of the old version stays.
#[cfg(not(windows))]
pub fn remove_guard() -> Result<(), UpdateError> {
    Err(UpdateError::Unsupported)
}

/// The new version's check at start (§5.3). `Ok` also when there was nothing to check.
#[cfg(not(windows))]
pub fn self_check() -> Result<(), UpdateError> {
    Ok(())
}

/// `--sense-upgrade-local` (§8): the elevated step of the manual move from version 2, started
/// by `manual::upgrade_in_place` from the new setup file, without further arguments. Same
/// backup + guard + `update_me` path with `source = manual`; no sign-in, no registration.
/// Returns `UPGRADE_*`. Outside Windows it returns 1 at once, whatever the arguments
/// (`core_main` routes the flag here on every platform).
#[cfg(not(windows))]
pub fn upgrade_local(args: &[String]) -> i32 {
    let _ = args;
    UPGRADE_FAILED
}

#[cfg(windows)]
mod win {
    use super::*;
    use crate::sense::update::{current_version, store, UpdateSource};
    use hbb_common::{config::Config, log};
    use std::{os::windows::fs::MetadataExt, process::Command};

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

    fn program_data() -> PathBuf {
        std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .filter(|p| is_safe_path(p) && p.is_dir())
            .unwrap_or_else(|| PathBuf::from("C:\\ProgramData"))
    }

    fn run(program: &str, args: &[String]) -> Option<i32> {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        match Command::new(program)
            .args(args)
            .creation_flags(CREATE_NO_WINDOW)
            .output()
        {
            Ok(output) => output.status.code(),
            Err(err) => {
                log::error!("Sense Remote: {program} did not start: {err}");
                None
            }
        }
    }

    fn run_ok(program: &str, args: &[String]) -> bool {
        run(program, args) == Some(0)
    }

    /// `Ok(true)` = a real folder, `Ok(false)` = missing; a link, junction or file is an error.
    fn plain_dir(path: &Path) -> Result<bool, String> {
        match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 => {
                Err(format!("reparse point: {}", path.display()))
            }
            Ok(meta) if meta.is_dir() => Ok(true),
            Ok(_) => Err(format!("not a folder: {}", path.display())),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(err) => Err(err.to_string()),
        }
    }

    /// Creates `dir` under `base` level by level, refusing reparse points on the way.
    fn make_dirs(base: &Path, dir: &Path) -> Result<(), String> {
        let rest = dir.strip_prefix(base).map_err(|_| "outside base".to_owned())?;
        let mut path = base.to_path_buf();
        if !plain_dir(&path)? {
            return Err(format!("missing: {}", path.display()));
        }
        for part in rest.components() {
            path.push(part);
            if !plain_dir(&path)? {
                std::fs::create_dir(&path).map_err(|err| err.to_string())?;
                if !plain_dir(&path)? {
                    return Err(format!("not created: {}", path.display()));
                }
            }
        }
        Ok(())
    }

    /// `secure` on any root (tests use a temporary one): the folders exist, no level is a
    /// reparse point, and `<root>\SenseRemote` is SYSTEM + Administrators only.
    pub(super) fn secure_in(program_data: &Path, dirs: &[PathBuf]) -> Result<(), String> {
        let top = sense_data_dir(program_data);
        make_dirs(program_data, &top)?;
        for args in icacls_runs(&top) {
            if !run_ok("icacls", &args) {
                return Err(format!("icacls failed: {}", args[1]));
            }
        }
        for dir in dirs {
            make_dirs(program_data, dir)?;
        }
        Ok(())
    }

    fn secure(dirs: &[PathBuf]) -> Result<(), String> {
        secure_in(&program_data(), dirs)
    }

    pub fn download_dir() -> Option<PathBuf> {
        let dir = dl_dir(&program_data());
        match secure(std::slice::from_ref(&dir)) {
            Ok(()) => Some(dir),
            Err(err) => {
                log::error!("Sense Remote: update download folder not safe: {err}");
                None
            }
        }
    }

    pub(super) fn mirror(from: &Path, to: &Path) -> Result<(), String> {
        if !plain_dir(from)? {
            return Err(format!("missing: {}", from.display()));
        }
        let code = run("robocopy", &robocopy_args(from, to));
        if robocopy_succeeded(code) {
            Ok(())
        } else {
            Err(format!("robocopy {code:?}"))
        }
    }

    /// The installation folder as the registry knows it; checked like every command path.
    fn install_dir() -> Result<PathBuf, String> {
        let (_, path, _, exe) = crate::platform::get_install_info();
        let path = PathBuf::from(path);
        if !is_safe_path(&path) || !Path::new(&exe).is_file() || !plain_dir(&path)? {
            return Err("not installed".to_owned());
        }
        Ok(path)
    }

    fn register_guard(exe: &Path) -> Result<(), String> {
        let xml = guard_task_xml(exe).ok_or("unsafe guard path")?;
        let file = update_dir(&program_data()).join("guard.xml");
        // Task Scheduler reads UTF-16 with a byte order mark.
        let bytes: Vec<u8> = std::iter::once(0xFEFF_u16)
            .chain(xml.encode_utf16())
            .flat_map(u16::to_le_bytes)
            .collect();
        std::fs::write(&file, bytes).map_err(|err| err.to_string())?;
        let created = run_ok("schtasks", &schtasks_create_args(&file));
        let _ = std::fs::remove_file(&file);
        if created {
            Ok(())
        } else {
            Err("schtasks /Create failed".to_owned())
        }
    }

    pub fn remove_guard() -> Result<(), UpdateError> {
        if run_ok("schtasks", &schtasks_delete_args()) {
            return Ok(());
        }
        let query = ["/Query", "/TN", GUARD_TASK].map(str::to_owned).to_vec();
        if run_ok("schtasks", &query) {
            log::error!("Sense Remote: update guard task not removed");
            Err(UpdateError::InstallFailed)
        } else {
            Ok(())
        }
    }

    fn write_state(state: &Persisted) {
        if let Err(err) = store::write(state) {
            log::error!("Sense Remote: update state not written: {err}");
        }
    }

    /// Steps 1–3 shared by `install` and `upgrade_local`: state, backup, guard. On error the
    /// state says `failed` and no guard is left behind.
    fn prepare(
        job: &InstallJob,
        from: u32,
        identity: Option<(String, String)>,
        guard_from: Option<&Path>,
    ) -> Result<PersistedGuard, String> {
        let install = install_dir()?;
        let before = store::read()?;
        let (from_id, from_key_hash) = identity.unzip();
        let state = installing_state(
            before.as_ref(),
            job,
            from,
            from_id,
            from_key_hash,
            now_s(),
        );
        store::write(&state)?;
        let failed = PersistedGuard {
            state,
            install,
            armed: true,
        };
        let pd = program_data();
        let mut dirs = vec![prev_dir(&pd)];
        if guard_from.is_some() {
            dirs.push(guard_dir(&pd));
        }
        secure(&dirs)?;
        mirror(&failed.install, &prev_dir(&pd))?;
        let guard_exe = match guard_from {
            // Manual move: the old version 2 has no guard; a copy of this new program guards.
            Some(own_dir) => {
                mirror(own_dir, &guard_dir(&pd))?;
                let name = std::env::current_exe()
                    .ok()
                    .and_then(|exe| exe.file_name().map(|n| n.to_owned()))
                    .ok_or("no exe name")?;
                guard_dir(&pd).join(name)
            }
            None => prev_dir(&pd).join(INSTALLED_EXE),
        };
        if !guard_exe.is_file() {
            return Err("guard program missing".to_owned());
        }
        register_guard(&guard_exe)?;
        Ok(failed)
    }

    /// Writes `failed` and removes the guard unless `disarm` was called: every early return
    /// after step 1 leaves a clean state.
    struct PersistedGuard {
        state: Persisted,
        install: PathBuf,
        armed: bool,
    }

    impl PersistedGuard {
        fn disarm(mut self) {
            self.armed = false;
        }
    }

    impl Drop for PersistedGuard {
        fn drop(&mut self) {
            if self.armed {
                let _ = remove_guard();
                let mut state = self.state.clone();
                state.state = StoredState::Failed;
                state.last_error = Some(UpdateError::InstallFailed);
                write_state(&state);
            }
        }
    }

    fn mark_failed(job: &InstallJob, before: u32) {
        let _ = remove_guard();
        let current = store::read().ok().flatten();
        let mut state = installing_state(current.as_ref(), job, before, None, None, now_s());
        state.state = StoredState::Failed;
        state.last_error = Some(UpdateError::InstallFailed);
        write_state(&state);
    }

    fn identity() -> (String, String) {
        let (_, public_key) = Config::get_key_pair();
        (Config::get_id(), store::key_hash(&public_key))
    }

    pub fn install(job: &InstallJob) -> Result<(), UpdateError> {
        let mine = current_version();
        if job.version <= mine || job.version <= store::installed_version() {
            return Err(UpdateError::Downgrade);
        }
        if !crate::updater::has_no_active_conns() {
            return Err(UpdateError::Busy);
        }
        let Some(file) = job.file.to_str().filter(|_| is_safe_path(&job.file)) else {
            return Err(UpdateError::InstallFailed);
        };
        let guard = match prepare(job, mine, Some(identity()), None) {
            Ok(guard) => guard,
            Err(err) => {
                log::error!("Sense Remote: update {} not prepared: {err}", job.version);
                mark_failed(job, mine);
                return Err(UpdateError::InstallFailed);
            }
        };
        // Step 4, as upstream's `update_new_version`: a private, locked copy checked once more.
        let verified = match crate::platform::copy_and_verify_update_file_sha256(file, &job.sha256)
        {
            Ok(verified) => verified,
            Err(err) => {
                log::error!("Sense Remote: update file refused: {err}");
                return Err(UpdateError::HashMismatch);
            }
        };
        let size = verified
            .path_str()
            .ok()
            .and_then(|p| std::fs::metadata(p).ok())
            .map(|m| m.len());
        if size != Some(job.size) {
            verified.cleanup();
            return Err(UpdateError::SizeMismatch);
        }
        let Some(command) = verified
            .path_str()
            .ok()
            .and_then(|p| update_command_line(Path::new(p)))
        else {
            verified.cleanup();
            return Err(UpdateError::InstallFailed);
        };
        if !crate::updater::has_no_active_conns() {
            verified.cleanup();
            return Err(UpdateError::Busy);
        }
        let Some(session) = crate::platform::get_current_process_session_id() else {
            verified.cleanup();
            return Err(UpdateError::InstallFailed);
        };
        if let Err(err) = crate::platform::handle_custom_client_staging_dir_before_update(
            &crate::platform::get_custom_client_staging_dir(),
        ) {
            log::error!("Sense Remote: staging folder before update: {err}");
            verified.cleanup();
            return Err(UpdateError::InstallFailed);
        }
        match crate::platform::launch_privileged_process(session, &command) {
            Ok(handle) if !handle.is_null() => {
                unsafe { winapi::um::handleapi::CloseHandle(handle) };
                log::info!("Sense Remote: update {} started", job.version);
                // The started `--update` schedules the removal of its own verified copy.
                drop(verified);
                guard.disarm();
                Ok(())
            }
            Ok(_) | Err(_) => {
                log::error!("Sense Remote: update {} did not start", job.version);
                verified.cleanup();
                Err(UpdateError::InstallFailed)
            }
        }
    }

    fn wait_service_stopped() {
        for _ in 0..30 {
            if !crate::platform::is_self_service_running() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }

    pub fn roll_back() -> Result<(), UpdateError> {
        let before = match store::read() {
            Ok(Some(state)) => state,
            Ok(None) => return Err(UpdateError::RollbackFailed),
            Err(err) => {
                log::error!("Sense Remote: rollback without a readable state: {err}");
                return Err(UpdateError::RollbackFailed);
            }
        };
        let pd = program_data();
        let prev = prev_dir(&pd);
        let install = match install_dir() {
            Ok(install) if prev.join(INSTALLED_EXE).is_file() => install,
            _ => {
                log::error!("Sense Remote: rollback has no old version to restore");
                return Err(UpdateError::RollbackFailed);
            }
        };
        log::warn!("Sense Remote: rolling back update {:?}", before.target);
        let _ = run("sc", &["stop".to_owned(), SERVICE.to_owned()]);
        wait_service_stopped();
        let _ = run("taskkill", &taskkill_args(std::process::id()));
        let copied = plain_dir(&prev).and_then(|_| mirror(&prev, &install));
        let result = match copied {
            Ok(()) => {
                if let Err(err) = store::store_installed_version(before.from.unwrap_or(0)) {
                    log::error!("Sense Remote: version not restored: {err}");
                }
                write_state(&rolled_back_state(&before));
                Ok(())
            }
            Err(err) => {
                log::error!("Sense Remote: rollback copy failed: {err}");
                let mut state = before.clone();
                state.last_error = Some(UpdateError::RollbackFailed);
                write_state(&state);
                Err(UpdateError::RollbackFailed)
            }
        };
        let _ = run("sc", &["start".to_owned(), SERVICE.to_owned()]);
        result
    }

    pub fn self_check() -> Result<(), UpdateError> {
        let state = match store::read() {
            Ok(state) => state,
            Err(err) => {
                log::error!("Sense Remote: update state unreadable: {err}");
                return Ok(());
            }
        };
        let mine = current_version();
        let (id, key_hash) = identity();
        let observed = Observed {
            role_installed: crate::sense::installed_role().is_some(),
            id,
            key_hash,
            api_server_is_builtin: crate::sense::api_server() == crate::sense::API_SERVER,
        };
        let Some(mut state) = state else {
            return Ok(());
        };
        match check_self(Some(&state), mine, &observed) {
            SelfCheck::NotMine => Ok(()),
            SelfCheck::Healthy => {
                if let Err(err) = store::store_installed_version(mine) {
                    log::error!("Sense Remote: version not stored: {err}");
                }
                state.state = StoredState::Installed;
                state.healthy_at = Some(now_s());
                state.last_error = None;
                write_state(&state);
                log::info!("Sense Remote: update to {mine} is healthy");
                Ok(())
            }
            SelfCheck::Unhealthy => {
                state.state = StoredState::Unhealthy;
                state.last_error = Some(UpdateError::IdentityChanged);
                write_state(&state);
                log::error!("Sense Remote: update to {mine} changed the identity; rolling back");
                Err(UpdateError::IdentityChanged)
            }
        }
    }

    pub fn upgrade_local(args: &[String]) -> i32 {
        if !args.is_empty() {
            return UPGRADE_FAILED;
        }
        if !crate::platform::is_elevated(None).unwrap_or(false) {
            return UPGRADE_NOT_ELEVATED;
        }
        let mine = current_version();
        if mine == 0 {
            return UPGRADE_FAILED;
        }
        if install_dir().is_err() || crate::sense::installed_role().is_none() {
            return UPGRADE_NOT_INSTALLED;
        }
        let installed = store::installed_version();
        if installed >= mine {
            return UPGRADE_NOT_NEWER;
        }
        let Some(own_dir) = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf))
            .filter(|dir| is_safe_path(dir))
        else {
            return UPGRADE_FAILED;
        };
        let job = InstallJob {
            file: own_dir.clone(),
            version: mine,
            sha256: String::new(),
            size: 0,
            source: UpdateSource::Manual,
            oid: None,
        };
        let guard = match prepare(&job, installed, None, Some(&own_dir)) {
            Ok(guard) => guard,
            Err(err) => {
                log::error!("Sense Remote: manual update not prepared: {err}");
                mark_failed(&job, installed);
                return UPGRADE_FAILED;
            }
        };
        // As `core_main`'s `--update`, in this elevated process: `update_me` copies this
        // program's folder over the installation and restarts the service.
        match crate::platform::prepare_custom_client_update() {
            Ok(true) => {}
            _ => return UPGRADE_FAILED,
        }
        match crate::platform::update_me(false) {
            Ok(()) => {
                guard.disarm();
                UPGRADE_OK
            }
            Err(err) => {
                log::error!("Sense Remote: manual update failed: {err}");
                UPGRADE_FAILED
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::update::{store::key_hash, UpdateSource};

    fn job(version: u32) -> InstallJob {
        InstallJob {
            file: PathBuf::from("C:\\ProgramData\\SenseRemote\\update\\dl\\SenseRemote-Kurulum-4.exe"),
            version,
            sha256: "00".repeat(32),
            size: 1,
            source: UpdateSource::Panel,
            oid: Some("upd_0123456789abcdef".to_owned()),
        }
    }

    fn observed() -> Observed {
        Observed {
            role_installed: true,
            id: "123456789".to_owned(),
            key_hash: key_hash(b"pk"),
            api_server_is_builtin: true,
        }
    }

    fn installing(target: u32) -> Persisted {
        installing_state(
            None,
            &job(target),
            3,
            Some("123456789".to_owned()),
            Some(key_hash(b"pk")),
            1_795_000_000,
        )
    }

    // Outside Windows the flag never does anything.
    #[cfg(not(windows))]
    #[test]
    fn upgrade_local_is_windows_only() {
        let args = |list: &[&str]| list.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>();
        assert_eq!(upgrade_local(&[]), 1);
        assert_eq!(upgrade_local(&args(&["SenseRemote-Kurulum-3.exe"])), 1);
        let cli = args(&[crate::sense::update::ARG_UPGRADE_LOCAL, "x"]);
        assert_eq!(crate::sense::update::run_cli(&cli), Some(1));
        assert_eq!(install(&job(4)), Err(UpdateError::Unsupported));
        assert_eq!(roll_back(), Err(UpdateError::Unsupported));
        assert_eq!(download_dir(), None);
    }

    #[test]
    fn folders_live_under_programdata_sense_remote() {
        let pd = Path::new("C:\\ProgramData");
        let text = |p: PathBuf| p.to_string_lossy().replace('/', "\\");
        assert_eq!(text(prev_dir(pd)), "C:\\ProgramData\\SenseRemote\\update\\prev");
        assert_eq!(text(dl_dir(pd)), "C:\\ProgramData\\SenseRemote\\update\\dl");
        assert_eq!(text(guard_dir(pd)), "C:\\ProgramData\\SenseRemote\\update\\guard");
    }

    #[test]
    fn command_paths_are_quoted_and_checked() {
        let exe = Path::new("C:\\Windows\\SystemTemp\\.sense verified-1-2.exe");
        assert_eq!(
            update_command_line(exe).unwrap(),
            "\"C:\\Windows\\SystemTemp\\.sense verified-1-2.exe\" --update"
        );
        for bad in [
            "C:\\a\" --install \"x.exe",
            "C:\\%TEMP%\\x.exe",
            "C:\\a\r\nb.exe",
            "relative\\x.exe",
            "",
        ] {
            assert_eq!(update_command_line(Path::new(bad)), None, "{bad:?}");
            assert_eq!(guard_task_xml(Path::new(bad)), None, "{bad:?}");
        }
    }

    #[test]
    fn robocopy_mirrors_without_following_junctions() {
        let args = robocopy_args(
            Path::new("C:\\Program Files\\SenseRemote\\"),
            Path::new("C:\\ProgramData\\SenseRemote\\update\\prev"),
        );
        assert_eq!(args[0], "C:\\Program Files\\SenseRemote");
        assert_eq!(args[1], "C:\\ProgramData\\SenseRemote\\update\\prev");
        assert!(args.contains(&"/MIR".to_owned()) && args.contains(&"/XJ".to_owned()));
        for code in 0..=7 {
            assert!(robocopy_succeeded(Some(code)));
        }
        for code in [Some(8), Some(16), Some(-1), None] {
            assert!(!robocopy_succeeded(code), "{code:?}");
        }
    }

    #[test]
    fn guard_task_runs_the_old_copy_as_system() {
        let exe = Path::new("C:\\ProgramData\\SenseRemote\\update\\prev\\SenseRemote.exe");
        let xml = guard_task_xml(exe).unwrap();
        assert!(xml.contains(
            "<Command>C:\\ProgramData\\SenseRemote\\update\\prev\\SenseRemote.exe</Command>"
        ));
        assert!(xml.contains("<Arguments>--sense-update-guard</Arguments>"));
        assert!(xml.contains("<UserId>S-1-5-18</UserId>"));
        assert!(xml.contains("<BootTrigger>"));
        assert!(xml.contains("<Interval>PT1M</Interval>"));
        assert!(!xml.contains("<Duration>"), "repeats without end");
        // `&` in a folder name stays text.
        let xml = guard_task_xml(Path::new("C:\\A&B\\SenseRemote.exe")).unwrap();
        assert!(xml.contains("<Command>C:\\A&amp;B\\SenseRemote.exe</Command>"));
        assert_eq!(
            schtasks_create_args(Path::new("C:\\x\\guard.xml")),
            ["/Create", "/TN", "SenseRemoteUpdateGuard", "/XML", "C:\\x\\guard.xml", "/F"]
        );
        assert_eq!(schtasks_delete_args(), ["/Delete", "/TN", "SenseRemoteUpdateGuard", "/F"]);
    }

    #[test]
    fn rollback_kills_only_the_program_and_never_itself() {
        assert_eq!(taskkill_args(42), ["/F", "/IM", "SenseRemote.exe", "/FI", "PID ne 42"]);
    }

    #[test]
    fn acl_is_system_and_administrators_only() {
        let runs = icacls_runs(Path::new("C:\\ProgramData\\SenseRemote"));
        assert_eq!(runs.len(), 3);
        assert!(runs.iter().all(|r| r[0] == "C:\\ProgramData\\SenseRemote"));
        assert!(runs.iter().all(|r| r.contains(&"/L".to_owned())), "links are not followed");
        let grants = runs[2].join(" ");
        assert!(grants.contains("/inheritance:r"));
        assert!(grants.contains("*S-1-5-18:(OI)(CI)F") && grants.contains("*S-1-5-32-544:(OI)(CI)F"));
        assert!(!grants.contains("S-1-5-11") && !grants.contains("S-1-5-32-545"));
    }

    // §4.4: after an update the program is `SenseRemote.exe`, which is not a setup name, so
    // the setup wizard does not open (`core_main`: `is_setup`; packer: `-kurulum`).
    #[test]
    fn installed_name_does_not_open_the_wizard() {
        assert_eq!(INSTALLED_EXE, format!("{}.exe", crate::common::SENSE_APP_NAME));
        assert_eq!(SERVICE, crate::common::SENSE_APP_NAME);
        let name = INSTALLED_EXE.to_lowercase();
        assert!(!name.ends_with("install.exe") && !name.contains("-kurulum"));
    }

    #[test]
    fn self_check_accepts_only_the_same_identity() {
        let state = installing(4);
        assert_eq!(check_self(Some(&state), 4, &observed()), SelfCheck::Healthy);
        let mut other = observed();
        other.id = "987654321".to_owned();
        assert_eq!(check_self(Some(&state), 4, &other), SelfCheck::Unhealthy);
        let mut other = observed();
        other.key_hash = key_hash(b"new key");
        assert_eq!(check_self(Some(&state), 4, &other), SelfCheck::Unhealthy);
        let mut other = observed();
        other.role_installed = false;
        assert_eq!(check_self(Some(&state), 4, &other), SelfCheck::Unhealthy);
        let mut other = observed();
        other.api_server_is_builtin = false;
        assert_eq!(check_self(Some(&state), 4, &other), SelfCheck::Unhealthy);
        // The manual move stores no identity: role and API address still count.
        let mut manual = state.clone();
        manual.from_id = None;
        manual.from_key_hash = None;
        let mut other = observed();
        other.id = "987654321".to_owned();
        assert_eq!(check_self(Some(&manual), 4, &other), SelfCheck::Healthy);
    }

    #[test]
    fn self_check_ignores_what_is_not_its_own() {
        let state = installing(4);
        // The old version still running (the installer failed), a local build, no state.
        assert_eq!(check_self(Some(&state), 3, &observed()), SelfCheck::NotMine);
        assert_eq!(check_self(Some(&state), 0, &observed()), SelfCheck::NotMine);
        assert_eq!(check_self(None, 4, &observed()), SelfCheck::NotMine);
        for done in [StoredState::Installed, StoredState::Unhealthy, StoredState::RolledBack] {
            let mut other = state.clone();
            other.state = done;
            assert_eq!(check_self(Some(&other), 4, &observed()), SelfCheck::NotMine);
        }
    }

    #[test]
    fn states_around_an_installation() {
        let mut before = installing(4);
        before.attempts = 2;
        before.last_error = Some(UpdateError::DownloadFailed);
        let state = installing_state(Some(&before), &job(5), 0, None, None, 7);
        assert_eq!(state.state, StoredState::Installing);
        assert_eq!((state.target, state.from, state.attempts), (Some(5), None, 2));
        assert_eq!((state.started_at, state.healthy_at, state.last_error), (Some(7), None, None));
        assert_eq!(state.source, Some(UpdateSource::Panel));
        let back = rolled_back_state(&installing(4));
        assert_eq!(back.state, StoredState::RolledBack);
        assert_eq!(back.last_error, Some(UpdateError::HealthTimeout));
        assert_eq!(back.from, Some(3));
        let mut unhealthy = installing(4);
        unhealthy.state = StoredState::Unhealthy;
        unhealthy.last_error = Some(UpdateError::IdentityChanged);
        assert_eq!(rolled_back_state(&unhealthy).last_error, Some(UpdateError::IdentityChanged));
    }

    // Windows CI: the folder tree is SYSTEM + Administrators only, a junction is refused, and
    // a backup → broken installation → restore round really restores (robocopy).
    #[cfg(windows)]
    #[test]
    fn backup_break_and_restore_in_a_temporary_tree() {
        if !crate::platform::is_elevated(None).unwrap_or(false) {
            assert!(std::env::var_os("GITHUB_ACTIONS").is_none(), "CI runs elevated");
            return;
        }
        let base = std::env::temp_dir().join(format!("sense-u3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let install = base.join("install");
            std::fs::create_dir_all(install.join("data")).unwrap();
            std::fs::write(install.join("SenseRemote.exe"), b"v3").unwrap();
            std::fs::write(install.join("data").join("a.dll"), b"v3").unwrap();

            let prev = prev_dir(&base);
            win::secure_in(&base, &[prev.clone()]).unwrap();
            let acl = std::process::Command::new("icacls")
                .arg(sense_data_dir(&base))
                .output()
                .unwrap();
            let acl = String::from_utf8_lossy(&acl.stdout).to_string();
            for broad in ["BUILTIN\\Users", "Authenticated Users", "Everyone", "CREATOR OWNER"] {
                assert!(!acl.contains(broad), "{broad}: {acl}");
            }
            assert!(!acl.contains("(I)"), "inheritance cut: {acl}");

            win::mirror(&install, &prev).unwrap();
            std::fs::write(install.join("SenseRemote.exe"), b"broken v4").unwrap();
            std::fs::write(install.join("extra.dll"), b"v4").unwrap();
            win::mirror(&prev, &install).unwrap();
            assert_eq!(std::fs::read(install.join("SenseRemote.exe")).unwrap(), b"v3");
            assert_eq!(std::fs::read(install.join("data").join("a.dll")).unwrap(), b"v3");
            assert!(!install.join("extra.dll").exists());

            // A junction in place of a folder is refused, the target is untouched.
            let target = base.join("elsewhere");
            std::fs::create_dir_all(&target).unwrap();
            let dl = dl_dir(&base);
            let status = std::process::Command::new("cmd")
                .args(["/C", "mklink", "/J"])
                .arg(&dl)
                .arg(&target)
                .status()
                .unwrap();
            assert!(status.success());
            assert!(win::secure_in(&base, &[dl.clone()]).is_err());
            assert!(win::mirror(&dl, &install).is_err());
        }));
        let _ = std::process::Command::new("icacls")
            .arg(&base)
            .args(["/reset", "/T", "/Q"])
            .status();
        let _ = std::fs::remove_dir_all(&base);
        result.unwrap();
    }
}
