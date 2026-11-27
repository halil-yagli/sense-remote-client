//! Camera profiles and the rule that moves between them (fizibilite 2026-11-27 §2.1, §3.2).
//!
//! | Profile | Size · fps | Target bitrate | When |
//! |---|---|---|---|
//! | P1 | 640×360 · 15 | 450 kbit/s | direct connection, link good |
//! | P2 | 320×180 · 10 | 150 kbit/s | relay, or link wavy |
//! | P3 | stopped (Sense logo) | 0 | link bad, or (Host sender) screen fps below half its target |
//!
//! Going down is immediate; going up waits until the better condition has held for 10 s.
//! The latency thresholds that grade the link are a pending user decision (#135); the caller
//! (E1b) grades the link and passes the grade here, nothing here knows milliseconds.

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Profile {
    P1,
    P2,
    P3,
}

impl Profile {
    /// Frame size, `None` when the camera stream is paused (P3).
    pub fn size(self) -> Option<(u32, u32)> {
        match self {
            Profile::P1 => Some((640, 360)),
            Profile::P2 => Some((320, 180)),
            Profile::P3 => None,
        }
    }

    pub fn fps(self) -> u32 {
        match self {
            Profile::P1 => 15,
            Profile::P2 => 10,
            Profile::P3 => 0,
        }
    }

    pub fn bitrate_kbps(self) -> u32 {
        match self {
            Profile::P1 => 450,
            Profile::P2 => 150,
            Profile::P3 => 0,
        }
    }

    /// Higher is better.
    fn rank(self) -> u8 {
        match self {
            Profile::P1 => 2,
            Profile::P2 => 1,
            Profile::P3 => 0,
        }
    }

    pub(crate) fn to_u8(self) -> u8 {
        self.rank()
    }

    pub(crate) fn from_u8(v: u8) -> Profile {
        match v {
            2 => Profile::P1,
            1 => Profile::P2,
            _ => Profile::P3,
        }
    }
}

/// How the link is doing, as the caller grades it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinkGrade {
    Good,
    Wavy,
    Bad,
}

/// How long a better condition must hold before the profile goes up.
pub const RAISE_AFTER: Duration = Duration::from_secs(10);
/// Below this share of its target fps, the Host's screen gets the whole link (P3).
pub const SCREEN_FPS_RATIO_MIN: f32 = 0.5;

/// The profile the conditions ask for right now. `screen_fps_ratio` is passed only by the Host
/// sender (its camera shares the link with the screen); the Controller passes `None`.
pub fn target(link: LinkGrade, relay: bool, screen_fps_ratio: Option<f32>) -> Profile {
    if link == LinkGrade::Bad {
        return Profile::P3;
    }
    if let Some(r) = screen_fps_ratio {
        if r.is_finite() && r < SCREEN_FPS_RATIO_MIN {
            return Profile::P3;
        }
    }
    if relay || link == LinkGrade::Wavy {
        return Profile::P2;
    }
    Profile::P1
}

/// One step of the rule: `now` is the current profile, `better_for` how long the conditions
/// have continuously asked for a better profile than `now` (zero when they do not).
pub fn profile(
    link: LinkGrade,
    relay: bool,
    screen_fps_ratio: Option<f32>,
    now: Profile,
    better_for: Duration,
) -> Profile {
    let want = target(link, relay, screen_fps_ratio);
    if want.rank() < now.rank() {
        want
    } else if want.rank() > now.rank() && better_for >= RAISE_AFTER {
        want
    } else {
        now
    }
}

/// Keeps the clock `profile` needs: call `update` with every new grade (once a second is
/// enough).
#[derive(Debug, Clone)]
pub struct Pacer {
    now: Profile,
    better_since: Option<Instant>,
}

impl Pacer {
    pub fn new(start: Profile) -> Self {
        Pacer {
            now: start,
            better_since: None,
        }
    }

    pub fn current(&self) -> Profile {
        self.now
    }

    pub fn update(
        &mut self,
        link: LinkGrade,
        relay: bool,
        screen_fps_ratio: Option<f32>,
        at: Instant,
    ) -> Profile {
        let want = target(link, relay, screen_fps_ratio);
        let better_for = if want.rank() > self.now.rank() {
            let since = *self.better_since.get_or_insert(at);
            at.saturating_duration_since(since)
        } else {
            self.better_since = None;
            Duration::ZERO
        };
        let next = profile(link, relay, screen_fps_ratio, self.now, better_for);
        if next != self.now {
            self.now = next;
            self.better_since = None;
        }
        self.now
    }
}
