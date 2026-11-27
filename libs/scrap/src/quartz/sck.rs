//! Sense Remote (S11, M5): ScreenCaptureKit capturer (Objective-C side: `sck.m`).
//!
//! Gives the same `quartz::Frame` (IOSurface, BGRA) as the `CGDisplayStream` capturer
//! (`capturer.rs`), so `common/quartz.rs` treats both alike. Which one runs: `select.rs`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use hbb_common::libc::c_void;

use super::config::Config;
use super::display::Display;
use super::ffi::IOSurfaceRef;
use super::frame::Frame;

type FrameFn = extern "C" fn(ctx: *mut c_void, surface: IOSurfaceRef);
type StopFn = extern "C" fn(ctx: *mut c_void, code: std::os::raw::c_long);

extern "C" {
    fn sense_sck_supported() -> i32;
    fn sense_sck_os_version(major: *mut i32, minor: *mut i32);
    fn sense_sck_start(
        display_id: u32,
        width: usize,
        height: usize,
        cursor: i32,
        min_frame_interval: f64,
        queue_depth: i32,
        ctx: *mut c_void,
        on_frame: FrameFn,
        on_stop: StopFn,
        err: *mut std::os::raw::c_long,
    ) -> *mut c_void;
    fn sense_sck_stop(handle: *mut c_void);
}

/// Whether ScreenCaptureKit can be loaded (macOS 12.3+, framework present).
pub fn supported() -> bool {
    unsafe { sense_sck_supported() != 0 }
}

/// The running macOS as (major, minor).
pub fn os_version() -> (u32, u32) {
    let (mut major, mut minor) = (0i32, 0i32);
    unsafe { sense_sck_os_version(&mut major, &mut minor) };
    (major.max(0) as u32, minor.max(0) as u32)
}

/// Frames the stream may hold at once. We keep at most two (the latest and the one being
/// copied); ScreenCaptureKit drops frames when every buffer is held. Default 3, maximum 8.
const QUEUE_DEPTH: i32 = 5;

struct Ctx {
    handler: Box<dyn Fn(Frame)>,
    stopped: Arc<AtomicBool>,
    got_frame: Arc<AtomicBool>,
}

extern "C" fn on_frame(ctx: *mut c_void, surface: IOSurfaceRef) {
    // `sck.m` calls this only between start and stop, while `ctx` is alive.
    let ctx = unsafe { &*(ctx as *const Ctx) };
    ctx.got_frame.store(true, Ordering::Relaxed);
    (ctx.handler)(unsafe { Frame::new(surface) });
}

extern "C" fn on_stop(ctx: *mut c_void, code: std::os::raw::c_long) {
    let ctx = unsafe { &*(ctx as *const Ctx) };
    ctx.stopped.store(true, Ordering::Relaxed);
    hbb_common::log::warn!("ScreenCaptureKit stream stopped, error code {}", code);
}

pub struct Capturer {
    handle: *mut c_void,
    ctx: *mut Ctx,
    width: usize,
    height: usize,
    started: Instant,
    stopped: Arc<AtomicBool>,
    got_frame: Arc<AtomicBool>,
}

impl Capturer {
    /// Starts a stream for `display` at `width` x `height` pixels. The error is `sck.m`'s code
    /// (1 unavailable, 2 no shareable content / permission, 3 display not found, 4 no output,
    /// 5 not started).
    pub fn new<F: Fn(Frame) + 'static>(
        display: Display,
        width: usize,
        height: usize,
        config: &Config,
        handler: F,
    ) -> Result<Capturer, i64> {
        let stopped = Arc::new(AtomicBool::new(false));
        let got_frame = Arc::new(AtomicBool::new(false));
        let ctx = Box::into_raw(Box::new(Ctx {
            handler: Box::new(handler),
            stopped: stopped.clone(),
            got_frame: got_frame.clone(),
        }));
        let mut err: std::os::raw::c_long = 0;
        let handle = unsafe {
            sense_sck_start(
                display.id(),
                width,
                height,
                config.cursor as i32,
                config.throttle,
                QUEUE_DEPTH,
                ctx as *mut c_void,
                on_frame,
                on_stop,
                &mut err,
            )
        };
        if handle.is_null() {
            // No callback runs after a failed start (`sck.m` detaches before returning).
            drop(unsafe { Box::from_raw(ctx) });
            return Err(err as i64);
        }
        Ok(Capturer {
            handle,
            ctx,
            width,
            height,
            started: Instant::now(),
            stopped,
            got_frame,
        })
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    /// Whether the stream failed (`select::sck_failed`): stopped by the system, or no first
    /// picture in time.
    pub fn failed(&self) -> bool {
        super::select::sck_failed(
            self.stopped.load(Ordering::Relaxed),
            self.got_frame.load(Ordering::Relaxed),
            self.started.elapsed().as_secs(),
        )
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe {
            // Returns after the last callback; `ctx` is free to go.
            sense_sck_stop(self.handle);
            drop(Box::from_raw(self.ctx));
        }
    }
}
