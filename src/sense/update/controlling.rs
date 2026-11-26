//! Sense Remote (S9 P5, #96): is this computer's own Controller side in a session?
//!
//! The privileged updater process (Windows `--server`) learns it from the UI process, which
//! sends the number of its sessions over IPC (`Data::ControllingSessionCount`). Upstream keeps
//! that as a bare counter: when the UI process dies without sending `0` (crash, killed, the
//! window closed by the system), the counter stays above zero for ever and an update ordered
//! for "no connection" waits for ever, with no connection open.
//!
//! Fix: a report is only trusted while it is fresh. The UI process repeats its count every
//! `REFRESH_S` while a session is open (`keep_fresh`); the receiver counts the report as an
//! open session only for `TTL_S` after it arrived. A healthy session refreshes several times
//! inside the TTL; a dead one expires by itself. A stale value can only delay an update for at
//! most `TTL_S`, never cause one while a session is alive (the refresh keeps it fresh).

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use std::time::Duration;

/// A report older than this no longer counts. Three missed refreshes.
pub const TTL_S: i64 = 90;
/// The UI process repeats a non-zero count this often.
pub const REFRESH_S: u64 = 20;

/// The last count the UI process sent and when it arrived (Unix seconds).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    pub count: usize,
    pub at_s: i64,
}

/// Pure: does this report mean an open Controller session at `now_s`? A clock that jumped by
/// more than the TTL (either way) makes the report stale rather than fresh for ever.
pub fn is_active(report: Option<Report>, now_s: i64) -> bool {
    report.is_some_and(|r| r.count > 0 && (now_s - r.at_s).abs() < TTL_S)
}

/// Pure: age of the report in seconds, `None` without one.
pub fn age_s(report: Option<Report>, now_s: i64) -> Option<i64> {
    report.map(|r| (now_s - r.at_s).max(0))
}

static LAST: Mutex<Option<Report>> = Mutex::new(None);

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}

fn last() -> Option<Report> {
    *LAST.lock().unwrap_or_else(|e| e.into_inner())
}

/// The receiving side: the UI process reported `count` sessions.
pub fn report(count: usize) {
    *LAST.lock().unwrap_or_else(|e| e.into_inner()) = Some(Report {
        count,
        at_s: now_s(),
    });
}

/// The receiving side: is a Controller session open (and its report fresh)?
pub fn active() -> bool {
    is_active(last(), now_s())
}

/// For the log: `(count, age in seconds)` of the last report.
pub fn snapshot() -> Option<(usize, i64)> {
    let now = now_s();
    last().map(|r| (r.count, age_s(Some(r), now).unwrap_or(0)))
}

static REFRESHING: AtomicBool = AtomicBool::new(false);

/// The UI process: while `push` (which sends the current count and returns it) says a session
/// is open, repeat it every `REFRESH_S` so the receiver keeps it fresh. One thread at most; it
/// ends when the count is `0`.
pub fn keep_fresh(push: fn() -> usize) {
    if REFRESHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("sense-controlling-refresh".to_owned())
        .spawn(move || loop {
            std::thread::sleep(Duration::from_secs(REFRESH_S));
            if push() > 0 {
                continue;
            }
            REFRESHING.store(false, Ordering::SeqCst);
            // A session opened between the last push and the flag: take the job again.
            if push() > 0 && !REFRESHING.swap(true, Ordering::SeqCst) {
                continue;
            }
            return;
        });
    if spawned.is_err() {
        REFRESHING.store(false, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(count: usize, at_s: i64) -> Option<Report> {
        Some(Report { count, at_s })
    }

    #[test]
    fn fresh_nonzero_report_is_active() {
        assert!(is_active(at(1, 1000), 1000));
        assert!(is_active(at(2, 1000), 1000 + TTL_S - 1));
    }

    #[test]
    fn stale_report_is_ignored() {
        assert!(!is_active(at(1, 1000), 1000 + TTL_S));
        assert!(!is_active(at(3, 1000), 1000 + 3600));
    }

    #[test]
    fn zero_or_missing_report_is_not_active() {
        assert!(!is_active(at(0, 1000), 1000));
        assert!(!is_active(None, 1000));
    }

    #[test]
    fn clock_jump_back_does_not_keep_a_report_for_ever() {
        assert!(is_active(at(1, 1000), 1000 - 5));
        assert!(!is_active(at(1, 1000), 1000 - 3600));
    }

    #[test]
    fn refresh_keeps_a_live_session_active() {
        // Refreshes every REFRESH_S: at any moment the newest report is younger than the TTL.
        for t in (0..600).step_by(7) {
            let newest = (t / REFRESH_S as i64) * REFRESH_S as i64;
            assert!(is_active(at(1, newest), t), "t={t}");
        }
        assert!(REFRESH_S as i64 * 3 <= TTL_S);
    }

    #[test]
    fn age_is_never_negative() {
        assert_eq!(age_s(at(1, 1000), 1030), Some(30));
        assert_eq!(age_s(at(1, 1000), 990), Some(0));
        assert_eq!(age_s(None, 5), None);
    }

    #[test]
    fn report_then_active_then_zero() {
        report(2);
        assert!(active());
        assert_eq!(snapshot().map(|s| s.0), Some(2));
        report(0);
        assert!(!active());
    }
}
