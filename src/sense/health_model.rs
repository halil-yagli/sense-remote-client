//! Sense Remote (S6): detailed health data for the panel's "Bilgisayar durumu" popup (O8).
//!
//! Two parts, as the roadmap asks (S6):
//! - `Inventory`: fixed facts (models, drivers, BIOS, memory slots, disk models, network
//!   configuration). Read at start and every `INVENTORY_INTERVAL` in a background thread; sent
//!   in sysinfo (`sense.inventory`) only when its summary (hash) differs from the one sent.
//! - Live values (usage, temperatures, traffic, read / write rates, GPU): extra optional fields
//!   of the heartbeat's `health` (`report::SenseHealth`), measured with it once a minute.
//!
//! Both are sent only while the panel announces `health_v2` in its heartbeat answer
//! (`sense_panel_caps`): the panel's schema is strict, so an older panel gets today's body.
//!
//! This module holds the contract shapes and the pure rules (value ranges, rates, grouping,
//! change detection), tested on every platform. Reading the values is in `health_*` /
//! `inventory_*`. A value that cannot be read, or is outside its plausible range, is left out
//! (the panel shows "okunamadı"); nothing is estimated.
//!
//! Contract: `Calisma/plan/2026-11-23_saglik-sozlesmesi.md` (atölye).

// Sense Remote: parts are used only on one platform or by the tests.
#![allow(dead_code)]

use serde_derive::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    time::{Duration, Instant},
};

/// Capability the panel announces in its heartbeat answer when it accepts the fields below.
pub const CAP_HEALTH_V2: &str = "health_v2";
/// Sense Remote (Sürüm 9, O8): `physical_disks[].written_gb` / `written_boot_gb`.
pub const CAP_DISK_WRITTEN: &str = "disk_written";
/// Health interval while a session is open (O8 "Canlı · 8 sn önce"); only the live values, never
/// the inventory. The sync loop runs every 3 s with a session, so it is sent about every 9 s.
pub const HEALTH_INTERVAL_CONNECTED: Duration = Duration::from_secs(8);

/// How often `health` goes into the heartbeat: `HEALTH_INTERVAL_CONNECTED` while connected and
/// the panel takes `health_v2` (an older panel's contract says at most once a minute), else
/// `idle`.
pub fn health_interval(v2: bool, connected: bool, idle: Duration) -> Duration {
    if v2 && connected {
        HEALTH_INTERVAL_CONNECTED.min(idle)
    } else {
        idle
    }
}

/// The inventory is read again this often (and at start).
pub const INVENTORY_INTERVAL: Duration = Duration::from_secs(30 * 60);
/// Sense Remote (Sürüm 10, #117): after a reading that failed (the main script did not finish,
/// nothing read), the next one starts this soon instead of after `INVENTORY_INTERVAL`.
pub const INVENTORY_RETRY: Duration = Duration::from_secs(2 * 60);

pub const MAX_TEXT: usize = 128;
pub const MAX_ITEMS: usize = 32;
pub const MAX_TOP_PROCESSES: usize = 5;

// ---------------------------------------------------------------------------------------------
// Inventory (sysinfo `sense.inventory`)
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inventory {
    /// Unix seconds of the reading; not part of the change summary.
    pub at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu: Option<CpuInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpus: Option<Vec<GpuInfo>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory: Option<MemoryInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub physical_disks: Option<Vec<PhysicalDisk>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network: Option<Vec<NetAdapter>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub board: Option<BoardInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bios: Option<BiosInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub serial: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usb: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power_plan: Option<String>,
    /// "Elektrik kesilince açılış": true = the computer starts again after a power loss.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power_restore: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<OsInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<DriverInfo>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CpuInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cores: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub threads: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_mhz: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GpuInfo {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub integrated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vram_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub driver_version: Option<String>,
    /// YYYY-MM-DD
    #[serde(skip_serializing_if = "Option::is_none")]
    pub driver_date: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slots_total: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modules: Option<Vec<MemoryModule>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryModule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slot: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_mb: Option<u64>,
    /// "DDR4", "LPDDR5" ...
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed_mts: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PhysicalDisk {
    /// Join key with the live `physical_disks`: Windows disk number ("0"), macOS BSD name
    /// ("disk0").
    pub id: String,
    pub model: String,
    /// "nvme" | "sata" | "usb" | "sas" | "raid" | "other"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bus: Option<String>,
    /// "ssd" | "hdd"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_gb: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub firmware: Option<String>,
    /// "ok" | "warning" | "failing"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub health: Option<String>,
    /// Remaining life (100 - NVMe "percentage used").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub life_left_pct: Option<f64>,
    /// Drive letters / volumes on the disk ("C:").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mounts: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetAdapter {
    /// Shown name ("Ethernet", "Wi-Fi"); same as `sense.network[].name` on Windows.
    pub name: String,
    /// BSD name on macOS ("en0"): the live `net_io[].name` there.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// "ethernet" | "wifi" | "other"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Card model / driver description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac: Option<String>,
    /// false = cable not plugged / not associated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected: Option<bool>,
    /// true = DHCP, false = static.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dhcp: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gateway: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dns: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed_mbps: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub driver_version: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BoardInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BiosInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// YYYY-MM-DD
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OsInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
    /// YYYY-MM-DD of the last installed update.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_update: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DriverInfo {
    /// "display" | "network" | "wifi" | "audio" | "chipset"
    pub class: String,
    pub device: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// YYYY-MM-DD
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
}

// ---------------------------------------------------------------------------------------------
// Live values (extra fields of heartbeat `health`)
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TopProcess {
    pub name: String,
    /// Share of the whole CPU (all cores = 100).
    pub cpu_pct: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GpuLive {
    /// Same text as `inventory.gpus[].name` where both are read from the same adapter.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub util_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vram_used_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vram_total_mb: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temp_c: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fan_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power_w: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiskLive {
    /// `inventory.physical_disks[].id`
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read_bps: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub write_bps: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temp_c: Option<f64>,
    /// Sense Remote (Sürüm 9, O8): data the disk has written over its whole life, GB (decimal),
    /// from the drive's own SMART counter. Only with the panel capability `disk_written`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub written_gb: Option<f64>,
    /// Sense Remote (Sürüm 9, O8): data written since the computer started, GB. macOS has no
    /// lifetime counter without root; this one restarts from 0 at every boot, so it is its own
    /// field and never shown as "total written". Only with the panel capability `disk_written`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub written_boot_gb: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetLive {
    /// Windows: adapter name ("Ethernet"); macOS: BSD name ("en0").
    pub name: String,
    /// Bytes per second since the previous heartbeat health.
    pub rx_bps: u64,
    pub tx_bps: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WifiLive {
    /// Adapter name ("Wi-Fi").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssid: Option<String>,
    /// "2.4 GHz" | "5 GHz" | "6 GHz"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub band: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signal_pct: Option<f64>,
}

// ---------------------------------------------------------------------------------------------
// Value rules
// ---------------------------------------------------------------------------------------------

pub fn round_to(value: f64, decimals: i32) -> f64 {
    let f = 10f64.powi(decimals);
    (value * f).round() / f
}

/// A percentage; a small overshoot from summed counters is capped, anything else is dropped.
pub fn pct(value: f64) -> Option<f64> {
    (value.is_finite() && (0.0..=101.0).contains(&value)).then(|| round_to(value.min(100.0), 1))
}

/// Written data in GB (decimal, one decimal place). Above 10 million GB (10 PB) is a broken
/// counter, not a disk.
pub fn written_gb(bytes: u128) -> Option<f64> {
    let gb = bytes as f64 / 1.0e9;
    (gb.is_finite() && gb <= 1.0e7).then(|| round_to(gb, 1))
}

/// NVMe SMART / Health log page (id 2, 512 bytes): "Data Units Written" is the 128-bit
/// little-endian value at bytes 48..64, in units of 1000 x 512 bytes. An all-zero value is not
/// trusted (a bridge or driver that returns an empty page), so it is "not read".
pub fn nvme_written_bytes(log: &[u8]) -> Option<u128> {
    let raw: [u8; 16] = log.get(48..64)?.try_into().ok()?;
    let units = u128::from_le_bytes(raw);
    if units == 0 {
        return None;
    }
    units.checked_mul(512_000)
}

/// CPU / GPU / disk temperature in °C; outside -20..150 is a broken sensor.
pub fn temp_c(value: f64) -> Option<f64> {
    (value.is_finite() && (-20.0..=150.0).contains(&value) && value != 0.0)
        .then(|| round_to(value, 1))
}

pub fn power_w(value: f64) -> Option<f64> {
    (value.is_finite() && value > 0.0 && value <= 2000.0).then(|| round_to(value, 1))
}

pub fn mhz(value: f64) -> Option<u32> {
    (value.is_finite() && (100.0..=10_000.0).contains(&value)).then(|| value.round() as u32)
}

/// Bytes per second; above 100 GB/s is a counter wrap, not a measurement.
pub fn bps(value: f64) -> Option<u64> {
    (value.is_finite() && (0.0..=1.0e11).contains(&value)).then(|| value.round() as u64)
}

pub fn bytes_to_mb(bytes: u64) -> u64 {
    bytes / (1024 * 1024)
}

pub fn bytes_to_gb(bytes: u64) -> Option<f64> {
    (bytes > 0).then(|| round_to(bytes as f64 / (1024.0 * 1024.0 * 1024.0), 1))
}

/// Trimmed, non-empty, at most `MAX_TEXT` characters; vendor placeholders are dropped.
pub fn text(raw: &str) -> Option<String> {
    let value = raw.trim().trim_matches('\0').trim();
    if value.is_empty() || is_placeholder(value) {
        return None;
    }
    Some(value.chars().take(MAX_TEXT).collect())
}

/// SMBIOS strings that firmware leaves unfilled.
fn is_placeholder(value: &str) -> bool {
    const PLACEHOLDERS: [&str; 8] = [
        "to be filled by o.e.m.",
        "default string",
        "system serial number",
        "not specified",
        "not applicable",
        "unknown",
        "none",
        "n/a",
    ];
    let lower = value.to_ascii_lowercase();
    PLACEHOLDERS.contains(&lower.as_str())
}

/// "2024-01-31" (or a longer ISO time starting with it) -> "2024-01-31"; anything else -> None.
pub fn iso_date(raw: &str) -> Option<String> {
    let value = raw.trim();
    let date = value.get(..10)?;
    let bytes = date.as_bytes();
    let digits = |r: std::ops::Range<usize>| bytes[r].iter().all(u8::is_ascii_digit);
    if !(digits(0..4) && bytes[4] == b'-' && digits(5..7) && bytes[7] == b'-' && digits(8..10)) {
        return None;
    }
    let year: u32 = date[..4].parse().ok()?;
    let month: u32 = date[5..7].parse().ok()?;
    let day: u32 = date[8..10].parse().ok()?;
    ((1990..=2100).contains(&year) && (1..=12).contains(&month) && (1..=31).contains(&day))
        .then(|| date.to_owned())
}

/// A list of texts, cleaned, without duplicates, at most `MAX_ITEMS`; empty -> None.
pub fn text_list<'a>(items: impl IntoIterator<Item = &'a str>) -> Option<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for item in items {
        if let Some(t) = text(item) {
            if !out.contains(&t) {
                out.push(t);
            }
        }
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    (!out.is_empty()).then_some(out)
}

/// `Some(list)` only when it has an entry.
pub fn non_empty<T>(list: Vec<T>) -> Option<Vec<T>> {
    (!list.is_empty()).then_some(list)
}

// ---------------------------------------------------------------------------------------------
// Live helpers
// ---------------------------------------------------------------------------------------------

/// `(name, cpu % of one core)` per process -> the busiest names, summed per name and scaled to
/// the whole CPU. Idle pseudo-processes and values under 0.1 % are left out.
pub fn top_processes<'a>(
    processes: impl IntoIterator<Item = (&'a str, f32)>,
    cpu_count: usize,
) -> Option<Vec<TopProcess>> {
    if cpu_count == 0 {
        return None;
    }
    let mut by_name: HashMap<String, f64> = HashMap::new();
    for (name, usage) in processes {
        let usage = usage as f64;
        let lower = name.to_ascii_lowercase();
        if !usage.is_finite() || usage <= 0.0 || lower == "system idle process" || lower == "idle"
        {
            continue;
        }
        let Some(name) = text(name) else { continue };
        *by_name.entry(name).or_default() += usage / cpu_count as f64;
    }
    let mut list: Vec<(String, f64)> = by_name.into_iter().collect();
    list.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    non_empty(
        list.into_iter()
            .filter_map(|(name, share)| {
                let cpu_pct = pct(share)?;
                (cpu_pct >= 0.1).then_some(TopProcess { name, cpu_pct })
            })
            .take(MAX_TOP_PROCESSES)
            .collect(),
    )
}

/// Byte counters since the previous reading -> bytes per second. `None` without a previous
/// reading, a counter that went back (restart / wrap) or a too short interval.
pub fn rate(previous: Option<u64>, now: u64, elapsed: Duration) -> Option<u64> {
    let secs = elapsed.as_secs_f64();
    if secs < 0.5 {
        return None;
    }
    let delta = now.checked_sub(previous?)?;
    bps(delta as f64 / secs)
}

/// Keeps the cumulative counters of the previous reading for `rate`.
#[derive(Debug, Default)]
pub struct CounterHistory {
    last: Option<(Instant, HashMap<String, (u64, u64)>)>,
}

impl CounterHistory {
    pub const fn new() -> Self {
        Self { last: None }
    }

    /// `(id, total_a, total_b)` now -> `(id, rate_a, rate_b)` for ids seen last time too.
    pub fn rates(
        &mut self,
        now: Instant,
        totals: Vec<(String, u64, u64)>,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        let previous = self.last.take();
        let out = totals
            .iter()
            .map(|(id, a, b)| match &previous {
                Some((at, map)) => {
                    let elapsed = now.saturating_duration_since(*at);
                    let prev = map.get(id);
                    (
                        id.clone(),
                        rate(prev.map(|p| p.0), *a, elapsed),
                        rate(prev.map(|p| p.1), *b, elapsed),
                    )
                }
                None => (id.clone(), None, None),
            })
            .collect();
        self.last = Some((
            now,
            totals.into_iter().map(|(id, a, b)| (id, (a, b))).collect(),
        ));
        out
    }
}

/// Windows `\GPU Engine(*)\Utilization Percentage` items -> utilisation per adapter LUID, the
/// way Task Manager shows it: summed per engine type, the busiest engine type.
pub fn gpu_util_by_luid<'a>(items: impl IntoIterator<Item = (&'a str, f64)>) -> HashMap<u64, f64> {
    let mut per_engine: HashMap<(u64, String), f64> = HashMap::new();
    for (instance, value) in items {
        if !value.is_finite() || value < 0.0 {
            continue;
        }
        let Some(luid) = parse_luid(instance) else { continue };
        let engine = instance
            .split("engtype_")
            .nth(1)
            .unwrap_or("")
            .to_ascii_lowercase();
        *per_engine.entry((luid, engine)).or_default() += value;
    }
    let mut out: HashMap<u64, f64> = HashMap::new();
    for ((luid, _), value) in per_engine {
        let entry = out.entry(luid).or_insert(0.0);
        *entry = entry.max(value);
    }
    out
}

/// "pid_1_luid_0x00000000_0x0000C3A5_phys_0_eng_0_engtype_3D" / "luid_0x00000000_0x0000C3A5_phys_0"
/// -> LUID as `(high << 32) | low`.
pub fn parse_luid(instance: &str) -> Option<u64> {
    let rest = instance.split("luid_").nth(1)?;
    let mut parts = rest.split('_');
    let high = parse_hex(parts.next()?)?;
    let low = parse_hex(parts.next()?)?;
    Some(((high as u64) << 32) | low as u64)
}

fn parse_hex(raw: &str) -> Option<u32> {
    let digits = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X"))?;
    u32::from_str_radix(digits, 16).ok()
}

/// Windows `\PhysicalDisk(*)` instance "0 C: D:" -> disk number "0"; "_Total" -> None.
pub fn physical_disk_id(instance: &str) -> Option<String> {
    let first = instance.split_whitespace().next()?;
    first.parse::<u32>().ok().map(|n| n.to_string())
}

/// Fills `gpu_pct` / `gpu_temp_c` of the summary bar from the per-card values: the busiest /
/// hottest card.
pub fn gpu_summary(gpus: &[GpuLive]) -> (Option<f64>, Option<f64>) {
    let max = |values: Vec<f64>| values.into_iter().reduce(f64::max);
    (
        max(gpus.iter().filter_map(|g| g.util_pct).collect()),
        max(gpus.iter().filter_map(|g| g.temp_c).collect()),
    )
}

// ---------------------------------------------------------------------------------------------
// Panel capability and inventory change detection
// ---------------------------------------------------------------------------------------------

/// The heartbeat answer's `sense_panel_caps` -> whether the panel takes the v2 fields. A
/// missing key means an older panel (strict schema): off.
pub fn panel_takes_v2(caps: Option<&[String]>) -> bool {
    caps.is_some_and(|caps| caps.iter().any(|c| c == CAP_HEALTH_V2))
}

/// Should sysinfo be uploaded again because of the inventory?
/// - v2 on and a read inventory differs from the one in the last sysinfo (or none was sent);
/// - v2 off but the last sysinfo carried one (the panel no longer takes it).
pub fn inventory_resend_needed(v2: bool, latest: Option<&str>, sent: Option<&str>) -> bool {
    if v2 {
        latest.is_some() && latest != sent
    } else {
        sent.is_some()
    }
}

/// A new background reading is due: never started, or the last one started at least
/// `INVENTORY_INTERVAL` ago (`INVENTORY_RETRY` when it failed, #117), and none is running.
pub fn inventory_refresh_due(
    last_started: Option<Instant>,
    running: bool,
    last_failed: bool,
    now: Instant,
) -> bool {
    let wait = if last_failed { INVENTORY_RETRY } else { INVENTORY_INTERVAL };
    !running && last_started.map_or(true, |t| now.saturating_duration_since(t) >= wait)
}

/// Sense Remote (Sürüm 10, #117): a new reading where a part that a computer always has (CPU,
/// graphics cards, memory, disks, board, BIOS, OS, driver list) came back empty keeps that part
/// of the previous reading. Such a part only goes missing when its query failed or timed out
/// (WMI busy); sending the gap would replace the panel's whole inventory with an almost empty
/// one and every detail of the "Bilgisayar durumu" popup would read "okunamadı". Parts that can
/// really disappear (network adapters, USB, audio, power settings, serial) are taken as read.
pub fn keep_known_parts(previous: Option<&Inventory>, mut read: Inventory) -> Inventory {
    let Some(prev) = previous else { return read };
    macro_rules! keep {
        ($($field:ident),*) => {
            $(if read.$field.is_none() {
                read.$field = prev.$field.clone();
            })*
        };
    }
    keep!(cpu, gpus, memory, physical_disks, board, bios, os, drivers);
    read
}

/// Sense Remote (Sürüm 10, #117): one card per graphics adapter. DXGI can list one card twice
/// (a second adapter object with the same name and its own LUID, e.g. after a driver reset);
/// only one of them has utilisation / memory counters. An entry without any live value whose
/// name another entry with live values carries is dropped, so the popup shows the card once.
/// Two real cards of the same model both have counters and both stay.
pub fn dedupe_gpus(gpus: Vec<GpuLive>) -> Vec<GpuLive> {
    let has_live = |g: &GpuLive| {
        g.util_pct.is_some()
            || g.vram_used_mb.is_some()
            || g.temp_c.is_some()
            || g.fan_pct.is_some()
            || g.power_w.is_some()
    };
    let key = |g: &GpuLive| g.name.as_deref().map(|n| n.trim().to_ascii_lowercase());
    let live_names: Vec<Option<String>> =
        gpus.iter().filter(|g| has_live(g)).map(key).collect();
    let mut out: Vec<GpuLive> = Vec::new();
    for gpu in gpus {
        if !has_live(&gpu) {
            let k = key(&gpu);
            if k.is_some() && (live_names.contains(&k) || out.iter().any(|o| key(o) == k)) {
                continue;
            }
        }
        out.push(gpu);
    }
    out
}

/// Summary of an inventory for change detection: the JSON without `at`, keys sorted.
pub fn inventory_summary(inventory: &Inventory) -> String {
    let mut value = serde_json::to_value(Inventory {
        at: 0,
        ..inventory.clone()
    })
    .unwrap_or(serde_json::Value::Null);
    sort_keys(&mut value);
    value.to_string()
}

fn sort_keys(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            let sorted: BTreeMap<String, serde_json::Value> = std::mem::take(map)
                .into_iter()
                .map(|(k, mut v)| {
                    sort_keys(&mut v);
                    (k, v)
                })
                .collect();
            *map = sorted.into_iter().collect();
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(sort_keys),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn out_of_range_values_are_dropped() {
        assert_eq!(pct(42.04), Some(42.0));
        assert_eq!(pct(100.6), Some(100.0));
        assert_eq!(pct(150.0), None);
        assert_eq!(pct(-1.0), None);
        assert_eq!(pct(f64::NAN), None);
        assert_eq!(temp_c(45.56), Some(45.6));
        assert_eq!(temp_c(0.0), None, "0 °C is a sensor that does not report");
        assert_eq!(temp_c(200.0), None);
        assert_eq!(temp_c(-40.0), None);
        assert_eq!(power_w(0.0), None);
        assert_eq!(power_w(3000.0), None);
        assert_eq!(power_w(125.37), Some(125.4));
        assert_eq!(mhz(3600.4), Some(3600));
        assert_eq!(mhz(0.0), None);
        assert_eq!(mhz(50_000.0), None);
        assert_eq!(bps(-1.0), None);
        assert_eq!(bps(2.0e11), None);
        assert_eq!(bytes_to_gb(0), None);
        assert_eq!(bytes_to_gb(512 * 1024 * 1024 * 1024), Some(512.0));
    }

    #[test]
    fn texts_and_dates() {
        assert_eq!(text("  Samsung SSD 980  \0"), Some("Samsung SSD 980".into()));
        assert_eq!(text("To Be Filled By O.E.M."), None);
        assert_eq!(text("Default string"), None);
        assert_eq!(text(""), None);
        assert_eq!(text(&"x".repeat(500)).unwrap().chars().count(), MAX_TEXT);
        assert_eq!(iso_date("2024-01-31"), Some("2024-01-31".into()));
        assert_eq!(iso_date("2023-05-01T00:00:00Z"), Some("2023-05-01".into()));
        assert_eq!(iso_date("1601-01-01"), None);
        assert_eq!(iso_date("31.01.2024"), None);
        assert_eq!(iso_date("2024-13-01"), None);
        assert_eq!(iso_date("2024"), None);
        assert_eq!(
            text_list(["Realtek Audio", "", "Realtek Audio", "USB Audio"]),
            Some(vec!["Realtek Audio".into(), "USB Audio".into()])
        );
        assert_eq!(text_list([" "]), None);
    }

    #[test]
    fn top_processes_group_scale_and_cut() {
        let list = top_processes(
            [
                ("chrome.exe", 40.0),
                ("chrome.exe", 40.0),
                ("System Idle Process", 700.0),
                ("obs64.exe", 60.0),
                ("a", 0.1),
                ("b", 8.0),
                ("c", 7.0),
                ("d", 6.0),
                ("e", 5.0),
                ("nan", f32::NAN),
            ],
            8,
        )
        .unwrap();
        assert_eq!(list.len(), MAX_TOP_PROCESSES);
        assert_eq!(list[0], TopProcess { name: "chrome.exe".into(), cpu_pct: 10.0 });
        assert_eq!(list[1], TopProcess { name: "obs64.exe".into(), cpu_pct: 7.5 });
        assert!(list.iter().all(|p| p.name != "System Idle Process" && p.name != "a"));
        assert_eq!(top_processes([("x", 0.0)], 4), None);
        assert_eq!(top_processes([("x", 50.0)], 0), None);
    }

    #[test]
    fn rates_need_a_previous_reading_and_a_growing_counter() {
        let t0 = Instant::now();
        let mut history = CounterHistory::default();
        let first = history.rates(t0, vec![("0".into(), 1000, 5000)]);
        assert_eq!(first, vec![("0".into(), None, None)]);
        let second = history.rates(
            t0 + Duration::from_secs(10),
            vec![("0".into(), 11_000, 4000), ("1".into(), 7, 7)],
        );
        assert_eq!(
            second,
            vec![("0".into(), Some(1000), None), ("1".into(), None, None)]
        );
        assert_eq!(rate(Some(10), 20, Duration::from_millis(100)), None);
    }

    #[test]
    fn gpu_engine_counters_are_grouped_like_task_manager() {
        let a = "pid_100_luid_0x00000000_0x0000C3A5_phys_0_eng_0_engtype_3D";
        let b = "pid_200_luid_0x00000000_0x0000C3A5_phys_0_eng_0_engtype_3D";
        let c = "pid_200_luid_0x00000000_0x0000C3A5_phys_0_eng_3_engtype_VideoDecode";
        let d = "pid_300_luid_0x00000001_0x00000010_phys_0_eng_0_engtype_3D";
        let util = gpu_util_by_luid([(a, 20.0), (b, 15.0), (c, 50.0), (d, 3.0), ("junk", 9.0)]);
        assert_eq!(util.get(&0xC3A5), Some(&50.0));
        assert_eq!(util.get(&((1u64 << 32) | 0x10)), Some(&3.0));
        assert_eq!(util.len(), 2);
        assert_eq!(parse_luid("luid_0x00000000_0x0000D1F2_phys_0"), Some(0xD1F2));
        assert_eq!(parse_luid("luid_zz_0x1"), None);
        assert_eq!(physical_disk_id("0 C: D:"), Some("0".into()));
        assert_eq!(physical_disk_id("_Total"), None);
    }

    #[test]
    fn written_data_rules() {
        assert_eq!(written_gb(1_500_000_000_000), Some(1500.0));
        assert_eq!(written_gb(123_456_789_012), Some(123.5));
        assert_eq!(written_gb(u128::MAX), None);
        let mut page = vec![0u8; 512];
        assert_eq!(nvme_written_bytes(&page), None);
        page[48] = 0x10;
        page[49] = 0x27; // 10000 units
        assert_eq!(nvme_written_bytes(&page), Some(5_120_000_000));
        assert_eq!(nvme_written_bytes(&page[..60]), None);
        page[63] = 0xFF; // overflowing counter
        assert_eq!(nvme_written_bytes(&page), None);
    }

    #[test]
    fn written_fields_are_optional_in_the_contract() {
        let old = serde_json::json!({ "id": "0", "write_bps": 5 });
        let disk: DiskLive = serde_json::from_value(old).unwrap();
        assert_eq!(disk.written_gb, None);
        let new = DiskLive { id: "0".into(), written_gb: Some(12.5), ..Default::default() };
        assert_eq!(
            serde_json::to_value(new).unwrap(),
            serde_json::json!({ "id": "0", "written_gb": 12.5 })
        );
    }

    #[test]
    fn gpu_summary_takes_the_busiest_and_hottest_card() {
        let gpus = vec![
            GpuLive { util_pct: Some(10.0), temp_c: Some(70.0), ..Default::default() },
            GpuLive { util_pct: Some(40.0), ..Default::default() },
        ];
        assert_eq!(gpu_summary(&gpus), (Some(40.0), Some(70.0)));
        assert_eq!(gpu_summary(&[]), (None, None));
    }

    #[test]
    fn health_interval_is_short_only_while_connected_with_v2() {
        let idle = Duration::from_secs(60);
        assert_eq!(health_interval(true, true, idle), Duration::from_secs(8));
        assert_eq!(health_interval(true, false, idle), idle);
        assert_eq!(health_interval(false, true, idle), idle, "v1 panel: at most once a minute");
        assert_eq!(health_interval(false, false, idle), idle);
    }

    #[test]
    fn panel_capability() {
        assert!(!panel_takes_v2(None));
        assert!(!panel_takes_v2(Some(&["other".to_owned()][..])));
        assert!(panel_takes_v2(Some(&["x".to_owned(), "health_v2".to_owned()][..])));
    }

    #[test]
    fn inventory_change_detection() {
        // v2 on: send when read and different from what was sent.
        assert!(inventory_resend_needed(true, Some("a"), None));
        assert!(inventory_resend_needed(true, Some("b"), Some("a")));
        assert!(!inventory_resend_needed(true, Some("a"), Some("a")));
        assert!(!inventory_resend_needed(true, None, None));
        // v2 off: only to take a sent inventory back out.
        assert!(inventory_resend_needed(false, Some("a"), Some("a")));
        assert!(!inventory_resend_needed(false, Some("a"), None));

        let base = Inventory {
            at: 1,
            serial: Some("X1".into()),
            ..Default::default()
        };
        let later = Inventory { at: 999, ..base.clone() };
        assert_eq!(inventory_summary(&base), inventory_summary(&later), "`at` is not a change");
        let changed = Inventory {
            power_plan: Some("Balanced".into()),
            ..base.clone()
        };
        assert_ne!(inventory_summary(&base), inventory_summary(&changed));
    }

    #[test]
    fn inventory_refresh_timing() {
        let now = Instant::now();
        assert!(inventory_refresh_due(None, false, false, now));
        assert!(!inventory_refresh_due(None, true, false, now));
        assert!(!inventory_refresh_due(Some(now), false, false, now + Duration::from_secs(60)));
        assert!(inventory_refresh_due(Some(now), false, false, now + INVENTORY_INTERVAL));
        // #117: a failed reading is tried again after two minutes, not half an hour.
        assert!(!inventory_refresh_due(Some(now), false, true, now + Duration::from_secs(60)));
        assert!(inventory_refresh_due(Some(now), false, true, now + INVENTORY_RETRY));
        assert!(!inventory_refresh_due(Some(now), true, true, now + INVENTORY_RETRY));
    }

    // Sürüm 10 (#117): a part whose query failed keeps the previous value; parts that can really
    // disappear are taken as read.
    #[test]
    fn a_failed_part_keeps_the_previous_reading() {
        let previous = Inventory {
            at: 1,
            cpu: Some(CpuInfo { model: Some("Ryzen 9".into()), ..Default::default() }),
            gpus: Some(vec![GpuInfo {
                name: "NVIDIA GeForce RTX 4090".into(),
                driver_version: Some("32.0.15.9144".into()),
                ..Default::default()
            }]),
            usb: Some(vec!["Logitech USB Receiver".into()]),
            drivers: Some(vec![]),
            ..Default::default()
        };
        let read = Inventory {
            at: 2,
            memory: Some(MemoryInfo { total_mb: Some(65536), ..Default::default() }),
            ..Default::default()
        };
        let merged = keep_known_parts(Some(&previous), read.clone());
        assert_eq!(merged.at, 2);
        assert_eq!(merged.cpu, previous.cpu);
        assert_eq!(merged.gpus, previous.gpus);
        assert_eq!(merged.memory, read.memory);
        assert_eq!(merged.drivers, previous.drivers);
        assert_eq!(merged.usb, None, "USB devices can be unplugged");
        assert_eq!(keep_known_parts(None, read.clone()), read);
    }

    // Sürüm 10 (#117): the RTX 4090 listed twice (one entry with values, one without) is one card.
    #[test]
    fn a_card_listed_twice_is_shown_once() {
        let live = GpuLive {
            name: Some("NVIDIA GeForce RTX 4090".into()),
            util_pct: Some(12.0),
            vram_total_mb: Some(24564),
            temp_c: Some(41.0),
            ..Default::default()
        };
        let ghost = GpuLive {
            name: Some("NVIDIA GeForce RTX 4090 ".into()),
            vram_total_mb: Some(24564),
            ..Default::default()
        };
        let igpu = GpuLive {
            name: Some("AMD Radeon(TM) Graphics".into()),
            vram_total_mb: Some(512),
            ..Default::default()
        };
        assert_eq!(
            dedupe_gpus(vec![ghost.clone(), live.clone(), igpu.clone()]),
            vec![live.clone(), igpu.clone()]
        );
        // A card without counters and no twin stays ("okunamadı" rows are honest there).
        assert_eq!(dedupe_gpus(vec![igpu.clone()]), vec![igpu.clone()]);
        // Two empty entries of one name: once.
        assert_eq!(dedupe_gpus(vec![igpu.clone(), igpu.clone()]), vec![igpu]);
        // Two real cards of the same model both report values: both stay.
        let second = GpuLive { util_pct: Some(80.0), ..live.clone() };
        assert_eq!(dedupe_gpus(vec![live.clone(), second.clone()]), vec![live, second]);
    }

    #[test]
    fn empty_inventory_and_live_parts_send_only_what_was_read() {
        let value = serde_json::to_value(Inventory { at: 5, ..Default::default() }).unwrap();
        assert_eq!(value, serde_json::json!({ "at": 5 }));
        let value = serde_json::to_value(GpuLive::default()).unwrap();
        assert_eq!(value, serde_json::json!({}));
        let disk = serde_json::to_value(DiskLive { id: "0".into(), ..Default::default() }).unwrap();
        assert_eq!(disk, serde_json::json!({ "id": "0" }));
    }
}
