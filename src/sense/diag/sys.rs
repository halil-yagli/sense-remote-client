//! Sense Remote (#103): the computer in the event record (`--server`). `sys/info` at start and at
//! the start of every connection record: operating system, processor, graphics cards, memory,
//! displays (size, position, scale, refresh, native size). `sys/load` once a minute: processor
//! load and memory in use. No host name, user name or serial number.

use crate::sense::health_model::Inventory;
use hbb_common::sysinfo::{System, MINIMUM_CPU_UPDATE_INTERVAL};
use serde_json::{json, Value};
use std::sync::Mutex;

/// Hardware read once per run from the inventory (blocking, seconds; Windows / macOS only).
static HARDWARE: Mutex<Option<Value>> = Mutex::new(None);

/// The hardware part of `sys/info` from an inventory (pure).
pub fn hardware_fields(inventory: &Inventory) -> Value {
    let gpus: Vec<Value> = inventory
        .gpus
        .as_deref()
        .unwrap_or_default()
        .iter()
        .map(|g| {
            json!({
                "ad": g.name,
                "surucu": g.driver_version,
                "vram_mb": g.vram_mb,
                "tumlesik": g.integrated,
            })
        })
        .collect();
    let os = inventory.os.as_ref();
    json!({
        "gpu": gpus,
        "cpu": inventory.cpu.as_ref().and_then(|c| c.model.clone()),
        "cekirdek": inventory.cpu.as_ref().and_then(|c| c.cores),
        "is_parcacigi": inventory.cpu.as_ref().and_then(|c| c.threads),
        "bellek_mb": inventory.memory.as_ref().and_then(|m| m.total_mb),
        "os_ad": os.and_then(|o| o.name.clone()),
        "os_surum": os.and_then(|o| o.version.clone()),
        "os_derleme": os.and_then(|o| o.build.clone()),
    })
}

#[cfg(windows)]
fn read_inventory() -> Option<Inventory> {
    crate::sense::inventory_win::collect()
}

#[cfg(target_os = "macos")]
fn read_inventory() -> Option<Inventory> {
    crate::sense::inventory_mac::collect()
}

#[cfg(not(any(windows, target_os = "macos")))]
fn read_inventory() -> Option<Inventory> {
    None
}

/// Reads the hardware once (blocking; the ticker thread) and records `sys/info` with it.
pub fn read_hardware_once() {
    let known = HARDWARE.lock().unwrap_or_else(|e| e.into_inner()).is_some();
    if known {
        return;
    }
    let value = read_inventory().map(|inv| hardware_fields(&inv)).unwrap_or(Value::Null);
    *HARDWARE.lock().unwrap_or_else(|e| e.into_inner()) = Some(value);
    emit_info();
}

fn os_text(system: &System) -> String {
    #[allow(unused_mut)]
    let mut os = format!(
        "{} / {}",
        system.distribution_id(),
        system.long_os_version().unwrap_or_default()
    );
    #[cfg(windows)]
    {
        os = format!("{os} - {}", system.os_version().unwrap_or_default());
    }
    os
}

/// `sys/info` now (displays read now; hardware as read before, if yet).
pub fn emit_info() {
    let mut system = System::new();
    system.refresh_memory();
    let mut fields = json!({
        "os": os_text(&system),
        "bellek_toplam_mb": system.total_memory() / (1024 * 1024),
        "monitorler": crate::sense::report::displays().0,
        "surum": crate::sense::update::current_version(),
        "platform": crate::sense::log_upload::platform_name(),
        "rol": crate::sense::installed_role().map(|r| r.as_str()),
    });
    if let (Some(map), Some(Value::Object(hw))) = (
        fields.as_object_mut(),
        HARDWARE.lock().unwrap_or_else(|e| e.into_inner()).clone(),
    ) {
        for (k, v) in hw {
            map.insert(k, v);
        }
    }
    super::event("sys", "info", fields);
}

/// Processor and memory load, sampled once a minute by the ticker.
pub struct Load {
    system: System,
    primed: bool,
}

impl Default for Load {
    fn default() -> Self {
        Self {
            system: System::new(),
            primed: false,
        }
    }
}

impl Load {
    /// `sys/load` fields since the previous sample; `None` the first time (baseline only).
    pub fn sample(&mut self) -> Option<Value> {
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();
        if !self.primed {
            self.primed = true;
            std::thread::sleep(MINIMUM_CPU_UPDATE_INTERVAL);
            self.system.refresh_cpu_usage();
        }
        let cpu = self.system.global_cpu_info().cpu_usage();
        let total = self.system.total_memory();
        let used = self.system.used_memory().min(total);
        Some(load_fields(cpu, used, total))
    }
}

/// `sys/load` fields (pure): CPU % with one decimal, memory in MB.
pub fn load_fields(cpu_pct: f32, used_bytes: u64, total_bytes: u64) -> Value {
    let cpu = if cpu_pct.is_finite() {
        Some(((cpu_pct.clamp(0.0, 100.0) as f64) * 10.0).round() / 10.0)
    } else {
        None
    };
    json!({
        "cpu_yuzde": cpu,
        "bellek_mb": used_bytes / (1024 * 1024),
        "bellek_toplam_mb": total_bytes / (1024 * 1024),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::health_model::{CpuInfo, GpuInfo, MemoryInfo, OsInfo};

    #[test]
    fn hardware_fields_carry_no_host_name() {
        let inventory = Inventory {
            cpu: Some(CpuInfo {
                model: Some("AMD Ryzen 7".to_owned()),
                cores: Some(8),
                threads: Some(16),
                ..Default::default()
            }),
            gpus: Some(vec![GpuInfo {
                name: "AMD Radeon".to_owned(),
                integrated: Some(false),
                vram_mb: Some(8192),
                driver_version: Some("31.0".to_owned()),
                driver_date: None,
            }]),
            memory: Some(MemoryInfo {
                total_mb: Some(32768),
                ..Default::default()
            }),
            os: Some(OsInfo {
                name: Some("Windows 11 Pro".to_owned()),
                version: Some("24H2".to_owned()),
                hostname: Some("SENSE-SLAYER".to_owned()),
                ..Default::default()
            }),
            serial: Some("ABC123".to_owned()),
            ..Default::default()
        };
        let v = hardware_fields(&inventory);
        assert_eq!(v["gpu"][0]["ad"], "AMD Radeon");
        assert_eq!(v["gpu"][0]["vram_mb"], 8192);
        assert_eq!(v["cpu"], "AMD Ryzen 7");
        assert_eq!(v["bellek_mb"], 32768);
        assert_eq!(v["os_ad"], "Windows 11 Pro");
        let text = v.to_string();
        assert!(!text.contains("SENSE-SLAYER") && !text.contains("ABC123"), "{text}");
    }

    #[test]
    fn load_fields_round_and_clamp() {
        let v = load_fields(12.345, 3 * 1024 * 1024 * 1024, 16 * 1024 * 1024 * 1024);
        assert_eq!(v["cpu_yuzde"], 12.3);
        assert_eq!(v["bellek_mb"], 3072);
        assert_eq!(v["bellek_toplam_mb"], 16384);
        assert_eq!(load_fields(250.0, 0, 0)["cpu_yuzde"], 100.0);
        assert!(load_fields(f32::NAN, 0, 0)["cpu_yuzde"].is_null());
    }
}
