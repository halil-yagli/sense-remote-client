//! Sense Remote: maintenance curtain for ghost mode (hayalet mod), wave 3 I10.
//!
//! When the Controller turns ghost mode on, every physical screen of the Host shows a calm
//! Sense "Bakım yapılıyor" curtain, so visitors (e.g. in a museum) do not see the work. The
//! curtain windows are excluded from screen capture (`WDA_EXCLUDEFROMCAPTURE`, Windows 10 2004+),
//! so the Controller keeps seeing the real screen. The windows let input through (layered +
//! transparent) and never take focus.
//!
//! The connection must stay visible on the controlled side (workshop CLAUDE.md, Security): the
//! Sense icon (the connection manager window of this same program) is kept ABOVE the curtain.
//! A pure-black curtain is a separate team decision and is not offered here.
//!
//! Layout and colours follow the prototype (`uygulama.html` → "Hayalet mod — sahada") and
//! BRAND_CORE: black, a soft navy→purple glow, the Sense mark, "**Bakım** yapılıyor".
//!
//! MAC-SONRA-15: macOS has no curtain yet (privacy mode is not offered there).

use std::sync::atomic::{AtomicBool, Ordering};

static SHOWN: AtomicBool = AtomicBool::new(false);

/// True while the curtain is on (heartbeat `maintenance_curtain`, `report::heartbeat_base`).
pub fn is_shown() -> bool {
    SHOWN.load(Ordering::SeqCst)
}

/// Sense Remote: true where this computer can show the curtain: Windows 10 2004 (build 19041)
/// or later, the first with `WDA_EXCLUDEFROMCAPTURE`. Privacy mode and the heartbeat `caps`
/// (`curtain`) both ask here, so the two never disagree. Read once; the OS build does not
/// change while the program runs.
#[cfg(windows)]
pub fn is_supported() -> bool {
    static SUPPORTED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *SUPPORTED.get_or_init(|| {
        // https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity
        base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
    })
}

/// Sense Remote: no curtain outside Windows yet (MAC-SONRA-15).
#[cfg(not(windows))]
pub fn is_supported() -> bool {
    false
}

// Curtain texts (Turkish UI first; the curtain is for visitors on site).
pub const TITLE_BOLD: &str = "Bakım";
pub const TITLE_LIGHT: &str = " yapılıyor";
pub const SUBTITLE: &str = "Kısa süre içinde yeniden hizmetinizde.";

/// Prototype `--muted` (#8e8e98) and the mark box border (#2a2a33).
#[cfg_attr(not(windows), allow(dead_code))]
const MUTED: (u8, u8, u8) = (0x8e, 0x8e, 0x98);
#[cfg_attr(not(windows), allow(dead_code))]
const BORDER: (u8, u8, u8) = (0x2a, 0x2a, 0x33);

/// Positions on one screen, in pixels of that screen.
#[derive(Debug, Clone, Copy, PartialEq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) struct Layout {
    pub width: i32,
    pub height: i32,
    pub mark_x: i32,
    pub mark_y: i32,
    pub mark_size: i32,
    pub border: i32,
    pub title_px: i32,
    pub title_top: i32,
    pub title_line: i32,
    pub sub_px: i32,
    pub sub_top: i32,
    pub sub_line: i32,
    /// Sense Remote (H5): blur of the green glow around a watched screen's logo.
    pub glow: i32,
}

/// Centered block (mark, title, subtitle), sized for the screen: 1080 px tall (or wide, for a
/// portrait screen) is the reference; 4K doubles everything.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn layout(width: i32, height: i32) -> Layout {
    let s = (width.min(height).max(1) as f32 / 1080.0).max(0.3);
    let px = |v: f32| ((v * s).round() as i32).max(1);
    let mark_size = px(128.0);
    let gap_mark = px(36.0);
    let title_px = px(52.0);
    let title_line = px(68.0);
    let gap_sub = px(10.0);
    let sub_px = px(26.0);
    let sub_line = px(36.0);
    let total = mark_size + gap_mark + title_line + gap_sub + sub_line;
    let top = ((height - total) / 2).max(0);
    let title_top = top + mark_size + gap_mark;
    Layout {
        width,
        height,
        mark_x: (width - mark_size) / 2,
        mark_y: top,
        mark_size,
        border: px(1.5),
        title_px,
        title_top,
        title_line,
        sub_px,
        sub_top: title_top + title_line + gap_sub,
        sub_line,
        glow: px(crate::sense::tokens::WATCHED_GLOW_PX),
    }
}

/// Background colour at (x, y) in 0..1 of the screen (`aspect` = width / height): black with
/// the prototype's glow, a navy blob in the middle and a purple one to the lower right
/// (`.glow`: rgba(2,1,98,.8) and rgba(100,1,100,.55) at 70%/60%, opacity .6, blurred).
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn glow_rgb(x: f32, y: f32, aspect: f32) -> (u8, u8, u8) {
    let blob = |cx: f32, cy: f32, r: f32| {
        let dx = (x - cx) * aspect;
        let dy = y - cy;
        let d = (dx * dx + dy * dy).sqrt() / r;
        if d >= 1.0 {
            0.0
        } else {
            let t = 1.0 - d;
            t * t * (3.0 - 2.0 * t)
        }
    };
    let navy = blob(0.5, 0.5, 0.42) * 0.48;
    let purple = blob(0.5 + 0.24 / aspect.max(0.1), 0.585, 0.34) * 0.33;
    let mix = |a: f32, b: f32| (a * navy + b * purple).round().clamp(0.0, 255.0) as u8;
    (mix(2.0, 100.0), mix(1.0, 1.0), mix(98.0, 100.0))
}

/// Size of the small glow bitmap that is stretched over the screen.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn glow_size(width: i32, height: i32) -> (i32, i32) {
    const GLOW_W: i32 = 320;
    let h = (GLOW_W as i64 * height.max(1) as i64 / width.max(1) as i64) as i32;
    (GLOW_W, h.clamp(1, 1024))
}

/// Top-down 32-bit DIB pixels (B, G, R, X in memory) of the glow.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn glow_pixels(gw: i32, gh: i32, aspect: f32) -> Vec<u32> {
    let mut out = Vec::with_capacity((gw.max(0) * gh.max(0)) as usize);
    for j in 0..gh {
        for i in 0..gw {
            let (r, g, b) = glow_rgb(
                (i as f32 + 0.5) / gw as f32,
                (j as f32 + 0.5) / gh as f32,
                aspect,
            );
            out.push(dib_pixel(r, g, b));
        }
    }
    out
}

#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn dib_pixel(r: u8, g: u8, b: u8) -> u32 {
    (b as u32) | ((g as u32) << 8) | ((r as u32) << 16)
}

/// GDI COLORREF (0x00BBGGRR).
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn colorref((r, g, b): (u8, u8, u8)) -> u32 {
    (r as u32) | ((g as u32) << 8) | ((b as u32) << 16)
}

/// Where a top-level window sits relative to the curtain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) enum Layer {
    /// One of our curtain windows.
    Curtain,
    /// The Sense icon: must stay above the curtain.
    Keep,
    /// Any other visible window: must stay below the curtain.
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) enum Restack {
    /// Order is right: nothing to do.
    Nothing,
    /// No Sense icon window: curtain windows to the top.
    Top,
    /// Curtain windows directly below the lowest Sense icon window; raise the icon windows to
    /// the top first when another window sits above them.
    UnderKeep { raise_keep: bool },
}

/// What to change, given the z-order from top to bottom. Changing only when needed means the
/// icon is never covered, not even for a frame.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn plan_restack(order: &[Layer]) -> Restack {
    let (Some(first_curtain), Some(last_curtain)) = (
        order.iter().position(|l| *l == Layer::Curtain),
        order.iter().rposition(|l| *l == Layer::Curtain),
    ) else {
        return Restack::Nothing;
    };
    let other_above = order[..last_curtain].contains(&Layer::Other);
    let keep_below = order[first_curtain..].contains(&Layer::Keep);
    if !other_above && !keep_below {
        return Restack::Nothing;
    }
    match order.iter().rposition(|l| *l == Layer::Keep) {
        None => Restack::Top,
        Some(last_keep) => Restack::UnderKeep {
            raise_keep: order[..last_keep].contains(&Layer::Other),
        },
    }
}

/// A visible top-level window of another process.
#[derive(Debug, Clone)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) struct Candidate {
    pub pid: u32,
    pub exe: Option<String>,
    pub topmost: bool,
}

/// Windows kept above the curtain: always-on-top windows of this same program in another
/// process, i.e. the Sense icon (connection manager). Indexes into `candidates`.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn keep_above(own_pid: u32, own_exe: &str, candidates: &[Candidate]) -> Vec<usize> {
    candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| {
            c.pid != own_pid
                && c.topmost
                && !own_exe.is_empty()
                && c
                    .exe
                    .as_deref()
                    .map_or(false, |exe| exe.to_lowercase() == own_exe.to_lowercase())
        })
        .map(|(i, _)| i)
        .collect()
}

// Sense Remote (S7-a, H5): the screens the Controller watches show a green logo.

/// A screen the Controller watches, as the video service knows it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub struct WatchedDisplay {
    /// Device name (`\\.\DISPLAY1`), the same as the monitor's `szDevice`.
    pub name: String,
    /// Top-left corner, used when the names do not match.
    pub x: i32,
    pub y: i32,
}

static WATCHED: std::sync::Mutex<Vec<WatchedDisplay>> = std::sync::Mutex::new(Vec::new());

/// Sets the watched screens; the curtain (when on) turns their logos green within 0.4 s. An
/// empty list makes every logo white. Kept while the curtain is off, read when it comes on.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn set_watched(displays: Vec<WatchedDisplay>) {
    {
        let mut watched = WATCHED.lock().unwrap();
        if *watched == displays {
            return;
        }
        *watched = displays;
    }
    #[cfg(windows)]
    win::watched_changed();
}

#[cfg_attr(not(windows), allow(dead_code))]
fn watched() -> Vec<WatchedDisplay> {
    WATCHED.lock().unwrap().clone()
}

/// Which screens (device name, left, top) are watched: a watched display is found by its
/// device name, or by its top-left corner when no screen has that name.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn watched_flags(screens: &[(String, i32, i32)], watched: &[WatchedDisplay]) -> Vec<bool> {
    let mut flags = vec![false; screens.len()];
    for w in watched {
        let by_name = screens
            .iter()
            .position(|(name, _, _)| !w.name.is_empty() && name.eq_ignore_ascii_case(&w.name));
        let found = by_name.or_else(|| {
            screens
                .iter()
                .position(|(_, x, y)| *x == w.x && *y == w.y)
        });
        if let Some(i) = found {
            flags[i] = true;
        }
    }
    flags
}

/// Next green level (0 white … 1 green) after `dt_ms`, moving linearly so a full change takes
/// the design's transition time.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn step_level(level: f32, watched: bool, dt_ms: u32) -> f32 {
    let target = if watched { 1.0 } else { 0.0 };
    let step = dt_ms as f32 / crate::sense::tokens::WATCHED_TRANSITION_MS.max(1) as f32;
    if level < target {
        (level + step).min(target)
    } else {
        (level - step).max(target)
    }
}

/// Logo colour at a green level.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn logo_rgb(level: f32) -> (u8, u8, u8) {
    use crate::sense::tokens::{UNWATCHED_WHITE as W, WATCHED_GREEN as G};
    let t = level.clamp(0.0, 1.0);
    let mix = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round() as u8;
    (mix(W.0, G.0), mix(W.1, G.1), mix(W.2, G.2))
}

/// Opacity of the green glow `dist` px outside the logo circle: a soft blur of `glow` px
/// (CSS-like, sigma = glow / 2), scaled by the green level.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn halo_alpha(dist: f32, glow: f32, level: f32) -> f32 {
    const PEAK: f32 = 0.6;
    if level <= 0.0 || glow <= 0.0 {
        return 0.0;
    }
    let sigma = glow / 2.0;
    let d = dist.max(0.0);
    PEAK * level.min(1.0) * (-(d * d) / (2.0 * sigma * sigma)).exp()
}

/// One premultiplied BGRA pixel of the logo in `tint`, from the icon drawn once on black and
/// once on white: what changes between the two is the icon's transparency, what it shows on
/// black is its (premultiplied) colour, which the tint then multiplies (white mark → tint).
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn tinted_pixel(on_black: (u8, u8, u8), on_white: (u8, u8, u8), tint: (u8, u8, u8)) -> [u8; 4] {
    let diff = |b: u8, w: u8| w.saturating_sub(b) as u32;
    let see_through = diff(on_black.0, on_white.0)
        .max(diff(on_black.1, on_white.1))
        .max(diff(on_black.2, on_white.2));
    let a = 255 - see_through.min(255);
    let ch = |c: u8, t: u8| ((c as u32 * t as u32 + 127) / 255).min(a) as u8;
    [
        ch(on_black.2, tint.2),
        ch(on_black.1, tint.1),
        ch(on_black.0, tint.0),
        a as u8,
    ]
}

#[cfg(windows)]
pub use win::{hide, show};

#[cfg(not(windows))]
#[allow(dead_code)]
pub fn show() -> hbb_common::ResultType<()> {
    hbb_common::bail!("Sense Remote: the maintenance curtain is Windows only (MAC-SONRA-15)")
}

#[cfg(not(windows))]
#[allow(dead_code)]
pub fn hide() {}

#[cfg(windows)]
mod win {
    use super::*;
    use hbb_common::{bail, log, ResultType};
    use std::{
        io::Error,
        mem::{size_of, zeroed},
        ptr::{null, null_mut},
        sync::{atomic::Ordering, mpsc, Mutex},
        time::{Duration, Instant},
    };
    use winapi::{
        shared::{
            minwindef::{BOOL, DWORD, FALSE, HINSTANCE, LPARAM, LRESULT, TRUE, UINT, WPARAM},
            windef::{HDC, HFONT, HICON, HMONITOR, HWND, RECT, SIZE},
        },
        um::{
            handleapi::CloseHandle,
            libloaderapi::GetModuleHandleW,
            processthreadsapi::{
                GetCurrentProcess, GetCurrentProcessId, GetCurrentThreadId, OpenProcess,
            },
            wingdi::{
                CreateCompatibleDC, CreateDIBSection, CreateFontW, CreatePen, DeleteDC,
                DeleteObject, GdiFlush, GetStockObject, GetTextExtentPoint32W, GetTextFaceW,
                GetTextMetricsW, RoundRect, SelectObject, SetBkMode, SetBrushOrgEx,
                SetStretchBltMode, SetTextAlign, SetTextColor, StretchDIBits, TextOutW,
                BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, TEXTMETRICW,
            },
            winnt::{HANDLE, PROCESS_QUERY_LIMITED_INFORMATION},
            winuser::{
                BeginPaint, CreateWindowExW, DefWindowProcW, DestroyIcon, DestroyWindow,
                DispatchMessageW, DrawIconEx, EndPaint, EnumDisplayMonitors, EnumWindows,
                GetClientRect, GetMessageW, GetMonitorInfoW, GetTopWindow, GetWindow,
                GetWindowLongPtrW, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId,
                InvalidateRect, IsWindowVisible, KillTimer, LoadImageW, PeekMessageW,
                PostThreadMessageW, RegisterClassExW, SetLayeredWindowAttributes, SetTimer,
                SetWindowLongPtrW, SetWindowPos, ShowWindow, TranslateMessage, UpdateWindow,
                MONITORINFO, MONITORINFOEXW, MSG, PAINTSTRUCT, WNDCLASSEXW,
            },
        },
    };

    // Win32 values, written out so the build does not depend on optional winapi constants.
    const WDA_EXCLUDEFROMCAPTURE: DWORD = 0x0000_0011;
    const WS_POPUP: DWORD = 0x8000_0000;
    const WS_EX_TOPMOST: DWORD = 0x0000_0008;
    const WS_EX_TRANSPARENT: DWORD = 0x0000_0020;
    const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;
    const WS_EX_LAYERED: DWORD = 0x0008_0000;
    const WS_EX_NOACTIVATE: DWORD = 0x0800_0000;
    const GWL_EXSTYLE: i32 = -20;
    const GW_HWNDNEXT: UINT = 2;
    const LWA_ALPHA: DWORD = 0x2;
    const SW_SHOWNOACTIVATE: i32 = 4;
    const SWP_NOSIZE: UINT = 0x0001;
    const SWP_NOMOVE: UINT = 0x0002;
    const SWP_NOACTIVATE: UINT = 0x0010;
    const SWP_ASYNCWINDOWPOS: UINT = 0x4000;
    const HWND_TOPMOST: HWND = -1isize as HWND;
    const WM_USER: UINT = 0x0400;
    const WM_QUIT: UINT = 0x0012;
    const WM_TIMER: UINT = 0x0113;
    const WM_PAINT: UINT = 0x000F;
    const WM_ERASEBKGND: UINT = 0x0014;
    const WM_CLOSE: UINT = 0x0010;
    const WM_NCHITTEST: UINT = 0x0084;
    const WM_MOUSEACTIVATE: UINT = 0x0021;
    const HTTRANSPARENT: LRESULT = -1;
    const MA_NOACTIVATE: LRESULT = 3;
    const PM_NOREMOVE: UINT = 0;
    const IMAGE_ICON: UINT = 1;
    const DI_NORMAL: UINT = 3;
    const IDI_APP_ICON: usize = 101; // flutter/windows/runner/resource.h (Sense icon)
    const ERROR_CLASS_ALREADY_EXISTS: i32 = 1410;
    const BI_RGB: DWORD = 0;
    const DIB_RGB_COLORS: UINT = 0;
    const SRCCOPY: DWORD = 0x00CC_0020;
    const HALFTONE: i32 = 4;
    const TRANSPARENT_BK: i32 = 1;
    const TA_LEFT_BASELINE: UINT = 24;
    const PS_SOLID: i32 = 0;
    const BLACK_BRUSH: i32 = 4;
    const DEFAULT_CHARSET: DWORD = 1;
    const CLEARTYPE_QUALITY: DWORD = 5;
    // Sense Remote (H5): watched-screen logo.
    const GWLP_USERDATA: i32 = -21;
    const AC_SRC_OVER: u8 = 0;
    const AC_SRC_ALPHA: u8 = 1;
    /// Thread message: the watched screens changed (`set_watched`).
    const WM_SENSE_WATCHED: UINT = WM_USER + 1;
    /// Frame time of the white/green transition.
    const ANIM_MS: UINT = 16;

    const CLASS_NAME: &str = "SenseRemoteMaintenanceCurtain";
    const WINDOW_TITLE: &str = "Sense Remote";
    /// How often the curtain checks screens and window order.
    const REFRESH_MS: UINT = 400;
    const START_TIMEOUT: Duration = Duration::from_secs(3);
    const STOP_TIMEOUT: Duration = Duration::from_secs(2);

    #[link(name = "user32")]
    extern "system" {
        fn SetWindowDisplayAffinity(hwnd: HWND, affinity: DWORD) -> BOOL;
    }

    #[link(name = "msimg32")]
    extern "system" {
        fn AlphaBlend(
            dest: HDC,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
            src: HDC,
            sx: i32,
            sy: i32,
            sw: i32,
            sh: i32,
            blend: BLENDFUNCTION,
        ) -> BOOL;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn QueryFullProcessImageNameW(
            process: HANDLE,
            flags: DWORD,
            name: *mut u16,
            size: *mut DWORD,
        ) -> BOOL;
    }

    struct Running {
        thread_id: DWORD,
        done: mpsc::Receiver<()>,
    }

    static RUNNING: Mutex<Option<Running>> = Mutex::new(None);

    /// Shows the curtain on every screen; returns once it is painted (or failed).
    pub fn show() -> ResultType<()> {
        let mut running = RUNNING.lock().unwrap();
        if running.is_some() {
            return Ok(());
        }
        let (ready_tx, ready_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("sense-curtain".to_owned())
            .spawn(move || {
                run(ready_tx);
                let _ = done_tx.send(());
            })?;
        match ready_rx.recv_timeout(START_TIMEOUT) {
            Ok(Ok(thread_id)) => {
                *running = Some(Running {
                    thread_id,
                    done: done_rx,
                });
                SHOWN.store(true, Ordering::SeqCst);
                log::info!("Sense curtain on");
                Ok(())
            }
            Ok(Err(e)) => bail!("Sense curtain failed: {}", e),
            // The thread closes its windows itself when nobody waits for it anymore.
            Err(_) => bail!("Sense curtain did not start in time"),
        }
    }

    /// Removes the curtain from every screen.
    pub fn hide() {
        let running = RUNNING.lock().unwrap().take();
        if let Some(running) = running {
            unsafe {
                PostThreadMessageW(running.thread_id, WM_QUIT, 0, 0);
            }
            if running.done.recv_timeout(STOP_TIMEOUT).is_err() {
                log::warn!("Sense curtain thread did not stop in time");
            }
            log::info!("Sense curtain off");
        }
        SHOWN.store(false, Ordering::SeqCst);
    }

    /// Sense Remote (H5): tells a running curtain to re-read the watched screens.
    pub(super) fn watched_changed() {
        if let Some(running) = RUNNING.lock().unwrap().as_ref() {
            unsafe {
                PostThreadMessageW(running.thread_id, WM_SENSE_WATCHED, 0, 0);
            }
        }
    }

    fn run(ready: mpsc::Sender<Result<DWORD, String>>) {
        unsafe {
            let thread_id = GetCurrentThreadId();
            let mut msg: MSG = zeroed();
            // Creates the message queue before anyone posts WM_QUIT to it.
            PeekMessageW(&mut msg, null_mut(), WM_USER, WM_USER, PM_NOREMOVE);
            let mut curtain = match Curtain::open() {
                Ok(c) => c,
                Err(e) => {
                    let _ = ready.send(Err(e.to_string()));
                    return;
                }
            };
            if ready.send(Ok(thread_id)).is_err() {
                curtain.close();
                return;
            }
            let timer = SetTimer(null_mut(), 0, REFRESH_MS, None);
            while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
                // Sense Remote (H5): the logo transition has its own, faster timer.
                if msg.hwnd.is_null()
                    && msg.message == WM_TIMER
                    && curtain.anim_timer != 0
                    && msg.wParam == curtain.anim_timer
                {
                    curtain.animate();
                    continue;
                }
                if msg.hwnd.is_null() && msg.message == WM_TIMER {
                    curtain.refresh();
                    continue;
                }
                if msg.hwnd.is_null() && msg.message == WM_SENSE_WATCHED {
                    curtain.update_watched();
                    continue;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if timer != 0 {
                KillTimer(null_mut(), timer);
            }
            curtain.stop_animation();
            curtain.close();
        }
    }

    type MonitorRect = (i32, i32, i32, i32);

    /// A physical screen: its rectangle and device name (`szDevice`).
    #[derive(Debug, Clone, PartialEq)]
    struct Screen {
        rect: MonitorRect,
        name: String,
    }

    struct Curtain {
        hinst: HINSTANCE,
        windows: Vec<HWND>,
        screens: Vec<Screen>,
        own_pid: u32,
        own_exe: String,
        // Sense Remote (H5): per window, the green level shown (0 white, 1 green) and whether
        // its screen is watched; the transition timer runs only while they differ.
        levels: Vec<f32>,
        watched: Vec<bool>,
        anim_timer: usize,
        anim_last: Instant,
    }

    impl Curtain {
        unsafe fn open() -> ResultType<Self> {
            let hinst = GetModuleHandleW(null());
            register_class(hinst)?;
            let screens = monitor_screens()?;
            if screens.is_empty() {
                bail!("no screen found");
            }
            let windows = create_windows(hinst, &screens)?;
            let mut curtain = Self {
                hinst,
                windows,
                screens,
                own_pid: GetCurrentProcessId(),
                own_exe: process_exe(GetCurrentProcess()).unwrap_or_default(),
                levels: Vec::new(),
                watched: Vec::new(),
                anim_timer: 0,
                anim_last: Instant::now(),
            };
            curtain.reset_levels();
            curtain.restack();
            if curtain.keep_windows().is_empty() {
                log::warn!("Sense curtain: no Sense icon window found yet");
            }
            Ok(curtain)
        }

        /// Follows screen changes and keeps the order: Sense icon, curtain, everything else.
        unsafe fn refresh(&mut self) {
            match monitor_screens() {
                Ok(screens) if !screens.is_empty() && screens != self.screens => {
                    // New windows first, so the screens are never uncovered in between.
                    match create_windows(self.hinst, &screens) {
                        Ok(windows) => {
                            let old = std::mem::replace(&mut self.windows, windows);
                            self.screens = screens;
                            destroy_windows(&old);
                            self.reset_levels();
                            log::info!("Sense curtain: screens changed ({})", self.screens.len());
                        }
                        Err(e) => log::warn!("Sense curtain: screens changed, {}", e),
                    }
                }
                Err(e) => log::warn!("Sense curtain: {}", e),
                _ => {}
            }
            self.restack();
        }

        unsafe fn close(&mut self) {
            destroy_windows(&self.windows);
            self.windows.clear();
        }

        /// Watched flag of every window, from `set_watched`.
        fn watched_now(&self) -> Vec<bool> {
            let screens: Vec<(String, i32, i32)> = self
                .screens
                .iter()
                .map(|s| (s.name.clone(), s.rect.0, s.rect.1))
                .collect();
            watched_flags(&screens, &watched())
        }

        /// New windows start at their final colour (no transition).
        unsafe fn reset_levels(&mut self) {
            self.stop_animation();
            self.watched = self.watched_now();
            self.levels = final_levels(&self.watched);
            for (i, &hwnd) in self.windows.iter().enumerate() {
                set_window_level(hwnd, self.levels.get(i).copied().unwrap_or(0.0));
            }
        }

        unsafe fn update_watched(&mut self) {
            let watched = self.watched_now();
            if watched == self.watched {
                return;
            }
            self.watched = watched;
            if self.anim_timer == 0 {
                self.anim_last = Instant::now();
                self.anim_timer = SetTimer(null_mut(), 0, ANIM_MS, None);
                if self.anim_timer == 0 {
                    // No timer: jump to the final colours.
                    self.levels = final_levels(&self.watched);
                    self.repaint_logos();
                }
            }
        }

        unsafe fn animate(&mut self) {
            let now = Instant::now();
            let dt = now.duration_since(self.anim_last).as_millis().min(1000) as u32;
            self.anim_last = now;
            let mut moving = false;
            for (i, level) in self.levels.iter_mut().enumerate() {
                let watched = self.watched.get(i).copied().unwrap_or(false);
                *level = step_level(*level, watched, dt);
                moving |= *level != if watched { 1.0 } else { 0.0 };
            }
            self.repaint_logos();
            if !moving {
                self.stop_animation();
            }
        }

        unsafe fn stop_animation(&mut self) {
            if self.anim_timer != 0 {
                KillTimer(null_mut(), self.anim_timer);
                self.anim_timer = 0;
            }
        }

        /// Repaints only the logo (with its glow) of every window.
        unsafe fn repaint_logos(&self) {
            for (i, &hwnd) in self.windows.iter().enumerate() {
                set_window_level(hwnd, self.levels.get(i).copied().unwrap_or(0.0));
                let mut rc: RECT = zeroed();
                GetClientRect(hwnd, &mut rc);
                let lay = layout(rc.right - rc.left, rc.bottom - rc.top);
                let reach = mark_reach(&lay);
                let area = RECT {
                    left: lay.mark_x - reach,
                    top: lay.mark_y - reach,
                    right: lay.mark_x + lay.mark_size + reach,
                    bottom: lay.mark_y + lay.mark_size + reach,
                };
                InvalidateRect(hwnd, &area, FALSE);
            }
        }

        unsafe fn keep_windows(&self) -> Vec<HWND> {
            let mut found: Vec<HWND> = Vec::new();
            EnumWindows(Some(collect_window), &mut found as *mut Vec<HWND> as LPARAM);
            let mut candidates = Vec::new();
            let mut hwnds = Vec::new();
            for hwnd in found {
                if FALSE == IsWindowVisible(hwnd) {
                    continue;
                }
                let mut pid: DWORD = 0;
                GetWindowThreadProcessId(hwnd, &mut pid);
                if pid == self.own_pid {
                    continue;
                }
                let topmost = (GetWindowLongW(hwnd, GWL_EXSTYLE) as DWORD) & WS_EX_TOPMOST != 0;
                if !topmost {
                    continue;
                }
                candidates.push(Candidate {
                    pid,
                    exe: pid_exe(pid),
                    topmost,
                });
                hwnds.push(hwnd);
            }
            keep_above(self.own_pid, &self.own_exe, &candidates)
                .into_iter()
                .map(|i| hwnds[i])
                .collect()
        }

        unsafe fn restack(&self) {
            if self.windows.is_empty() {
                return;
            }
            let keep = self.keep_windows();
            let mut order: Vec<(HWND, Layer)> = Vec::new();
            let mut hwnd = GetTopWindow(null_mut());
            let mut guard = 0;
            while !hwnd.is_null() && guard < 8192 {
                guard += 1;
                if self.windows.contains(&hwnd) {
                    order.push((hwnd, Layer::Curtain));
                } else if keep.contains(&hwnd) {
                    order.push((hwnd, Layer::Keep));
                } else if FALSE != IsWindowVisible(hwnd) && has_area(hwnd) {
                    order.push((hwnd, Layer::Other));
                }
                hwnd = GetWindow(hwnd, GW_HWNDNEXT);
            }
            let layers: Vec<Layer> = order.iter().map(|(_, l)| *l).collect();
            let flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            match plan_restack(&layers) {
                Restack::Nothing => {}
                Restack::Top => {
                    for &w in &self.windows {
                        SetWindowPos(w, HWND_TOPMOST, 0, 0, 0, 0, flags);
                    }
                }
                Restack::UnderKeep { raise_keep } => {
                    if raise_keep {
                        // Another process: asynchronous, so a hung window cannot block us.
                        for &k in &keep {
                            SetWindowPos(k, HWND_TOPMOST, 0, 0, 0, 0, flags | SWP_ASYNCWINDOWPOS);
                        }
                    }
                    let Some(&(lowest_keep, _)) =
                        order.iter().rev().find(|(_, l)| *l == Layer::Keep)
                    else {
                        return;
                    };
                    let mut after = lowest_keep;
                    for &w in &self.windows {
                        SetWindowPos(w, after, 0, 0, 0, 0, flags);
                        after = w;
                    }
                }
            }
        }
    }

    unsafe extern "system" fn collect_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let found = &mut *(lparam as *mut Vec<HWND>);
        found.push(hwnd);
        TRUE
    }

    fn final_levels(watched: &[bool]) -> Vec<f32> {
        watched.iter().map(|&w| if w { 1.0 } else { 0.0 }).collect()
    }

    /// How far the glow reaches outside the logo circle.
    fn mark_reach(lay: &Layout) -> i32 {
        lay.glow * 2
    }

    /// The green level a window paints with, kept on the window (thousandths).
    unsafe fn set_window_level(hwnd: HWND, level: f32) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (level.clamp(0.0, 1.0) * 1000.0).round() as isize);
    }

    unsafe fn window_level(hwnd: HWND) -> f32 {
        (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as f32 / 1000.0).clamp(0.0, 1.0)
    }

    unsafe fn has_area(hwnd: HWND) -> bool {
        let mut r: RECT = zeroed();
        FALSE != GetWindowRect(hwnd, &mut r) && r.right > r.left && r.bottom > r.top
    }

    unsafe fn pid_exe(pid: DWORD) -> Option<String> {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if process.is_null() {
            return None;
        }
        let exe = process_exe(process);
        CloseHandle(process);
        exe
    }

    unsafe fn process_exe(process: HANDLE) -> Option<String> {
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as DWORD;
        if FALSE == QueryFullProcessImageNameW(process, 0, buf.as_mut_ptr(), &mut len) {
            return None;
        }
        Some(String::from_utf16_lossy(&buf[..(len as usize).min(buf.len())]))
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe fn register_class(hinst: HINSTANCE) -> ResultType<()> {
        let class = wide(CLASS_NAME);
        let mut wc: WNDCLASSEXW = zeroed();
        wc.cbSize = size_of::<WNDCLASSEXW>() as UINT;
        wc.lpfnWndProc = Some(wnd_proc);
        wc.hInstance = hinst;
        wc.lpszClassName = class.as_ptr();
        if RegisterClassExW(&wc) == 0 {
            let err = Error::last_os_error();
            if err.raw_os_error() != Some(ERROR_CLASS_ALREADY_EXISTS) {
                bail!("RegisterClassExW: {}", err);
            }
        }
        Ok(())
    }

    unsafe fn create_windows(hinst: HINSTANCE, screens: &[Screen]) -> ResultType<Vec<HWND>> {
        let class = wide(CLASS_NAME);
        let title = wide(WINDOW_TITLE);
        let ex_style = WS_EX_TOPMOST
            | WS_EX_TOOLWINDOW
            | WS_EX_LAYERED
            | WS_EX_TRANSPARENT
            | WS_EX_NOACTIVATE;
        let mut windows = Vec::new();
        for &(left, top, right, bottom) in screens.iter().map(|s| &s.rect) {
            let hwnd = CreateWindowExW(
                ex_style,
                class.as_ptr(),
                title.as_ptr(),
                WS_POPUP,
                left,
                top,
                right - left,
                bottom - top,
                null_mut(),
                null_mut(),
                hinst,
                null_mut(),
            );
            if hwnd.is_null() {
                let err = Error::last_os_error();
                destroy_windows(&windows);
                bail!("CreateWindowExW: {}", err);
            }
            windows.push(hwnd);
            // Opaque, and kept out of every capture: the Controller sees the real screen.
            if FALSE == SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
                || FALSE == SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)
            {
                let err = Error::last_os_error();
                destroy_windows(&windows);
                bail!("curtain window setup: {}", err);
            }
        }
        for &hwnd in &windows {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            UpdateWindow(hwnd);
        }
        Ok(windows)
    }

    unsafe fn destroy_windows(windows: &[HWND]) {
        for &hwnd in windows {
            DestroyWindow(hwnd);
        }
    }

    unsafe fn monitor_screens() -> ResultType<Vec<Screen>> {
        let mut screens: Vec<Screen> = Vec::new();
        if FALSE
            == EnumDisplayMonitors(
                null_mut(),
                null(),
                Some(collect_monitor),
                &mut screens as *mut Vec<Screen> as LPARAM,
            )
        {
            bail!("EnumDisplayMonitors: {}", Error::last_os_error());
        }
        Ok(screens)
    }

    unsafe extern "system" fn collect_monitor(
        hmon: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        lparam: LPARAM,
    ) -> BOOL {
        let screens = &mut *(lparam as *mut Vec<Screen>);
        // Sense Remote (H5): the extended info also gives the device name (`\\.\DISPLAY1`),
        // which the watched screens are matched by.
        let mut info: MONITORINFOEXW = zeroed();
        info.cbSize = size_of::<MONITORINFOEXW>() as DWORD;
        if FALSE != GetMonitorInfoW(hmon, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) {
            let r = info.rcMonitor;
            let end = info
                .szDevice
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(info.szDevice.len());
            screens.push(Screen {
                rect: (r.left, r.top, r.right, r.bottom),
                name: String::from_utf16_lossy(&info.szDevice[..end]),
            });
        }
        TRUE
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_PAINT => {
                paint(hwnd);
                0
            }
            WM_ERASEBKGND => 1,
            // Input goes through to the windows below; the curtain never takes focus.
            WM_NCHITTEST => HTTRANSPARENT,
            WM_MOUSEACTIVATE => MA_NOACTIVATE,
            // Only `hide` closes the curtain.
            WM_CLOSE => 0,
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    unsafe fn paint(hwnd: HWND) {
        let mut ps: PAINTSTRUCT = zeroed();
        let hdc = BeginPaint(hwnd, &mut ps);
        if hdc.is_null() {
            return;
        }
        let mut rc: RECT = zeroed();
        GetClientRect(hwnd, &mut rc);
        let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
        if w > 0 && h > 0 {
            draw_glow(hdc, w, h);
            let lay = layout(w, h);
            // Sense Remote (H5): green glow + logo on a watched screen.
            let level = window_level(hwnd);
            draw_halo(hdc, &lay, level);
            draw_mark(hdc, &lay, level);
            draw_texts(hdc, &lay);
        }
        EndPaint(hwnd, &ps);
    }

    unsafe fn draw_glow(hdc: HDC, w: i32, h: i32) {
        let (gw, gh) = glow_size(w, h);
        let pixels = glow_pixels(gw, gh, w as f32 / h as f32);
        let mut bmi: BITMAPINFO = zeroed();
        bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as DWORD;
        bmi.bmiHeader.biWidth = gw;
        bmi.bmiHeader.biHeight = -gh; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        SetStretchBltMode(hdc, HALFTONE);
        SetBrushOrgEx(hdc, 0, 0, null_mut());
        StretchDIBits(
            hdc,
            0,
            0,
            w,
            h,
            0,
            0,
            gw,
            gh,
            pixels.as_ptr() as _,
            &bmi,
            DIB_RGB_COLORS,
            SRCCOPY,
        );
    }

    /// The Sense mark: the program icon (white mark on black) in a thin rounded box; on a
    /// watched screen the mark is green (Sense Remote, H5).
    unsafe fn draw_mark(hdc: HDC, lay: &Layout, level: f32) {
        let (x, y, size) = (lay.mark_x, lay.mark_y, lay.mark_size);
        let pen = CreatePen(PS_SOLID, lay.border, colorref(BORDER));
        let old_pen = SelectObject(hdc, pen as _);
        let old_brush = SelectObject(hdc, GetStockObject(BLACK_BRUSH));
        let round = size / 2;
        RoundRect(hdc, x, y, x + size, y + size, round, round);
        SelectObject(hdc, old_brush);
        SelectObject(hdc, old_pen);
        if !pen.is_null() {
            DeleteObject(pen as _);
        }
        let inset = lay.border + size / 16;
        let icon_size = size - 2 * inset;
        if icon_size <= 0 {
            return;
        }
        let icon = LoadImageW(
            GetModuleHandleW(null()),
            IDI_APP_ICON as *const u16,
            IMAGE_ICON,
            icon_size,
            icon_size,
            0,
        ) as HICON;
        if !icon.is_null() {
            // Sense Remote (H5): tinted logo; the plain icon when the tint cannot be drawn.
            if !draw_tinted_icon(hdc, icon, x + inset, y + inset, icon_size, logo_rgb(level)) {
                DrawIconEx(
                    hdc,
                    x + inset,
                    y + inset,
                    icon,
                    icon_size,
                    icon_size,
                    0,
                    null_mut(),
                    DI_NORMAL,
                );
            }
            DestroyIcon(icon);
        }
    }

    /// A 32-bit top-down DIB section selected into a new memory DC.
    struct Canvas {
        dc: HDC,
        bitmap: winapi::shared::windef::HBITMAP,
        old: winapi::shared::windef::HGDIOBJ,
        bits: *mut u32,
        len: usize,
    }

    impl Canvas {
        unsafe fn new(hdc: HDC, w: i32, h: i32) -> Option<Self> {
            if w <= 0 || h <= 0 {
                return None;
            }
            let mut bmi: BITMAPINFO = zeroed();
            bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as DWORD;
            bmi.bmiHeader.biWidth = w;
            bmi.bmiHeader.biHeight = -h; // top-down
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;
            let dc = CreateCompatibleDC(hdc);
            if dc.is_null() {
                return None;
            }
            let mut bits: *mut winapi::ctypes::c_void = null_mut();
            let bitmap = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
            if bitmap.is_null() || bits.is_null() {
                DeleteDC(dc);
                return None;
            }
            let old = SelectObject(dc, bitmap as _);
            Some(Self {
                dc,
                bitmap,
                old,
                bits: bits as *mut u32,
                len: (w * h) as usize,
            })
        }

        unsafe fn pixels(&mut self) -> &mut [u32] {
            std::slice::from_raw_parts_mut(self.bits, self.len)
        }

        /// Draws this premultiplied-alpha canvas onto `hdc`.
        unsafe fn blend_onto(&self, hdc: HDC, x: i32, y: i32, w: i32, h: i32) -> bool {
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA,
            };
            FALSE != AlphaBlend(hdc, x, y, w, h, self.dc, 0, 0, w, h, blend)
        }
    }

    impl Drop for Canvas {
        fn drop(&mut self) {
            unsafe {
                SelectObject(self.dc, self.old);
                DeleteObject(self.bitmap as _);
                DeleteDC(self.dc);
            }
        }
    }

    fn rgb_of(px: u32) -> (u8, u8, u8) {
        (((px >> 16) & 0xff) as u8, ((px >> 8) & 0xff) as u8, (px & 0xff) as u8)
    }

    /// The icon in `tint`: drawn once on black and once on white to recover its transparency
    /// (`tinted_pixel`), then blended onto the screen.
    unsafe fn draw_tinted_icon(
        hdc: HDC,
        icon: HICON,
        x: i32,
        y: i32,
        size: i32,
        tint: (u8, u8, u8),
    ) -> bool {
        let (Some(mut black), Some(mut white)) =
            (Canvas::new(hdc, size, size), Canvas::new(hdc, size, size))
        else {
            return false;
        };
        black.pixels().fill(0);
        white.pixels().fill(0x00ff_ffff);
        for c in [&black, &white] {
            if FALSE == DrawIconEx(c.dc, 0, 0, icon, size, size, 0, null_mut(), DI_NORMAL) {
                return false;
            }
        }
        // GDI may batch the drawing; finish it before reading the pixels.
        GdiFlush();
        let on_white: Vec<u32> = white.pixels().to_vec();
        for (px, w) in black.pixels().iter_mut().zip(on_white) {
            let [b, g, r, a] = tinted_pixel(rgb_of(*px), rgb_of(w), tint);
            *px = u32::from_le_bytes([b, g, r, a]);
        }
        black.blend_onto(hdc, x, y, size, size)
    }

    /// The green glow around a watched screen's logo circle (nothing at level 0).
    unsafe fn draw_halo(hdc: HDC, lay: &Layout, level: f32) {
        if level <= 0.0 {
            return;
        }
        let reach = mark_reach(lay);
        let size = lay.mark_size + 2 * reach;
        let Some(mut canvas) = Canvas::new(hdc, size, size) else {
            return;
        };
        let (r, g, b) = crate::sense::tokens::WATCHED_GREEN;
        let center = size as f32 / 2.0;
        let radius = lay.mark_size as f32 / 2.0;
        let glow = lay.glow as f32;
        for (i, px) in canvas.pixels().iter_mut().enumerate() {
            let (cx, cy) = ((i as i32 % size) as f32 + 0.5, (i as i32 / size) as f32 + 0.5);
            let dist = ((cx - center).powi(2) + (cy - center).powi(2)).sqrt() - radius;
            let a = halo_alpha(dist, glow, level);
            let pre = |c: u8| (c as f32 * a).round() as u8;
            *px = u32::from_le_bytes([pre(b), pre(g), pre(r), (a * 255.0).round() as u8]);
        }
        canvas.blend_onto(hdc, lay.mark_x - reach, lay.mark_y - reach, size, size);
    }

    unsafe fn draw_texts(hdc: HDC, lay: &Layout) {
        SetBkMode(hdc, TRANSPARENT_BK);
        SetTextAlign(hdc, TA_LEFT_BASELINE);
        // Poppins when the computer has it (BRAND_CORE), otherwise Segoe UI.
        let bold = font(hdc, &["Poppins", "Segoe UI"], lay.title_px, 700);
        let light = font(
            hdc,
            &["Poppins ExtraLight", "Poppins Light", "Segoe UI Light"],
            lay.title_px,
            200,
        );
        let sub = font(hdc, &["Poppins Light", "Segoe UI"], lay.sub_px, 300);

        let w_bold = text_width(hdc, bold, TITLE_BOLD);
        let w_light = text_width(hdc, light, TITLE_LIGHT);
        let baseline = lay.title_top + ascent(hdc, bold, lay.title_px);
        let x = (lay.width - (w_bold + w_light)) / 2;
        SetTextColor(hdc, colorref((255, 255, 255)));
        text_out(hdc, bold, x, baseline, TITLE_BOLD);
        text_out(hdc, light, x + w_bold, baseline, TITLE_LIGHT);

        SetTextColor(hdc, colorref(MUTED));
        let w_sub = text_width(hdc, sub, SUBTITLE);
        let sub_baseline = lay.sub_top + ascent(hdc, sub, lay.sub_px);
        text_out(hdc, sub, (lay.width - w_sub) / 2, sub_baseline, SUBTITLE);

        for f in [bold, light, sub] {
            if !f.is_null() {
                DeleteObject(f as _);
            }
        }
    }

    /// First face the computer really has; the last one is taken as it comes.
    unsafe fn font(hdc: HDC, faces: &[&str], px: i32, weight: i32) -> HFONT {
        for (i, face) in faces.iter().enumerate() {
            let name = wide(face);
            let f = CreateFontW(
                -px,
                0,
                0,
                0,
                weight,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                0,
                0,
                CLEARTYPE_QUALITY,
                0,
                name.as_ptr(),
            );
            if f.is_null() {
                continue;
            }
            if i + 1 == faces.len() || font_face_is(hdc, f, face) {
                return f;
            }
            DeleteObject(f as _);
        }
        null_mut()
    }

    unsafe fn font_face_is(hdc: HDC, f: HFONT, face: &str) -> bool {
        let old = SelectObject(hdc, f as _);
        let mut buf = [0u16; 64];
        let n = GetTextFaceW(hdc, buf.len() as i32, buf.as_mut_ptr());
        SelectObject(hdc, old);
        if n <= 0 {
            return false;
        }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        String::from_utf16_lossy(&buf[..end]).eq_ignore_ascii_case(face)
    }

    unsafe fn with_font<T>(hdc: HDC, f: HFONT, run: impl FnOnce() -> T) -> T {
        if f.is_null() {
            return run();
        }
        let old = SelectObject(hdc, f as _);
        let out = run();
        SelectObject(hdc, old);
        out
    }

    unsafe fn text_width(hdc: HDC, f: HFONT, text: &str) -> i32 {
        let t: Vec<u16> = text.encode_utf16().collect();
        with_font(hdc, f, || {
            let mut size: SIZE = zeroed();
            if FALSE == GetTextExtentPoint32W(hdc, t.as_ptr(), t.len() as i32, &mut size) {
                0
            } else {
                size.cx
            }
        })
    }

    unsafe fn ascent(hdc: HDC, f: HFONT, px: i32) -> i32 {
        with_font(hdc, f, || {
            let mut tm: TEXTMETRICW = zeroed();
            if FALSE == GetTextMetricsW(hdc, &mut tm) {
                px
            } else {
                tm.tmAscent
            }
        })
    }

    unsafe fn text_out(hdc: HDC, f: HFONT, x: i32, y: i32, text: &str) {
        let t: Vec<u16> = text.encode_utf16().collect();
        with_font(hdc, f, || {
            TextOutW(hdc, x, y, t.as_ptr(), t.len() as i32);
        });
    }

    #[cfg(test)]
    pub(super) unsafe fn count_windows() -> usize {
        // Sense Remote: imported here; only this test helper uses it (unused-import warning).
        use winapi::um::winuser::FindWindowExW;
        let class = wide(CLASS_NAME);
        let mut n = 0;
        let mut after: HWND = null_mut();
        loop {
            after = FindWindowExW(null_mut(), after, class.as_ptr(), null());
            if after.is_null() {
                return n;
            }
            n += 1;
        }
    }

    #[cfg(test)]
    pub(super) fn screen_count() -> usize {
        unsafe { monitor_screens().map(|r| r.len()).unwrap_or(0) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_is_centered_and_ordered() {
        for (w, h) in [(1920, 1080), (3840, 2160), (1080, 1920), (1280, 800), (800, 600)] {
            let l = layout(w, h);
            assert!(l.mark_x >= 0 && l.mark_x + l.mark_size <= w, "{w}x{h}");
            assert_eq!(l.mark_x, (w - l.mark_size) / 2);
            assert!(l.mark_y >= 0);
            assert!(l.mark_y + l.mark_size < l.title_top);
            assert!(l.title_top + l.title_line < l.sub_top);
            assert!(l.sub_top + l.sub_line <= h, "{w}x{h}");
            let total = l.sub_top + l.sub_line - l.mark_y;
            assert!((l.mark_y - (h - l.sub_top - l.sub_line)).abs() <= 1, "centered {w}x{h}");
            assert!(total < h);
            assert!(l.border >= 1);
        }
        assert_eq!(layout(1920, 1080).title_px, 52);
        assert_eq!(layout(3840, 2160).title_px, 104);
        // A portrait screen keeps the landscape size.
        assert_eq!(layout(1080, 1920).title_px, 52);
    }

    #[test]
    fn layout_survives_tiny_screens() {
        let l = layout(1, 1);
        assert!(l.mark_size >= 1 && l.title_px >= 1 && l.sub_px >= 1);
        assert!(l.mark_y >= 0);
    }

    #[test]
    fn glow_is_dark_at_edges_and_navy_in_the_middle() {
        let aspect = 16.0 / 9.0;
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0), (0.02, 0.5)] {
            assert_eq!(glow_rgb(x, y, aspect), (0, 0, 0), "edge {x},{y}");
        }
        let (r, g, b) = glow_rgb(0.5, 0.5, aspect);
        assert!(b > 40 && b < 120, "{r},{g},{b}");
        assert!(b > r && r > g);
        // Calm: never brighter than the brand gradient itself.
        for j in 0..=20 {
            for i in 0..=20 {
                let (r, g, b) = glow_rgb(i as f32 / 20.0, j as f32 / 20.0, aspect);
                assert!(r <= 100 && g <= 2 && b <= 160);
            }
        }
    }

    #[test]
    fn glow_bitmap_size_and_pixels() {
        assert_eq!(glow_size(1920, 1080), (320, 180));
        assert_eq!(glow_size(1080, 1920), (320, 568));
        assert_eq!(glow_size(0, 0), (320, 320));
        let px = glow_pixels(4, 3, 4.0 / 3.0);
        assert_eq!(px.len(), 12);
        assert_eq!(dib_pixel(0x11, 0x22, 0x33), 0x0011_2233);
        assert_eq!(colorref((0x11, 0x22, 0x33)), 0x0033_2211);
        assert_eq!(colorref(MUTED), 0x0098_8e8e);
    }

    #[test]
    fn restack_only_when_needed() {
        use Layer::*;
        assert_eq!(plan_restack(&[]), Restack::Nothing);
        assert_eq!(plan_restack(&[Other, Keep]), Restack::Nothing);
        // Icon above curtain above everything: right.
        assert_eq!(plan_restack(&[Keep, Curtain, Curtain, Other]), Restack::Nothing);
        assert_eq!(plan_restack(&[Curtain, Other, Other]), Restack::Nothing);
        // Another window jumped above the curtain.
        assert_eq!(plan_restack(&[Other, Curtain, Other]), Restack::Top);
        assert_eq!(plan_restack(&[Curtain, Other, Curtain]), Restack::Top);
        // The icon fell below the curtain.
        assert_eq!(
            plan_restack(&[Curtain, Keep, Other]),
            Restack::UnderKeep { raise_keep: false }
        );
        // Something above both: raise the icon, then the curtain right under it.
        assert_eq!(
            plan_restack(&[Other, Keep, Curtain]),
            Restack::UnderKeep { raise_keep: true }
        );
        assert_eq!(
            plan_restack(&[Keep, Other, Keep, Curtain]),
            Restack::UnderKeep { raise_keep: true }
        );
        assert_eq!(
            plan_restack(&[Keep, Other, Curtain]),
            Restack::UnderKeep { raise_keep: false }
        );
    }

    #[test]
    fn only_the_sense_icon_stays_above() {
        let exe = r"C:\Program Files\SenseRemote\SenseRemote.exe";
        let c = |pid: u32, exe: Option<&str>, topmost: bool| Candidate {
            pid,
            exe: exe.map(str::to_owned),
            topmost,
        };
        let candidates = vec![
            c(10, Some(r"c:\program files\senseremote\senseremote.exe"), true), // icon (--cm)
            c(1, Some(exe), true),                                            // ourselves
            c(11, Some(r"C:\Windows\explorer.exe"), true),                    // taskbar
            c(12, Some(exe), false),                                          // main window
            c(13, None, true),                                                // unknown
        ];
        assert_eq!(keep_above(1, exe, &candidates), vec![0]);
        assert!(keep_above(1, "", &candidates).is_empty());
    }

    // Sense Remote (S7-a, H5): watched screens.
    fn wd(name: &str, x: i32, y: i32) -> WatchedDisplay {
        WatchedDisplay {
            name: name.to_owned(),
            x,
            y,
        }
    }

    #[test]
    fn watched_screens_are_found_by_name_then_corner() {
        let screens = vec![
            (r"\\.\DISPLAY1".to_owned(), 0, 0),
            (r"\\.\DISPLAY2".to_owned(), 1920, 0),
            (r"\\.\DISPLAY3".to_owned(), -1280, 0),
        ];
        assert_eq!(watched_flags(&screens, &[]), vec![false, false, false]);
        // By name, whatever the corner says (DPI can move it).
        assert_eq!(
            watched_flags(&screens, &[wd(r"\\.\display2", 5, 5)]),
            vec![false, true, false]
        );
        // Unknown name: by top-left corner.
        assert_eq!(
            watched_flags(&screens, &[wd("", -1280, 0)]),
            vec![false, false, true]
        );
        assert_eq!(
            watched_flags(&screens, &[wd("other", 0, 0)]),
            vec![true, false, false]
        );
        // "Tümü": every screen.
        assert_eq!(
            watched_flags(
                &screens,
                &[wd(r"\\.\DISPLAY1", 0, 0), wd(r"\\.\DISPLAY2", 1920, 0), wd(r"\\.\DISPLAY3", -1280, 0)]
            ),
            vec![true, true, true]
        );
        // A display that is gone matches nothing.
        assert_eq!(
            watched_flags(&screens, &[wd(r"\\.\DISPLAY9", 99, 99)]),
            vec![false, false, false]
        );
    }

    #[test]
    fn logo_turns_green_in_the_design_time() {
        let ms = crate::sense::tokens::WATCHED_TRANSITION_MS;
        assert_eq!(ms, 400);
        assert_eq!(step_level(0.0, true, ms), 1.0);
        assert_eq!(step_level(1.0, false, ms), 0.0);
        assert!((step_level(0.0, true, ms / 2) - 0.5).abs() < 1e-6);
        // Never overshoots, and stays when there.
        assert_eq!(step_level(0.9, true, ms), 1.0);
        assert_eq!(step_level(1.0, true, 16), 1.0);
        assert_eq!(step_level(0.0, false, 16), 0.0);
        // 16 ms frames reach green in 25 steps (0.4 s).
        let mut level = 0.0;
        let mut frames = 0;
        while level < 1.0 {
            level = step_level(level, true, 16);
            frames += 1;
        }
        assert!((25..=26).contains(&frames), "{frames}");
    }

    #[test]
    fn logo_colour_runs_from_white_to_sense_green() {
        assert_eq!(logo_rgb(0.0), (0xff, 0xff, 0xff));
        assert_eq!(logo_rgb(1.0), (0x00, 0xff, 0xb6));
        assert_eq!(logo_rgb(2.0), (0x00, 0xff, 0xb6));
        let (r, g, b) = logo_rgb(0.5);
        assert!(r > 0x70 && r < 0x90 && g == 0xff && b > 0xd0 && b < 0xe0, "{r},{g},{b}");
    }

    #[test]
    fn halo_fades_out_and_follows_the_level() {
        assert_eq!(halo_alpha(0.0, 14.0, 0.0), 0.0);
        let at_edge = halo_alpha(0.0, 14.0, 1.0);
        assert!(at_edge > 0.5 && at_edge <= 0.6);
        assert!(halo_alpha(7.0, 14.0, 1.0) < at_edge);
        assert!(halo_alpha(28.0, 14.0, 1.0) < 0.01);
        assert!((halo_alpha(0.0, 14.0, 0.5) - at_edge / 2.0).abs() < 1e-6);
        // Inside the circle it is as strong as at the edge (the box covers it).
        assert_eq!(halo_alpha(-5.0, 14.0, 1.0), at_edge);
    }

    #[test]
    fn tinted_pixel_keeps_transparency_and_tints_the_white_mark() {
        let green = (0x00, 0xff, 0xb6);
        // Opaque white mark → green, opaque.
        assert_eq!(tinted_pixel((255, 255, 255), (255, 255, 255), green), [0xb6, 0xff, 0x00, 255]);
        // Opaque black stays black.
        assert_eq!(tinted_pixel((0, 0, 0), (0, 0, 0), green), [0, 0, 0, 255]);
        // Fully transparent: nothing.
        assert_eq!(tinted_pixel((0, 0, 0), (255, 255, 255), green), [0, 0, 0, 0]);
        // Half-covered white edge: half alpha, premultiplied half green.
        let [b, g, r, a] = tinted_pixel((128, 128, 128), (255, 255, 255), green);
        assert_eq!(a, 128);
        assert_eq!((r, g), (0, 128));
        assert!(b <= a);
        // White tint leaves the icon as it is.
        assert_eq!(
            tinted_pixel((200, 100, 50), (200, 100, 50), (255, 255, 255)),
            [50, 100, 200, 255]
        );
    }

    #[test]
    fn set_watched_keeps_the_list() {
        set_watched(vec![wd(r"\\.\DISPLAY1", 0, 0)]);
        assert_eq!(watched(), vec![wd(r"\\.\DISPLAY1", 0, 0)]);
        set_watched(Vec::new());
        assert!(watched().is_empty());
    }

    #[test]
    fn curtain_texts() {
        assert_eq!(format!("{TITLE_BOLD}{TITLE_LIGHT}"), "Bakım yapılıyor");
        assert!(!SUBTITLE.is_empty());
        for t in [TITLE_BOLD, TITLE_LIGHT, SUBTITLE] {
            assert!(!t.to_lowercase().contains("rustdesk"));
        }
    }

    /// Real windows where the runner has a desktop; otherwise the failure must leave nothing.
    #[cfg(windows)]
    #[test]
    fn curtain_covers_every_screen_and_goes_away() {
        match show() {
            Ok(()) => {
                assert!(is_shown());
                // Idempotent.
                assert!(show().is_ok());
                let screens = win::screen_count();
                assert_eq!(unsafe { win::count_windows() }, screens);
                hide();
                assert!(!is_shown());
                assert_eq!(unsafe { win::count_windows() }, 0);
            }
            Err(e) => {
                eprintln!("curtain not available here: {e}");
                assert!(!is_shown());
                assert_eq!(unsafe { win::count_windows() }, 0);
            }
        }
        hide();
        assert!(!is_shown());
    }
}
