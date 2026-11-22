//! Sense Remote (S6): the macOS inventory from `system_profiler -json` (one run for all data
//! types), `pmset -g` (start after power loss) and the `/etc/localtime` link (time zone).
//! `health_parse::mac_inventory` maps them.
//!
//! The CPU part (model, cores, threads) comes from `sysinfo` like the rest of the health data;
//! Apple Silicon has no published base clock, so `base_mhz` is not sent. Not read on macOS:
//! memory slots (soldered unified memory), graphics driver version (part of macOS), disk wear /
//! temperature (no public interface), Wi-Fi name / signal (location permission), last update,
//! power plan, drivers.
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
    (inventory != Inventory::default()).then_some(inventory)
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
