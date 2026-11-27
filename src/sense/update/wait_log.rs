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

/// Sense Remote (#134): the fields of `update/fail` when this step made a new error after a
/// failed attempt, `None` otherwise. `deneme` = attempts in this period, `sonraki_s` = seconds to
/// the automatic retry (`-1` = none: the attempts are used up, or nothing was counted).
pub fn fail_fields(before_error: Option<super::UpdateError>, s: &State, now_s: i64) -> Option<(String, u8, i64)> {
    let error = s.error?;
    let failed_attempt = matches!(s.phase, UpdateState::Available | UpdateState::Failed) && s.attempts > 0;
    if before_error == Some(error) || !failed_attempt {
        return None;
    }
    let next = match (s.phase, s.not_before_s) {
        (UpdateState::Available, Some(t)) => (t - now_s).max(0),
        _ => -1,
    };
    Some((error.as_str().to_owned(), s.attempts, next))
}

/// After one engine step: a failed attempt goes to the log and the event record with its
/// number and the next try (the SYSTEM / root log the panel's diagnostics read).
pub fn observe_fail(before_error: Option<super::UpdateError>, s: &State, now_s: i64) {
    let Some((hata, deneme, sonraki_s)) = fail_fields(before_error, s, now_s) else {
        return;
    };
    log::warn!(
        "[sense-update] fail hata={hata} deneme={deneme}/{} sonraki_s={sonraki_s}",
        super::engine::MAX_ATTEMPTS
    );
    super::super::diag::event(
        "update",
        "fail",
        serde_json::json!({ "hata": hata, "deneme": deneme, "sonraki_s": sonraki_s }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_attempt_is_logged_once_with_its_retry() {
        let failed = State {
            phase: UpdateState::Available,
            error: Some(super::super::UpdateError::DownloadFailed),
            attempts: 1,
            not_before_s: Some(100 + 1800),
            source: Some(super::super::UpdateSource::Local),
            ..State::default()
        };
        assert_eq!(
            fail_fields(None, &failed, 100),
            Some(("download_failed".to_owned(), 1, 1800))
        );
        // The same error on the next step (a tick) is not a new failure.
        assert_eq!(fail_fields(failed.error, &failed, 105), None);
        let last = State { phase: UpdateState::Failed, attempts: 3, not_before_s: None, ..failed.clone() };
        assert_eq!(fail_fields(None, &last, 100), Some(("download_failed".to_owned(), 3, -1)));
        // A refused notice is an error without an attempt: not a failed attempt.
        let refused = State { attempts: 0, ..failed };
        assert_eq!(fail_fields(None, &refused, 100), None);
        crate::sense::diag::sink::take();
        observe_fail(None, &last, 100);
        let got = crate::sense::diag::sink::take();
        assert!(got.contains(&("update".to_owned(), "fail".to_owned())), "{got:?}");
    }

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
