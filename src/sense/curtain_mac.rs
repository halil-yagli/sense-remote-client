//! Sense Remote (H5, MAC-SONRA-15): the maintenance curtain of ghost mode (hayalet mod) on macOS.
//!
//! Same curtain as on Windows (`curtain.rs`): every physical screen shows the calm Sense
//! "Bakım yapılıyor" page while the Controller keeps seeing the real screen. The drawing and the
//! windows live in `curtain_mac.mm` (AppKit, main thread of the `--server` process, whose main
//! thread runs the tray's event loop); this module gives it the numbers Windows uses (layout,
//! glow, texts, colours, the Sense mark) so the two platforms look alike, and turns privacy mode
//! into curtain + local input blocked, as RustDesk's own macOS privacy mode blocks input.
//!
//! - Every screen, every Space, above full-screen apps, Dock and menu bar; input goes through to
//!   the windows below (remote input), the curtain never takes focus.
//! - Kept out of capture with `NSWindowSharingNone` (CGDisplayStream). Apple no longer promises
//!   this on macOS 15+ (ScreenCaptureKit); the device test (H5 "Perde ekran kaydına girmiyor")
//!   decides.
//! - The connection stays visible (workshop CLAUDE.md, Security): the curtain asks the Sense icon
//!   (connection manager, `--cm`) to stay above it (`AppDelegate.swift`, `SenseCurtainIcon`).
//! - Local input: physical keyboard and mouse are blocked with an event tap (the same rule as
//!   RustDesk's macOS privacy mode); remote input (enigo) passes. If the tap can not be made,
//!   ghost mode does not turn on.

use super::curtain;

/// The Sense mark (white, transparent), the same file the app draws.
const MARK_SVG: &str = include_str!("../../flutter/assets/sense/mark_white.svg");

/// Path operations of `mark_ops`: move (x, y), line (x, y), cubic (x1, y1, x2, y2, x, y), close.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const OP_MOVE: f32 = 0.0;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const OP_LINE: f32 = 1.0;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const OP_CUBIC: f32 = 2.0;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const OP_CLOSE: f32 = 3.0;

/// One absolute path segment.
#[derive(Debug, Clone, Copy, PartialEq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) enum Seg {
    Move(f32, f32),
    Line(f32, f32),
    Cubic(f32, f32, f32, f32, f32, f32),
    Close,
}

/// SVG path data (`M m L l H h V v C c Z z`, the commands the Sense mark uses) as absolute
/// segments. `None` on anything else, so a changed asset is noticed by the tests, not drawn wrong.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn parse_path(d: &str) -> Option<Vec<Seg>> {
    let mut nums: Vec<f32> = Vec::new();
    let mut out = Vec::new();
    let (mut cx, mut cy, mut sx, mut sy) = (0f32, 0f32, 0f32, 0f32);
    let mut cmd: Option<char> = None;
    let mut chars = d.char_indices().peekable();
    // Tokens: command letters and numbers ("-12.5", ".5", "1e-3"; "1.2.3" = 1.2 .3).
    let mut tokens: Vec<Result<char, f32>> = Vec::new();
    while let Some(&(i, c)) = chars.peek() {
        if c.is_ascii_alphabetic() && c != 'e' && c != 'E' {
            tokens.push(Ok(c));
            chars.next();
        } else if c == '-' || c == '+' || c == '.' || c.is_ascii_digit() {
            let start = i;
            let mut end = i;
            let mut seen_dot = false;
            let mut seen_exp = false;
            let mut first = true;
            while let Some(&(j, ch)) = chars.peek() {
                let ok = if ch.is_ascii_digit() {
                    true
                } else if ch == '.' && !seen_dot && !seen_exp {
                    seen_dot = true;
                    true
                } else if (ch == 'e' || ch == 'E') && !seen_exp && !first {
                    seen_exp = true;
                    true
                } else if (ch == '-' || ch == '+')
                    && (first || matches!(d[..j].chars().last(), Some('e') | Some('E')))
                {
                    true
                } else {
                    false
                };
                if !ok {
                    break;
                }
                first = false;
                end = j + ch.len_utf8();
                chars.next();
            }
            tokens.push(Err(d[start..end].parse::<f32>().ok()?));
        } else {
            chars.next();
        }
    }
    let flush = |cmd: char,
                 nums: &mut Vec<f32>,
                 out: &mut Vec<Seg>,
                 cx: &mut f32,
                 cy: &mut f32,
                 sx: &mut f32,
                 sy: &mut f32|
     -> Option<()> {
        let rel = cmd.is_ascii_lowercase();
        let (bx, by) = if rel { (*cx, *cy) } else { (0.0, 0.0) };
        match cmd.to_ascii_uppercase() {
            'Z' => {
                if !nums.is_empty() {
                    return None;
                }
                out.push(Seg::Close);
                *cx = *sx;
                *cy = *sy;
            }
            'M' | 'L' => {
                if nums.is_empty() || nums.len() % 2 != 0 {
                    return None;
                }
                for (k, p) in nums.chunks(2).enumerate() {
                    let (bx, by) = if rel { (*cx, *cy) } else { (bx, by) };
                    let (x, y) = (bx + p[0], by + p[1]);
                    if k == 0 && cmd.to_ascii_uppercase() == 'M' {
                        out.push(Seg::Move(x, y));
                        *sx = x;
                        *sy = y;
                    } else {
                        out.push(Seg::Line(x, y));
                    }
                    *cx = x;
                    *cy = y;
                }
            }
            'H' | 'V' => {
                if nums.is_empty() {
                    return None;
                }
                for &v in nums.iter() {
                    if cmd.to_ascii_uppercase() == 'H' {
                        *cx = if rel { *cx + v } else { v };
                    } else {
                        *cy = if rel { *cy + v } else { v };
                    }
                    out.push(Seg::Line(*cx, *cy));
                }
            }
            'C' => {
                if nums.is_empty() || nums.len() % 6 != 0 {
                    return None;
                }
                for p in nums.chunks(6) {
                    let (bx, by) = if rel { (*cx, *cy) } else { (0.0, 0.0) };
                    let seg = Seg::Cubic(
                        bx + p[0],
                        by + p[1],
                        bx + p[2],
                        by + p[3],
                        bx + p[4],
                        by + p[5],
                    );
                    out.push(seg);
                    *cx = bx + p[4];
                    *cy = by + p[5];
                }
            }
            _ => return None,
        }
        nums.clear();
        Some(())
    };
    for t in tokens {
        match t {
            Ok(c) => {
                if let Some(prev) = cmd {
                    flush(prev, &mut nums, &mut out, &mut cx, &mut cy, &mut sx, &mut sy)?;
                }
                cmd = Some(c);
            }
            Err(n) => {
                cmd?;
                nums.push(n);
            }
        }
    }
    if let Some(prev) = cmd {
        flush(prev, &mut nums, &mut out, &mut cx, &mut cy, &mut sx, &mut sy)?;
    }
    Some(out)
}

/// Value of `name="…"` in the first tag of `svg` that has it, after byte `from`.
fn attr(svg: &str, name: &str, from: usize) -> Option<(String, usize)> {
    let key = format!(" {}=\"", name);
    let start = svg.get(from..)?.find(&key)? + from + key.len();
    let end = svg[start..].find('"')? + start;
    Some((svg[start..end].to_owned(), end))
}

/// The Sense mark as flat path operations (`OP_*`), fitted into the unit square (y down,
/// centred, aspect kept). Empty when the asset can not be read; the curtain then shows the
/// circle without the mark.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn mark_ops(svg: &str) -> Vec<f32> {
    let Some((view_box, _)) = attr(svg, "viewBox", 0) else {
        return Vec::new();
    };
    let vb: Vec<f32> = view_box
        .split(|c: char| c == ' ' || c == ',')
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse().ok())
        .collect();
    if vb.len() != 4 || vb[2] <= 0.0 || vb[3] <= 0.0 {
        return Vec::new();
    }
    let scale = 1.0 / vb[2].max(vb[3]);
    let (ox, oy) = (
        (1.0 - vb[2] * scale) / 2.0 - vb[0] * scale,
        (1.0 - vb[3] * scale) / 2.0 - vb[1] * scale,
    );
    let p = |x: f32, y: f32| [ox + x * scale, oy + y * scale];
    let mut ops = Vec::new();
    let mut from = 0;
    while let Some((d, end)) = attr(svg, "d", from) {
        from = end;
        let Some(segs) = parse_path(&d) else {
            return Vec::new();
        };
        for s in segs {
            match s {
                Seg::Move(x, y) => {
                    ops.push(OP_MOVE);
                    ops.extend(p(x, y));
                }
                Seg::Line(x, y) => {
                    ops.push(OP_LINE);
                    ops.extend(p(x, y));
                }
                Seg::Cubic(x1, y1, x2, y2, x, y) => {
                    ops.push(OP_CUBIC);
                    ops.extend(p(x1, y1));
                    ops.extend(p(x2, y2));
                    ops.extend(p(x, y));
                }
                Seg::Close => ops.push(OP_CLOSE),
            }
        }
    }
    ops
}

/// The Sense mark of the curtain (read once).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn sense_mark_ops() -> &'static [f32] {
    static OPS: std::sync::OnceLock<Vec<f32>> = std::sync::OnceLock::new();
    OPS.get_or_init(|| mark_ops(MARK_SVG))
}

/// Whether the screens (display id, left, top) are watched: `curtain::watched_flags` with the
/// macOS display id (`CGDirectDisplayID`, the display name the video service uses) as the name.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn watched_for(
    screens: &[(u32, i32, i32)],
    watched: &[curtain::WatchedDisplay],
) -> Vec<bool> {
    let screens: Vec<(String, i32, i32)> = screens
        .iter()
        .map(|(id, x, y)| (id.to_string(), *x, *y))
        .collect();
    curtain::watched_flags(&screens, watched)
}

#[cfg(target_os = "macos")]
pub use mac::{hide, show, watched_changed, PrivacyModeImpl};

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use crate::privacy_mode::{PrivacyMode, PrivacyModeState, INVALID_PRIVACY_MODE_CONN_ID};
    use hbb_common::{allow_err, bail, log, ResultType};
    use std::{ffi::CString, os::raw::c_char, sync::OnceLock};

    /// `curtain::Layout`, as `curtain_mac.mm` reads it.
    #[repr(C)]
    pub struct LayoutC {
        width: i32,
        height: i32,
        mark_x: i32,
        mark_y: i32,
        mark_size: i32,
        border: i32,
        title_px: i32,
        title_top: i32,
        title_line: i32,
        sub_px: i32,
        sub_top: i32,
        sub_line: i32,
        glow: i32,
    }

    #[repr(C)]
    pub struct ScreenC {
        display_id: u32,
        x: i32,
        y: i32,
    }

    /// Must match `SenseCurtainConfig` in `curtain_mac.mm`.
    #[repr(C)]
    pub struct ConfigC {
        title_bold: *const c_char,
        title_light: *const c_char,
        subtitle: *const c_char,
        mark_ops: *const f32,
        mark_ops_len: usize,
        muted: [u8; 3],
        border: [u8; 3],
        green: [u8; 3],
        white: [u8; 3],
        transition_ms: u32,
        layout: extern "C" fn(i32, i32, *mut LayoutC),
        glow_size: extern "C" fn(i32, i32, *mut i32, *mut i32),
        glow_pixels: extern "C" fn(i32, i32, f32, *mut u32),
        watched: extern "C" fn(*const ScreenC, usize, *mut bool),
    }

    extern "C" {
        fn SenseCurtainMacShow(cfg: *const ConfigC, timeout_ms: u32) -> bool;
        fn SenseCurtainMacHide(timeout_ms: u32);
        fn SenseCurtainMacWatchedChanged();
        fn SenseCurtainMacBlockInput(on: bool, timeout_ms: u32) -> bool;
    }

    const START_TIMEOUT_MS: u32 = 3000;
    const STOP_TIMEOUT_MS: u32 = 2000;

    extern "C" fn layout_cb(w: i32, h: i32, out: *mut LayoutC) {
        if out.is_null() {
            return;
        }
        let l = curtain::layout(w, h);
        unsafe {
            *out = LayoutC {
                width: l.width,
                height: l.height,
                mark_x: l.mark_x,
                mark_y: l.mark_y,
                mark_size: l.mark_size,
                border: l.border,
                title_px: l.title_px,
                title_top: l.title_top,
                title_line: l.title_line,
                sub_px: l.sub_px,
                sub_top: l.sub_top,
                sub_line: l.sub_line,
                glow: l.glow,
            };
        }
    }

    extern "C" fn glow_size_cb(w: i32, h: i32, gw: *mut i32, gh: *mut i32) {
        if gw.is_null() || gh.is_null() {
            return;
        }
        let (a, b) = curtain::glow_size(w, h);
        unsafe {
            *gw = a;
            *gh = b;
        }
    }

    /// Fills `gw * gh` pixels (0x00RRGGBB, as on Windows).
    extern "C" fn glow_pixels_cb(gw: i32, gh: i32, aspect: f32, out: *mut u32) {
        if out.is_null() || gw <= 0 || gh <= 0 {
            return;
        }
        let px = curtain::glow_pixels(gw, gh, aspect);
        unsafe {
            std::ptr::copy_nonoverlapping(px.as_ptr(), out, px.len().min((gw * gh) as usize));
        }
    }

    extern "C" fn watched_cb(screens: *const ScreenC, n: usize, out: *mut bool) {
        if screens.is_null() || out.is_null() || n == 0 {
            return;
        }
        let list: Vec<(u32, i32, i32)> = unsafe { std::slice::from_raw_parts(screens, n) }
            .iter()
            .map(|s| (s.display_id, s.x, s.y))
            .collect();
        let flags = watched_for(&list, &curtain::watched());
        let out = unsafe { std::slice::from_raw_parts_mut(out, n) };
        for (o, f) in out.iter_mut().zip(flags) {
            *o = f;
        }
    }

    struct Config {
        _texts: [CString; 3],
        c: ConfigC,
    }

    // The pointers point into `_texts` and a `'static` slice; nothing is written after init.
    unsafe impl Send for Config {}
    unsafe impl Sync for Config {}

    fn config() -> &'static Config {
        static CONFIG: OnceLock<Config> = OnceLock::new();
        CONFIG.get_or_init(|| {
            let text = |s: &str| CString::new(s).unwrap_or_default();
            let texts = [
                text(curtain::TITLE_BOLD),
                text(curtain::TITLE_LIGHT),
                text(curtain::SUBTITLE),
            ];
            let ops = sense_mark_ops();
            let rgb = |(r, g, b): (u8, u8, u8)| [r, g, b];
            let c = ConfigC {
                title_bold: texts[0].as_ptr(),
                title_light: texts[1].as_ptr(),
                subtitle: texts[2].as_ptr(),
                mark_ops: ops.as_ptr(),
                mark_ops_len: ops.len(),
                muted: rgb(curtain::MUTED),
                border: rgb(curtain::BORDER),
                green: rgb(crate::sense::tokens::WATCHED_GREEN),
                white: rgb(crate::sense::tokens::UNWATCHED_WHITE),
                transition_ms: crate::sense::tokens::WATCHED_TRANSITION_MS,
                layout: layout_cb,
                glow_size: glow_size_cb,
                glow_pixels: glow_pixels_cb,
                watched: watched_cb,
            };
            // CString data lives on the heap: moving the array keeps the pointers valid.
            Config { _texts: texts, c }
        })
    }

    /// Shows the curtain on every screen; returns once it is up (or failed).
    pub fn show() -> ResultType<()> {
        if unsafe { SenseCurtainMacShow(&config().c, START_TIMEOUT_MS) } {
            log::info!("Sense curtain on (macOS)");
            Ok(())
        } else {
            bail!("Sense curtain did not start (macOS)")
        }
    }

    /// Removes the curtain from every screen.
    pub fn hide() {
        unsafe { SenseCurtainMacHide(STOP_TIMEOUT_MS) };
        log::info!("Sense curtain off (macOS)");
    }

    /// The watched screens changed (`curtain::set_watched`).
    pub fn watched_changed() {
        unsafe { SenseCurtainMacWatchedChanged() };
    }

    fn block_input(on: bool) -> bool {
        unsafe { SenseCurtainMacBlockInput(on, START_TIMEOUT_MS) }
    }

    /// Sense Remote: privacy mode on macOS = maintenance curtain + local input blocked (the
    /// Windows mode, `win_exclude_from_capture`). Registered under RustDesk's macOS key
    /// (`privacy_mode_impl_macos`), so Controllers of any version know it.
    pub struct PrivacyModeImpl {
        impl_key: String,
        conn_id: i32,
    }

    impl PrivacyModeImpl {
        pub fn new(impl_key: &str) -> Self {
            Self {
                impl_key: impl_key.to_owned(),
                conn_id: INVALID_PRIVACY_MODE_CONN_ID,
            }
        }
    }

    impl PrivacyMode for PrivacyModeImpl {
        fn is_async_privacy_mode(&self) -> bool {
            false
        }

        fn init(&self) -> ResultType<()> {
            Ok(())
        }

        fn clear(&mut self) {
            allow_err!(self.turn_off_privacy(self.conn_id, None));
        }

        fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
            if self.check_on_conn_id(conn_id)? {
                log::debug!("Privacy mode of conn {} is already on", conn_id);
                return Ok(true);
            }
            curtain::show()?;
            if !block_input(true) {
                curtain::hide();
                bail!("Sense curtain: local input could not be blocked (Accessibility)");
            }
            self.conn_id = conn_id;
            Ok(true)
        }

        fn turn_off_privacy(
            &mut self,
            conn_id: i32,
            _state: Option<PrivacyModeState>,
        ) -> ResultType<()> {
            // As in RustDesk's macOS mode, `_state` is not sent to the connection manager
            // (there is no local key that turns the mode off on macOS).
            self.check_off_conn_id(conn_id)?;
            let unblocked = block_input(false);
            curtain::hide();
            self.conn_id = INVALID_PRIVACY_MODE_CONN_ID;
            if !unblocked {
                bail!("Sense curtain: local input could not be unblocked in time");
            }
            Ok(())
        }

        #[inline]
        fn pre_conn_id(&self) -> i32 {
            self.conn_id
        }

        #[inline]
        fn get_impl_key(&self) -> &str {
            &self.impl_key
        }
    }

    impl Drop for PrivacyModeImpl {
        fn drop(&mut self) {
            if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
                allow_err!(self.turn_off_privacy(self.conn_id, None));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_relative_and_absolute_commands() {
        let segs = parse_path("M10,20l5-5h3v-2c1,1,2,2,3,3Z").unwrap();
        assert_eq!(
            segs,
            vec![
                Seg::Move(10.0, 20.0),
                Seg::Line(15.0, 15.0),
                Seg::Line(18.0, 15.0),
                Seg::Line(18.0, 13.0),
                Seg::Cubic(19.0, 14.0, 20.0, 15.0, 21.0, 16.0),
                Seg::Close,
            ]
        );
        // Repeated pairs after M are lines; "1.5.5" is 1.5 then .5; exponents.
        let segs = parse_path("M0 0 1 1 L2 2 C 1.5.5 1e1 -2e-1 3 3 z").unwrap();
        assert_eq!(segs[1], Seg::Line(1.0, 1.0));
        assert_eq!(segs[3], Seg::Cubic(1.5, 0.5, 10.0, -0.2, 3.0, 3.0));
        // Close returns to the subpath start; relative commands continue from there.
        let segs = parse_path("M5 5 l1 0 z l1 1").unwrap();
        assert_eq!(segs[3], Seg::Line(6.0, 6.0));
    }

    #[test]
    fn rejects_what_the_mark_does_not_use() {
        assert!(parse_path("M0 0 A 1 1 0 0 1 2 2").is_none());
        assert!(parse_path("M0 0 L1").is_none());
        assert!(parse_path("1 2").is_none());
    }

    #[test]
    fn sense_mark_fits_the_unit_square() {
        let ops = mark_ops(MARK_SVG);
        assert!(!ops.is_empty(), "flutter/assets/sense/mark_white.svg is readable");
        // Walk the ops: two closed shapes, every end point inside the square (y down).
        let (mut i, mut moves, mut closes) = (0, 0, 0);
        let (mut min_x, mut max_x, mut min_y, mut max_y) = (1f32, 0f32, 1f32, 0f32);
        while i < ops.len() {
            let n = match ops[i] {
                x if x == OP_MOVE => {
                    moves += 1;
                    2
                }
                x if x == OP_LINE => 2,
                x if x == OP_CUBIC => 6,
                x if x == OP_CLOSE => {
                    closes += 1;
                    0
                }
                other => panic!("unknown op {other}"),
            };
            if n > 0 {
                let (x, y) = (ops[i + n - 1], ops[i + n]);
                assert!((-0.01..=1.01).contains(&x) && (-0.01..=1.01).contains(&y), "{x},{y}");
                min_x = min_x.min(x);
                max_x = max_x.max(x);
                min_y = min_y.min(y);
                max_y = max_y.max(y);
            }
            i += 1 + n;
        }
        assert_eq!(i, ops.len());
        assert_eq!((moves, closes), (2, 2));
        // The mark (end points) spans most of the square's width and is centred.
        assert!(max_x - min_x > 0.85, "{min_x}..{max_x}");
        assert!(((min_y + max_y) / 2.0 - 0.5).abs() < 0.03, "{min_y}..{max_y}");
        assert_eq!(sense_mark_ops(), ops.as_slice());
    }

    #[test]
    fn watched_screens_by_display_id_then_origin() {
        use crate::sense::curtain::WatchedDisplay;
        let wd = |name: &str, x: i32, y: i32| WatchedDisplay {
            name: name.to_owned(),
            x,
            y,
        };
        let screens = [(1, 0, 0), (2, 1440, 0), (3, -1920, 0)];
        assert_eq!(watched_for(&screens, &[wd("2", 0, 0)]), vec![false, true, false]);
        // Unknown id: found by its top-left corner.
        assert_eq!(watched_for(&screens, &[wd("99", -1920, 0)]), vec![false, false, true]);
        // "Tümü": every screen.
        let all = [wd("1", 0, 0), wd("2", 1440, 0), wd("3", -1920, 0)];
        assert_eq!(watched_for(&screens, &all), vec![true, true, true]);
        assert_eq!(watched_for(&screens, &[]), vec![false, false, false]);
    }
}
