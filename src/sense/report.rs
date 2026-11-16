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
//!   health at most once per `HEALTH_INTERVAL`). I4 adds `applied_seq`, `envelope_error`,
//!   `clock_skew_s` to this object.
//! - `health()`, `displays()` and `network()` for direct use.
//!
//! `network` (adapter IP addresses, `network.rs`) goes into sysinfo and, with `health`, into the
//! heartbeat at most once per `HEALTH_INTERVAL`, so a changed DHCP address shows within a minute.
//! Both builders return `None` when there is no installed role (portable / not installed),
//! no `SENSE_VERSION` at build time, or an unsupported platform: then no `sense` is sent.
//!
//! Blocking: the first `health()` sleeps `MINIMUM_CPU_UPDATE_INTERVAL` (200 ms) to get a CPU
//! value, and the temperature query (WMI on Windows) can take a moment; a display read creates
//! DXGI objects. Call from a blocking context (e.g. `spawn_blocking`) if the caller is async.
//!
//! MAC-SONRA: macOS sends no displays yet (CGDisplay / IOKit, plan MAC-SONRA-10); health comes
//! from `sysinfo` (temperature may be unavailable on Apple Silicon, MAC-SONRA-11).

// Sense Remote: the sync loop starts using these in task I4.
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network: Option<Vec<SenseNetwork>>,
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
        network: network_list(),
    };
    to_json(&ext)
}

/// `heartbeat["sense"]` without the envelope fields. Contains `health` when the last one was
/// put in at least `HEALTH_INTERVAL` ago.
pub fn heartbeat_base() -> Option<Value> {
    let (role, app_version, _) = identity()?;
    let due = take_health_slot(Instant::now());
    let base = HeartbeatBase {
        v: EXT_VERSION,
        role: role_name(role).to_owned(),
        app_version,
        displays_hash: cached_displays_hash(),
        health: due.then(measure_health),
        network: if due { network_list() } else { None },
    };
    to_json(&base)
}

/// `SenseHealth` measured now.
pub fn health() -> Value {
    let health = measure_health();
    to_json(&health).unwrap_or_else(|| serde_json::json!({ "at": health.at }))
}

/// (`SenseDisplay` list, `displays_hash`). Both empty / `None` when nothing could be read
/// (macOS for now, Session 0, lock screen): then the fields are not sent and the panel keeps
/// the last known displays.
pub fn displays() -> (Vec<Value>, Option<String>) {
    let displays = collect_displays();
    let hash = displays_hash(&displays);
    let values = displays.iter().filter_map(to_json).collect();
    (values, hash)
}

/// `sense.network`: Ethernet / Wi-Fi adapters with their IP addresses (no MAC).
pub fn network() -> Vec<Value> {
    super::network::collect().iter().filter_map(to_json).collect()
}

fn network_list() -> Option<Vec<SenseNetwork>> {
    let list = super::network::collect();
    (!list.is_empty()).then_some(list)
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

/// Raw per-display values from the OS (Windows: `displays_win`), mapped by the pure
/// functions below.
#[derive(Debug, Clone, Default)]
pub(super) struct DisplayDetails {
    pub name: Option<String>,
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

// MAC-SONRA: CGDisplayBounds / CGDisplayCopyDisplayMode (plan MAC-SONRA-10).
#[cfg(not(windows))]
fn collect_displays() -> Vec<SenseDisplay> {
    Vec::new()
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
/// for these ranges).
fn canonical_json(value: &Value) -> String {
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
    // SenseHeartbeatExt (+ wave 2 envelope fields filled by I4, + network).
    const SCHEMA_HEARTBEAT_KEYS: [&str; 10] = [
        "v", "role", "app_version", "displays_hash", "health", "applied_seq",
        "maintenance_curtain", "envelope_error", "clock_skew_s", "network",
    ];
    // Network entry (contract from the coordinator, 2026-11-17; P0 branch ortak/sozlesme-v2).
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
            network: Some(full_network()),
        })
        .unwrap();
        assert!(keys(&heartbeat).is_subset(&set(&SCHEMA_HEARTBEAT_KEYS)));
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
        if cfg!(not(windows)) {
            assert!(displays.is_empty()); // MAC-SONRA
        }
        for n in network() {
            assert!(keys(&n).is_subset(&set(&SCHEMA_NETWORK_KEYS)));
            assert!(SCHEMA_NETWORK_KINDS.contains(&n["kind"].as_str().unwrap()));
        }
    }
}
