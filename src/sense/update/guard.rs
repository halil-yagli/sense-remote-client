//! Sense Remote (update plan 2026-11-21, §5.2): the guard. Package U2 (decision) with U3 / U4
//! (the actions, `super::apply`).
//!
//! Before an installation the old program is copied aside and a guard is registered that runs
//! from that copy (`--sense-update-guard`; Windows: scheduled task as SYSTEM at start-up and
//! every minute; macOS: launchd job as root, `RunAtLoad` + every 60 s). An installation only
//! becomes permanent once the new version declared itself healthy (§5.3); a new version that
//! is broken can therefore not prevent the rollback, and a power cut continues at boot.
//!
//! `decide`:
//! - `installing`, no `healthy_at`, `now - started_at > HEALTH_TIMEOUT_S` → roll back
//! - `unhealthy` → roll back at once
//! - `installed` (healthy), `rolled_back`, `failed` → remove the guard (the copy of the old
//!   version stays until the next update)
//! - store unreadable or breaking its rules → do nothing and log (safe side)
//! - anything else → nothing

use super::store::{Persisted, StoredState};
use hbb_common::log;

/// How long a new version has to declare itself healthy.
pub const HEALTH_TIMEOUT_S: i64 = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardAction {
    /// `super::apply::roll_back`.
    RollBack,
    /// `super::apply::remove_guard`.
    RemoveGuard,
    Nothing,
}

/// Pure. `state` is `store::read()` as it came.
pub fn decide(state: &Result<Option<Persisted>, String>, now_s: i64) -> GuardAction {
    let Ok(Some(state)) = state else {
        return GuardAction::Nothing; // unreadable or broken: the safe side
    };
    match state.state {
        StoredState::Unhealthy => GuardAction::RollBack,
        StoredState::Installing => match (state.healthy_at, state.started_at) {
            // A start time in the future (clock moved back) waits rather than rolls back.
            (None, Some(started)) if now_s - started > HEALTH_TIMEOUT_S => GuardAction::RollBack,
            _ => GuardAction::Nothing,
        },
        StoredState::Installed => {
            if state.healthy_at.is_some() {
                GuardAction::RemoveGuard
            } else {
                GuardAction::Nothing // breaks the rule: healthy without a time
            }
        }
        StoredState::RolledBack | StoredState::Failed => GuardAction::RemoveGuard,
        _ => GuardAction::Nothing,
    }
}

/// `--sense-update-guard`: reads the store, decides, acts. Returns the exit code (0 = nothing
/// to do or done, 1 = the action failed; the guard runs again a minute later).
pub fn run() -> i32 {
    let stored = super::store::read();
    if let Err(err) = &stored {
        log::warn!("Sense Remote: update guard: store not usable: {err}");
    }
    let now_s = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let action = decide(&stored, now_s);
    let result = match action {
        GuardAction::Nothing => return 0,
        GuardAction::RollBack => super::apply::roll_back(),
        GuardAction::RemoveGuard => super::apply::remove_guard(),
    };
    match result {
        Ok(()) => {
            log::info!("Sense Remote: update guard: {action:?} done");
            0
        }
        Err(err) => {
            log::error!("Sense Remote: update guard: {action:?} failed: {}", err.as_str());
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_795_000_000;

    fn stored(state: StoredState, started_at: Option<i64>, healthy_at: Option<i64>) -> Persisted {
        Persisted {
            state,
            target: Some(4),
            from: Some(3),
            from_id: None,
            from_key_hash: None,
            oid: None,
            source: None,
            attempts: 1,
            last_error: None,
            started_at,
            healthy_at,
        }
    }

    fn decide_on(state: StoredState, started_at: Option<i64>, healthy_at: Option<i64>) -> GuardAction {
        decide(&Ok(Some(stored(state, started_at, healthy_at))), NOW)
    }

    // The table of plan §5.2.
    #[test]
    fn decision_table() {
        use GuardAction::*;
        use StoredState as S;
        // installing, not healthy, more than 300 s: roll back.
        assert_eq!(decide_on(S::Installing, Some(NOW - 301), None), RollBack);
        assert_eq!(decide_on(S::Installing, Some(NOW - 300), None), Nothing);
        assert_eq!(decide_on(S::Installing, Some(NOW + 600), None), Nothing);
        assert_eq!(decide_on(S::Installing, Some(NOW - 3600), Some(NOW - 3500)), Nothing);
        // installing without a start time breaks the rules: nothing.
        assert_eq!(decide_on(S::Installing, None, None), Nothing);
        // unhealthy: at once.
        assert_eq!(decide_on(S::Unhealthy, Some(NOW), None), RollBack);
        assert_eq!(decide_on(S::Unhealthy, None, None), RollBack);
        // installed (healthy), rolled back, failed: the guard goes.
        assert_eq!(decide_on(S::Installed, Some(NOW - 100), Some(NOW - 50)), RemoveGuard);
        assert_eq!(decide_on(S::Installed, Some(NOW - 100), None), Nothing);
        assert_eq!(decide_on(S::RolledBack, None, None), RemoveGuard);
        assert_eq!(decide_on(S::Failed, None, None), RemoveGuard);
        // everything before an installation: nothing.
        for state in [
            S::Idle,
            S::Available,
            S::Scheduled,
            S::WaitingIdle,
            S::Downloading,
            S::Verifying,
        ] {
            assert_eq!(decide_on(state, Some(NOW - 9999), None), Nothing, "{state:?}");
        }
        // unreadable or missing store: nothing.
        assert_eq!(decide(&Err("owner".to_owned()), NOW), Nothing);
        assert_eq!(decide(&Ok(None), NOW), Nothing);
    }
}
