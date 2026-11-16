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

#[cfg(test)]
mod tests {
    use super::*;

    const CLI: &str = keys::OPTION_ALLOW_COMMAND_LINE_SETTINGS_WHEN_SETTINGS_DISABLED;

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
