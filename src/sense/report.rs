//! Sense Remote: the `sense` extension of the heartbeat and sysinfo bodies sent to the panel
//! (wave 2, task I3): role, Sense version, platform, health and per-display info.
//!
//! Contract: `sense-remote-panel/packages/shared/src/client-api/sense-ext.ts` (Zod schemas
//! `SenseSysinfoExt`, `SenseHeartbeatExt`, `SenseHealth`, `SenseDisk`, `SenseDisplay`). The
//! structs below carry exactly those field names (checked by the tests against a sample taken
//! from the panel's own tests). Anything that cannot be read is left out, never guessed, so
//! the body always passes the schema.
//!
//! Interface for the sync loop (`src/hbbs_http/sync.rs`, task I4):
//! - `sysinfo_ext()`: value for `sysinfo["sense"]`, with the display list.
//! - `heartbeat_base()`: value for `heartbeat["sense"]` (v, role, app_version, displays_hash,
//!   health at most once per `HEALTH_INTERVAL`, `caps`, `maintenance_curtain` where the curtain
//!   is supported). I4 adds `applied_seq`, `envelope_error`,
//!   `clock_skew_s` to this object.
//! - `health()`, `displays()` and `network()` for direct use.
//!
//! `network` (adapter IP addresses, `network.rs`) goes into sysinfo only (contract: "değişince
//! sysinfo yeniden gelir"). The sync loop asks `network_changed_since_sysinfo()` (checks at most
//! once per `HEALTH_INTERVAL`) and uploads sysinfo again when it returns true, so a changed DHCP
//! address shows within about a minute.
//! Both builders return `None` when there is no installed role (portable / not installed),
//! no `SENSE_VERSION` at build time, or an unsupported platform: then no `sense` is sent.
//!
//! Blocking: the first `health()` sleeps `MINIMUM_CPU_UPDATE_INTERVAL` (200 ms) to get a CPU
//! value, and the temperature query (WMI on Windows) can take a moment; a display read creates
//! DXGI objects. Call from a blocking context (e.g. `spawn_blocking`) if the caller is async.
//!
//! Sense Remote (Mac M4): macOS sends its displays (`displays_mac`: size, backing scale, refresh
//! rate, monitor name; no connection type), the adapters with their kind from SystemConfiguration
//! (`network.rs`) and, in the heartbeat only, `mac_permissions` (`mac_perm`; not part of the
//! signed report). Health comes from `sysinfo` (the temperature may be unavailable on Apple
//! Silicon; then it is not sent). `caps` carries `apply` where this build applies envelopes.

// Sense Remote: `health()`, `displays()` and `network()` are only used by tests so far.
#![allow(dead_code)]

use super::{network::SenseNetwork, SenseRole};
use hbb_common::{
    log,
    sysinfo::{Components, Disks, System, MINIMUM_CPU_UPDATE_INTERVAL},
};
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// `v` of the extension (`SENSE_EXT_VERSION` in the contract).
pub const EXT_VERSION: u32 = 1;
/// Sense Remote (wave 3, K-ROL-2): capabilities of every build in every heartbeat (`sense.caps`).
/// `role_all`: this build takes all three roles from the panel.
pub const CAPS: [&str; 1] = ["role_all"];
/// Sense Remote (wave 3, I10): added to `caps` only where the maintenance curtain can be shown
/// (`curtain::is_supported`: Windows 10 2004+; not on macOS or older Windows).
pub const CAP_CURTAIN: &str = "curtain";
/// Sense Remote (Mac M4, plan §3.4): added to `caps` only where this build applies a signed
/// envelope (`envelope_apply::APPLIES`). The panel looks at it on macOS: a Mac without it gets
/// no policy.
pub const CAP_APPLY: &str = "apply";
/// Health goes into the heartbeat at most this often (contract: "en çok 60 sn'de bir").
pub const HEALTH_INTERVAL: Duration = Duration::from_secs(60);
/// The heartbeat's `displays_hash` is recomputed at most this often (the heartbeat runs every
/// 3-15 s; a changed hash makes the panel ask for sysinfo again).
const DISPLAYS_HASH_TTL: Duration = Duration::from_secs(30);

const MAX_DISPLAYS: usize = 32;
const MAX_DISKS: usize = 16;
const MAX_DISPLAY_NAME_CHARS: usize = 128;
const MAX_MOUNT_CHARS: usize = 64;

// ---------------------------------------------------------------------------------------------
// Contract shapes
// ---------------------------------------------------------------------------------------------

/// `SenseDisplay`. x/y/width/height mean the same as `DisplayInfo` (message.proto) and come
/// from the same list the controller sees, so `index` matches the controller's display index.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SenseDisplay {
    pub index: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    /// Not sent on Windows (`DisplayInfo.scale` is always 1 there).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_hz: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_format: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hdr: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_height: Option<u32>,
}

/// `SenseDisk`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SenseDisk {
    pub mount: String,
    pub used_pct: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_gb: Option<f64>,
}

/// `SenseHealth`. `gpu_pct` / `gpu_temp_c` are filled by the GPU task (I5).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SenseHealth {
    pub at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_temp_c: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu_temp_c: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mem_used_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mem_total_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disks: Option<Vec<SenseDisk>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uptime_s: Option<u64>,
}

/// Sense Remote (Mac M4): `SenseMacPermissions`, the heartbeat's `mac_permissions` (`mac_perm`
/// reads the values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MacPermissions {
    pub screen_recording: bool,
    pub accessibility: bool,
    pub input_monitoring: bool,
}

/// `SenseSysinfoExt`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SysinfoExt {
    pub v: u32,
    pub role: String,
    pub app_version: u32,
    pub platform: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub displays: Option<Vec<SenseDisplay>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub displays_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network: Option<Vec<SenseNetwork>>,
}

/// The part of `SenseHeartbeatExt` this module fills (I4 adds the envelope fields).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HeartbeatBase {
    pub v: u32,
    pub role: String,
    pub app_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub displays_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub health: Option<SenseHealth>,
    /// Sense Remote (K-ROL-2): `CAPS`; covered by the signed report (`report_sig.rs`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caps: Option<Vec<String>>,
    /// Sense Remote (I10): curtain on now; only where `caps` has `curtain` (left out elsewhere,
    /// e.g. on macOS). Signed like `caps`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub maintenance_curtain: Option<bool>,
    /// Sense Remote (Mac M4): only macOS sends it; information only, NOT in the signed report
    /// (`report_sig::SIGNED_FIELDS`), so no policy decision may rest on it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac_permissions: Option<MacPermissions>,
}

// ---------------------------------------------------------------------------------------------
// Public interface (I4)
// ---------------------------------------------------------------------------------------------

/// `sysinfo["sense"]`. Reads the displays now and refreshes the heartbeat's hash cache, so the
/// hash sent here and in the next heartbeats is the same value.
pub fn sysinfo_ext() -> Option<Value> {
    let (role, app_version, platform) = identity()?;
    let displays = collect_displays();
    let hash = displays_hash(&displays);
    store_displays_hash(hash.clone());
    let ext = SysinfoExt {
        v: EXT_VERSION,
        role: role_name(role).to_owned(),
        app_version,
        platform: platform.to_owned(),
        displays: (!displays.is_empty()).then_some(displays),
        displays_hash: hash,
        network: {
            let network = network_list();
            *SENT_NETWORK_HASH.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(network_hash(network.as_deref()));
            network
        },
    };
    to_json(&ext)
}

/// `heartbeat["sense"]` without the envelope fields. Contains `health` when the last one was
/// put in at least `HEALTH_INTERVAL` ago.
pub fn heartbeat_base() -> Option<Value> {
    let (role, app_version, _) = identity()?;
    let health = take_health_slot(Instant::now()).then(measure_health);
    let curtain_supported = crate::sense::curtain::is_supported();
    let base = HeartbeatBase {
        v: EXT_VERSION,
        role: role_name(role).to_owned(),
        app_version,
        displays_hash: cached_displays_hash(),
        health,
        // Sense Remote (update plan 2026-11-21, §3.5): `update` only where this build installs
        // signed updates.
        // Sense Remote (permanent password plan §3.5): `password` only where the permanent
        // password is set in the app (`password::SUPPORTED`).
        caps: Some(caps_with_password(
            caps_with_update(
                caps(curtain_supported, super::envelope_apply::APPLIES),
                super::update::SUPPORTED,
            ),
            super::password::SUPPORTED,
        )),
        maintenance_curtain: curtain_state(curtain_supported, crate::sense::curtain::is_shown()),
        mac_permissions: mac_permissions(),
    };
    to_json(&base)
}

/// Sense Remote: `caps` of this computer: `CAPS`, plus `curtain` where it can be shown and
/// (Mac M4) `apply` where envelopes are applied.
fn caps(curtain_supported: bool, applies: bool) -> Vec<String> {
    let mut caps: Vec<String> = CAPS.iter().map(|cap| (*cap).to_owned()).collect();
    if curtain_supported {
        caps.push(CAP_CURTAIN.to_owned());
    }
    if applies {
        caps.push(CAP_APPLY.to_owned());
    }
    caps
}

/// Sense Remote (update plan 2026-11-21, §3.5): `update` is the last capability, added only when
/// this build installs signed updates (`update::SUPPORTED`). The panel sends releases and orders
/// only to a computer that reports it in the signed report.
fn caps_with_update(mut caps: Vec<String>, update_supported: bool) -> Vec<String> {
    if update_supported {
        caps.push(super::update::CAP_UPDATE.to_owned());
    }
    caps
}

/// Sense Remote (permanent password plan §3.5): `password` comes after `update`, only when this
/// build sets the permanent password in the app (`password::SUPPORTED`).
fn caps_with_password(mut caps: Vec<String>, password_supported: bool) -> Vec<String> {
    if password_supported {
        caps.push(super::password::CAP_PASSWORD.to_owned());
    }
    caps
}

/// Sense Remote (Mac M4): the three macOS privacy permissions of this process, read without a
/// prompt.
#[cfg(target_os = "macos")]
fn mac_permissions() -> Option<MacPermissions> {
    Some(super::mac_perm::current())
}

/// Sense Remote (Mac M4): the field does not exist outside macOS.
#[cfg(not(target_os = "macos"))]
fn mac_permissions() -> Option<MacPermissions> {
    None
}

/// Sense Remote: `maintenance_curtain`, sent only next to the `curtain` capability.
fn curtain_state(curtain_supported: bool, shown: bool) -> Option<bool> {
    curtain_supported.then_some(shown)
}

/// `SenseHealth` measured now.
pub fn health() -> Value {
    let health = measure_health();
    to_json(&health).unwrap_or_else(|| serde_json::json!({ "at": health.at }))
}

/// (`SenseDisplay` list, `displays_hash`). Both empty / `None` when nothing could be read
/// (Session 0, lock screen, no window server session): then the fields are not sent and the panel keeps
/// the last known displays.
pub fn displays() -> (Vec<Value>, Option<String>) {
    let displays = collect_displays();
    let hash = displays_hash(&displays);
    let values = displays.iter().filter_map(to_json).collect();
    (values, hash)
}

/// `sense.network`: Ethernet / Wi-Fi adapters with their IP addresses (no MAC).
pub fn network() -> Vec<Value> {
    super::network::collect()
        .unwrap_or_default()
        .iter()
        .filter_map(to_json)
        .collect()
}

/// Sense Remote (K2-5): `Some(vec![])` (no adapter left) is sent as `network: []`, so the panel
/// stops showing the old addresses; only `None` (adapters could not be read) leaves it out.
fn network_list() -> Option<Vec<SenseNetwork>> {
    super::network::collect()
}

// Hash of the network list in the last sysinfo (`None` = no sysinfo built yet) and the time of
// the last comparison.
static SENT_NETWORK_HASH: Mutex<Option<String>> = Mutex::new(None);
static LAST_NETWORK_CHECK: Mutex<Option<Instant>> = Mutex::new(None);

/// True when the adapters / addresses differ from those in the last `sysinfo_ext()`: the sync
/// loop then uploads sysinfo again. Reads the adapters at most once per `HEALTH_INTERVAL`
/// (otherwise false); false before the first sysinfo (that upload carries the list anyway).
/// Sense Remote (K2-7): cheap, non-blocking test the sync loop makes before it starts a blocking
/// task for `network_changed_since_sysinfo` (instead of one every 3 s).
pub fn network_check_due() -> bool {
    health_due(
        *LAST_NETWORK_CHECK.lock().unwrap_or_else(|e| e.into_inner()),
        Instant::now(),
    )
}

pub fn network_changed_since_sysinfo() -> bool {
    let now = Instant::now();
    {
        let mut last = LAST_NETWORK_CHECK.lock().unwrap_or_else(|e| e.into_inner());
        if !health_due(*last, now) {
            return false;
        }
        *last = Some(now);
    }
    let Some(sent) = SENT_NETWORK_HASH.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
        return false;
    };
    // A failed read is not a change (the next sysinfo would leave `network` out anyway).
    let Some(now) = network_list() else {
        return false;
    };
    network_hash(Some(&now[..])) != sent
}

/// Sense Remote (K2-5): `None` (not sent) and `Some([])` (sent empty) hash differently.
fn network_hash(list: Option<&[SenseNetwork]>) -> String {
    let value = serde_json::to_value(list).unwrap_or(Value::Null);
    let digest = Sha256::digest(canonical_json(&value).as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

// ---------------------------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------------------------

fn identity() -> Option<(SenseRole, u32, &'static str)> {
    let role = super::installed_role()?;
    Some((role, app_version()?, platform()?))
}

/// Contract `SenseRole` value.
pub fn role_name(role: SenseRole) -> &'static str {
    match role {
        SenseRole::Host => "host",
        SenseRole::Controller => "controller",
        SenseRole::Both => "host_controller",
    }
}

/// Contract `Platform` value; `None` for builds the panel does not know (Intel Mac, Linux).
pub fn platform() -> Option<&'static str> {
    if cfg!(all(windows, target_arch = "x86_64")) {
        Some("windows-x64")
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Some("macos-arm64")
    } else {
        None
    }
}

/// Sense version number (1, 2, 3 ...) from `SENSE_VERSION` at build time.
pub fn app_version() -> Option<u32> {
    parse_app_version(option_env!("SENSE_VERSION"))
}

fn parse_app_version(value: Option<&str>) -> Option<u32> {
    value?.trim().parse::<u32>().ok().filter(|n| *n > 0)
}

fn to_json<T: serde::Serialize>(value: &T) -> Option<Value> {
    match serde_json::to_value(value) {
        Ok(v) => Some(v),
        Err(err) => {
            log::error!("Sense Remote: report serialization failed: {err}");
            None
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------------------------

// Kept between calls: CPU usage is the average since the previous refresh.
static CPU_SYSTEM: Mutex<Option<System>> = Mutex::new(None);
static LAST_HEALTH: Mutex<Option<Instant>> = Mutex::new(None);

fn take_health_slot(now: Instant) -> bool {
    let mut last = LAST_HEALTH.lock().unwrap_or_else(|e| e.into_inner());
    if health_due(*last, now) {
        *last = Some(now);
        true
    } else {
        false
    }
}

fn health_due(last: Option<Instant>, now: Instant) -> bool {
    match last {
        None => true,
        Some(t) => now.saturating_duration_since(t) >= HEALTH_INTERVAL,
    }
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn measure_health() -> SenseHealth {
    let mut health = SenseHealth {
        at: unix_now(),
        ..Default::default()
    };
    {
        let mut guard = CPU_SYSTEM.lock().unwrap_or_else(|e| e.into_inner());
        let first = guard.is_none();
        let system = guard.get_or_insert_with(System::new);
        system.refresh_cpu_usage();
        if first {
            // The first refresh only sets the baseline.
            std::thread::sleep(MINIMUM_CPU_UPDATE_INTERVAL);
            system.refresh_cpu_usage();
        }
        system.refresh_memory();
        if !system.cpus().is_empty() {
            health.cpu_pct = cpu_pct(system.global_cpu_info().cpu_usage());
        }
        let (used, total) = (system.used_memory(), system.total_memory());
        if total > 0 {
            health.mem_total_mb = Some(bytes_to_mb(total));
            health.mem_used_mb = Some(bytes_to_mb(used.min(total)));
        }
        health.uptime_s = Some(system.uptime());
    }
    let disks = measure_disks();
    health.disks = (!disks.is_empty()).then_some(disks);
    health.cpu_temp_c = measure_cpu_temp();
    health
}

fn bytes_to_mb(bytes: u64) -> u64 {
    bytes / (1024 * 1024)
}

fn round_to(value: f64, decimals: i32) -> f64 {
    let f = 10f64.powi(decimals);
    (value * f).round() / f
}

fn cpu_pct(usage: f32) -> Option<f64> {
    let usage = usage as f64;
    usage
        .is_finite()
        .then(|| round_to(usage.clamp(0.0, 100.0), 1))
}

fn measure_disks() -> Vec<SenseDisk> {
    let disks = Disks::new_with_refreshed_list();
    let mut out: Vec<SenseDisk> = Vec::new();
    for disk in disks.list() {
        if disk.is_removable() {
            continue;
        }
        let Some(mount) = mount_name(&disk.mount_point().to_string_lossy()) else {
            continue;
        };
        if out.iter().any(|d| d.mount == mount) {
            continue;
        }
        if let Some(entry) = disk_entry(mount, disk.total_space(), disk.available_space()) {
            out.push(entry);
        }
        if out.len() >= MAX_DISKS {
            break;
        }
    }
    out
}

/// Windows `C:\` -> `C:`. macOS: only the system volume `/` (the others are APFS helper
/// volumes of the same disk).
fn mount_name(raw: &str) -> Option<String> {
    let mount = if cfg!(windows) {
        raw.trim_end_matches('\\')
    } else {
        raw
    };
    if cfg!(target_os = "macos") && mount != "/" {
        return None;
    }
    if mount.is_empty() || mount.chars().count() > MAX_MOUNT_CHARS {
        return None;
    }
    Some(mount.to_owned())
}

fn disk_entry(mount: String, total: u64, available: u64) -> Option<SenseDisk> {
    if total == 0 {
        return None;
    }
    let used = total.saturating_sub(available.min(total));
    let used_pct = round_to(used as f64 * 100.0 / total as f64, 1).clamp(0.0, 100.0);
    let total_gb = round_to(total as f64 / (1024.0 * 1024.0 * 1024.0), 1);
    Some(SenseDisk {
        mount,
        used_pct,
        total_gb: Some(total_gb),
    })
}

fn measure_cpu_temp() -> Option<f64> {
    let components = Components::new_with_refreshed_list();
    pick_cpu_temp(
        components
            .list()
            .iter()
            .map(|c| (c.label(), c.temperature())),
    )
}

/// Highest valid reading among CPU-like sensors. On Windows `sysinfo` reports the ACPI thermal
/// zone as "Computer" (WMI, needs SYSTEM / admin); that is the closest to a CPU value there.
/// No matching sensor -> `None` (field not sent).
fn pick_cpu_temp<'a>(readings: impl Iterator<Item = (&'a str, f32)>) -> Option<f64> {
    const CPU_LABELS: [&str; 5] = ["cpu", "package", "tctl", "tdie", "core"];
    readings
        .filter(|(label, _)| {
            let label = label.to_ascii_lowercase();
            CPU_LABELS.iter().any(|k| label.contains(k)) || label == "computer"
        })
        .map(|(_, t)| t as f64)
        .filter(|t| t.is_finite() && (-20.0..=150.0).contains(t))
        .fold(None, |max: Option<f64>, t| Some(max.map_or(t, |m| m.max(t))))
        .map(|t| round_to(t, 1))
}

// ---------------------------------------------------------------------------------------------
// Displays
// ---------------------------------------------------------------------------------------------

/// Raw per-display values from the OS (Windows: `displays_win`, macOS: `displays_mac`), mapped
/// by the pure functions below.
#[derive(Debug, Clone, Default)]
pub(super) struct DisplayDetails {
    pub name: Option<String>,
    /// Sense Remote (Mac M4): backing scale factor (2 on a Retina display); macOS only.
    pub scale: Option<f64>,
    /// Sense Remote (Mac M4): size in pixels at the backing scale; macOS only (see
    /// `mac_geometry`).
    pub pixel_size: Option<(u32, u32)>,
    /// DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY
    pub output_technology: Option<u32>,
    /// Target refresh rate (numerator, denominator).
    pub refresh: Option<(u32, u32)>,
    /// DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO (flag bits, color encoding, bits per channel).
    pub advanced_color: Option<(u32, u32, u32)>,
    /// Preferred (native) mode width, height.
    pub native: Option<(u32, u32)>,
}

/// One entry of the display list the controller sees (`scrap::Display::all()`).
#[derive(Debug, Clone)]
pub(super) struct Geometry {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: usize,
    pub height: usize,
    pub primary: bool,
}

#[cfg(windows)]
fn collect_displays() -> Vec<SenseDisplay> {
    // Same source as `display_service::try_get_displays` without its side effect (it may plug
    // in a virtual display when none is found), so the index matches the controller's list.
    let list = match scrap::Display::all() {
        Ok(list) => list,
        Err(err) => {
            log::debug!("Sense Remote: display list unavailable: {err}");
            return Vec::new();
        }
    };
    let geometry: Vec<Geometry> = list
        .iter()
        .map(|d| Geometry {
            name: d.name(),
            x: d.origin().0,
            y: d.origin().1,
            width: d.width(),
            height: d.height(),
            primary: d.is_primary(),
        })
        .collect();
    merge_displays(&geometry, &super::displays_win::query())
}

/// Sense Remote (Mac M4): order, index, position and "primary" come from the list the
/// controller sees (`scrap::Display::all()`); size, scale, refresh rate and name from
/// `displays_mac`, merged by display id.
#[cfg(target_os = "macos")]
fn collect_displays() -> Vec<SenseDisplay> {
    let list = match scrap::Display::all() {
        Ok(list) => list,
        Err(err) => {
            log::debug!("Sense Remote: display list unavailable: {err}");
            return Vec::new();
        }
    };
    let details = super::displays_mac::query();
    let geometry: Vec<Geometry> = list
        .iter()
        .map(|d| {
            let name = d.name();
            let found = details.get(&name);
            mac_geometry(name, d.origin(), (d.width(), d.height()), d.is_primary(), found)
        })
        .collect();
    merge_displays(&geometry, &details)
}

#[cfg(not(any(windows, target_os = "macos")))]
fn collect_displays() -> Vec<SenseDisplay> {
    Vec::new()
}

/// Sense Remote (Mac M4): one entry of the controller's list on macOS. `DisplayInfo` there is
/// the size in pixels at the backing scale plus `scale` (x / y in points), but only while
/// scrap's Retina switch is on, and the server turns that off while more than one display is
/// captured (`server.rs`, `ENABLE_RETINA`). The report must not change with a running
/// connection, so the pixel size comes from `displays_mac` (the value `DisplayInfo` has with
/// the switch on); scrap's own size is only the fallback when the mode could not be read.
fn mac_geometry(
    name: String,
    origin: (i32, i32),
    scrap_size: (usize, usize),
    primary: bool,
    details: Option<&DisplayDetails>,
) -> Geometry {
    let (width, height) = details
        .and_then(|d| d.pixel_size)
        .map(|(w, h)| (w as usize, h as usize))
        .unwrap_or(scrap_size);
    Geometry {
        name,
        x: origin.0,
        y: origin.1,
        width,
        height,
        primary,
    }
}

/// Sense Remote (Mac M4): backing scale of a display mode (`CGDisplayModeGetPixelWidth` /
/// `CGDisplayModeGetWidth`): 1 on a normal display, 2 on a Retina one. Anything else than a
/// plausible value is not sent.
pub(super) fn mac_scale(mode_pixel_width: usize, mode_width: usize) -> Option<f64> {
    if mode_pixel_width == 0 || mode_width == 0 {
        return None;
    }
    let scale = round_to(mode_pixel_width as f64 / mode_width as f64, 2);
    (1.0..=4.0).contains(&scale).then_some(scale)
}

/// Sense Remote (Mac M4): size in points (`CGDisplayPixelsWide` / `High`, rotation applied)
/// times the backing scale. `None` without a scale (the caller then keeps scrap's size).
pub(super) fn mac_pixel_size(points: (usize, usize), scale: Option<f64>) -> Option<(u32, u32)> {
    let scale = scale?;
    let to_pixels = |points: usize| {
        let pixels = (points as f64 * scale).round();
        (pixels >= 1.0 && pixels <= u32::MAX as f64).then_some(pixels as u32)
    };
    Some((to_pixels(points.0)?, to_pixels(points.1)?))
}

/// Sense Remote (Mac M4): refresh rate as the rational `DisplayDetails::refresh` carries.
/// `CGDisplayModeGetRefreshRate` is 0 for some built-in panels; then the screen's
/// `maximumFramesPerSecond` stands in. Neither readable -> not sent.
pub(super) fn mac_refresh(mode_hz: f64, max_fps: Option<i64>) -> Option<(u32, u32)> {
    let hz = if mode_hz.is_finite() && mode_hz >= 1.0 {
        mode_hz
    } else {
        max_fps.filter(|fps| *fps >= 1)? as f64
    };
    (hz <= 1000.0).then(|| ((hz * 1000.0).round() as u32, 1000))
}

fn merge_displays(
    geometry: &[Geometry],
    details: &HashMap<String, DisplayDetails>,
) -> Vec<SenseDisplay> {
    geometry
        .iter()
        .enumerate()
        .take(MAX_DISPLAYS)
        .filter(|(_, g)| g.width > 0 && g.height > 0)
        .filter_map(|(index, g)| {
            let mut display = SenseDisplay {
                index: index as u32,
                x: g.x,
                y: g.y,
                width: u32::try_from(g.width).ok()?,
                height: u32::try_from(g.height).ok()?,
                primary: Some(g.primary),
                ..Default::default()
            };
            if let Some(d) = details.get(&g.name) {
                apply_details(&mut display, d);
            }
            Some(display)
        })
        .collect()
}

fn apply_details(display: &mut SenseDisplay, d: &DisplayDetails) {
    display.name = d.name.as_deref().and_then(display_name);
    // Sense Remote (Mac M4): only macOS reads a scale (`DisplayInfo.scale` is 1 on Windows).
    display.scale = d.scale.filter(|s| s.is_finite() && *s > 0.0);
    display.connection = d.output_technology.map(|t| connection_name(t).to_owned());
    display.refresh_hz = d.refresh.and_then(|(num, den)| refresh_hz(num, den));
    if let Some((flags, encoding, bits)) = d.advanced_color {
        display.hdr = Some(is_hdr(flags));
        display.color_format = color_format(encoding).map(str::to_owned);
        display.bit_depth = (6..=16).contains(&bits).then_some(bits);
    }
    if let Some((w, h)) = d.native {
        if w > 0 && h > 0 {
            display.native_width = Some(w);
            display.native_height = Some(h);
        }
    }
}

fn display_name(raw: &str) -> Option<String> {
    let name = raw.trim();
    (!name.is_empty()).then(|| name.chars().take(MAX_DISPLAY_NAME_CHARS).collect())
}

/// DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY -> contract `connection`. USB-C carries DisplayPort
/// and Windows reports it as DisplayPort (or a USB tunnel), so `usb_c` is never sent.
fn connection_name(technology: u32) -> &'static str {
    match technology {
        0 => "vga",                              // HD15
        4 => "dvi",                              // DVI
        5 => "hdmi",                             // HDMI
        10 | 18 => "displayport",                // DISPLAYPORT_EXTERNAL, DISPLAYPORT_USB_TUNNEL
        6 | 11 | 13 | 0x8000_0000 => "internal", // LVDS, DISPLAYPORT_EMBEDDED, UDI_EMBEDDED, INTERNAL
        _ => "other", // S-video, composite, component, D-JPN, SDI, UDI external, TV dongle,
                      // Miracast, indirect (wired / virtual), OTHER
    }
}

/// DISPLAYCONFIG_COLOR_ENCODING -> contract `color_format`; intensity / unknown -> not sent.
fn color_format(encoding: u32) -> Option<&'static str> {
    match encoding {
        0 => Some("rgb"),
        1 => Some("ycbcr444"),
        2 => Some("ycbcr422"),
        3 => Some("ycbcr420"),
        _ => None,
    }
}

/// HDR is on when advanced color is enabled and not only for wide color gamut on SDR
/// (`advancedColorEnabled` = bit 1, `wideColorEnforced` = bit 2).
fn is_hdr(flags: u32) -> bool {
    let enabled = flags & 0b010 != 0;
    let wide_color_enforced = flags & 0b100 != 0;
    enabled && !wide_color_enforced
}

/// Rational refresh rate -> Hz with two decimals (59.94); out of contract range -> `None`.
fn refresh_hz(numerator: u32, denominator: u32) -> Option<f64> {
    if numerator == 0 || denominator == 0 {
        return None;
    }
    let hz = round_to(numerator as f64 / denominator as f64, 2);
    (hz > 0.0 && hz <= 1000.0).then_some(hz)
}

// ---------------------------------------------------------------------------------------------
// displays_hash
// ---------------------------------------------------------------------------------------------

static DISPLAYS_HASH: Mutex<Option<(Instant, Option<String>)>> = Mutex::new(None);

fn store_displays_hash(hash: Option<String>) {
    *DISPLAYS_HASH.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), hash));
}

fn cached_displays_hash() -> Option<String> {
    let mut cache = DISPLAYS_HASH.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, hash)) = cache.as_ref() {
        if at.elapsed() < DISPLAYS_HASH_TTL {
            return hash.clone();
        }
    }
    let hash = displays_hash(&collect_displays());
    *cache = Some((Instant::now(), hash.clone()));
    hash
}

/// SHA-256 hex of the JCS (RFC 8785) form of the display list: the same value the panel's
/// `displaysHashOf` computes from the list it received. `None` for an empty list.
fn displays_hash(displays: &[SenseDisplay]) -> Option<String> {
    if displays.is_empty() {
        return None;
    }
    let value = serde_json::to_value(displays).ok()?;
    let digest = Sha256::digest(canonical_json(&value).as_bytes());
    Some(digest.iter().map(|b| format!("{b:02x}")).collect())
}

/// JCS for the values this module produces: keys sorted (all ASCII, so byte order equals the
/// UTF-16 order JCS asks for), whole floats written as integers like ECMAScript does, other
/// numbers and strings as `serde_json` writes them (same shortest form / escapes as JSON.stringify
/// for these ranges). Sense Remote (wave 3): also the signed heartbeat report (`report_sig.rs`).
pub(super) fn canonical_json(value: &Value) -> String {
    match value {
        Value::Array(items) => {
            let parts: Vec<String> = items.iter().map(canonical_json).collect();
            format!("[{}]", parts.join(","))
        }
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|a, b| a.0.cmp(b.0));
            let parts: Vec<String> = entries
                .into_iter()
                .map(|(k, v)| format!("{}:{}", Value::String(k.clone()), canonical_json(v)))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
        Value::Number(n) => {
            if n.is_f64() {
                let f = n.as_f64().unwrap_or(0.0);
                if f.fract() == 0.0 && f.abs() < 9.0e15 {
                    return format!("{}", f as i64);
                }
            }
            n.to_string()
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    // Field names and enum values of the Zod contract
    // (sense-remote-panel packages/shared/src/client-api/sense-ext.ts + common.ts, main 6ef012c).
    const SCHEMA_DISPLAY_KEYS: [&str; 15] = [
        "index", "name", "x", "y", "width", "height", "scale", "primary", "refresh_hz",
        "connection", "bit_depth", "color_format", "hdr", "native_width", "native_height",
    ];
    const SCHEMA_DISPLAY_REQUIRED: [&str; 5] = ["index", "x", "y", "width", "height"];
    const SCHEMA_HEALTH_KEYS: [&str; 9] = [
        "at", "cpu_pct", "gpu_pct", "cpu_temp_c", "gpu_temp_c", "mem_used_mb", "mem_total_mb",
        "disks", "uptime_s",
    ];
    const SCHEMA_DISK_KEYS: [&str; 3] = ["mount", "used_pct", "total_gb"];
    const SCHEMA_SYSINFO_KEYS: [&str; 7] =
        ["v", "role", "app_version", "platform", "displays", "displays_hash", "network"];
    // SenseHeartbeatExt (+ wave 2 envelope fields filled by I4, + wave 3 `caps` and the signed
    // `report`, contract v3).
    // Sense Remote (Mac M4): + `mac_permissions` (panel PR #41, Mac plan §3.4).
    const SCHEMA_HEARTBEAT_KEYS: [&str; 12] = [
        "v", "role", "app_version", "displays_hash", "health", "applied_seq",
        "maintenance_curtain", "envelope_error", "clock_skew_s", "caps", "report",
        "mac_permissions",
    ];
    const SCHEMA_MAC_PERMISSION_KEYS: [&str; 3] =
        ["screen_recording", "accessibility", "input_monitoring"];
    // Contract v3: `caps` is at most 16 strings of at most 32 characters.
    const SCHEMA_CAPS_MAX: usize = 16;
    const SCHEMA_CAP_MAX_CHARS: usize = 32;
    // SenseNetworkInterface (P0 branch ortak/sozlesme-v2, 40d007a).
    const SCHEMA_NETWORK_KEYS: [&str; 5] = ["name", "kind", "ipv4", "ipv6", "up"];
    const SCHEMA_NETWORK_KINDS: [&str; 3] = ["ethernet", "wifi", "other"];
    const SCHEMA_ROLES: [&str; 3] = ["host", "controller", "host_controller"];
    const SCHEMA_PLATFORMS: [&str; 2] = ["windows-x64", "macos-arm64"];
    const SCHEMA_CONNECTIONS: [&str; 8] = [
        "hdmi", "displayport", "dvi", "vga", "usb_c", "internal", "other", "unknown",
    ];
    const SCHEMA_COLOR_FORMATS: [&str; 5] = ["rgb", "ycbcr444", "ycbcr422", "ycbcr420", "unknown"];

    const SAMPLES: &str = include_str!("testdata/sense-ext-samples.json");

    fn keys(value: &Value) -> BTreeSet<String> {
        value.as_object().unwrap().keys().cloned().collect()
    }

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    fn full_display() -> SenseDisplay {
        SenseDisplay {
            index: 0,
            name: Some("DELL U2720Q".into()),
            x: 0,
            y: 0,
            width: 3840,
            height: 2160,
            scale: Some(1.5),
            primary: Some(true),
            refresh_hz: Some(59.94),
            connection: Some("displayport".into()),
            bit_depth: Some(10),
            color_format: Some("rgb".into()),
            hdr: Some(true),
            native_width: Some(3840),
            native_height: Some(2160),
        }
    }

    fn full_network() -> Vec<SenseNetwork> {
        vec![SenseNetwork {
            name: "Ethernet".into(),
            kind: "ethernet".into(),
            ipv4: vec!["192.168.1.10".into()],
            ipv6: Some(vec!["2001:db8::10".into()]),
            up: Some(true),
        }]
    }

    fn full_health() -> SenseHealth {
        SenseHealth {
            at: 1_800_000_000,
            cpu_pct: Some(12.5),
            gpu_pct: Some(30.0),
            cpu_temp_c: Some(55.0),
            gpu_temp_c: Some(71.0),
            mem_used_mb: Some(8000),
            mem_total_mb: Some(32000),
            disks: Some(vec![SenseDisk {
                mount: "C:".into(),
                used_pct: 41.2,
                total_gb: Some(953.8),
            }]),
            uptime_s: Some(3600),
        }
    }

    /// Every field this module can fill has the contract's name, and nothing else is sent.
    #[test]
    fn field_names_match_contract() {
        let display = serde_json::to_value(full_display()).unwrap();
        assert_eq!(keys(&display), set(&SCHEMA_DISPLAY_KEYS));
        let health = serde_json::to_value(full_health()).unwrap();
        assert_eq!(keys(&health), set(&SCHEMA_HEALTH_KEYS));
        assert_eq!(keys(&health["disks"][0]), set(&SCHEMA_DISK_KEYS));
        let sysinfo = serde_json::to_value(SysinfoExt {
            v: EXT_VERSION,
            role: "host".into(),
            app_version: 1,
            platform: "windows-x64".into(),
            displays: Some(vec![full_display()]),
            displays_hash: Some("0".repeat(64)),
            network: Some(full_network()),
        })
        .unwrap();
        assert_eq!(keys(&sysinfo), set(&SCHEMA_SYSINFO_KEYS));
        assert_eq!(keys(&sysinfo["network"][0]), set(&SCHEMA_NETWORK_KEYS));
        assert!(SCHEMA_NETWORK_KINDS.contains(&sysinfo["network"][0]["kind"].as_str().unwrap()));
        let heartbeat = serde_json::to_value(HeartbeatBase {
            v: EXT_VERSION,
            role: "host".into(),
            app_version: 1,
            displays_hash: Some("0".repeat(64)),
            health: Some(full_health()),
            caps: Some(caps(true, true)),
            maintenance_curtain: Some(false),
            mac_permissions: Some(MacPermissions::default()),
        })
        .unwrap();
        assert!(keys(&heartbeat).is_subset(&set(&SCHEMA_HEARTBEAT_KEYS)));
        assert!(keys(&heartbeat).contains("maintenance_curtain"));
        assert_eq!(keys(&heartbeat["mac_permissions"]), set(&SCHEMA_MAC_PERMISSION_KEYS));
        // K-ROL-2: the capabilities fit the contract and say `role_all`.
        assert!(CAPS.len() <= SCHEMA_CAPS_MAX);
        assert!(CAPS.iter().all(|cap| !cap.is_empty() && cap.len() <= SCHEMA_CAP_MAX_CHARS));
        assert!(CAPS.contains(&"role_all"));
        assert!(caps(true, true).len() <= SCHEMA_CAPS_MAX);
        assert!(CAP_CURTAIN.len() <= SCHEMA_CAP_MAX_CHARS);
        assert!(!CAP_APPLY.is_empty() && CAP_APPLY.len() <= SCHEMA_CAP_MAX_CHARS);
        // Nothing unread is sent: an empty display has only the required fields.
        let minimal = serde_json::to_value(SenseDisplay {
            width: 1,
            height: 1,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(keys(&minimal), set(&SCHEMA_DISPLAY_REQUIRED));
        assert_eq!(keys(&serde_json::to_value(SenseHealth::default()).unwrap()), set(&["at"]));
    }

    /// K2-5: an empty adapter list is sent as `"network": []`; only an unread one is left out.
    #[test]
    fn empty_network_is_sent_as_an_empty_list() {
        let ext = |network| SysinfoExt {
            v: EXT_VERSION,
            role: "host".into(),
            app_version: 1,
            platform: "windows-x64".into(),
            displays: None,
            displays_hash: None,
            network,
        };
        let empty = serde_json::to_value(ext(Some(vec![]))).unwrap();
        assert_eq!(empty["network"], serde_json::json!([]));
        let unknown = serde_json::to_value(ext(None)).unwrap();
        assert!(unknown.get("network").is_none());
    }

    /// The panel's own test bodies parse into these structs (unknown field -> error) and come
    /// back unchanged.
    #[test]
    fn panel_samples_round_trip() {
        let samples: Value = serde_json::from_str(SAMPLES).unwrap();
        let sysinfo: SysinfoExt = serde_json::from_value(samples["sysinfo"].clone()).unwrap();
        assert_eq!(
            canonical_json(&serde_json::to_value(&sysinfo).unwrap()),
            canonical_json(&samples["sysinfo"])
        );
        let heartbeat: HeartbeatBase =
            serde_json::from_value(samples["heartbeat"].clone()).unwrap();
        assert_eq!(
            canonical_json(&serde_json::to_value(&heartbeat).unwrap()),
            canonical_json(&samples["heartbeat"])
        );
        // Sense Remote (Mac M4): the macOS bodies (panel PR #41) as well.
        let sysinfo: SysinfoExt =
            serde_json::from_value(samples["sysinfo_macos"].clone()).unwrap();
        assert_eq!(sysinfo.platform, "macos-arm64");
        assert_eq!(
            canonical_json(&serde_json::to_value(&sysinfo).unwrap()),
            canonical_json(&samples["sysinfo_macos"])
        );
        let heartbeat: HeartbeatBase =
            serde_json::from_value(samples["heartbeat_macos"].clone()).unwrap();
        assert_eq!(heartbeat.caps, Some(caps(false, true)));
        assert_eq!(
            heartbeat.mac_permissions,
            Some(MacPermissions {
                screen_recording: true,
                accessibility: true,
                input_monitoring: false,
            })
        );
        assert_eq!(
            canonical_json(&serde_json::to_value(&heartbeat).unwrap()),
            canonical_json(&samples["heartbeat_macos"])
        );
        // The Windows heartbeat has no `mac_permissions`.
        assert!(samples["heartbeat"].get("mac_permissions").is_none());
        let mut bad = samples["heartbeat_macos"]["mac_permissions"].clone();
        bad["camera"] = Value::from(true);
        assert!(serde_json::from_value::<MacPermissions>(bad).is_err());
        let mut bad = samples["sysinfo"]["displays"][0].clone();
        bad["serial"] = Value::from("X");
        assert!(serde_json::from_value::<SenseDisplay>(bad).is_err());
        // The MAC address is not part of the contract.
        let mut bad = samples["sysinfo"]["network"][0].clone();
        bad["mac"] = Value::from("00:11:22:33:44:55");
        assert!(serde_json::from_value::<SenseNetwork>(bad).is_err());
    }

    #[test]
    fn enum_values_are_in_contract() {
        for t in (0..=20).chain([0x8000_0000, 0xFFFF_FFFF]) {
            let c = connection_name(t);
            assert!(SCHEMA_CONNECTIONS.contains(&c), "{c}");
            assert_ne!(c, "usb_c");
        }
        for e in 0..=6 {
            if let Some(f) = color_format(e) {
                assert!(SCHEMA_COLOR_FORMATS.contains(&f), "{f}");
            }
        }
        for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
            assert!(SCHEMA_ROLES.contains(&role_name(role)));
        }
        if let Some(p) = platform() {
            assert!(SCHEMA_PLATFORMS.contains(&p));
        }
        if cfg!(all(windows, target_arch = "x86_64")) {
            assert_eq!(platform(), Some("windows-x64"));
        }
    }

    #[test]
    fn output_technology_table() {
        let table = [
            (0, "vga"),
            (1, "other"),
            (2, "other"),
            (3, "other"),
            (4, "dvi"),
            (5, "hdmi"),
            (6, "internal"),
            (8, "other"),
            (9, "other"),
            (10, "displayport"),
            (11, "internal"),
            (12, "other"),
            (13, "internal"),
            (14, "other"),
            (15, "other"),
            (16, "other"),
            (17, "other"),
            (18, "displayport"),
            (0x8000_0000, "internal"),
            (0xFFFF_FFFF, "other"),
        ];
        for (technology, expected) in table {
            assert_eq!(connection_name(technology), expected, "{technology:#x}");
        }
    }

    #[test]
    fn color_info_mapping() {
        assert_eq!(color_format(0), Some("rgb"));
        assert_eq!(color_format(3), Some("ycbcr420"));
        assert_eq!(color_format(4), None); // intensity
        assert!(!is_hdr(0b001)); // supported, off
        assert!(is_hdr(0b011)); // HDR on
        assert!(!is_hdr(0b111)); // advanced color for WCG on SDR, not HDR
    }

    #[test]
    fn refresh_rate_rounding_and_range() {
        assert_eq!(refresh_hz(60, 1), Some(60.0));
        assert_eq!(refresh_hz(59_940, 1000), Some(59.94));
        assert_eq!(refresh_hz(60_000, 1001), Some(59.94));
        assert_eq!(refresh_hz(144_000, 1001), Some(143.86));
        assert_eq!(refresh_hz(0, 0), None);
        assert_eq!(refresh_hz(60, 0), None);
        assert_eq!(refresh_hz(2_000_000, 1), None);
    }

    #[test]
    fn merge_keeps_controller_index_and_leaves_unread_out() {
        let geometry = vec![
            Geometry {
                name: "\\\\.\\DISPLAY1".into(),
                x: 0,
                y: 0,
                width: 3840,
                height: 2160,
                primary: true,
            },
            Geometry {
                name: "\\\\.\\DISPLAY9".into(),
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                primary: false,
            },
            Geometry {
                name: "\\\\.\\DISPLAY2".into(),
                x: -1920,
                y: 0,
                width: 1920,
                height: 1080,
                primary: false,
            },
        ];
        let mut details = HashMap::new();
        details.insert(
            "\\\\.\\DISPLAY1".to_owned(),
            DisplayDetails {
                name: Some("  DELL U2720Q ".into()),
                output_technology: Some(10),
                refresh: Some((59_940, 1000)),
                advanced_color: Some((0b011, 0, 10)),
                native: Some((3840, 2160)),
                ..Default::default()
            },
        );
        details.insert(
            "\\\\.\\DISPLAY2".to_owned(),
            DisplayDetails {
                name: Some(String::new()),
                output_technology: Some(5),
                refresh: Some((60, 1)),
                advanced_color: Some((0, 99, 0)),
                native: Some((0, 0)),
                ..Default::default()
            },
        );
        let displays = merge_displays(&geometry, &details);
        assert_eq!(displays.len(), 2);
        let mut first = full_display();
        first.scale = None;
        assert_eq!(displays[0], first);
        assert_eq!(
            displays[1],
            SenseDisplay {
                index: 2, // the zero-size entry keeps its slot
                x: -1920,
                y: 0,
                width: 1920,
                height: 1080,
                primary: Some(false),
                refresh_hz: Some(60.0),
                connection: Some("hdmi".into()),
                hdr: Some(false),
                ..Default::default()
            }
        );
        // No details at all (e.g. the CCD API failed): geometry only.
        let plain = merge_displays(&geometry[..1], &HashMap::new());
        assert_eq!(
            keys(&serde_json::to_value(&plain[0]).unwrap()),
            set(&["index", "x", "y", "width", "height", "primary"])
        );
    }

    /// Same bytes as the panel: `displaysHashOf` (JCS + SHA-256) on this list, computed with
    /// `packages/shared/src/jcs.ts` (main 6ef012c).
    #[test]
    fn displays_hash_matches_panel_jcs() {
        let mut first = full_display();
        first.scale = None;
        let second = SenseDisplay {
            index: 1,
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080,
            primary: Some(false),
            refresh_hz: Some(60.0),
            connection: Some("hdmi".into()),
            ..Default::default()
        };
        let list = vec![first, second];
        assert_eq!(
            canonical_json(&serde_json::to_value(&list).unwrap()),
            "[{\"bit_depth\":10,\"color_format\":\"rgb\",\"connection\":\"displayport\",\
             \"hdr\":true,\"height\":2160,\"index\":0,\"name\":\"DELL U2720Q\",\
             \"native_height\":2160,\"native_width\":3840,\"primary\":true,\
             \"refresh_hz\":59.94,\"width\":3840,\"x\":0,\"y\":0},\
             {\"connection\":\"hdmi\",\"height\":1080,\"index\":1,\"primary\":false,\
             \"refresh_hz\":60,\"width\":1920,\"x\":-1920,\"y\":0}]"
        );
        assert_eq!(
            displays_hash(&list).as_deref(),
            Some("72cfb7232992afeaf653ac62aabaaaf3534d192f184b54330c7fd7001a44576f")
        );
        assert_eq!(displays_hash(&[]), None);
    }

    #[test]
    fn disks_and_mounts() {
        if cfg!(windows) {
            assert_eq!(mount_name("C:\\").as_deref(), Some("C:"));
        }
        assert_eq!(mount_name(""), None);
        assert_eq!(disk_entry("C:".into(), 0, 0), None);
        let d = disk_entry("C:".into(), 1024 * 1024 * 1024 * 100, 1024 * 1024 * 1024 * 60).unwrap();
        assert_eq!(d.used_pct, 40.0);
        assert_eq!(d.total_gb, Some(100.0));
        // Available larger than total (racy read) never gives a negative value.
        assert_eq!(disk_entry("C:".into(), 10, 20).unwrap().used_pct, 0.0);
    }

    #[test]
    fn cpu_values() {
        assert_eq!(cpu_pct(12.34), Some(12.3));
        assert_eq!(cpu_pct(130.0), Some(100.0));
        assert_eq!(cpu_pct(f32::NAN), None);
        let readings = [("Computer", 48.0f32), ("GPU", 80.0), ("CPU Package", 61.26)];
        assert_eq!(pick_cpu_temp(readings.into_iter()), Some(61.3));
        assert_eq!(pick_cpu_temp([("GPU", 80.0f32)].into_iter()), None);
        assert_eq!(pick_cpu_temp([("cpu", f32::NAN), ("core 0", 400.0)].into_iter()), None);
    }

    #[test]
    fn network_hash_is_stable_and_order_sensitive() {
        let mut two = full_network();
        two.push(SenseNetwork {
            name: "Wi-Fi".into(),
            kind: "wifi".into(),
            ipv4: vec!["192.168.1.20".into()],
            ipv6: None,
            up: Some(true),
        });
        assert_eq!(network_hash(Some(&two[..])), network_hash(Some(&two.clone()[..])));
        assert_ne!(network_hash(Some(&two[..])), network_hash(Some(&two[..1])));
        // K2-5: unplugging the last adapter is a change from "unknown" too.
        assert_ne!(network_hash(None), network_hash(Some(&[][..])));
        assert_ne!(network_hash(Some(&two[..])), network_hash(Some(&[][..])));
        let mut moved = two.clone();
        moved[1].ipv4 = vec!["192.168.1.21".into()];
        assert_ne!(network_hash(Some(&two[..])), network_hash(Some(&moved[..])));
    }

    // Update plan 2026-11-21 §3.5: `update` follows the one switch and comes last.
    #[test]
    fn update_cap_follows_the_switch() {
        use crate::sense::update;
        assert_eq!(caps_with_update(caps(true, true), false), caps(true, true));
        assert_eq!(
            caps_with_update(caps(true, true), true),
            ["role_all", "curtain", "apply", "update"]
        );
        assert_eq!(caps_with_update(caps(false, false), true), ["role_all", "update"]);
        assert!(caps_with_update(caps(true, true), true).len() <= SCHEMA_CAPS_MAX);
        assert!(update::CAP_UPDATE.len() <= SCHEMA_CAP_MAX_CHARS);
    }

    // Sense Remote (U8): the signed report's `caps` carries `update` on Windows and macOS (run by
    // the Windows and Mac CI jobs) and not on Linux.
    #[test]
    fn update_cap_on_windows_and_macos_only() {
        let reported = caps_with_update(caps(false, false), crate::sense::update::SUPPORTED);
        let has_update = reported.iter().any(|cap| cap == "update");
        #[cfg(any(windows, target_os = "macos"))]
        assert!(has_update);
        #[cfg(not(any(windows, target_os = "macos")))]
        assert!(!has_update);
    }

    // Permanent password plan §3.5: `password` follows its one switch, which is off in U9.
    #[test]
    fn password_cap_follows_the_switch() {
        use crate::sense::password;
        assert!(!password::SUPPORTED);
        let base = || caps_with_update(caps(true, true), true);
        assert_eq!(caps_with_password(base(), password::SUPPORTED), base());
        assert!(!caps_with_password(base(), password::SUPPORTED)
            .iter()
            .any(|cap| cap == "password"));
        assert_eq!(
            caps_with_password(base(), true),
            ["role_all", "curtain", "apply", "update", "password"]
        );
        assert!(caps_with_password(base(), true).len() <= SCHEMA_CAPS_MAX);
        assert!(password::CAP_PASSWORD.len() <= SCHEMA_CAP_MAX_CHARS);
    }

    /// I10: `curtain` and `maintenance_curtain` only where the curtain can be shown; the order
    /// matches the shared vector (`hb-report-v1.json`, case `ok_full`), so the signed text is
    /// byte for byte the panel's.
    #[test]
    fn caps_and_curtain_state() {
        assert_eq!(caps(false, false), vec!["role_all".to_owned()]);
        assert_eq!(caps(true, false), vec!["role_all".to_owned(), "curtain".to_owned()]);
        // Mac M4: `apply` only where envelopes are applied; a Mac (no curtain) then sends the
        // list of the panel's macOS sample.
        assert_eq!(caps(false, true), vec!["role_all".to_owned(), "apply".to_owned()]);
        assert_eq!(caps(true, true), ["role_all", "curtain", "apply"]);
        for curtain in [false, true] {
            assert!(!caps(curtain, false).contains(&CAP_APPLY.to_owned()));
            assert!(caps(curtain, true).contains(&CAP_APPLY.to_owned()));
        }
        assert_eq!(curtain_state(false, true), None);
        assert_eq!(curtain_state(true, false), Some(false));
        assert_eq!(curtain_state(true, true), Some(true));

        let vector: Value =
            serde_json::from_str(include_str!("testdata/hb-report-v1.json")).unwrap();
        let ok_full = vector["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|case| case["name"] == "ok_full")
            .unwrap();
        let sense = &ok_full["heartbeat"]["sense"];
        assert_eq!(sense["caps"], serde_json::json!(caps(true, false)));
        assert_eq!(sense["maintenance_curtain"], serde_json::json!(true));

        // Unsupported (macOS, Windows before 2004): neither field leaves the computer.
        let base = |supported: bool| {
            serde_json::to_value(HeartbeatBase {
                v: EXT_VERSION,
                role: "host".into(),
                app_version: 1,
                displays_hash: None,
                health: None,
                caps: Some(caps(supported, false)),
                maintenance_curtain: curtain_state(supported, false),
                mac_permissions: None,
            })
            .unwrap()
        };
        assert!(base(false).get("maintenance_curtain").is_none());
        assert_eq!(base(false)["caps"], serde_json::json!(["role_all"]));
        assert_eq!(base(true)["maintenance_curtain"], serde_json::json!(false));
        // Outside Windows there is no curtain, so no `curtain` capability (MAC-SONRA-15).
        #[cfg(not(windows))]
        assert!(!crate::sense::curtain::is_supported());
    }

    /// Mac M4: what `displays_mac` reads, mapped to the contract.
    #[test]
    fn mac_display_values() {
        assert_eq!(mac_scale(3024, 1512), Some(2.0));
        assert_eq!(mac_scale(1920, 1920), Some(1.0));
        assert_eq!(mac_scale(0, 1512), None);
        assert_eq!(mac_scale(3024, 0), None);
        assert_eq!(mac_scale(100, 1000), None); // below 1: not a real mode
        assert_eq!(mac_scale(10_000, 100), None);
        assert_eq!(mac_pixel_size((1512, 982), Some(2.0)), Some((3024, 1964)));
        assert_eq!(mac_pixel_size((1080, 1920), Some(1.0)), Some((1080, 1920))); // rotated
        assert_eq!(mac_pixel_size((1512, 982), None), None);
        assert_eq!(mac_pixel_size((0, 982), Some(2.0)), None);
        assert_eq!(mac_refresh(120.0, Some(120)), Some((120_000, 1000)));
        assert_eq!(mac_refresh(59.94, None), Some((59_940, 1000)));
        assert_eq!(mac_refresh(0.0, Some(60)), Some((60_000, 1000))); // built-in panel
        assert_eq!(mac_refresh(0.0, None), None);
        assert_eq!(mac_refresh(0.0, Some(0)), None);
        assert_eq!(mac_refresh(f64::NAN, None), None);
        assert_eq!(mac_refresh(5000.0, None), None);
        let (num, den) = mac_refresh(59.94, None).unwrap();
        assert_eq!(refresh_hz(num, den), Some(59.94));
    }

    /// Mac M4: a Retina laptop with an external display, as `collect_displays` builds it on
    /// macOS. The result does not depend on scrap's Retina switch (its size is only used
    /// when the mode could not be read).
    #[test]
    fn mac_displays_keep_controller_order_and_send_only_what_was_read() {
        let mut details = HashMap::new();
        details.insert(
            "1".to_owned(),
            DisplayDetails {
                name: Some("Built-in Retina Display".into()),
                scale: mac_scale(3024, 1512),
                pixel_size: mac_pixel_size((1512, 982), Some(2.0)),
                refresh: mac_refresh(120.0, Some(120)),
                ..Default::default()
            },
        );
        details.insert(
            "5".to_owned(),
            DisplayDetails {
                scale: mac_scale(1920, 1920),
                pixel_size: mac_pixel_size((1920, 1080), Some(1.0)),
                refresh: mac_refresh(60.0, None),
                ..Default::default()
            },
        );
        // scrap's order: the external display first; with the Retina switch off scrap
        // reports the built-in panel in points.
        let geometry = vec![
            mac_geometry("5".into(), (1512, 0), (1920, 1080), false, details.get("5")),
            mac_geometry("1".into(), (0, 0), (1512, 982), true, details.get("1")),
            mac_geometry("9".into(), (-800, 0), (800, 600), false, details.get("9")),
        ];
        let displays = merge_displays(&geometry, &details);
        assert_eq!(
            displays,
            vec![
                SenseDisplay {
                    index: 0,
                    x: 1512,
                    y: 0,
                    width: 1920,
                    height: 1080,
                    scale: Some(1.0),
                    primary: Some(false),
                    refresh_hz: Some(60.0),
                    ..Default::default()
                },
                SenseDisplay {
                    index: 1,
                    name: Some("Built-in Retina Display".into()),
                    x: 0,
                    y: 0,
                    width: 3024,
                    height: 1964,
                    scale: Some(2.0),
                    primary: Some(true),
                    refresh_hz: Some(120.0),
                    ..Default::default()
                },
                // Not in the details: scrap's geometry only.
                SenseDisplay {
                    index: 2,
                    x: -800,
                    y: 0,
                    width: 800,
                    height: 600,
                    primary: Some(false),
                    ..Default::default()
                },
            ]
        );
        // No connection type, bit depth, color format, HDR or native size on macOS.
        for d in &displays {
            let value = serde_json::to_value(d).unwrap();
            assert!(keys(&value).is_subset(&set(&[
                "index", "name", "x", "y", "width", "height", "scale", "primary", "refresh_hz",
            ])));
        }
        // Windows details never carry a scale: the field stays out there.
        let windows = merge_displays(
            &geometry[..1],
            &HashMap::from([("5".to_owned(), DisplayDetails::default())]),
        );
        assert_eq!(windows[0].scale, None);
    }

    /// Mac M4 (plan §3.4): `mac_permissions` is sent by macOS only and is not signed.
    #[test]
    fn mac_permissions_only_on_macos_and_outside_the_signed_report() {
        assert_eq!(mac_permissions().is_some(), cfg!(target_os = "macos"));
        let base = |mac_permissions| {
            serde_json::to_value(HeartbeatBase {
                v: EXT_VERSION,
                role: "host".into(),
                app_version: 2,
                displays_hash: None,
                health: None,
                caps: Some(caps(false, true)),
                maintenance_curtain: None,
                mac_permissions,
            })
            .unwrap()
        };
        // Windows: the field is not in the body at all.
        let mut windows = base(None);
        assert!(windows.get("mac_permissions").is_none());
        let mut mac = base(Some(MacPermissions {
            screen_recording: true,
            accessibility: false,
            input_monitoring: true,
        }));
        assert_eq!(
            mac["mac_permissions"],
            serde_json::json!({
                "screen_recording": true, "accessibility": false, "input_monitoring": true
            })
        );
        // Same signed bytes with and without it, whatever its value.
        windows["applied_seq"] = Value::from(4);
        mac["applied_seq"] = Value::from(4);
        let signed = |sense: &Value| {
            crate::sense::report_sig::signed_bytes("123456789", "uuid", 1_800_000_000, sense)
        };
        assert!(signed(&windows).is_some());
        assert_eq!(signed(&windows), signed(&mac));
        mac["mac_permissions"]["accessibility"] = Value::from(true);
        assert_eq!(signed(&windows), signed(&mac));
        // `caps` is signed: changing it changes the bytes.
        mac["caps"] = serde_json::json!(["role_all"]);
        assert_ne!(signed(&windows), signed(&mac));
    }

    /// Mac M4: the root daemon's update check never starts an update from a test process: not
    /// root -> it stops at the root-owned lock; root -> at the option, which Sense pins to "N"
    /// (`sense.rs`, test `hide_cm_remote_config_and_auto_update_are_pinned_off`) and which is off
    /// by default.
    #[cfg(target_os = "macos")]
    #[test]
    fn root_update_check_does_not_start_an_update() {
        assert!(!matches!(crate::updater::check_update_as_root(), Ok(true)));
    }

    #[test]
    fn app_version_and_health_interval() {
        assert_eq!(parse_app_version(Some("3")), Some(3));
        assert_eq!(parse_app_version(Some(" 12 ")), Some(12));
        assert_eq!(parse_app_version(Some("0")), None);
        assert_eq!(parse_app_version(Some("1.4")), None);
        assert_eq!(parse_app_version(None), None);
        let now = Instant::now();
        assert!(health_due(None, now));
        assert!(!health_due(Some(now), now + Duration::from_secs(59)));
        assert!(health_due(Some(now), now + HEALTH_INTERVAL));
    }

    /// Real measurement on the CI machine: whatever it reads must fit the contract.
    #[test]
    fn live_values_fit_contract() {
        let health: SenseHealth = serde_json::from_value(health()).unwrap();
        assert!(health.at > 1_700_000_000);
        if let Some(cpu) = health.cpu_pct {
            assert!((0.0..=100.0).contains(&cpu));
        }
        if let Some(t) = health.cpu_temp_c {
            assert!((-20.0..=150.0).contains(&t));
        }
        if let (Some(used), Some(total)) = (health.mem_used_mb, health.mem_total_mb) {
            assert!(total > 0 && used <= total);
        }
        for disk in health.disks.unwrap_or_default() {
            assert!((0.0..=100.0).contains(&disk.used_pct));
            assert!(!disk.mount.is_empty() && disk.mount.len() <= MAX_MOUNT_CHARS);
        }
        let (displays, hash) = displays();
        assert_eq!(displays.is_empty(), hash.is_none());
        for d in &displays {
            let parsed: SenseDisplay = serde_json::from_value(d.clone()).unwrap();
            assert!(parsed.width > 0 && parsed.height > 0 && parsed.index < 32);
            if let Some(hz) = parsed.refresh_hz {
                assert!(hz > 0.0 && hz <= 1000.0);
            }
            if let Some(bits) = parsed.bit_depth {
                assert!((6..=16).contains(&bits));
            }
            assert!(keys(d).is_subset(&set(&SCHEMA_DISPLAY_KEYS)));
        }
        if cfg!(not(any(windows, target_os = "macos"))) {
            assert!(displays.is_empty());
        }
        // Mac M4: index and order are those of the controller's list.
        let indexes: Vec<u64> = displays.iter().filter_map(|d| d["index"].as_u64()).collect();
        assert!(indexes.windows(2).all(|pair| pair[0] < pair[1]));
        for n in network() {
            assert!(keys(&n).is_subset(&set(&SCHEMA_NETWORK_KEYS)));
            assert!(SCHEMA_NETWORK_KINDS.contains(&n["kind"].as_str().unwrap()));
        }
    }
}
