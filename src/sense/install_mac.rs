//! Sense Remote (Mac M0, plan §3.2): installation from the Sense setup wizard on macOS.
//!
//! M0 is the skeleton only: signatures and return codes are the contract (wizard: M3, home
//! screen: M7); the bodies have safe defaults, so macOS behaves as before ("unsupported").
//! M2 fills this file in:
//! 1. `prepare_install(role, info_json)` (validation, role of this process);
//! 2. ID + device key pair in the user config before the copy (Windows:
//!    `store_identity_for_import`);
//! 3. one synchronous privileged script (osascript, administrator prompt `PROMPT_INSTALL`):
//!    `mkdir -p` the root config directory → copy the two user config files →
//!    `service --sense-install-state <role> <setup_hex>` → plists → daemon bootstrap → agent;
//! 4. registration and, on a Host, removing the local sign-in (existing flow).
//! Only the role (`host|controller|both`) and `setup_hex` (`[0-9a-f]`) go into the script.

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
/// Skeleton result until M2 implements the installation.
pub const UNSUPPORTED: &str = "unsupported";

pub const DAEMON_TIMEOUT_SECS: u64 = 15;

/// Text of the administrator password prompt (install / uninstall).
pub const PROMPT_INSTALL: &str =
    "Sense Remote, bu bilgisayara kurulmak için yönetici izni istiyor.";
pub const PROMPT_UNINSTALL: &str = "Sense Remote'u kaldırmak için yönetici izni gerekiyor.";

/// `service` flag that stores role and setup info as root: `--sense-install-state <role> <hex>`.
pub const SERVICE_ARG_INSTALL_STATE: &str = "--sense-install-state";

/// Installs from the Sense setup wizard (`sense::install` on macOS). `role` is
/// `host|controller|both`, `info_json` is `SetupInfo` as JSON. Returns one of the `INSTALL_*`
/// codes, otherwise an error text (logged; the wizard shows a general error).
pub fn install(_options: &str, _path: String, _role: &str, _info_json: &str) -> String {
    UNSUPPORTED.to_owned()
}

/// Leaves the setup wizard (`sense::finish_install` on macOS, after `enroll::finish`). On
/// macOS the wizard runs inside the installed app, so M2 / M3 decide what "leave" means; the
/// skeleton exits like before.
pub fn finish_install(_open_app: bool) {
    std::process::exit(0);
}

/// Root side of `service --sense-install-state <role> <setup_hex>`: validates both values
/// and writes them with `mac_state::update` (keeps the stored `envelope_seq`). `Err` when not
/// root or a value is not allowed; the `service` binary then exits with 1.
pub fn store_install_state(_role: &str, _setup_hex: &str) -> Result<(), String> {
    Err(UNSUPPORTED.to_owned())
}

/// FFI `install_sense_restart_agent`: restarts the session agent
/// (`launchctl kickstart -k gui/<uid>/<label>`) after the Screen Recording permission was
/// granted. `""` on success, otherwise an error.
pub fn restart_agent() -> String {
    UNSUPPORTED.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_never_name_the_upstream_app() {
        for text in [PROMPT_INSTALL, PROMPT_UNINSTALL] {
            assert!(text.starts_with("Sense Remote"));
            assert!(!text.to_lowercase().contains("rustdesk"));
        }
    }

    #[test]
    fn skeleton_installs_nothing() {
        assert_eq!(install("", String::new(), "host", "{}"), UNSUPPORTED);
        assert_eq!(restart_agent(), UNSUPPORTED);
        assert!(store_install_state("host", "").is_err());
    }
}
