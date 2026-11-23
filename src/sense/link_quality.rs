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

#[cfg(test)]
mod tests {
    use super::*;

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
