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

use super::store::Persisted;

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

/// Pure. `state` is `store::read()` as it came. U0: never acts.
pub fn decide(state: &Result<Option<Persisted>, String>, now_s: i64) -> GuardAction {
    let _ = (state, now_s);
    GuardAction::Nothing
}

/// `--sense-update-guard`: reads the store, decides, acts. Returns the exit code.
/// U0: does nothing, 0.
pub fn run() -> i32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    // U0: the guard never touches an installation.
    #[test]
    fn skeleton_never_acts() {
        assert_eq!(decide(&Ok(None), 1_795_000_000), GuardAction::Nothing);
        assert_eq!(decide(&Err("unreadable".to_owned()), 0), GuardAction::Nothing);
    }
}
