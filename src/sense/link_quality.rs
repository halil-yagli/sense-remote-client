//! Sense Remote (S10, O13): connection values the session shows next to delay and fps.
//!
//! - **Last frame age** (`last_frame_ms`): how long ago the last video frame was decoded.
//!   Careful: the Host sends no frame while its screen does not change, so a still screen also
//!   ages; the app reads it together with the delay probes ("Kesildi" only when both stop).
//! - **Loss estimate** (`loss_est`, percent): the protocol runs over TCP / KCP, which resend
//!   what is lost, so loss is not measured; it shows up as late probes and stalled video. The
//!   Host sends a delay probe (`TestDelay`) one second after the previous one was answered, so
//!   a probe that is late by more than the last round trip plus a slack means the link stalled
//!   for that long. A falling fps counts only while the delay also rises (a still screen drops
//!   fps without any network trouble). The value is an estimate and is named so in the app.

use std::{
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc,
    },
    time::Instant,
};

/// Host side: a new probe one second after the previous answer (`TEST_DELAY_TIMEOUT`).
const PROBE_INTERVAL_MS: u64 = 1000;
/// Scheduling jitter that is not counted as a stall.
const PROBE_SLACK_MS: u64 = 300;
/// The window the estimate describes: one status tick.
const TICK_MS: u64 = 1000;
/// fps / delay references follow the last few seconds (exponential average).
const REF_WEIGHT: f32 = 0.2;

/// Share (0…1) of the last tick the link stalled, from how late the delay probe is.
pub fn probe_stall(since_probe_ms: u64, last_delay_ms: u64) -> f32 {
    let expected = PROBE_INTERVAL_MS + last_delay_ms + PROBE_SLACK_MS;
    let late = since_probe_ms.saturating_sub(expected);
    late.min(TICK_MS) as f32 / TICK_MS as f32
}

/// Share (0…1) of the frame rate lost, counted only while the delay rises above its usual
/// value (by half, and by at least 50 ms).
pub fn fps_drop(fps: f32, fps_ref: f32, delay_ms: f32, delay_ref: f32) -> f32 {
    let delay_rising = delay_ms > delay_ref * 1.5 && delay_ms - delay_ref >= 50.0;
    if !delay_rising || fps_ref < 1.0 || fps >= fps_ref {
        return 0.0;
    }
    (1.0 - fps.max(0.0) / fps_ref).clamp(0.0, 1.0)
}

/// Loss estimate in percent, one decimal.
pub fn loss_percent(probe_stall: f32, fps_drop: f32) -> f32 {
    (probe_stall.max(fps_drop).clamp(0.0, 1.0) * 1000.0).round() / 10.0
}

/// Per-session state behind the two values.
#[derive(Debug)]
pub struct LinkMeter {
    /// Unix ms of the last decoded frame; 0 = none yet. Shared with the video threads.
    last_frame: Arc<AtomicI64>,
    last_probe: Option<Instant>,
    last_delay_ms: u32,
    fps_ref: Option<f32>,
    delay_ref: Option<f32>,
}

impl Default for LinkMeter {
    fn default() -> Self {
        Self {
            last_frame: Arc::new(AtomicI64::new(0)),
            last_probe: None,
            last_delay_ms: 0,
            fps_ref: None,
            delay_ref: None,
        }
    }
}

/// What one status tick reports.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LinkSample {
    pub last_frame_ms: Option<i64>,
    pub loss_est: Option<f32>,
}

impl LinkMeter {
    /// Handed to a video thread; it stores the time of every decoded frame.
    pub fn frame_clock(&self) -> Arc<AtomicI64> {
        self.last_frame.clone()
    }

    /// Called from a video thread for every decoded frame.
    pub fn mark_frame(clock: &AtomicI64) {
        clock.store(hbb_common::get_time(), Ordering::Relaxed);
    }

    /// A delay probe arrived from the Host (`TestDelay`, `last_delay` in ms).
    pub fn on_probe(&mut self, last_delay_ms: u32) {
        self.last_probe = Some(Instant::now());
        self.last_delay_ms = last_delay_ms;
    }

    /// The values for this tick; `fps` is the sum over every display.
    pub fn tick(&mut self, fps: i32) -> LinkSample {
        let last = self.last_frame.load(Ordering::Relaxed);
        let last_frame_ms = (last > 0).then(|| (hbb_common::get_time() - last).max(0));
        let loss_est = self.last_probe.map(|probe| {
            let since = probe.elapsed().as_millis() as u64;
            self.estimate(since, fps as f32)
        });
        LinkSample {
            last_frame_ms,
            loss_est,
        }
    }

    fn estimate(&mut self, since_probe_ms: u64, fps: f32) -> f32 {
        let delay = self.last_delay_ms as f32;
        let fps_ref = *self.fps_ref.get_or_insert(fps);
        let delay_ref = *self.delay_ref.get_or_insert(delay);
        let stall = probe_stall(since_probe_ms, self.last_delay_ms as u64);
        let fps_loss = fps_drop(fps, fps_ref, delay, delay_ref);
        // References follow only healthy seconds, so a long stall does not become "usual".
        if stall == 0.0 && fps_loss == 0.0 {
            self.fps_ref = Some(fps_ref + (fps - fps_ref) * REF_WEIGHT);
            self.delay_ref = Some(delay_ref + (delay - delay_ref) * REF_WEIGHT);
        }
        loss_percent(stall, fps_loss)
    }
}

// ---------------------------------------------------------------------------------------------
// Sense Remote (#100): decoder start after a reset.
//
// A decoder that was just created or reset (new codec, `SwitchDisplay` after a privacy-mode
// switch, a decode error) can only start from a key frame. Frames and the reset travel on two
// different paths (the frame queue and the media channel), so after a reset the first frames can
// still be the old encoder's delta frames. Fed to a fresh H.264 / H.265 decoder they fail ("PPS
// id out of range"), the stock client takes the failed first frame as a broken decoder, marks the
// codec unsupported and the Host renegotiates: H.265 -> H.264 -> AV1 (software, slow). So until a
// key frame arrives delta frames are skipped, and a key frame is requested from the Host.

/// Skipped delta frames after which a key frame is requested from the Host (a fresh encoder
/// sends one by itself; this only covers the case where none is on its way).
pub const KEY_WAIT_REQUEST_AFTER: u32 = 3;
/// Upper bound on skipped frames: an encoder that never flags key frames falls back to the
/// stock behaviour (decode everything) instead of a black screen.
pub const KEY_WAIT_MAX_FRAMES: u32 = 60;
/// At most one key frame request in this window; each request rebuilds the Host's encoder.
pub const KEY_REQUEST_INTERVAL_MS: u64 = 2_000;

/// What to do with an incoming frame while the decoder may be waiting for a key frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyGate {
    Decode,
    Skip,
    SkipAndRequestKey,
}

/// `skipped`: delta frames already skipped in this wait.
pub fn key_gate(waiting_for_key: bool, is_key: bool, skipped: u32) -> KeyGate {
    if !waiting_for_key || is_key || skipped >= KEY_WAIT_MAX_FRAMES {
        return KeyGate::Decode;
    }
    if skipped + 1 == KEY_WAIT_REQUEST_AFTER {
        KeyGate::SkipAndRequestKey
    } else {
        KeyGate::Skip
    }
}

/// Whether a key frame request may go out now (`since_last_ms`: time since the previous one).
pub fn key_request_due(since_last_ms: Option<u64>) -> bool {
    since_last_ms.map_or(true, |ms| ms >= KEY_REQUEST_INTERVAL_MS)
}

// ---------------------------------------------------------------------------------------------
// Sense Remote (#100): why a connection went through the relay.
//
// Our ID server is the open-source hbbs (1.1.16). It forwards only the TCP punch: it does not
// answer the UDP NAT test and drops `udp_port`, `socket_addr_v6`, `force_relay` and the WebRTC
// offer, so UDP / IPv6 / WebRTC punching cannot work with it (the client already turns them off
// for a non-public server). What is left is the TCP punch, and the controlled side relays at once
// when either side's NAT is symmetric (the controller sends SYMMETRIC also when it is forced to
// relay). These names go to the log so a measurement says which of them it was.

/// The controlled side's reason for answering a punch request with a relay; `None` = it punches.
pub fn relay_reason(
    peer_nat_symmetric: bool,
    my_nat_symmetric: bool,
    local_proxy: bool,
    force_relay: bool,
    tcp_listen_off_without_udp: bool,
) -> Option<&'static str> {
    if local_proxy {
        Some("own proxy or websocket")
    } else if force_relay {
        Some("controller forced relay")
    } else if peer_nat_symmetric && my_nat_symmetric {
        Some("both NATs symmetric")
    } else if peer_nat_symmetric {
        Some("controller NAT symmetric (or controller forced relay)")
    } else if my_nat_symmetric {
        Some("own NAT symmetric")
    } else if tcp_listen_off_without_udp {
        Some("TCP listen off and no UDP punch")
    } else {
        None
    }
}

/// Sense Remote (A, #100): relay fallback delay set by the panel (`Config`, seconds), in ms.
/// `None` when unset or not a number; otherwise clamped to 1–30 s.
pub fn panel_relay_fallback_delay_ms(value: &str) -> Option<u64> {
    match value.trim().parse::<f64>() {
        Ok(secs) if secs.is_finite() && secs > 0.0 => {
            Some((secs.clamp(1.0, 30.0) * 1000.0).round() as u64)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_relay_fallback_delay_is_bounded() {
        assert_eq!(panel_relay_fallback_delay_ms(""), None);
        assert_eq!(panel_relay_fallback_delay_ms("abc"), None);
        assert_eq!(panel_relay_fallback_delay_ms("0"), None);
        assert_eq!(panel_relay_fallback_delay_ms("-3"), None);
        assert_eq!(panel_relay_fallback_delay_ms("NaN"), None);
        assert_eq!(panel_relay_fallback_delay_ms(" 2.5 "), Some(2_500));
        assert_eq!(panel_relay_fallback_delay_ms("0.2"), Some(1_000));
        assert_eq!(panel_relay_fallback_delay_ms("90"), Some(30_000));
    }

    #[test]
    fn key_gate_skips_delta_frames_until_a_key_frame() {
        // Not waiting: everything is decoded.
        assert_eq!(key_gate(false, false, 0), KeyGate::Decode);
        // Waiting: a key frame ends the wait at once.
        assert_eq!(key_gate(true, true, 0), KeyGate::Decode);
        assert_eq!(key_gate(true, true, 10), KeyGate::Decode);
        // Delta frames are skipped; one of them asks for a key frame.
        assert_eq!(key_gate(true, false, 0), KeyGate::Skip);
        assert_eq!(key_gate(true, false, KEY_WAIT_REQUEST_AFTER - 1), KeyGate::SkipAndRequestKey);
        assert_eq!(key_gate(true, false, KEY_WAIT_REQUEST_AFTER), KeyGate::Skip);
    }

    #[test]
    fn key_gate_gives_up_after_the_bound() {
        // Exactly one request per wait.
        let requests = (0..KEY_WAIT_MAX_FRAMES)
            .filter(|s| key_gate(true, false, *s) == KeyGate::SkipAndRequestKey)
            .count();
        assert_eq!(requests, 1);
        // An encoder that never flags key frames still gets decoded (stock behaviour).
        assert_eq!(key_gate(true, false, KEY_WAIT_MAX_FRAMES), KeyGate::Decode);
    }

    #[test]
    fn key_requests_are_throttled() {
        assert!(key_request_due(None));
        assert!(!key_request_due(Some(0)));
        assert!(!key_request_due(Some(KEY_REQUEST_INTERVAL_MS - 1)));
        assert!(key_request_due(Some(KEY_REQUEST_INTERVAL_MS)));
    }

    #[test]
    fn relay_reason_names_the_cause() {
        assert_eq!(relay_reason(false, false, false, false, false), None);
        assert_eq!(
            relay_reason(true, false, false, false, false),
            Some("controller NAT symmetric (or controller forced relay)")
        );
        assert_eq!(relay_reason(false, true, false, false, false), Some("own NAT symmetric"));
        assert_eq!(relay_reason(true, true, false, false, false), Some("both NATs symmetric"));
        // Configuration wins over NAT: it relays whatever the NAT.
        assert_eq!(relay_reason(true, true, true, false, false), Some("own proxy or websocket"));
        assert_eq!(relay_reason(false, false, false, true, false), Some("controller forced relay"));
        assert_eq!(
            relay_reason(false, false, false, false, true),
            Some("TCP listen off and no UDP punch")
        );
    }

    #[test]
    fn on_time_probes_mean_no_loss() {
        assert_eq!(probe_stall(0, 40), 0.0);
        assert_eq!(probe_stall(1000, 40), 0.0);
        // Within round trip + slack.
        assert_eq!(probe_stall(1340, 40), 0.0);
    }

    #[test]
    fn a_late_probe_counts_its_lateness() {
        // 1000 + 40 + 300 = 1340 expected; 1840 is half a second late.
        assert_eq!(probe_stall(1840, 40), 0.5);
        // Never more than the whole tick.
        assert_eq!(probe_stall(10_000, 40), 1.0);
        // A slow but steady link is not lossy: the expected gap grows with the delay.
        assert_eq!(probe_stall(1800, 500), 0.0);
    }

    #[test]
    fn a_still_screen_is_not_loss() {
        // fps fell to 0 but the delay did not rise.
        assert_eq!(fps_drop(0.0, 30.0, 40.0, 40.0), 0.0);
        assert_eq!(fps_drop(5.0, 30.0, 45.0, 40.0), 0.0);
    }

    #[test]
    fn falling_fps_with_rising_delay_is_loss() {
        assert_eq!(fps_drop(15.0, 30.0, 200.0, 40.0), 0.5);
        assert_eq!(fps_drop(0.0, 30.0, 200.0, 40.0), 1.0);
        // Rising fps or no reference: nothing.
        assert_eq!(fps_drop(40.0, 30.0, 200.0, 40.0), 0.0);
        assert_eq!(fps_drop(0.0, 0.0, 200.0, 40.0), 0.0);
        // A small delay rise (under 50 ms) is ordinary jitter.
        assert_eq!(fps_drop(10.0, 30.0, 70.0, 30.0), 0.0);
    }

    #[test]
    fn loss_percent_is_the_worse_signal() {
        assert_eq!(loss_percent(0.0, 0.0), 0.0);
        assert_eq!(loss_percent(0.25, 0.1), 25.0);
        assert_eq!(loss_percent(0.0, 0.333), 33.3);
        assert_eq!(loss_percent(2.0, 0.0), 100.0);
    }

    #[test]
    fn meter_reports_nothing_before_data() {
        let mut m = LinkMeter::default();
        assert_eq!(
            m.tick(30),
            LinkSample {
                last_frame_ms: None,
                loss_est: None
            }
        );
    }

    #[test]
    fn meter_reports_frame_age_and_loss() {
        let mut m = LinkMeter::default();
        LinkMeter::mark_frame(&m.frame_clock());
        m.on_probe(40);
        let s = m.tick(30);
        assert!(s.last_frame_ms.unwrap() < 1000);
        assert_eq!(s.loss_est, Some(0.0));
        // An old frame.
        m.frame_clock()
            .store(hbb_common::get_time() - 5_000, Ordering::Relaxed);
        assert!(m.tick(30).last_frame_ms.unwrap() >= 5_000);
    }

    #[test]
    fn references_follow_only_healthy_seconds() {
        let mut m = LinkMeter::default();
        m.last_delay_ms = 40;
        assert_eq!(m.estimate(500, 30.0), 0.0);
        // A stalled, slow second: loss, and the references stay where they were.
        m.last_delay_ms = 400;
        assert_eq!(m.estimate(500, 10.0), loss_percent(0.0, fps_drop(10.0, 30.0, 400.0, 40.0)));
        assert_eq!(m.fps_ref, Some(30.0));
        assert_eq!(m.delay_ref, Some(40.0));
        // Healthy again: they move towards the new values.
        m.last_delay_ms = 40;
        assert_eq!(m.estimate(500, 20.0), 0.0);
        assert_eq!(m.fps_ref, Some(28.0));
    }
}
