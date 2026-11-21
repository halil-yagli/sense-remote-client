//! Sense Remote (permanent password plan §3.4, §3.7, U10): UI-process side of the seven FFI
//! calls.
//!
//! Flow: `begin` asks the privileged process for a signed request (fresh nonce) and starts the
//! panel's OIDC flow with `purpose = "password"` and `remember_me = false`; `login_status`
//! shows the pairing code; `unlock` sends the request with the short-lived token to
//! `POST /api/sense/password-grant` and keeps the panel's grant in memory only (until it expires
//! or `set` / `cancel`); `set` hands grant + new password to the privileged process, which
//! checks everything again (§3.3) and writes.
//!
//! The token is dropped after `unlock` in every case and is never saved: the Controller's saved
//! app sign-in (`LocalConfig access_token`) is not touched. No answer carries a password, token,
//! key, request or grant, and none of them is logged (only codes).

use super::{
    request::incoming_role, status::AccessStatus, SensePasswordIpc, SensePasswordSecret,
    PASSWORD_GRANT_TTL_S,
};
use crate::{
    hbbs_http::account::{LoginPurpose, OidcSession},
    sense::SenseRole,
};
use hbb_common::{config::Config, log, tokio, ResultType};
use serde_derive::Deserialize;
use serde_json::{json, Value};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

const OIDC_OP: &str = "Google";
const GRANT_PATH: &str = "/api/sense/password-grant";
/// `PasswordGrantError` (panel `client-api/password.ts`).
const GRANT_ERRORS: [&str; 10] = [
    "token_invalid",
    "password_scope",
    "device_mismatch",
    "device_not_eligible",
    "bad_request_signature",
    "request_expired",
    "replayed",
    "rate_limited",
    "signing_unavailable",
    "validation",
];
/// Answers of a panel that does not know the `password` purpose or route yet
/// (`OIDC_PURPOSE_UNSUPPORTED_ERROR`; older panels refuse the unknown purpose as a schema error).
const OUTDATED_PANEL_ERRORS: [&str; 2] = ["purpose_unsupported", "invalid_request"];
/// `Begin` answer codes of the privileged process the UI shows as they are.
const BEGIN_ERRORS: [&str; 4] = ["not_incoming", "unsupported", "busy", "rate_limited"];
const IPC_BEGIN_MS: u64 = 5_000;
const IPC_SET_MS: u64 = 15_000;
const IPC_STATUS_MS: u64 = 1_000;

/// The panel's grant, in memory only.
struct HeldGrant {
    grant: String,
    deadline: Instant,
    until: i64,
    user: String,
}

#[derive(Default)]
struct UiState {
    /// The signed request of the running unlock (between `begin` and `unlock`).
    request: Option<String>,
    grant: Option<HeldGrant>,
}

impl UiState {
    fn drop_expired(&mut self, now: Instant) {
        if self.grant.as_ref().is_some_and(|g| now >= g.deadline) {
            self.grant = None;
        }
    }

    /// (stage, until, user) for the page.
    fn stage(&mut self, now: Instant) -> (&'static str, Option<i64>, Option<String>) {
        self.drop_expired(now);
        match (&self.grant, &self.request) {
            (Some(g), _) => ("unlocked", Some(g.until), Some(g.user.clone())),
            (None, Some(_)) => ("verifying", None, None),
            (None, None) => ("locked", None, None),
        }
    }

    fn clear(&mut self) {
        self.request = None;
        self.grant = None;
    }
}

static STATE: Mutex<Option<UiState>> = Mutex::new(None);

fn with_state<R>(f: impl FnOnce(&mut UiState) -> R) -> R {
    let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(UiState::default))
}

fn is_incoming(role: Option<SenseRole>) -> bool {
    role.and_then(incoming_role).is_some()
}

// ---------------------------------------------------------------------------------------------
// Side effects: IPC to the privileged process, HTTP to the panel.
// ---------------------------------------------------------------------------------------------

#[tokio::main(flavor = "current_thread")]
async fn ipc_call(message: SensePasswordIpc, timeout_ms: Option<u64>) -> Option<SensePasswordIpc> {
    let mut conn = crate::ipc::connect(1_000, "").await.ok()?;
    conn.send(&crate::ipc::Data::SensePassword(message)).await.ok()?;
    match conn.next_timeout(timeout_ms?).await {
        Ok(Some(crate::ipc::Data::SensePassword(reply))) => Some(reply),
        _ => None,
    }
}

#[tokio::main(flavor = "current_thread")]
async fn post_json(url: String, body: String, header: String) -> ResultType<(u16, String)> {
    crate::common::post_request_with_status(url, body, &header).await
}

// ---------------------------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------------------------

/// `main_sense_password_status`.
pub fn status() -> String {
    let role = crate::sense::installed_role();
    let access = (super::SUPPORTED && is_incoming(role))
        .then(|| ipc_call(SensePasswordIpc::StatusQuery, Some(IPC_STATUS_MS)))
        .flatten()
        .and_then(|reply| match reply {
            SensePasswordIpc::Status(json) => serde_json::from_str::<AccessStatus>(&json).ok(),
            _ => None,
        });
    let (stage, until, user) = with_state(|s| s.stage(Instant::now()));
    status_value(super::SUPPORTED, role, access.as_ref(), stage, until, user).to_string()
}

fn role_name(role: Option<SenseRole>) -> &'static str {
    match role {
        Some(SenseRole::Host) => "host",
        Some(SenseRole::Both) => "both",
        Some(SenseRole::Controller) => "controller",
        None => "none",
    }
}

/// Pure part of `status`. `perm_set` is null while unknown (no answer of the privileged
/// process).
fn status_value(
    supported: bool,
    role: Option<SenseRole>,
    access: Option<&AccessStatus>,
    stage: &str,
    until: Option<i64>,
    user: Option<String>,
) -> Value {
    json!({
        "supported": supported,
        "role": role_name(role),
        "perm_set": access.map(|a| a.perm_set),
        "changed_at": access.and_then(|a| a.changed_at),
        "stage": stage,
        "until": until,
        "user": user,
    })
}

/// `main_sense_password_begin`: `{"ok":true}` or `{"ok":false,"error":...}`.
pub fn begin() -> String {
    let request = begin_with(super::SUPPORTED, crate::sense::installed_role(), |message| {
        ipc_call(message, Some(IPC_BEGIN_MS))
    });
    match request {
        Ok(request) => {
            with_state(|s| {
                s.clear();
                s.request = Some(request);
            });
            OidcSession::sense_forget_auth();
            OidcSession::account_auth_for(
                crate::sense::api_server(),
                OIDC_OP.to_owned(),
                crate::ui_interface::get_id(),
                crate::ui_interface::get_uuid(),
                false, // remember_me: the token is never saved as the app sign-in
                LoginPurpose::Password,
            );
            json!({"ok": true}).to_string()
        }
        Err(code) => {
            log::info!("Sense Remote: password unlock not started: {code}");
            json!({"ok": false, "error": code}).to_string()
        }
    }
}

/// Pure part of `begin`: the signed request from the privileged process, or the error code.
fn begin_with(
    supported: bool,
    role: Option<SenseRole>,
    call: impl FnOnce(SensePasswordIpc) -> Option<SensePasswordIpc>,
) -> Result<String, &'static str> {
    if !supported {
        return Err(super::UNSUPPORTED);
    }
    if !is_incoming(role) {
        return Err("not_incoming");
    }
    match call(SensePasswordIpc::Begin) {
        Some(SensePasswordIpc::Request(Ok(request))) => Ok(request),
        Some(SensePasswordIpc::Request(Err(code))) => Err(BEGIN_ERRORS
            .iter()
            .find(|known| **known == code)
            .copied()
            .unwrap_or("ipc_failed")),
        _ => Err("ipc_failed"),
    }
}

/// `main_sense_password_login_status`: the setup sign-in's shape (`enroll::login_status`; the
/// URL only when it is a page of our panel, never the token); a panel that does not know the
/// `password` purpose gives `panel_outdated`.
pub fn login_status() -> String {
    let value = serde_json::from_str(&crate::sense::enroll::login_status()).unwrap_or(Value::Null);
    login_status_value(value).to_string()
}

fn login_status_value(value: Value) -> Value {
    if value["state"] == "failed" {
        let detail = value["detail"].as_str().unwrap_or_default();
        if OUTDATED_PANEL_ERRORS.iter().any(|code| detail.contains(code)) {
            return json!({"state": "failed", "error": "panel_outdated"});
        }
    }
    value
}

/// The panel's answer (`PasswordGrantResponse`).
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GrantAnswer {
    grant: Value,
    until: i64,
    user: GrantUser,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GrantUser {
    name: String,
    #[serde(default)]
    display_name: Option<String>,
}

impl GrantUser {
    fn shown(&self) -> String {
        match &self.display_name {
            Some(name) if !name.is_empty() => name.clone(),
            _ => self.name.clone(),
        }
    }
}

/// Panel answer → grant or error code (`PasswordGrantError`, `panel_outdated`, `network`).
fn parse_grant_answer(status: u16, body: &str) -> Result<GrantAnswer, &'static str> {
    if (200..300).contains(&status) {
        return serde_json::from_str::<GrantAnswer>(body)
            .ok()
            .filter(|a| a.grant.is_object() && a.until > 0)
            .ok_or("network");
    }
    let code = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("error")?.as_str().map(str::to_owned));
    if let Some(code) = code.as_deref() {
        if let Some(known) = GRANT_ERRORS.iter().find(|known| **known == code) {
            return Err(*known);
        }
        if OUTDATED_PANEL_ERRORS.contains(&code) {
            return Err("panel_outdated");
        }
    }
    Err(match status {
        404 | 405 => "panel_outdated",
        401 => "token_invalid",
        403 => "password_scope",
        429 => "rate_limited",
        503 => "signing_unavailable",
        _ => "network",
    })
}

/// `main_sense_password_unlock`.
pub fn unlock() -> String {
    let token = OidcSession::sense_access_token();
    // The token leaves memory whatever happens next.
    OidcSession::sense_forget_auth();
    let request = with_state(|s| s.request.take());
    let answer = unlock_with(
        token,
        request,
        &crate::ui_interface::get_id(),
        &crate::ui_interface::get_uuid(),
        post_json,
    );
    let (text, held) = unlock_answer(answer, Instant::now(), hbb_common::get_time() / 1000);
    if let Some(held) = held {
        with_state(|s| s.grant = Some(held));
    }
    text
}

/// Pure part of `unlock`: one request to the panel through `post`.
fn unlock_with(
    token: Option<String>,
    request: Option<String>,
    id: &str,
    uuid: &str,
    post: impl FnOnce(String, String, String) -> ResultType<(u16, String)>,
) -> Result<GrantAnswer, &'static str> {
    let token = token.ok_or("token_invalid")?;
    let request: Value = request
        .and_then(|r| serde_json::from_str(&r).ok())
        .ok_or("no_pending")?;
    let body = json!({"id": id, "uuid": uuid, "request": request}).to_string();
    let url = format!("{}{GRANT_PATH}", crate::sense::api_server());
    let (status, answer) = post(url, body, format!("Authorization: Bearer {token}")).map_err(|_| {
        log::warn!("Sense Remote: password grant request failed (network)");
        "network"
    })?;
    parse_grant_answer(status, &answer).map_err(|code| {
        log::warn!("Sense Remote: password grant refused: {code} (HTTP {status})");
        code
    })
}

/// The page's answer and the grant to keep in memory. The lock closes after the grant's own
/// lifetime at most, counted on the monotonic clock (`now_s` = local Unix seconds).
fn unlock_answer(
    answer: Result<GrantAnswer, &'static str>,
    now: Instant,
    now_s: i64,
) -> (String, Option<HeldGrant>) {
    match answer {
        Ok(answer) => {
            let secs = (answer.until - now_s).clamp(1, PASSWORD_GRANT_TTL_S);
            let user = answer.user.shown();
            log::info!("Sense Remote: permanent password unlocked");
            let text = json!({"ok": true, "until": answer.until, "user": user}).to_string();
            let held = HeldGrant {
                grant: answer.grant.to_string(),
                deadline: now + Duration::from_secs(secs as u64),
                until: answer.until,
                user,
            };
            (text, Some(held))
        }
        Err(code) => (json!({"ok": false, "error": code}).to_string(), None),
    }
}

/// `main_sense_password_check`: "" or a rule code (hint only; the privileged process decides).
pub fn check(password: &str) -> String {
    match super::rule::check(password, &Config::get_id()) {
        Ok(()) => String::new(),
        Err(code) => code.to_owned(),
    }
}

/// `main_sense_password_set`: "" or an error code.
pub fn set(password: String) -> String {
    let password = SensePasswordSecret::new(password);
    let role = crate::sense::installed_role();
    let rid = Config::get_id();
    // The grant is taken out so the page can keep asking for the status while the privileged
    // process writes; it goes back only when the answer leaves it usable.
    let mut local = UiState {
        request: None,
        grant: with_state(|s| s.grant.take()),
    };
    let code = set_with(super::SUPPORTED, role, &rid, &password, &mut local, Instant::now(), |message| {
        ipc_call(message, Some(IPC_SET_MS))
    });
    if let Some(held) = local.grant {
        with_state(|s| {
            if s.grant.is_none() {
                s.grant = Some(held);
            }
        });
    }
    code
}

/// Pure part of `set`. The grant is kept only when the answer leaves it usable (weak password,
/// privileged process not reachable or busy).
fn set_with(
    supported: bool,
    role: Option<SenseRole>,
    rid: &str,
    password: &SensePasswordSecret,
    state: &mut UiState,
    now: Instant,
    call: impl FnOnce(SensePasswordIpc) -> Option<SensePasswordIpc>,
) -> String {
    if !supported {
        return super::UNSUPPORTED.to_owned();
    }
    if !is_incoming(role) {
        return "not_incoming".to_owned();
    }
    state.drop_expired(now);
    let Some(held) = state.grant.take() else {
        return "no_pending".to_owned();
    };
    if let Err(rule) = super::rule::check(password.expose(), rid) {
        state.grant = Some(held);
        return format!("weak_password:{rule}");
    }
    let code = match call(SensePasswordIpc::Set {
        grant: held.grant.clone(),
        password: password.clone(),
    }) {
        Some(SensePasswordIpc::SetResult { code, .. }) => code,
        _ => "ipc_failed".to_owned(),
    };
    if code.starts_with("weak_password:") || code == "busy" || code == "ipc_failed" {
        state.grant = Some(held);
    }
    if code.is_empty() {
        log::info!("Sense Remote: permanent password changed");
    } else {
        log::warn!("Sense Remote: permanent password not changed: {code}");
    }
    code
}

/// `main_sense_password_cancel`: the sign-in is forgotten, the grant dropped, the privileged
/// process drops its pending nonce.
pub fn cancel() {
    OidcSession::sense_forget_auth();
    let was_running = with_state(|s| {
        let running = s.request.is_some() || s.grant.is_some();
        s.clear();
        running
    });
    if super::SUPPORTED && was_running {
        ipc_call(SensePasswordIpc::Cancel, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRANT: &str = r#"{"k":"94d01a580be13482","p":"GRANT-MARKER","s":"x"}"#;

    fn granted_state(now: Instant) -> UiState {
        UiState {
            request: None,
            grant: Some(HeldGrant {
                grant: GRANT.to_owned(),
                deadline: now + Duration::from_secs(300),
                until: 1_800_000_300,
                user: "Deneme".to_owned(),
            }),
        }
    }

    #[test]
    fn status_shape() {
        for (role, name) in [
            (None, "none"),
            (Some(SenseRole::Host), "host"),
            (Some(SenseRole::Both), "both"),
            (Some(SenseRole::Controller), "controller"),
        ] {
            let value = status_value(false, role, None, "locked", None, None);
            assert_eq!(value["supported"], false);
            assert_eq!(value["role"], name);
            assert_eq!(value["stage"], "locked");
            assert!(value["perm_set"].is_null());
        }
        let access = AccessStatus {
            perm_set: true,
            changed_at: Some(1_700_000_000),
            ack: None,
        };
        let value = status_value(
            true,
            Some(SenseRole::Host),
            Some(&access),
            "unlocked",
            Some(5),
            Some("Ali".to_owned()),
        );
        assert_eq!(
            value,
            json!({"supported": true, "role": "host", "perm_set": true,
                "changed_at": 1_700_000_000, "stage": "unlocked", "until": 5, "user": "Ali"})
        );
    }

    #[test]
    fn stages_follow_the_flow() {
        let now = Instant::now();
        let mut state = UiState::default();
        assert_eq!(state.stage(now).0, "locked");
        state.request = Some("{}".to_owned());
        assert_eq!(state.stage(now).0, "verifying");
        let mut state = granted_state(now);
        assert_eq!(state.stage(now).0, "unlocked");
        // The lock closes by itself.
        assert_eq!(state.stage(now + Duration::from_secs(300)).0, "locked");
        assert!(state.grant.is_none());
    }

    #[test]
    fn begin_codes() {
        let never = |_: SensePasswordIpc| -> Option<SensePasswordIpc> { panic!("no IPC") };
        assert_eq!(begin_with(false, Some(SenseRole::Host), never), Err("unsupported"));
        assert_eq!(begin_with(true, Some(SenseRole::Controller), never), Err("not_incoming"));
        assert_eq!(begin_with(true, None, never), Err("not_incoming"));
        let reply = |r: Option<SensePasswordIpc>| {
            move |m: SensePasswordIpc| {
                assert_eq!(m, SensePasswordIpc::Begin);
                r
            }
        };
        assert_eq!(
            begin_with(true, Some(SenseRole::Both), reply(Some(SensePasswordIpc::Request(Ok("{}".into()))))),
            Ok("{}".to_owned())
        );
        for code in BEGIN_ERRORS {
            assert_eq!(
                begin_with(true, Some(SenseRole::Host), reply(Some(SensePasswordIpc::Request(Err(code.into()))))),
                Err(code)
            );
        }
        assert_eq!(
            begin_with(true, Some(SenseRole::Host), reply(Some(SensePasswordIpc::Request(Err("weird".into()))))),
            Err("ipc_failed")
        );
        assert_eq!(begin_with(true, Some(SenseRole::Host), reply(None)), Err("ipc_failed"));
    }

    #[test]
    fn login_status_maps_an_outdated_panel() {
        for detail in ["purpose_unsupported", "invalid_request"] {
            assert_eq!(
                login_status_value(json!({"state": "failed", "error": "failed", "detail": detail})),
                json!({"state": "failed", "error": "panel_outdated"})
            );
        }
        let waiting = json!({"state": "waiting", "url": "https://p/x", "pairing_code": "123456"});
        assert_eq!(login_status_value(waiting.clone()), waiting);
    }

    fn ok_body() -> String {
        json!({
            "grant": {"k": "94d01a580be13482", "p": "GRANT-MARKER", "s": "x"},
            "until": 1_800_000_300,
            "user": {"name": "ali@example.test", "display_name": "Ali"},
        })
        .to_string()
    }

    /// The fake panel: checks what is sent and answers `(status, body)`.
    fn fake_panel(
        status: u16,
        body: String,
    ) -> impl FnOnce(String, String, String) -> ResultType<(u16, String)> {
        move |url, sent, header| {
            assert!(url.ends_with("/api/sense/password-grant"), "{url}");
            assert_eq!(header, "Authorization: Bearer TOKEN-MARKER");
            let sent: Value = serde_json::from_str(&sent).unwrap();
            assert_eq!(
                sent,
                json!({"id": "123456789", "uuid": "dGVzdC11dWlk", "request": {"k": "r"}})
            );
            Ok((status, body))
        }
    }

    fn unlock_fake(status: u16, body: String) -> Result<GrantAnswer, &'static str> {
        unlock_with(
            Some("TOKEN-MARKER".to_owned()),
            Some(r#"{"k":"r"}"#.to_owned()),
            "123456789",
            "dGVzdC11dWlk",
            fake_panel(status, body),
        )
    }

    #[test]
    fn unlock_success() {
        let answer = unlock_fake(200, ok_body()).unwrap();
        assert_eq!(answer.until, 1_800_000_300);
        assert_eq!(answer.user.shown(), "Ali");
    }

    #[test]
    fn unlock_maps_every_panel_error() {
        let statuses = [401, 403, 409, 409, 400, 400, 409, 429, 503, 400];
        for (code, status) in GRANT_ERRORS.iter().zip(statuses) {
            let body = json!({"error": code}).to_string();
            assert_eq!(unlock_fake(status, body).err(), Some(*code));
        }
        // Without a known body: by HTTP status.
        for (status, code) in [
            (401, "token_invalid"),
            (403, "password_scope"),
            (429, "rate_limited"),
            (503, "signing_unavailable"),
            (500, "network"),
            (404, "panel_outdated"),
        ] {
            assert_eq!(unlock_fake(status, "<html>".to_owned()).err(), Some(code));
        }
        // A panel that does not know the purpose / route.
        for code in OUTDATED_PANEL_ERRORS {
            let body = json!({"error": code}).to_string();
            assert_eq!(unlock_fake(400, body).err(), Some("panel_outdated"));
        }
        // An answer that is not the contract.
        assert_eq!(unlock_fake(200, "{}".to_owned()).err(), Some("network"));
        let mut extra: Value = serde_json::from_str(&ok_body()).unwrap();
        extra["password"] = "x".into();
        assert_eq!(unlock_fake(200, extra.to_string()).err(), Some("network"));
    }

    #[test]
    fn unlock_without_network_token_or_request() {
        let down = |_: String, _: String, _: String| -> ResultType<(u16, String)> {
            Err(hbb_common::anyhow::anyhow!("connection refused"))
        };
        let never = |_: String, _: String, _: String| -> ResultType<(u16, String)> {
            panic!("no request")
        };
        assert_eq!(
            unlock_with(Some("t".into()), Some("{}".into()), "1", "u", down).err(),
            Some("network")
        );
        assert_eq!(unlock_with(None, Some("{}".into()), "1", "u", never).err(), Some("token_invalid"));
        assert_eq!(unlock_with(Some("t".into()), None, "1", "u", never).err(), Some("no_pending"));
    }

    #[test]
    fn unlock_answer_holds_the_grant_for_its_lifetime_at_most() {
        let now = Instant::now();
        let answer = unlock_fake(200, ok_body());
        let (text, held) = unlock_answer(answer, now, 1_800_000_000);
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value, json!({"ok": true, "until": 1_800_000_300, "user": "Ali"}));
        assert!(!text.contains("GRANT-MARKER") && !text.contains("TOKEN-MARKER"));
        let held = held.unwrap();
        assert!(held.grant.contains("GRANT-MARKER"));
        assert_eq!(held.deadline, now + Duration::from_secs(300));
        // A panel clock far ahead does not keep the lock open longer.
        let (_, held) = unlock_answer(unlock_fake(200, ok_body()), now, 0);
        assert_eq!(
            held.unwrap().deadline,
            now + Duration::from_secs(PASSWORD_GRANT_TTL_S as u64)
        );
        let (error, held) = unlock_answer(Err("replayed"), now, 0);
        assert_eq!(error, json!({"ok": false, "error": "replayed"}).to_string());
        assert!(held.is_none());
    }

    #[test]
    fn set_flow() {
        let now = Instant::now();
        let good = SensePasswordSecret::new("Mavi-Kapi_47!tuz".to_owned());
        let never = |_: SensePasswordIpc| -> Option<SensePasswordIpc> { panic!("no IPC") };
        let mut state = granted_state(now);
        assert_eq!(set_with(false, Some(SenseRole::Host), "1", &good, &mut state, now, never), "unsupported");
        assert_eq!(
            set_with(true, Some(SenseRole::Controller), "1", &good, &mut state, now, never),
            "not_incoming"
        );
        // Weak password: refused here, no IPC, the grant stays.
        let weak = SensePasswordSecret::new("aaaaaaaaaaaa".to_owned());
        assert_eq!(
            set_with(true, Some(SenseRole::Host), "1", &weak, &mut state, now, never),
            "weak_password:repeated"
        );
        assert!(state.grant.is_some());
        // Privileged process not reachable: the grant stays.
        assert_eq!(
            set_with(true, Some(SenseRole::Host), "1", &good, &mut state, now, |_| None),
            "ipc_failed"
        );
        assert!(state.grant.is_some());
        // Refused grant: dropped.
        let answer = |code: &str| {
            let code = code.to_owned();
            move |m: SensePasswordIpc| {
                let SensePasswordIpc::Set { grant, password } = m else {
                    panic!("not Set");
                };
                assert_eq!(grant, GRANT);
                assert_eq!(password.expose(), "Mavi-Kapi_47!tuz");
                Some(SensePasswordIpc::SetResult { code, storage: None, salt: None })
            }
        };
        assert_eq!(
            set_with(true, Some(SenseRole::Host), "1", &good, &mut state, now, answer("grant_invalid:expired")),
            "grant_invalid:expired"
        );
        assert!(state.grant.is_none());
        assert_eq!(
            set_with(true, Some(SenseRole::Host), "1", &good, &mut state, now, never),
            "no_pending"
        );
        // Success: the grant is used up.
        let mut state = granted_state(now);
        assert_eq!(set_with(true, Some(SenseRole::Both), "1", &good, &mut state, now, answer("")), "");
        assert!(state.grant.is_none());
        // Expired in the UI: not sent.
        let mut state = granted_state(now);
        assert_eq!(
            set_with(true, Some(SenseRole::Host), "1", &good, &mut state, now + Duration::from_secs(301), never),
            "no_pending"
        );
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
        let installed = log::set_logger(&CAPTURE).is_ok();
        log::set_max_level(log::LevelFilter::Trace);
        let now = Instant::now();
        let secret = SensePasswordSecret::new("Gizli-Kapi_47!PW".to_owned());
        // Every logged path: refused grant, network error, success, refused and accepted set.
        let _ = unlock_fake(409, json!({"error": "replayed"}).to_string());
        let _ = unlock_with(
            Some("TOKEN-MARKER".into()),
            Some(r#"{"k":"REQUEST-MARKER"}"#.into()),
            "1",
            "u",
            |_, _, _| Err(hbb_common::anyhow::anyhow!("down")),
        );
        let _ = unlock_answer(unlock_fake(200, ok_body()), now, 1_800_000_000);
        let mut state = granted_state(now);
        let _ = set_with(true, Some(SenseRole::Host), "1", &secret, &mut state, now, |_| {
            Some(SensePasswordIpc::SetResult { code: "nonce_mismatch".into(), storage: None, salt: None })
        });
        let mut state = granted_state(now);
        let _ = set_with(true, Some(SenseRole::Host), "1", &secret, &mut state, now, |_| {
            Some(SensePasswordIpc::SetResult { code: String::new(), storage: None, salt: None })
        });
        let lines = LINES.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if installed {
            assert!(lines.iter().any(|l| l.contains("password grant refused: replayed")), "{lines:?}");
            assert!(lines.iter().any(|l| l.contains("permanent password changed")), "{lines:?}");
        }
        for line in &lines {
            for marker in ["Gizli-Kapi", "TOKEN-MARKER", "GRANT-MARKER", "REQUEST-MARKER", "Bearer"] {
                assert!(!line.contains(marker), "{line}");
            }
        }
    }

    /// The Controller's saved app sign-in is not touched: this flow never writes `LocalConfig`
    /// and signs in with `remember_me = false`.
    #[test]
    fn app_sign_in_is_never_written() {
        let source = include_str!("ui.rs");
        let code = &source[..source.find("#[cfg(test)]").unwrap()];
        assert!(!code.contains("LocalConfig::"));
        assert!(code.contains("false, // remember_me"));
        assert!(code.contains("LoginPurpose::Password"));
        assert!(!code.contains("LoginPurpose::App"));
    }
}
