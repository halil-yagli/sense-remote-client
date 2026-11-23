//! Sense Remote (Sürüm 4, S4 / H2; plan 2026-11-23 §2.3, §2.6; TK4; decision #69): changing this
//! computer's role from the app. The user can never write the role by hand.
//!
//! Flow (UI process, no new privileged IPC):
//! 1. `begin(target)`: Sense sign-in with purpose `role` (pairing code, like the permanent
//!    password; `remember_me = false`, the token stays in memory only).
//! 2. `change_status` (polled by the page): once the sign-in is done, the token is used once for
//!    `POST /api/sense/role-change`; the panel checks `install_device` (else
//!    `role_change_denied`) and answers a signed STRATEGY envelope carrying `sense_role`.
//!    The UI checks the envelope against the build keys and the target (a wrong answer never
//!    shows "applying"); it is not applied here.
//! 3. The panel sends the same envelope with the next heartbeat (≤ 15 s); the privileged process
//!    (Windows: SYSTEM `--server`, HKLM; macOS: root daemon, `state.json`) verifies it again and
//!    applies it through the existing `envelope_apply` path, and restarts `--server` when the
//!    change goes into or out of Controller. The new role reaches the panel with the heartbeat.
//! 4. The UI sees the stored role become the target, applies it in this process and answers
//!    `restarting`: the page shows the splash and the app opens with the new role.
//!
//! There is no "no role" target, so the last role can not be removed (`last_role`). Nothing of
//! the token or the envelope is logged or answered; only codes.

use super::{
    envelope::Expect,
    envelope_apply,
    envelope_keys::TrustedKey,
    SenseRole,
};
use hbb_common::{log, ResultType};
use serde_json::{json, Value};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

/// On where a privileged process applies envelopes (Windows, macOS).
pub const SUPPORTED: bool = envelope_apply::APPLIES;

const UNSUPPORTED: &str = "unsupported";
const CHANGE_PATH: &str = "/api/sense/role-change";
/// The sign-in waits this long for the approval (`account.rs` `QUERY_TIMEOUT_SECS`).
const LOGIN_WINDOW_S: i64 = 180;
/// After the panel's answer: the heartbeat (≤ 15 s) and a `--server` restart; then `timeout`.
const APPLY_TIMEOUT: Duration = Duration::from_secs(120);
/// `begin` waits this long for the pairing code.
#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
const PAIRING_WAIT: Duration = Duration::from_secs(10);
/// `RoleChangeError` codes the panel produces (`packages/shared` `client-api/role-change.ts`).
const PANEL_ERRORS: [&str; 9] = [
    "token_invalid",
    "role_scope",
    "device_mismatch",
    "device_not_eligible",
    "role_change_denied",
    "not_supported",
    "signing_unavailable",
    "validation",
    "rate_limited",
];
/// Answers of a panel that does not know the `role` purpose or route yet.
const OUTDATED_PANEL_ERRORS: [&str; 2] = ["purpose_unsupported", "invalid_request"];

/// Wire name of a role (`SenseRole` of the panel contract).
pub fn wire_role(role: SenseRole) -> &'static str {
    match role {
        SenseRole::Host => "host",
        SenseRole::Controller => "controller",
        SenseRole::Both => "host_controller",
    }
}

/// The page's target. There is no "no role": an empty set is the last role being removed.
fn parse_target(target: &str) -> Result<SenseRole, &'static str> {
    match target.trim() {
        "host" => Ok(SenseRole::Host),
        "controller" => Ok(SenseRole::Controller),
        "host_controller" => Ok(SenseRole::Both),
        "" | "none" => Err("last_role"),
        _ => Err("invalid_target"),
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Stage {
    Idle,
    /// Waiting for the Sense sign-in (pairing code). `attempt` tells a newer `begin` apart.
    Login {
        target: SenseRole,
        expires_at: i64,
        attempt: u64,
    },
    /// Sign-in done; the request to the panel is running.
    Verifying { target: SenseRole },
    /// The panel answered a valid envelope; waiting for the privileged process to store it.
    Applying { target: SenseRole, since: Instant },
    /// The role is stored: the app reopens with it.
    Restarting { target: SenseRole },
}

impl Stage {
    /// (target, stage name) for the page; `Verifying` already shows as "applying".
    fn pending(&self) -> Option<(SenseRole, &'static str)> {
        match self {
            Stage::Idle => None,
            Stage::Login { target, .. } => Some((*target, "login")),
            Stage::Verifying { target } | Stage::Applying { target, .. } => {
                Some((*target, "applying"))
            }
            Stage::Restarting { target } => Some((*target, "restarting")),
        }
    }
}

struct State {
    stage: Stage,
    attempts: u64,
}

static STATE: Mutex<State> = Mutex::new(State {
    stage: Stage::Idle,
    attempts: 0,
});

#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

// ---------------------------------------------------------------------------------------------
// Pure core
// ---------------------------------------------------------------------------------------------

/// `main_sense_role_status`: `{roles, pending, error}`.
fn role_status_value(supported: bool, installed: Option<SenseRole>, stage: &Stage) -> Value {
    let error = if !supported {
        Some(UNSUPPORTED)
    } else if installed.is_none() {
        Some("not_installed")
    } else {
        None
    };
    json!({
        "roles": installed.map(|r| vec![wire_role(r)]).unwrap_or_default(),
        "pending": stage.pending().map(|(target, stage)| json!({
            "target": wire_role(target),
            "stage": stage,
        })),
        "error": error,
    })
}

/// Checks of `begin`: the target to sign in for, or the code.
fn begin_check(
    supported: bool,
    installed: Option<SenseRole>,
    target: &str,
    stage: &Stage,
) -> Result<SenseRole, &'static str> {
    if !supported {
        return Err(UNSUPPORTED);
    }
    let target = parse_target(target)?;
    let installed = installed.ok_or("not_installed")?;
    if matches!(
        stage,
        Stage::Verifying { .. } | Stage::Applying { .. } | Stage::Restarting { .. }
    ) {
        return Err("busy");
    }
    if target == installed {
        return Err("unchanged");
    }
    Ok(target)
}

#[derive(Debug, PartialEq)]
enum LoginStep {
    /// Still waiting; the pairing code and URL when they are there.
    Waiting { code: String, url: String },
    Done,
    Failed(&'static str),
}

/// The setup sign-in's state (`enroll::login_status`) → step of this flow.
fn login_step(value: &Value) -> LoginStep {
    let text = |key: &str| value[key].as_str().unwrap_or_default().to_owned();
    match value["state"].as_str() {
        Some("done") => LoginStep::Done,
        Some("failed") => {
            let detail = text("detail");
            if OUTDATED_PANEL_ERRORS.iter().any(|code| detail.contains(code)) {
                LoginStep::Failed("panel_outdated")
            } else if value["error"] == "timeout" {
                LoginStep::Failed("timeout")
            } else {
                LoginStep::Failed("login_failed")
            }
        }
        _ => LoginStep::Waiting {
            code: text("pairing_code"),
            url: text("url"),
        },
    }
}

/// Panel answer → the envelope, or the error code (`RoleChangeError`, `panel_outdated`,
/// `network`).
fn parse_change_answer(status: u16, body: &str) -> Result<Value, &'static str> {
    if (200..300).contains(&status) {
        let answer: Value = serde_json::from_str(body).map_err(|_| "bad_answer")?;
        let object = answer.as_object().ok_or("bad_answer")?;
        return match (object.len(), object.get("envelope")) {
            (1, Some(envelope)) if envelope.is_object() => Ok(envelope.clone()),
            _ => Err("bad_answer"),
        };
    }
    let code = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("error")?.as_str().map(str::to_owned));
    if let Some(code) = code.as_deref() {
        if let Some(known) = PANEL_ERRORS.iter().find(|known| **known == code) {
            return Err(*known);
        }
        if OUTDATED_PANEL_ERRORS.contains(&code) {
            return Err("panel_outdated");
        }
    }
    Err(match status {
        404 | 405 => "panel_outdated",
        401 => "token_invalid",
        403 => "role_change_denied",
        409 => "device_not_eligible",
        429 => "rate_limited",
        _ => "network",
    })
}

/// One request to the panel through `post` (url, body, header) → the envelope.
fn request_change(
    token: Option<String>,
    id: &str,
    uuid: &str,
    target: SenseRole,
    api_server: &str,
    post: impl FnOnce(String, String, String) -> ResultType<(u16, String)>,
) -> Result<Value, &'static str> {
    let token = token.ok_or("token_invalid")?;
    let body = json!({"id": id, "uuid": uuid, "target": wire_role(target)}).to_string();
    let url = format!("{api_server}{CHANGE_PATH}");
    let (status, answer) = post(url, body, format!("Authorization: Bearer {token}")).map_err(|_| {
        log::warn!("Sense Remote: role change request failed (network)");
        "network"
    })?;
    parse_change_answer(status, &answer).map_err(|code| {
        log::warn!("Sense Remote: role change refused: {code} (HTTP {status})");
        code
    })
}

/// The UI's own look at the answer: a strategy envelope for this computer, signed with a build
/// key, with the full permission set and exactly the target role. The privileged process checks
/// it again (with its stored seq) before anything changes; `last_seq` here is 0.
fn check_envelope(
    envelope: &Value,
    target: SenseRole,
    keys: &[TrustedKey],
    expect: &Expect,
) -> Result<u64, &'static str> {
    let verified = envelope_apply::check(envelope, keys, expect, true).map_err(|rejection| {
        log::warn!(
            "Sense Remote: role change answer not valid: {}",
            rejection.reason.as_str()
        );
        "bad_answer"
    })?;
    match verified.body.sense_role {
        Some(role) if role.sense_role() == target => Ok(verified.seq),
        _ => {
            log::warn!("Sense Remote: role change answer carries another role");
            Err("bad_answer")
        }
    }
}

/// While applying: done when the stored role is the target; `timeout` after `APPLY_TIMEOUT`.
fn applying_step(
    target: SenseRole,
    stored: Option<SenseRole>,
    since: Instant,
    now: Instant,
) -> Result<Stage, &'static str> {
    if stored == Some(target) {
        return Ok(Stage::Restarting { target });
    }
    if now.saturating_duration_since(since) >= APPLY_TIMEOUT {
        return Err("timeout");
    }
    Ok(Stage::Applying { target, since })
}

/// `main_sense_role_change_status` answer.
fn change_status_value(stage: &Stage, error: Option<&str>) -> Value {
    match error {
        Some(code) => json!({"stage": Value::Null, "error": code}),
        None => json!({
            "stage": stage.pending().map(|(_, stage)| stage),
            "error": Value::Null,
        }),
    }
}

/// Seconds the helper waits before starting the app again: this process has ended by then (the
/// main window is single-instance, a second one would only bring the old one forward).
const REOPEN_DELAY_S: u32 = 2;

/// The helper that starts this app again after `REOPEN_DELAY_S`: (program, args, raw Windows
/// command line). No user text goes in; the path is passed as an argument on macOS and quoted
/// whole on Windows (a Windows path can not contain `"`).
fn reopen_command(windows: bool, exe: &std::path::Path) -> (String, Vec<String>) {
    if windows {
        // `timeout` refuses a redirected stdin; `ping -n N+1` waits N seconds.
        let line = format!(
            "ping -n {} 127.0.0.1 >nul & start \"\" \"{}\"",
            REOPEN_DELAY_S + 1,
            exe.display()
        );
        return ("cmd".to_owned(), vec!["/C".to_owned(), line]);
    }
    // macOS: open the bundle (`…/X.app/Contents/MacOS/X`) so it comes forward as an app.
    let bundle = exe
        .ancestors()
        .nth(3)
        .filter(|p| p.extension().map_or(false, |e| e == "app"));
    let (script, target) = match bundle {
        Some(bundle) => ("sleep {d}; exec /usr/bin/open -n \"$0\"", bundle),
        None => ("sleep {d}; exec \"$0\"", exe),
    };
    (
        "/bin/sh".to_owned(),
        vec![
            "-c".to_owned(),
            script.replace("{d}", &REOPEN_DELAY_S.to_string()),
            target.display().to_string(),
        ],
    )
}

// ---------------------------------------------------------------------------------------------
// Side effects (Flutter UI only: the sign-in is `hbbs_http::account`)
// ---------------------------------------------------------------------------------------------

#[cfg(feature = "flutter")]
mod ui {
    use super::*;
    use crate::hbbs_http::account::{LoginPurpose, OidcSession};
    use hbb_common::tokio;

    const OIDC_OP: &str = "Google";

    fn now_s() -> i64 {
        hbb_common::get_time() / 1000
    }

    fn login_status() -> Value {
        serde_json::from_str(&crate::sense::enroll::login_status()).unwrap_or(Value::Null)
    }

    #[tokio::main(flavor = "current_thread")]
    async fn post_json(url: String, body: String, header: String) -> ResultType<(u16, String)> {
        crate::common::post_request_with_status(url, body, &header).await
    }

    pub fn role_status() -> String {
        let installed = crate::sense::installed_role();
        let stage = with_state(|s| s.stage.clone());
        role_status_value(SUPPORTED, installed, &stage).to_string()
    }

    pub fn begin(target: &str) -> String {
        let installed = crate::sense::installed_role();
        let started: Result<(SenseRole, i64, u64), &'static str> = with_state(|s| {
            let target = begin_check(SUPPORTED, installed, target, &s.stage)?;
            s.attempts += 1;
            let expires_at = now_s() + LOGIN_WINDOW_S;
            s.stage = Stage::Login {
                target,
                expires_at,
                attempt: s.attempts,
            };
            Ok((target, expires_at, s.attempts))
        });
        let (target, expires_at, attempt) = match started {
            Ok(started) => started,
            Err(code) => {
                log::info!("Sense Remote: role change not started: {code}");
                return json!({"error": code}).to_string();
            }
        };
        log::info!(
            "Sense Remote: role change sign-in started ({} -> {})",
            installed.map_or("none", |r| r.as_str()),
            target.as_str()
        );
        OidcSession::sense_forget_auth();
        OidcSession::account_auth_for(
            crate::sense::api_server(),
            OIDC_OP.to_owned(),
            crate::ui_interface::get_id(),
            crate::ui_interface::get_uuid(),
            false, // remember_me: the token is never saved as the app sign-in
            LoginPurpose::Role,
        );
        // The page shows the pairing code right away: wait for it here.
        let deadline = Instant::now() + PAIRING_WAIT;
        loop {
            let current = with_state(|s| {
                matches!(s.stage, Stage::Login { attempt: a, .. } if a == attempt)
            });
            if !current {
                return json!({"error": "cancelled"}).to_string();
            }
            match login_step(&login_status()) {
                LoginStep::Waiting { code, url } if !url.is_empty() => {
                    return json!({"pairing_code": code, "url": url, "expires_at": expires_at})
                        .to_string();
                }
                LoginStep::Failed(code) => {
                    fail(attempt);
                    return json!({"error": code}).to_string();
                }
                _ if Instant::now() >= deadline => {
                    fail(attempt);
                    return json!({"error": "network"}).to_string();
                }
                _ => std::thread::sleep(Duration::from_millis(200)),
            }
        }
    }

    /// Ends the sign-in of `attempt` (when it is still the running one).
    fn fail(attempt: u64) {
        let ended = with_state(|s| {
            let current = matches!(s.stage, Stage::Login { attempt: a, .. } if a == attempt);
            if current {
                s.stage = Stage::Idle;
            }
            current
        });
        if ended {
            OidcSession::sense_forget_auth();
        }
    }

    pub fn change_status() -> String {
        let stage = with_state(|s| s.stage.clone());
        let (stage, error) = match stage {
            Stage::Login {
                target,
                expires_at,
                attempt,
            } => login_progress(target, expires_at, attempt),
            Stage::Applying { target, since } => {
                let stored = crate::sense::installed_role();
                match applying_step(target, stored, since, Instant::now()) {
                    Ok(next) => {
                        if matches!(next, Stage::Restarting { .. }) {
                            // This process too: the home screen reads the role settings.
                            crate::sense::apply_role(Some(target));
                            log::info!("Sense Remote: role changed to {}", target.as_str());
                        }
                        set_if_current(&Stage::Applying { target, since }, next.clone());
                        (next, None)
                    }
                    Err(code) => {
                        log::warn!("Sense Remote: role change not applied in time");
                        set_if_current(&Stage::Applying { target, since }, Stage::Idle);
                        (Stage::Idle, Some(code))
                    }
                }
            }
            other => (other, None),
        };
        change_status_value(&stage, error).to_string()
    }

    fn set_if_current(expected: &Stage, next: Stage) {
        with_state(|s| {
            if &s.stage == expected {
                s.stage = next;
            }
        });
    }

    /// Login stage: waiting, failed, or done → one request to the panel.
    fn login_progress(target: SenseRole, expires_at: i64, attempt: u64) -> (Stage, Option<&'static str>) {
        let login = Stage::Login {
            target,
            expires_at,
            attempt,
        };
        let step = if now_s() > expires_at {
            LoginStep::Failed("timeout")
        } else {
            login_step(&login_status())
        };
        match step {
            LoginStep::Waiting { .. } => (login, None),
            LoginStep::Failed(code) => {
                fail(attempt);
                (Stage::Idle, Some(code))
            }
            LoginStep::Done => {
                // Only one caller moves on from this sign-in.
                let claimed = with_state(|s| {
                    let current = s.stage == login;
                    if current {
                        s.stage = Stage::Verifying { target };
                    }
                    current
                });
                if !claimed {
                    let stage = with_state(|s| s.stage.clone());
                    return (stage, None);
                }
                let token = OidcSession::sense_access_token();
                // The token leaves memory whatever happens next (single use on the panel too).
                OidcSession::sense_forget_auth();
                let id = crate::ui_interface::get_id();
                let uuid = crate::ui_interface::get_uuid();
                let result = request_change(token, &id, &uuid, target, &crate::sense::api_server(), post_json)
                    .and_then(|envelope| {
                        let iss = crate::sense::envelope::expected_issuer();
                        let expect = Expect {
                            iss: &iss,
                            did: &id,
                            duuid: &uuid,
                            now_s: now_s(),
                            last_seq: 0,
                        };
                        check_envelope(&envelope, target, crate::sense::envelope_keys::trusted_keys(), &expect)
                    });
                let verifying = Stage::Verifying { target };
                match result {
                    Ok(seq) => {
                        log::info!("Sense Remote: role change signed by the panel (seq {seq}), waiting for the service");
                        let next = Stage::Applying {
                            target,
                            since: Instant::now(),
                        };
                        set_if_current(&verifying, next.clone());
                        (next, None)
                    }
                    Err(code) => {
                        set_if_current(&verifying, Stage::Idle);
                        (Stage::Idle, Some(code))
                    }
                }
            }
        }
    }

    /// Starts the app again (after the splash) so the new role's window opens; only once the
    /// role is stored. "" = the helper runs and the page ends this process.
    pub fn reopen() -> String {
        let restarting = with_state(|s| matches!(s.stage, Stage::Restarting { .. }));
        if !restarting {
            return "not_restarting".to_owned();
        }
        let exe = match std::env::current_exe() {
            Ok(exe) => exe,
            Err(err) => {
                log::warn!("Sense Remote: reopen after the role change failed: {err}");
                return "reopen_failed".to_owned();
            }
        };
        let (program, args) = reopen_command(cfg!(windows), &exe);
        let mut command = std::process::Command::new(program);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.arg(&args[0]).raw_arg(&args[1]).creation_flags(CREATE_NO_WINDOW);
        }
        #[cfg(not(windows))]
        command.args(&args);
        match command.spawn() {
            Ok(_) => {
                log::info!("Sense Remote: the app reopens with the new role");
                String::new()
            }
            Err(err) => {
                log::warn!("Sense Remote: reopen after the role change failed: {err}");
                "reopen_failed".to_owned()
            }
        }
    }

    pub fn cancel() {
        // Only the sign-in can be cancelled; once the panel signed, the change goes on.
        let was_login = with_state(|s| {
            let login = matches!(s.stage, Stage::Login { .. });
            if login {
                s.stage = Stage::Idle;
            }
            login
        });
        if was_login {
            OidcSession::sense_forget_auth();
            log::info!("Sense Remote: role change sign-in cancelled");
        }
    }
}

// ---------------------------------------------------------------------------------------------
// FFI (`main_sense_role_*`, names from D3-0)
// ---------------------------------------------------------------------------------------------

/// `main_sense_role_status`: `{roles: [..], pending: null | {target, stage}, error}`.
#[cfg(feature = "flutter")]
pub fn ffi_role_status() -> String {
    ui::role_status()
}

/// `main_sense_role_change_begin`: starts the sign-in for `target` ("host" / "controller" /
/// "host_controller") → `{pairing_code, url, expires_at}` or `{error}`.
#[cfg(feature = "flutter")]
pub fn ffi_role_change_begin(target: &str) -> String {
    ui::begin(target)
}

/// `main_sense_role_change_status`: `{stage: null | "login" | "applying" | "restarting", error:
/// null | "role_change_denied" | "last_role" | "timeout" | "network" | other code}`.
#[cfg(feature = "flutter")]
pub fn ffi_role_change_status() -> String {
    ui::change_status()
}

/// `main_sense_role_change_cancel`: drops a running sign-in.
#[cfg(feature = "flutter")]
pub fn ffi_role_change_cancel() {
    ui::cancel()
}

/// `main_sense_role_reopen`: after the splash, starts the app again with the new role → "" (the
/// page then ends this process) or an error code.
#[cfg(feature = "flutter")]
pub fn ffi_role_reopen() -> String {
    ui::reopen()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::{
        envelope::{OptionRule, ALLOWED_OPTIONS, SIGNING_PREFIX},
        envelope_keys::key_id,
    };
    use hbb_common::{
        base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
        sodiumoxide::{self, crypto::sign},
    };
    use serde_json::Map;

    const ISS: &str = "remote.snsdpt.com";
    const DID: &str = "123456789";
    const DUUID: &str = "dGVzdC11dWlk";
    const NOW: i64 = 1_800_000_000;

    fn parse(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    #[test]
    fn wire_names_match_the_contract() {
        assert_eq!(wire_role(SenseRole::Host), "host");
        assert_eq!(wire_role(SenseRole::Controller), "controller");
        assert_eq!(wire_role(SenseRole::Both), "host_controller");
        for role in [SenseRole::Host, SenseRole::Controller, SenseRole::Both] {
            assert_eq!(parse_target(wire_role(role)), Ok(role));
        }
    }

    // S4: the last role can not be removed — there is no "no role" target.
    #[test]
    fn last_role_can_not_be_removed() {
        for empty in ["", "none", "  "] {
            assert_eq!(parse_target(empty), Err("last_role"));
            assert_eq!(
                begin_check(true, Some(SenseRole::Host), empty, &Stage::Idle),
                Err("last_role")
            );
        }
        assert_eq!(parse_target("both"), Err("invalid_target"));
    }

    #[test]
    fn begin_checks() {
        let idle = Stage::Idle;
        assert_eq!(begin_check(false, Some(SenseRole::Host), "controller", &idle), Err("unsupported"));
        assert_eq!(begin_check(true, None, "controller", &idle), Err("not_installed"));
        assert_eq!(begin_check(true, Some(SenseRole::Host), "host", &idle), Err("unchanged"));
        assert_eq!(
            begin_check(true, Some(SenseRole::Host), "host_controller", &idle),
            Ok(SenseRole::Both)
        );
        // A new sign-in replaces one that waits; not while the change runs.
        let login = Stage::Login {
            target: SenseRole::Both,
            expires_at: 0,
            attempt: 1,
        };
        assert_eq!(
            begin_check(true, Some(SenseRole::Host), "controller", &login),
            Ok(SenseRole::Controller)
        );
        for running in [
            Stage::Verifying { target: SenseRole::Both },
            Stage::Applying { target: SenseRole::Both, since: Instant::now() },
            Stage::Restarting { target: SenseRole::Both },
        ] {
            assert_eq!(
                begin_check(true, Some(SenseRole::Host), "controller", &running),
                Err("busy")
            );
        }
    }

    #[test]
    fn role_status_shape() {
        assert_eq!(
            role_status_value(true, Some(SenseRole::Both), &Stage::Idle),
            json!({"roles": ["host_controller"], "pending": null, "error": null})
        );
        assert_eq!(
            role_status_value(false, None, &Stage::Idle),
            json!({"roles": [], "pending": null, "error": "unsupported"})
        );
        assert_eq!(role_status_value(true, None, &Stage::Idle)["error"], "not_installed");
        let stages = [
            (
                Stage::Login { target: SenseRole::Controller, expires_at: 1, attempt: 1 },
                "login",
            ),
            (Stage::Verifying { target: SenseRole::Controller }, "applying"),
            (
                Stage::Applying { target: SenseRole::Controller, since: Instant::now() },
                "applying",
            ),
            (Stage::Restarting { target: SenseRole::Controller }, "restarting"),
        ];
        for (stage, name) in stages {
            assert_eq!(
                role_status_value(true, Some(SenseRole::Host), &stage)["pending"],
                json!({"target": "controller", "stage": name})
            );
            assert_eq!(
                change_status_value(&stage, None),
                json!({"stage": name, "error": null})
            );
        }
        assert_eq!(
            change_status_value(&Stage::Idle, None),
            json!({"stage": null, "error": null})
        );
        assert_eq!(
            change_status_value(&Stage::Idle, Some("role_change_denied")),
            json!({"stage": null, "error": "role_change_denied"})
        );
    }

    #[test]
    fn login_steps() {
        assert_eq!(login_step(&json!({"state": "requesting"})), LoginStep::Waiting {
            code: String::new(),
            url: String::new()
        });
        assert_eq!(
            login_step(&json!({"state": "waiting", "url": "https://p/x", "pairing_code": "123456"})),
            LoginStep::Waiting { code: "123456".into(), url: "https://p/x".into() }
        );
        assert_eq!(login_step(&json!({"state": "done", "user": {}})), LoginStep::Done);
        assert_eq!(
            login_step(&json!({"state": "failed", "error": "timeout", "detail": "timeout"})),
            LoginStep::Failed("timeout")
        );
        for detail in OUTDATED_PANEL_ERRORS {
            assert_eq!(
                login_step(&json!({"state": "failed", "error": "failed", "detail": detail})),
                LoginStep::Failed("panel_outdated")
            );
        }
        assert_eq!(
            login_step(&json!({"state": "failed", "error": "failed", "detail": "x"})),
            LoginStep::Failed("login_failed")
        );
    }

    /// The fake panel: checks what is sent and answers `(status, body)`.
    fn fake_panel(
        status: u16,
        body: String,
    ) -> impl FnOnce(String, String, String) -> ResultType<(u16, String)> {
        move |url, sent, header| {
            assert_eq!(url, "https://remote.snsdpt.com/api/sense/role-change");
            assert_eq!(header, "Authorization: Bearer TOKEN-MARKER");
            assert_eq!(
                parse(&sent),
                json!({"id": DID, "uuid": DUUID, "target": "controller"})
            );
            Ok((status, body))
        }
    }

    fn request_fake(status: u16, body: String) -> Result<Value, &'static str> {
        request_change(
            Some("TOKEN-MARKER".to_owned()),
            DID,
            DUUID,
            SenseRole::Controller,
            "https://remote.snsdpt.com",
            fake_panel(status, body),
        )
    }

    #[test]
    fn request_success_returns_the_envelope() {
        let envelope = json!({"k": "94d01a580be13482", "p": "x", "s": "y"});
        let answer = request_fake(200, json!({"envelope": envelope}).to_string());
        assert_eq!(answer, Ok(envelope));
    }

    // S4: `install_device` missing → `role_change_denied`; every other panel code passes.
    #[test]
    fn request_maps_every_panel_error() {
        let statuses = [401, 403, 403, 409, 403, 409, 409, 400, 429];
        for (code, status) in PANEL_ERRORS.iter().zip(statuses) {
            let body = json!({"error": code}).to_string();
            assert_eq!(request_fake(status, body), Err(*code));
        }
        for (status, code) in [
            (401, "token_invalid"),
            (403, "role_change_denied"),
            (409, "device_not_eligible"),
            (429, "rate_limited"),
            (500, "network"),
            (404, "panel_outdated"),
        ] {
            assert_eq!(request_fake(status, "<html>".to_owned()), Err(code));
        }
        for code in OUTDATED_PANEL_ERRORS {
            assert_eq!(
                request_fake(400, json!({"error": code}).to_string()),
                Err("panel_outdated")
            );
        }
        // Not the contract.
        assert_eq!(request_fake(200, "{}".to_owned()), Err("bad_answer"));
        assert_eq!(request_fake(200, "x".to_owned()), Err("bad_answer"));
        assert_eq!(
            request_fake(200, json!({"envelope": {}, "extra": 1}).to_string()),
            Err("bad_answer")
        );
    }

    #[test]
    fn request_without_network_or_token() {
        let down = |_: String, _: String, _: String| -> ResultType<(u16, String)> {
            Err(hbb_common::anyhow::anyhow!("connection refused"))
        };
        let never = |_: String, _: String, _: String| -> ResultType<(u16, String)> {
            panic!("no request")
        };
        assert_eq!(
            request_change(Some("t".into()), DID, DUUID, SenseRole::Host, "https://p", down),
            Err("network")
        );
        assert_eq!(
            request_change(None, DID, DUUID, SenseRole::Host, "https://p", never),
            Err("token_invalid")
        );
    }

    struct Signer {
        sk: sign::SecretKey,
        trusted: TrustedKey,
    }

    // Key made at run time; nothing secret is stored in the repository.
    fn signer() -> Signer {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        Signer {
            sk,
            trusted: TrustedKey {
                k: key_id(&pk.0),
                public_key: pk.0,
            },
        }
    }

    impl Signer {
        fn sign(&self, payload: &Value) -> Value {
            let payload = serde_json::to_vec(payload).unwrap();
            let mut data = SIGNING_PREFIX.to_vec();
            data.extend_from_slice(&payload);
            let signature = &sign::sign(&data, &self.sk)[..64];
            json!({
                "k": self.trusted.k,
                "p": URL_SAFE_NO_PAD.encode(&payload),
                "s": URL_SAFE_NO_PAD.encode(signature),
            })
        }
    }

    fn strategy(did: &str, role: Option<&str>, full: bool) -> Value {
        let mut set = Map::new();
        for (key, rule) in ALLOWED_OPTIONS.iter().skip(usize::from(!full)) {
            let value = match rule {
                OptionRule::YesNo => "Y",
                OptionRule::Empty | OptionRule::Minutes => "",
            };
            set.insert((*key).to_owned(), json!(value));
        }
        let mut body = json!({"config_options": set, "revision": 2});
        if let Some(role) = role {
            body["sense_role"] = json!(role);
        }
        json!({
            "v": 1, "typ": "strategy", "iss": ISS, "did": did, "duuid": DUUID, "seq": 7,
            "nonce": "AAECAwQFBgcICQoLDA0ODw", "iat": NOW, "nbf": NOW, "exp": NOW + 86_400,
            "body": body,
        })
    }

    fn expect() -> Expect<'static> {
        Expect {
            iss: ISS,
            did: DID,
            duuid: DUUID,
            now_s: NOW,
            last_seq: 0,
        }
    }

    // The answer is checked before the page says "applying"; the service checks it again.
    #[test]
    fn envelope_is_checked_before_applying() {
        let s = signer();
        let keys = [s.trusted.clone()];
        let good = s.sign(&strategy(DID, Some("controller"), true));
        assert_eq!(check_envelope(&good, SenseRole::Controller, &keys, &expect()), Ok(7));
        // Another role than asked, no role, another computer, partial set, unknown key.
        for bad in [
            s.sign(&strategy(DID, Some("host_controller"), true)),
            s.sign(&strategy(DID, None, true)),
            s.sign(&strategy("987654321", Some("controller"), true)),
            s.sign(&strategy(DID, Some("controller"), false)),
            signer().sign(&strategy(DID, Some("controller"), true)),
        ] {
            assert_eq!(
                check_envelope(&bad, SenseRole::Controller, &keys, &expect()),
                Err("bad_answer")
            );
        }
        let mut tampered = good.clone();
        tampered["s"] = json!(URL_SAFE_NO_PAD.encode([0u8; 64]));
        assert_eq!(
            check_envelope(&tampered, SenseRole::Controller, &keys, &expect()),
            Err("bad_answer")
        );
    }

    // S4: the role is applied by the service; the page goes on only when it is stored.
    #[test]
    fn applying_waits_for_the_stored_role() {
        let since = Instant::now();
        assert_eq!(
            applying_step(SenseRole::Controller, Some(SenseRole::Host), since, since),
            Ok(Stage::Applying { target: SenseRole::Controller, since })
        );
        assert_eq!(
            applying_step(SenseRole::Controller, Some(SenseRole::Controller), since, since),
            Ok(Stage::Restarting { target: SenseRole::Controller })
        );
        assert_eq!(
            applying_step(SenseRole::Controller, Some(SenseRole::Host), since, since + APPLY_TIMEOUT),
            Err("timeout")
        );
        // Stored before the timeout wins.
        assert_eq!(
            applying_step(SenseRole::Both, Some(SenseRole::Both), since, since + APPLY_TIMEOUT * 2),
            Ok(Stage::Restarting { target: SenseRole::Both })
        );
    }

    // The app starts again by itself after the role change (no user text in the command).
    #[test]
    fn reopen_command_per_platform() {
        let win = std::path::Path::new(r"C:\Program Files\SenseRemote\SenseRemote.exe");
        let (program, args) = reopen_command(true, win);
        assert_eq!(program, "cmd");
        assert_eq!(
            args,
            vec![
                "/C".to_owned(),
                r#"ping -n 3 127.0.0.1 >nul & start "" "C:\Program Files\SenseRemote\SenseRemote.exe""#
                    .to_owned()
            ]
        );
        let mac = std::path::Path::new("/Applications/Sense Remote.app/Contents/MacOS/SenseRemote");
        let (program, args) = reopen_command(false, mac);
        assert_eq!(program, "/bin/sh");
        assert_eq!(
            args,
            vec![
                "-c".to_owned(),
                r#"sleep 2; exec /usr/bin/open -n "$0""#.to_owned(),
                "/Applications/Sense Remote.app".to_owned()
            ]
        );
        // Not inside a bundle: the program itself.
        let (_, args) = reopen_command(false, std::path::Path::new("/opt/sense/SenseRemote"));
        assert_eq!(args[1], r#"sleep 2; exec "$0""#);
        assert_eq!(args[2], "/opt/sense/SenseRemote");
    }

    // TK4: no new privileged IPC, no hand-written role, no saved app sign-in.
    #[test]
    fn no_ipc_no_role_write_no_saved_sign_in() {
        let source = include_str!("role_change.rs");
        let code = &source[..source.find("mod tests {").unwrap()];
        for forbidden in ["crate::ipc", "store_role", "LocalConfig::", "LoginPurpose::App"] {
            assert!(!code.contains(forbidden), "{forbidden}");
        }
        assert!(code.contains("false, // remember_me"));
        assert!(code.contains("LoginPurpose::Role"));
    }

    /// Captures every log line of this test binary.
    struct Capture;
    static CAPTURE: Capture = Capture;
    static LINES: Mutex<Vec<String>> = Mutex::new(Vec::new());
    impl log::Log for Capture {
        fn enabled(&self, _: &log::Metadata) -> bool {
            true
        }
        fn log(&self, record: &log::Record) {
            LINES
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(format!("{}", record.args()));
        }
        fn flush(&self) {}
    }

    #[test]
    fn nothing_secret_reaches_the_log() {
        let _ = log::set_logger(&CAPTURE);
        log::set_max_level(log::LevelFilter::Trace);
        let _ = request_fake(403, json!({"error": "role_change_denied"}).to_string());
        let _ = request_change(
            Some("TOKEN-MARKER".into()),
            DID,
            DUUID,
            SenseRole::Host,
            "https://p",
            |_, _, _| Err(hbb_common::anyhow::anyhow!("down")),
        );
        let s = signer();
        let wrong = s.sign(&strategy(DID, Some("host"), true));
        let _ = check_envelope(&wrong, SenseRole::Controller, &[s.trusted.clone()], &expect());
        let lines = LINES.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let p = wrong["p"].as_str().unwrap().to_owned();
        for line in &lines {
            for marker in ["TOKEN-MARKER", "Bearer", p.as_str()] {
                assert!(!line.contains(marker), "{line}");
            }
        }
    }
}
