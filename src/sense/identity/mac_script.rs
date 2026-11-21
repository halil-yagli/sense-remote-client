//! Sense Remote (Mac M2, plan 2026-11-21 §3.2): the pure part of the macOS installation: the
//! text of the privileged shell script, which values may enter it, how its result maps to the
//! wizard's codes.
//!
//! It lives under `identity` (compiled on every platform) and not in `install_mac`
//! (macOS-only), so these tests also run in the Linux and Windows CI jobs; on Unix they run
//! the generated script against a temporary directory with stub `launchctl` / `service`.
//!
//! Why the script exists (plan §10 risk 3): upstream's `install.scpt` copied the user's config
//! with `cp` into `/var/root/Library/Preferences/<org>.<app>/` without creating that directory
//! and without checking the result. On a fresh Mac the copy failed silently, root generated
//! its own ID and key pair, and the panel had registered another one (`bad_signature`). Here
//! the directory is created first, the copy is compared byte by byte, and any failed step
//! stops the installation with the step's name.
//!
//! Only these values enter the script: the role (`host|controller|both`), the setup info as
//! hex (`[0-9a-f]`), the numeric uid, and paths / launchd labels checked by `ScriptEnv::check`.
//! The script holds no secret: the sign-in token is in the user's *local* config, which is
//! never copied.

use super::super::{SenseRole, SetupInfo, MAX_SETUP_JSON_BYTES};
use std::time::Duration;

/// `service` flag that stores role and setup info as root (same value as
/// `install_mac::SERVICE_ARG_INSTALL_STATE`).
pub const SERVICE_ARG_INSTALL_STATE: &str = "--sense-install-state";
/// Upstream `service` flag that writes both launchd plists atomically.
pub const SERVICE_ARG_WRITE_PLISTS: &str = "--write-plists";
/// `PATH` of the privileged script: system directories only.
pub const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Same directory as `mac_state::STATE_DIR` (that module is macOS-only; a macOS test in
/// `install_mac` keeps the two equal).
pub const STATE_DIR: &str = "/Library/Application Support/SenseRemote";
const STATE_DIR_SUFFIX: &str = "/Application Support/SenseRemote";
/// The script writes `<marker><step>` to stderr when a step fails.
pub const FAILED_MARKER: &str = "sense-install-failed:";
/// Error prefix the wizard gets for a failed step (`install-failed:<step>`).
pub const INSTALL_FAILED_PREFIX: &str = "install-failed:";

pub const ERR_UNSAFE_VALUE: &str = "unsafe-script-value";
pub const ERR_CONFIG_PATH: &str = "config-path";
pub const ERR_INVALID_ROLE: &str = "invalid-role";
pub const ERR_INVALID_SETUP: &str = "invalid-setup";

/// Letters, digits, `.`, `_`, `-`; used for names that become part of paths and labels.
fn is_safe_token(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with(['-', '.'])
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Absolute path made of characters that mean nothing inside a double-quoted shell string
/// (no `"`, `$`, backtick, `\`, quote, newline ...), without `..` or empty components.
fn is_safe_path(value: &str) -> bool {
    value.starts_with('/')
        && value.len() > 1
        && !value.ends_with('/')
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/' | b' '))
        && value[1..]
            .split('/')
            .all(|part| !part.is_empty() && part != ".." && part != "." && part.trim() == part)
}

/// Setup info as the script and the state file accept it: lowercase hex of a `SetupInfo`.
pub fn check_setup_hex(hex: &str) -> Result<(), &'static str> {
    let well_formed = !hex.is_empty()
        && hex.len() % 2 == 0
        && hex.len() <= MAX_SETUP_JSON_BYTES * 2
        && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    if well_formed && SetupInfo::decode(hex).is_some() {
        Ok(())
    } else {
        Err(ERR_INVALID_SETUP)
    }
}

/// Root side of `service --sense-install-state <role> <hex>`: both values validated again
/// (the caller is a script, but the binary can be started by hand).
pub fn parse_install_state(role: &str, hex: &str) -> Result<(SenseRole, String), &'static str> {
    // No trimming: exactly one of the three words.
    let role = ["host", "controller", "both"]
        .contains(&role)
        .then(|| SenseRole::parse(role))
        .flatten()
        .ok_or(ERR_INVALID_ROLE)?;
    check_setup_hex(hex)?;
    Ok((role, hex.to_owned()))
}

/// `service` arguments → `(role, hex)` when this is the install-state call; `None` otherwise.
/// `Some(Err)` = it is that call but the argument count is wrong.
pub fn install_state_args(args: &[String]) -> Option<Result<(&str, &str), &'static str>> {
    if args.get(1).map(String::as_str) != Some(SERVICE_ARG_INSTALL_STATE) {
        return None;
    }
    Some(match args {
        [_, _, role, hex] => Ok((role.as_str(), hex.as_str())),
        _ => Err("usage"),
    })
}

/// The wizard may install only from `/Applications/<app>.app` (not from the dmg, not from an
/// App Translocation copy): launchd runs the daemon and the agent from that path.
pub fn runs_from_applications(exe: &str, app_name: &str) -> bool {
    is_safe_token(app_name)
        && exe.starts_with(&format!("/Applications/{app_name}.app/Contents/MacOS/"))
}

/// Everything the scripts need. Production values come from `production`; tests point the
/// paths at a temporary directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptEnv {
    /// `PATH` of the script.
    pub path: String,
    /// `/Applications/<app>.app`.
    pub app_bundle: String,
    /// Config file stem (`<app>.toml`, `<app>2.toml`).
    pub app_name: String,
    /// Config directory of the user who runs the wizard.
    pub user_config_dir: String,
    /// Config directory of root (the daemon reads its ID and key pair there).
    pub root_config_dir: String,
    pub daemon_label: String,
    pub agent_label: String,
    pub daemon_plist: String,
    pub agent_plist: String,
    pub state_dir: String,
    /// uid of the user who runs the wizard (GUI domain of the agent).
    pub uid: u32,
}

impl ScriptEnv {
    /// `full_name` = `<org>.<app>` (`common::get_full_name`), `user_config_dir` = directory of
    /// `Config::file()` in the wizard process.
    pub fn production(
        app_name: &str,
        full_name: &str,
        user_config_dir: &str,
        uid: u32,
    ) -> Result<Self, &'static str> {
        if !is_safe_token(app_name) || !is_safe_token(full_name) {
            return Err(ERR_UNSAFE_VALUE);
        }
        let prefs = format!("/Library/Preferences/{full_name}");
        // The root copy goes to the same relative place; a config somewhere else would mean
        // the daemon reads another file than the one copied.
        if !is_safe_path(user_config_dir) || !user_config_dir.ends_with(&prefs) {
            return Err(ERR_CONFIG_PATH);
        }
        let env = Self {
            path: SYSTEM_PATH.to_owned(),
            app_bundle: format!("/Applications/{app_name}.app"),
            app_name: app_name.to_owned(),
            user_config_dir: user_config_dir.to_owned(),
            root_config_dir: format!("/var/root{prefs}"),
            daemon_label: format!("{full_name}_service"),
            agent_label: format!("{full_name}_server"),
            daemon_plist: format!("/Library/LaunchDaemons/{full_name}_service.plist"),
            agent_plist: format!("/Library/LaunchAgents/{full_name}_server.plist"),
            state_dir: STATE_DIR.to_owned(),
            uid,
        };
        env.check()?;
        Ok(env)
    }

    /// No value may change the meaning of the script, whatever it contains.
    pub fn check(&self) -> Result<(), &'static str> {
        let paths = [
            &self.app_bundle,
            &self.user_config_dir,
            &self.root_config_dir,
            &self.daemon_plist,
            &self.agent_plist,
            &self.state_dir,
        ];
        let safe = paths.iter().all(|path| is_safe_path(path))
            && self.path.split(':').all(is_safe_path)
            && [&self.app_name, &self.daemon_label, &self.agent_label]
                .iter()
                .all(|token| is_safe_token(token))
            // `rm -rf` target of the uninstall script: only ever the Sense state directory.
            && self.state_dir.ends_with(STATE_DIR_SUFFIX)
            && self.user_config_dir != self.root_config_dir;
        if safe {
            Ok(())
        } else {
            Err(ERR_UNSAFE_VALUE)
        }
    }

    /// `gui/<uid>/<label>`: launchd target of the session agent.
    pub fn agent_target(&self) -> String {
        format!("gui/{}/{}", self.uid, self.agent_label)
    }

    pub fn daemon_target(&self) -> String {
        format!("system/{}", self.daemon_label)
    }
}

/// Shell script run as root by `install.scpt`. `state` = role and setup hex from the wizard;
/// `None` keeps the stored role (service started again outside the wizard).
///
/// Order (plan §3.2): checks → stop the old daemon / agent → create root's config directory
/// and copy the user's config (ID + key pair) → role into the state file → plists → daemon →
/// agent. When a step fails after the old jobs were stopped, they are started again.
pub fn install_script(
    env: &ScriptEnv,
    state: Option<(SenseRole, &str)>,
) -> Result<String, &'static str> {
    env.check()?;
    let state_step = match state {
        Some((role, hex)) => {
            check_setup_hex(hex)?;
            format!(
                "step=state\n\"$service\" {SERVICE_ARG_INSTALL_STATE} {} {hex}\n",
                role.as_str()
            )
        }
        None => String::new(),
    };
    let ScriptEnv {
        path,
        app_bundle,
        app_name,
        user_config_dir,
        root_config_dir,
        daemon_plist,
        agent_plist,
        ..
    } = env;
    let daemon = env.daemon_target();
    let agent = env.agent_target();
    let uid = env.uid;
    Ok(format!(
        r#"set -eu
PATH="{path}"; export PATH
umask 022
step=check
stopped=0
service="{app_bundle}/Contents/MacOS/service"
src="{user_config_dir}"
dst="{root_config_dir}"
start_jobs() {{
  launchctl enable "{daemon}" 2>/dev/null || true
  launchctl bootstrap system "{daemon_plist}" 2>/dev/null || launchctl load -w "{daemon_plist}" || return 1
  launchctl enable "{agent}" 2>/dev/null || true
  launchctl bootstrap "gui/{uid}" "{agent_plist}" 2>/dev/null || launchctl asuser {uid} launchctl load -w "{agent_plist}" || return 1
}}
on_exit() {{
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "{FAILED_MARKER}$step" >&2
    if [ "$stopped" -eq 1 ] && [ -e "{daemon_plist}" ] && [ -e "{agent_plist}" ]; then
      start_jobs >/dev/null 2>&1 || true
    fi
  fi
}}
trap on_exit EXIT
wait_gone() {{
  n=0
  while launchctl print "$1" >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -ge 10 ]; then break; fi
    sleep 1
  done
}}
copy_config() {{
  cp -f "$src/$1" "$dst/$1.new"
  chown 0:0 "$dst/$1.new"
  chmod 600 "$dst/$1.new"
  mv -f "$dst/$1.new" "$dst/$1"
  cmp -s "$src/$1" "$dst/$1"
}}
[ -x "$service" ]
step=identity-source
[ -f "$src/{app_name}.toml" ]
[ ! -L "$src/{app_name}.toml" ]
[ ! -L "$src/{app_name}2.toml" ]
step=stop
stopped=1
launchctl bootout "{daemon}" 2>/dev/null || true
launchctl bootout "{agent}" 2>/dev/null || true
wait_gone "{daemon}"
wait_gone "{agent}"
step=identity
(
  umask 077
  mkdir -p "$dst"
  chown 0:0 "$dst"
  chmod 700 "$dst"
  copy_config "{app_name}.toml"
  if [ -e "$src/{app_name}2.toml" ]; then copy_config "{app_name}2.toml"; fi
)
{state_step}step=plists
"$service" {SERVICE_ARG_WRITE_PLISTS}
step=start
start_jobs
stopped=0
step=done
"#
    ))
}

/// Shell script run as root by `uninstall.scpt`: stops both jobs, removes the plists and the
/// Sense state directory (role, setup info, envelope seq: a reinstall starts at seq 0, like
/// the deleted registry key on Windows). Root's config (ID + key pair) stays, so a reinstall
/// keeps the identity the panel knows.
pub fn uninstall_script(env: &ScriptEnv) -> Result<String, &'static str> {
    env.check()?;
    let ScriptEnv {
        path,
        daemon_plist,
        agent_plist,
        state_dir,
        ..
    } = env;
    let daemon = env.daemon_target();
    let agent = env.agent_target();
    Ok(format!(
        r#"set -u
PATH="{path}"; export PATH
launchctl bootout "{daemon}" 2>/dev/null || launchctl unload "{daemon_plist}" 2>/dev/null || true
launchctl bootout "{agent}" 2>/dev/null || true
rm -f "{daemon_plist}" "{agent_plist}"
rm -rf "{state_dir}"
if [ -e "{daemon_plist}" ] || [ -e "{agent_plist}" ] || [ -e "{state_dir}" ]; then
  echo "{FAILED_MARKER}remove" >&2
  exit 1
fi
"#
    ))
}

/// Result of the privileged script as `osascript` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScriptOutcome {
    Done,
    /// The administrator prompt was closed (AppleScript error -128).
    Cancelled,
    /// A step failed; the name is one of the script's own step names.
    Failed(String),
}

pub fn classify_osascript(success: bool, stderr: &str) -> ScriptOutcome {
    if success {
        return ScriptOutcome::Done;
    }
    if let Some(at) = stderr.find(FAILED_MARKER) {
        let step: String = stderr[at + FAILED_MARKER.len()..]
            .chars()
            .take_while(|c| c.is_ascii_lowercase() || *c == '-')
            .take(24)
            .collect();
        if !step.is_empty() {
            return ScriptOutcome::Failed(step);
        }
    }
    if stderr.contains("(-128)") {
        return ScriptOutcome::Cancelled;
    }
    ScriptOutcome::Failed("script".to_owned())
}

/// The wizard's result code for a script outcome (`cancelled` and `""` are the shared
/// contract; a failed step is an error text that is logged and shown as a general error).
pub fn install_code(outcome: &ScriptOutcome) -> String {
    match outcome {
        ScriptOutcome::Done => String::new(),
        ScriptOutcome::Cancelled => "cancelled".to_owned(),
        ScriptOutcome::Failed(step) => format!("{INSTALL_FAILED_PREFIX}{step}"),
    }
}

/// Polls `ready` until it is true or `timeout` has passed (`pause` sleeps `interval`).
pub fn wait_until(
    timeout: Duration,
    interval: Duration,
    mut ready: impl FnMut() -> bool,
    mut pause: impl FnMut(Duration),
) -> bool {
    let mut waited = Duration::ZERO;
    loop {
        if ready() {
            return true;
        }
        if waited >= timeout || interval.is_zero() {
            return false;
        }
        pause(interval);
        waited += interval;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const USER_DIR: &str = "/Users/ekip/Library/Preferences/com.carriez.SenseRemote";

    fn env() -> ScriptEnv {
        ScriptEnv::production("SenseRemote", "com.carriez.SenseRemote", USER_DIR, 501).unwrap()
    }

    fn setup_hex() -> String {
        SetupInfo {
            name: "Giriş \"ekranı\"; $(reboot) `x`".to_owned(),
            location: "Kat 2 & 'salon'".to_owned(),
        }
        .encode()
        .unwrap()
    }

    #[test]
    fn production_paths_are_the_launchd_and_root_config_paths() {
        let env = env();
        assert_eq!(env.app_bundle, "/Applications/SenseRemote.app");
        assert_eq!(
            env.root_config_dir,
            "/var/root/Library/Preferences/com.carriez.SenseRemote"
        );
        assert_eq!(
            env.daemon_plist,
            "/Library/LaunchDaemons/com.carriez.SenseRemote_service.plist"
        );
        assert_eq!(
            env.agent_plist,
            "/Library/LaunchAgents/com.carriez.SenseRemote_server.plist"
        );
        assert_eq!(env.daemon_target(), "system/com.carriez.SenseRemote_service");
        assert_eq!(env.agent_target(), "gui/501/com.carriez.SenseRemote_server");
        assert_eq!(env.state_dir, STATE_DIR);
        assert_eq!(env.path, SYSTEM_PATH);
    }

    #[test]
    fn config_outside_the_preferences_directory_is_refused() {
        for dir in [
            "/Users/ekip/Library/Application Support/com.carriez.SenseRemote",
            "/Users/ekip/Library/Preferences/com.carriez.RustDesk",
            "Users/ekip/Library/Preferences/com.carriez.SenseRemote",
            "/Users/../var/root/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a\"b/Library/Preferences/com.carriez.SenseRemote",
            "/Users/$(id)/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a`b`/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a\nb/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a;b/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a'b/Library/Preferences/com.carriez.SenseRemote",
            "/Users/a\\b/Library/Preferences/com.carriez.SenseRemote",
            "/Users//Library/Preferences/com.carriez.SenseRemote",
            "",
        ] {
            assert_eq!(
                ScriptEnv::production("SenseRemote", "com.carriez.SenseRemote", dir, 501),
                Err(ERR_CONFIG_PATH),
                "{dir:?}"
            );
        }
        // A home directory with a space or outside /Users is fine.
        for dir in [
            "/Users/sense ekip/Library/Preferences/com.carriez.SenseRemote",
            "/Volumes/Veri/ev/ekip/Library/Preferences/com.carriez.SenseRemote",
        ] {
            assert!(
                ScriptEnv::production("SenseRemote", "com.carriez.SenseRemote", dir, 501).is_ok()
            );
        }
        for (app, full) in [
            ("Sense Remote", "com.carriez.SenseRemote"),
            ("SenseRemote", "com.carriez.Sense;Remote"),
            ("", "com.carriez.SenseRemote"),
            ("-rf", "com.carriez.SenseRemote"),
            ("SenseRemote", "../x"),
        ] {
            assert_eq!(
                ScriptEnv::production(app, full, USER_DIR, 501),
                Err(ERR_UNSAFE_VALUE)
            );
        }
    }

    #[test]
    fn unsafe_values_never_reach_a_script() {
        let hex = setup_hex();
        let mut changes: Vec<Box<dyn Fn(&mut ScriptEnv)>> = Vec::new();
        for bad in ["/tmp/a\"b", "/tmp/$HOME", "/tmp/`id`", "/tmp/a\nb", "/tmp/a;b", "/tmp/../etc", "tmp/x", "/tmp/x/"] {
            changes.push(Box::new(move |e: &mut ScriptEnv| e.app_bundle = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.user_config_dir = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.root_config_dir = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.daemon_plist = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.agent_plist = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.path = format!("/usr/bin:{bad}")));
        }
        for bad in ["a b", "a;b", "$(x)", "", "a/b", "-x"] {
            changes.push(Box::new(move |e: &mut ScriptEnv| e.app_name = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.daemon_label = bad.to_owned()));
            changes.push(Box::new(move |e: &mut ScriptEnv| e.agent_label = bad.to_owned()));
        }
        // The uninstall script's `rm -rf` target is only ever the Sense state directory.
        for bad in ["/", "/Library", "/Library/Application Support", "/Users/ekip"] {
            changes.push(Box::new(move |e: &mut ScriptEnv| e.state_dir = bad.to_owned()));
        }
        changes.push(Box::new(|e: &mut ScriptEnv| e.root_config_dir = e.user_config_dir.clone()));
        for change in changes {
            let mut env = env();
            change(&mut env);
            assert_eq!(env.check(), Err(ERR_UNSAFE_VALUE), "{env:?}");
            assert!(install_script(&env, Some((SenseRole::Host, &hex))).is_err());
            assert!(uninstall_script(&env).is_err());
        }
    }

    #[test]
    fn only_lowercase_hex_of_a_setup_info_is_accepted() {
        let hex = setup_hex();
        assert_eq!(check_setup_hex(&hex), Ok(()));
        for bad in [
            String::new(),
            hex.to_uppercase(),
            format!("{hex}0"),
            format!("{hex};id"),
            format!("{hex} "),
            "$(id)".to_owned(),
            "zz".to_owned(),
            // hex, but not a SetupInfo
            hex::encode("[1,2]"),
            "7b".repeat(MAX_SETUP_JSON_BYTES + 1),
        ] {
            assert_eq!(check_setup_hex(&bad), Err(ERR_INVALID_SETUP), "{bad:?}");
            assert!(install_script(&env(), Some((SenseRole::Both, &bad))).is_err());
            assert!(parse_install_state("host", &bad).is_err());
        }
    }

    #[test]
    fn install_state_accepts_exactly_the_three_roles() {
        let hex = setup_hex();
        for (text, role) in [
            ("host", SenseRole::Host),
            ("controller", SenseRole::Controller),
            ("both", SenseRole::Both),
        ] {
            assert_eq!(parse_install_state(text, &hex), Ok((role, hex.clone())));
        }
        for bad in ["", "Host", " host", "host ", "admin", "host;id", "host\n"] {
            assert_eq!(parse_install_state(bad, &hex), Err(ERR_INVALID_ROLE), "{bad:?}");
        }
    }

    #[test]
    fn service_arguments_of_the_install_state_call() {
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(install_state_args(&args(&["service"])), None);
        assert_eq!(install_state_args(&args(&["service", "--write-plists"])), None);
        assert_eq!(
            install_state_args(&args(&["service", SERVICE_ARG_INSTALL_STATE, "host", "7b7d"])),
            Some(Ok(("host", "7b7d")))
        );
        for wrong in [
            args(&["service", SERVICE_ARG_INSTALL_STATE]),
            args(&["service", SERVICE_ARG_INSTALL_STATE, "host"]),
            args(&["service", SERVICE_ARG_INSTALL_STATE, "host", "7b7d", "x"]),
        ] {
            assert_eq!(install_state_args(&wrong), Some(Err("usage")));
        }
    }

    /// Property test of plan §3.2: whatever was typed on the setup screen, the script consists
    /// of the fixed text plus `[0-9a-f]`, and the typed text itself is not in it.
    #[test]
    fn script_text_has_only_allowed_characters_for_any_setup_text() {
        let nasty = [
            "\"; rm -rf / #",
            "$(reboot)",
            "`id`",
            "a\\b",
            "'tek' \"çift\"",
            "Müze — Kat 3 & Salon | x > y",
            "%PATH% ^ ! * ? [a] {b} ~",
            "satır\u{2028}ayırıcı",
        ];
        let fixed = install_script(&env(), None).unwrap();
        for name in nasty {
            for location in nasty {
                let hex = SetupInfo {
                    name: name.to_owned(),
                    location: location.to_owned(),
                }
                .encode()
                .unwrap();
                for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
                    let script = install_script(&env(), Some((role, &hex))).unwrap();
                    assert!(script.is_ascii());
                    assert!(!script.contains(name) && !script.contains(location));
                    let line = format!(
                        "step=state\n\"$service\" {SERVICE_ARG_INSTALL_STATE} {} {hex}\n",
                        role.as_str()
                    );
                    // Removing the one state line gives the fixed script: nothing else
                    // depends on the input.
                    assert_eq!(script.replacen(&line, "", 1), fixed);
                }
            }
        }
        for c in fixed.chars() {
            assert!(c == '\n' || (' '..='~').contains(&c), "{c:?}");
        }
    }

    #[test]
    fn install_steps_are_in_the_contract_order() {
        let hex = setup_hex();
        let script = install_script(&env(), Some((SenseRole::Host, &hex))).unwrap();
        let at = |needle: &str| {
            script
                .find(needle)
                .unwrap_or_else(|| panic!("{needle:?} missing"))
        };
        let order = [
            at("\n[ -x \"$service\" ]"),
            at("\n[ -f \"$src/SenseRemote.toml\" ]"),
            at("\nlaunchctl bootout \"system/com.carriez.SenseRemote_service\""),
            // Risk 3: the directory is created before anything is copied into it.
            at("\n  mkdir -p \"$dst\""),
            at("\n  copy_config \"SenseRemote.toml\""),
            at("copy_config \"SenseRemote2.toml\""),
            at("\"$service\" --sense-install-state host "),
            at("\"$service\" --write-plists"),
            at("\nstart_jobs\n"),
        ];
        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{order:?}");
        // Inside start_jobs: daemon first, then the agent in the user's GUI domain.
        assert!(
            at("launchctl bootstrap system \"/Library/LaunchDaemons/")
                < at("launchctl bootstrap \"gui/501\" \"/Library/LaunchAgents/")
        );
        assert!(script.contains("dst=\"/var/root/Library/Preferences/com.carriez.SenseRemote\""));
        assert!(script.contains("cmp -s \"$src/$1\" \"$dst/$1\""));
        assert!(script.starts_with("set -eu\nPATH=\"/usr/bin:/bin:/usr/sbin:/sbin\"; export PATH\n"));
    }

    #[test]
    fn scripts_never_touch_the_sign_in_or_name_upstream() {
        let hex = setup_hex();
        let install = install_script(&env(), Some((SenseRole::Host, &hex))).unwrap();
        let uninstall = uninstall_script(&env()).unwrap();
        for script in [&install, &uninstall] {
            let lower = script.to_lowercase();
            // The sign-in token is in `<app>_local.toml`; it must stay with the user.
            for word in ["_local", "access_token", "rustdesk", "password", "curl", "http"] {
                assert!(!lower.contains(word), "{word}");
            }
        }
        // Root's config (ID + key pair) survives an uninstall.
        assert!(!uninstall.contains("/var/root"));
        assert!(uninstall.contains("rm -rf \"/Library/Application Support/SenseRemote\"\n"));
        assert!(uninstall.contains(
            "rm -f \"/Library/LaunchDaemons/com.carriez.SenseRemote_service.plist\" \
             \"/Library/LaunchAgents/com.carriez.SenseRemote_server.plist\"\n"
        ));
    }

    #[test]
    fn without_a_role_the_stored_state_is_left_alone() {
        let script = install_script(&env(), None).unwrap();
        assert!(!script.contains(SERVICE_ARG_INSTALL_STATE));
        assert!(script.contains("copy_config \"SenseRemote.toml\""));
    }

    #[test]
    fn osascript_results_map_to_the_wizard_codes() {
        assert_eq!(classify_osascript(true, ""), ScriptOutcome::Done);
        assert_eq!(classify_osascript(true, "warning (-128)"), ScriptOutcome::Done);
        let cancelled = "0:123: execution error: User canceled. (-128)\n";
        assert_eq!(classify_osascript(false, cancelled), ScriptOutcome::Cancelled);
        // Other language of the system: only the number is stable.
        assert_eq!(
            classify_osascript(false, "execution error: Kullanıcı vazgeçti. (-128)"),
            ScriptOutcome::Cancelled
        );
        assert_eq!(
            classify_osascript(
                false,
                "0:99: execution error: cp: x: No such file\nsense-install-failed:identity (1)\n"
            ),
            ScriptOutcome::Failed("identity".to_owned())
        );
        assert_eq!(
            classify_osascript(false, "sense-install-failed:identity-source (1)"),
            ScriptOutcome::Failed("identity-source".to_owned())
        );
        assert_eq!(
            classify_osascript(false, "sense-install-failed:$(x)"),
            ScriptOutcome::Failed("script".to_owned())
        );
        assert_eq!(
            classify_osascript(false, "execution error: something (1)"),
            ScriptOutcome::Failed("script".to_owned())
        );

        assert_eq!(install_code(&ScriptOutcome::Done), "");
        assert_eq!(install_code(&ScriptOutcome::Cancelled), "cancelled");
        assert_eq!(
            install_code(&ScriptOutcome::Failed("state".to_owned())),
            "install-failed:state"
        );
    }

    #[test]
    fn only_the_applications_copy_may_install() {
        let ok = "/Applications/SenseRemote.app/Contents/MacOS/SenseRemote";
        assert!(runs_from_applications(ok, "SenseRemote"));
        for exe in [
            "/Volumes/Sense Remote/SenseRemote.app/Contents/MacOS/SenseRemote",
            "/private/var/folders/ab/T/AppTranslocation/1A2B/d/SenseRemote.app/Contents/MacOS/SenseRemote",
            "/Users/ekip/Applications/SenseRemote.app/Contents/MacOS/SenseRemote",
            "/Users/ekip/Downloads/SenseRemote.app/Contents/MacOS/SenseRemote",
            "/Applications/SenseRemote.app.evil/Contents/MacOS/SenseRemote",
            "/Applications/SenseRemote2.app/Contents/MacOS/SenseRemote",
            "/Applications/SenseRemote.app",
            "",
        ] {
            assert!(!runs_from_applications(exe, "SenseRemote"), "{exe}");
        }
        assert!(!runs_from_applications(ok, ""));
    }

    #[test]
    fn waiting_stops_when_ready_or_after_the_timeout() {
        let second = Duration::from_secs(1);
        let mut pauses = 0;
        assert!(wait_until(Duration::from_secs(15), second, || true, |_| pauses += 1));
        assert_eq!(pauses, 0);

        let mut polls = 0;
        let mut pauses = 0;
        assert!(wait_until(
            Duration::from_secs(15),
            second,
            || {
                polls += 1;
                polls == 4
            },
            |_| pauses += 1
        ));
        assert_eq!(pauses, 3);

        let mut polls = 0;
        let mut waited = Duration::ZERO;
        assert!(!wait_until(
            Duration::from_secs(15),
            second,
            || {
                polls += 1;
                false
            },
            |d| waited += d
        ));
        assert_eq!(waited, Duration::from_secs(15));
        assert_eq!(polls, 16);
        assert!(!wait_until(Duration::ZERO, Duration::ZERO, || false, |_| ()));
    }

    /// The generated script run by `/bin/sh` against a temporary directory: real `mkdir`,
    /// `cp`, `cmp`, `mv`, `chmod`, `rm`; stub `launchctl`, `chown`, `sleep` and `service`
    /// that write their arguments to a log.
    #[cfg(unix)]
    mod run {
        use super::*;
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            path::{Path, PathBuf},
            process::Command,
        };

        struct Sandbox {
            root: PathBuf,
            env: ScriptEnv,
        }

        impl Drop for Sandbox {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.root);
            }
        }

        fn stub(path: &Path, body: &str) {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }

        impl Sandbox {
            /// `service_body`: extra shell of the `service` stub before it exits 0.
            fn new(name: &str, service_body: &str) -> Self {
                let root = std::env::temp_dir()
                    .canonicalize()
                    .unwrap()
                    .join(format!("sense-m2-{}-{name}", std::process::id()));
                let _ = fs::remove_dir_all(&root);
                let dir = |rel: &str| root.join(rel).to_str().unwrap().to_owned();
                let log = dir("calls.log");
                let bin = root.join("bin");
                // `print` fails like launchd does for a job that is not loaded.
                stub(
                    &bin.join("launchctl"),
                    &format!("echo \"launchctl $*\" >> \"{log}\"\n[ \"$1\" != print ]"),
                );
                stub(&bin.join("chown"), &format!("echo \"chown $*\" >> \"{log}\""));
                stub(&bin.join("sleep"), "exit 0");
                let env = ScriptEnv {
                    path: format!("{}:/usr/bin:/bin", bin.to_str().unwrap()),
                    app_bundle: dir("Applications/SenseRemote.app"),
                    app_name: "SenseRemote".to_owned(),
                    user_config_dir: dir("Users/ekip/Library/Preferences/com.carriez.SenseRemote"),
                    // Deliberately missing, with missing parents: the fresh Mac of risk 3.
                    root_config_dir: dir("var/root/Library/Preferences/com.carriez.SenseRemote"),
                    daemon_label: "com.carriez.SenseRemote_service".to_owned(),
                    agent_label: "com.carriez.SenseRemote_server".to_owned(),
                    daemon_plist: dir("Library/LaunchDaemons/com.carriez.SenseRemote_service.plist"),
                    agent_plist: dir("Library/LaunchAgents/com.carriez.SenseRemote_server.plist"),
                    state_dir: dir("Library/Application Support/SenseRemote"),
                    uid: 501,
                };
                stub(
                    &Path::new(&env.app_bundle).join("Contents/MacOS/service"),
                    &format!("echo \"service $*\" >> \"{log}\"\n{service_body}"),
                );
                fs::create_dir_all(&env.user_config_dir).unwrap();
                let sandbox = Self { root, env };
                sandbox.write_user("SenseRemote.toml", "id = 'A1'\nkey_pair = 'user-key'\n");
                sandbox.write_user("SenseRemote2.toml", "options = 'user'\n");
                // The sign-in lives here and must never be copied.
                sandbox.write_user("SenseRemote_local.toml", "access_token = 'not-copied'\n");
                sandbox
            }

            fn write_user(&self, file: &str, content: &str) {
                fs::write(Path::new(&self.env.user_config_dir).join(file), content).unwrap();
            }

            fn root_file(&self, file: &str) -> PathBuf {
                Path::new(&self.env.root_config_dir).join(file)
            }

            fn run(&self, script: &str) -> (bool, String) {
                let output = Command::new("/bin/sh").arg("-c").arg(script).output().unwrap();
                (
                    output.status.success(),
                    String::from_utf8_lossy(&output.stderr).into_owned(),
                )
            }

            fn install(&self, state: Option<(SenseRole, &str)>) -> (bool, String) {
                self.run(&install_script(&self.env, state).unwrap())
            }

            fn calls(&self) -> Vec<String> {
                fs::read_to_string(self.root.join("calls.log"))
                    .unwrap_or_default()
                    .lines()
                    .map(str::to_owned)
                    .collect()
            }

            fn call_index(&self, prefix: &str) -> Option<usize> {
                self.calls().iter().position(|call| call.starts_with(prefix))
            }
        }

        #[test]
        fn fresh_mac_gets_the_users_identity_in_roots_config() {
            let sandbox = Sandbox::new("fresh", "");
            let hex = setup_hex();
            assert!(!Path::new(&sandbox.env.root_config_dir).exists());
            let (ok, stderr) = sandbox.install(Some((SenseRole::Host, &hex)));
            assert!(ok, "{stderr}");
            assert_eq!(classify_osascript(ok, &stderr), ScriptOutcome::Done);

            // Same ID and key pair for root (daemon) and the user who registered them.
            for file in ["SenseRemote.toml", "SenseRemote2.toml"] {
                let user = fs::read(Path::new(&sandbox.env.user_config_dir).join(file)).unwrap();
                assert_eq!(fs::read(sandbox.root_file(file)).unwrap(), user);
                let mode = fs::metadata(sandbox.root_file(file)).unwrap().permissions().mode();
                assert_eq!(mode & 0o777, 0o600);
            }
            let dir_mode = fs::metadata(&sandbox.env.root_config_dir).unwrap().permissions().mode();
            assert_eq!(dir_mode & 0o777, 0o700);
            // Host: no sign-in anywhere near root's config.
            let copied: Vec<String> = fs::read_dir(&sandbox.env.root_config_dir)
                .unwrap()
                .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                .collect();
            assert_eq!(copied.len(), 2, "{copied:?}");
            assert!(!sandbox.root_file("SenseRemote_local.toml").exists());

            let state = sandbox
                .call_index(&format!("service --sense-install-state host {hex}"))
                .expect("state stored");
            let plists = sandbox.call_index("service --write-plists").unwrap();
            let stop = sandbox
                .call_index("launchctl bootout system/com.carriez.SenseRemote_service")
                .unwrap();
            let daemon = sandbox.call_index("launchctl bootstrap system ").unwrap();
            let agent = sandbox.call_index("launchctl bootstrap gui/501 ").unwrap();
            assert!(stop < state && state < plists && plists < daemon && daemon < agent);
            let calls = sandbox.calls();
            assert_eq!(calls.iter().filter(|c| c.starts_with("service ")).count(), 2);
            assert!(calls.contains(&format!("chown 0:0 {}", sandbox.env.root_config_dir)));
        }

        #[test]
        fn reinstall_replaces_an_identity_root_made_up() {
            let sandbox = Sandbox::new("reinstall", "");
            fs::create_dir_all(&sandbox.env.root_config_dir).unwrap();
            fs::write(
                sandbox.root_file("SenseRemote.toml"),
                "id = 'ROOT'\nkey_pair = 'root-made-this-up'\n",
            )
            .unwrap();
            let hex = setup_hex();
            let (ok, stderr) = sandbox.install(Some((SenseRole::Both, &hex)));
            assert!(ok, "{stderr}");
            assert_eq!(
                fs::read_to_string(sandbox.root_file("SenseRemote.toml")).unwrap(),
                "id = 'A1'\nkey_pair = 'user-key'\n"
            );
            assert!(!sandbox.root_file("SenseRemote.toml.new").exists());
        }

        #[test]
        fn second_config_file_is_optional() {
            let sandbox = Sandbox::new("no-config2", "");
            fs::remove_file(Path::new(&sandbox.env.user_config_dir).join("SenseRemote2.toml"))
                .unwrap();
            let (ok, stderr) = sandbox.install(Some((SenseRole::Controller, &setup_hex())));
            assert!(ok, "{stderr}");
            assert!(sandbox.root_file("SenseRemote.toml").exists());
            assert!(!sandbox.root_file("SenseRemote2.toml").exists());
        }

        #[test]
        fn missing_identity_stops_before_anything_is_changed() {
            let sandbox = Sandbox::new("no-identity", "");
            fs::remove_file(Path::new(&sandbox.env.user_config_dir).join("SenseRemote.toml"))
                .unwrap();
            let (ok, stderr) = sandbox.install(Some((SenseRole::Host, &setup_hex())));
            assert!(!ok);
            assert_eq!(
                classify_osascript(ok, &stderr),
                ScriptOutcome::Failed("identity-source".to_owned())
            );
            // The running daemon was not stopped, no role stored, nothing started.
            assert_eq!(sandbox.calls(), Vec::<String>::new());
            assert!(!Path::new(&sandbox.env.root_config_dir).exists());
        }

        #[test]
        fn symlinked_config_is_not_followed_as_root() {
            let sandbox = Sandbox::new("symlink", "");
            let secret = sandbox.root.join("root-only-file");
            fs::write(&secret, "secret").unwrap();
            for file in ["SenseRemote.toml", "SenseRemote2.toml"] {
                let fresh = Sandbox::new(&format!("symlink-{file}"), "");
                let link = Path::new(&fresh.env.user_config_dir).join(file);
                fs::remove_file(&link).unwrap();
                std::os::unix::fs::symlink(&secret, &link).unwrap();
                let (ok, stderr) = fresh.install(Some((SenseRole::Host, &setup_hex())));
                assert!(!ok);
                assert_eq!(
                    classify_osascript(ok, &stderr),
                    ScriptOutcome::Failed("identity-source".to_owned())
                );
                assert!(!Path::new(&fresh.env.root_config_dir).exists());
            }
        }

        #[test]
        fn failed_state_write_starts_nothing_new_and_restores_the_old_jobs() {
            // `service --sense-install-state` fails (not root, bad value, state file rules).
            let sandbox = Sandbox::new("state-fails", "[ \"$1\" != --sense-install-state ]");
            // An earlier installation: both plists exist.
            for plist in [&sandbox.env.daemon_plist, &sandbox.env.agent_plist] {
                fs::create_dir_all(Path::new(plist).parent().unwrap()).unwrap();
                fs::write(plist, "<plist/>").unwrap();
            }
            let (ok, stderr) = sandbox.install(Some((SenseRole::Host, &setup_hex())));
            assert!(!ok);
            assert_eq!(
                classify_osascript(ok, &stderr),
                ScriptOutcome::Failed("state".to_owned())
            );
            assert_eq!(sandbox.call_index("service --write-plists"), None);
            // Stopped for the copy, so the old daemon and agent are started again: a Host
            // stays reachable after a failed reinstall.
            let stop = sandbox.call_index("launchctl bootout system/").unwrap();
            let again = sandbox.call_index("launchctl bootstrap system ").unwrap();
            assert!(stop < again);
            assert!(sandbox.call_index("launchctl bootstrap gui/501 ").is_some());
        }

        #[test]
        fn failed_first_install_starts_no_job() {
            let sandbox = Sandbox::new("first-fails", "[ \"$1\" != --sense-install-state ]");
            let (ok, _) = sandbox.install(Some((SenseRole::Host, &setup_hex())));
            assert!(!ok);
            assert_eq!(sandbox.call_index("launchctl bootstrap"), None);
            assert_eq!(sandbox.call_index("launchctl load"), None);
        }

        #[test]
        fn missing_service_binary_is_the_first_failure() {
            let sandbox = Sandbox::new("no-service", "");
            fs::remove_file(Path::new(&sandbox.env.app_bundle).join("Contents/MacOS/service"))
                .unwrap();
            let (ok, stderr) = sandbox.install(Some((SenseRole::Host, &setup_hex())));
            assert!(!ok);
            assert_eq!(
                classify_osascript(ok, &stderr),
                ScriptOutcome::Failed("check".to_owned())
            );
            assert_eq!(sandbox.calls(), Vec::<String>::new());
        }

        #[test]
        fn restart_without_a_role_copies_the_identity_and_keeps_the_state() {
            let sandbox = Sandbox::new("no-role", "");
            let (ok, stderr) = sandbox.install(None);
            assert!(ok, "{stderr}");
            assert_eq!(sandbox.call_index("service --sense-install-state"), None);
            assert!(sandbox.call_index("service --write-plists").is_some());
            assert!(sandbox.root_file("SenseRemote.toml").exists());
        }

        #[test]
        fn uninstall_removes_plists_and_state_but_keeps_the_identity() {
            let sandbox = Sandbox::new("uninstall", "");
            let (ok, stderr) = sandbox.install(Some((SenseRole::Host, &setup_hex())));
            assert!(ok, "{stderr}");
            for plist in [&sandbox.env.daemon_plist, &sandbox.env.agent_plist] {
                fs::create_dir_all(Path::new(plist).parent().unwrap()).unwrap();
                fs::write(plist, "<plist/>").unwrap();
            }
            fs::create_dir_all(&sandbox.env.state_dir).unwrap();
            fs::write(Path::new(&sandbox.env.state_dir).join("state.json"), "{}").unwrap();
            let other = Path::new(&sandbox.env.state_dir).parent().unwrap().join("Other");
            fs::create_dir_all(&other).unwrap();

            let (ok, stderr) = sandbox.run(&uninstall_script(&sandbox.env).unwrap());
            assert!(ok, "{stderr}");
            assert!(!Path::new(&sandbox.env.daemon_plist).exists());
            assert!(!Path::new(&sandbox.env.agent_plist).exists());
            assert!(!Path::new(&sandbox.env.state_dir).exists());
            assert!(other.exists());
            assert!(sandbox.root_file("SenseRemote.toml").exists());
            assert!(sandbox
                .calls()
                .contains(&"launchctl bootout gui/501/com.carriez.SenseRemote_server".to_owned()));
            // Running it again on a clean computer is not an error.
            let (ok, _) = sandbox.run(&uninstall_script(&sandbox.env).unwrap());
            assert!(ok);
        }
    }
}
