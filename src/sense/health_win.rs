//! Sense Remote (S6): Windows live values for the heartbeat `health` (with `health_v2`).
//!
//! - Graphics cards: DXGI adapter list (name, LUID, dedicated memory); utilisation and memory in
//!   use from the PDH counters `\GPU Engine(*)\Utilization Percentage` and
//!   `\GPU Adapter Memory(*)\Dedicated Usage` (Windows 10 1709+), joined by LUID. NVIDIA cards
//!   add temperature, fan and power from the driver's `nvidia-smi`; other vendors publish no
//!   documented temperature, so it is not sent.
//! - Disks: read / write bytes per second from `\PhysicalDisk(*)`; temperature from the Storage
//!   reliability counters (PowerShell, at most every `DISK_TEMP_INTERVAL`, in the background).
//!   Lifetime data written (NVMe SMART log, `nvme_written_gb`) only with the panel capability
//!   `disk_written`.
//! - CPU current clock: `\Processor Information(_Total)\% Processor Performance` x base clock
//!   (inventory).
//! - Wi-Fi: `netsh wlan show interfaces` (SSID needs location access on Windows 11 24H2; without
//!   it only the signal / band are read).
//!
//! The PDH query stays open between heartbeats, so the rates are averages since the previous
//! health (about a minute). English counter names (`PdhAddEnglishCounterW`) work on every
//! display language.

use super::{health_cmd, health_model::*, health_parse};
use hbb_common::log;
use std::{
    collections::HashMap,
    path::Path,
    ptr,
    sync::Mutex,
    time::{Duration, Instant},
};
use winapi::um::pdh::{
    PdhAddEnglishCounterW, PdhCollectQueryData, PdhGetFormattedCounterArrayW, PdhOpenQueryW,
    PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_FMT_NOCAP100, PDH_HCOUNTER, PDH_HQUERY,
};

const PDH_MORE_DATA: u32 = 0x8000_07D2;
/// PDH_CSTATUS_VALID_DATA / PDH_CSTATUS_NEW_DATA
const PDH_CSTATUS_OK_MAX: u32 = 1;
const ADAPTERS_TTL: Duration = Duration::from_secs(10 * 60);
const DISK_TEMP_INTERVAL: Duration = Duration::from_secs(5 * 60);
/// Older disk temperatures are not sent.
const DISK_TEMP_MAX_AGE: Duration = Duration::from_secs(15 * 60);
const TOOL_TIMEOUT: Duration = Duration::from_secs(5);
const DISK_TEMP_TIMEOUT: Duration = Duration::from_secs(15);
const VENDOR_NVIDIA: u32 = 0x10DE;
const VENDOR_MICROSOFT: u32 = 0x1414;

const DISK_TEMP_SCRIPT: &[&str] = &[
    "$ErrorActionPreference='SilentlyContinue'",
    "$t=@(Get-PhysicalDisk | ForEach-Object { $r=($_ | Get-StorageReliabilityCounter); [pscustomobject]@{id=[string]$_.DeviceId;temp=$r.Temperature} })",
    "ConvertTo-Json -InputObject $t -Compress",
];

/// One graphics adapter from DXGI.
#[derive(Debug, Clone)]
pub struct Adapter {
    pub name: String,
    pub luid: u64,
    pub vendor: u32,
    pub vram_bytes: u64,
}

static ADAPTERS: Mutex<Option<(Instant, Vec<Adapter>)>> = Mutex::new(None);

/// Hardware adapters (no software renderer, no Microsoft remote / basic adapter, no virtual
/// display driver). Cached for `ADAPTERS_TTL`.
pub fn adapters() -> Vec<Adapter> {
    let mut cache = ADAPTERS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, list)) = cache.as_ref() {
        if at.elapsed() < ADAPTERS_TTL {
            return list.clone();
        }
    }
    let list = read_adapters();
    *cache = Some((Instant::now(), list.clone()));
    list
}

fn read_adapters() -> Vec<Adapter> {
    use windows::Win32::Graphics::Dxgi::{
        CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE,
    };
    let mut out = Vec::new();
    // SAFETY: plain DXGI enumeration; every returned interface is released on drop.
    unsafe {
        let factory: IDXGIFactory1 = match CreateDXGIFactory1() {
            Ok(factory) => factory,
            Err(err) => {
                log::debug!("Sense Remote: DXGI factory unavailable: {err}");
                return out;
            }
        };
        let mut index = 0u32;
        while let Ok(adapter) = factory.EnumAdapters1(index) {
            index += 1;
            let Ok(desc) = adapter.GetDesc1() else { continue };
            let software = desc.Flags & (DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32) != 0;
            let len = desc.Description.iter().position(|c| *c == 0).unwrap_or(128);
            let Some(name) = text(&String::from_utf16_lossy(&desc.Description[..len])) else {
                continue;
            };
            if software || desc.VendorId == VENDOR_MICROSOFT || is_virtual_display(&name) {
                continue;
            }
            let luid = ((desc.AdapterLuid.HighPart as u32 as u64) << 32)
                | desc.AdapterLuid.LowPart as u64;
            if out.iter().any(|a: &Adapter| a.luid == luid) {
                continue;
            }
            out.push(Adapter {
                name,
                luid,
                vendor: desc.VendorId,
                vram_bytes: desc.DedicatedVideoMemory as u64,
            });
            if out.len() >= MAX_ITEMS {
                break;
            }
        }
    }
    out
}

fn is_virtual_display(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    ["idd", "virtual display", "remote display", "parsec", "spacedesk"]
        .iter()
        .any(|k| lower.contains(k))
}

// ---------------------------------------------------------------------------------------------
// PDH
// ---------------------------------------------------------------------------------------------

struct Pdh {
    query: PDH_HQUERY,
    gpu_engine: PDH_HCOUNTER,
    gpu_memory: PDH_HCOUNTER,
    disk_read: PDH_HCOUNTER,
    disk_write: PDH_HCOUNTER,
    cpu_performance: PDH_HCOUNTER,
}

// SAFETY: the handles are only used under `PDH`'s lock; PDH handles are not tied to a thread.
unsafe impl Send for Pdh {}

/// Opened on first use; `None` inside when PDH cannot be opened (then nothing is retried).
static PDH: Mutex<Option<Option<Pdh>>> = Mutex::new(None);

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe fn add_counter(query: PDH_HQUERY, path: &str) -> PDH_HCOUNTER {
    let mut counter: PDH_HCOUNTER = ptr::null_mut();
    let path = wide(path);
    if PdhAddEnglishCounterW(query, path.as_ptr(), 0, &mut counter) != 0 {
        log::debug!("Sense Remote: PDH counter not available");
        return ptr::null_mut();
    }
    counter
}

fn open_pdh() -> Option<Pdh> {
    // SAFETY: PDH calls with valid out pointers; the query lives for the process.
    unsafe {
        let mut query: PDH_HQUERY = ptr::null_mut();
        if PdhOpenQueryW(ptr::null(), 0, &mut query) != 0 {
            log::warn!("Sense Remote: PdhOpenQueryW failed");
            return None;
        }
        let pdh = Pdh {
            query,
            gpu_engine: add_counter(query, "\\GPU Engine(*)\\Utilization Percentage"),
            gpu_memory: add_counter(query, "\\GPU Adapter Memory(*)\\Dedicated Usage"),
            disk_read: add_counter(query, "\\PhysicalDisk(*)\\Disk Read Bytes/sec"),
            disk_write: add_counter(query, "\\PhysicalDisk(*)\\Disk Write Bytes/sec"),
            cpu_performance: add_counter(
                query,
                "\\Processor Information(_Total)\\% Processor Performance",
            ),
        };
        // Rate counters need two samples; the first health waits once for the second one.
        PdhCollectQueryData(query);
        std::thread::sleep(Duration::from_secs(1));
        Some(pdh)
    }
}

/// All instances of a counter as `(instance name, value)`; empty when unavailable.
unsafe fn counter_array(counter: PDH_HCOUNTER) -> Vec<(String, f64)> {
    if counter.is_null() {
        return Vec::new();
    }
    let format = PDH_FMT_DOUBLE | PDH_FMT_NOCAP100;
    for _ in 0..3 {
        let (mut size, mut count) = (0u32, 0u32);
        let status =
            PdhGetFormattedCounterArrayW(counter, format, &mut size, &mut count, ptr::null_mut());
        if status as u32 != PDH_MORE_DATA || size == 0 {
            return Vec::new();
        }
        // u64 storage keeps the items 8-byte aligned.
        let mut buffer = vec![0u64; (size as usize + 7) / 8];
        let items = buffer.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
        let status = PdhGetFormattedCounterArrayW(counter, format, &mut size, &mut count, items);
        if status as u32 == PDH_MORE_DATA {
            continue; // instances appeared in between
        }
        if status != 0 {
            return Vec::new();
        }
        return std::slice::from_raw_parts(items, count as usize)
            .iter()
            .filter(|item| item.FmtValue.CStatus <= PDH_CSTATUS_OK_MAX)
            .filter_map(|item| {
                let name = wide_c_string(item.szName)?;
                Some((name, *item.FmtValue.u.doubleValue()))
            })
            .collect();
    }
    Vec::new()
}

unsafe fn wide_c_string(ptr: *const u16) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let mut len = 0usize;
    while *ptr.add(len) != 0 && len < 1024 {
        len += 1;
    }
    Some(String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len)))
}

struct PdhSample {
    gpu_util: HashMap<u64, f64>,
    gpu_memory: HashMap<u64, u64>,
    disks: HashMap<String, (Option<u64>, Option<u64>)>,
    cpu_performance_pct: Option<f64>,
}

fn sample_pdh() -> Option<PdhSample> {
    let mut guard = PDH.lock().unwrap_or_else(|e| e.into_inner());
    let pdh = guard.get_or_insert_with(open_pdh).as_ref()?;
    // SAFETY: handles from `open_pdh`, used under the lock.
    unsafe {
        if PdhCollectQueryData(pdh.query) != 0 {
            return None;
        }
        let engines = counter_array(pdh.gpu_engine);
        let gpu_util = gpu_util_by_luid(engines.iter().map(|(n, v)| (n.as_str(), *v)));
        let mut gpu_memory: HashMap<u64, u64> = HashMap::new();
        for (instance, value) in counter_array(pdh.gpu_memory) {
            if let (Some(luid), Some(bytes)) = (parse_luid(&instance), bps(value)) {
                *gpu_memory.entry(luid).or_default() += bytes;
            }
        }
        let mut disks: HashMap<String, (Option<u64>, Option<u64>)> = HashMap::new();
        for (instance, value) in counter_array(pdh.disk_read) {
            if let Some(id) = physical_disk_id(&instance) {
                disks.entry(id).or_default().0 = bps(value);
            }
        }
        for (instance, value) in counter_array(pdh.disk_write) {
            if let Some(id) = physical_disk_id(&instance) {
                disks.entry(id).or_default().1 = bps(value);
            }
        }
        let cpu_performance_pct = counter_array(pdh.cpu_performance)
            .into_iter()
            .map(|(_, v)| v)
            .find(|v| v.is_finite() && *v > 0.0 && *v < 1000.0);
        Some(PdhSample {
            gpu_util,
            gpu_memory,
            disks,
            cpu_performance_pct,
        })
    }
}

// ---------------------------------------------------------------------------------------------
// Disk temperatures (background, every DISK_TEMP_INTERVAL)
// ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct DiskTemps {
    started: Option<Instant>,
    running: bool,
    read_at: Option<Instant>,
    values: Vec<(String, f64)>,
}

static DISK_TEMPS: Mutex<DiskTemps> = Mutex::new(DiskTemps {
    started: None,
    running: false,
    read_at: None,
    values: Vec::new(),
});

fn disk_temps() -> HashMap<String, f64> {
    let mut state = DISK_TEMPS.lock().unwrap_or_else(|e| e.into_inner());
    let due = !state.running
        && state
            .started
            .map_or(true, |t| t.elapsed() >= DISK_TEMP_INTERVAL);
    if due {
        state.running = true;
        state.started = Some(Instant::now());
        std::thread::spawn(|| {
            let values = super::inventory_win::run_script(DISK_TEMP_SCRIPT, DISK_TEMP_TIMEOUT)
                .map(|v| health_parse::win_disk_temps(&v));
            let mut state = DISK_TEMPS.lock().unwrap_or_else(|e| e.into_inner());
            state.running = false;
            if let Some(values) = values {
                state.values = values;
                state.read_at = Some(Instant::now());
            }
        });
    }
    match state.read_at {
        Some(at) if at.elapsed() <= DISK_TEMP_MAX_AGE => state.values.iter().cloned().collect(),
        _ => HashMap::new(),
    }
}


// ---------------------------------------------------------------------------------------------
// Total written (Sense Remote Sürüm 9, O8): NVMe SMART / Health log page
// ---------------------------------------------------------------------------------------------

/// Lifetime data written by NVMe disk number `disk` (GB), from the drive's SMART / Health log
/// page 2 via `IOCTL_STORAGE_QUERY_PROPERTY` on the PhysicalDriveN device. The handle is opened with
/// no access rights (a query needs none); the service runs as SYSTEM anyway. SATA, USB bridges
/// and RAID volumes refuse the request, so they stay "not read" (nothing is estimated).
fn nvme_written_gb(disk: u32) -> Option<f64> {
    /// Device path of the physical disk (raw string: the prefix is two backslashes, a dot, one).
    fn device_path(disk: u32) -> String {
        format!("{}{disk}", r"\\.\PhysicalDrive")
    }

    use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
    use windows::Win32::{Foundation::HANDLE, System::IO::DeviceIoControl};

    const IOCTL_STORAGE_QUERY_PROPERTY: u32 = 0x002D_1400;
    const STORAGE_DEVICE_PROTOCOL_SPECIFIC_PROPERTY: u32 = 50;
    const PROTOCOL_TYPE_NVME: u32 = 3;
    const NVME_DATA_TYPE_LOG_PAGE: u32 = 2;
    const NVME_LOG_PAGE_HEALTH_INFO: u32 = 2;
    /// STORAGE_PROPERTY_QUERY header (id + query type) and STORAGE_PROTOCOL_SPECIFIC_DATA.
    const QUERY_HEADER: usize = 8;
    const SPECIFIC_DATA: usize = 40;
    const LOG_LEN: usize = 512;

    let file = std::fs::OpenOptions::new()
        .access_mode(0)
        .share_mode(3)
        .open(device_path(disk))
        .ok()?;
    let handle = HANDLE(file.as_raw_handle());
    // Namespace 0 first (Microsoft's sample), then "all namespaces" (what some tools send).
    for namespace in [0u32, 0xFFFF_FFFF] {
        let mut input = vec![0u8; QUERY_HEADER + SPECIFIC_DATA];
        let mut put = |at: usize, value: u32| input[at..at + 4].copy_from_slice(&value.to_le_bytes());
        put(0, STORAGE_DEVICE_PROTOCOL_SPECIFIC_PROPERTY);
        put(4, 0); // PropertyStandardQuery
        put(QUERY_HEADER, PROTOCOL_TYPE_NVME);
        put(QUERY_HEADER + 4, NVME_DATA_TYPE_LOG_PAGE);
        put(QUERY_HEADER + 8, NVME_LOG_PAGE_HEALTH_INFO);
        put(QUERY_HEADER + 12, namespace);
        put(QUERY_HEADER + 16, SPECIFIC_DATA as u32); // ProtocolDataOffset
        put(QUERY_HEADER + 20, LOG_LEN as u32); // ProtocolDataLength
        let mut output = vec![0u8; 1024];
        let mut returned = 0u32;
        let ok = unsafe {
            DeviceIoControl(
                handle,
                IOCTL_STORAGE_QUERY_PROPERTY,
                Some(input.as_ptr() as *const std::ffi::c_void),
                input.len() as u32,
                Some(output.as_mut_ptr() as *mut std::ffi::c_void),
                output.len() as u32,
                Some(&mut returned),
                None,
            )
        }
        .is_ok();
        if !ok {
            continue;
        }
        // STORAGE_PROTOCOL_DATA_DESCRIPTOR: 8 bytes, then the specific data whose
        // `ProtocolDataOffset` (+16) / `ProtocolDataLength` (+20) locate the log page.
        let word = |at: usize| -> Option<usize> {
            let raw: [u8; 4] = output.get(at..at + 4)?.try_into().ok()?;
            Some(u32::from_le_bytes(raw) as usize)
        };
        let (Some(offset), Some(len)) = (word(8 + 16), word(8 + 20)) else {
            continue;
        };
        let start = 8usize.saturating_add(offset);
        let end = start.saturating_add(len.min(LOG_LEN)).min(returned as usize);
        if let Some(gb) = output
            .get(start..end)
            .and_then(nvme_written_bytes)
            .and_then(written_gb)
        {
            return Some(gb);
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------------------------

fn system32(tool: &str) -> String {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
    format!("{root}\\System32\\{tool}")
}

fn nvidia_smi() -> Vec<GpuLive> {
    let program_files =
        std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".to_owned());
    let candidates = [
        system32("nvidia-smi.exe"),
        format!("{program_files}\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe"),
    ];
    let Some(path) = candidates.iter().find(|p| Path::new(p.as_str()).exists()) else {
        return Vec::new();
    };
    health_cmd::run(
        path,
        &[
            "--query-gpu=name,temperature.gpu,fan.speed,power.draw,utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ],
        TOOL_TIMEOUT,
    )
    .map(|out| health_parse::nvidia_smi(&out))
    .unwrap_or_default()
}

fn wifi() -> Option<WifiLive> {
    let out = health_cmd::run(
        &system32("netsh.exe"),
        &["wlan", "show", "interfaces"],
        TOOL_TIMEOUT,
    )?;
    health_parse::netsh_wifi(&out)
}

// ---------------------------------------------------------------------------------------------
// Live values
// ---------------------------------------------------------------------------------------------

/// Windows part of the v2 live values. `base_mhz` from the inventory (for the current clock).
pub fn extend(health: &mut super::report::SenseHealth, base_mhz: Option<u32>) {
    let sample = sample_pdh();
    let adapters = adapters();
    let mut gpus: Vec<GpuLive> = adapters
        .iter()
        .map(|a| GpuLive {
            name: Some(a.name.clone()),
            util_pct: sample.as_ref().and_then(|s| s.gpu_util.get(&a.luid).copied()).and_then(pct),
            vram_used_mb: sample
                .as_ref()
                .and_then(|s| s.gpu_memory.get(&a.luid).copied())
                .map(bytes_to_mb),
            vram_total_mb: Some(bytes_to_mb(a.vram_bytes)).filter(|mb| *mb > 0),
            ..Default::default()
        })
        .collect();
    if adapters.iter().any(|a| a.vendor == VENDOR_NVIDIA) {
        for smi in nvidia_smi() {
            let Some(name) = smi.name.as_deref() else { continue };
            let same = |g: &GpuLive| g.name.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(name));
            // Sürüm 10 (#117): of two adapters with this name, the one with counters gets the
            // driver's values (the other is a duplicate `dedupe_gpus` drops).
            let at = gpus
                .iter()
                .position(|g| same(g) && (g.util_pct.is_some() || g.vram_used_mb.is_some()))
                .or_else(|| gpus.iter().position(|g| same(g)));
            if let Some(gpu) = at.and_then(|i| gpus.get_mut(i)) {
                gpu.temp_c = smi.temp_c;
                gpu.fan_pct = smi.fan_pct;
                gpu.power_w = smi.power_w;
                gpu.util_pct = gpu.util_pct.or(smi.util_pct);
                gpu.vram_used_mb = gpu.vram_used_mb.or(smi.vram_used_mb);
                gpu.vram_total_mb = gpu.vram_total_mb.or(smi.vram_total_mb);
            }
        }
    }
    // Sürüm 10 (#117): a card DXGI lists twice is sent once.
    let mut gpus = dedupe_gpus(gpus);
    let (gpu_pct, gpu_temp) = gpu_summary(&gpus);
    health.gpu_pct = gpu_pct;
    health.gpu_temp_c = gpu_temp;
    gpus.retain(|g| *g != GpuLive { name: g.name.clone(), ..Default::default() });
    health.gpus = non_empty(gpus);

    let temps = disk_temps();
    if let Some(sample) = &sample {
        let mut disks: Vec<DiskLive> = sample
            .disks
            .iter()
            .map(|(id, (read, write))| DiskLive {
                id: id.clone(),
                read_bps: *read,
                write_bps: *write,
                temp_c: temps.get(id).copied(),
                // Sense Remote (Sürüm 9): written_gb is filled below (NVMe SMART).
                ..Default::default()
            })
            .collect();
        for (id, temp) in &temps {
            if !disks.iter().any(|d| &d.id == id) {
                disks.push(DiskLive {
                    id: id.clone(),
                    temp_c: Some(*temp),
                    ..Default::default()
                });
            }
        }
        disks.sort_by(|a, b| a.id.cmp(&b.id));
        disks.truncate(MAX_ITEMS);
        // Sense Remote (Sürüm 9, O8): lifetime data written, only with the panel capability
        // `disk_written`; disks that do not answer (SATA, USB, RAID) send no value.
        if super::report_sig::panel_has(CAP_DISK_WRITTEN) {
            for disk in &mut disks {
                disk.written_gb = disk.id.parse::<u32>().ok().and_then(nvme_written_gb);
            }
        }
        health.physical_disks = non_empty(disks);
        health.cpu_mhz = match (sample.cpu_performance_pct, base_mhz) {
            (Some(perf), Some(base)) => mhz(perf * base as f64 / 100.0),
            _ => None,
        };
    }
    health.wifi = wifi();
}
