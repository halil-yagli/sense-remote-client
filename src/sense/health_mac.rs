//! Sense Remote (S6): macOS live values for the heartbeat `health` (with `health_v2`).
//!
//! - Graphics: `ioreg` IOAccelerator `PerformanceStatistics` (utilisation, memory in use). The
//!   GPU temperature, fan and power have no public interface and are not sent. Sense Remote
//!   (Sürüm 11, #119): an integrated GPU (Apple Silicon) shares the computer's memory, so its
//!   memory total is the installed memory (shown as "Paylaşılan bellek").
//! - Disks: cumulative bytes of `IOBlockStorageDriver` `Statistics`, turned into bytes per second
//!   between two heartbeats (`CounterHistory`).
//! - Memory available: `vm_stat` (Sürüm 11: sysinfo gave 0 on the test Macs, the field never came).
//! - Wi-Fi band / signal (Sürüm 11): `system_profiler SPAirPortDataType -json` in the background
//!   at most every `WIFI_INTERVAL` (it takes about a second); the last reading is kept for
//!   `WIFI_MAX_AGE`. The network name needs the location permission (not asked for).
//! - CPU current clock: not published on Apple Silicon (not sent).
//!
//! `ioreg` / `vm_stat` are fast (tens of ms) and run with a time limit. Values are checked on a
//! device (plan §8): the property names come from the IOKit registry, not from a documented API.

use super::{health_cmd, health_model::*, health_parse};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

const TOOL_TIMEOUT: Duration = Duration::from_secs(5);
const PROFILER_TIMEOUT: Duration = Duration::from_secs(20);
const WIFI_INTERVAL: Duration = Duration::from_secs(2 * 60);
const WIFI_MAX_AGE: Duration = Duration::from_secs(5 * 60);

static DISK_COUNTERS: Mutex<CounterHistory> = Mutex::new(CounterHistory::new());
static MEM_LOGGED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

struct WifiState {
    started: Option<Instant>,
    running: bool,
    kept: Kept<WifiLive>,
}

static WIFI: Mutex<WifiState> = Mutex::new(WifiState {
    started: None,
    running: false,
    kept: Kept::new(),
});

fn ioreg(args: &[&str]) -> Option<String> {
    health_cmd::run("/usr/sbin/ioreg", args, TOOL_TIMEOUT)
}

/// The kept Wi-Fi reading; starts a background reading when one is due.
fn wifi() -> Option<WifiLive> {
    let mut state = WIFI.lock().unwrap_or_else(|e| e.into_inner());
    let due = !state.running && state.started.map_or(true, |t| t.elapsed() >= WIFI_INTERVAL);
    if due {
        state.running = true;
        state.started = Some(Instant::now());
        std::thread::spawn(|| {
            let read = health_cmd::run(
                "/usr/sbin/system_profiler",
                &["-json", "SPAirPortDataType"],
                PROFILER_TIMEOUT,
            )
            .and_then(|out| serde_json::from_str::<serde_json::Value>(&out).ok())
            .and_then(|root| health_parse::mac_wifi(&root));
            let mut state = WIFI.lock().unwrap_or_else(|e| e.into_inner());
            state.running = false;
            state.kept.update(Instant::now(), read, WIFI_MAX_AGE);
        });
    }
    state.kept.get(Instant::now(), WIFI_MAX_AGE)
}

/// macOS part of the v2 live values. The single GPU of the inventory gives its name when the
/// registry entry has none, and whether it is integrated (shared memory).
pub fn extend(health: &mut super::report::SenseHealth, inventory_gpu: Option<(String, bool)>) {
    let mut gpus = ioreg(&["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        .map(|out| health_parse::mac_gpu_stats(&out))
        .unwrap_or_default();
    if let (1, Some((name, integrated))) = (gpus.len(), inventory_gpu) {
        if gpus[0].name.is_none() {
            gpus[0].name = Some(name);
        }
        if integrated && gpus[0].vram_total_mb.is_none() {
            gpus[0].vram_total_mb = health.mem_total_mb.filter(|mb| *mb > 0);
        }
    }
    gpus.truncate(MAX_ITEMS);
    let (gpu_pct, gpu_temp) = gpu_summary(&gpus);
    health.gpu_pct = gpu_pct;
    health.gpu_temp_c = gpu_temp;
    health.gpus = non_empty(gpus);

    let sysinfo_available = health.mem_available_mb;
    let vm_stat = health_cmd::run("/usr/bin/vm_stat", &[], TOOL_TIMEOUT)
        .and_then(|out| health_parse::vm_stat_available_mb(&out));
    if let Some(mb) = vm_stat {
        health.mem_available_mb = Some(match health.mem_total_mb {
            Some(total) if total > 0 => mb.min(total),
            _ => mb,
        });
    }
    // Sürüm 11 (#119): the first reading of the process goes into the log (sysinfo's value next
    // to it), so a missing field can be traced on a device.
    if !MEM_LOGGED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        hbb_common::log::info!(
            "Sense Remote: mem_available_mb={:?} (vm_stat; sysinfo {:?})",
            health.mem_available_mb,
            sysinfo_available
        );
    }
    health.wifi = wifi();

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
