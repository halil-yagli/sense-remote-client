//! Sense Remote (S6): the macOS inventory from `system_profiler -json` (one run for all data
//! types), `pmset -g` (start after power loss) and the `/etc/localtime` link (time zone).
//! `health_parse::mac_inventory` maps them.
//!
//! The CPU part (model, cores, threads) comes from `sysinfo` like the rest of the health data;
//! Apple Silicon has no published base clock, so `base_mhz` is not sent. Not read on macOS:
//! memory slots (soldered unified memory), graphics driver version (part of macOS), disk wear /
//! temperature (no public interface), power plan, drivers. Sense Remote (Sürüm 11, #119): the
//! last macOS update (install history) and each adapter's link / speed (`ifconfig`, Wi-Fi link
//! rate) are read too.
//!
//! `system_profiler` takes a few seconds; it runs only in the background inventory thread, with
//! a time limit.

use super::{health_cmd, health_model::*, health_parse};
use hbb_common::{log, sysinfo::System};
use std::time::Duration;

const PROFILER_TIMEOUT: Duration = Duration::from_secs(45);
const TOOL_TIMEOUT: Duration = Duration::from_secs(5);

/// `SPUSBDataType` was renamed `SPUSBHostDataType` in macOS 15; unknown types are skipped by the
/// tool, so both are asked for.
const DATA_TYPES: [&str; 10] = [
    "SPHardwareDataType",
    "SPSoftwareDataType",
    "SPMemoryDataType",
    "SPDisplaysDataType",
    "SPNVMeDataType",
    "SPSerialATADataType",
    "SPNetworkDataType",
    "SPAudioDataType",
    "SPUSBDataType",
    "SPUSBHostDataType",
];

pub fn collect() -> Option<Inventory> {
    let mut args = vec!["-json"];
    args.extend(DATA_TYPES);
    let profiler = health_cmd::run("/usr/sbin/system_profiler", &args, PROFILER_TIMEOUT)
        .and_then(|out| match serde_json::from_str::<serde_json::Value>(&out) {
            Ok(value) => Some(value),
            Err(err) => {
                log::warn!("Sense Remote: system_profiler output not JSON: {err}");
                None
            }
        });
    let pmset = health_cmd::run("/usr/bin/pmset", &["-g"], TOOL_TIMEOUT);
    let timezone = std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|link| health_parse::zoneinfo_name(&link.to_string_lossy()));
    let mut inventory = health_parse::mac_inventory(
        profiler.as_ref().unwrap_or(&serde_json::Value::Null),
        pmset.as_deref(),
        timezone,
    );
    inventory.cpu = cpu();
    if inventory == Inventory::default() {
        return None;
    }
    // Sürüm 11 (#119): last update, adapter link / speed. Their own run with its own limit, so a
    // slow install history never costs the rest of the inventory.
    let extra = health_cmd::run("/usr/sbin/system_profiler", &EXTRA_ARGS, EXTRA_TIMEOUT)
        .and_then(|out| serde_json::from_str::<serde_json::Value>(&out).ok())
        .unwrap_or(serde_json::Value::Null);
    let links: Vec<health_parse::MacLink> = inventory
        .network
        .iter()
        .flatten()
        .filter_map(|adapter| adapter.device.clone())
        .filter(|device| is_bsd_name(device))
        .filter_map(|device| {
            let out = health_cmd::run("/sbin/ifconfig", &[device.as_str()], TOOL_TIMEOUT)?;
            let (up, speed) = health_parse::mac_ifconfig(&out);
            Some((device, up, speed))
        })
        .collect();
    health_parse::mac_inventory_extras(&mut inventory, &extra, &links);
    Some(inventory)
}

const EXTRA_ARGS: [&str; 3] = ["-json", "SPAirPortDataType", "SPInstallHistoryDataType"];
const EXTRA_TIMEOUT: Duration = Duration::from_secs(30);

/// "en0", "en12": only such names go to `ifconfig` as an argument.
fn is_bsd_name(name: &str) -> bool {
    name.len() <= 16
        && name.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && name.chars().all(|c| c.is_ascii_alphanumeric())
}

fn cpu() -> Option<CpuInfo> {
    let mut system = System::new();
    system.refresh_cpu();
    let model = system.cpus().first().and_then(|c| text(c.brand()));
    let threads = u32::try_from(system.cpus().len()).ok().filter(|n| *n > 0);
    let cores = system
        .physical_core_count()
        .and_then(|n| u32::try_from(n).ok())
        .filter(|n| *n > 0);
    let info = CpuInfo {
        model,
        cores,
        threads,
        base_mhz: None,
    };
    (info != CpuInfo::default()).then_some(info)
}
