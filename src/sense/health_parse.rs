//! Sense Remote (S6): pure parsers from the outputs of the system tools to the contract shapes
//! (`health_model`). Tested on every platform with sample outputs; the readers in
//! `inventory_*` / `health_*` only run the tools.
//!
//! Windows: the JSON our own PowerShell scripts print (`inventory_win`), `nvidia-smi` CSV,
//! `netsh wlan show interfaces`, `powercfg /getactivescheme`.
//! macOS: `system_profiler -json`, `pmset -g`, `ioreg` (GPU statistics, block storage
//! statistics), the `/etc/localtime` link.

// Sense Remote: each platform uses its own half; the tests use both.
#![allow(dead_code)]

use super::health_model::*;
use serde_json::Value;

// ---------------------------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------------------------

/// PowerShell's ConvertTo-Json writes one item as an object and several as an array.
fn list(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(other) => vec![other],
    }
}

fn s(value: &Value, key: &str) -> Option<String> {
    match value.get(key)? {
        Value::String(t) => text(t),
        Value::Number(n) => text(&n.to_string()),
        _ => None,
    }
}

fn u(value: &Value, key: &str) -> Option<u64> {
    match value.get(key)? {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64)),
        Value::String(t) => t.trim().parse().ok(),
        _ => None,
    }
}

fn b(value: &Value, key: &str) -> Option<bool> {
    value.get(key)?.as_bool()
}

fn strings(value: Option<&Value>) -> Vec<String> {
    list(value)
        .into_iter()
        .filter_map(|v| v.as_str().and_then(text))
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------------------------

/// SMBIOS memory type (Win32_PhysicalMemory.SMBIOSMemoryType) -> name.
pub fn smbios_memory_type(code: u64) -> Option<&'static str> {
    Some(match code {
        20 => "DDR",
        21 => "DDR2",
        24 => "DDR3",
        26 => "DDR4",
        27 => "LPDDR",
        28 => "LPDDR2",
        29 => "LPDDR3",
        30 => "LPDDR4",
        34 => "DDR5",
        35 => "LPDDR5",
        _ => return None,
    })
}

/// MSFT_PhysicalDisk.BusType -> contract `bus`.
pub fn win_bus(code: u64) -> Option<&'static str> {
    Some(match code {
        17 => "nvme",
        3 | 11 => "sata",
        7 => "usb",
        10 => "sas",
        8 => "raid",
        0 => return None,
        _ => "other",
    })
}

/// MSFT_PhysicalDisk.MediaType -> contract `media`.
pub fn win_media(code: u64) -> Option<&'static str> {
    match code {
        3 => Some("hdd"),
        4 => Some("ssd"),
        _ => None,
    }
}

/// MSFT_PhysicalDisk.HealthStatus -> contract `health`.
pub fn win_health(code: u64) -> Option<&'static str> {
    match code {
        0 => Some("ok"),
        1 => Some("warning"),
        2 => Some("failing"),
        _ => None,
    }
}

/// Sense Remote (Sürüm 11, #119): `Get-PhysicalDisk` in Windows PowerShell 5.1 gives BusType,
/// MediaType and HealthStatus as text ("NVMe", "SSD", "Healthy"); the script reads the raw CIM
/// numbers, and the text is mapped too so an older script (or another PowerShell) still reads.
pub fn win_bus_text(raw: &str) -> Option<&'static str> {
    Some(match raw.trim().to_ascii_lowercase().as_str() {
        "nvme" => "nvme",
        "sata" | "ata" => "sata",
        "usb" => "usb",
        "sas" => "sas",
        "raid" => "raid",
        "" | "unknown" => return None,
        _ => "other",
    })
}

pub fn win_media_text(raw: &str) -> Option<&'static str> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "ssd" => Some("ssd"),
        "hdd" => Some("hdd"),
        _ => None,
    }
}

pub fn win_health_text(raw: &str) -> Option<&'static str> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "healthy" => Some("ok"),
        "warning" => Some("warning"),
        "unhealthy" => Some("failing"),
        _ => None,
    }
}

/// A Storage enum field: the CIM number, or its PowerShell text.
fn win_enum(
    value: &Value,
    key: &str,
    by_code: fn(u64) -> Option<&'static str>,
    by_text: fn(&str) -> Option<&'static str>,
) -> Option<String> {
    let mapped = match value.get(key)? {
        Value::String(t) => match t.trim().parse::<u64>() {
            Ok(code) => by_code(code),
            Err(_) => by_text(t),
        },
        _ => u(value, key).and_then(by_code),
    };
    mapped.map(str::to_owned)
}

/// Integrated or discrete, only where the PCI vendor says it: Intel cards other than Arc are
/// integrated, NVIDIA cards are discrete. Sense Remote (Sürüm 11, #119): AMD's processor graphics
/// ("AMD Radeon(TM) Graphics", "Radeon(TM) 610M" / "780M", "Vega 8") are integrated, Radeon RX /
/// Pro / FirePro cards discrete. Anything else is not stated.
pub fn win_gpu_integrated(name: &str, pnp_id: &str) -> Option<bool> {
    let pnp = pnp_id.to_ascii_uppercase();
    let lower = name.to_ascii_lowercase();
    if pnp.contains("VEN_8086") {
        Some(!lower.contains("arc"))
    } else if pnp.contains("VEN_10DE") {
        Some(false)
    } else if pnp.contains("VEN_1002") {
        amd_integrated(&lower)
    } else {
        None
    }
}

fn amd_integrated(lower: &str) -> Option<bool> {
    let words: Vec<&str> = lower
        .split(|c: char| c.is_whitespace() || c == '(' || c == ')')
        .filter(|w| !w.is_empty())
        .collect();
    if words
        .iter()
        .any(|w| matches!(*w, "rx" | "pro" | "firepro" | "instinct") || (w.starts_with("rx") && w.len() > 2))
    {
        return Some(false);
    }
    // "610m", "680m", "780m", "890m": three digits and "m" is a processor's graphics.
    let apu_number =
        |w: &&str| w.len() == 4 && w.ends_with('m') && w[..3].bytes().all(|b| b.is_ascii_digit());
    (words.contains(&"graphics") || words.contains(&"vega") || words.iter().any(apu_number))
        .then_some(true)
}

/// Inventory from the output of `inventory_win::INVENTORY_SCRIPT`.
pub fn win_inventory(root: &Value) -> Inventory {
    let mut inv = Inventory::default();

    let cpus = list(root.get("cpu"));
    if let Some(first) = cpus.first() {
        let sum = |key: &str| -> Option<u32> {
            let values: Vec<u64> = cpus.iter().filter_map(|c| u(c, key)).collect();
            (!values.is_empty()).then(|| values.iter().sum::<u64>() as u32).filter(|n| *n > 0)
        };
        let cpu = CpuInfo {
            model: s(first, "Name"),
            cores: sum("NumberOfCores"),
            threads: sum("NumberOfLogicalProcessors"),
            base_mhz: u(first, "MaxClockSpeed").and_then(|v| mhz(v as f64)),
        };
        if cpu != CpuInfo::default() {
            inv.cpu = Some(cpu);
        }
    }

    inv.gpus = non_empty(
        list(root.get("gpu"))
            .into_iter()
            .filter_map(|g| {
                let pnp = s(g, "PNPDeviceID").unwrap_or_default();
                // Remote / virtual / basic display adapters are not cards.
                if !pnp.to_ascii_uppercase().starts_with("PCI\\") {
                    return None;
                }
                let name = s(g, "Name")?;
                Some(GpuInfo {
                    integrated: win_gpu_integrated(&name, &pnp),
                    name,
                    vram_mb: None,
                    driver_version: s(g, "DriverVersion"),
                    driver_date: s(g, "DriverDate").and_then(|d| iso_date(&d)),
                })
            })
            .take(MAX_ITEMS)
            .collect(),
    );

    let modules: Vec<MemoryModule> = list(root.get("mem"))
        .into_iter()
        .take(MAX_ITEMS)
        .map(|m| MemoryModule {
            slot: s(m, "DeviceLocator"),
            size_mb: u(m, "Capacity").map(bytes_to_mb).filter(|v| *v > 0),
            kind: u(m, "SMBIOSMemoryType").and_then(smbios_memory_type).map(str::to_owned),
            speed_mts: u(m, "ConfiguredClockSpeed")
                .filter(|v| *v > 0)
                .or_else(|| u(m, "Speed"))
                .filter(|v| (100..=20_000).contains(v))
                .map(|v| v as u32),
            model: s(m, "PartNumber"),
            manufacturer: s(m, "Manufacturer"),
        })
        .collect();
    let total: u64 = modules.iter().filter_map(|m| m.size_mb).sum();
    let memory = MemoryInfo {
        total_mb: (total > 0).then_some(total),
        slots_total: u(root, "slots").filter(|n| (1..=256).contains(n)).map(|n| n as u32),
        modules: non_empty(modules),
    };
    if memory != MemoryInfo::default() {
        inv.memory = Some(memory);
    }

    let partitions: Vec<(String, String)> = list(root.get("part"))
        .into_iter()
        .filter_map(|p| Some((s(p, "d")?, s(p, "l")?)))
        .collect();
    inv.physical_disks = non_empty(
        list(root.get("disk"))
            .into_iter()
            .take(MAX_ITEMS)
            .filter_map(|d| {
                let id = s(d, "id")?;
                let mounts: Vec<String> = partitions
                    .iter()
                    .filter(|(disk, _)| *disk == id)
                    .filter(|(_, letter)| letter.len() == 1)
                    .map(|(_, letter)| format!("{}:", letter.to_ascii_uppercase()))
                    .collect();
                Some(PhysicalDisk {
                    model: s(d, "model")?,
                    bus: win_enum(d, "bus", win_bus, win_bus_text),
                    media: win_enum(d, "media", win_media, win_media_text),
                    size_gb: u(d, "size").and_then(bytes_to_gb),
                    firmware: s(d, "fw"),
                    health: win_enum(d, "health", win_health, win_health_text),
                    life_left_pct: u(d, "wear")
                        .filter(|w| *w <= 100)
                        .and_then(|w| pct(100.0 - w as f64)),
                    mounts: non_empty(mounts),
                    id,
                })
            })
            .collect(),
    );

    inv.network = non_empty(win_network(root));

    let board = BoardInfo {
        manufacturer: root.get("board").and_then(|v| s(v, "Manufacturer")),
        product: root.get("board").and_then(|v| s(v, "Product")),
    };
    if board != BoardInfo::default() {
        inv.board = Some(board);
    }
    if let Some(bios) = root.get("bios").filter(|v| v.is_object()) {
        let info = BiosInfo {
            vendor: s(bios, "Manufacturer"),
            version: s(bios, "SMBIOSBIOSVersion"),
            date: s(bios, "ReleaseDate").and_then(|d| iso_date(&d)),
        };
        if info != BiosInfo::default() {
            inv.bios = Some(info);
        }
        // Some firmware writes zeros instead of a serial number.
        inv.serial = s(bios, "SerialNumber").filter(|v| v.chars().any(|c| c != '0' && c != ' '));
    }
    inv.audio = text_list(strings(root.get("audio")).iter().map(String::as_str));
    inv.usb = text_list(
        strings(root.get("usb"))
            .iter()
            .map(String::as_str)
            .filter(|name| is_usb_device_name(name)),
    );
    inv.power_plan = root
        .get("plan")
        .and_then(Value::as_str)
        .and_then(power_plan_name);
    if let Some(os) = root.get("os").filter(|v| v.is_object()) {
        let build = match (s(os, "build"), u(os, "ubr")) {
            (Some(build), Some(ubr)) => Some(format!("{build}.{ubr}")),
            (build, _) => build,
        };
        let info = OsInfo {
            name: s(os, "name"),
            version: s(os, "dv").or_else(|| s(os, "version")),
            build,
            last_update: root.get("hotfix").and_then(Value::as_str).and_then(iso_date),
            hostname: s(os, "host"),
            timezone: root.get("tz").and_then(Value::as_str).and_then(text),
        };
        if info != OsInfo::default() {
            inv.os = Some(info);
        }
    }
    inv
}

/// Sense Remote (Sürüm 11, #119): the error messages the inventory script collected (`err`).
pub fn win_script_errors(root: &Value) -> Vec<String> {
    strings(root.get("err"))
}

fn win_network(root: &Value) -> Vec<NetAdapter> {
    let configs = list(root.get("cfg"));
    list(root.get("nic"))
        .into_iter()
        .filter_map(|n| {
            let name = s(n, "NetConnectionID")?;
            let description = s(n, "Name");
            if super::network::looks_virtual(&name, description.as_deref().unwrap_or("")) {
                return None;
            }
            let index = u(n, "Index");
            let config = configs.iter().find(|c| index.is_some() && u(c, "Index") == index);
            let kind = description.as_deref().map(|d| {
                if is_wifi_name(d) || is_wifi_name(&name) {
                    "wifi"
                } else {
                    "ethernet"
                }
            });
            // NetConnectionStatus: 2 connected, 7 media disconnected.
            let connected = match u(n, "NetConnectionStatus") {
                Some(2) => Some(true),
                Some(7) => Some(false),
                _ => None,
            };
            Some(NetAdapter {
                kind: kind.map(str::to_owned),
                mac: s(n, "MACAddress").and_then(|m| mac_address(&m)),
                connected,
                dhcp: config.and_then(|c| b(c, "DHCPEnabled")),
                gateway: config.and_then(|c| text_list(strings(c.get("DefaultIPGateway")).iter().map(String::as_str))),
                dns: config.and_then(|c| text_list(strings(c.get("DNSServerSearchOrder")).iter().map(String::as_str))),
                // Win32_NetworkAdapter.Speed is bits per second; a disconnected card reports a
                // meaningless maximum.
                speed_mbps: (connected != Some(false))
                    .then(|| u(n, "Speed"))
                    .flatten()
                    .map(|bits| bits / 1_000_000)
                    .filter(|m| (1..=400_000).contains(m)),
                driver_version: None,
                device: None,
                description,
                name,
            })
        })
        .take(MAX_ITEMS)
        .collect()
}

fn is_wifi_name(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    ["wi-fi", "wifi", "wireless", "wlan", "802.11"]
        .iter()
        .any(|k| lower.contains(k))
}

/// "AA:BB:CC:DD:EE:FF" / "aa-bb-..." -> "AA:BB:CC:DD:EE:FF"; anything else -> None.
pub fn mac_address(raw: &str) -> Option<String> {
    let hex: String = raw
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect::<String>()
        .to_ascii_uppercase();
    if hex.len() != 12 || raw.trim().len() != 17 || hex.chars().all(|c| c == '0') {
        return None;
    }
    Some(
        hex.as_bytes()
            .chunks(2)
            .map(|pair| String::from_utf8_lossy(pair).into_owned())
            .collect::<Vec<_>>()
            .join(":"),
    )
}

/// USB entries that are devices, not the controller / hub plumbing Windows lists with them.
pub fn is_usb_device_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    !["hub", "composite", "host controller", "root", "usb input device"]
        .iter()
        .any(|k| lower.contains(k))
}

/// `powercfg /getactivescheme` (any language): the name in the last parentheses.
pub fn powercfg_scheme_name(output: &str) -> Option<String> {
    let line = output.lines().find(|l| l.contains('('))?;
    let start = line.rfind('(')?;
    let end = line[start..].find(')')? + start;
    text(&line[start + 1..end])
}

/// Sense Remote (Sürüm 11, W13): the active power plan in Turkish. Windows writes the plan name
/// in its display language ("Balanced" / "Dengeli"); Windows' own plans are known by GUID and
/// get their Turkish name, any other plan (the maker's or the user's) keeps its own name.
pub fn power_plan_name(output: &str) -> Option<String> {
    let known = output.split_whitespace().find_map(|word| {
        let guid = word.trim_matches(|c: char| !c.is_ascii_hexdigit() && c != '-');
        Some(match guid.to_ascii_lowercase().as_str() {
            "381b4222-f694-41f0-9685-ff5bb260df2e" => "Dengeli",
            "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" => "Yüksek performans",
            "a1841308-3541-4fab-bc81-f71556f20b4a" => "Güç tasarrufu",
            "e9a42b02-d5df-448d-aa00-03f14749eb61" => "Nihai performans",
            _ => return None,
        })
    });
    match known {
        Some(name) => Some(name.to_owned()),
        None => powercfg_scheme_name(output),
    }
}

/// Drivers from the output of `inventory_win::DRIVERS_SCRIPT` (Win32_PnPSignedDriver): graphics,
/// network, Wi-Fi, audio and chipset drivers.
pub fn win_drivers(root: &Value) -> Vec<DriverInfo> {
    let mut out: Vec<DriverInfo> = Vec::new();
    for d in list(Some(root)) {
        let Some(device) = s(d, "DeviceName") else { continue };
        let class = s(d, "DeviceClass").unwrap_or_default().to_ascii_uppercase();
        let Some(class) = driver_class(&class, &device) else { continue };
        let entry = DriverInfo {
            class: class.to_owned(),
            version: s(d, "DriverVersion"),
            date: s(d, "DriverDate").and_then(|v| iso_date(&v)),
            provider: s(d, "DriverProviderName"),
            device,
        };
        if !out.contains(&entry) {
            out.push(entry);
        }
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    out
}

/// PnP device class + name -> contract driver class; `None` for devices O8 does not list.
pub fn driver_class(device_class: &str, device: &str) -> Option<&'static str> {
    let lower = device.to_ascii_lowercase();
    match device_class {
        "DISPLAY" => Some("display"),
        "NET" if is_wifi_name(device) => Some("wifi"),
        "NET" if !super::network::looks_virtual(device, device) && !lower.contains("wan miniport") => {
            Some("network")
        }
        "MEDIA" if lower.contains("audio") || lower.contains("sound") => Some("audio"),
        "SYSTEM"
            if ["chipset", "smbus", "lpc", "management engine", "serial io", "gpio"]
                .iter()
                .any(|k| lower.contains(k)) =>
        {
            Some("chipset")
        }
        _ => None,
    }
}

/// Network adapters get their driver version from the driver list (same device name).
pub fn attach_driver_versions(inventory: &mut Inventory) {
    let Some(drivers) = inventory.drivers.clone() else { return };
    if let Some(network) = inventory.network.as_mut() {
        for adapter in network {
            adapter.driver_version = adapter.description.as_ref().and_then(|d| {
                drivers
                    .iter()
                    .find(|x| (x.class == "network" || x.class == "wifi") && &x.device == d)
                    .and_then(|x| x.version.clone())
            });
        }
    }
}

/// Disk temperatures from `health_win::DISK_TEMP_SCRIPT`: `[{ id, temp }]`.
pub fn win_disk_temps(root: &Value) -> Vec<(String, f64)> {
    list(Some(root))
        .into_iter()
        .filter_map(|d| Some((s(d, "id")?, temp_c(u(d, "temp")? as f64)?)))
        .collect()
}

/// `nvidia-smi --query-gpu=name,temperature.gpu,fan.speed,power.draw,utilization.gpu,
/// memory.used,memory.total --format=csv,noheader,nounits`.
pub fn nvidia_smi(output: &str) -> Vec<GpuLive> {
    output
        .lines()
        .filter_map(|line| {
            let cols: Vec<&str> = line.split(',').map(str::trim).collect();
            if cols.len() != 7 {
                return None;
            }
            let num = |i: usize| cols[i].parse::<f64>().ok();
            Some(GpuLive {
                name: text(cols[0]),
                temp_c: num(1).and_then(temp_c),
                fan_pct: num(2).and_then(pct),
                power_w: num(3).and_then(power_w),
                util_pct: num(4).and_then(pct),
                vram_used_mb: num(5).filter(|v| *v >= 0.0).map(|v| v as u64),
                vram_total_mb: num(6).filter(|v| *v > 0.0).map(|v| v as u64),
            })
        })
        .collect()
}

/// `netsh wlan show interfaces` in any language: the first `key : value` line is the adapter
/// name; SSID / signal / band are recognised by key or by the shape of the value.
pub fn netsh_wifi(output: &str) -> Option<WifiLive> {
    let mut wifi = WifiLive::default();
    let mut channel: Option<u32> = None;
    for line in output.lines() {
        let Some((key, value)) = line.split_once(" : ") else { continue };
        let (key, value) = (key.trim(), value.trim());
        if wifi.name.is_none() {
            wifi.name = text(value);
            continue;
        }
        if key == "SSID" && wifi.ssid.is_none() {
            wifi.ssid = text(value);
        } else if let Some(n) = value.strip_suffix('%').or_else(|| value.strip_prefix('%')) {
            // "86%" (English) or "%54" (the Turkish way of writing a percentage, W12).
            if wifi.signal_pct.is_none() {
                wifi.signal_pct = n.trim().parse::<f64>().ok().and_then(pct);
            }
        } else if value.ends_with("GHz") && wifi.band.is_none() {
            wifi.band = wifi_band(value);
        } else if matches!(key, "Channel" | "Kanal") && channel.is_none() {
            channel = value.parse::<u32>().ok();
        }
    }
    // Sense Remote (Sürüm 11): Windows 10's netsh has no "Band" line; the channel tells it.
    if wifi.band.is_none() {
        wifi.band = channel.and_then(channel_band);
    }
    (wifi.ssid.is_some() || wifi.signal_pct.is_some()).then_some(wifi)
}

/// Wi-Fi channel -> band. 1–14 is 2.4 GHz, 32–177 is 5 GHz; 6 GHz channels overlap these
/// numbers, so they are only known from a band text.
pub fn channel_band(channel: u32) -> Option<String> {
    match channel {
        1..=14 => Some("2.4 GHz".to_owned()),
        32..=177 => Some("5 GHz".to_owned()),
        _ => None,
    }
}

/// "5 GHz" / "2,4 GHz" / "5GHz" -> contract band text.
pub fn wifi_band(raw: &str) -> Option<String> {
    let number = raw.to_ascii_lowercase().replace("ghz", "").replace(',', ".");
    let ghz: f64 = number.trim().parse().ok()?;
    Some(
        match ghz {
            g if (2.3..2.6).contains(&g) => "2.4 GHz",
            g if (4.9..5.9).contains(&g) => "5 GHz",
            g if (5.9..7.2).contains(&g) => "6 GHz",
            _ => return None,
        }
        .to_owned(),
    )
}

// ---------------------------------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------------------------------

fn sp<'a>(root: &'a Value, data_type: &str) -> Vec<&'a Value> {
    list(root.get(data_type))
}

/// Every `_items` entry under an item, depth first (USB trees, audio devices).
fn sp_items<'a>(item: &'a Value, out: &mut Vec<&'a Value>) {
    for child in list(item.get("_items")) {
        out.push(child);
        sp_items(child, out);
    }
}

/// "16 GB" / "512 MB" -> MB.
pub fn size_text_mb(raw: &str) -> Option<u64> {
    let mut parts = raw.split_whitespace();
    let number: f64 = parts.next()?.replace(',', ".").parse().ok()?;
    let factor = match parts.next()?.to_ascii_uppercase().as_str() {
        "TB" => 1024.0 * 1024.0,
        "GB" => 1024.0,
        "MB" => 1.0,
        _ => return None,
    };
    let mb = number * factor;
    (mb.is_finite() && mb > 0.0).then(|| mb.round() as u64)
}

/// Inventory from `system_profiler -json` (hardware, memory, graphics, storage, audio, USB,
/// software, network), plus `pmset -g` and the time zone.
pub fn mac_inventory(root: &Value, pmset: Option<&str>, timezone: Option<String>) -> Inventory {
    let mut inv = Inventory::default();
    let hardware = sp(root, "SPHardwareDataType").into_iter().next();

    if let Some(hw) = hardware {
        let model = s(hw, "machine_name");
        let identifier = s(hw, "machine_model");
        let product = match (model, identifier) {
            (Some(m), Some(i)) => Some(format!("{m} ({i})")),
            (m, i) => m.or(i),
        };
        inv.board = Some(BoardInfo {
            manufacturer: Some("Apple".to_owned()),
            product,
        });
        inv.bios = s(hw, "boot_rom_version").map(|version| BiosInfo {
            vendor: Some("Apple".to_owned()),
            version: Some(version),
            date: None,
        });
        inv.serial = s(hw, "serial_number");
    }

    inv.gpus = non_empty(
        sp(root, "SPDisplaysDataType")
            .into_iter()
            .filter_map(|g| {
                let name = s(g, "sppci_model").or_else(|| s(g, "_name"))?;
                let integrated = match g.get("sppci_bus").and_then(Value::as_str) {
                    Some("spdisplays_builtin") => Some(true),
                    Some("spdisplays_pcie_device") => Some(false),
                    _ => None,
                };
                let vram = s(g, "spdisplays_vram").and_then(|v| size_text_mb(&v));
                Some(GpuInfo {
                    name,
                    integrated,
                    vram_mb: vram,
                    driver_version: None,
                    driver_date: None,
                })
            })
            .take(MAX_ITEMS)
            .collect(),
    );

    let mut modules: Vec<MemoryModule> = Vec::new();
    for entry in sp(root, "SPMemoryDataType") {
        // Apple Silicon: one entry for the unified memory, no slots.
        if let Some(size) = s(entry, "SPMemoryDataType").and_then(|v| size_text_mb(&v)) {
            modules.push(MemoryModule {
                size_mb: Some(size),
                kind: s(entry, "dimm_type"),
                manufacturer: s(entry, "dimm_manufacturer"),
                ..Default::default()
            });
        }
        let mut items = Vec::new();
        sp_items(entry, &mut items);
        for dimm in items {
            let size = s(dimm, "dimm_size").and_then(|v| size_text_mb(&v));
            modules.push(MemoryModule {
                slot: s(dimm, "_name"),
                size_mb: size,
                kind: s(dimm, "dimm_type"),
                speed_mts: s(dimm, "dimm_speed")
                    .and_then(|v| v.split_whitespace().next()?.parse::<u32>().ok()),
                model: s(dimm, "dimm_part_number"),
                manufacturer: s(dimm, "dimm_manufacturer"),
            });
        }
    }
    let total: u64 = modules.iter().filter_map(|m| m.size_mb).sum();
    if !modules.is_empty() {
        inv.memory = Some(MemoryInfo {
            total_mb: (total > 0).then_some(total),
            slots_total: None,
            modules: non_empty(modules.into_iter().take(MAX_ITEMS).collect()),
        });
    }

    let mut disks: Vec<PhysicalDisk> = Vec::new();
    for (data_type, bus) in [("SPNVMeDataType", "nvme"), ("SPSerialATADataType", "sata")] {
        for controller in sp(root, data_type) {
            let mut items = Vec::new();
            sp_items(controller, &mut items);
            for d in items {
                let (Some(id), Some(model)) = (s(d, "bsd_name"), s(d, "device_model").or_else(|| s(d, "_name"))) else {
                    continue;
                };
                let media = match d.get("spsata_medium_type").and_then(Value::as_str) {
                    Some("Rotational") => Some("hdd"),
                    Some("Solid State") => Some("ssd"),
                    _ if bus == "nvme" => Some("ssd"),
                    _ => None,
                };
                let health = match d.get("smart_status").and_then(Value::as_str) {
                    Some("Verified") => Some("ok"),
                    Some("Failing") => Some("failing"),
                    _ => None,
                };
                disks.push(PhysicalDisk {
                    id,
                    model,
                    bus: Some(bus.to_owned()),
                    media: media.map(str::to_owned),
                    size_gb: u(d, "size_in_bytes").and_then(bytes_to_gb),
                    firmware: s(d, "device_revision"),
                    health: health.map(str::to_owned),
                    life_left_pct: None,
                    mounts: None,
                });
            }
        }
    }
    inv.physical_disks = non_empty(disks.into_iter().take(MAX_ITEMS).collect());

    inv.network = non_empty(
        sp(root, "SPNetworkDataType")
            .into_iter()
            .filter_map(mac_network)
            .take(MAX_ITEMS)
            .collect(),
    );

    let mut audio = Vec::new();
    for group in sp(root, "SPAudioDataType") {
        sp_items(group, &mut audio);
    }
    inv.audio = text_list(audio.iter().filter_map(|a| a.get("_name")?.as_str()));
    let mut usb = Vec::new();
    for bus in sp(root, "SPUSBDataType").into_iter().chain(sp(root, "SPUSBHostDataType")) {
        sp_items(bus, &mut usb);
    }
    inv.usb = text_list(
        usb.iter()
            .filter_map(|d| d.get("_name")?.as_str())
            .filter(|name| is_usb_device_name(name)),
    );
    inv.power_restore = pmset.and_then(pmset_autorestart);

    if let Some(sw) = sp(root, "SPSoftwareDataType").into_iter().next() {
        let (version, build) = s(sw, "os_version")
            .map(|v| split_mac_os_version(&v))
            .unwrap_or((None, None));
        inv.os = Some(OsInfo {
            name: Some("macOS".to_owned()),
            version,
            build,
            last_update: None,
            hostname: s(sw, "local_host_name"),
            timezone,
        });
    }
    inv
}

/// One `SPNetworkDataType` service -> adapter. Only hardware interfaces (Ethernet, Wi-Fi).
fn mac_network(service: &Value) -> Option<NetAdapter> {
    let name = s(service, "_name")?;
    let device = s(service, "interface");
    let kind = match service.get("hardware").and_then(Value::as_str) {
        Some("AirPort") | Some("Wi-Fi") => "wifi",
        Some("Ethernet") => "ethernet",
        _ => return None,
    };
    let ipv4 = service.get("IPv4");
    let dhcp = match ipv4.and_then(|v| v.get("ConfigMethod")).and_then(Value::as_str) {
        Some("DHCP") | Some("BOOTP") => Some(true),
        Some("Manual") => Some(false),
        _ => None,
    };
    let gateway = ipv4
        .and_then(|v| v.get("Router"))
        .and_then(Value::as_str)
        .and_then(|r| text_list([r]));
    let dns = service
        .get("DNS")
        .and_then(|d| text_list(strings(d.get("ServerAddresses")).iter().map(String::as_str)));
    let mac = service
        .get("Ethernet")
        .and_then(|e| s(e, "MAC Address"))
        .and_then(|m| mac_address(&m));
    Some(NetAdapter {
        name,
        device,
        kind: Some(kind.to_owned()),
        description: None,
        mac,
        connected: None,
        dhcp,
        gateway,
        dns,
        speed_mbps: None,
        driver_version: None,
    })
}

/// "macOS 14.5 (23F79)" -> ("14.5", "23F79").
pub fn split_mac_os_version(raw: &str) -> (Option<String>, Option<String>) {
    let without_name = raw.trim().trim_start_matches("macOS").trim();
    match without_name.split_once('(') {
        Some((version, build)) => (text(version), text(build.trim_end_matches(')'))),
        None => (text(without_name), None),
    }
}

/// `pmset -g`: " autorestart          1" -> true. Missing -> None.
pub fn pmset_autorestart(output: &str) -> Option<bool> {
    output.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        (parts.next()? == "autorestart").then_some(())?;
        match parts.next()? {
            "1" => Some(true),
            "0" => Some(false),
            _ => None,
        }
    })
}

/// `/etc/localtime` link target -> "Europe/Istanbul".
pub fn zoneinfo_name(link: &str) -> Option<String> {
    let name = link.split("zoneinfo/").nth(1)?;
    (name.contains('/') || name == "UTC").then(|| text(name)).flatten()
}

/// The `ioreg` blocks of one class: text from each "+-o" line to the next one of that class.
fn ioreg_blocks<'a>(output: &'a str, class: &str) -> Vec<&'a str> {
    let marker = format!("<class {class}");
    let mut starts: Vec<usize> = output.match_indices("+-o ").map(|(i, _)| i).collect();
    starts.retain(|i| output[*i..].lines().next().is_some_and(|l| l.contains(&marker)));
    starts
        .iter()
        .enumerate()
        .map(|(n, start)| {
            let end = starts.get(n + 1).copied().unwrap_or(output.len());
            &output[*start..end]
        })
        .collect()
}

/// `"Key"=123` or `"Key" = 123` inside an ioreg block.
fn ioreg_number(block: &str, key: &str) -> Option<u64> {
    let quoted = format!("\"{key}\"");
    let mut search = block;
    while let Some(pos) = search.find(&quoted) {
        let rest = search[pos + quoted.len()..].trim_start();
        if let Some(rest) = rest.strip_prefix('=') {
            let digits: String = rest
                .trim_start()
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            if let Ok(n) = digits.parse() {
                return Some(n);
            }
        }
        search = &search[pos + quoted.len()..];
    }
    None
}

fn ioreg_string(block: &str, key: &str) -> Option<String> {
    let quoted = format!("\"{key}\" = \"");
    let start = block.find(&quoted)? + quoted.len();
    let end = block[start..].find('"')? + start;
    text(&block[start..end])
}

/// `ioreg -r -d 1 -w 0 -c IOAccelerator`: GPU utilisation and memory in use per accelerator.
pub fn mac_gpu_stats(output: &str) -> Vec<GpuLive> {
    ioreg_blocks(output, "")
        .into_iter()
        .filter(|block| block.contains("PerformanceStatistics"))
        .map(|block| GpuLive {
            name: ioreg_string(block, "model"),
            util_pct: ioreg_number(block, "Device Utilization %").and_then(|v| pct(v as f64)),
            vram_used_mb: ioreg_number(block, "In use system memory").map(bytes_to_mb),
            ..Default::default()
        })
        .filter(|g| g.util_pct.is_some() || g.vram_used_mb.is_some())
        .collect()
}

/// `ioreg -r -w 0 -l -d 2 -c IOBlockStorageDriver`: cumulative bytes read / written per disk
/// (BSD name of the media below the driver).
pub fn mac_disk_counters(output: &str) -> Vec<(String, u64, u64)> {
    ioreg_blocks(output, "IOBlockStorageDriver")
        .into_iter()
        .filter_map(|block| {
            let id = ioreg_string(block, "BSD Name")?;
            let read = ioreg_number(block, "Bytes (Read)")?;
            let write = ioreg_number(block, "Bytes (Write)")?;
            Some((id, read, write))
        })
        .collect()
}

// Sense Remote (Sürüm 11, #119): values macOS has but were not collected. The property names
// come from `system_profiler -json` / the tools' text, not from a documented API; each value
// that does not parse stays "not read" (checked on a device, plan §8).

/// The connected Wi-Fi interface of `system_profiler SPAirPortDataType -json`.
fn mac_airport_current(root: &Value) -> Option<(&Value, &Value)> {
    sp(root, "SPAirPortDataType").into_iter().find_map(|entry| {
        list(entry.get("spairport_airport_interfaces"))
            .into_iter()
            .find_map(|i| Some((i, i.get("spairport_current_network_information")?)))
    })
}

/// "-52 dBm / -92 dBm" -> -52.
fn dbm(raw: &str) -> Option<f64> {
    let first = raw.split('/').next()?.trim();
    let number = first.trim_end_matches("dBm").trim();
    number.parse::<f64>().ok().filter(|v| (-120.0..=0.0).contains(v))
}

/// Signal strength in dBm -> percentage on the scale Windows' netsh uses (-100 dBm = 0 %,
/// -50 dBm and stronger = 100 %).
pub fn dbm_to_pct(dbm: f64) -> Option<f64> {
    pct((2.0 * (dbm + 100.0)).clamp(0.0, 100.0))
}

/// "149 (5GHz, 80MHz)" / "6 (2GHz, 20MHz)" / "36,80" -> band.
fn mac_channel_band(raw: &str) -> Option<String> {
    let lower = raw.to_ascii_lowercase();
    if lower.contains("6ghz") {
        return Some("6 GHz".to_owned());
    }
    if lower.contains("5ghz") {
        return Some("5 GHz".to_owned());
    }
    if lower.contains("2ghz") || lower.contains("2.4ghz") {
        return Some("2.4 GHz".to_owned());
    }
    let digits: String = lower.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok().and_then(channel_band)
}

/// Live Wi-Fi from `system_profiler SPAirPortDataType -json`. The network name needs the
/// location permission on macOS 14+ ("<redacted>" without it), so only band / signal may come.
pub fn mac_wifi(root: &Value) -> Option<WifiLive> {
    let (interface, current) = mac_airport_current(root)?;
    let wifi = WifiLive {
        name: s(interface, "_name"),
        ssid: s(current, "_name").filter(|n| !n.starts_with('<')),
        band: s(current, "spairport_network_channel").and_then(|c| mac_channel_band(&c)),
        signal_pct: s(current, "spairport_signal_noise")
            .and_then(|v| dbm(&v))
            .and_then(dbm_to_pct),
    };
    (wifi.ssid.is_some() || wifi.signal_pct.is_some() || wifi.band.is_some()).then_some(wifi)
}

/// Link rate of the connected Wi-Fi (Mbit/s) and its BSD name.
pub fn mac_wifi_rate(root: &Value) -> Option<(String, u64)> {
    let (interface, current) = mac_airport_current(root)?;
    let rate = u(current, "spairport_network_rate").filter(|r| (1..=100_000).contains(r))?;
    Some((s(interface, "_name")?, rate))
}

/// `ifconfig <en>`: link up (`status: active`) and, for Ethernet, the speed from the media line
/// ("media: autoselect (1000baseT <full-duplex>)", "10GbaseT", "2500Base-T").
pub fn mac_ifconfig(output: &str) -> (Option<bool>, Option<u64>) {
    let mut connected = None;
    let mut speed = None;
    for line in output.lines().map(str::trim) {
        if let Some(status) = line.strip_prefix("status:") {
            connected = match status.trim() {
                "active" => Some(true),
                "inactive" => Some(false),
                _ => None,
            };
        } else if let Some(media) = line.strip_prefix("media:") {
            let inner = media.split('(').nth(1).unwrap_or(media).to_ascii_lowercase();
            if let Some(at) = inner.find("base") {
                let head = &inner[..at];
                let (number, factor) = match head.strip_suffix('g') {
                    Some(n) => (n, 1000),
                    None => (head, 1),
                };
                speed = number
                    .trim()
                    .parse::<u64>()
                    .ok()
                    .map(|n| n * factor)
                    .filter(|m| (1..=400_000).contains(m));
            }
        }
    }
    (connected, speed.filter(|_| connected != Some(false)))
}

/// One `ifconfig` reading per BSD name: (name, link up, speed Mbit/s).
pub type MacLink = (String, Option<bool>, Option<u64>);

/// Adds to a macOS inventory what the second `system_profiler` run (Wi-Fi, install history) and
/// `ifconfig` give: last update, adapter connected / speed (Wi-Fi: the link rate).
pub fn mac_inventory_extras(inv: &mut Inventory, extra: &Value, links: &[MacLink]) {
    if let Some(os) = inv.os.as_mut() {
        os.last_update = mac_last_update(extra);
    }
    let wifi_rate = mac_wifi_rate(extra);
    let Some(network) = inv.network.as_mut() else { return };
    for adapter in network {
        let Some(device) = adapter.device.clone() else { continue };
        if let Some((_, up, speed)) = links.iter().find(|(d, ..)| *d == device) {
            adapter.connected = *up;
            adapter.speed_mbps = *speed;
        }
        if adapter.kind.as_deref() == Some("wifi") && adapter.connected != Some(false) {
            if let Some((_, rate)) = wifi_rate.as_ref().filter(|(d, _)| *d == device) {
                adapter.speed_mbps = Some(*rate);
            }
        }
    }
}

/// Date of the newest macOS update (`system_profiler SPInstallHistoryDataType -json`): system
/// versions and security responses installed by Apple, not apps.
pub fn mac_last_update(root: &Value) -> Option<String> {
    sp(root, "SPInstallHistoryDataType")
        .into_iter()
        .filter(|item| {
            let name = item.get("_name").and_then(Value::as_str).unwrap_or_default();
            name.starts_with("macOS") || name.contains("Security Response")
        })
        .filter_map(|item| s(item, "install_date").and_then(|d| iso_date(&d)))
        .max()
}

/// Memory the system can give to programs without swapping, from `vm_stat`: free, speculative,
/// inactive and purgeable pages. Sense Remote (Sürüm 11, #119): sysinfo reported 0 on both test
/// Macs (it subtracts the compressor pages), so the field never reached the popup.
pub fn vm_stat_available_mb(output: &str) -> Option<u64> {
    let page: u64 = output
        .split("page size of ")
        .nth(1)?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
        .filter(|p| *p >= 4096)?;
    let pages = |key: &str| -> Option<u64> {
        let line = output.lines().find(|l| l.trim_start().starts_with(key))?;
        line.split(':').nth(1)?.trim().trim_end_matches('.').parse().ok()
    };
    let total = pages("Pages free")?
        + pages("Pages speculative").unwrap_or(0)
        + pages("Pages inactive").unwrap_or(0)
        + pages("Pages purgeable").unwrap_or(0);
    Some(bytes_to_mb(total.saturating_mul(page))).filter(|mb| *mb > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn win_sample() -> Value {
        serde_json::from_str(
            r#"{
            "cpu": {"Name": "Intel(R) Core(TM) i7-12700 ", "NumberOfCores": 12,
                    "NumberOfLogicalProcessors": 20, "MaxClockSpeed": 2100},
            "gpu": [
                {"Name": "NVIDIA GeForce RTX 3060", "DriverVersion": "32.0.15.6094",
                 "PNPDeviceID": "PCI\\VEN_10DE&DEV_2504", "DriverDate": "2024-08-14"},
                {"Name": "Intel(R) UHD Graphics 770", "DriverVersion": "31.0.101.4502",
                 "PNPDeviceID": "PCI\\VEN_8086&DEV_4680", "DriverDate": null},
                {"Name": "RustDesk IddDriver", "PNPDeviceID": "ROOT\\DISPLAY\\0000"}
            ],
            "mem": [
                {"DeviceLocator": "DIMM1", "Capacity": 17179869184, "SMBIOSMemoryType": 26,
                 "Speed": 3200, "ConfiguredClockSpeed": 2933, "PartNumber": "KHX3200C16D4/16GX ",
                 "Manufacturer": "Kingston"},
                {"DeviceLocator": "DIMM2", "Capacity": 17179869184, "SMBIOSMemoryType": 0,
                 "Speed": 3200, "ConfiguredClockSpeed": 0, "PartNumber": "", "Manufacturer": "Unknown"}
            ],
            "slots": 4,
            "disk": [
                {"id": "0", "model": "Samsung SSD 980 PRO 1TB", "bus": 17, "media": 4,
                 "size": 1000204886016, "fw": "5B2QGXA7", "health": 0, "wear": 3, "temp": 41},
                {"id": "1", "model": "ST2000DM008", "bus": 11, "media": 3, "size": 2000398934016,
                 "fw": "0001", "health": 1, "wear": null, "temp": 0}
            ],
            "part": [{"d": "0", "l": "C"}, {"d": "1", "l": "D"}, {"d": "1", "l": "e"}],
            "nic": [
                {"Index": 1, "NetConnectionID": "Ethernet", "Name": "Intel(R) Ethernet Connection I219-V",
                 "MACAddress": "00:1B:21:AA:BB:CC", "Speed": 1000000000, "NetConnectionStatus": 2},
                {"Index": 2, "NetConnectionID": "Wi-Fi", "Name": "Intel(R) Wi-Fi 6 AX201 160MHz",
                 "MACAddress": "00:1B:21:AA:BB:CD", "Speed": 9223372036854775807, "NetConnectionStatus": 7},
                {"Index": 3, "NetConnectionID": "vEthernet (WSL)", "Name": "Hyper-V Virtual Ethernet Adapter",
                 "MACAddress": "00:15:5D:00:00:01", "Speed": 10000000000, "NetConnectionStatus": 2}
            ],
            "cfg": {"Index": 1, "DHCPEnabled": false, "DefaultIPGateway": ["192.168.1.1"],
                    "DNSServerSearchOrder": ["1.1.1.1", "8.8.8.8"]},
            "board": {"Manufacturer": "ASUSTeK COMPUTER INC.", "Product": "PRIME B660M-A D4"},
            "bios": {"Manufacturer": "American Megatrends Inc.", "SMBIOSBIOSVersion": "2803",
                     "SerialNumber": "System Serial Number", "ReleaseDate": "2023-05-01"},
            "audio": ["Realtek High Definition Audio", "NVIDIA High Definition Audio"],
            "usb": ["USB Root Hub (USB 3.0)", "Logitech USB Receiver", "USB Composite Device", "Elgato Stream Deck"],
            "plan": "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)",
            "os": {"name": "Microsoft Windows 11 Pro", "version": "10.0.26100", "build": "26100",
                   "host": "MUSEUM-PC-01", "ubr": 2314, "dv": "24H2"},
            "tz": "Turkey Standard Time",
            "hotfix": "2024-11-12"
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn windows_inventory_mapping() {
        let inv = win_inventory(&win_sample());
        let cpu = inv.cpu.unwrap();
        assert_eq!(cpu.model.as_deref(), Some("Intel(R) Core(TM) i7-12700"));
        assert_eq!((cpu.cores, cpu.threads, cpu.base_mhz), (Some(12), Some(20), Some(2100)));

        let gpus = inv.gpus.unwrap();
        assert_eq!(gpus.len(), 2, "virtual display adapter left out");
        assert_eq!(gpus[0].integrated, Some(false));
        assert_eq!(gpus[0].driver_date.as_deref(), Some("2024-08-14"));
        assert_eq!(gpus[1].integrated, Some(true));
        assert_eq!(gpus[1].driver_date, None);

        let memory = inv.memory.unwrap();
        assert_eq!(memory.total_mb, Some(32768));
        assert_eq!(memory.slots_total, Some(4));
        let modules = memory.modules.unwrap();
        assert_eq!(modules[0].kind.as_deref(), Some("DDR4"));
        assert_eq!(modules[0].speed_mts, Some(2933));
        assert_eq!(modules[0].model.as_deref(), Some("KHX3200C16D4/16GX"));
        assert_eq!(modules[1].kind, None);
        assert_eq!(modules[1].speed_mts, Some(3200));
        assert_eq!(modules[1].manufacturer, None, "\"Unknown\" is not a value");

        let disks = inv.physical_disks.unwrap();
        assert_eq!(disks[0].bus.as_deref(), Some("nvme"));
        assert_eq!(disks[0].media.as_deref(), Some("ssd"));
        assert_eq!(disks[0].life_left_pct, Some(97.0));
        assert_eq!(disks[0].health.as_deref(), Some("ok"));
        assert_eq!(disks[0].mounts, Some(vec!["C:".to_owned()]));
        assert_eq!(disks[0].size_gb, Some(931.5));
        assert_eq!(disks[1].bus.as_deref(), Some("sata"));
        assert_eq!(disks[1].health.as_deref(), Some("warning"));
        assert_eq!(disks[1].life_left_pct, None);
        assert_eq!(disks[1].mounts, Some(vec!["D:".to_owned(), "E:".to_owned()]));

        let net = inv.network.unwrap();
        assert_eq!(net.len(), 2, "Hyper-V adapter left out");
        assert_eq!(net[0].kind.as_deref(), Some("ethernet"));
        assert_eq!(net[0].dhcp, Some(false));
        assert_eq!(net[0].gateway, Some(vec!["192.168.1.1".to_owned()]));
        assert_eq!(net[0].dns.as_ref().unwrap().len(), 2);
        assert_eq!(net[0].speed_mbps, Some(1000));
        assert_eq!(net[0].connected, Some(true));
        assert_eq!(net[1].kind.as_deref(), Some("wifi"));
        assert_eq!(net[1].connected, Some(false));
        assert_eq!(net[1].speed_mbps, None);
        assert_eq!(net[1].dhcp, None);

        assert_eq!(inv.board.unwrap().product.as_deref(), Some("PRIME B660M-A D4"));
        assert_eq!(inv.bios.unwrap().date.as_deref(), Some("2023-05-01"));
        assert_eq!(inv.serial, None, "placeholder serial left out");
        assert_eq!(inv.usb, Some(vec!["Logitech USB Receiver".into(), "Elgato Stream Deck".into()]));
        // Sürüm 11 (W13): Windows' own plan by GUID, in Turkish.
        assert_eq!(inv.power_plan.as_deref(), Some("Dengeli"));
        let os = inv.os.unwrap();
        assert_eq!(os.version.as_deref(), Some("24H2"));
        assert_eq!(os.build.as_deref(), Some("26100.2314"));
        assert_eq!(os.last_update.as_deref(), Some("2024-11-12"));
        assert_eq!(os.timezone.as_deref(), Some("Turkey Standard Time"));
    }

    #[test]
    fn windows_empty_output_gives_an_empty_inventory() {
        assert_eq!(win_inventory(&json!({})), Inventory::default());
        assert_eq!(win_inventory(&Value::Null), Inventory::default());
    }

    #[test]
    fn drivers_are_classified_and_attached() {
        let raw: Value = serde_json::from_str(
            r#"[
            {"DeviceClass": "DISPLAY", "DeviceName": "NVIDIA GeForce RTX 3060", "DriverVersion": "32.0.15.6094", "DriverDate": "2024-08-14", "DriverProviderName": "NVIDIA"},
            {"DeviceClass": "NET", "DeviceName": "Intel(R) Ethernet Connection I219-V", "DriverVersion": "12.19.2.45"},
            {"DeviceClass": "NET", "DeviceName": "Intel(R) Wi-Fi 6 AX201 160MHz", "DriverVersion": "22.250.1.2"},
            {"DeviceClass": "NET", "DeviceName": "WAN Miniport (IP)", "DriverVersion": "10.0"},
            {"DeviceClass": "MEDIA", "DeviceName": "Realtek High Definition Audio", "DriverVersion": "6.0.9600.1"},
            {"DeviceClass": "SYSTEM", "DeviceName": "Intel(R) SMBus - 7AA3", "DriverVersion": "10.1.1"},
            {"DeviceClass": "SYSTEM", "DeviceName": "System timer", "DriverVersion": "10.0"}
        ]"#,
        )
        .unwrap();
        let drivers = win_drivers(&raw);
        let classes: Vec<&str> = drivers.iter().map(|d| d.class.as_str()).collect();
        assert_eq!(classes, vec!["display", "network", "wifi", "audio", "chipset"]);
        assert_eq!(drivers[0].date.as_deref(), Some("2024-08-14"));

        let mut inv = win_inventory(&win_sample());
        inv.drivers = Some(drivers);
        attach_driver_versions(&mut inv);
        let net = inv.network.unwrap();
        assert_eq!(net[0].driver_version.as_deref(), Some("12.19.2.45"));
        assert_eq!(net[1].driver_version.as_deref(), Some("22.250.1.2"));
    }

    #[test]
    fn small_windows_parsers() {
        assert_eq!(mac_address("00-1b-21-aa-bb-cc"), Some("00:1B:21:AA:BB:CC".into()));
        assert_eq!(mac_address("00:00:00:00:00:00"), None);
        assert_eq!(mac_address("nonsense"), None);
        assert_eq!(
            powercfg_scheme_name("Güç Düzeni GUID'si: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Yüksek performans)"),
            Some("Yüksek performans".into())
        );
        assert_eq!(powercfg_scheme_name("error"), None);
        assert_eq!(
            win_disk_temps(&json!([{"id": "0", "temp": 38}, {"id": "1", "temp": 0}, {"id": "2", "temp": 255}])),
            vec![("0".to_owned(), 38.0)]
        );
        assert_eq!(win_disk_temps(&json!({"id": "0", "temp": 40})), vec![("0".to_owned(), 40.0)]);
    }

    #[test]
    fn nvidia_smi_csv() {
        let out = "NVIDIA GeForce RTX 3060, 47, 30, 25.31, 4, 812, 12288\n\
                   NVIDIA T400, 52, [N/A], [N/A], 0, 100, 2048\n\
                   garbage";
        let gpus = nvidia_smi(out);
        assert_eq!(gpus.len(), 2);
        assert_eq!(gpus[0].name.as_deref(), Some("NVIDIA GeForce RTX 3060"));
        assert_eq!(gpus[0].temp_c, Some(47.0));
        assert_eq!(gpus[0].fan_pct, Some(30.0));
        assert_eq!(gpus[0].power_w, Some(25.3));
        assert_eq!(gpus[0].util_pct, Some(4.0));
        assert_eq!((gpus[0].vram_used_mb, gpus[0].vram_total_mb), (Some(812), Some(12288)));
        assert_eq!((gpus[1].fan_pct, gpus[1].power_w), (None, None));
        assert_eq!(gpus[1].util_pct, Some(0.0));
    }

    #[test]
    fn netsh_in_english_and_turkish() {
        let en = "\nThere is 1 interface on the system:\n\n    Name                   : Wi-Fi\n    Description            : Intel(R) Wi-Fi 6 AX201\n    State                  : connected\n    SSID                   : Museum-Guest\n    BSSID                  : aa:bb:cc:dd:ee:ff\n    Band                   : 5 GHz\n    Channel                : 36\n    Signal                 : 86% \n";
        let wifi = netsh_wifi(en).unwrap();
        assert_eq!(wifi.name.as_deref(), Some("Wi-Fi"));
        assert_eq!(wifi.ssid.as_deref(), Some("Museum-Guest"));
        assert_eq!(wifi.band.as_deref(), Some("5 GHz"));
        assert_eq!(wifi.signal_pct, Some(86.0));
        let tr = "    Ad                     : Kablosuz\n    SSID                   : Ofis\n    Bant                   : 2,4 GHz\n    Sinyal                 : 54%\n";
        let wifi = netsh_wifi(tr).unwrap();
        assert_eq!(wifi.name.as_deref(), Some("Kablosuz"));
        assert_eq!(wifi.band.as_deref(), Some("2.4 GHz"));
        assert_eq!(wifi.signal_pct, Some(54.0));
        assert_eq!(netsh_wifi("The Wireless AutoConfig Service (wlansvc) is not running."), None);
        assert_eq!(wifi_band("60 GHz"), None);
    }

    fn mac_sample() -> Value {
        serde_json::from_str(
            r#"{
            "SPHardwareDataType": [{"machine_name": "Mac mini", "machine_model": "Mac14,3",
                "chip_type": "Apple M2", "serial_number": "ABCD1234EF", "boot_rom_version": "10151.121.1"}],
            "SPDisplaysDataType": [{"_name": "Apple M2", "sppci_model": "Apple M2",
                "sppci_bus": "spdisplays_builtin", "sppci_cores": "10"}],
            "SPMemoryDataType": [{"SPMemoryDataType": "16 GB", "dimm_manufacturer": "Hynix", "dimm_type": "LPDDR5"}],
            "SPNVMeDataType": [{"_name": "Apple SSD Controller", "_items": [
                {"_name": "APPLE SSD AP0512Z", "bsd_name": "disk0", "device_model": "APPLE SSD AP0512Z",
                 "device_revision": "387.100.", "size_in_bytes": 500277790720, "smart_status": "Verified"}]}],
            "SPNetworkDataType": [
                {"_name": "Ethernet", "interface": "en0", "hardware": "Ethernet",
                 "IPv4": {"ConfigMethod": "Manual", "Router": "10.0.0.1"},
                 "DNS": {"ServerAddresses": ["10.0.0.2"]}, "Ethernet": {"MAC Address": "aa:bb:cc:dd:ee:01"}},
                {"_name": "Wi-Fi", "interface": "en1", "hardware": "AirPort", "IPv4": {"ConfigMethod": "DHCP"}},
                {"_name": "Thunderbolt Bridge", "interface": "bridge0", "hardware": "Bridge"}
            ],
            "SPAudioDataType": [{"_name": "Devices", "_items": [{"_name": "Mac mini Speakers"}, {"_name": "LG HDR 4K"}]}],
            "SPUSBHostDataType": [{"_name": "USB31Bus", "_items": [{"_name": "USB3.1 Hub", "_items": [{"_name": "Magic Keyboard"}]}]}],
            "SPSoftwareDataType": [{"os_version": "macOS 14.5 (23F79)", "local_host_name": "Sense-Mini"}]
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn mac_inventory_mapping() {
        let inv = mac_inventory(
            &mac_sample(),
            Some("System-wide power settings:\n autorestart          1\n sleep 0\n"),
            Some("Europe/Istanbul".into()),
        );
        assert_eq!(inv.board.unwrap().product.as_deref(), Some("Mac mini (Mac14,3)"));
        assert_eq!(inv.bios.unwrap().version.as_deref(), Some("10151.121.1"));
        assert_eq!(inv.serial.as_deref(), Some("ABCD1234EF"));
        let gpus = inv.gpus.unwrap();
        assert_eq!(gpus[0].name, "Apple M2");
        assert_eq!(gpus[0].integrated, Some(true));
        let memory = inv.memory.unwrap();
        assert_eq!(memory.total_mb, Some(16384));
        assert_eq!(memory.slots_total, None);
        assert_eq!(memory.modules.unwrap()[0].kind.as_deref(), Some("LPDDR5"));
        let disks = inv.physical_disks.unwrap();
        assert_eq!(disks[0].id, "disk0");
        assert_eq!(disks[0].bus.as_deref(), Some("nvme"));
        assert_eq!(disks[0].health.as_deref(), Some("ok"));
        let net = inv.network.unwrap();
        assert_eq!(net.len(), 2, "bridge left out");
        assert_eq!(net[0].dhcp, Some(false));
        assert_eq!(net[0].gateway, Some(vec!["10.0.0.1".to_owned()]));
        assert_eq!(net[0].mac.as_deref(), Some("AA:BB:CC:DD:EE:01"));
        assert_eq!(net[0].device.as_deref(), Some("en0"));
        assert_eq!(net[1].kind.as_deref(), Some("wifi"));
        assert_eq!(net[1].dhcp, Some(true));
        assert_eq!(inv.audio.unwrap().len(), 2);
        assert_eq!(inv.usb, Some(vec!["Magic Keyboard".to_owned()]));
        assert_eq!(inv.power_restore, Some(true));
        let os = inv.os.unwrap();
        assert_eq!((os.version.as_deref(), os.build.as_deref()), (Some("14.5"), Some("23F79")));
        assert_eq!(os.timezone.as_deref(), Some("Europe/Istanbul"));
    }

    #[test]
    fn small_mac_parsers() {
        assert_eq!(size_text_mb("16 GB"), Some(16384));
        assert_eq!(size_text_mb("1,5 GB"), Some(1536));
        assert_eq!(size_text_mb("lots"), None);
        assert_eq!(pmset_autorestart(" sleep 1\n"), None);
        assert_eq!(pmset_autorestart(" autorestart 0\n"), Some(false));
        assert_eq!(zoneinfo_name("/var/db/timezone/zoneinfo/Europe/Istanbul"), Some("Europe/Istanbul".into()));
        assert_eq!(zoneinfo_name("/etc/whatever"), None);
        assert_eq!(split_mac_os_version("macOS 15.1"), (Some("15.1".into()), None));
    }

    #[test]
    fn mac_ioreg_outputs() {
        let gpu = "+-o AGXAcceleratorG14G  <class AGXAcceleratorG14G, id 0x1000, registered>\n    {\n      \"PerformanceStatistics\" = {\"In use system memory (driver)\"=0,\"Device Utilization %\"=12,\"In use system memory\"=274251776}\n      \"model\" = \"Apple M2\"\n    }\n";
        let gpus = mac_gpu_stats(gpu);
        assert_eq!(gpus.len(), 1);
        assert_eq!(gpus[0].name.as_deref(), Some("Apple M2"));
        assert_eq!(gpus[0].util_pct, Some(12.0));
        assert_eq!(gpus[0].vram_used_mb, Some(261));
        assert!(mac_gpu_stats("").is_empty());

        let disk = "+-o IOBlockStorageDriver  <class IOBlockStorageDriver, id 0x1>\n    {\n      \"Statistics\" = {\"Bytes (Read)\"=1000,\"Operations (Write)\"=5,\"Bytes (Write)\"=2000}\n    }\n    +-o APPLE SSD Media  <class IOMedia, id 0x2>\n        {\n          \"BSD Name\" = \"disk0\"\n        }\n+-o IOBlockStorageDriver  <class IOBlockStorageDriver, id 0x3>\n    {\n      \"Statistics\" = {\"Bytes (Read)\"=7,\"Bytes (Write)\"=8}\n    }\n";
        assert_eq!(mac_disk_counters(disk), vec![("disk0".to_owned(), 1000, 2000)]);
    }

    // ------------------------------------------------------------------ Sürüm 11 (#119, #124)

    /// Real output of this build's scripts on Windows PowerShell 5.1 (`testdata/win-ps51-disk.json`,
    /// bakış açısı 20: the sample is the tool's own output, not typed by hand).
    fn ps51() -> Value {
        serde_json::from_str(include_str!("testdata/win-ps51-disk.json")).unwrap()
    }

    #[test]
    fn real_ps51_disk_output_gives_a_disk() {
        let real = ps51();
        let root = json!({ "disk": real["script_disk"], "part": real["script_part"], "plan": real["plan"] });
        let inv = win_inventory(&root);
        let disks = inv.physical_disks.expect("the disk list is not empty on real output");
        assert_eq!(disks.len(), 1);
        assert_eq!(disks[0].id, "0");
        assert_eq!(disks[0].model, "CT2000P310SSD8");
        assert_eq!(disks[0].bus.as_deref(), Some("nvme"));
        assert_eq!(disks[0].media.as_deref(), Some("ssd"));
        assert_eq!(disks[0].health.as_deref(), Some("ok"));
        assert_eq!(disks[0].firmware.as_deref(), Some("V8CR001"));
        assert_eq!(disks[0].mounts, Some(vec!["C:".to_owned()]));
        assert_eq!(disks[0].life_left_pct, None, "wear is null for a normal user");
        assert_eq!(inv.power_plan.as_deref(), Some("Dengeli"));
        assert!(win_script_errors(&root).is_empty());
        let with_errors = json!({"err": "Cannot convert value \"NVMe\" to type \"System.Int32\"."});
        assert_eq!(win_script_errors(&with_errors).len(), 1);
    }

    #[test]
    fn text_enum_values_of_powershell_are_mapped() {
        let real = ps51();
        let t = &real["text_values"];
        let disk = json!([{ "id": t["DeviceId"], "model": "X", "bus": t["BusType"],
            "media": t["MediaType"], "health": t["HealthStatus"] }]);
        let disks = win_inventory(&json!({ "disk": disk })).physical_disks.unwrap();
        assert_eq!(disks[0].bus.as_deref(), Some("nvme"));
        assert_eq!(disks[0].media.as_deref(), Some("ssd"));
        assert_eq!(disks[0].health.as_deref(), Some("ok"));
        assert_eq!(win_bus_text("SATA"), Some("sata"));
        assert_eq!(win_bus_text("Unknown"), None);
        assert_eq!(win_bus_text("Storage Spaces"), Some("other"));
        assert_eq!(win_media_text("HDD"), Some("hdd"));
        assert_eq!(win_media_text("Unspecified"), None);
        assert_eq!(win_health_text("Unhealthy"), Some("failing"));
        assert_eq!(win_health_text("Warning"), Some("warning"));
        // Numbers sent as text are still numbers.
        let disks = win_inventory(&json!({ "disk": [{"id": "1", "model": "Y", "bus": "11", "media": "3"}] }))
            .physical_disks
            .unwrap();
        assert_eq!((disks[0].bus.as_deref(), disks[0].media.as_deref()), (Some("sata"), Some("hdd")));
    }

    #[test]
    fn amd_processor_graphics_is_integrated() {
        let real = ps51();
        let gpus = win_inventory(&json!({ "gpu": real["gpu"] })).gpus.unwrap();
        assert_eq!(gpus.len(), 2, "the virtual display adapter is not a card");
        assert_eq!(gpus[0].name, "NVIDIA GeForce RTX 5070 Ti Laptop GPU");
        assert_eq!(gpus[0].integrated, Some(false));
        assert_eq!(gpus[1].name, "AMD Radeon(TM) 610M");
        assert_eq!(gpus[1].integrated, Some(true));
        let amd = "PCI\\VEN_1002&DEV_1681";
        assert_eq!(win_gpu_integrated("AMD Radeon(TM) Graphics", amd), Some(true));
        assert_eq!(win_gpu_integrated("AMD Radeon 780M", amd), Some(true));
        assert_eq!(win_gpu_integrated("Radeon RX Vega 11 Graphics", amd), Some(false));
        assert_eq!(win_gpu_integrated("AMD Radeon RX 7800 XT", amd), Some(false));
        assert_eq!(win_gpu_integrated("AMD Radeon RX6800M", amd), Some(false));
        assert_eq!(win_gpu_integrated("AMD Radeon Pro W6600", amd), Some(false));
        assert_eq!(win_gpu_integrated("AMD Radeon HD 7970", amd), None);
    }

    #[test]
    fn power_plan_names_are_turkish() {
        assert_eq!(
            power_plan_name("Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)"),
            Some("Dengeli".into())
        );
        assert_eq!(
            power_plan_name("Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)"),
            Some("Yüksek performans".into())
        );
        assert_eq!(
            power_plan_name("Power Scheme GUID: a1841308-3541-4fab-bc81-f71556f20b4a  (Power saver)"),
            Some("Güç tasarrufu".into())
        );
        assert_eq!(
            power_plan_name("Power Scheme GUID: e9a42b02-d5df-448d-aa00-03f14749eb61  (Ultimate Performance)"),
            Some("Nihai performans".into())
        );
        // A maker's own plan keeps its name.
        assert_eq!(
            power_plan_name("Power Scheme GUID: 64a64f24-65b9-4b56-befd-5ec1eaced9b3  (ASUS Recommended)"),
            Some("ASUS Recommended".into())
        );
        assert_eq!(power_plan_name("error"), None);
    }

    #[test]
    fn netsh_turkish_percent_and_channel_band() {
        // Real output of a disconnected adapter: no Wi-Fi value.
        let real = ps51();
        assert_eq!(netsh_wifi(real["netsh_disconnected"].as_str().unwrap()), None);
        // Turkish percent sign in front (W12; not seen on a device yet, both forms are read).
        let tr = "    Ad                     : Wi-Fi\n    SSID                   : Ofis\n    Kanal                  : 6\n    Sinyal                 : %54\n";
        let wifi = netsh_wifi(tr).unwrap();
        assert_eq!(wifi.signal_pct, Some(54.0));
        assert_eq!(wifi.band.as_deref(), Some("2.4 GHz"), "Windows 10: band from the channel");
        let en10 = "    Name                   : Wi-Fi\n    SSID                   : Museum\n    Channel                : 44\n    Signal                 : 70%\n";
        assert_eq!(netsh_wifi(en10).unwrap().band.as_deref(), Some("5 GHz"));
        assert_eq!(channel_band(200), None);
    }

    #[test]
    fn mac_wifi_from_system_profiler() {
        // Shape of `system_profiler SPAirPortDataType -json` (macOS 14); to be checked against a
        // device's output (plan §8).
        let root = json!({"SPAirPortDataType": [{"spairport_airport_interfaces": [
            {"_name": "en0", "spairport_current_network_information": {
                "_name": "<redacted>", "spairport_network_channel": "149 (5GHz, 80MHz)",
                "spairport_network_rate": 866, "spairport_signal_noise": "-58 dBm / -94 dBm"}},
            {"_name": "awdl0"}
        ]}]});
        let wifi = mac_wifi(&root).unwrap();
        assert_eq!(wifi.name.as_deref(), Some("en0"));
        assert_eq!(wifi.ssid, None, "a hidden name is not a name");
        assert_eq!(wifi.band.as_deref(), Some("5 GHz"));
        assert_eq!(wifi.signal_pct, Some(84.0));
        assert_eq!(mac_wifi_rate(&root), Some(("en0".to_owned(), 866)));
        assert_eq!(mac_wifi(&json!({"SPAirPortDataType": [{"spairport_airport_interfaces": [{"_name": "en0"}]}]})), None);
        assert_eq!(mac_channel_band("6 (2GHz, 20MHz)").as_deref(), Some("2.4 GHz"));
        assert_eq!(mac_channel_band("37 (6GHz, 160MHz)").as_deref(), Some("6 GHz"));
        assert_eq!(mac_channel_band("36,80").as_deref(), Some("5 GHz"));
        assert_eq!(dbm_to_pct(-40.0), Some(100.0));
        assert_eq!(dbm_to_pct(-110.0), Some(0.0));
    }

    #[test]
    fn mac_ifconfig_link_and_speed() {
        let up = "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tether aa:bb:cc:dd:ee:ff\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\n";
        assert_eq!(mac_ifconfig(up), (Some(true), Some(1000)));
        let ten = "\tmedia: autoselect (10GbaseT <full-duplex>)\n\tstatus: active\n";
        assert_eq!(mac_ifconfig(ten), (Some(true), Some(10_000)));
        let down = "\tmedia: autoselect (none)\n\tstatus: inactive\n";
        assert_eq!(mac_ifconfig(down), (Some(false), None));
        let wifi = "\tmedia: autoselect\n\tstatus: active\n";
        assert_eq!(mac_ifconfig(wifi), (Some(true), None));
    }

    #[test]
    fn mac_extras_fill_the_inventory() {
        let mut inv = mac_inventory(&mac_sample(), None, None);
        let extra = json!({
            "SPInstallHistoryDataType": [
                {"_name": "macOS Sonoma 14.4", "install_date": "2024-03-08T10:00:00Z"},
                {"_name": "XProtectPlistConfigData", "install_date": "2024-06-01T10:00:00Z"},
                {"_name": "macOS Sonoma 14.5", "install_date": "2024-05-20T09:12:33Z"}
            ],
            "SPAirPortDataType": [{"spairport_airport_interfaces": [{"_name": "en1",
                "spairport_current_network_information": {"spairport_network_rate": 573}}]}]
        });
        let links = vec![
            ("en0".to_owned(), Some(true), Some(1000)),
            ("en1".to_owned(), Some(true), None),
        ];
        mac_inventory_extras(&mut inv, &extra, &links);
        assert_eq!(inv.os.unwrap().last_update.as_deref(), Some("2024-05-20"), "apps are not updates");
        let net = inv.network.unwrap();
        assert_eq!((net[0].connected, net[0].speed_mbps), (Some(true), Some(1000)));
        assert_eq!((net[1].connected, net[1].speed_mbps), (Some(true), Some(573)));
    }

    #[test]
    fn vm_stat_available_memory() {
        // Shape of `vm_stat` on Apple Silicon (16 KB pages); to be checked against a device.
        let out = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               10000.\nPages active:                            300000.\nPages inactive:                          200000.\nPages speculative:                         5000.\nPages throttled:                              0.\nPages wired down:                        150000.\nPages purgeable:                           1000.\n";
        // (10000 + 5000 + 200000 + 1000) x 16 KB = 3375 MB
        assert_eq!(vm_stat_available_mb(out), Some(3375));
        assert_eq!(vm_stat_available_mb("nonsense"), None);
    }
}
