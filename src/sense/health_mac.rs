//! Sense Remote (S6): macOS live values for the heartbeat `health` (with `health_v2`).
//!
//! - Graphics: `ioreg` IOAccelerator `PerformanceStatistics` (utilisation, memory in use). The
//!   GPU temperature, fan and power have no public interface and are not sent.
//! - Disks: cumulative bytes of `IOBlockStorageDriver` `Statistics`, turned into bytes per second
//!   between two heartbeats (`CounterHistory`).
//! - CPU current clock: not published on Apple Silicon (not sent).
//!
//! `ioreg` is fast (tens of ms) and runs with a time limit. Values are checked on a device
//! (plan §8): the property names come from the IOKit registry, not from a documented API.

use super::{health_cmd, health_model::*, health_parse};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

const TOOL_TIMEOUT: Duration = Duration::from_secs(5);

static DISK_COUNTERS: Mutex<CounterHistory> = Mutex::new(CounterHistory::new());

fn ioreg(args: &[&str]) -> Option<String> {
    health_cmd::run("/usr/sbin/ioreg", args, TOOL_TIMEOUT)
}

/// macOS part of the v2 live values. The single integrated GPU takes the inventory's name when
/// the registry entry has none.
pub fn extend(health: &mut super::report::SenseHealth, inventory_gpu: Option<String>) {
    let mut gpus = ioreg(&["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        .map(|out| health_parse::mac_gpu_stats(&out))
        .unwrap_or_default();
    if gpus.len() == 1 && gpus[0].name.is_none() {
        gpus[0].name = inventory_gpu;
    }
    gpus.truncate(MAX_ITEMS);
    let (gpu_pct, gpu_temp) = gpu_summary(&gpus);
    health.gpu_pct = gpu_pct;
    health.gpu_temp_c = gpu_temp;
    health.gpus = non_empty(gpus);

    if let Some(out) = ioreg(&["-r", "-w", "0", "-l", "-d", "2", "-c", "IOBlockStorageDriver"]) {
        let totals = health_parse::mac_disk_counters(&out);
        // Sense Remote (Sürüm 9, O8): the driver's write counter restarts at every boot, so it is
        // sent as `written_boot_gb`, never as the lifetime total (only with `disk_written`).
        let with_written = super::report_sig::panel_has(CAP_DISK_WRITTEN);
        let written: std::collections::HashMap<String, u64> = totals
            .iter()
            .map(|(id, _, write)| (id.clone(), *write))
            .collect();
        let rates = DISK_COUNTERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .rates(Instant::now(), totals);
        health.physical_disks = non_empty(
            rates
                .into_iter()
                .map(|(id, read_bps, write_bps)| {
                    let written_boot_gb = written
                        .get(&id)
                        .filter(|_| with_written)
                        .and_then(|b| written_gb(*b as u128));
                    DiskLive {
                        id,
                        read_bps,
                        write_bps,
                        written_boot_gb,
                        ..Default::default()
                    }
                })
                .filter(|d| {
                    d.read_bps.is_some() || d.write_bps.is_some() || d.written_boot_gb.is_some()
                })
                .take(MAX_ITEMS)
                .collect(),
        );
    }
}
