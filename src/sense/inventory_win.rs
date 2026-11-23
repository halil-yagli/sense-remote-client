//! Sense Remote (S6): the Windows inventory (fixed facts) through WMI / CIM and the Storage
//! module, read by Windows PowerShell 5.1 (part of every Windows 10 / 11). Our own fixed scripts
//! print one JSON document; `health_parse::win_inventory` / `win_drivers` map it.
//!
//! Why PowerShell and not COM from Rust: the queries span three WMI namespaces and the Storage
//! cmdlets (reliability counters), the output is plain JSON that the pure parser maps and the
//! tests cover on every platform, and no crate has to be added (the build is `--locked`).
//!
//! Cost: a few seconds once at start and every `INVENTORY_INTERVAL`, in a background thread, with
//! a time limit; `Win32_PnPSignedDriver` (slow) runs as its own script with its own limit, so a
//! slow driver list never costs the rest. The service runs as SYSTEM, so the Storage reliability
//! counters (wear) can be read. Scripts are passed as plain text (no encoded command), use only
//! single quotes, and nothing from outside goes into them.
//!
//! The graphics memory size comes from DXGI (`health_win::adapters`): WMI's `AdapterRAM` stops
//! at 4 GB.

use super::{health_cmd, health_model::*, health_parse};
use hbb_common::log;
use std::time::Duration;

const INVENTORY_TIMEOUT: Duration = Duration::from_secs(20);
const DRIVERS_TIMEOUT: Duration = Duration::from_secs(25);

/// `powercfg` runs before the output encoding is switched (its text is read in the console code
/// page); after that everything is written as UTF-8.
const INVENTORY_SCRIPT: &[&str] = &[
    "$ErrorActionPreference='SilentlyContinue'",
    "$o=@{}",
    "$o.plan=(powercfg /getactivescheme) -join ' '",
    "[Console]::OutputEncoding=[Text.Encoding]::UTF8",
    "$o.cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)",
    "$o.gpu=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID,@{n='DriverDate';e={if($_.DriverDate){$_.DriverDate.ToString('yyyy-MM-dd')}}})",
    "$o.mem=@(Get-CimInstance Win32_PhysicalMemory | Select-Object DeviceLocator,Capacity,SMBIOSMemoryType,Speed,ConfiguredClockSpeed,PartNumber,Manufacturer)",
    "$o.slots=(Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum",
    "$o.disk=@(Get-PhysicalDisk | ForEach-Object { $r=($_ | Get-StorageReliabilityCounter); [pscustomobject]@{id=[string]$_.DeviceId;model=$_.FriendlyName;bus=[int]$_.BusType;media=[int]$_.MediaType;size=$_.Size;fw=$_.FirmwareVersion;health=[int]$_.HealthStatus;wear=$r.Wear} })",
    "$o.part=@(Get-Partition | Where-Object { $_.DriveLetter } | ForEach-Object { [pscustomobject]@{d=[string]$_.DiskNumber;l=[string]$_.DriveLetter} })",
    "$o.nic=@(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' | Where-Object { $_.NetConnectionID } | Select-Object Index,NetConnectionID,Name,MACAddress,Speed,NetConnectionStatus)",
    "$o.cfg=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | Select-Object Index,DHCPEnabled,DefaultIPGateway,DNSServerSearchOrder)",
    "$o.board=(Get-CimInstance Win32_BaseBoard | Select-Object -First 1 Manufacturer,Product)",
    "$o.bios=(Get-CimInstance Win32_BIOS | Select-Object -First 1 Manufacturer,SMBIOSBIOSVersion,SerialNumber,@{n='ReleaseDate';e={if($_.ReleaseDate){$_.ReleaseDate.ToString('yyyy-MM-dd')}}})",
    "$o.audio=@(Get-CimInstance Win32_SoundDevice | ForEach-Object { $_.Name })",
    "$o.usb=@(Get-CimInstance Win32_PnPEntity -Filter 'PNPDeviceID LIKE ''USB\\\\VID%''' | ForEach-Object { $_.Name })",
    "$os=Get-CimInstance Win32_OperatingSystem",
    "$cv=Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'",
    "$o.os=[pscustomobject]@{name=$os.Caption;version=$os.Version;build=$os.BuildNumber;host=$os.CSName;ubr=$cv.UBR;dv=$cv.DisplayVersion}",
    "$o.tz=(Get-TimeZone).Id",
    "$o.hotfix=(Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1 | ForEach-Object { $_.InstalledOn.ToString('yyyy-MM-dd') })",
    "ConvertTo-Json -InputObject $o -Depth 5 -Compress",
];

const DRIVERS_SCRIPT: &[&str] = &[
    "$ErrorActionPreference='SilentlyContinue'",
    "[Console]::OutputEncoding=[Text.Encoding]::UTF8",
    "$d=@(Get-CimInstance Win32_PnPSignedDriver -Filter 'DeviceClass=''DISPLAY'' OR DeviceClass=''NET'' OR DeviceClass=''MEDIA'' OR DeviceClass=''SYSTEM''' | Select-Object DeviceClass,DeviceName,DriverVersion,DriverProviderName,@{n='DriverDate';e={if($_.DriverDate){$_.DriverDate.ToString('yyyy-MM-dd')}}})",
    "ConvertTo-Json -InputObject $d -Depth 3 -Compress",
];

/// Windows PowerShell by its fixed path (not through the search path).
fn powershell_path() -> String {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
    format!("{root}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
}

/// Runs one of our fixed scripts and parses its JSON output.
pub(super) fn run_script(lines: &[&str], timeout: Duration) -> Option<serde_json::Value> {
    let script = lines.join("; ");
    let out = health_cmd::run(
        &powershell_path(),
        &[
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &script,
        ],
        timeout,
    )?;
    match serde_json::from_str(out.trim()) {
        Ok(value) => Some(value),
        Err(err) => {
            log::warn!("Sense Remote: inventory script output not JSON: {err}");
            None
        }
    }
}

/// The whole inventory; blocking (seconds). `None` when nothing at all could be read.
pub fn collect() -> Option<Inventory> {
    let root = run_script(INVENTORY_SCRIPT, INVENTORY_TIMEOUT);
    let drivers = run_script(DRIVERS_SCRIPT, DRIVERS_TIMEOUT);
    if root.is_none() && drivers.is_none() {
        return None;
    }
    let mut inventory = root
        .as_ref()
        .map(health_parse::win_inventory)
        .unwrap_or_default();
    inventory.drivers = drivers
        .as_ref()
        .and_then(|d| non_empty(health_parse::win_drivers(d)));
    health_parse::attach_driver_versions(&mut inventory);
    attach_vram(&mut inventory, &super::health_win::adapters());
    Some(inventory)
}

/// DXGI's dedicated memory for the cards of the same name.
fn attach_vram(inventory: &mut Inventory, adapters: &[super::health_win::Adapter]) {
    let Some(gpus) = inventory.gpus.as_mut() else { return };
    for gpu in gpus {
        if let Some(adapter) = adapters
            .iter()
            .find(|a| a.name.eq_ignore_ascii_case(gpu.name.trim()))
        {
            gpu.vram_mb = Some(bytes_to_mb(adapter.vram_bytes)).filter(|mb| *mb > 0);
        }
    }
}
