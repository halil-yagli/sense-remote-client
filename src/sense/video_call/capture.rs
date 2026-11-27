//! Camera list and capture for the video call, one interface on every platform:
//! Windows (Media Foundation) and Linux (V4L2) through `scrap::camera::sense` (nokhwa),
//! macOS through our AVFoundation module (`cam_mac.*`).
//!
//! The camera is opened once at the P1 size (640×360 or the closest the camera offers) and
//! every frame is cropped to 16:9 and scaled to the current profile (P2 = 320×180) here, so a
//! profile change never reopens the camera. Frames leave as tightly packed RGBA, which both the
//! encoder and the "you" preview in the app use.
//!
//! Camera frames go only to the caller's sink: never to disk, the log, the panel, the session
//! recording or a diagnostics bundle (fizibilite §2.3-4).

use super::pace::Profile;
use super::wire::CamState;
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};

/// One camera in the list the app shows (`{"id","name","desc"}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CameraInfo {
    pub id: String,
    pub name: String,
    /// Short description, e.g. "USB · 1080p", "Dahili · 720p".
    pub desc: String,
}

/// Why a camera is not available. `kind()` is the word the app and the panel event use
/// (`cam/error {kind}`); device names never travel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CamError {
    /// No camera (or the chosen one is gone).
    None,
    /// The system refuses the camera (Windows privacy setting, macOS permission).
    Denied,
    /// Another app holds the camera.
    Busy,
    /// Anything else; the text is for the log only.
    Open(String),
}

impl CamError {
    pub fn kind(&self) -> &'static str {
        match self {
            CamError::None => "none",
            CamError::Denied => "denied",
            CamError::Busy => "busy",
            CamError::Open(_) => "open",
        }
    }

    /// What the other side is told (`sense.cam-ctl` state). An open error reads as "none":
    /// the other side shows the Sense logo either way.
    pub fn state(&self) -> CamState {
        match self {
            CamError::None | CamError::Open(_) => CamState::None,
            CamError::Denied => CamState::Denied,
            CamError::Busy => CamState::Busy,
        }
    }
}

impl std::fmt::Display for CamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CamError::Open(m) => write!(f, "open: {}", m),
            e => f.write_str(e.kind()),
        }
    }
}

/// Camera permission as far as the system tells before opening.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permission {
    Granted,
    /// macOS: never asked; opening the camera asks.
    NotDetermined,
    Denied,
    /// The system cannot tell before opening (Windows, Linux).
    Unknown,
}

/// Reads a backend's error text. Windows HRESULTs and Linux errno texts as nokhwa passes them.
pub fn classify_error(msg: &str) -> CamError {
    let m = msg.to_ascii_lowercase();
    const DENIED: &[&str] = &[
        "0x80070005",
        "access is denied",
        "permission denied",
        "os error 13",
        "not authorized",
        "denied",
    ];
    const BUSY: &[&str] = &[
        "0xc00d3704", // MF_E_HW_MFT_FAILED_START_STREAMING: held by another app
        "0xc00d3ea3", // MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED
        "in use",
        "busy",
        "os error 16",
        "preempted",
    ];
    const NONE: &[&str] = &[
        "no camera",
        "not found",
        "no such device",
        "os error 19",
        "0xc00d3ea2", // MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED: unplugged
    ];
    if DENIED.iter().any(|p| m.contains(p)) {
        CamError::Denied
    } else if BUSY.iter().any(|p| m.contains(p)) {
        CamError::Busy
    } else if NONE.iter().any(|p| m.contains(p)) {
        CamError::None
    } else {
        CamError::Open(msg.chars().take(200).collect())
    }
}

/// "1080p" style label of a frame height.
pub fn height_label(h: u32) -> String {
    format!("{}p", h)
}

/// The list's short description: connection kind and highest resolution, either may be absent.
pub fn desc_label(kind: Option<&str>, max_height: Option<u32>) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(k) = kind.filter(|k| !k.is_empty()) {
        parts.push(k.to_owned());
    }
    if let Some(h) = max_height.filter(|h| *h > 0) {
        parts.push(height_label(h));
    }
    parts.join(" · ")
}

/// Pixel formats a camera may offer (mirror of the platform glue, kept here so the choice is
/// tested on every platform).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Fourcc {
    Mjpeg,
    Yuyv,
    Nv12,
    Gray,
    Rgb,
}

impl Fourcc {
    /// Lower is preferred; `None` = cannot be used (grey).
    fn cost(self) -> Option<u8> {
        match self {
            Fourcc::Nv12 => Some(0),
            Fourcc::Yuyv => Some(1),
            Fourcc::Mjpeg => Some(2),
            Fourcc::Rgb => Some(3),
            Fourcc::Gray => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SrcFormat {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub fourcc: Fourcc,
}

/// Picks the capture mode for a `want_w`×`want_h` @ `want_fps` stream:
/// 1. the smallest mode that covers the wanted size (so it is scaled down, never up); when
///    none covers it, the largest;
/// 2. among those, the lowest fps that reaches `want_fps`, else the highest;
/// 3. then the cheapest pixel format to decode (NV12, YUYV, MJPEG, RGB). Grey is never picked.
pub fn choose_format(
    formats: &[SrcFormat],
    want_w: u32,
    want_h: u32,
    want_fps: u32,
) -> Option<SrcFormat> {
    let usable: Vec<SrcFormat> = formats
        .iter()
        .copied()
        .filter(|f| f.width > 0 && f.height > 0 && f.fourcc.cost().is_some())
        .collect();
    if usable.is_empty() {
        return None;
    }
    let area = |f: &SrcFormat| f.width as u64 * f.height as u64;
    let covering: Vec<SrcFormat> = usable
        .iter()
        .copied()
        .filter(|f| f.width >= want_w && f.height >= want_h)
        .collect();
    let size_pick = if covering.is_empty() {
        usable.iter().max_by_key(|f| area(f)).map(|f| (f.width, f.height))?
    } else {
        covering
            .iter()
            .min_by_key(|f| area(f))
            .map(|f| (f.width, f.height))?
    };
    let same_size: Vec<SrcFormat> = usable
        .into_iter()
        .filter(|f| (f.width, f.height) == size_pick)
        .collect();
    let reaching: Vec<&SrcFormat> = same_size.iter().filter(|f| f.fps >= want_fps).collect();
    let fps_pick = if reaching.is_empty() {
        same_size.iter().map(|f| f.fps).max()?
    } else {
        reaching.iter().map(|f| f.fps).min()?
    };
    same_size
        .into_iter()
        .filter(|f| f.fps == fps_pick)
        .min_by_key(|f| f.fourcc.cost().unwrap_or(u8::MAX))
}

/// Byte order of a raw frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelOrder {
    Rgba,
    Bgra,
}

/// The centred part of a `src_w`×`src_h` frame that has the aspect of `dst_w`×`dst_h`:
/// `(x, y, w, h)`.
pub fn crop_rect(src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) -> (u32, u32, u32, u32) {
    if src_w == 0 || src_h == 0 || dst_w == 0 || dst_h == 0 {
        return (0, 0, src_w, src_h);
    }
    // Compare src_w/src_h with dst_w/dst_h without floats.
    let lhs = src_w as u64 * dst_h as u64;
    let rhs = dst_w as u64 * src_h as u64;
    if lhs > rhs {
        // Wider than wanted: cut left and right.
        let w = ((src_h as u64 * dst_w as u64) / dst_h as u64).max(1) as u32;
        ((src_w - w) / 2, 0, w, src_h)
    } else if lhs < rhs {
        let h = ((src_w as u64 * dst_h as u64) / dst_w as u64).max(1) as u32;
        (0, (src_h - h) / 2, src_w, h)
    } else {
        (0, 0, src_w, src_h)
    }
}

/// Crops `src` to the aspect of the destination and scales it to `dst_w`×`dst_h` RGBA (area
/// average when shrinking, nearest when enlarging). `false` when `src` is too short for its
/// stated size.
pub fn scale_to_rgba(
    src: &[u8],
    src_w: u32,
    src_h: u32,
    stride: usize,
    order: PixelOrder,
    dst_w: u32,
    dst_h: u32,
    out: &mut Vec<u8>,
) -> bool {
    if src_w == 0 || src_h == 0 || dst_w == 0 || dst_h == 0 {
        return false;
    }
    if stride < src_w as usize * 4 || src.len() < stride * (src_h as usize - 1) + src_w as usize * 4
    {
        return false;
    }
    let (cx, cy, cw, ch) = crop_rect(src_w, src_h, dst_w, dst_h);
    let (ri, bi) = match order {
        PixelOrder::Rgba => (0usize, 2usize),
        PixelOrder::Bgra => (2usize, 0usize),
    };
    out.clear();
    out.resize(dst_w as usize * dst_h as usize * 4, 0);
    for dy in 0..dst_h as usize {
        let y0 = cy as usize + dy * ch as usize / dst_h as usize;
        let y1 = (cy as usize + (dy + 1) * ch as usize / dst_h as usize).max(y0 + 1);
        for dx in 0..dst_w as usize {
            let x0 = cx as usize + dx * cw as usize / dst_w as usize;
            let x1 = (cx as usize + (dx + 1) * cw as usize / dst_w as usize).max(x0 + 1);
            let mut acc = [0u32; 4];
            for y in y0..y1 {
                let row = &src[y * stride..];
                for x in x0..x1 {
                    let p = &row[x * 4..x * 4 + 4];
                    acc[0] += p[ri] as u32;
                    acc[1] += p[1] as u32;
                    acc[2] += p[bi] as u32;
                    acc[3] += p[3] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = (dy * dst_w as usize + dx) * 4;
            out[o] = ((acc[0] + n / 2) / n) as u8;
            out[o + 1] = ((acc[1] + n / 2) / n) as u8;
            out[o + 2] = ((acc[2] + n / 2) / n) as u8;
            out[o + 3] = 255;
        }
    }
    true
}

/// Lets through at most `fps` frames a second (cameras deliver 30).
#[derive(Debug, Clone)]
pub struct FramePacer {
    next: Option<Instant>,
}

impl FramePacer {
    pub fn new() -> Self {
        FramePacer { next: None }
    }

    pub fn accept(&mut self, at: Instant, fps: u32) -> bool {
        if fps == 0 {
            return false;
        }
        let interval = Duration::from_micros(1_000_000 / fps as u64);
        // A little slack so a 30 fps camera gives a steady 15 (every second frame).
        let slack = interval / 4;
        match self.next {
            Some(next) if at + slack < next => false,
            Some(next) => {
                // Keep the rhythm, but never build up a backlog after a pause.
                let mut n = next + interval;
                if n + interval < at {
                    n = at + interval;
                }
                self.next = Some(n);
                true
            }
            None => {
                self.next = Some(at + interval);
                true
            }
        }
    }
}

/// A frame ready for the encoder and the preview.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RgbaFrame {
    pub width: u32,
    pub height: u32,
    /// Tightly packed RGBA, `width * height * 4` bytes.
    pub data: Vec<u8>,
    pub captured_at: Instant,
}

/// A raw frame from a backend.
pub(crate) struct Raw {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub order: PixelOrder,
}

/// What a platform camera gives the capture thread.
pub(crate) trait Source {
    /// Next frame; `Ok(None)` when none came within `timeout`.
    fn next(&mut self, timeout: Duration) -> Result<Option<Raw>, CamError>;
}

/// Opens a platform camera (on the capture thread; device handles never cross threads).
pub(crate) type Opener = Box<dyn FnOnce() -> Result<Box<dyn Source>, CamError> + Send>;

// ---- platforms -------------------------------------------------------------------------------

#[cfg(any(target_os = "windows", target_os = "linux"))]
mod native {
    use super::*;
    use scrap::camera::sense as glue;

    fn fourcc(f: glue::Fourcc) -> Fourcc {
        match f {
            glue::Fourcc::Mjpeg => Fourcc::Mjpeg,
            glue::Fourcc::Yuyv => Fourcc::Yuyv,
            glue::Fourcc::Nv12 => Fourcc::Nv12,
            glue::Fourcc::Gray => Fourcc::Gray,
            glue::Fourcc::Rgb => Fourcc::Rgb,
        }
    }

    pub fn list() -> Result<Vec<CameraInfo>, CamError> {
        let list = glue::list(true).map_err(|e| classify_error(&e))?;
        Ok(list
            .into_iter()
            .map(|c| {
                let kind = if c.bus == "usb" { Some("USB") } else { None };
                CameraInfo {
                    desc: desc_label(kind, c.max_height),
                    id: c.id,
                    name: c.name,
                }
            })
            .collect())
    }

    pub fn permission() -> Permission {
        Permission::Unknown
    }

    struct NativeSource {
        dev: glue::Device,
        buf: Vec<u8>,
    }

    impl Source for NativeSource {
        fn next(&mut self, _timeout: Duration) -> Result<Option<Raw>, CamError> {
            // Media Foundation / V4L2 block for one frame interval; the timeout is not needed.
            let (w, h) = self
                .dev
                .frame_rgba(&mut self.buf)
                .map_err(|e| classify_error(&e))?;
            Ok(Some(Raw {
                data: std::mem::take(&mut self.buf),
                width: w,
                height: h,
                stride: w as usize * 4,
                order: PixelOrder::Rgba,
            }))
        }
    }

    pub fn opener(id: String, want: (u32, u32, u32)) -> Opener {
        Box::new(move || {
            let choose = move |offered: &[glue::Format]| -> Option<glue::Format> {
                let mine: Vec<SrcFormat> = offered
                    .iter()
                    .map(|f| SrcFormat {
                        width: f.width,
                        height: f.height,
                        fps: f.fps,
                        fourcc: fourcc(f.fourcc),
                    })
                    .collect();
                let pick = choose_format(&mine, want.0, want.1, want.2)?;
                offered
                    .iter()
                    .copied()
                    .find(|f| f.width == pick.width && f.height == pick.height && f.fps == pick.fps && fourcc(f.fourcc) == pick.fourcc)
            };
            let dev = glue::Device::open(&id, &choose).map_err(|e| classify_error(&e))?;
            Ok(Box::new(NativeSource {
                dev,
                buf: Vec::new(),
            }) as Box<dyn Source>)
        })
    }
}

#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use crate::sense::video_call::cam_mac;

    pub fn list() -> Result<Vec<CameraInfo>, CamError> {
        cam_mac::list()
    }

    pub fn permission() -> Permission {
        cam_mac::permission()
    }

    pub fn opener(id: String, want: (u32, u32, u32)) -> Opener {
        Box::new(move || cam_mac::open(&id, want.0, want.1, want.2))
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
mod native {
    use super::*;

    pub fn list() -> Result<Vec<CameraInfo>, CamError> {
        Ok(Vec::new())
    }

    pub fn permission() -> Permission {
        Permission::Unknown
    }

    pub fn opener(_id: String, _want: (u32, u32, u32)) -> Opener {
        Box::new(|| Err(CamError::None))
    }
}

/// Cameras on this computer. Windows opens each camera briefly to read its resolution, so call
/// it off the UI thread. An empty list means "none".
pub fn list_cameras() -> Result<Vec<CameraInfo>, CamError> {
    native::list()
}

/// Camera permission before opening (macOS tells; elsewhere `Unknown`).
pub fn permission() -> Permission {
    native::permission()
}

// ---- capture thread --------------------------------------------------------------------------

/// What the capture thread hands the sink.
pub enum CaptureEvent {
    Frame(RgbaFrame),
    /// The camera stopped delivering (unplugged, taken over); the thread ends after this.
    Lost(CamError),
}

pub type CaptureSink = Box<dyn FnMut(CaptureEvent) + Send>;

/// How long `start` waits for the camera to open. macOS may first ask the person for the
/// permission, so this is long; normally it opens in well under a second.
pub const OPEN_TIMEOUT: Duration = Duration::from_secs(70);
/// How long `stop` waits for the thread before leaving it to finish on its own.
pub const STOP_TIMEOUT: Duration = Duration::from_secs(2);
/// How long an opened camera may take to deliver its first frame.
pub const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(8);
const POLL: Duration = Duration::from_millis(200);

/// A running camera. Stops when dropped.
pub struct Capture {
    stop: Arc<AtomicBool>,
    profile: Arc<AtomicU8>,
    done: Option<mpsc::Receiver<()>>,
}

impl Capture {
    /// Opens the camera (`""` = the first one) and starts delivering frames at the profile's
    /// size and rate. Fails with the reason when the camera cannot be opened.
    pub fn start(device_id: &str, profile: Profile, sink: CaptureSink) -> Result<Capture, CamError> {
        let (w, h) = Profile::P1.size().unwrap_or((640, 360));
        let opener = native::opener(device_id.to_owned(), (w, h, Profile::P1.fps()));
        Self::start_with(opener, profile, sink, OPEN_TIMEOUT)
    }

    pub(crate) fn start_with(
        opener: Opener,
        profile: Profile,
        mut sink: CaptureSink,
        open_timeout: Duration,
    ) -> Result<Capture, CamError> {
        let stop = Arc::new(AtomicBool::new(false));
        let shared_profile = Arc::new(AtomicU8::new(profile.to_u8()));
        let (open_tx, open_rx) = mpsc::channel::<Result<(), CamError>>();
        let (done_tx, done_rx) = mpsc::channel::<()>();
        let stop2 = stop.clone();
        let profile2 = shared_profile.clone();
        let spawned = thread::Builder::new()
            .name("sense-camera".to_owned())
            .spawn(move || {
                // Opened = the first frame arrived: Windows reports a privacy block or a busy
                // camera only when the stream starts, macOS a busy camera by sending nothing.
                let opened = opener().and_then(|mut s| {
                    let t0 = Instant::now();
                    loop {
                        match s.next(POLL) {
                            Ok(Some(raw)) => break Ok((s, raw)),
                            Ok(None) if t0.elapsed() < FIRST_FRAME_TIMEOUT => {}
                            Ok(None) => break Err(CamError::Open("no frame".to_owned())),
                            Err(e) => break Err(e),
                        }
                    }
                });
                let (mut source, first) = match opened {
                    Ok((s, raw)) => {
                        if open_tx.send(Ok(())).is_err() {
                            // `start` gave up waiting; close the camera again.
                            drop(s);
                            let _ = done_tx.send(());
                            return;
                        }
                        (s, raw)
                    }
                    Err(e) => {
                        let _ = open_tx.send(Err(e));
                        let _ = done_tx.send(());
                        return;
                    }
                };
                let mut pending = Some(first);
                let mut pacer = FramePacer::new();
                let mut scaled: Vec<u8> = Vec::new();
                while !stop2.load(Ordering::Relaxed) {
                    let next = match pending.take() {
                        Some(raw) => Ok(Some(raw)),
                        None => source.next(POLL),
                    };
                    match next {
                        Ok(Some(raw)) => {
                            let p = Profile::from_u8(profile2.load(Ordering::Relaxed));
                            let Some((dw, dh)) = p.size() else {
                                continue; // P3: camera stays open, nothing is sent
                            };
                            let at = Instant::now();
                            if !pacer.accept(at, p.fps()) {
                                continue;
                            }
                            if scale_to_rgba(
                                &raw.data, raw.width, raw.height, raw.stride, raw.order, dw, dh,
                                &mut scaled,
                            ) {
                                sink(CaptureEvent::Frame(RgbaFrame {
                                    width: dw,
                                    height: dh,
                                    data: std::mem::take(&mut scaled),
                                    captured_at: at,
                                }));
                            }
                        }
                        Ok(None) => {}
                        Err(e) => {
                            if !stop2.load(Ordering::Relaxed) {
                                hbb_common::log::info!("sense camera lost: {}", e.kind());
                                sink(CaptureEvent::Lost(e));
                            }
                            break;
                        }
                    }
                }
                drop(source);
                let _ = done_tx.send(());
            });
        if let Err(e) = spawned {
            return Err(CamError::Open(format!("thread: {}", e)));
        }
        match open_rx.recv_timeout(open_timeout) {
            Ok(Ok(())) => Ok(Capture {
                stop,
                profile: shared_profile,
                done: Some(done_rx),
            }),
            Ok(Err(e)) => Err(e),
            Err(_) => {
                stop.store(true, Ordering::Relaxed);
                Err(CamError::Open("camera did not open in time".to_owned()))
            }
        }
    }

    pub fn set_profile(&self, p: Profile) {
        self.profile.store(p.to_u8(), Ordering::Relaxed);
    }

    pub fn profile(&self) -> Profile {
        Profile::from_u8(self.profile.load(Ordering::Relaxed))
    }

    /// Stops the camera. Returns at once if the thread ended; waits at most `STOP_TIMEOUT`
    /// (a camera stuck in the driver finishes on its own and closes then).
    pub fn stop(mut self) {
        self.stop_inner();
    }

    fn stop_inner(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(done) = self.done.take() {
            let _ = done.recv_timeout(STOP_TIMEOUT);
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop_inner();
    }
}
