//! macOS camera for the video call: AVFoundation through `cam_mac.mm` (built with
//! `src/platform/macos.mm`, see `build.rs`).
//!
//! Why not nokhwa's AVFoundation backend (fizibilite R1, checked in the pinned fork
//! `rustdesk-org/nokhwa@c2f7466`, `nokhwa-bindings-macos/src/lib.rs`):
//! - the frame callback rebuilds the sender with `Arc::from_raw` and drops it on every frame,
//!   so the reference count falls by one per frame (use after free within seconds);
//! - NV12 is requested as the 10-bit format (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`)
//!   and frames are copied from the first plane's address with `CVPixelBufferGetDataSize`,
//!   ignoring row padding and the second plane;
//! - every frame is tagged `GRAY` whatever its format, and `frame()` waits on the channel with
//!   no timeout, so a camera that stops would hang the capture thread for good.
//! A compile check would pass all of this; our module asks AVFoundation for packed BGRA, copies
//! rows with their real stride and never blocks without a timeout.
//!
//! Permission: macOS asks once ("Sense Remote kameraya erişmek istiyor"); the text comes from
//! `NSCameraUsageDescription` in Info.plist (package E3). Without that key macOS would kill the
//! process on first camera access, so opening is refused with an error instead.

use super::capture::{desc_label, CamError, CameraInfo, Permission, PixelOrder, Raw, Source};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};

type DeviceCb = extern "C" fn(ctx: *mut c_void, uid: *const c_char, name: *const c_char, kind: i32, max_h: i32);
type FrameCb = extern "C" fn(ctx: *mut c_void, bgra: *const u8, w: i32, h: i32, stride: i32);

extern "C" {
    fn SenseCamMacAuth() -> i32;
    fn SenseCamMacRequestAccess(timeout_ms: u32) -> bool;
    fn SenseCamMacList(cb: DeviceCb, ctx: *mut c_void) -> i32;
    fn SenseCamMacStart(
        uid: *const c_char,
        want_w: i32,
        want_h: i32,
        fps: i32,
        cb: FrameCb,
        ctx: *mut c_void,
        err: *mut i32,
    ) -> *mut c_void;
    fn SenseCamMacStop(handle: *mut c_void);
}

// Codes shared with cam_mac.mm.
const AUTH_MISSING_PLIST: i32 = -1;
const AUTH_NOT_DETERMINED: i32 = 0;
const AUTH_RESTRICTED: i32 = 1;
const AUTH_DENIED: i32 = 2;
const AUTH_AUTHORIZED: i32 = 3;

const ERR_NONE: i32 = 1;
const ERR_DENIED: i32 = 2;
const ERR_BUSY: i32 = 3;
const ERR_PLIST: i32 = 5;

const KIND_BUILT_IN: i32 = 1;
const KIND_EXTERNAL: i32 = 2;
const KIND_CONTINUITY: i32 = 3;

/// How long the permission question may stay open.
const ASK_TIMEOUT_MS: u32 = 60_000;

pub(super) fn kind_label(kind: i32) -> Option<&'static str> {
    match kind {
        KIND_BUILT_IN => Some("Dahili"),
        KIND_EXTERNAL => Some("USB"),
        KIND_CONTINUITY => Some("iPhone"),
        _ => None,
    }
}

pub(super) fn error_of(code: i32) -> CamError {
    match code {
        ERR_NONE => CamError::None,
        ERR_DENIED => CamError::Denied,
        ERR_BUSY => CamError::Busy,
        ERR_PLIST => CamError::Open("Info.plist has no NSCameraUsageDescription".to_owned()),
        c => CamError::Open(format!("avfoundation error {}", c)),
    }
}

pub fn permission() -> Permission {
    match unsafe { SenseCamMacAuth() } {
        AUTH_AUTHORIZED => Permission::Granted,
        AUTH_NOT_DETERMINED => Permission::NotDetermined,
        AUTH_RESTRICTED | AUTH_DENIED => Permission::Denied,
        AUTH_MISSING_PLIST => Permission::Denied,
        _ => Permission::Unknown,
    }
}

extern "C" fn device_cb(ctx: *mut c_void, uid: *const c_char, name: *const c_char, kind: i32, max_h: i32) {
    if ctx.is_null() || uid.is_null() || name.is_null() {
        return;
    }
    let out = unsafe { &mut *(ctx as *mut Vec<CameraInfo>) };
    let id = unsafe { CStr::from_ptr(uid) }.to_string_lossy().into_owned();
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned();
    let max_h = if max_h > 0 { Some(max_h as u32) } else { None };
    out.push(CameraInfo {
        id,
        name,
        desc: desc_label(kind_label(kind), max_h),
    });
}

/// Listing needs no permission.
pub fn list() -> Result<Vec<CameraInfo>, CamError> {
    let mut out: Vec<CameraInfo> = Vec::new();
    unsafe { SenseCamMacList(device_cb, &mut out as *mut Vec<CameraInfo> as *mut c_void) };
    Ok(out)
}

/// The latest frame; AVFoundation's queue writes, the capture thread takes.
struct Slot {
    frame: Mutex<Option<Raw>>,
    cv: Condvar,
}

extern "C" fn frame_cb(ctx: *mut c_void, bgra: *const u8, w: i32, h: i32, stride: i32) {
    if ctx.is_null() || bgra.is_null() || w <= 0 || h <= 0 || stride < w * 4 {
        return;
    }
    let slot = unsafe { &*(ctx as *const Slot) };
    let len = stride as usize * h as usize;
    let data = unsafe { std::slice::from_raw_parts(bgra, len) }.to_vec();
    if let Ok(mut f) = slot.frame.lock() {
        // An unread frame is replaced: the newest one is what counts.
        *f = Some(Raw {
            data,
            width: w as u32,
            height: h as u32,
            stride: stride as usize,
            order: PixelOrder::Bgra,
        });
        slot.cv.notify_one();
    }
}

struct MacSource {
    handle: *mut c_void,
    // Kept alive until `SenseCamMacStop` returned (no callback runs after that).
    slot: Arc<Slot>,
}

impl Source for MacSource {
    fn next(&mut self, timeout: Duration) -> Result<Option<Raw>, CamError> {
        let guard = self
            .slot
            .frame
            .lock()
            .map_err(|_| CamError::Open("lock".to_owned()))?;
        let (mut guard, _) = self
            .slot
            .cv
            .wait_timeout_while(guard, timeout, |f| f.is_none())
            .map_err(|_| CamError::Open("lock".to_owned()))?;
        Ok(guard.take())
    }
}

impl Drop for MacSource {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { SenseCamMacStop(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}

/// Opens the camera (`""` = the system default) on the calling (capture) thread. Asks for the
/// permission first when it was never asked.
pub fn open(id: &str, want_w: u32, want_h: u32, fps: u32) -> Result<Box<dyn Source>, CamError> {
    match unsafe { SenseCamMacAuth() } {
        AUTH_AUTHORIZED => {}
        AUTH_NOT_DETERMINED => {
            if !unsafe { SenseCamMacRequestAccess(ASK_TIMEOUT_MS) } {
                return Err(CamError::Denied);
            }
        }
        AUTH_MISSING_PLIST => return Err(error_of(ERR_PLIST)),
        _ => return Err(CamError::Denied),
    }
    let uid = CString::new(id).map_err(|_| CamError::None)?;
    let slot = Arc::new(Slot {
        frame: Mutex::new(None),
        cv: Condvar::new(),
    });
    let mut err: i32 = 0;
    let handle = unsafe {
        SenseCamMacStart(
            uid.as_ptr(),
            want_w as i32,
            want_h as i32,
            fps as i32,
            frame_cb,
            Arc::as_ptr(&slot) as *mut c_void,
            &mut err,
        )
    };
    if handle.is_null() {
        return Err(error_of(err));
    }
    Ok(Box::new(MacSource { handle, slot }))
}
