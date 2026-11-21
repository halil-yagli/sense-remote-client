//! Sense Remote (Mac M2, plan 2026-11-21 §3.2): installation from the Sense setup wizard on
//! macOS. The wizard is the app the user opened from `/Applications`; it stays unprivileged
//! and asks for the administrator password once.
//!
//! 1. `prepare_install(role, info_json)` (validation, role of this process);
//! 2. ID + device key pair in the user config file before the copy (Windows:
//!    `store_identity_for_import`);
//! 3. one synchronous privileged script (osascript, administrator prompt `PROMPT_INSTALL`):
//!    `mkdir -p` the root config directory → copy and compare the two user config files →
//!    `service --sense-install-state <role> <setup_hex>` → plists → daemon bootstrap → agent;
//! 4. registration and, on a Host, removing the local sign-in (existing flow:
//!    `enroll::remember_installed_role` here, `enroll::finish` in `sense::finish_install`).
//!
//! The role ends up in the root-owned state file (`mac_state`): the user can not change it.
//! Only the role (`host|controller|both`), `setup_hex` (`[0-9a-f]`), the uid and checked paths
//! go into the script; the script text and every decision are in `identity::mac_script`
//! (pure, tested on every platform). The sign-in token is never copied to root and nothing
//! secret is logged (the script text is not logged either).

use super::{
    identity::{
        self,
        mac_script::{self, ScriptEnv, ScriptOutcome},
    },
    mac_state, SenseRole, SetupInfo,
};
use hbb_common::{config, libc, log};
use std::time::Duration;

/// `install` results (strings the wizard maps to Turkish text). `""` = installed.
pub const INSTALL_OK: &str = "";
/// The administrator password prompt was closed (osascript `-128`).
pub const INSTALL_CANCELLED: &str = "cancelled";
pub const INSTALL_NOT_SIGNED_IN: &str = "not-signed-in";
/// The app does not run from `/Applications/SenseRemote.app` (App Translocation, opened in
/// the dmg).
pub const INSTALL_NOT_IN_APPLICATIONS: &str = "not-in-applications";
/// The daemon did not read `state.json` / the agent was not loaded within
/// `DAEMON_TIMEOUT_SECS`.
pub const INSTALL_DAEMON_TIMEOUT: &str = "daemon-timeout";
/// Result on platforms / builds without the installation.
pub const UNSUPPORTED: &str = "unsupported";

pub const DAEMON_TIMEOUT_SECS: u64 = 15;

/// Text of the administrator password prompt (install / uninstall).
pub const PROMPT_INSTALL: &str =
    "Sense Remote, bu bilgisayara kurulmak için yönetici izni istiyor.";
pub const PROMPT_UNINSTALL: &str = "Sense Remote'u kaldırmak için yönetici izni gerekiyor.";

/// `service` flag that stores role and setup info as root: `--sense-install-state <role> <hex>`.
pub const SERVICE_ARG_INSTALL_STATE: &str = mac_script::SERVICE_ARG_INSTALL_STATE;

const INSTALL_SCRIPT: &str = "install.scpt";
const UNINSTALL_SCRIPT: &str = "uninstall.scpt";

fn uid() -> u32 {
    // The wizard and the agent belong to the user who opened the app.
    unsafe { libc::getuid() }
}

/// Paths and launchd names of this installation, from this process's own config path.
fn script_env() -> Result<ScriptEnv, &'static str> {
    let config_file = config::Config::file();
    let config_dir = config_file
        .parent()
        .and_then(|dir| dir.to_str())
        .unwrap_or_default();
    ScriptEnv::production(
        &crate::get_app_name(),
        &crate::get_full_name(),
        config_dir,
        uid(),
    )
}

/// ID and key pair in this process's config file before root copies it (K3-2 on macOS).
/// `get_key_pair` writes a new key pair from a background thread, so the file is polled.
fn store_identity_for_copy() -> Result<(), &'static str> {
    let _ = config::Config::get_id();
    let _ = config::Config::get_key_pair();
    let path = config::Config::file();
    let stored = identity::wait_stored_for_import(
        30,
        || config::load_path::<config::Config>(path.clone()).is_empty(),
        || std::thread::sleep(Duration::from_millis(100)),
    );
    if stored.is_err() {
        log::error!("Sense Remote: ID or device key not stored before installation");
    }
    stored
}

/// Runs the privileged install script and maps its result. `state` = `None` keeps the role.
fn run_install_script(env: &ScriptEnv, state: Option<(SenseRole, &str)>) -> String {
    let script = match mac_script::install_script(env, state) {
        Ok(script) => script,
        Err(err) => return err.to_owned(),
    };
    let outcome =
        match crate::platform::macos::sense_run_privileged(INSTALL_SCRIPT, &script, PROMPT_INSTALL)
        {
            Ok((success, stderr)) => {
                let outcome = mac_script::classify_osascript(success, &stderr);
                if let ScriptOutcome::Failed(step) = &outcome {
                    // stderr of launchctl / cp and the step marker; the script holds no secret.
                    let tail: String = stderr.chars().take(600).collect();
                    log::error!("Sense Remote: installation step {step} failed: {tail}");
                }
                outcome
            }
            Err(err) => {
                log::error!("Sense Remote: could not run the installation script: {err}");
                ScriptOutcome::Failed("osascript".to_owned())
            }
        };
    mac_script::install_code(&outcome)
}

/// The state file has the chosen role and launchd knows the daemon and this user's agent.
fn installed_as(env: &ScriptEnv, role: SenseRole) -> bool {
    let state_ok = matches!(mac_state::read(), Ok(Some(state)) if state.role == Some(role));
    state_ok
        && crate::platform::macos::sense_launchctl_ok(&["print", env.daemon_target().as_str()])
        && crate::platform::macos::sense_launchctl_ok(&["print", env.agent_target().as_str()])
}

/// Installs from the Sense setup wizard (`sense::install` on macOS). `role` is
/// `host|controller|both`, `info_json` is `SetupInfo` as JSON. Returns one of the `INSTALL_*`
/// codes, otherwise an error text (logged; the wizard shows a general error).
pub fn install(_options: &str, _path: String, role: &str, info_json: &str) -> String {
    // Sense Remote (wave 3 K-GİRİŞ): only a signed-in Sense employee installs; the sign-in
    // token registers the computer right after.
    #[cfg(feature = "flutter")]
    if !super::enroll::is_signed_in() {
        return INSTALL_NOT_SIGNED_IN.to_owned();
    }
    let exe = std::env::current_exe().unwrap_or_default();
    if !mac_script::runs_from_applications(
        exe.to_str().unwrap_or_default(),
        &crate::get_app_name(),
    ) {
        return INSTALL_NOT_IN_APPLICATIONS.to_owned();
    }
    if let Err(err) = super::prepare_install(role, info_json) {
        return err.to_owned();
    }
    // Same values `prepare_install` just accepted, as the hex the state file stores.
    let chosen = SenseRole::parse(role).zip(
        serde_json::from_str::<SetupInfo>(info_json)
            .ok()
            .and_then(|info| info.normalized().ok())
            .and_then(|info| info.encode().ok()),
    );
    let Some((role, setup_hex)) = chosen else {
        return "invalid-info".to_owned();
    };
    let env = match script_env() {
        Ok(env) => env,
        Err(err) => {
            log::error!("Sense Remote: installation not possible from this account: {err}");
            return err.to_owned();
        }
    };
    if let Err(err) = store_identity_for_copy() {
        return err.to_owned();
    }
    let code = run_install_script(&env, Some((role, &setup_hex)));
    if code != INSTALL_OK {
        return code;
    }
    let ready = mac_script::wait_until(
        Duration::from_secs(DAEMON_TIMEOUT_SECS),
        Duration::from_millis(500),
        || installed_as(&env, role),
        std::thread::sleep,
    );
    if !ready {
        log::error!("Sense Remote: daemon or agent not ready after the installation");
        return INSTALL_DAEMON_TIMEOUT.to_owned();
    }
    #[cfg(feature = "flutter")]
    super::enroll::remember_installed_role(role);
    log::info!("Sense Remote: installed as {}", role.as_str());
    INSTALL_OK.to_owned()
}

/// Upstream's "start the service" (`platform::is_installed_daemon(true)`): the same
/// privileged script without a role, so the stored role and setup info stay. Returns the
/// same codes as `install`.
pub fn start_service_again() -> String {
    let env = match script_env() {
        Ok(env) => env,
        Err(err) => return err.to_owned(),
    };
    if let Err(err) = store_identity_for_copy() {
        return err.to_owned();
    }
    run_install_script(&env, None)
}

/// Runs the privileged uninstall script (`platform::uninstall_service`): stops daemon and
/// agent, removes the plists and the Sense state directory. Root's config (ID + key pair)
/// stays, so a reinstall keeps the identity the panel knows.
pub fn run_uninstall_script() -> Result<(), String> {
    let env = script_env()?;
    let script = mac_script::uninstall_script(&env)?;
    let (success, stderr) =
        crate::platform::macos::sense_run_privileged(UNINSTALL_SCRIPT, &script, PROMPT_UNINSTALL)
            .map_err(|err| err.to_string())?;
    match mac_script::classify_osascript(success, &stderr) {
        ScriptOutcome::Done => Ok(()),
        ScriptOutcome::Cancelled => {
            log::info!("Sense Remote: uninstall cancelled at the administrator prompt");
            Ok(())
        }
        ScriptOutcome::Failed(step) => Err(format!("uninstall step {step} failed")),
    }
}

/// Security review G4-1: paths of this bundle that root executes but that are not root's
/// (owner, group / other write access, symbolic link). Empty = fine. The install script
/// makes them root's; this is the daemon's own look at start.
pub fn untrusted_bundle_paths() -> Vec<String> {
    use std::os::unix::fs::MetadataExt;
    let app = format!("/Applications/{}.app", crate::get_app_name());
    Vec::from(mac_script::root_executed_paths(&app, &crate::get_app_name()))
        .into_iter()
        .filter(|path| match std::fs::symlink_metadata(path) {
            Ok(meta) => !mac_script::bundle_file_trusted(
                meta.uid(),
                meta.mode(),
                meta.file_type().is_symlink(),
            ),
            Err(_) => true,
        })
        .collect()
}

/// Leaves the setup wizard (`sense::finish_install` on macOS, after `enroll::finish`). The
/// wizard runs inside the installed app with the role it had at its own start, so it never
/// continues as the app: it exits, and with `open_app` a new instance starts first and reads
/// the installed role.
pub fn finish_install(open_app: bool) {
    if open_app {
        let app = format!("/Applications/{}.app", crate::get_app_name());
        if let Err(err) = std::process::Command::new("/usr/bin/open")
            .arg("-n")
            .arg(&app)
            .spawn()
        {
            log::error!("Sense Remote: could not open {app}: {err}");
        }
        // Leave `open` a moment to hand over to launch services.
        std::thread::sleep(Duration::from_millis(300));
    }
    std::process::exit(0);
}

/// Root side of `service --sense-install-state <role> <setup_hex>`: validates both values
/// and writes them with `mac_state::update` (keeps the stored `envelope_seq`). `Err` when not
/// root or a value is not allowed; the `service` binary then exits with 1.
pub fn store_install_state(role: &str, setup_hex: &str) -> Result<(), String> {
    let (role, setup_hex) = mac_script::parse_install_state(role, setup_hex)?;
    // `mac_state::update` refuses too; checked here as well so the flag is a no-op for every
    // other user whatever the state module does.
    if unsafe { libc::geteuid() } != 0 {
        return Err(mac_state::ERR_NOT_ROOT.to_owned());
    }
    mac_state::update(move |state| {
        state.role = Some(role);
        state.setup_hex = setup_hex;
    })
}

/// FFI `install_sense_restart_agent`: restarts the session agent
/// (`launchctl kickstart -k gui/<uid>/<label>`) after the Screen Recording permission was
/// granted. `""` on success, otherwise an error.
pub fn restart_agent() -> String {
    let env = match script_env() {
        Ok(env) => env,
        Err(err) => return err.to_owned(),
    };
    if crate::platform::macos::sense_launchctl_ok(&["kickstart", "-k", env.agent_target().as_str()]) {
        String::new()
    } else {
        log::error!("Sense Remote: could not restart the session agent");
        "restart-failed".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_never_name_the_upstream_app() {
        for text in [PROMPT_INSTALL, PROMPT_UNINSTALL] {
            assert!(text.starts_with("Sense Remote"));
            assert!(!text.to_lowercase().contains("rustdesk"));
            // The text is an AppleScript argument, not script source; still no quote or
            // line break that could surprise the prompt.
            assert!(!text.contains(['"', '\\', '\n']));
        }
    }

    #[test]
    fn codes_match_the_wizard_contract() {
        assert_eq!(mac_script::install_code(&ScriptOutcome::Done), INSTALL_OK);
        assert_eq!(
            mac_script::install_code(&ScriptOutcome::Cancelled),
            INSTALL_CANCELLED
        );
        assert_eq!(SERVICE_ARG_INSTALL_STATE, "--sense-install-state");
        // The uninstall script removes exactly the directory the state module writes.
        assert_eq!(mac_script::STATE_DIR, mac_state::STATE_DIR);
    }

    #[test]
    fn install_state_is_refused_without_root_or_with_bad_values() {
        let hex = SetupInfo {
            name: "Test".to_owned(),
            location: String::new(),
        }
        .encode()
        .unwrap();
        assert_eq!(
            store_install_state("admin", &hex),
            Err(mac_script::ERR_INVALID_ROLE.to_owned())
        );
        assert_eq!(
            store_install_state("host", "zz"),
            Err(mac_script::ERR_INVALID_SETUP.to_owned())
        );
        // CI and developers do not run the tests as root: nothing is written.
        if unsafe { libc::geteuid() } != 0 {
            assert_eq!(
                store_install_state("host", &hex),
                Err(mac_state::ERR_NOT_ROOT.to_owned())
            );
        }
    }

    #[test]
    fn installation_needs_the_applications_copy() {
        // The test binary does not run from /Applications/<app>.app.
        let exe = std::env::current_exe().unwrap();
        assert!(!mac_script::runs_from_applications(
            exe.to_str().unwrap(),
            &crate::get_app_name()
        ));
    }
}
