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

/// True while the curtain is on (for the heartbeat `maintenance_curtain`, I7 owner).
#[allow(dead_code)]
pub fn is_shown() -> bool {
    SHOWN.load(Ordering::SeqCst)
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
        time::Duration,
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
                CreateFontW, CreatePen, DeleteObject, GetStockObject, GetTextExtentPoint32W,
                GetTextFaceW, GetTextMetricsW, RoundRect, SelectObject, SetBkMode,
                SetBrushOrgEx, SetStretchBltMode, SetTextAlign, SetTextColor, StretchDIBits,
                TextOutW, BITMAPINFO, BITMAPINFOHEADER, TEXTMETRICW,
            },
            winnt::{HANDLE, PROCESS_QUERY_LIMITED_INFORMATION},
            winuser::{
                BeginPaint, CreateWindowExW, DefWindowProcW, DestroyIcon, DestroyWindow,
                DispatchMessageW, DrawIconEx, EndPaint, EnumDisplayMonitors, EnumWindows,
                FindWindowExW, GetClientRect, GetMessageW, GetMonitorInfoA, GetTopWindow,
                GetWindow, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId,
                IsWindowVisible, KillTimer, LoadImageW, PeekMessageW, PostThreadMessageW,
                RegisterClassExW, SetLayeredWindowAttributes, SetTimer, SetWindowPos, ShowWindow,
                TranslateMessage, UpdateWindow, MONITORINFO, MSG, PAINTSTRUCT, WNDCLASSEXW,
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
                if msg.hwnd.is_null() && msg.message == WM_TIMER {
                    curtain.refresh();
                    continue;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if timer != 0 {
                KillTimer(null_mut(), timer);
            }
            curtain.close();
        }
    }

    type MonitorRect = (i32, i32, i32, i32);

    struct Curtain {
        hinst: HINSTANCE,
        windows: Vec<HWND>,
        rects: Vec<MonitorRect>,
        own_pid: u32,
        own_exe: String,
    }

    impl Curtain {
        unsafe fn open() -> ResultType<Self> {
            let hinst = GetModuleHandleW(null());
            register_class(hinst)?;
            let rects = monitor_rects()?;
            if rects.is_empty() {
                bail!("no screen found");
            }
            let windows = create_windows(hinst, &rects)?;
            let mut curtain = Self {
                hinst,
                windows,
                rects,
                own_pid: GetCurrentProcessId(),
                own_exe: process_exe(GetCurrentProcess()).unwrap_or_default(),
            };
            curtain.restack();
            if curtain.keep_windows().is_empty() {
                log::warn!("Sense curtain: no Sense icon window found yet");
            }
            Ok(curtain)
        }

        /// Follows screen changes and keeps the order: Sense icon, curtain, everything else.
        unsafe fn refresh(&mut self) {
            match monitor_rects() {
                Ok(rects) if !rects.is_empty() && rects != self.rects => {
                    // New windows first, so the screens are never uncovered in between.
                    match create_windows(self.hinst, &rects) {
                        Ok(windows) => {
                            let old = std::mem::replace(&mut self.windows, windows);
                            self.rects = rects;
                            destroy_windows(&old);
                            log::info!("Sense curtain: screens changed ({})", self.rects.len());
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

    unsafe fn create_windows(hinst: HINSTANCE, rects: &[MonitorRect]) -> ResultType<Vec<HWND>> {
        let class = wide(CLASS_NAME);
        let title = wide(WINDOW_TITLE);
        let ex_style = WS_EX_TOPMOST
            | WS_EX_TOOLWINDOW
            | WS_EX_LAYERED
            | WS_EX_TRANSPARENT
            | WS_EX_NOACTIVATE;
        let mut windows = Vec::new();
        for &(left, top, right, bottom) in rects {
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

    unsafe fn monitor_rects() -> ResultType<Vec<MonitorRect>> {
        let mut rects: Vec<MonitorRect> = Vec::new();
        if FALSE
            == EnumDisplayMonitors(
                null_mut(),
                null(),
                Some(collect_monitor),
                &mut rects as *mut Vec<MonitorRect> as LPARAM,
            )
        {
            bail!("EnumDisplayMonitors: {}", Error::last_os_error());
        }
        Ok(rects)
    }

    unsafe extern "system" fn collect_monitor(
        hmon: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        lparam: LPARAM,
    ) -> BOOL {
        let rects = &mut *(lparam as *mut Vec<MonitorRect>);
        let mut info: MONITORINFO = zeroed();
        info.cbSize = size_of::<MONITORINFO>() as DWORD;
        if FALSE != GetMonitorInfoA(hmon, &mut info) {
            let r = info.rcMonitor;
            rects.push((r.left, r.top, r.right, r.bottom));
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
            draw_mark(hdc, &lay);
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

    /// The Sense mark: the program icon (white mark on black) in a thin rounded box.
    unsafe fn draw_mark(hdc: HDC, lay: &Layout) {
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
            DestroyIcon(icon);
        }
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
        unsafe { monitor_rects().map(|r| r.len()).unwrap_or(0) }
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
