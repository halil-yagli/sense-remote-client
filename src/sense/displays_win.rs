//! Sense Remote: per-display details from the Windows display configuration (CCD) API
//! (`QueryDisplayConfig` + `DisplayConfigGetDeviceInfo`) for the panel's display info:
//! connection type, refresh rate, bit depth, color format, HDR, native resolution, monitor name.
//!
//! Only raw values are read here; mapping them to the panel contract is in `report.rs` (pure,
//! tested on every platform). Every value that cannot be read stays `None` and is not sent.
//!
//! The structs are declared here instead of taken from `winapi` / `windows` so that their layout
//! is checked at compile time (size asserts below) and no crate feature has to be added; the
//! same API is used with hand-written declarations in `libs/scrap/src/dxgi/hdr.rs`.
//!
//! Sense Remote (Sürüm 10, #118): the scale ("Ölçek", 100 / 125 / 150 %) of each display from its
//! effective DPI (`GetDpiForMonitor`, read with this thread switched to per-monitor DPI awareness
//! so Windows does not answer 96 for every monitor). Where the switch is not available (Windows
//! before 10 1607) no scale is sent.
//!
//! Session 0: the CCD API describes the displays of the calling process's session. The sync
//! loop runs in the `--server` process in the console session, so it sees the user's displays.
//! Called from the Windows service itself (Session 0) it returns no paths or only a virtual
//! adapter; at the lock screen / during a user switch the list can be empty.
//!
//! Sense Remote (Sürüm 11, W4): at the lock screen / UAC the `--server` thread is on the
//! `Default` desktop and `QueryDisplayConfig` answers `ERROR_ACCESS_DENIED` (Microsoft: a caller
//! without access to the current desktop). Then the last good details are sent again
//! (`winos::display_details_kept`), so the panel does not lose name, refresh rate, HDR and scale
//! while the Host is locked; the error code is logged once per stretch.

// Sense Remote: the FFI structs mirror the SDK layout; not every field is read.
#![allow(dead_code)]

use super::report::DisplayDetails;
use std::{collections::HashMap, mem, ptr};

const QDC_ONLY_ACTIVE_PATHS: u32 = 0x2;
const ERROR_SUCCESS: i32 = 0;
const ERROR_INSUFFICIENT_BUFFER: i32 = 122;

// DISPLAYCONFIG_DEVICE_INFO_TYPE
const GET_SOURCE_NAME: u32 = 1;
const GET_TARGET_NAME: u32 = 2;
const GET_TARGET_PREFERRED_MODE: u32 = 3;
const GET_ADVANCED_COLOR_INFO: u32 = 9;

#[repr(C)]
#[derive(Clone, Copy)]
struct Luid {
    low_part: u32,
    high_part: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Rational {
    numerator: u32,
    denominator: u32,
}

/// DISPLAYCONFIG_PATH_SOURCE_INFO
#[repr(C)]
#[derive(Clone, Copy)]
struct PathSourceInfo {
    adapter_id: Luid,
    id: u32,
    mode_info_idx: u32,
    status_flags: u32,
}

/// DISPLAYCONFIG_PATH_TARGET_INFO
#[repr(C)]
#[derive(Clone, Copy)]
struct PathTargetInfo {
    adapter_id: Luid,
    id: u32,
    mode_info_idx: u32,
    output_technology: u32,
    rotation: u32,
    scaling: u32,
    refresh_rate: Rational,
    scan_line_ordering: u32,
    target_available: i32,
    status_flags: u32,
}

/// DISPLAYCONFIG_PATH_INFO
#[repr(C)]
#[derive(Clone, Copy)]
struct PathInfo {
    source_info: PathSourceInfo,
    target_info: PathTargetInfo,
    flags: u32,
}

/// DISPLAYCONFIG_MODE_INFO; the union body is not read, only its size and alignment matter.
#[repr(C)]
#[derive(Clone, Copy)]
struct ModeInfo {
    info_type: u32,
    id: u32,
    adapter_id: Luid,
    body: [u64; 6],
}

/// DISPLAYCONFIG_DEVICE_INFO_HEADER
#[repr(C)]
#[derive(Clone, Copy)]
struct Header {
    kind: u32,
    size: u32,
    adapter_id: Luid,
    id: u32,
}

/// DISPLAYCONFIG_SOURCE_DEVICE_NAME
#[repr(C)]
#[derive(Clone, Copy)]
struct SourceDeviceName {
    header: Header,
    view_gdi_device_name: [u16; 32],
}

/// DISPLAYCONFIG_TARGET_DEVICE_NAME
#[repr(C)]
#[derive(Clone, Copy)]
struct TargetDeviceName {
    header: Header,
    flags: u32,
    output_technology: u32,
    edid_manufacture_id: u16,
    edid_product_code_id: u16,
    connector_instance: u32,
    monitor_friendly_device_name: [u16; 64],
    monitor_device_path: [u16; 128],
}

/// DISPLAYCONFIG_TARGET_PREFERRED_MODE; `target_mode` (DISPLAYCONFIG_TARGET_MODE) is not read.
#[repr(C)]
#[derive(Clone, Copy)]
struct TargetPreferredMode {
    header: Header,
    width: u32,
    height: u32,
    target_mode: [u64; 6],
}

/// DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO
#[repr(C)]
#[derive(Clone, Copy)]
struct AdvancedColorInfo {
    header: Header,
    value: u32,
    color_encoding: u32,
    bits_per_color_channel: u32,
}

// Sizes from the Windows SDK (x64). A wrong declaration stops the build instead of corrupting
// memory at run time.
const _: () = assert!(mem::size_of::<PathInfo>() == 72);
const _: () = assert!(mem::size_of::<ModeInfo>() == 64);
const _: () = assert!(mem::size_of::<Header>() == 20);
const _: () = assert!(mem::size_of::<SourceDeviceName>() == 84);
const _: () = assert!(mem::size_of::<TargetDeviceName>() == 420);
const _: () = assert!(mem::size_of::<TargetPreferredMode>() == 80);
const _: () = assert!(mem::size_of::<AdvancedColorInfo>() == 32);

#[link(name = "user32")]
extern "system" {
    fn GetDisplayConfigBufferSizes(flags: u32, num_paths: *mut u32, num_modes: *mut u32) -> i32;
    fn QueryDisplayConfig(
        flags: u32,
        num_paths: *mut u32,
        paths: *mut PathInfo,
        num_modes: *mut u32,
        modes: *mut ModeInfo,
        current_topology_id: *mut u32,
    ) -> i32;
    fn DisplayConfigGetDeviceInfo(request_packet: *mut Header) -> i32;
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

/// MONITORINFOEXW
#[repr(C)]
#[derive(Clone, Copy)]
struct MonitorInfoEx {
    size: u32,
    monitor: Rect,
    work: Rect,
    flags: u32,
    device: [u16; 32],
}

const _: () = assert!(mem::size_of::<MonitorInfoEx>() == 104);

type MonitorEnumProc = unsafe extern "system" fn(isize, isize, *mut Rect, isize) -> i32;

#[link(name = "user32")]
extern "system" {
    fn EnumDisplayMonitors(hdc: isize, clip: *const Rect, callback: MonitorEnumProc, data: isize) -> i32;
    fn GetMonitorInfoW(monitor: isize, info: *mut MonitorInfoEx) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> isize;
    fn GetProcAddress(module: isize, name: *const u8) -> *const std::ffi::c_void;
}

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 / _PER_MONITOR_AWARE
const DPI_CONTEXT_PER_MONITOR_V2: isize = -4;
const DPI_CONTEXT_PER_MONITOR: isize = -3;
const MDT_EFFECTIVE_DPI: u32 = 0;

/// This thread in per-monitor DPI awareness while it lives; the previous context comes back on
/// drop. `SetThreadDpiAwarenessContext` is looked up at run time (Windows 10 1607+), so the
/// program still starts where it is missing.
struct PerMonitorDpi(Option<(unsafe extern "system" fn(isize) -> isize, isize)>);

impl PerMonitorDpi {
    fn enter() -> Self {
        let user32: Vec<u16> = "user32.dll\0".encode_utf16().collect();
        // SAFETY: plain lookups; the pointer is only called with the documented signature.
        unsafe {
            let module = GetModuleHandleW(user32.as_ptr());
            if module == 0 {
                return Self(None);
            }
            let proc = GetProcAddress(module, b"SetThreadDpiAwarenessContext\0".as_ptr());
            if proc.is_null() {
                return Self(None);
            }
            let set: unsafe extern "system" fn(isize) -> isize = mem::transmute(proc);
            let mut old = set(DPI_CONTEXT_PER_MONITOR_V2);
            if old == 0 {
                old = set(DPI_CONTEXT_PER_MONITOR);
            }
            Self((old != 0).then_some((set, old)))
        }
    }

    fn active(&self) -> bool {
        self.0.is_some()
    }
}

impl Drop for PerMonitorDpi {
    fn drop(&mut self) {
        if let Some((set, old)) = self.0 {
            // SAFETY: restores the context this thread had.
            unsafe {
                set(old);
            }
        }
    }
}

/// Effective DPI of every monitor, keyed by GDI device name (`\.\DISPLAY1`). Empty when the
/// thread cannot be made per-monitor aware (the value would be 96 everywhere: not a reading).
fn monitor_dpis() -> HashMap<String, u32> {
    unsafe extern "system" fn each(monitor: isize, _hdc: isize, _rect: *mut Rect, data: isize) -> i32 {
        // SAFETY: `data` is the map passed below, alive for the whole enumeration.
        let out = &mut *(data as *mut HashMap<String, u32>);
        let mut info: MonitorInfoEx = mem::zeroed();
        info.size = mem::size_of::<MonitorInfoEx>() as u32;
        if GetMonitorInfoW(monitor, &mut info) != 0 {
            let (mut x, mut y) = (0u32, 0u32);
            let hr = winapi::um::shellscalingapi::GetDpiForMonitor(
                monitor as winapi::shared::windef::HMONITOR,
                MDT_EFFECTIVE_DPI,
                &mut x,
                &mut y,
            );
            if hr == 0 {
                out.insert(wide_to_string(&info.device), x);
            }
        }
        1
    }
    let mut out: HashMap<String, u32> = HashMap::new();
    let dpi = PerMonitorDpi::enter();
    if !dpi.active() {
        return out;
    }
    // SAFETY: the callback only writes into `out`, which outlives the call.
    unsafe {
        EnumDisplayMonitors(0, ptr::null(), each, &mut out as *mut HashMap<String, u32> as isize);
    }
    drop(dpi);
    out
}

/// Details of every active display, keyed by GDI source name (`\\.\DISPLAY1`), the name
/// `scrap::Display::name()` returns. When the API fails (lock screen, UAC) the last good
/// details; empty when nothing was ever read (e.g. Session 0).
pub fn query() -> HashMap<String, DisplayDetails> {
    let (fresh, error) = query_now();
    super::winos::display_details_kept(fresh, error)
}

/// One reading; the second value is the API's error code when the paths could not be read.
fn query_now() -> (HashMap<String, DisplayDetails>, Option<i32>) {
    let mut out = HashMap::new();
    let paths = match active_paths() {
        Ok(paths) => paths,
        Err(code) => return (out, Some(code)),
    };
    for path in &paths {
        let source = &path.source_info;
        let target = &path.target_info;
        let Some(gdi_name) = source_name(source.adapter_id, source.id) else {
            continue;
        };
        // Clone mode: one source, several targets. The first path wins.
        if out.contains_key(&gdi_name) {
            continue;
        }
        let mut details = DisplayDetails {
            output_technology: Some(target.output_technology),
            refresh: Some((target.refresh_rate.numerator, target.refresh_rate.denominator)),
            ..Default::default()
        };
        if let Some((name, technology)) = target_name(target.adapter_id, target.id) {
            details.name = Some(name);
            details.output_technology = Some(technology);
        }
        details.advanced_color = advanced_color(target.adapter_id, target.id);
        details.native = preferred_mode(target.adapter_id, target.id);
        out.insert(gdi_name, details);
    }
    // Sürüm 10 (#118): the scale by the same GDI name.
    if !out.is_empty() {
        for (name, dpi) in monitor_dpis() {
            if let Some(details) = out.get_mut(&name) {
                details.scale = super::report::scale_from_dpi(dpi);
            }
        }
    }
    (out, None)
}

/// The active paths, or the API's error code (0 when it reported no path).
fn active_paths() -> Result<Vec<PathInfo>, i32> {
    // The configuration can change between the two calls; retry a few times.
    for _ in 0..3 {
        let (mut num_paths, mut num_modes) = (0u32, 0u32);
        // SAFETY: both pointers are valid for writes.
        let rc = unsafe {
            GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut num_paths, &mut num_modes)
        };
        if rc != ERROR_SUCCESS {
            return Err(rc);
        }
        if num_paths == 0 {
            return Err(0);
        }
        // SAFETY: plain C structs; all-zero is a valid value.
        let mut paths = vec![unsafe { mem::zeroed::<PathInfo>() }; num_paths as usize];
        let mut modes = vec![unsafe { mem::zeroed::<ModeInfo>() }; num_modes as usize];
        // SAFETY: the arrays hold `num_paths` / `num_modes` elements, as the API is told.
        let rc = unsafe {
            QueryDisplayConfig(
                QDC_ONLY_ACTIVE_PATHS,
                &mut num_paths,
                paths.as_mut_ptr(),
                &mut num_modes,
                modes.as_mut_ptr(),
                ptr::null_mut(),
            )
        };
        if rc == ERROR_SUCCESS {
            paths.truncate(num_paths as usize);
            return Ok(paths);
        }
        if rc != ERROR_INSUFFICIENT_BUFFER {
            return Err(rc);
        }
    }
    Err(ERROR_INSUFFICIENT_BUFFER)
}

/// Sends one `DisplayConfigGetDeviceInfo` request. `T` must be one of the packet structs above,
/// all `repr(C)` with `Header` as their first field.
fn device_info<T: Copy>(kind: u32, adapter_id: Luid, id: u32) -> Option<T> {
    // SAFETY: plain C struct; all-zero is a valid value.
    let mut packet: T = unsafe { mem::zeroed() };
    let header = Header {
        kind,
        size: mem::size_of::<T>() as u32,
        adapter_id,
        id,
    };
    // SAFETY: `T` starts with `Header` (repr(C)) and is `size` bytes long, which is what the
    // API reads and writes.
    let rc = unsafe {
        let p = &mut packet as *mut T as *mut Header;
        ptr::write(p, header);
        DisplayConfigGetDeviceInfo(p)
    };
    (rc == ERROR_SUCCESS).then_some(packet)
}

fn source_name(adapter_id: Luid, id: u32) -> Option<String> {
    let packet: SourceDeviceName = device_info(GET_SOURCE_NAME, adapter_id, id)?;
    let name = wide_to_string(&packet.view_gdi_device_name);
    (!name.is_empty()).then_some(name)
}

/// (monitor name from EDID, output technology). Built-in panels often have no name.
fn target_name(adapter_id: Luid, id: u32) -> Option<(String, u32)> {
    let packet: TargetDeviceName = device_info(GET_TARGET_NAME, adapter_id, id)?;
    Some((
        wide_to_string(&packet.monitor_friendly_device_name),
        packet.output_technology,
    ))
}

/// (flag bits, color encoding, bits per color channel). Windows 10 1709+.
fn advanced_color(adapter_id: Luid, id: u32) -> Option<(u32, u32, u32)> {
    let packet: AdvancedColorInfo = device_info(GET_ADVANCED_COLOR_INFO, adapter_id, id)?;
    Some((
        packet.value,
        packet.color_encoding,
        packet.bits_per_color_channel,
    ))
}

fn preferred_mode(adapter_id: Luid, id: u32) -> Option<(u32, u32)> {
    let packet: TargetPreferredMode = device_info(GET_TARGET_PREFERRED_MODE, adapter_id, id)?;
    Some((packet.width, packet.height))
}

fn wide_to_string(wide: &[u16]) -> String {
    let end = wide.iter().position(|&c| c == 0).unwrap_or(wide.len());
    String::from_utf16_lossy(&wide[..end]).trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wide_names_stop_at_nul() {
        let mut buf = [0u16; 32];
        for (i, c) in "\\\\.\\DISPLAY2".encode_utf16().enumerate() {
            buf[i] = c;
        }
        assert_eq!(wide_to_string(&buf), "\\\\.\\DISPLAY2");
        assert_eq!(wide_to_string(&[0u16; 4]), "");
    }

    /// Runs the real API on the CI machine: it must not crash, whatever it finds (a runner may
    /// have one virtual display or none).
    #[test]
    fn query_does_not_crash() {
        let _ = monitor_dpis();
        for (name, d) in query() {
            if let Some(scale) = d.scale {
                assert!((1.0..=5.0).contains(&scale), "{scale}");
            }
            assert!(name.starts_with("\\\\.\\"), "{name}");
            if let Some((num, den)) = d.refresh {
                assert!(den == 0 || num / den.max(1) < 100_000);
            }
        }
    }
}
