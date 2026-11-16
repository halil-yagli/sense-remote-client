//! Sense Remote: the role chosen at installation and the computer info entered on the
//! Sense setup screen.
//!
//! One build serves every computer; the role is picked during installation:
//! - Host: the team connects to this computer (incoming only, settings locked).
//! - Controller: this computer connects to others (outgoing only).
//! - Host + Controller: both directions, settings locked.
//!
//! Windows: the elevated installer writes the role to
//! `HKEY_LOCAL_MACHINE\SOFTWARE\SenseRemote` (`Role`, `Setup`). Only administrators and
//! SYSTEM can write there; standard users can read it but cannot change it. Every process
//! (service, server, tray, UI) reads it at start in `load_custom_client`, so the role ends up
//! in the code-level `HARD_SETTINGS` / `BUILTIN_SETTINGS`, which no user setting and no
//! server strategy can override. Later the role will change only through a signed panel
//! payload (wave 2b).
//!
//! MAC-SONRA: macOS stores nothing yet (`installed_role` returns `None`, full UI). The plan is
//! a root-owned file written by the installer package.

use base::config::keys;
use hbb_common::{config, log};
use serde_derive::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Mutex};

// Sense Remote: signed panel envelopes (wave 2). Verification only; the heartbeat applies them
// (`hbbs_http/sync.rs`, task I4), until then nothing calls these modules outside tests.
#[allow(dead_code)]
pub mod envelope;
#[allow(dead_code)]
pub mod envelope_keys;
#[allow(dead_code)]
pub mod envelope_seq;

/// Registry key (under HKLM) that holds the installed role and setup info.
pub const REG_SUBKEY: &str = "SOFTWARE\\SenseRemote";
const REG_KEY_FOR_CMD: &str = "HKEY_LOCAL_MACHINE\\SOFTWARE\\SenseRemote";
const REG_VALUE_ROLE: &str = "Role";
const REG_VALUE_SETUP: &str = "Setup";

/// Publisher shown in Windows "Installed apps".
pub const PUBLISHER: &str = "Sense Department";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SenseRole {
    Host,
    Controller,
    Both,
}

impl SenseRole {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "host" => Some(Self::Host),
            "controller" => Some(Self::Controller),
            "both" => Some(Self::Both),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::Controller => "controller",
            Self::Both => "both",
        }
    }
}

/// Hard settings any role may set. They are cleared before a role is applied so that a
/// role change in the same process (e.g. the installer) never leaves a stale lock behind.
const ROLE_HARD_KEYS: [&str; 3] = ["conn-type", "disable-settings", "disable-ab"];
const ROLE_BUILTIN_KEYS: [&str; 1] = [keys::OPTION_ALLOW_COMMAND_LINE_SETTINGS_WHEN_SETTINGS_DISABLED];

type Settings = Vec<(&'static str, &'static str)>;

/// (hard settings, builtin settings) for a role. Hard settings are what RustDesk reads for
/// custom clients (`config::is_incoming_only`, `is_outgoing_only`, `is_disable_settings`...).
/// Host keeps the elevated command line allowed so the team can set the permanent password
/// with `SenseRemote.exe --password ...` even though the settings page is locked.
pub fn role_settings(role: Option<SenseRole>) -> (Settings, Settings) {
    let locks = || -> (Settings, Settings) {
        (
            vec![("disable-settings", "Y"), ("disable-ab", "Y")],
            vec![(
                keys::OPTION_ALLOW_COMMAND_LINE_SETTINGS_WHEN_SETTINGS_DISABLED,
                "Y",
            )],
        )
    };
    match role {
        Some(SenseRole::Host) => {
            let (mut hard, builtin) = locks();
            hard.insert(0, ("conn-type", "incoming"));
            (hard, builtin)
        }
        Some(SenseRole::Controller) => (vec![("conn-type", "outgoing")], vec![]),
        Some(SenseRole::Both) => locks(),
        None => (vec![], vec![]),
    }
}

/// Pure part of `apply_role`: replaces the role-managed keys in the given maps.
fn apply_role_to(
    role: Option<SenseRole>,
    hard: &mut HashMap<String, String>,
    builtin: &mut HashMap<String, String>,
) {
    for k in ROLE_HARD_KEYS {
        hard.remove(k);
    }
    for k in ROLE_BUILTIN_KEYS {
        builtin.remove(k);
    }
    let (hard_settings, builtin_settings) = role_settings(role);
    for (k, v) in hard_settings {
        hard.insert(k.to_owned(), v.to_owned());
    }
    for (k, v) in builtin_settings {
        builtin.insert(k.to_owned(), v.to_owned());
    }
}

pub fn apply_role(role: Option<SenseRole>) {
    let mut hard = config::HARD_SETTINGS.write().unwrap();
    let mut builtin = config::BUILTIN_SETTINGS.write().unwrap();
    apply_role_to(role, &mut hard, &mut builtin);
}

/// Role written by the installer, `None` when not installed (or not Windows yet).
pub fn installed_role() -> Option<SenseRole> {
    let value = read_reg_value(REG_VALUE_ROLE)?;
    let role = SenseRole::parse(&value);
    if role.is_none() {
        log::error!("Sense Remote: unknown installed role {value:?}, no role applied");
    }
    role
}

/// Called once at start (`load_custom_client`) in every process.
pub fn apply_installed_role() {
    apply_role(installed_role());
}

/// Computer info from the setup screen. Kept on the computer until the panel exists
/// (wave 3), then sent with the device registration.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SetupInfo {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub projects: Vec<String>,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub note: String,
}

pub const MAX_NAME_CHARS: usize = 64;
pub const MAX_PROJECTS: usize = 10;
pub const MAX_PROJECT_CHARS: usize = 48;
pub const MAX_LOCATION_CHARS: usize = 96;
pub const MAX_NOTE_CHARS: usize = 300;
/// Keeps the hex value well under the 8191-character cmd.exe line limit.
const MAX_SETUP_JSON_BYTES: usize = 2048;

fn clean_text(value: &str, max_chars: usize, error: &'static str) -> Result<String, &'static str> {
    let value = value.trim();
    if value.chars().any(|c| c.is_control()) || value.chars().count() > max_chars {
        return Err(error);
    }
    Ok(value.to_owned())
}

impl SetupInfo {
    /// Trims, validates and de-duplicates. Errors are short keys the setup screen shows.
    pub fn normalized(&self) -> Result<Self, &'static str> {
        let name = clean_text(&self.name, MAX_NAME_CHARS, "invalid-name")?;
        if name.is_empty() {
            return Err("invalid-name");
        }
        let mut projects: Vec<String> = Vec::new();
        for project in &self.projects {
            let project = clean_text(project, MAX_PROJECT_CHARS, "invalid-project")?;
            if !project.is_empty()
                && !projects.iter().any(|p| p.to_lowercase() == project.to_lowercase())
            {
                projects.push(project);
            }
        }
        if projects.len() > MAX_PROJECTS {
            return Err("invalid-project");
        }
        Ok(Self {
            name,
            projects,
            location: clean_text(&self.location, MAX_LOCATION_CHARS, "invalid-location")?,
            note: clean_text(&self.note, MAX_NOTE_CHARS, "invalid-note")?,
        })
    }

    /// Hex of the JSON: only `0-9a-f`, so it is safe inside the elevated cmd script whatever
    /// the user typed (quotes, `&`, `%`, `^`...).
    pub fn encode(&self) -> Result<String, &'static str> {
        let json = serde_json::to_vec(self).map_err(|_| "invalid-info")?;
        if json.len() > MAX_SETUP_JSON_BYTES {
            return Err("info-too-long");
        }
        Ok(hex::encode(json))
    }

    pub fn decode(value: &str) -> Option<Self> {
        let bytes = hex::decode(value.trim()).ok()?;
        serde_json::from_slice(&bytes).ok()
    }
}

/// Setup info written by the installer (for wave 3: device registration).
#[allow(dead_code)]
pub fn installed_setup_info() -> Option<SetupInfo> {
    SetupInfo::decode(&read_reg_value(REG_VALUE_SETUP)?)
}

/// Lines for the elevated install script that store the role and setup info.
pub fn install_commands(role: SenseRole, encoded_info: &str) -> String {
    format!(
        "reg add \"{REG_KEY_FOR_CMD}\" /f /v {REG_VALUE_ROLE} /t REG_SZ /d {role}\r\n\
         reg add \"{REG_KEY_FOR_CMD}\" /f /v {REG_VALUE_SETUP} /t REG_SZ /d {encoded_info}\r\n",
        role = role.as_str(),
    )
}

/// Line for the elevated uninstall script.
pub fn uninstall_commands() -> String {
    format!("reg delete \"{REG_KEY_FOR_CMD}\" /f > nul 2>&1\r\n")
}

/// Choices from the setup screen, waiting for `install_me` in this (installer) process.
static PENDING_INSTALL: Mutex<Option<String>> = Mutex::new(None);

/// Validates the setup screen choices, applies the role to this process (the installer
/// decides service / tray / config import from it) and remembers the registry commands for
/// `install_me`. `info_json` is `SetupInfo` as JSON.
pub fn prepare_install(role: &str, info_json: &str) -> Result<(), &'static str> {
    let role = SenseRole::parse(role).ok_or("invalid-role")?;
    let info: SetupInfo = serde_json::from_str(info_json).map_err(|_| "invalid-info")?;
    let encoded = info.normalized()?.encode()?;
    apply_role(Some(role));
    *PENDING_INSTALL.lock().unwrap() = Some(install_commands(role, &encoded));
    Ok(())
}

/// Commands to add to the install script; empty for installs that did not come from the
/// Sense setup screen (e.g. `--silent-install`), which keep the existing role.
pub fn pending_install_commands() -> String {
    PENDING_INSTALL.lock().unwrap().clone().unwrap_or_default()
}

/// Shortcut names people see (desktop, start menu).
pub fn shortcut_name() -> String {
    crate::common::get_app_display_name()
}

pub fn uninstall_shortcut_name() -> String {
    format!("{}'u kaldır", shortcut_name())
}

#[cfg(windows)]
fn read_reg_value(name: &str) -> Option<String> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(REG_SUBKEY)
        .ok()?
        .get_value::<String, _>(name)
        .ok()
}

#[cfg(not(windows))]
fn read_reg_value(_name: &str) -> Option<String> {
    // MAC-SONRA: read the root-owned role file.
    None
}

/// Installs from the Sense setup screen. Returns "" on success, "cancelled" when the
/// administrator prompt was declined, otherwise an error to show.
#[cfg(windows)]
pub fn install(options: &str, path: String, role: &str, info_json: &str) -> String {
    if let Err(err) = prepare_install(role, info_json) {
        return err.to_owned();
    }
    // silent = true: the setup screen shows "Kuruldu" and opens the app on request.
    match crate::platform::windows::install_me(options, path, true, false) {
        Ok(()) => String::new(),
        Err(err) => {
            let cancelled = err
                .downcast_ref::<::windows::core::Error>()
                .is_some_and(|err| {
                    err.code() == ::windows::Win32::Foundation::ERROR_CANCELLED.to_hresult()
                });
            if cancelled {
                "cancelled".to_owned()
            } else {
                log::error!("Sense Remote installation failed: {err:#}");
                format!("{err:#}")
            }
        }
    }
}

#[cfg(not(windows))]
pub fn install(_options: &str, _path: String, _role: &str, _info_json: &str) -> String {
    // MAC-SONRA: macOS installs from the dmg; the role step comes with the pkg installer.
    "unsupported".to_owned()
}

/// Leaves the setup screen, optionally opening the installed app first.
pub fn finish_install(open_app: bool) {
    #[cfg(windows)]
    if open_app {
        let (_, _, _, exe) = crate::platform::windows::get_install_info();
        if let Err(err) = std::process::Command::new(&exe).spawn() {
            log::error!("Failed to open {exe}: {err}");
        }
    }
    #[cfg(not(windows))]
    let _ = open_app;
    std::process::exit(0);
}

// ---------------------------------------------------------------------------------------------
// Sense Remote: panel API security (wave 2).
//
// The panel at `API_SERVER` is the only server that may see the panel access token or answer
// API requests. The ID / relay server stays RustDesk's free public one, so:
// 1. the API address is fixed at build time; no user setting, custom ID server, exe-name
//    license or panel strategy can move it (and it never falls back to admin.rustdesk.com);
// 2. API requests are never retried through the ID server's TCP proxy: a failure is returned;
// 3. the access token is never put in messages to the ID / relay server;
// 4. certificate checking for TLS can not be switched off.
// ---------------------------------------------------------------------------------------------

/// Panel API address, fixed at build time (`SENSE_API_SERVER`, no trailing slash).
pub const API_SERVER: &str = match option_env!("SENSE_API_SERVER") {
    Some(url) => url,
    None => "https://remote.snsdpt.com",
};

const fn starts_with(value: &str, prefix: &str) -> bool {
    let (value, prefix) = (value.as_bytes(), prefix.as_bytes());
    if value.len() < prefix.len() {
        return false;
    }
    let mut i = 0;
    while i < prefix.len() {
        if value[i] != prefix[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// `https://<host>` (no path, no trailing slash). Plain `http://` only for a panel on this
/// computer (`localhost` / `127.0.0.1`), so a development build can talk to a local panel;
/// it never leaves the machine.
pub const fn is_valid_api_server(url: &str) -> bool {
    let bytes = url.as_bytes();
    let rest_from = if starts_with(url, "https://") {
        8
    } else if starts_with(url, "http://localhost:") || starts_with(url, "http://127.0.0.1:") {
        7
    } else {
        return false;
    };
    if bytes.len() <= rest_from {
        return false;
    }
    let mut i = rest_from;
    while i < bytes.len() {
        let c = bytes[i];
        // No path, query, user info or whitespace: only the origin.
        if c == b'/' || c == b'?' || c == b'#' || c == b'@' || c == b'\\' || c <= b' ' {
            return false;
        }
        i += 1;
    }
    true
}

// A wrong `SENSE_API_SERVER` stops the build instead of producing an insecure client.
const _: () = assert!(
    is_valid_api_server(API_SERVER),
    "SENSE_API_SERVER must be https://<host>[:port] (http only for localhost)"
);

/// The API address every caller gets (`common::get_api_server`). Its inputs (the
/// `api-server` and `custom-rendezvous-server` settings) are deliberately not used.
pub fn api_server() -> String {
    API_SERVER.to_owned()
}

/// API requests may go through the ID server's TCP proxy (`use-raw-tcp-for-api` or the
/// fallback after a connection error / 5xx). Never in our build: the public ID server is not
/// ours, and its answer would be handled as if it came from the panel.
pub const API_TCP_PROXY_ALLOWED: bool = false;

/// Pure form of the upstream fallback decision with the Sense rule applied:
/// `upstream_eligible` is what RustDesk would decide (WebSocket off, target is the API host).
pub fn api_tcp_proxy_allowed(upstream_eligible: bool) -> bool {
    API_TCP_PROXY_ALLOWED && upstream_eligible
}

/// Token to put in messages to the ID / relay server (`PunchHoleRequest`, `RequestRelay`,
/// `HealthCheck`). Always empty: the panel access token belongs to the panel only, and the
/// ID server is RustDesk's public one. Without a token the client connects like any
/// signed-out RustDesk client.
pub fn token_for_rendezvous(_access_token: &str) -> String {
    String::new()
}

/// Settings pinned in `OVERWRITE_SETTINGS`: neither the user, a custom.txt nor a panel
/// strategy can change them. `api-server` is pinned too so the settings page shows the real
/// (fixed) address.
pub fn security_overwrite_settings() -> [(&'static str, &'static str); 2] {
    [
        (keys::OPTION_API_SERVER, API_SERVER),
        (keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK, "N"),
    ]
}

fn apply_security_to(overwrite: &mut HashMap<String, String>) {
    for (k, v) in security_overwrite_settings() {
        overwrite.insert(k.to_owned(), v.to_owned());
    }
}

/// Called at the end of `load_custom_client` in every process.
pub fn apply_security_settings() {
    apply_security_to(&mut config::OVERWRITE_SETTINGS.write().unwrap());
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLI: &str = keys::OPTION_ALLOW_COMMAND_LINE_SETTINGS_WHEN_SETTINGS_DISABLED;

    #[test]
    fn api_server_is_https_panel_origin() {
        assert!(is_valid_api_server(API_SERVER));
        assert!(API_SERVER.starts_with("https://"));
        assert!(!API_SERVER.ends_with('/'));
        assert_eq!(api_server(), API_SERVER);
        assert!(!crate::common::is_public(API_SERVER));
        if option_env!("SENSE_API_SERVER").is_none() {
            assert_eq!(API_SERVER, "https://remote.snsdpt.com");
        }
    }

    #[test]
    fn api_server_validation() {
        for ok in [
            "https://remote.snsdpt.com",
            "https://remote.snsdpt.com:8443",
            "http://localhost:3000",
            "http://127.0.0.1:8787",
        ] {
            assert!(is_valid_api_server(ok), "{ok}");
        }
        for bad in [
            "",
            "https://",
            "http://remote.snsdpt.com",
            "http://localhost",
            "http://localhost.evil.test",
            "ws://remote.snsdpt.com",
            "remote.snsdpt.com",
            "https://remote.snsdpt.com/",
            "https://remote.snsdpt.com/api",
            "https://remote.snsdpt.com?x=1",
            "https://user@evil.test",
            "https://remote.snsdpt.com evil",
            "HTTPS://remote.snsdpt.com",
        ] {
            assert!(!is_valid_api_server(bad), "{bad}");
        }
    }

    #[test]
    fn get_api_server_ignores_every_input() {
        for (api, custom) in [
            ("", ""),
            ("https://admin.rustdesk.com", ""),
            ("https://evil.test", "evil.test"),
            ("", "rs-ny.rustdesk.com"),
            ("", "10.0.0.1:21116"),
            ("http://remote.snsdpt.com:21114", "remote.snsdpt.com"),
        ] {
            assert_eq!(
                crate::common::get_api_server(api.to_owned(), custom.to_owned()),
                API_SERVER,
                "api={api:?} custom={custom:?}"
            );
        }
        // Heartbeat, audit and strategy stay on (they are off for a "public" address).
        assert_eq!(
            crate::common::get_audit_server("x".to_owned(), "y".to_owned(), "conn".to_owned()),
            format!("{API_SERVER}/api/audit/conn")
        );
    }

    #[test]
    fn api_requests_never_use_the_tcp_proxy() {
        assert!(!API_TCP_PROXY_ALLOWED);
        assert!(!api_tcp_proxy_allowed(true));
        assert!(!api_tcp_proxy_allowed(false));
    }

    #[test]
    fn access_token_never_goes_to_the_id_server() {
        assert_eq!(token_for_rendezvous("panel-issued-test-value"), "");
        assert_eq!(token_for_rendezvous(""), "");
    }

    #[test]
    fn security_settings_are_pinned_over_user_and_custom_values() {
        let mut overwrite = HashMap::from([
            (keys::OPTION_API_SERVER.to_owned(), "https://evil.test".to_owned()),
            (keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK.to_owned(), "Y".to_owned()),
            ("other".to_owned(), "kept".to_owned()),
        ]);
        apply_security_to(&mut overwrite);
        assert_eq!(overwrite[keys::OPTION_API_SERVER], API_SERVER);
        assert_eq!(overwrite[keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK], "N");
        assert_eq!(overwrite["other"], "kept");
    }

    #[test]
    fn tls_certificate_check_cannot_be_skipped() {
        // Pure check (no global OVERWRITE_SETTINGS write: other tests in this process compare
        // `Config::get_options()` with the saved file). Settings are read
        // OVERWRITE > user > default (`config::get_or`), so the pinned "N" wins over a user "Y",
        // `allow_insecure_tls_fallback()` is false and `get_cached_tls_accept_invalid_cert`
        // always returns `Some(false)`: no client retries with certificate checking off.
        let mut overwrite = HashMap::new();
        apply_security_to(&mut overwrite);
        let user = HashMap::from([(
            keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK.to_owned(),
            "Y".to_owned(),
        )]);
        let key = keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK;
        let effective = overwrite
            .get(key)
            .or_else(|| user.get(key))
            .cloned()
            .unwrap_or_default();
        assert_eq!(effective, "N");
        assert!(!config::option2bool(key, &effective));
    }

    #[test]
    fn role_parse_round_trip() {
        for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
            assert_eq!(SenseRole::parse(role.as_str()), Some(role));
        }
        assert_eq!(SenseRole::parse(" host "), Some(SenseRole::Host));
        assert_eq!(SenseRole::parse("incoming"), None);
        assert_eq!(SenseRole::parse(""), None);
        assert_eq!(SenseRole::parse("Host"), None);
    }

    #[test]
    fn host_is_incoming_and_locked_with_cli_password() {
        let (hard, builtin) = role_settings(Some(SenseRole::Host));
        assert!(hard.contains(&("conn-type", "incoming")));
        assert!(hard.contains(&("disable-settings", "Y")));
        assert!(hard.contains(&("disable-ab", "Y")));
        assert_eq!(builtin, vec![(CLI, "Y")]);
        assert!(config::option2bool(CLI, "Y"));
    }

    #[test]
    fn controller_is_outgoing_only() {
        let (hard, builtin) = role_settings(Some(SenseRole::Controller));
        assert_eq!(hard, vec![("conn-type", "outgoing")]);
        assert!(builtin.is_empty());
    }

    #[test]
    fn both_has_no_conn_type_but_same_locks() {
        let (hard, builtin) = role_settings(Some(SenseRole::Both));
        assert!(hard.iter().all(|(k, _)| *k != "conn-type"));
        assert!(hard.contains(&("disable-settings", "Y")));
        assert!(hard.contains(&("disable-ab", "Y")));
        assert_eq!(builtin, vec![(CLI, "Y")]);
    }

    #[test]
    fn no_role_changes_nothing() {
        assert_eq!(role_settings(None), (vec![], vec![]));
    }

    #[test]
    fn every_role_key_is_managed() {
        for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
            let (hard, builtin) = role_settings(Some(role));
            assert!(hard.iter().all(|(k, _)| ROLE_HARD_KEYS.contains(k)));
            assert!(builtin.iter().all(|(k, _)| ROLE_BUILTIN_KEYS.contains(k)));
        }
    }

    #[test]
    fn switching_role_clears_stale_locks_and_keeps_other_keys() {
        let mut hard = HashMap::from([("disable-account".to_owned(), "Y".to_owned())]);
        let mut builtin = HashMap::from([("hide-tray".to_owned(), "Y".to_owned())]);
        apply_role_to(Some(SenseRole::Host), &mut hard, &mut builtin);
        assert_eq!(hard.get("conn-type").map(String::as_str), Some("incoming"));
        apply_role_to(Some(SenseRole::Both), &mut hard, &mut builtin);
        assert_eq!(hard.get("conn-type"), None);
        assert_eq!(hard.get("disable-settings").map(String::as_str), Some("Y"));
        apply_role_to(Some(SenseRole::Controller), &mut hard, &mut builtin);
        assert_eq!(hard.get("conn-type").map(String::as_str), Some("outgoing"));
        assert_eq!(hard.get("disable-settings"), None);
        assert_eq!(hard.get("disable-ab"), None);
        assert_eq!(builtin.get(CLI), None);
        assert_eq!(hard.get("disable-account").map(String::as_str), Some("Y"));
        assert_eq!(builtin.get("hide-tray").map(String::as_str), Some("Y"));
    }

    fn info() -> SetupInfo {
        SetupInfo {
            name: "  Galeri kioskı ".to_owned(),
            projects: vec![
                "Örnek Müze".to_owned(),
                " ".to_owned(),
                "örnek müze".to_owned(),
                "Ekip".to_owned(),
            ],
            location: "Galeri 1".to_owned(),
            note: "2 ekran \"LED\" & 100% ^ | <>".to_owned(),
        }
    }

    #[test]
    fn info_is_trimmed_and_deduplicated() {
        let info = info().normalized().unwrap();
        assert_eq!(info.name, "Galeri kioskı");
        assert_eq!(info.projects, vec!["Örnek Müze", "Ekip"]);
        assert_eq!(info.location, "Galeri 1");
    }

    #[test]
    fn info_rejects_bad_input() {
        let mut bad = info();
        bad.name = "   ".to_owned();
        assert_eq!(bad.normalized(), Err("invalid-name"));
        let mut bad = info();
        bad.name = "a\r\nb".to_owned();
        assert_eq!(bad.normalized(), Err("invalid-name"));
        let mut bad = info();
        bad.name = "x".repeat(MAX_NAME_CHARS + 1);
        assert_eq!(bad.normalized(), Err("invalid-name"));
        let mut bad = info();
        bad.projects = (0..=MAX_PROJECTS).map(|i| format!("P{i}")).collect();
        assert_eq!(bad.normalized(), Err("invalid-project"));
        let mut bad = info();
        bad.note = "n".repeat(MAX_NOTE_CHARS + 1);
        assert_eq!(bad.normalized(), Err("invalid-note"));
        let mut ok = info();
        ok.name = "ı".repeat(MAX_NAME_CHARS);
        assert!(ok.normalized().is_ok());
    }

    #[test]
    fn info_encoding_is_cmd_safe_and_round_trips() {
        let info = info().normalized().unwrap();
        let encoded = info.encode().unwrap();
        assert!(encoded.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(SetupInfo::decode(&encoded), Some(info));
        assert_eq!(SetupInfo::decode("zz"), None);
    }

    #[test]
    fn largest_valid_info_fits_the_cmd_line() {
        let info = SetupInfo {
            name: "ğ".repeat(MAX_NAME_CHARS),
            projects: (0..MAX_PROJECTS)
                .map(|i| format!("{i}{}", "ş".repeat(MAX_PROJECT_CHARS - 1)))
                .collect(),
            location: "ü".repeat(MAX_LOCATION_CHARS),
            note: "ö".repeat(MAX_NOTE_CHARS),
        }
        .normalized()
        .unwrap();
        let commands = install_commands(SenseRole::Both, &info.encode().unwrap());
        assert!(commands.lines().all(|line| line.len() < 8000));
    }

    #[test]
    fn install_commands_write_role_and_setup_to_hklm() {
        let commands = install_commands(SenseRole::Host, "7b7d");
        assert!(commands.contains(
            "reg add \"HKEY_LOCAL_MACHINE\\SOFTWARE\\SenseRemote\" /f /v Role /t REG_SZ /d host"
        ));
        assert!(commands.contains("/v Setup /t REG_SZ /d 7b7d"));
        assert!(uninstall_commands()
            .starts_with("reg delete \"HKEY_LOCAL_MACHINE\\SOFTWARE\\SenseRemote\" /f"));
    }

    #[test]
    fn prepare_install_rejects_unknown_role_and_bad_json() {
        assert_eq!(prepare_install("admin", "{}"), Err("invalid-role"));
        assert_eq!(prepare_install("host", "not json"), Err("invalid-info"));
        assert_eq!(prepare_install("host", "{\"name\":\"\"}"), Err("invalid-name"));
        assert_eq!(pending_install_commands(), "");
    }
}
