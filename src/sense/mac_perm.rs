//! Sense Remote (Mac M0 + M4, plan §3.2 / §3.4): state of the three macOS privacy permissions
//! (Screen Recording, Accessibility, Input Monitoring) for the heartbeat extension
//! `mac_permissions` (M4, `report::heartbeat_base`) and, as JSON, for the user interface.
//!
//! Read with RustDesk's existing checks and never with a prompt (`prompt = false`), so asking
//! every heartbeat shows nothing on the computer. macOS answers for the calling process: the
//! heartbeat is sent by the `--server` agent, the process that captures the screen and injects
//! input, so the panel sees the permissions that matter for a connection.
//!
//! Known macOS behaviour (to be checked on a device, plan §8): the Screen Recording answer of a
//! running process can stay at its old value until the process restarts; that is why the wizard
//! restarts the agent after the permission is given (`install_sense_restart_agent`).
//!
//! Sürüm 11 (tarama-mac M4): the setup wizard asks in its own (UI) process, which started before
//! the permission was given, so its answer stayed "no" and the row "Bekleniyor". Outside the
//! `--server`, a "no" is now checked again in a fresh process (`service --sense-screen-capture`,
//! [`fresh_screen_recording`]) that reads the permission as it is now; the answer comes from the
//! last finished check, so the caller never waits for a process (the wizard asks every second).
//! The `--server` keeps its own answer: it is the one that captures, and its "no" is real until
//! the wizard restarts it.

/// Sense Remote: the panel contract's `SenseHeartbeatExt.mac_permissions`; it lives in
/// `report.rs` because that file is compiled (and its contract tests run) on every platform.
pub use super::report::MacPermissions;
use std::time::{Duration, Instant};

/// `service --sense-screen-capture`: prints `1` or `0` (Screen Recording of a fresh process)
/// and exits; never prompts.
pub const SERVICE_ARG_SCREEN_CAPTURE: &str = "--sense-screen-capture";
/// How often a fresh check may run while the answer stays "no".
pub const FRESH_EVERY: Duration = Duration::from_millis(1500);
/// A fresh check that does not finish in this time counts as "no".
pub const FRESH_TIMEOUT: Duration = Duration::from_secs(3);

/// Pure: the fresh process's answer on stdout. `None` for anything else.
pub fn parse_fresh_answer(stdout: &str) -> Option<bool> {
    match stdout.trim() {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// What the fresh checks know: the last finished answer and whether one is running.
#[derive(Debug, Default, Clone, Copy)]
pub struct FreshState {
    pub last: Option<(bool, Instant)>,
    pub running: bool,
}

/// Pure: the answer to give now and whether to start a fresh check. `own` = this process's
/// answer. A "yes" of this process is final; otherwise the last fresh answer is given (no answer
/// yet = "no") and a new check starts when none runs and the last one is older than
/// [`FRESH_EVERY`].
pub fn fresh_decide(own: bool, state: &FreshState, now: Instant) -> (bool, bool) {
    if own {
        return (true, false);
    }
    let answer = state.last.map(|(granted, _)| granted).unwrap_or(false);
    let due = match state.last {
        None => true,
        Some((_, at)) => now.saturating_duration_since(at) >= FRESH_EVERY,
    };
    (answer, !state.running && due)
}

/// Permissions of the calling process, read without showing a system prompt.
#[cfg(target_os = "macos")]
pub fn current() -> MacPermissions {
    use crate::platform::macos;
    MacPermissions {
        screen_recording: macos::is_can_screen_recording(false),
        accessibility: macos::is_process_trusted(false),
        input_monitoring: macos::is_can_input_monitoring(false),
    }
}

/// `{"screen_recording":bool,"accessibility":bool,"input_monitoring":bool}`.
pub fn to_json(permissions: &MacPermissions) -> String {
    serde_json::to_string(permissions).unwrap_or_else(|_| "{}".to_owned())
}

/// The current permissions as JSON, for a caller outside Rust.
#[cfg(target_os = "macos")]
pub fn current_json() -> String {
    to_json(&current())
}

/// Sense Remote (S11 M4): Screen Recording when this process (not the `--server`) said "no":
/// the last answer of a fresh process; starts a new one in the background when due. Never
/// blocks and never prompts.
#[cfg(target_os = "macos")]
pub fn fresh_screen_recording(own: bool) -> bool {
    use std::sync::Mutex;
    static STATE: Mutex<FreshState> = Mutex::new(FreshState {
        last: None,
        running: false,
    });
    let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
    let (answer, spawn) = fresh_decide(own, &state, Instant::now());
    if spawn {
        state.running = true;
        let started = std::thread::Builder::new()
            .name("sense-screen-capture".to_owned())
            .spawn(|| {
                let granted = run_fresh_check();
                let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
                state.last = Some((granted, Instant::now()));
                state.running = false;
            });
        if started.is_err() {
            state.running = false;
            state.last = Some((false, Instant::now()));
        }
    }
    answer
}

/// `<bundle>/Contents/MacOS/service --sense-screen-capture` (the same bundle, so macOS asks
/// about the same app). "No" when it can not run, times out or answers anything else.
#[cfg(target_os = "macos")]
fn run_fresh_check() -> bool {
    use std::process::{Command, Stdio};
    let Some(service) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("service")))
    else {
        return false;
    };
    let Ok(mut child) = Command::new(&service)
        .arg(SERVICE_ARG_SCREEN_CAPTURE)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        hbb_common::log::warn!("Sense Remote: fresh Screen Recording check did not start");
        return false;
    };
    let deadline = Instant::now() + FRESH_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        use std::io::Read;
        let _ = stdout.by_ref().take(16).read_to_string(&mut out);
    }
    parse_fresh_answer(&out).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_has_the_three_contract_fields() {
        let json = to_json(&MacPermissions {
            screen_recording: true,
            accessibility: false,
            input_monitoring: true,
        });
        assert_eq!(
            json,
            r#"{"screen_recording":true,"accessibility":false,"input_monitoring":true}"#
        );
        let back: MacPermissions = serde_json::from_str(&json).unwrap();
        assert!(back.screen_recording && !back.accessibility && back.input_monitoring);
    }

    /// Whatever this machine answers, reading does not prompt or panic and the JSON keeps the
    /// contract shape.
    #[cfg(target_os = "macos")]
    #[test]
    fn live_read_keeps_the_contract_shape() {
        let json = current_json();
        let back: MacPermissions = serde_json::from_str(&json).unwrap();
        assert_eq!(to_json(&back), json);
    }

    #[test]
    fn fresh_answer_is_one_or_zero_only() {
        assert_eq!(parse_fresh_answer("1\n"), Some(true));
        assert_eq!(parse_fresh_answer(" 0 "), Some(false));
        for other in ["", "true", "10", "yes", "1 0"] {
            assert_eq!(parse_fresh_answer(other), None, "{other}");
        }
    }

    /// S11 M4: the wizard's row turns green once a fresh process sees the permission, without
    /// waiting for a process and without starting more than one at a time.
    #[test]
    fn fresh_check_rules() {
        let now = Instant::now();
        let none = FreshState::default();
        // This process says yes: final, no check.
        assert_eq!(fresh_decide(true, &none, now), (true, false));
        // No answer yet: "no" now, a check starts.
        assert_eq!(fresh_decide(false, &none, now), (false, true));
        // One runs: nothing new.
        let running = FreshState {
            last: None,
            running: true,
        };
        assert_eq!(fresh_decide(false, &running, now), (false, false));
        // A fresh "yes" is given at once, even while this process still says "no".
        let granted = FreshState {
            last: Some((true, now)),
            running: false,
        };
        assert_eq!(fresh_decide(false, &granted, now), (true, false));
        // Checked again only after FRESH_EVERY.
        let denied = FreshState {
            last: Some((false, now)),
            running: false,
        };
        assert_eq!(fresh_decide(false, &denied, now), (false, false));
        assert_eq!(
            fresh_decide(false, &denied, now + FRESH_EVERY),
            (false, true)
        );
        // A clock that went back never panics and waits.
        let future = FreshState {
            last: Some((false, now + Duration::from_secs(60))),
            running: false,
        };
        assert_eq!(fresh_decide(false, &future, now), (false, false));
    }
}
