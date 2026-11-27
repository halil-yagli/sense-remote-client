//! Sense Remote (S6): Windows live values for the heartbeat `health` (with `health_v2`).
//!
//! - Graphics cards: DXGI adapter list (name, LUID, dedicated memory); utilisation and memory in
//!   use from the PDH counters `\GPU Engine(*)\Utilization Percentage` and
//!   `\GPU Adapter Memory(*)\Dedicated Usage` (Windows 10 1709+), joined by LUID. NVIDIA cards
//!   add temperature, fan and power from the driver's `nvidia-smi`; other vendors publish no
//!   documented temperature, so it is not sent.
//! - Disks: read / write bytes per second from `\PhysicalDisk(*)`; NVMe temperature from the
//!   drive's SMART / Health log page (Sürüm 11, W2), other disks' from the Storage reliability
//!   counters (PowerShell, at most every `DISK_TEMP_INTERVAL`, in the background, only when a
//!   disk has no NVMe temperature). Lifetime data written (same NVMe log page,
//!   `nvme_health_log`) only with the panel capability `disk_written`.
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
    PdhAddEnglishCounterW, PdhCloseQuery, PdhCollectQueryData, PdhGetFormattedCounterArrayW,
    PdhOpenQueryW,
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

impl Pdh {
    /// Every counter could be added.
    fn complete(&self) -> bool {
        [
            self.gpu_engine,
            self.gpu_memory,
            self.disk_read,
            self.disk_write,
            self.cpu_performance,
        ]
        .iter()
        .all(|c| !c.is_null())
    }
}

impl Drop for Pdh {
    fn drop(&mut self) {
        // SAFETY: the query was opened by `open_pdh` and is closed once (its counters with it).
        unsafe {
            PdhCloseQuery(self.query);
        }
    }
}

/// Sense Remote (Sürüm 11, W3): the query and when it was last opened. A query that could not be
/// opened, or opened without a counter (graphics driver not ready at start, driver update), is
/// opened again after `PDH_RETRY`; a failed collection opens it again at once, then after
/// `PDH_RETRY` if it keeps failing. Before, a failure stayed until the service restarted.
struct PdhState {
    pdh: Option<Pdh>,
    opened_at: Option<Instant>,
    collect_failures: u32,
}

static PDH: Mutex<PdhState> = Mutex::new(PdhState {
    pdh: None,
    opened_at: None,
    collect_failures: 0,
});

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
    let mut state = PDH.lock().unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    let complete = state.pdh.as_ref().is_some_and(Pdh::complete);
    if pdh_reopen_due(state.opened_at, complete, now) {
        let again = state.opened_at.is_some();
        state.pdh = None; // closes the old query
        state.pdh = open_pdh();
        state.opened_at = Some(Instant::now());
        match state.pdh.as_ref() {
            Some(pdh) if pdh.complete() => {
                if again {
                    log::info!("Sense Remote: PDH counters opened again");
                }
            }
            Some(_) => log::warn!(
                "Sense Remote: PDH counter missing, tried again in {}s",
                PDH_RETRY.as_secs()
            ),
            None => log::warn!(
                "Sense Remote: PDH query not opened, tried again in {}s",
                PDH_RETRY.as_secs()
            ),
        }
    }
    let query = state.pdh.as_ref()?.query;
    // SAFETY: query handle from `open_pdh`, used under the lock.
    if unsafe { PdhCollectQueryData(query) } != 0 {
        state.collect_failures += 1;
        log::warn!(
            "Sense Remote: PDH collection failed ({}), the query is opened again",
            state.collect_failures
        );
        state.pdh = None;
        // First failure: open again at the next health; repeated: after `PDH_RETRY`.
        state.opened_at = (state.collect_failures > 1).then_some(now);
        return None;
    }
    state.collect_failures = 0;
    let pdh = state.pdh.as_ref()?;
    // SAFETY: handles from `open_pdh`, used under the lock.
    unsafe {
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

/// Temperatures from the Storage reliability counters. Sense Remote (Sürüm 11, W2 / W17): the
/// PowerShell script only runs when a disk has no temperature from its NVMe log page (SATA,
/// USB); on a computer with only NVMe disks no PowerShell is started for it at all.
fn disk_temps(needed: bool) -> HashMap<String, f64> {
    let mut state = DISK_TEMPS.lock().unwrap_or_else(|e| e.into_inner());
    let due = needed
        && !state.running
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

/// SMART / Health log page 2 of NVMe disk number `disk` via `IOCTL_STORAGE_QUERY_PROPERTY` on
/// the PhysicalDriveN device: lifetime data written (Sürüm 9) and, Sürüm 11 (W2), the composite
/// temperature, so NVMe disks need no PowerShell for it. The handle is opened with no access
/// rights (a query needs none); the service runs as SYSTEM anyway. SATA, USB bridges and RAID
/// volumes refuse the request, so they stay "not read" (nothing is estimated).
fn nvme_health_log(disk: u32) -> Option<Vec<u8>> {
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
        // A page with neither a written total nor a temperature is an empty answer.
        if let Some(page) = output
            .get(start..end)
            .filter(|page| nvme_written_bytes(page).is_some() || nvme_temp_c(page).is_some())
        {
            return Some(page.to_vec());
        }
    }
    None
}

/// What one NVMe log page gives: temperature (always) and the lifetime total written (only with
/// the panel capability `disk_written`, `with_written`).
fn nvme_values(disk: &str, with_written: bool) -> (Option<f64>, Option<f64>) {
    let Some(page) = disk.parse::<u32>().ok().and_then(nvme_health_log) else {
        return (None, None);
    };
    let written = with_written
        .then(|| nvme_written_bytes(&page).and_then(written_gb))
        .flatten();
    (nvme_temp_c(&page), written)
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

/// Sense Remote (Sürüm 11, #119): `netsh` runs at most every `WIFI_INTERVAL` (it ran at every
/// health, every 8 s with a session); a time-out keeps the last reading for `LIVE_KEEP`, an
/// answer without Wi-Fi (disconnected, no adapter) clears it.
fn wifi() -> Option<WifiLive> {
    let mut state = WIFI.lock().unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    if state.0.is_some_and(|at| now.saturating_duration_since(at) < WIFI_INTERVAL) {
        return state.1.get(now, LIVE_KEEP);
    }
    state.0 = Some(now);
    match health_cmd::run(&system32("netsh.exe"), &["wlan", "show", "interfaces"], TOOL_TIMEOUT) {
        Some(out) => match health_parse::netsh_wifi(&out) {
            Some(wifi) => state.1.update(now, Some(wifi), LIVE_KEEP),
            None => {
                state.1.clear();
                None
            }
        },
        None => state.1.get(now, LIVE_KEEP),
    }
}

const WIFI_INTERVAL: Duration = Duration::from_secs(60);
static WIFI: Mutex<(Option<Instant>, Kept<WifiLive>)> = Mutex::new((None, Kept::new()));

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

    let mut cpu_mhz = None;
    if let Some(sample) = &sample {
        // Sense Remote (Sürüm 9, O8): lifetime data written, only with the panel capability
        // `disk_written`; disks that do not answer (SATA, USB, RAID) send no value. Sürüm 11
        // (W2): the NVMe temperature comes from the same log page.
        let with_written = super::report_sig::panel_has(CAP_DISK_WRITTEN);
        let mut disks: Vec<DiskLive> = sample
            .disks
            .iter()
            .map(|(id, (read, write))| {
                let (temp_c, written_gb) = nvme_values(id, with_written);
                DiskLive {
                    id: id.clone(),
                    read_bps: *read,
                    write_bps: *write,
                    temp_c,
                    written_gb,
                    ..Default::default()
                }
            })
            .collect();
        let temps = disk_temps(disks.is_empty() || disks.iter().any(|d| d.temp_c.is_none()));
        for disk in &mut disks {
            disk.temp_c = disk.temp_c.or_else(|| temps.get(&disk.id).copied());
        }
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
        health.physical_disks = non_empty(disks);
        cpu_mhz = match (sample.cpu_performance_pct, base_mhz) {
            (Some(perf), Some(base)) => mhz(perf * base as f64 / 100.0),
            _ => None,
        };
    }
    // Sense Remote (Sürüm 11, #119): one missed sample keeps the last clock for `LIVE_KEEP`.
    health.cpu_mhz = CPU_MHZ
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .update(Instant::now(), cpu_mhz, LIVE_KEEP);
    health.wifi = wifi();
}

static CPU_MHZ: Mutex<Kept<u32>> = Mutex::new(Kept::new());
