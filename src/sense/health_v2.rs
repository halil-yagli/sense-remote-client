//! Sense Remote (S6): state and wiring of the detailed health data (`health_model`).
//!
//! - `set_panel_caps`: the heartbeat answer's `sense_panel_caps`. Only with `health_v2` in it
//!   does this build add the inventory to sysinfo and the live fields to `health` (the panel's
//!   schema is strict; an older panel gets today's body unchanged).
//! - Inventory: read in a background thread at start and every `INVENTORY_INTERVAL`, with time
//!   limits inside (`inventory_win` / `inventory_mac`). `inventory_changed` tells the sync loop to
//!   upload sysinfo again when the read inventory differs from the one in the last sysinfo
//!   (summary comparison, `health_model::inventory_summary`).
//! - Live values: `extend_health`, called by `report::measure_health` once a minute.

// Sense Remote: platform parts are unused on other targets.
#![allow(dead_code)]

use super::{health_model::*, report::SenseHealth};
use hbb_common::{
    log,
    sysinfo::{Networks, System},
};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Instant,
};

static PANEL_V2: AtomicBool = AtomicBool::new(false);

#[derive(Default)]
struct InventoryState {
    latest: Option<Inventory>,
    latest_summary: Option<String>,
    sent_summary: Option<String>,
    started: Option<Instant>,
    running: bool,
}

static INVENTORY: Mutex<InventoryState> = Mutex::new(InventoryState {
    latest: None,
    latest_summary: None,
    sent_summary: None,
    started: None,
    running: false,
});

/// Whether the panel takes the v2 fields (last heartbeat answer).
pub fn enabled() -> bool {
    PANEL_V2.load(Ordering::Relaxed)
}

/// From every parsed heartbeat answer.
pub fn set_panel_caps(caps: Option<&[String]>) {
    let v2 = panel_takes_v2(caps);
    if PANEL_V2.swap(v2, Ordering::Relaxed) != v2 {
        log::info!("Sense Remote: panel health_v2 {}", if v2 { "on" } else { "off" });
    }
    if v2 {
        start_inventory_if_due();
    }
}

fn start_inventory_if_due() {
    if !SUPPORTED {
        return;
    }
    {
        let mut state = INVENTORY.lock().unwrap_or_else(|e| e.into_inner());
        if !inventory_refresh_due(state.started, state.running, Instant::now()) {
            return;
        }
        state.running = true;
        state.started = Some(Instant::now());
    }
    std::thread::spawn(|| {
        let read = collect_inventory().map(|mut inventory| {
            inventory.at = super::report::unix_now();
            inventory
        });
        let mut state = INVENTORY.lock().unwrap_or_else(|e| e.into_inner());
        state.running = false;
        match read {
            Some(inventory) => {
                let summary = inventory_summary(&inventory);
                if state.latest_summary.as_ref() != Some(&summary) {
                    log::info!("Sense Remote: inventory read (changed)");
                }
                state.latest_summary = Some(summary);
                state.latest = Some(inventory);
            }
            None => log::warn!("Sense Remote: inventory could not be read"),
        }
    });
}

const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));

#[cfg(windows)]
fn collect_inventory() -> Option<Inventory> {
    super::inventory_win::collect()
}

#[cfg(target_os = "macos")]
fn collect_inventory() -> Option<Inventory> {
    super::inventory_mac::collect()
}

#[cfg(not(any(windows, target_os = "macos")))]
fn collect_inventory() -> Option<Inventory> {
    None
}

/// `sysinfo.sense.inventory`: the latest read inventory while v2 is on (`None` otherwise or
/// before the first reading). Records what was put in, for `inventory_changed`.
pub fn inventory_for_sysinfo() -> Option<Inventory> {
    let v2 = enabled();
    if v2 {
        start_inventory_if_due();
    }
    let mut state = INVENTORY.lock().unwrap_or_else(|e| e.into_inner());
    if !v2 || state.latest.is_none() {
        state.sent_summary = None;
        return None;
    }
    state.sent_summary = state.latest_summary.clone();
    state.latest.clone()
}

/// True when sysinfo should be uploaded again for the inventory (see
/// `health_model::inventory_resend_needed`). Starts a due background reading.
pub fn inventory_changed() -> bool {
    let v2 = enabled();
    if v2 {
        start_inventory_if_due();
    }
    let state = INVENTORY.lock().unwrap_or_else(|e| e.into_inner());
    let resend = inventory_resend_needed(
        v2,
        state.latest_summary.as_deref(),
        state.sent_summary.as_deref(),
    );
    if resend {
        log::info!("Sense Remote: inventory differs from the last sysinfo");
    }
    resend
}

fn inventory_snapshot() -> Option<Inventory> {
    INVENTORY
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .latest
        .clone()
}

// ---------------------------------------------------------------------------------------------
// Live values
// ---------------------------------------------------------------------------------------------

static NETWORKS: Mutex<Option<(Networks, Instant)>> = Mutex::new(None);

/// Adds the v2 live fields to `health`. `system` has fresh CPU / memory values (the caller's
/// kept `System`, so process CPU shares are averages since the previous health).
pub fn extend_health(health: &mut SenseHealth, system: &mut System) {
    if total_mb(system.available_memory()) > 0 {
        health.mem_available_mb = Some(total_mb(system.available_memory()));
    }
    if system.total_swap() > 0 {
        health.swap_total_mb = Some(total_mb(system.total_swap()));
        health.swap_used_mb = Some(total_mb(system.used_swap().min(system.total_swap())));
    }
    system.refresh_processes();
    health.top_processes = top_processes(
        system
            .processes()
            .values()
            .map(|p| (p.name(), p.cpu_usage())),
        system.cpus().len(),
    );

    let inventory = inventory_snapshot();
    health.net_io = net_io(inventory.as_ref());
    platform_extend(health, inventory.as_ref());
}

fn total_mb(bytes: u64) -> u64 {
    bytes_to_mb(bytes)
}

#[cfg(windows)]
fn platform_extend(health: &mut SenseHealth, inventory: Option<&Inventory>) {
    let base_mhz = inventory.and_then(|i| i.cpu.as_ref()).and_then(|c| c.base_mhz);
    super::health_win::extend(health, base_mhz);
}

#[cfg(target_os = "macos")]
fn platform_extend(health: &mut SenseHealth, inventory: Option<&Inventory>) {
    let gpu = inventory
        .and_then(|i| i.gpus.as_ref())
        .filter(|g| g.len() == 1)
        .map(|g| g[0].name.clone());
    super::health_mac::extend(health, gpu);
}

#[cfg(not(any(windows, target_os = "macos")))]
fn platform_extend(_health: &mut SenseHealth, _inventory: Option<&Inventory>) {}

/// Traffic per adapter since the previous health. With an inventory only its adapters (by name
/// on Windows, by BSD name on macOS); without one, adapters that do not look virtual.
fn net_io(inventory: Option<&Inventory>) -> Option<Vec<NetLive>> {
    let now = Instant::now();
    let mut guard = NETWORKS.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        // The first reading is only the baseline.
        *guard = Some((Networks::new_with_refreshed_list(), now));
        return None;
    }
    let (networks, last) = guard.as_mut()?;
    networks.refresh_list();
    let elapsed = now.saturating_duration_since(*last);
    *last = now;
    let known: Option<Vec<String>> = inventory.and_then(|i| i.network.as_ref()).map(|list| {
        list.iter()
            .map(|a| a.device.clone().unwrap_or_else(|| a.name.clone()))
            .collect()
    });
    let secs = elapsed.as_secs_f64();
    if secs < 0.5 {
        return None;
    }
    let mut out: Vec<NetLive> = networks
        .list()
        .iter()
        .filter(|(name, _)| match &known {
            Some(known) => known.iter().any(|k| k == *name),
            None => !super::network::looks_virtual(name, "") && !name.starts_with("lo"),
        })
        .filter_map(|(name, data)| {
            Some(NetLive {
                name: text(name)?,
                rx_bps: bps(data.received() as f64 / secs)?,
                tx_bps: bps(data.transmitted() as f64 / secs)?,
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.truncate(MAX_ITEMS);
    non_empty(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Without `health_v2` from the panel nothing new goes out and no reading starts; on a
    /// platform without readers v2 on still sends no inventory.
    #[test]
    fn nothing_new_without_the_panel_capability() {
        set_panel_caps(None);
        assert!(!enabled());
        assert_eq!(inventory_for_sysinfo(), None);
        assert!(!inventory_changed());
        if !SUPPORTED {
            set_panel_caps(Some(&[CAP_HEALTH_V2.to_owned()][..]));
            assert!(enabled());
            assert_eq!(inventory_for_sysinfo(), None);
            assert!(!inventory_changed());
            set_panel_caps(Some(&[][..]));
            assert!(!enabled());
        }
    }

    #[test]
    fn live_extension_fits_the_contract() {
        let mut system = System::new();
        system.refresh_memory();
        let mut health = SenseHealth::default();
        extend_health(&mut health, &mut system);
        let value = serde_json::to_value(&health).unwrap();
        let back: SenseHealth = serde_json::from_value(value).unwrap();
        assert_eq!(back, health);
        for p in health.top_processes.unwrap_or_default() {
            assert!(p.cpu_pct > 0.0 && p.cpu_pct <= 100.0 && !p.name.is_empty());
        }
    }
}
