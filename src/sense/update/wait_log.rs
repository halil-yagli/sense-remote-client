//! Sense Remote (S9 P5, #96): say in the log why an accepted update has not started.
//!
//! "Bağlantı yokken" orders sat in `scheduled` with no word of why. Every engine step now goes
//! through `observe`, which writes
//!   `[sense-update] state eski=<a> yeni=<b>`          when the phase changes,
//!   `[sense-update] wait neden=<n> ...`                while the update waits, when the reason
//!                                                      changes and then every `REPEAT_S`.
//! The names are the contract's `update/state` and `update/wait` (kayit-sozlesmesi §1); when the
//! event module (P1) is merged the two `log::info!` calls become `diag::event`.
//!
//! Reasons (`neden`): `incoming_connection`, `outgoing_session` (Windows UI count),
//! `outgoing_session_marker` (macOS marker file), `idle_window` (no session, but idle for less
//! than `IDLE_S`), `night_window`, `not_before` (a panel order's random start delay, `bekleme_s`
//! left), `retry_wait` (wait after a failed attempt).

use super::{engine::State, Blocked, UpdateState};
use hbb_common::log;
use std::sync::Mutex;

/// While one reason lasts it is repeated this often (a tick is 5 s; one line a minute).
pub const REPEAT_S: i64 = 60;

/// What keeps a session open, as far as the process can see.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sessions {
    Incoming,
    Outgoing,
    OutgoingMarker,
    None,
}

/// Pure: the reason an update waits, `None` when it is not waiting.
pub fn reason(
    phase: UpdateState,
    blocked: Option<Blocked>,
    has_source: bool,
    not_before_s: Option<i64>,
    now_s: i64,
    sessions: Sessions,
) -> Option<&'static str> {
    let delayed = not_before_s.is_some_and(|t| t > now_s);
    match phase {
        UpdateState::Scheduled if delayed => Some("not_before"),
        UpdateState::Available if has_source && delayed => Some("retry_wait"),
        UpdateState::WaitingIdle => Some(match blocked {
            Some(Blocked::NightWindow) => "night_window",
            _ => match sessions {
                Sessions::Incoming => "incoming_connection",
                Sessions::Outgoing => "outgoing_session",
                Sessions::OutgoingMarker => "outgoing_session_marker",
                Sessions::None => "idle_window",
            },
        }),
        _ => None,
    }
}

/// Pure: write the line? When the reason is new, or `REPEAT_S` after the last line.
pub fn due(last: Option<(&str, i64)>, neden: &str, now_s: i64) -> bool {
    match last {
        Some((old, at)) => old != neden || now_s - at >= REPEAT_S || now_s < at,
        None => true,
    }
}

struct Seen {
    wait: Option<(&'static str, i64)>,
}

static SEEN: Mutex<Seen> = Mutex::new(Seen { wait: None });

#[cfg(target_os = "macos")]
fn sessions() -> Sessions {
    if crate::platform::macos::get_logged_in_uids()
        .into_iter()
        .any(super::outgoing::uid_has_outgoing)
    {
        Sessions::OutgoingMarker
    } else {
        Sessions::Incoming
    }
}

#[cfg(not(any(target_os = "macos", target_os = "android", target_os = "ios")))]
fn sessions() -> Sessions {
    if !crate::Connection::alive_conns().is_empty() {
        Sessions::Incoming
    } else if super::controlling::active() {
        Sessions::Outgoing
    } else {
        Sessions::None
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn sessions() -> Sessions {
    Sessions::None
}

/// After one engine step: `before` is the phase before it, `s` the state after it.
pub fn observe(before: UpdateState, s: &State, now_s: i64, idle_s: u64) {
    let mut seen = SEEN.lock().unwrap_or_else(|e| e.into_inner());
    if before != s.phase {
        log::info!(
            "[sense-update] state eski={} yeni={}",
            before.as_str(),
            s.phase.as_str()
        );
        super::super::diag::kinds::update_state(before.as_str(), s.phase.as_str()); // Sense Remote (#103)
    }
    // The session lookup is only made while waiting for idle.
    let kind = if s.phase == UpdateState::WaitingIdle {
        sessions()
    } else {
        Sessions::None
    };
    let Some(neden) = reason(s.phase, s.blocked, s.source.is_some(), s.not_before_s, now_s, kind)
    else {
        seen.wait = None;
        return;
    };
    if !due(seen.wait, neden, now_s) {
        return;
    }
    seen.wait = Some((neden, now_s));
    let bekleme_s = s.not_before_s.map_or(0, |t| (t - now_s).max(0));
    let controlling = super::controlling::snapshot();
    log::info!(
        "[sense-update] wait neden={neden} idle_s={idle_s} bekleme_s={bekleme_s} ui_sayi={} ui_yas_s={}",
        controlling.map_or(0, |c| c.0),
        controlling.map_or(-1, |c| c.1),
    );
    super::super::diag::kinds::update_wait(neden); // Sense Remote (#103)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waiting(blocked: Option<Blocked>, sessions: Sessions) -> Option<&'static str> {
        reason(UpdateState::WaitingIdle, blocked, true, None, 100, sessions)
    }

    #[test]
    fn waiting_idle_names_what_blocks() {
        let b = Some(Blocked::SessionActive);
        assert_eq!(waiting(b, Sessions::Incoming), Some("incoming_connection"));
        assert_eq!(waiting(b, Sessions::Outgoing), Some("outgoing_session"));
        assert_eq!(waiting(b, Sessions::OutgoingMarker), Some("outgoing_session_marker"));
        assert_eq!(waiting(b, Sessions::None), Some("idle_window"));
        assert_eq!(waiting(Some(Blocked::NightWindow), Sessions::Incoming), Some("night_window"));
    }

    #[test]
    fn scheduled_waits_only_until_not_before() {
        let r = |nb| reason(UpdateState::Scheduled, None, true, nb, 100, Sessions::None);
        assert_eq!(r(Some(160)), Some("not_before"));
        assert_eq!(r(Some(100)), None);
        assert_eq!(r(None), None);
    }

    #[test]
    fn failed_attempt_wait_is_a_retry_wait() {
        let r = |src| reason(UpdateState::Available, None, src, Some(500), 100, Sessions::None);
        assert_eq!(r(true), Some("retry_wait"));
        assert_eq!(r(false), None);
    }

    #[test]
    fn other_phases_do_not_wait() {
        for phase in [UpdateState::Idle, UpdateState::Downloading, UpdateState::Installing] {
            assert_eq!(reason(phase, None, true, Some(900), 100, Sessions::Incoming), None, "{phase:?}");
        }
    }

    #[test]
    fn line_is_written_on_change_then_once_a_minute() {
        assert!(due(None, "incoming_connection", 100));
        assert!(!due(Some(("incoming_connection", 100)), "incoming_connection", 105));
        assert!(!due(Some(("incoming_connection", 100)), "incoming_connection", 159));
        assert!(due(Some(("incoming_connection", 100)), "incoming_connection", 160));
        assert!(due(Some(("incoming_connection", 100)), "outgoing_session", 105));
        // Clock set back: write again rather than stay silent.
        assert!(due(Some(("incoming_connection", 100)), "incoming_connection", 50));
    }

    #[test]
    fn observe_writes_state_and_wait_events() {
        crate::sense::diag::sink::take();
        let s = State {
            phase: UpdateState::WaitingIdle,
            ..State::default()
        };
        observe(UpdateState::Available, &s, 100, 0);
        let got = crate::sense::diag::sink::take();
        assert!(got.contains(&("update".to_owned(), "state".to_owned())), "{got:?}");
        assert!(got.contains(&("update".to_owned(), "wait".to_owned())), "{got:?}");
    }
}
