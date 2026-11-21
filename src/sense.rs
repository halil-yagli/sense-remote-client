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
//! macOS (plan 2026-11-21 §3.1): the role, setup info and envelope seq live in the root-owned
//! `/Library/Application Support/SenseRemote/state.json` (`mac_state`). Only root writes it:
//! the privileged installer step (`install_mac`) and the daemon when it applies a signed panel
//! envelope (`mac_apply`). Every process reads it at start like the registry on Windows; a
//! missing file means "not installed" (`installed_role` is `None`, full UI), a file that breaks
//! the rules (owner, mode, symlink, content) gives no role either and is logged.

use base::config::keys;
use hbb_common::{config, log};
use serde_derive::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Mutex};

// Sense Remote: signed panel envelopes (wave 2). `envelope*` verify (I2); `envelope_apply` is the
// heartbeat side (I4: what may be applied, what is reported); `hbbs_http/sync.rs` calls it.
#[allow(dead_code)]
pub mod envelope;
#[allow(dead_code)]
pub mod envelope_apply;
#[allow(dead_code)]
pub mod envelope_keys;
#[allow(dead_code)]
pub mod envelope_seq;
// Sense Remote: sign-in and registration from the setup wizard (wave 3 I6).
// Only the Flutter UI has the setup wizard and the panel sign-in (`hbbs_http::account`).
#[cfg(feature = "flutter")]
pub mod enroll;
// Sense Remote (K3-2): the service imports the ID + key pair the panel registers.
pub mod identity;

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
    // Sense Remote (wave 3 K-YEREL): the Host home screen reads name and location as built-in
    // options (`sense-name`, `sense-location`); users can not change built-in options.
    let info = installed_setup_info().unwrap_or_default();
    let mut builtin = config::BUILTIN_SETTINGS.write().unwrap();
    for (k, v) in setup_builtin_settings(&info) {
        builtin.insert(k.to_owned(), v);
    }
    // Sense Remote (wave 3 I9): "Sürüm n" on the About page reads the build's Sense version as a
    // built-in option, so users can not change it either.
    let (k, v) = version_builtin_setting(report::app_version());
    builtin.insert(k.to_owned(), v);
}

/// Built-in option names for the setup info (read by the Host home screen).
pub const OPTION_SENSE_NAME: &str = "sense-name";
pub const OPTION_SENSE_LOCATION: &str = "sense-location";

/// Sense Remote: built-in option with the Sense version number (`SENSE_VERSION` at build time).
pub const OPTION_SENSE_VERSION: &str = "sense-version";

/// Pure part: the version as a plain number (`"3"`); empty without `SENSE_VERSION` (local
/// builds), so the About page falls back to its own value instead of showing a wrong one.
fn version_builtin_setting(version: Option<u32>) -> (&'static str, String) {
    (
        OPTION_SENSE_VERSION,
        version.map(|v| v.to_string()).unwrap_or_default(),
    )
}

fn setup_builtin_settings(info: &SetupInfo) -> [(&'static str, String); 2] {
    [
        (OPTION_SENSE_NAME, info.name.clone()),
        (OPTION_SENSE_LOCATION, info.location.clone()),
    ]
}

/// Sense Remote: stores a role from a verified panel envelope (Host <-> Host + Controller only,
/// plan K-ROL). Runs in the `--server` process (SYSTEM), which may write HKLM; the tray and UI
/// processes read the new role at their next start.
#[cfg(windows)]
pub fn store_role(role: SenseRole) -> Result<(), String> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey(REG_SUBKEY)
        .map_err(|err| err.to_string())?;
    key.set_value(REG_VALUE_ROLE, &role.as_str().to_owned())
        .map_err(|err| err.to_string())
}

/// Sense Remote (Mac M0, plan §3.3): on macOS the `--server` process is the session user and
/// can not write the root-owned state file. Only the daemon stores a role (`mac_apply`, with
/// `mac_state::update`), after verifying the envelope itself.
#[cfg(target_os = "macos")]
pub fn store_role(_role: SenseRole) -> Result<(), String> {
    Err("daemon-only".to_owned())
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn store_role(_role: SenseRole) -> Result<(), String> {
    Err("unsupported platform".to_owned())
}

/// Computer info from the setup screen that stays on the computer (HKLM `Setup`).
/// Sense Remote (wave 3 K-YEREL): only name and location. Project names may contain a
/// customer's name, so they are never written here; projects and the note go only to the
/// panel with the registration (`enroll`). Older installs with `projects` / `note` still
/// decode (unknown fields are ignored) and lose them on the next install.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SetupInfo {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub location: String,
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

fn clean_name(value: &str) -> Result<String, &'static str> {
    let name = clean_text(value, MAX_NAME_CHARS, "invalid-name")?;
    if name.is_empty() {
        return Err("invalid-name");
    }
    Ok(name)
}

impl SetupInfo {
    /// Trims, validates and de-duplicates. Errors are short keys the setup screen shows.
    pub fn normalized(&self) -> Result<Self, &'static str> {
        Ok(Self {
            name: clean_name(&self.name)?,
            location: clean_text(&self.location, MAX_LOCATION_CHARS, "invalid-location")?,
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

/// Setup info written by the installer (name and location for the Host home screen).
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

/// Sense Remote (Mac M0, plan §3.1): macOS reads the same two values from the root-owned state
/// file. A file that breaks the rules (owner, mode, symlink, content) is an error in the log
/// and no value: no role is applied rather than one a user could have planted.
#[cfg(target_os = "macos")]
fn read_reg_value(name: &str) -> Option<String> {
    mac_value_from(mac_state::read(), name)
}

/// The value `name` out of one read of the state file (`mac_state::read` / `read_in`).
/// Sense Remote (K4-11): long-running processes read the role again and again, so a broken
/// file is logged at most once a minute, with the number of reads the line stands for.
#[cfg(target_os = "macos")]
fn mac_value_from(
    read: Result<Option<mac_state::MacState>, String>,
    name: &str,
) -> Option<String> {
    match read {
        Ok(state) => mac_state_value(&state?, name),
        Err(err) => {
            hbb_common::throttled_log!(
                std::time::Duration::from_secs(60),
                error,
                "Sense Remote: state file not usable, {name} not read: {err}"
            );
            None
        }
    }
}

/// Pure part: the Windows registry value names mapped to the fields of the macOS state.
#[cfg(target_os = "macos")]
fn mac_state_value(state: &mac_state::MacState, name: &str) -> Option<String> {
    match name {
        REG_VALUE_ROLE => state.role.map(|role| role.as_str().to_owned()),
        REG_VALUE_SETUP => Some(state.setup_hex.clone()).filter(|hex| !hex.is_empty()),
        _ => None,
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
fn read_reg_value(_name: &str) -> Option<String> {
    None
}

/// Installs from the Sense setup screen. Returns "" on success, "cancelled" when the
/// administrator prompt was declined, otherwise an error to show.
#[cfg(windows)]
pub fn install(options: &str, path: String, role: &str, info_json: &str) -> String {
    // Sense Remote (wave 3 K-GİRİŞ): only a signed-in Sense employee installs from the setup
    // screen; the sign-in token also registers the computer right after.
    #[cfg(feature = "flutter")]
    if !enroll::is_signed_in() {
        return "not-signed-in".to_owned();
    }
    if let Err(err) = prepare_install(role, info_json) {
        return err.to_owned();
    }
    // Sense Remote (K-R2-3, K3-2): create the RustDesk ID and device key pair and make sure
    // both are in the config file before `install_me`, so the service imports this pair
    // (`--import-config` skips a file without ID or key; `get_key_pair` writes the key from a
    // background thread). Registration then reads the pair back from the service.
    if let Err(err) = store_identity_for_import() {
        return err.to_owned();
    }
    // silent = true: the setup screen shows "Kuruldu" and opens the app on request.
    match crate::platform::windows::install_me(options, path, true, false) {
        Ok(()) => {
            #[cfg(feature = "flutter")]
            if let Some(role) = SenseRole::parse(role) {
                enroll::remember_installed_role(role);
            }
            String::new()
        }
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

/// Sense Remote (K3-2): ID and key pair in the setup process's config file, written before the
/// service imports it. Waits briefly for `get_key_pair`'s background write.
#[cfg(windows)]
fn store_identity_for_import() -> Result<(), &'static str> {
    let _ = config::Config::get_id();
    let _ = config::Config::get_key_pair();
    let path = config::Config::file();
    let mut ready = Err("identity-store");
    for _ in 0..30 {
        let file: config::Config = config::load_path(path.clone());
        ready = identity::stored_for_import(file.is_empty());
        if ready.is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    if ready.is_err() {
        log::error!("Sense Remote: RustDesk ID or device key not stored before installation");
        return ready;
    }
    // Reinstall: the service's config is usually newer than this file, and the import only
    // copies a newer file. Marking it as written now (content unchanged) keeps the import.
    let touched = std::fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
    if let Err(err) = touched {
        log::warn!("Sense Remote: could not mark the config for import: {err}");
    }
    ready
}

/// Sense Remote (Mac M0, plan §3.2): the macOS installation lives in `install_mac` (same
/// arguments and result strings, plus the macOS codes listed there).
#[cfg(target_os = "macos")]
pub fn install(options: &str, path: String, role: &str, info_json: &str) -> String {
    install_mac::install(options, path, role, info_json)
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn install(_options: &str, _path: String, _role: &str, _info_json: &str) -> String {
    "unsupported".to_owned()
}

/// Leaves the setup screen, optionally opening the installed app first.
pub fn finish_install(open_app: bool) {
    // Sense Remote (K-KAYIT-b): a Host keeps no sign-in, also when registration was skipped.
    #[cfg(feature = "flutter")]
    enroll::finish();
    #[cfg(windows)]
    if open_app {
        let (_, _, _, exe) = crate::platform::windows::get_install_info();
        if let Err(err) = std::process::Command::new(&exe).spawn() {
            log::error!("Failed to open {exe}: {err}");
        }
    }
    // Sense Remote (Mac M0): on macOS the wizard runs inside the installed app; `install_mac`
    // decides how it is left (the skeleton exits like before).
    #[cfg(target_os = "macos")]
    install_mac::finish_install(open_app);
    #[cfg(not(any(windows, target_os = "macos")))]
    let _ = open_app;
    #[cfg(not(target_os = "macos"))]
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
/// Sense Remote (wave 2, plan K-İZİN-b): the connection window can not be hidden, a controller
/// can not change this computer's settings remotely (permissions come only from signed panel
/// envelopes) and the upstream updater stays off.
pub fn security_overwrite_settings() -> [(&'static str, &'static str); 5] {
    [
        (keys::OPTION_API_SERVER, API_SERVER),
        (keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK, "N"),
        (OPTION_ALLOW_HIDE_CM, "N"),
        (keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION, "N"),
        (keys::OPTION_ALLOW_AUTO_UPDATE, "N"),
    ]
}

/// Read by `hbb_common::password_security` (no shared constant for it).
const OPTION_ALLOW_HIDE_CM: &str = "allow-hide-cm";

fn apply_security_to(overwrite: &mut HashMap<String, String>) {
    for (k, v) in security_overwrite_settings() {
        overwrite.insert(k.to_owned(), v.to_owned());
    }
}

/// Called at the end of `load_custom_client` in every process.
pub fn apply_security_settings() {
    apply_security_to(&mut config::OVERWRITE_SETTINGS.write().unwrap());
}

// ---------------------------------------------------------------------------------------------
// Sense Remote: no "license" from the exe name (YOL_HARITASI 2-not).
//
// Upstream reads an ID server, public key and API address from the executable's file name
// (`...-host=evil.example,key=....exe` or an encoded `--licensed--` part) and prefers it over
// every setting (`get_custom_rendezvous_server`, `get_key`, `get_rendezvous_server`, `bootstrap`,
// the installer). Whoever renames or re-hosts the file could point a computer at their own ID
// server and key. Sense builds never read it. (`--config <string>` stays: it needs an elevated,
// installed client.)
// ---------------------------------------------------------------------------------------------

/// Whether the exe name may carry server settings. Never in our build.
pub const EXE_NAME_LICENSE_ALLOWED: bool = false;

/// Sense Remote (G2-8): whether a `custom.txt` (or a custom client config passed at start) is
/// read. Never in our build: it is signed with RustDesk's key, and it could override the role
/// locks. Our settings come from the installed role and `apply_security_settings`.
pub const CUSTOM_CLIENT_FILE_ALLOWED: bool = false;

/// Gate in front of upstream's exe-name parser (`platform::windows::get_license_from_exe_name`).
#[allow(dead_code)] // only called on Windows
pub fn license_from_exe_name(
    exe: &str,
) -> hbb_common::ResultType<crate::custom_server::CustomServer> {
    if !EXE_NAME_LICENSE_ALLOWED {
        hbb_common::bail!("Sense Remote: server settings from the exe name are disabled");
    }
    crate::custom_server::get_custom_server_from_string(exe)
}

// Sense Remote: the `sense` extension of heartbeat / sysinfo (health, display info, network
// addresses), wave 2 I3.
pub mod report;
// Sense Remote: signed heartbeat report (wave 3 I7, K-R2-3 / G2-1).
pub mod report_sig;
#[cfg(windows)]
mod displays_win;
mod network;
// Sense Remote (plan 2026-11-21 §3): the macOS modules: state file (M1), installation (M2),
// displays + permissions (M4), envelope apply through the root daemon (M5).
// `displays_mac` and `mac_perm` are still being filled in by M4; parts of them are unused.
#[cfg(target_os = "macos")]
#[allow(dead_code)]
mod displays_mac;
#[cfg(target_os = "macos")]
pub mod install_mac;
// The IPC types are shared with `ipc::Data` (every platform); the daemon and the user-process
// side only run on macOS, so elsewhere most of the module is used by its tests alone.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod mac_apply;
#[cfg(target_os = "macos")]
#[allow(dead_code)]
pub mod mac_perm;
#[cfg(target_os = "macos")]
pub mod mac_state;
// Sense Remote: maintenance curtain of ghost mode; privacy mode turns it on (wave 3 I10).
pub mod curtain;

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
    fn hide_cm_remote_config_and_auto_update_are_pinned_off() {
        let mut overwrite = HashMap::from([
            (OPTION_ALLOW_HIDE_CM.to_owned(), "Y".to_owned()),
            (keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION.to_owned(), "Y".to_owned()),
            (keys::OPTION_ALLOW_AUTO_UPDATE.to_owned(), "Y".to_owned()),
        ]);
        apply_security_to(&mut overwrite);
        for key in [
            "allow-hide-cm",
            "allow-remote-config-modification",
            "allow-auto-update",
        ] {
            assert_eq!(overwrite[key], "N", "{key}");
            assert!(!config::option2bool(key, &overwrite[key]), "{key}");
            // The panel can not send them either.
            assert!(envelope::ALLOWED_OPTIONS.iter().all(|(k, _)| *k != key), "{key}");
        }
    }

    #[test]
    fn custom_client_file_is_never_read() {
        assert!(!CUSTOM_CLIENT_FILE_ALLOWED);
        // Whatever is passed, nothing changes (the signature is not even checked).
        let before = config::HARD_SETTINGS.read().unwrap().clone();
        crate::common::read_custom_client("not-base64 but ignored anyway");
        assert_eq!(*config::HARD_SETTINGS.read().unwrap(), before);
    }

    #[test]
    fn exe_name_never_sets_servers_or_key() {
        assert!(!EXE_NAME_LICENSE_ALLOWED);
        for name in [
            "SenseRemote-host=evil.example.net,key=Zm9vYmFyLiwyCg==,api=https://evil.example.net.exe",
            "rustdesk-host=evil.example.net,.exe",
            "C:\\Users\\x\\Downloads\\SenseRemote-host=10.0.0.1,key=abc.exe",
        ] {
            // Upstream accepts these names...
            assert!(
                crate::custom_server::get_custom_server_from_string(name)
                    .is_ok_and(|lic| !lic.host.is_empty()),
                "{name}"
            );
            // ...the Sense gate does not.
            assert!(license_from_exe_name(name).is_err(), "{name}");
        }
    }

    // Sense Remote: role and setup info come from the state file fields. The file is a
    // temporary one (K4-6): the real `/Library/Application Support/SenseRemote` is never read,
    // so the result is the same on a Mac with Sense Remote installed.
    #[cfg(target_os = "macos")]
    #[test]
    fn mac_state_maps_to_the_registry_value_names() {
        let state = mac_state::MacState {
            role: Some(SenseRole::Both),
            setup_hex: "7b7d".to_owned(),
            envelope_seq: 9,
        };
        assert_eq!(
            mac_state_value(&state, REG_VALUE_ROLE).as_deref(),
            Some("both")
        );
        assert_eq!(
            mac_state_value(&state, REG_VALUE_SETUP).as_deref(),
            Some("7b7d")
        );
        assert_eq!(mac_state_value(&state, "EnvelopeSeq"), None);
        let empty = mac_state::MacState::default();
        assert_eq!(mac_state_value(&empty, REG_VALUE_ROLE), None);
        assert_eq!(mac_state_value(&empty, REG_VALUE_SETUP), None);

        let base = std::env::temp_dir().join(format!("sense-role-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let dir = base.join("SenseRemote");
        let value = |name: &str| mac_value_from(mac_state::read_in(&dir, false), name);
        let role = || value(REG_VALUE_ROLE).and_then(|role| SenseRole::parse(&role));
        // Not installed: no directory, no role.
        assert_eq!(role(), None);
        // Installed: every process reads what was stored.
        mac_state::update_in(&dir, false, |state| {
            state.role = Some(SenseRole::Host);
            state.setup_hex = "7b7d".to_owned();
        })
        .unwrap();
        assert_eq!(role(), Some(SenseRole::Host));
        assert_eq!(value(REG_VALUE_SETUP).as_deref(), Some("7b7d"));
        // A broken file is no role (and a throttled log line), not a default one.
        std::fs::write(dir.join(mac_state::STATE_FILE), "not json").unwrap();
        assert!(mac_state::read_in(&dir, false).is_err());
        assert_eq!(role(), None);
        assert_eq!(value(REG_VALUE_SETUP), None);
        let _ = std::fs::remove_dir_all(&base);
        // The user process never stores a role.
        assert_eq!(store_role(SenseRole::Host), Err("daemon-only".to_owned()));
    }

    #[cfg(windows)]
    #[test]
    fn running_exe_has_no_license() {
        assert!(crate::platform::windows::get_license_from_exe_name().is_err());
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
            location: " Galeri 1 \"LED\" & 100% ^ | <>".to_owned(),
        }
    }

    #[test]
    fn info_is_trimmed() {
        let info = info().normalized().unwrap();
        assert_eq!(info.name, "Galeri kioskı");
        assert_eq!(info.location, "Galeri 1 \"LED\" & 100% ^ | <>");
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
        bad.location = "l".repeat(MAX_LOCATION_CHARS + 1);
        assert_eq!(bad.normalized(), Err("invalid-location"));
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
            location: "ü".repeat(MAX_LOCATION_CHARS),
        }
        .normalized()
        .unwrap();
        let commands = install_commands(SenseRole::Both, &info.encode().unwrap());
        assert!(commands.lines().all(|line| line.len() < 8000));
    }

    // Wave 3 K-YEREL: project names (they may name a customer) and the note never reach HKLM.
    #[test]
    fn setup_info_keeps_only_name_and_location() {
        let from_screen = r#"{"name":"Kiosk","location":"Galeri 1","projects":["Örnek Müze"],
            "project_ids":["prj_1"],"new_projects":["Yeni Müze"],"note":"LED"}"#;
        let info: SetupInfo = serde_json::from_str(from_screen).unwrap();
        let encoded = info.normalized().unwrap().encode().unwrap();
        let stored = String::from_utf8(hex::decode(&encoded).unwrap()).unwrap();
        let stored: serde_json::Value = serde_json::from_str(&stored).unwrap();
        assert_eq!(
            stored,
            serde_json::json!({"name": "Kiosk", "location": "Galeri 1"})
        );
        let commands = install_commands(SenseRole::Host, &encoded);
        assert!(!commands.to_lowercase().contains("project"));
        assert!(!commands.contains(&hex::encode("Örnek Müze")));
        assert!(!commands.contains(&hex::encode("Yeni Müze")));
        assert!(!commands.contains(&hex::encode("LED")));
    }

    #[test]
    fn older_setup_value_with_projects_still_decodes() {
        let old = hex::encode(
            r#"{"name":"Kiosk","projects":["Örnek Müze"],"location":"G1","note":"n"}"#,
        );
        assert_eq!(
            SetupInfo::decode(&old),
            Some(SetupInfo {
                name: "Kiosk".to_owned(),
                location: "G1".to_owned()
            })
        );
    }

    #[test]
    fn setup_info_becomes_builtin_name_and_location() {
        let info = SetupInfo {
            name: "Kiosk".to_owned(),
            location: "Galeri 1".to_owned(),
        };
        assert_eq!(
            setup_builtin_settings(&info),
            [
                ("sense-name", "Kiosk".to_owned()),
                ("sense-location", "Galeri 1".to_owned())
            ]
        );
        // Not installed: both empty, so the home screen shows nothing instead of stale values.
        assert_eq!(
            setup_builtin_settings(&SetupInfo::default()),
            [("sense-name", String::new()), ("sense-location", String::new())]
        );
    }

    #[test]
    fn sense_version_becomes_builtin_option() {
        assert_eq!(version_builtin_setting(Some(3)), ("sense-version", "3".to_owned()));
        assert_eq!(version_builtin_setting(None), ("sense-version", String::new()));
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

    // Sense Remote (T3): Windows file details (Properties > Details) of the setup file and the
    // installed program name Sense Department; the AGPL notice and the source link stay.
    #[test]
    fn windows_file_details_name_sense_and_keep_the_agpl_notice() {
        let sources = [
            ("Cargo.toml", include_str!("../Cargo.toml")),
            ("libs/portable/Cargo.toml", include_str!("../libs/portable/Cargo.toml")),
            ("Runner.rc", include_str!("../flutter/windows/runner/Runner.rc")),
        ];
        for (name, text) in sources {
            let copyright = text
                .lines()
                .find(|line| line.contains("LegalCopyright"))
                .unwrap_or_else(|| panic!("{name}: no LegalCopyright"));
            assert!(copyright.contains("Sense Department"), "{name}");
            assert!(copyright.contains("AGPL-3.0"), "{name}");
            assert!(
                copyright.contains("https://github.com/halil-yagli/sense-remote-client"),
                "{name}"
            );
            assert!(!copyright.contains("Purslane"), "{name}");
            let original = text
                .lines()
                .find(|line| line.contains("OriginalFilename"))
                .unwrap_or_else(|| panic!("{name}: no OriginalFilename"));
            assert!(!original.to_lowercase().contains("rustdesk"), "{name}");
        }
    }
}
