//! Sense Remote (update plan 2026-11-21, §8): the one-time manual move from version 2, which
//! has no updater. Package U7.
//!
//! - Windows: the new setup file sees an older installed version
//!   (`super::installed_version`), shows the short "Güncelleme" screen and, after the Windows
//!   administrator prompt, runs itself with `--sense-upgrade-local` (`apply_win::upgrade_local`:
//!   backup + guard + `update_me`, `source = manual`).
//! - macOS: after the new app was dragged over the old one, "Sürüm 3'e geçişi tamamla": an
//!   administrator prompt, `chown -R root:wheel` + `chmod -R go-w` (G4-1), daemon and agent
//!   `kickstart -k`, then the permissions step.
//! - No sign-in and no registration on either platform: `enroll` is never called, the ID, the
//!   device key and the role stay. Never a downgrade.

#[cfg(any(target_os = "macos", test))]
use crate::sense::identity::mac_script::{root_executed_paths, ScriptEnv, FAILED_MARKER};

/// Result codes of `upgrade_in_place` (FFI `install_sense_upgrade_in_place`).
pub const OK: &str = "";
#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
pub const CANCELLED: &str = "cancelled";
pub const NOT_INSTALLED: &str = "not_installed";
pub const NOT_NEWER: &str = "not_newer";
pub const FAILED: &str = "failed";

/// Exit codes of `--sense-upgrade-local`: the constants of package U3 (`apply_win::UPGRADE_*`).
// Sense Remote (U8): the Windows step; unused in the macOS build.
#[cfg_attr(target_os = "macos", allow(unused_imports))]
pub use super::apply_win::{
    UPGRADE_FAILED as EXIT_FAILED, UPGRADE_NOT_ELEVATED as EXIT_NOT_ELEVATED,
    UPGRADE_NOT_INSTALLED as EXIT_NOT_INSTALLED, UPGRADE_NOT_NEWER as EXIT_NOT_NEWER,
    UPGRADE_OK as EXIT_OK,
};

/// Pure (Windows): the setup screen must not run as the installed program's file name:
/// `update_me` ends every other `SenseRemote.exe` process (U3), so the screen would close
/// while it waits for the elevated step. The setup file is `SenseRemote-Kurulum-<n>.exe`.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub fn runs_as_installed_exe(file_name: &str) -> bool {
    file_name.eq_ignore_ascii_case(super::apply_win::INSTALLED_EXE)
}

/// Text of the macOS administrator password prompt.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub const PROMPT_MAC: &str = "Sense Remote, yeni sürüme geçişi tamamlamak için yönetici izni istiyor.";

/// Pure: the code for the exit code of the elevated Windows step. Anything unknown (also
/// "not elevated", which can only mean the prompt did not give the rights) is `failed`.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub fn code_for_exit(code: i32) -> &'static str {
    match code {
        EXIT_OK => OK,
        EXIT_NOT_INSTALLED => NOT_INSTALLED,
        EXIT_NOT_NEWER => NOT_NEWER,
        _ => FAILED,
    }
}

/// Pure: checked before any administrator prompt. `this` = version of this build (0 = a build
/// without `SENSE_VERSION`, which can not compare and does nothing); `installed` = the
/// installed version (0 = version 2 or older). On macOS the installed bundle is this build, so
/// the caller passes 0 there: the move is only offered when the bundle is not root's yet.
pub fn precheck(role_installed: bool, installed: u32, this: u32) -> Result<(), &'static str> {
    if this == 0 {
        return Err(FAILED);
    }
    if !role_installed {
        return Err(NOT_INSTALLED);
    }
    if installed >= this {
        return Err(NOT_NEWER);
    }
    Ok(())
}

/// Shell script run as root on macOS (`install.scpt`, M2 pattern): only checked values of
/// `env` go into it (`ScriptEnv::check`), nothing typed by anybody. It hands the bundle to root
/// (G4-1), checks the paths root executes, then restarts daemon and agent from the new binary.
/// No config copy, no state write: ID, device key and role stay as they are.
#[cfg(any(target_os = "macos", test))]
pub fn mac_script(env: &ScriptEnv) -> Result<String, &'static str> {
    env.check()?;
    let ScriptEnv {
        path,
        app_bundle,
        app_name,
        daemon_plist,
        agent_plist,
        ..
    } = env;
    let daemon = env.daemon_target();
    let agent = env.agent_target();
    let root_paths = root_executed_paths(app_bundle, app_name)
        .map(|path| format!("\"{path}\""))
        .join(" ");
    Ok(format!(
        r#"set -eu
PATH="{path}"; export PATH
step=check
app="{app_bundle}"
on_exit() {{
  code=$?
  if [ "$code" -ne 0 ]; then echo "{FAILED_MARKER}$step" >&2; fi
}}
trap on_exit EXIT
[ -d "$app" ]
[ ! -L "$app" ]
[ -x "$app/Contents/MacOS/service" ]
[ -f "{daemon_plist}" ]
[ -f "{agent_plist}" ]
step=harden
chown -R root:wheel "$app"
chmod -R go-w "$app"
for f in {root_paths}; do
  [ ! -L "$f" ]
  [ "$(stat -f %u "$f")" = 0 ]
done
step=restart
launchctl kickstart -k "{daemon}"
launchctl kickstart -k "{agent}"
step=done
"#
    ))
}

/// Runs the manual move from the setup screen and returns one of the codes above.
pub fn upgrade_in_place() -> String {
    #[cfg(windows)]
    return win::upgrade_in_place();
    #[cfg(target_os = "macos")]
    return mac::upgrade_in_place();
    #[cfg(not(any(windows, target_os = "macos")))]
    return FAILED.to_owned();
}

#[cfg(windows)]
mod win {
    use super::*;
    use crate::sense::update::{current_version, store, ARG_UPGRADE_LOCAL};
    use hbb_common::log;
    use std::{mem, path::Path};
    use windows::{
        core::PCWSTR,
        Win32::{
            Foundation::{CloseHandle, ERROR_CANCELLED, WAIT_OBJECT_0},
            System::{
                Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE},
                Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE},
            },
            UI::{
                Shell::{ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW},
                WindowsAndMessaging::SW_HIDE,
            },
        },
    };

    pub fn upgrade_in_place() -> String {
        let checked = precheck(
            crate::sense::installed_role().is_some(),
            store::installed_version(),
            current_version(),
        );
        if let Err(code) = checked {
            log::info!("Sense Remote: manual move not started: {code}");
            return code.to_owned();
        }
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(err) => {
                log::error!("Sense Remote: setup file path not known: {err}");
                return FAILED.to_owned();
            }
        };
        let name = exe.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        if runs_as_installed_exe(name) {
            log::error!("Sense Remote: manual move refused, setup runs as the installed exe name");
            return FAILED.to_owned();
        }
        match run_elevated(&exe, ARG_UPGRADE_LOCAL) {
            Ok(exit) => {
                let code = code_for_exit(exit as i32);
                log::info!("Sense Remote: manual move, elevated step ended with {exit}");
                code.to_owned()
            }
            Err(RunError::Cancelled) => CANCELLED.to_owned(),
            Err(RunError::Other(err)) => {
                log::error!("Sense Remote: manual move not started: {err}");
                FAILED.to_owned()
            }
        }
    }

    enum RunError {
        Cancelled,
        Other(String),
    }

    /// Starts `exe` with the one fixed argument through the administrator prompt and waits for
    /// its exit code. The path is passed as the file, not inside a command line.
    fn run_elevated(exe: &Path, arg: &str) -> Result<u32, RunError> {
        let com =
            unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) };
        let result = run_elevated_inner(exe, arg);
        if com.is_ok() {
            unsafe { CoUninitialize() };
        }
        result
    }

    fn run_elevated_inner(exe: &Path, arg: &str) -> Result<u32, RunError> {
        let verb = crate::platform::windows::wide_string("runas");
        let file = crate::platform::windows::wide_string(&exe.to_string_lossy());
        let params = crate::platform::windows::wide_string(arg);
        let mut info = SHELLEXECUTEINFOW::default();
        info.cbSize = mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        info.lpVerb = PCWSTR(verb.as_ptr());
        info.lpFile = PCWSTR(file.as_ptr());
        info.lpParameters = PCWSTR(params.as_ptr());
        info.nShow = SW_HIDE.0;
        if let Err(err) = unsafe { ShellExecuteExW(&mut info) } {
            return Err(if err.code() == ERROR_CANCELLED.to_hresult() {
                RunError::Cancelled
            } else {
                RunError::Other(err.to_string())
            });
        }
        let process = info.hProcess;
        if process.0.is_null() {
            return Err(RunError::Other("no process handle".to_owned()));
        }
        let waited = unsafe { WaitForSingleObject(process, INFINITE) };
        let mut exit = EXIT_FAILED as u32;
        let read = if waited == WAIT_OBJECT_0 {
            unsafe { GetExitCodeProcess(process, &mut exit) }.map_err(|err| err.to_string())
        } else {
            Err(format!("wait result {}", waited.0))
        };
        let _ = unsafe { CloseHandle(process) };
        read.map(|_| exit).map_err(RunError::Other)
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use crate::sense::identity::mac_script::{self, ScriptOutcome};
    use crate::sense::update::current_version;
    use hbb_common::{config, libc, log};

    pub fn upgrade_in_place() -> String {
        if let Err(code) = precheck(crate::sense::installed_role().is_some(), 0, current_version())
        {
            log::info!("Sense Remote: manual move not started: {code}");
            return code.to_owned();
        }
        let config_file = config::Config::file();
        let config_dir = config_file
            .parent()
            .and_then(|dir| dir.to_str())
            .unwrap_or_default();
        let uid = unsafe { libc::getuid() };
        let script = ScriptEnv::production(
            &crate::get_app_name(),
            &crate::get_full_name(),
            config_dir,
            uid,
        )
        .and_then(|env| mac_script(&env));
        let script = match script {
            Ok(script) => script,
            Err(err) => {
                log::error!("Sense Remote: manual move script not made: {err}");
                return FAILED.to_owned();
            }
        };
        match crate::platform::macos::sense_run_privileged("install.scpt", &script, PROMPT_MAC) {
            Ok((success, stderr)) => match mac_script::classify_osascript(success, &stderr) {
                ScriptOutcome::Done => OK.to_owned(),
                ScriptOutcome::Cancelled => CANCELLED.to_owned(),
                ScriptOutcome::Failed(step) => {
                    let tail: String = stderr.chars().take(600).collect();
                    log::error!("Sense Remote: manual move step {step} failed: {tail}");
                    FAILED.to_owned()
                }
            },
            Err(err) => {
                log::error!("Sense Remote: manual move script not run: {err}");
                FAILED.to_owned()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn precheck_never_downgrades_and_needs_a_role() {
        // Version 2 (no HKLM `Version`) with a role → move to 3.
        assert_eq!(precheck(true, 0, 3), Ok(()));
        assert_eq!(precheck(true, 2, 3), Ok(()));
        assert_eq!(precheck(true, 3, 3), Err(NOT_NEWER));
        assert_eq!(precheck(true, 4, 3), Err(NOT_NEWER));
        assert_eq!(precheck(false, 0, 3), Err(NOT_INSTALLED));
        // A build without a Sense version can not compare.
        assert_eq!(precheck(true, 0, 0), Err(FAILED));
    }

    #[test]
    fn exit_codes_map_to_screen_codes() {
        assert_eq!(code_for_exit(EXIT_OK), OK);
        assert_eq!(code_for_exit(EXIT_NOT_INSTALLED), NOT_INSTALLED);
        assert_eq!(code_for_exit(EXIT_NOT_NEWER), NOT_NEWER);
        assert_eq!(code_for_exit(EXIT_FAILED), FAILED);
        assert_eq!(code_for_exit(EXIT_NOT_ELEVATED), FAILED);
        assert_eq!(code_for_exit(-1), FAILED);
        assert_eq!(code_for_exit(259), FAILED);
    }

    #[test]
    fn exit_codes_are_u3_constants() {
        assert_eq!(
            [EXIT_OK, EXIT_FAILED, EXIT_NOT_INSTALLED, EXIT_NOT_NEWER, EXIT_NOT_ELEVATED],
            [0, 1, 2, 3, 4]
        );
    }

    #[test]
    fn setup_never_runs_as_the_installed_exe() {
        assert!(runs_as_installed_exe("SenseRemote.exe"));
        assert!(runs_as_installed_exe("senseremote.EXE"));
        assert!(!runs_as_installed_exe("SenseRemote-Kurulum-3.exe"));
        assert!(!runs_as_installed_exe(""));
    }

    fn env() -> ScriptEnv {
        ScriptEnv::production(
            "SenseRemote",
            "com.carriez.SenseRemote",
            "/Users/ekip/Library/Preferences/com.carriez.SenseRemote",
            501,
        )
        .unwrap()
    }

    // M2 pattern: the script is fixed text plus checked values, printable ASCII only.
    #[test]
    fn mac_script_has_only_allowed_characters() {
        let script = mac_script(&env()).unwrap();
        for c in script.chars() {
            assert!(c == '\n' || (' '..='~').contains(&c), "{c:?}");
        }
        for forbidden in ['`', '\\', '\''] {
            assert!(!script.contains(forbidden), "{forbidden:?}");
        }
        // Every `$` is one of the script's own variables or a command substitution of `stat`.
        for (at, _) in script.match_indices('$') {
            let rest = &script[at + 1..];
            assert!(
                ["step", "app", "f\"", "code", "?", "(stat -f %u \"$f\")"]
                    .iter()
                    .any(|allowed| rest.starts_with(allowed)),
                "{}",
                &rest[..rest.len().min(20)]
            );
        }
    }

    #[test]
    fn mac_script_hardens_then_restarts_and_keeps_identity_and_role() {
        let script = mac_script(&env()).unwrap();
        let harden = script.find("chown -R root:wheel \"$app\"").unwrap();
        let chmod = script.find("chmod -R go-w \"$app\"").unwrap();
        let daemon = script
            .find("launchctl kickstart -k \"system/com.carriez.SenseRemote_service\"")
            .unwrap();
        let agent = script
            .find("launchctl kickstart -k \"gui/501/com.carriez.SenseRemote_server\"")
            .unwrap();
        assert!(harden < chmod && chmod < daemon && daemon < agent);
        assert!(script.contains("\"/Applications/SenseRemote.app/Contents/MacOS/service\""));
        // No role, config copy, plist rewrite or removal: the move keeps everything.
        for absent in ["--sense-install-state", "--write-plists", "cp ", "rm ", "bootout", "enroll"] {
            assert!(!script.contains(absent), "{absent}");
        }
    }

    #[test]
    fn mac_script_refuses_unsafe_values() {
        let mut bad = env();
        bad.app_bundle = "/Applications/Sense\"; reboot; \".app".to_owned();
        assert!(mac_script(&bad).is_err());
        let mut bad = env();
        bad.agent_label = "x$(id)".to_owned();
        assert!(mac_script(&bad).is_err());
    }
}
