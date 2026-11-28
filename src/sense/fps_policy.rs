//! Sense Remote (Sürüm 12, U168c, #168): frame rate ceiling.
//!
//! Measured (#168, Slayer → 4090, same network, direct): at most 25.6 fps, 90th percentile
//! 17.4, at 2.3 Mbit/s and 3–4 ms delay. The network was not the limit. The ceiling was the
//! viewer's request: for the stock qualities (Dengeli / En iyi / Hızlı) the Controller's
//! automatic loop (`client/io_loop.rs` `fps_control`) asks the Host for at most 30 fps, and the
//! Host's QoS (`server/video_qos.rs`) never goes above what the viewer asked for.
//!
//! The rule now:
//! - Controller: on a direct connection with a stock quality the ceiling it asks for is
//!   [`DIRECT_FPS_CAP`] (60); its decoder limit (`decode_fps * 9 / 10`) still applies. Relayed
//!   connections and a custom quality (the person's own fps) keep the stock rule.
//! - Host: a request above the stock 30 is capped by the Host's display refresh rate (a 60 Hz
//!   screen gets 60, never more frames than it draws); 30 and below are left as they are, so
//!   relayed connections and older Controllers behave exactly as before.
//! - Host: the capture + encode time per frame is measured; when it, not the request, is what
//!   holds the frame rate down, `video/fps_cap` says `encoder` ([`EncodeMeter`]).

use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

/// RustDesk's frame rate for the stock qualities (and its default `custom-fps`).
pub const STOCK_FPS_CAP: usize = 30;
/// Ceiling a Controller asks for on a direct connection with a stock quality.
pub const DIRECT_FPS_CAP: usize = 60;
/// RustDesk's accepted range for a viewer's fps request (`client/io_loop.rs`).
const REQUEST_RANGE: std::ops::RangeInclusive<usize> = 5..=120;

/// Controller: the most frames per second the automatic loop asks the Host for.
/// `custom_fps` is the session's stored request (`LoginConfigHandler::custom_fps`).
pub fn controller_fps_ceiling(direct: bool, custom_quality: bool, custom_fps: Option<usize>) -> usize {
    let stock = custom_fps
        .filter(|fps| REQUEST_RANGE.contains(fps))
        .unwrap_or(STOCK_FPS_CAP);
    if direct && !custom_quality {
        DIRECT_FPS_CAP
    } else {
        stock
    }
}

/// Why the Host's ceiling is what it is (`video/fps_cap` `reason`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapReason {
    /// The viewer's request (quality, its decoder, its own fps choice).
    Viewer,
    /// The Host's display refresh rate.
    Refresh,
}

impl CapReason {
    pub fn as_str(self) -> &'static str {
        match self {
            CapReason::Viewer => "viewer",
            CapReason::Refresh => "refresh",
        }
    }
}

/// Host: a viewer's request capped by the display refresh rate. Only requests above the stock
/// 30 are touched; an unknown refresh rate leaves the request as it is.
pub fn host_fps_cap(requested: u32, refresh_hz: Option<u32>) -> (u32, CapReason) {
    match refresh_hz {
        Some(hz) if requested > STOCK_FPS_CAP as u32 && hz >= 1 => {
            let limit = hz.max(STOCK_FPS_CAP as u32);
            if requested > limit {
                (limit, CapReason::Refresh)
            } else {
                (requested, CapReason::Viewer)
            }
        }
        _ => (requested, CapReason::Viewer),
    }
}

/// Refresh rate of each captured display (Hz, rounded), set when its capture starts.
static REFRESH: Mutex<Option<HashMap<usize, u32>>> = Mutex::new(None);

/// Hz from the panel report's `refresh_hz` (59.94 -> 60); out of range -> `None`.
pub fn round_hz(hz: Option<f64>) -> Option<u32> {
    let hz = hz?;
    (hz.is_finite() && (1.0..=1000.0).contains(&hz)).then(|| hz.round() as u32)
}

/// Host: remembers display `index`'s refresh rate (`None` = unreadable, forgotten).
pub fn set_display_refresh(index: usize, hz: Option<u32>) {
    let mut map = REFRESH.lock().unwrap();
    let map = map.get_or_insert_with(HashMap::new);
    match hz {
        Some(hz) => {
            map.insert(index, hz);
        }
        None => {
            map.remove(&index);
        }
    }
}

/// Host: the highest refresh rate among the captured displays (`None` = none known).
pub fn host_refresh() -> Option<u32> {
    REFRESH.lock().unwrap().as_ref().and_then(highest)
}

fn highest(map: &HashMap<usize, u32>) -> Option<u32> {
    map.values().copied().max()
}

/// Host: reads display `index`'s refresh rate from the same list the panel report uses and
/// remembers it. Called once when that display's capture starts.
pub fn note_display_refresh(index: usize) {
    let (displays, _) = super::report::displays();
    let hz = displays
        .iter()
        .find(|d| d.get("index").and_then(|v| v.as_u64()) == Some(index as u64))
        .and_then(|d| round_hz(d.get("refresh_hz").and_then(|v| v.as_f64())));
    set_display_refresh(index, hz);
}

/// Window over which the capture + encode time is judged.
pub const ENCODE_WINDOW: Duration = Duration::from_secs(5);
/// Share of the frame interval the work may take before the encoder counts as the limit.
const ENCODE_BUSY_SHARE: f64 = 0.9;
/// Fewer frames than this in a window say nothing (a still screen).
const ENCODE_MIN_FRAMES: u32 = 10;

/// Host: capture + encode time per frame on one display.
#[derive(Debug, Clone)]
pub struct EncodeMeter {
    window_start: Instant,
    frames: u32,
    busy: Duration,
    limited: bool,
}

/// What a finished window found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncodeVerdict {
    /// Frames per second the encode time allows.
    pub achievable_fps: u32,
    /// The encoder holds the frame rate below the target.
    pub limited: bool,
    /// `limited` differs from the previous window (log / event once per change).
    pub changed: bool,
}

impl EncodeMeter {
    pub fn new(now: Instant) -> Self {
        Self {
            window_start: now,
            frames: 0,
            busy: Duration::ZERO,
            limited: false,
        }
    }

    /// One encoded frame took `work` (conversion + encode).
    pub fn on_frame(&mut self, work: Duration) {
        self.frames = self.frames.saturating_add(1);
        self.busy += work;
    }

    /// Call every loop; at the end of a window, the verdict against the target interval `spf`.
    pub fn tick(&mut self, now: Instant, spf: Duration) -> Option<EncodeVerdict> {
        if now.saturating_duration_since(self.window_start) < ENCODE_WINDOW {
            return None;
        }
        let frames = self.frames;
        let busy = self.busy;
        self.window_start = now;
        self.frames = 0;
        self.busy = Duration::ZERO;
        if frames < ENCODE_MIN_FRAMES {
            return None;
        }
        let per_frame = busy.as_secs_f64() / frames as f64;
        let achievable_fps = if busy > Duration::ZERO {
            (frames as f64 / busy.as_secs_f64()).round().min(u32::MAX as f64) as u32
        } else {
            u32::MAX
        };
        let limited = per_frame >= spf.as_secs_f64() * ENCODE_BUSY_SHARE;
        let changed = limited != self.limited;
        self.limited = limited;
        Some(EncodeVerdict {
            achievable_fps,
            limited,
            changed,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_stock_quality_asks_for_sixty() {
        // #168: Slayer -> 4090, same network, "Dengeli": was 30.
        assert_eq!(controller_fps_ceiling(true, false, None), 60);
        assert_eq!(controller_fps_ceiling(true, false, Some(30)), 60);
    }

    #[test]
    fn relayed_connection_keeps_the_stock_ceiling() {
        assert_eq!(controller_fps_ceiling(false, false, None), 30);
        assert_eq!(controller_fps_ceiling(false, false, Some(30)), 30);
    }

    #[test]
    fn custom_quality_keeps_the_persons_choice() {
        assert_eq!(controller_fps_ceiling(true, true, Some(90)), 90);
        assert_eq!(controller_fps_ceiling(true, true, Some(15)), 15);
        assert_eq!(controller_fps_ceiling(false, true, Some(45)), 45);
        // RustDesk's out-of-range rule stays.
        assert_eq!(controller_fps_ceiling(true, true, Some(2)), 30);
        assert_eq!(controller_fps_ceiling(true, true, Some(500)), 30);
        assert_eq!(controller_fps_ceiling(true, true, None), 30);
    }

    #[test]
    fn host_caps_a_high_request_at_its_refresh_rate() {
        assert_eq!(host_fps_cap(60, Some(60)), (60, CapReason::Viewer));
        assert_eq!(host_fps_cap(60, Some(144)), (60, CapReason::Viewer));
        assert_eq!(host_fps_cap(60, Some(50)), (50, CapReason::Refresh));
        assert_eq!(host_fps_cap(120, Some(60)), (60, CapReason::Refresh));
    }

    #[test]
    fn host_leaves_stock_requests_and_unknown_refresh_alone() {
        // Relayed and older Controllers: exactly as before.
        assert_eq!(host_fps_cap(30, Some(24)), (30, CapReason::Viewer));
        assert_eq!(host_fps_cap(20, Some(60)), (20, CapReason::Viewer));
        assert_eq!(host_fps_cap(60, None), (60, CapReason::Viewer));
        // A refresh rate below 30 never pulls a high request under the stock 30.
        assert_eq!(host_fps_cap(60, Some(24)), (30, CapReason::Refresh));
        assert_eq!(host_fps_cap(60, Some(0)), (60, CapReason::Viewer));
    }

    #[test]
    fn report_refresh_rates_round_to_whole_hertz() {
        assert_eq!(round_hz(Some(59.94)), Some(60));
        assert_eq!(round_hz(Some(143.86)), Some(144));
        assert_eq!(round_hz(Some(0.0)), None);
        assert_eq!(round_hz(Some(f64::NAN)), None);
        assert_eq!(round_hz(None), None);
    }

    #[test]
    fn the_highest_display_refresh_counts() {
        // The registry itself is not touched here: the QoS tests run in parallel and read it.
        assert_eq!(highest(&HashMap::new()), None);
        assert_eq!(highest(&HashMap::from([(0, 60), (1, 144)])), Some(144));
    }

    fn ms(v: u64) -> Duration {
        Duration::from_millis(v)
    }

    #[test]
    fn encoder_slower_than_the_target_is_reported_once() {
        let t0 = Instant::now();
        let mut meter = EncodeMeter::new(t0);
        let spf = ms(1000 / 60); // 16 ms target
        for _ in 0..100 {
            meter.on_frame(ms(25)); // 40 fps worth of encode time
        }
        assert_eq!(meter.tick(t0 + ms(1000), spf), None, "window not over");
        let v = meter.tick(t0 + ENCODE_WINDOW, spf).unwrap();
        assert!(v.limited && v.changed);
        assert_eq!(v.achievable_fps, 40);
        for _ in 0..100 {
            meter.on_frame(ms(25));
        }
        let v = meter.tick(t0 + ENCODE_WINDOW * 2, spf).unwrap();
        assert!(v.limited && !v.changed, "same state: no second event");
        for _ in 0..100 {
            meter.on_frame(ms(4));
        }
        let v = meter.tick(t0 + ENCODE_WINDOW * 3, spf).unwrap();
        assert!(!v.limited && v.changed);
        assert_eq!(v.achievable_fps, 250);
    }

    #[test]
    fn a_still_screen_says_nothing_about_the_encoder() {
        let t0 = Instant::now();
        let mut meter = EncodeMeter::new(t0);
        for _ in 0..3 {
            meter.on_frame(ms(100));
        }
        assert_eq!(meter.tick(t0 + ENCODE_WINDOW, ms(16)), None);
    }

    #[test]
    fn a_fast_encoder_at_thirty_is_not_the_limit() {
        // The #168 shape: 30 fps cap, a few ms per frame -> the request was the limit.
        let t0 = Instant::now();
        let mut meter = EncodeMeter::new(t0);
        for _ in 0..150 {
            meter.on_frame(ms(6));
        }
        let v = meter.tick(t0 + ENCODE_WINDOW, ms(33)).unwrap();
        assert!(!v.limited && !v.changed);
    }
}
