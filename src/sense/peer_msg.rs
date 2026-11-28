//! Sense Remote (Sürüm 12, plan 2026-11-28 §2.1): Sense messages between the two peers of a
//! connection, carried in `Misc.plugin_request` (`PluginRequest { id, content }`, the body is
//! JSON). One dispatcher per side: the Host's `connection.rs` and the Controller's `io_loop.rs`
//! send every `sense.*` request here (the older `sense.file-offer` arm stays where it is).
//!
//! Backward compatibility (both ways):
//! - an unknown `sense.*` name, an unknown body key or a body that does not parse is ignored
//!   (a newer peer may send more; an older peer never answers);
//! - an older peer ignores these names too (RustDesk drops plugin requests it does not know), so
//!   nothing here may wait for an answer forever.
//!
//! What a message may carry: flags, numbers, short codes and the shortcut id. Never screen,
//! keys, clipboard, chat, file names or command output (plan "Değişmez"). The admin terminal
//! ticket passes through here but never goes to the record or to Dart.
//!
//! Handlers are pure (context in, actions out) so they are tested here; the two RustDesk files
//! only apply the actions. A shortcut run is handed to `shortcuts::run_job` on its own thread
//! (FAV-Ç); its answer may carry a small result body (`res`, #171).
//!
//! Also here (ÇK): the Host's idle value sent to the Controller (`sense.idle`, [`idle_minutes`]),
//! the Host card's share of these messages on the CM side ([`cm_from_conn`]: card capture #151,
//! admin terminal #157) and the reconnect attempt the session bar shows ([`ffi_reconnect_info`]).

use base::message_proto::{Message, Misc, PluginRequest};
use hbb_common::log;
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};

/// Every Sense request id starts with this.
pub const PREFIX: &str = "sense.";

/// C → H `{on: bool}`: the Controller shows the Host card (#151).
pub const HOST_CHAT_VISIBLE: &str = "sense.host-chat-visible";
/// H → C `{min: u32 | null}`: the Host's `auto-disconnect-timeout` (#167).
pub const IDLE: &str = "sense.idle";
/// C → H `{req: u32, id: string, arg?: string}`: run one favourite shortcut. `arg` (FAV-Ç, #171):
/// only the ping address or the process id to close, checked again by the Host.
pub const SHORTCUT_RUN: &str = "sense.shortcut-run";
/// H → C `{req, ok, err?, res?}`; `res` (FAV-Ç, #171) is the optional result body: ping counts,
/// window list or IP card (`shortcuts::results`).
pub const SHORTCUT_RESULT: &str = "sense.shortcut-result";
/// C → H `{ticket}` on a terminal connection, before `TerminalAction::Open`.
pub const TERM_ADMIN: &str = "sense.term-admin";
/// H → C `{ok, err?}`.
pub const TERM_ADMIN_RESULT: &str = "sense.term-admin-result";

/// Names the Flutter bridge may send (`session_sense_send_msg`); anything else is refused there.
pub const UI_SENDABLE: [&str; 2] = [HOST_CHAT_VISIBLE, SHORTCUT_RUN];

/// Flutter session events (plan §2.4).
pub const EV_SHORTCUT_RESULT: &str = "sense_shortcut_result";
pub const EV_TERM_ADMIN_RESULT: &str = "sense_term_admin_result";
pub const EV_IDLE_POLICY: &str = "sense_idle_policy";

/// Bridge answer while a body is not filled in yet (or the peer is older).
pub const UNSUPPORTED_JSON: &str = r#"{"error":"unsupported"}"#;

/// CM channel key (`ipc::Data::Config`), value `Y`/`N`: `Y` = the Controller asked to see the Host
/// card (#151), so the card leaves its capture exclusion for that connection. The connection
/// always sends `N` when it ends.
pub const CM_CAPTURE: &str = "sense-cm-capture";

/// Largest body taken or sent (the ticket is at most 2048 characters).
pub const MAX_BODY: usize = 4096;
const MAX_ID: usize = 64;
const MAX_CODE: usize = 32;

/// One known Sense message.
#[derive(Debug, Clone, PartialEq)]
pub enum PeerMsg {
    HostChatVisible { on: bool },
    Idle { min: Option<u32> },
    ShortcutRun { req: u32, id: String, arg: Option<String> },
    ShortcutResult { req: u32, ok: bool, err: Option<String>, res: Option<Value> },
    TermAdmin { ticket: String },
    TermAdminResult { ok: bool, err: Option<String> },
}

/// What a plugin request is, as far as this module is concerned.
#[derive(Debug, Clone, PartialEq)]
pub enum Parsed {
    /// Not a `sense.*` id: not ours.
    NotSense,
    /// A `sense.*` id this version does not know (or handles elsewhere): ignored.
    Unknown,
    /// A known name whose body is not valid: ignored and logged.
    Bad,
    Msg(PeerMsg),
}

// Bodies: unknown keys are allowed (a newer peer may add some).
#[derive(Deserialize, Serialize)]
struct OnBody {
    on: bool,
}
#[derive(Deserialize, Serialize)]
struct IdleBody {
    min: Option<u32>,
}
#[derive(Deserialize, Serialize)]
struct RunBody {
    req: u32,
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    arg: Option<String>,
}
#[derive(Deserialize, Serialize)]
struct RunResultBody {
    req: u32,
    ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    err: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    res: Option<Value>,
}
#[derive(Deserialize, Serialize)]
struct TicketBody {
    ticket: String,
}
#[derive(Deserialize, Serialize)]
struct ResultBody {
    ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    err: Option<String>,
}

pub fn is_sense(id: &str) -> bool {
    id.starts_with(PREFIX)
}

/// A shortcut id: catalogue ids (`win.taskmgr`) and approved custom ones (`custom:<uuid>`).
fn valid_shortcut_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b':'))
}

/// The shortcut argument (FAV-Ç): absent, or a plain name / number (`shortcuts::results`).
fn valid_arg(arg: &Option<String>) -> bool {
    arg.as_deref()
        .map_or(true, |a| super::shortcuts::results::arg_problem(a).is_none())
}

/// The result body (FAV-Ç, #171): absent, or an object that stays small.
fn valid_res(res: &Option<Value>) -> bool {
    res.as_ref().map_or(true, |r| {
        r.is_object() && r.to_string().len() <= super::shortcuts::results::MAX_RES_BYTES
    })
}

/// An error code: `unknown_id`, `bad_sig` … A newer peer may send codes this version does not
/// know; they pass through as long as they look like a code.
fn valid_code(code: &Option<String>) -> bool {
    code.as_deref().map_or(true, |c| {
        !c.is_empty() && c.len() <= MAX_CODE && c.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
    })
}

fn body<T: serde::de::DeserializeOwned>(content: &[u8]) -> Option<T> {
    if content.len() > MAX_BODY {
        return None;
    }
    let value: Value = serde_json::from_slice(content).ok()?;
    if !value.is_object() {
        return None;
    }
    serde_json::from_value(value).ok()
}

/// Reads one plugin request (pure).
pub fn parse(id: &str, content: &[u8]) -> Parsed {
    if !is_sense(id) {
        return Parsed::NotSense;
    }
    let msg = match id {
        HOST_CHAT_VISIBLE => body::<OnBody>(content).map(|b| PeerMsg::HostChatVisible { on: b.on }),
        IDLE => body::<IdleBody>(content).map(|b| PeerMsg::Idle { min: b.min }),
        SHORTCUT_RUN => body::<RunBody>(content)
            .filter(|b| valid_shortcut_id(&b.id) && valid_arg(&b.arg))
            .map(|b| PeerMsg::ShortcutRun {
                req: b.req,
                id: b.id,
                arg: b.arg,
            }),
        SHORTCUT_RESULT => body::<RunResultBody>(content)
            .filter(|b| valid_code(&b.err) && valid_res(&b.res))
            .map(|b| PeerMsg::ShortcutResult {
                req: b.req,
                ok: b.ok,
                err: b.err,
                res: b.res,
            }),
        TERM_ADMIN => body::<TicketBody>(content)
            .filter(|b| !b.ticket.is_empty() && b.ticket.len() <= 2048)
            .map(|b| PeerMsg::TermAdmin { ticket: b.ticket }),
        TERM_ADMIN_RESULT => body::<ResultBody>(content)
            .filter(|b| valid_code(&b.err))
            .map(|b| PeerMsg::TermAdminResult { ok: b.ok, err: b.err }),
        _ => return Parsed::Unknown,
    };
    match msg {
        Some(m) => Parsed::Msg(m),
        None => Parsed::Bad,
    }
}

impl PeerMsg {
    pub fn name(&self) -> &'static str {
        match self {
            PeerMsg::HostChatVisible { .. } => HOST_CHAT_VISIBLE,
            PeerMsg::Idle { .. } => IDLE,
            PeerMsg::ShortcutRun { .. } => SHORTCUT_RUN,
            PeerMsg::ShortcutResult { .. } => SHORTCUT_RESULT,
            PeerMsg::TermAdmin { .. } => TERM_ADMIN,
            PeerMsg::TermAdminResult { .. } => TERM_ADMIN_RESULT,
        }
    }

    pub fn body(&self) -> Value {
        let v = match self {
            PeerMsg::HostChatVisible { on } => serde_json::to_value(OnBody { on: *on }),
            PeerMsg::Idle { min } => serde_json::to_value(IdleBody { min: *min }),
            PeerMsg::ShortcutRun { req, id, arg } => serde_json::to_value(RunBody {
                req: *req,
                id: id.clone(),
                arg: arg.clone(),
            }),
            PeerMsg::ShortcutResult { req, ok, err, res } => serde_json::to_value(RunResultBody {
                req: *req,
                ok: *ok,
                err: err.clone(),
                res: res.clone(),
            }),
            PeerMsg::TermAdmin { ticket } => serde_json::to_value(TicketBody {
                ticket: ticket.clone(),
            }),
            PeerMsg::TermAdminResult { ok, err } => serde_json::to_value(ResultBody {
                ok: *ok,
                err: err.clone(),
            }),
        };
        v.unwrap_or(Value::Null)
    }

    pub fn to_message(&self) -> Message {
        let mut misc = Misc::new();
        misc.set_plugin_request(PluginRequest {
            id: self.name().to_owned(),
            content: self.body().to_string().into_bytes().into(),
            ..Default::default()
        });
        let mut msg = Message::new();
        msg.set_misc(misc);
        msg
    }
}

/// A message the Flutter UI asks to send (`session_sense_send_msg`): only names in
/// [`UI_SENDABLE`], with a valid body. `Err` is the bridge answer: `not_allowed` | `invalid`.
pub fn outgoing(name: &str, json: &str) -> Result<Message, &'static str> {
    if !UI_SENDABLE.contains(&name) {
        return Err("not_allowed");
    }
    match parse(name, json.as_bytes()) {
        Parsed::Msg(m) => Ok(m.to_message()),
        _ => Err("invalid"),
    }
}

// ---------------------------------------------------------------------------------------------
// Host (`src/server/connection.rs`)
// ---------------------------------------------------------------------------------------------

/// What the Host connection knows when a message comes in.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostCtx {
    /// A screen connection (`Connection::is_remote`).
    pub remote: bool,
    /// A terminal connection.
    pub terminal: bool,
    /// The connection may type (keyboard permission on, not "only watch").
    pub keyboard: bool,
    /// The admin terminal can run here: Windows, installed service, no terminal opened yet on
    /// this connection.
    pub term_admin_capable: bool,
    /// Local `enable-terminal` is on.
    pub terminal_enabled: bool,
}

/// What the Host connection does with a message, in order.
#[derive(Debug, Clone, PartialEq)]
pub enum HostAction {
    /// Answer the Controller over the same connection.
    Reply(PeerMsg),
    /// Tell the CM `sense-cm-capture` Y (true) / N (false) for this connection.
    CmCapture(bool),
    /// Run a shortcut off the connection loop (FAV-Ç: ping and the window list take seconds);
    /// the connection sends `shortcuts::run_job`'s answer when it is ready.
    RunShortcut(super::shortcuts::Job),
    /// The ticket was accepted: the connection's terminal runs with the service's rights and the
    /// CM shows "Yönetici terminali açık · `by`". Comes before the reply, so the terminal the
    /// Controller opens after the answer is already the admin one.
    TermAdminGranted { by: String },
}

/// Host dispatcher (pure apart from the event record).
pub fn on_host(ctx: &HostCtx, p: &PluginRequest) -> Vec<HostAction> {
    match parse(&p.id, &p.content) {
        Parsed::Msg(m) => host_msg(ctx, m),
        Parsed::Bad => {
            log::warn!("Sense Remote: ignored malformed peer message {}", p.id);
            Vec::new()
        }
        Parsed::NotSense | Parsed::Unknown => Vec::new(),
    }
}

fn host_msg(ctx: &HostCtx, m: PeerMsg) -> Vec<HostAction> {
    match m {
        // #151: only a screen connection can see the card; the connection sets it back to N
        // when it ends.
        PeerMsg::HostChatVisible { on } if ctx.remote => vec![HostAction::CmCapture(on)],
        PeerMsg::HostChatVisible { .. } => Vec::new(),
        PeerMsg::ShortcutRun { req, id, arg } => {
            if !ctx.remote || !ctx.keyboard {
                let err = super::shortcuts::RunError::NoPermission.code();
                super::diag::kinds::shortcut_run(&id, false, Some(err));
                return vec![HostAction::Reply(PeerMsg::ShortcutResult {
                    req,
                    ok: false,
                    err: Some(err.to_owned()),
                    res: None,
                })];
            }
            // FAV-Ç: the runner answers (and records) from its own thread.
            vec![HostAction::RunShortcut(super::shortcuts::Job { req, id, arg })]
        }
        PeerMsg::TermAdmin { ticket } => {
            let result = if ctx.terminal {
                super::term_admin::check_ticket(
                    &ticket,
                    ctx.term_admin_capable,
                    ctx.terminal_enabled,
                )
            } else {
                Err(super::term_admin::Refusal::Unsupported)
            };
            term_admin_actions(result)
        }
        // Messages for the Controller arriving at a Host: ignored.
        PeerMsg::Idle { .. } | PeerMsg::ShortcutResult { .. } | PeerMsg::TermAdminResult { .. } => {
            Vec::new()
        }
    }
}

/// The Host's actions for a checked ticket (the record gets only the code, never the ticket).
fn term_admin_actions(
    result: Result<super::term_admin::Grant, super::term_admin::Refusal>,
) -> Vec<HostAction> {
    match result {
        Ok(grant) => {
            super::diag::kinds::term_admin(true, None);
            log::info!("Sense Remote: admin terminal ticket accepted");
            vec![
                HostAction::TermAdminGranted {
                    by: super::term_admin::card_name(&grant.email),
                },
                HostAction::Reply(PeerMsg::TermAdminResult { ok: true, err: None }),
            ]
        }
        Err(refusal) => {
            super::diag::kinds::term_admin(false, Some(refusal.code()));
            vec![HostAction::Reply(PeerMsg::TermAdminResult {
                ok: false,
                err: Some(refusal.code().to_owned()),
            })]
        }
    }
}

/// The Host's idle disconnect as `connection.rs` applies it (`get_auto_disconenct_timer`):
/// minutes when `allow-auto-disconnect` is `Y` (0 or unreadable = 10), otherwise none.
pub fn idle_minutes(allow: &str, timeout: &str) -> Option<u32> {
    if allow != "Y" {
        return None;
    }
    match timeout.trim().parse::<u64>() {
        Ok(0) | Err(_) => Some(10),
        Ok(m) => Some(m.min(u32::MAX as u64) as u32),
    }
}

/// Host connection: what to send to the Controller now. `last` is what was sent (outer `None` =
/// nothing yet); the first call sends, later calls only on a change.
pub fn idle_update(last: &mut Option<Option<u32>>, now: Option<u32>) -> Option<PeerMsg> {
    if *last == Some(now) {
        return None;
    }
    *last = Some(now);
    Some(PeerMsg::Idle { min: now })
}

// ---------------------------------------------------------------------------------------------
// CM side of the Host (`src/ui_cm_interface.rs`, the Host card's process)
// ---------------------------------------------------------------------------------------------

#[derive(Default)]
struct CmState {
    /// Connections whose Controller asked to see the card.
    capture: Vec<i32>,
    /// Connections whose terminal runs as admin, with the employee's e-mail.
    admin: Vec<(i32, String)>,
}

fn cm_state() -> &'static Mutex<CmState> {
    static STATE: OnceLock<Mutex<CmState>> = OnceLock::new();
    STATE.get_or_init(Default::default)
}

/// Connections remembered at most per list (a CM has a handful).
const CM_KEEP: usize = 64;

/// A message of connection `conn_id` on the CM channel. True when it was one of ours.
pub fn cm_from_conn(conn_id: i32, name: &str, value: Option<&str>) -> bool {
    let mut state = cm_state().lock().unwrap_or_else(|e| e.into_inner());
    match name {
        CM_CAPTURE => {
            state.capture.retain(|id| *id != conn_id);
            if value == Some("Y") && state.capture.len() < CM_KEEP {
                state.capture.push(conn_id);
            }
            true
        }
        super::term_admin::CM_KEY => {
            state.admin.retain(|(id, _)| *id != conn_id);
            if let Some(by) = value.filter(|v| !v.is_empty()) {
                if state.admin.len() < CM_KEEP {
                    state
                        .admin
                        .push((conn_id, super::term_admin::card_name(by)));
                }
            }
            true
        }
        _ => false,
    }
}

/// `main_sense_host_peer_state`: `{"chat_visible": [conn_id], "admin_terminals": [{conn_id, by}]}`
/// for the connections in `live` (one that went away without its `N` drops out).
pub fn ffi_host_peer_state(live: &[i32]) -> String {
    let mut state = cm_state().lock().unwrap_or_else(|e| e.into_inner());
    state.capture.retain(|id| live.contains(id));
    state.admin.retain(|(id, _)| live.contains(id));
    let admin: Vec<Value> = state
        .admin
        .iter()
        .map(|(id, by)| json!({ "conn_id": id, "by": by }))
        .collect();
    json!({ "chat_visible": state.capture, "admin_terminals": admin }).to_string()
}

// ---------------------------------------------------------------------------------------------
// Controller (`src/client/io_loop.rs`)
// ---------------------------------------------------------------------------------------------

/// A Flutter session event: name and fields (`push_event` adds `name`).
#[derive(Debug, Clone, PartialEq)]
pub struct UiEvent {
    pub name: &'static str,
    pub fields: Vec<(&'static str, Value)>,
}

/// The Host's idle policy per Controller session (`LoginConfigHandler::session_id`), as the Host
/// last sent it. Absent = the Host has not sent one (older Host).
fn idle_policies() -> &'static Mutex<HashMap<u64, Option<u32>>> {
    static IDLE_POLICIES: OnceLock<Mutex<HashMap<u64, Option<u32>>>> = OnceLock::new();
    IDLE_POLICIES.get_or_init(Default::default)
}

/// Sessions remembered at most; older entries are dropped all at once (a few bytes each).
const MAX_SESSIONS: usize = 256;

fn remember_idle(sid: u64, min: Option<u32>) {
    let mut map = idle_policies().lock().unwrap_or_else(|e| e.into_inner());
    if map.len() >= MAX_SESSIONS && !map.contains_key(&sid) {
        map.clear();
    }
    map.insert(sid, min);
}

/// What the Host last said about its idle disconnect: `Some(None)` = no limit.
pub fn idle_policy(sid: u64) -> Option<Option<u32>> {
    idle_policies()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&sid)
        .copied()
}

/// The session ended: forget what it was told (`session_close`).
pub fn forget(sid: u64) {
    idle_policies()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&sid);
    reconnect_marks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&sid);
    super::term_admin::forget(sid);
}

/// Per session: the session's reconnect counter when it last logged in.
fn reconnect_marks() -> &'static Mutex<HashMap<u64, usize>> {
    static MARKS: OnceLock<Mutex<HashMap<u64, usize>>> = OnceLock::new();
    MARKS.get_or_init(Default::default)
}

/// The session logged in (`io_loop`, PeerInfo): attempts count from here.
pub fn mark_connected(sid: u64, reconnect_count: usize) {
    let mut map = reconnect_marks().lock().unwrap_or_else(|e| e.into_inner());
    if map.len() >= MAX_SESSIONS && !map.contains_key(&sid) {
        map.clear();
    }
    map.insert(sid, reconnect_count);
}

/// Reconnect attempts since the last login (pure): every reconnect, automatic or from the UI,
/// goes through `Session::reconnect`, which counts. `max` is `null`: the retries have no limit
/// (the UI decides when to stop).
pub fn reconnect_info(mark: Option<usize>, reconnect_count: usize) -> Value {
    let attempt = reconnect_count.saturating_sub(mark.unwrap_or(0));
    json!({ "attempt": attempt, "max": null })
}

/// `session_sense_reconnect_info`: `{attempt, max}`, or `unsupported` without a session.
pub fn ffi_reconnect_info(sid: Option<u64>, reconnect_count: usize) -> String {
    let Some(sid) = sid else {
        return UNSUPPORTED_JSON.to_owned();
    };
    let mark = reconnect_marks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&sid)
        .copied();
    reconnect_info(mark, reconnect_count).to_string()
}

/// `session_sense_idle_policy`: `{"min": n | null}`, or [`UNSUPPORTED_JSON`] while the Host has
/// not sent one (older Host; the UI keeps its own default then).
pub fn ffi_idle_policy(sid: Option<u64>) -> String {
    match sid.and_then(idle_policy) {
        Some(min) => json!({ "min": min }).to_string(),
        None => UNSUPPORTED_JSON.to_owned(),
    }
}

/// Controller dispatcher: the event for the UI, if any.
pub fn on_controller(sid: u64, p: &PluginRequest) -> Option<UiEvent> {
    match parse(&p.id, &p.content) {
        Parsed::Msg(m) => controller_msg(sid, m),
        Parsed::Bad => {
            log::warn!("Sense Remote: ignored malformed peer message {}", p.id);
            None
        }
        Parsed::NotSense | Parsed::Unknown => None,
    }
}

fn controller_msg(sid: u64, m: PeerMsg) -> Option<UiEvent> {
    match m {
        PeerMsg::Idle { min } => {
            remember_idle(sid, min);
            Some(UiEvent {
                name: EV_IDLE_POLICY,
                fields: vec![("min", json!(min))],
            })
        }
        PeerMsg::ShortcutResult { req, ok, err, res } => Some(UiEvent {
            name: EV_SHORTCUT_RESULT,
            fields: vec![
                ("req", json!(req)),
                ("ok", json!(ok)),
                ("err", json!(err)),
                ("res", res.unwrap_or(Value::Null)),
            ],
        }),
        // Only an answer this session waits for (a late one, after the timeout, is dropped).
        PeerMsg::TermAdminResult { ok, err } if super::term_admin::take_pending(sid) => {
            Some(UiEvent {
                name: EV_TERM_ADMIN_RESULT,
                fields: vec![("ok", json!(ok)), ("err", json!(err))],
            })
        }
        PeerMsg::TermAdminResult { .. } => None,
        // Messages for the Host arriving at a Controller: ignored.
        PeerMsg::HostChatVisible { .. } | PeerMsg::ShortcutRun { .. } | PeerMsg::TermAdmin { .. } => None,
    }
}

/// Sends the event to the Flutter session(s) of this connection.
#[cfg(feature = "flutter")]
pub fn push_to_ui(sid: u64, ev: &UiEvent) {
    for s in crate::flutter::sessions::get_sessions() {
        if s.lc.read().unwrap().session_id == sid {
            s.push_event(ev.name, &ev.fields, &[]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(id: &str, body: &str) -> PluginRequest {
        PluginRequest {
            id: id.to_owned(),
            content: body.as_bytes().to_vec().into(),
            ..Default::default()
        }
    }

    const SCREEN: HostCtx = HostCtx {
        remote: true,
        terminal: false,
        keyboard: true,
        term_admin_capable: false,
        terminal_enabled: false,
    };

    const TERM: HostCtx = HostCtx {
        remote: false,
        terminal: true,
        keyboard: false,
        term_admin_capable: true,
        terminal_enabled: true,
    };

    fn reply(actions: Vec<HostAction>) -> PeerMsg {
        assert_eq!(actions.len(), 1, "{actions:?}");
        match actions.into_iter().next().unwrap() {
            HostAction::Reply(m) => m,
            other => panic!("not a reply: {other:?}"),
        }
    }

    #[test]
    fn not_sense_and_unknown_sense_names_are_ignored() {
        assert_eq!(parse("plugin.x", b"{}"), Parsed::NotSense);
        assert_eq!(parse("sense.something-new", br#"{"a":1}"#), Parsed::Unknown);
        // The older arm keeps its own id; the dispatcher leaves it alone.
        assert_eq!(parse(crate::sense::chat_file::OFFER_REQUEST, b"{}"), Parsed::Unknown);
        for id in ["plugin.x", "sense.something-new", "sense.file-offer"] {
            assert!(on_host(&SCREEN, &req(id, "{}")).is_empty(), "{id}");
            assert!(on_controller(1, &req(id, "{}")).is_none(), "{id}");
        }
    }

    #[test]
    fn bad_bodies_are_ignored() {
        for (id, body) in [
            (HOST_CHAT_VISIBLE, "not json"),
            (HOST_CHAT_VISIBLE, "[true]"),
            (HOST_CHAT_VISIBLE, r#"{"on":"yes"}"#),
            (SHORTCUT_RUN, r#"{"req":1}"#),
            (SHORTCUT_RUN, r#"{"req":-1,"id":"win.taskmgr"}"#),
            (SHORTCUT_RUN, r#"{"req":1,"id":"cmd /c del x"}"#),
            (SHORTCUT_RUN, r#"{"req":1,"id":""}"#),
            (SHORTCUT_RESULT, r#"{"req":1,"ok":false,"err":"Not A Code"}"#),
            (TERM_ADMIN, r#"{"ticket":""}"#),
            (IDLE, r#"{"min":-5}"#),
        ] {
            assert_eq!(parse(id, body.as_bytes()), Parsed::Bad, "{id} {body}");
            assert!(on_host(&SCREEN, &req(id, body)).is_empty(), "{id} {body}");
            assert!(on_controller(1, &req(id, body)).is_none(), "{id} {body}");
        }
        let long = format!(r#"{{"on":true,"pad":"{}"}}"#, "x".repeat(MAX_BODY));
        assert_eq!(parse(HOST_CHAT_VISIBLE, long.as_bytes()), Parsed::Bad);
    }

    #[test]
    fn unknown_body_keys_from_a_newer_peer_are_ignored() {
        assert_eq!(
            parse(SHORTCUT_RUN, br#"{"req":7,"id":"win.taskmgr","later":{"x":1}}"#),
            Parsed::Msg(PeerMsg::ShortcutRun {
                req: 7,
                id: "win.taskmgr".to_owned(),
                arg: None,
            })
        );
        assert_eq!(
            parse(SHORTCUT_RESULT, br#"{"req":7,"ok":false,"err":"some_new_code"}"#),
            Parsed::Msg(PeerMsg::ShortcutResult {
                req: 7,
                ok: false,
                err: Some("some_new_code".to_owned()),
                res: None,
            })
        );
    }

    #[test]
    fn every_message_round_trips() {
        let all = [
            PeerMsg::HostChatVisible { on: true },
            PeerMsg::Idle { min: Some(30) },
            PeerMsg::Idle { min: None },
            PeerMsg::ShortcutRun {
                req: 3,
                id: "custom:0b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b".to_owned(),
                arg: None,
            },
            PeerMsg::ShortcutRun {
                req: 5,
                id: "win.ping".to_owned(),
                arg: Some("8.8.8.8".to_owned()),
            },
            PeerMsg::ShortcutResult {
                req: 3,
                ok: true,
                err: None,
                res: None,
            },
            PeerMsg::ShortcutResult {
                req: 4,
                ok: false,
                err: Some("needs_admin".to_owned()),
                res: None,
            },
            PeerMsg::ShortcutResult {
                req: 5,
                ok: true,
                err: None,
                res: Some(json!({"ping": {"sent": 4, "received": 4, "avg_ms": 18, "loss": 0}})),
            },
            PeerMsg::TermAdmin {
                ticket: "e30.e30.sig".to_owned(),
            },
            PeerMsg::TermAdminResult {
                ok: false,
                err: Some("expired".to_owned()),
            },
        ];
        for m in all {
            let msg = m.to_message();
            let p = msg.misc().plugin_request();
            assert_eq!(p.id, m.name());
            assert_eq!(parse(&p.id, &p.content), Parsed::Msg(m.clone()), "{m:?}");
        }
        // `err` is left out when there is none (as the contract writes it).
        let ok = PeerMsg::ShortcutResult {
            req: 1,
            ok: true,
            err: None,
            res: None,
        };
        assert_eq!(ok.body(), json!({"req": 1, "ok": true}));
        let run = PeerMsg::ShortcutRun {
            req: 1,
            id: "win.taskmgr".to_owned(),
            arg: None,
        };
        assert_eq!(run.body(), json!({"req": 1, "id": "win.taskmgr"}));
        assert_eq!(PeerMsg::Idle { min: None }.body(), json!({"min": null}));
    }

    #[test]
    fn the_ui_may_send_only_the_allowed_names() {
        assert!(outgoing(HOST_CHAT_VISIBLE, r#"{"on":true}"#).is_ok());
        assert!(outgoing(SHORTCUT_RUN, r#"{"req":1,"id":"win.taskmgr"}"#).is_ok());
        for name in [
            TERM_ADMIN,
            TERM_ADMIN_RESULT,
            SHORTCUT_RESULT,
            IDLE,
            "sense.file-offer",
            "sense.anything",
            "plugin.x",
            "",
        ] {
            assert_eq!(outgoing(name, r#"{"on":true}"#).err(), Some("not_allowed"), "{name}");
        }
        assert_eq!(outgoing(SHORTCUT_RUN, "{}").err(), Some("invalid"));
        assert_eq!(outgoing(HOST_CHAT_VISIBLE, "nope").err(), Some("invalid"));
        let m = outgoing(SHORTCUT_RUN, r#"{"req":9,"id":"mac.activity"}"#).unwrap();
        assert_eq!(m.misc().plugin_request().id, SHORTCUT_RUN);
    }

    #[test]
    fn shortcut_run_answers_and_needs_typing_permission() {
        let run = req(SHORTCUT_RUN, r#"{"req":5,"id":"win.taskmgr"}"#);
        for ctx in [
            HostCtx {
                keyboard: false,
                ..SCREEN
            },
            HostCtx {
                keyboard: true,
                ..TERM
            },
        ] {
            assert_eq!(
                reply(on_host(&ctx, &run)),
                PeerMsg::ShortcutResult {
                    req: 5,
                    ok: false,
                    err: Some("no_permission".to_owned()),
                    res: None,
                }
            );
        }
        // FAV-Ç: a connection that may type hands the run to the runner's thread.
        assert_eq!(
            on_host(&SCREEN, &req(SHORTCUT_RUN, r#"{"req":5,"id":"win.ping","arg":"8.8.8.8"}"#)),
            vec![HostAction::RunShortcut(crate::sense::shortcuts::Job {
                req: 5,
                id: "win.ping".to_owned(),
                arg: Some("8.8.8.8".to_owned()),
            })]
        );
    }

    #[test]
    fn shortcut_arguments_and_result_bodies_are_checked() {
        for body in [
            r#"{"req":1,"id":"win.ping","arg":"-t"}"#,
            r#"{"req":1,"id":"win.ping","arg":"8.8.8.8 & calc"}"#,
            r#"{"req":1,"id":"win.ping","arg":""}"#,
            r#"{"req":1,"id":"win.ping","arg":5}"#,
        ] {
            assert_eq!(parse(SHORTCUT_RUN, body.as_bytes()), Parsed::Bad, "{body}");
        }
        for body in [
            r#"{"req":1,"ok":true,"res":[1]}"#,
            r#"{"req":1,"ok":true,"res":"text"}"#,
        ] {
            assert_eq!(parse(SHORTCUT_RESULT, body.as_bytes()), Parsed::Bad, "{body}");
        }
        let big = format!(r#"{{"req":1,"ok":true,"res":{{"windows":"{}"}}}}"#, "x".repeat(3100));
        assert_eq!(parse(SHORTCUT_RESULT, big.as_bytes()), Parsed::Bad);
        // An older Host answers without `res`; the event then carries null.
        let ev = on_controller(12, &req(SHORTCUT_RESULT, r#"{"req":2,"ok":true}"#)).unwrap();
        assert_eq!(ev.fields.last(), Some(&("res", Value::Null)));
        let ev = on_controller(
            12,
            &req(SHORTCUT_RESULT, r#"{"req":3,"ok":true,"res":{"ip":{"ip":"192.168.10.42","gateway":[],"dns":[]}}}"#),
        )
        .unwrap();
        assert_eq!(ev.fields.last().unwrap().1["ip"]["ip"], "192.168.10.42");
    }

    #[test]
    fn term_admin_answers_and_records_no_ticket() {
        crate::sense::diag::sink::take();
        let ticket = req(TERM_ADMIN, r#"{"ticket":"aaa.bbb.ccc"}"#);
        let not_here = HostCtx {
            term_admin_capable: false,
            ..TERM
        };
        // A screen connection, or a Host where it cannot run (Mac, portable, terminal open).
        for ctx in [not_here, SCREEN] {
            assert_eq!(
                reply(on_host(&ctx, &ticket)),
                PeerMsg::TermAdminResult {
                    ok: false,
                    err: Some("unsupported".to_owned())
                }
            );
        }
        let policy = HostCtx {
            terminal_enabled: false,
            ..TERM
        };
        assert_eq!(
            reply(on_host(&policy, &ticket)),
            PeerMsg::TermAdminResult {
                ok: false,
                err: Some("policy_off".to_owned())
            }
        );
        // The signature checks themselves: `term_admin` tests (shared vector).
        let got = crate::sense::diag::sink::take();
        assert_eq!(got.len(), 3);
        assert!(got.iter().all(|(c, k)| c == "term" && k == "admin"));
    }

    #[test]
    fn an_accepted_ticket_switches_the_terminal_before_the_answer() {
        let grant = crate::sense::term_admin::Grant {
            uid: "usr_1".to_owned(),
            email: "calisan@example.test\n".to_owned(),
            nonce: "AAAAAAAAAAAAAAAAAAAAAA".to_owned(),
        };
        assert_eq!(
            term_admin_actions(Ok(grant)),
            vec![
                HostAction::TermAdminGranted {
                    by: "calisan@example.test".to_owned()
                },
                HostAction::Reply(PeerMsg::TermAdminResult { ok: true, err: None }),
            ]
        );
    }

    #[test]
    fn host_ignores_controller_messages() {
        for (id, body) in [
            (IDLE, r#"{"min":30}"#),
            (SHORTCUT_RESULT, r#"{"req":1,"ok":true}"#),
            (TERM_ADMIN_RESULT, r#"{"ok":true}"#),
        ] {
            assert!(on_host(&SCREEN, &req(id, body)).is_empty(), "{id}");
        }
    }

    #[test]
    fn chat_visible_tells_the_cm_only_for_a_screen_connection() {
        assert_eq!(
            on_host(&SCREEN, &req(HOST_CHAT_VISIBLE, r#"{"on":true}"#)),
            vec![HostAction::CmCapture(true)]
        );
        assert_eq!(
            on_host(&SCREEN, &req(HOST_CHAT_VISIBLE, r#"{"on":false}"#)),
            vec![HostAction::CmCapture(false)]
        );
        assert!(on_host(&TERM, &req(HOST_CHAT_VISIBLE, r#"{"on":true}"#)).is_empty());
    }

    #[test]
    fn cm_keeps_the_card_state_per_live_connection() {
        let (a, b) = (9_101, 9_102);
        assert!(cm_from_conn(a, CM_CAPTURE, Some("Y")));
        assert!(cm_from_conn(b, CM_CAPTURE, Some("Y")));
        assert!(cm_from_conn(b, crate::sense::term_admin::CM_KEY, Some("ben@example.test")));
        assert!(!cm_from_conn(a, "audio-input", Some("x")));
        let v: Value = serde_json::from_str(&ffi_host_peer_state(&[a, b])).unwrap();
        assert_eq!(v["chat_visible"], json!([a, b]));
        assert_eq!(v["admin_terminals"], json!([{ "conn_id": b, "by": "ben@example.test" }]));
        // One connection ended with its N; the other went away without a word.
        cm_from_conn(a, CM_CAPTURE, Some("N"));
        let v: Value = serde_json::from_str(&ffi_host_peer_state(&[a])).unwrap();
        assert_eq!(v["chat_visible"], json!([]));
        assert_eq!(v["admin_terminals"], json!([]));
    }

    #[test]
    fn idle_value_follows_the_host_setting_and_is_sent_on_change() {
        assert_eq!(idle_minutes("N", "30"), None);
        assert_eq!(idle_minutes("", "30"), None);
        assert_eq!(idle_minutes("Y", "30"), Some(30));
        assert_eq!(idle_minutes("Y", "0"), Some(10));
        assert_eq!(idle_minutes("Y", ""), Some(10));
        assert_eq!(idle_minutes("Y", "abc"), Some(10));
        let mut last = None;
        assert_eq!(idle_update(&mut last, Some(30)), Some(PeerMsg::Idle { min: Some(30) }));
        assert_eq!(idle_update(&mut last, Some(30)), None);
        assert_eq!(idle_update(&mut last, None), Some(PeerMsg::Idle { min: None }));
        assert_eq!(idle_update(&mut last, None), None);
        // The first value is sent even when it is "no limit".
        let mut fresh = None;
        assert_eq!(idle_update(&mut fresh, None), Some(PeerMsg::Idle { min: None }));
    }

    #[test]
    fn reconnect_attempts_count_from_the_last_login() {
        assert_eq!(reconnect_info(None, 0), json!({"attempt": 0, "max": null}));
        assert_eq!(reconnect_info(Some(2), 5), json!({"attempt": 3, "max": null}));
        assert_eq!(reconnect_info(Some(5), 5), json!({"attempt": 0, "max": null}));
        let sid = 0xC0FFEE_u64;
        forget(sid);
        assert_eq!(ffi_reconnect_info(None, 3), UNSUPPORTED_JSON);
        assert_eq!(ffi_reconnect_info(Some(sid), 2), r#"{"attempt":2,"max":null}"#);
        mark_connected(sid, 2);
        assert_eq!(ffi_reconnect_info(Some(sid), 2), r#"{"attempt":0,"max":null}"#);
        assert_eq!(ffi_reconnect_info(Some(sid), 4), r#"{"attempt":2,"max":null}"#);
        forget(sid);
        assert_eq!(ffi_reconnect_info(Some(sid), 4), r#"{"attempt":4,"max":null}"#);
    }

    #[test]
    fn controller_turns_answers_into_ui_events() {
        let ev = on_controller(11, &req(SHORTCUT_RESULT, r#"{"req":2,"ok":false,"err":"failed"}"#)).unwrap();
        assert_eq!(ev.name, EV_SHORTCUT_RESULT);
        assert_eq!(
            ev.fields,
            vec![
                ("req", json!(2)),
                ("ok", json!(false)),
                ("err", json!("failed")),
                ("res", Value::Null)
            ]
        );
        // The admin result reaches the UI only when the session asked for it, once.
        assert!(on_controller(11, &req(TERM_ADMIN_RESULT, r#"{"ok":true}"#)).is_none());
        crate::sense::term_admin::mark_pending_for_test(11);
        let ev = on_controller(11, &req(TERM_ADMIN_RESULT, r#"{"ok":true}"#)).unwrap();
        assert_eq!(ev.name, EV_TERM_ADMIN_RESULT);
        assert_eq!(ev.fields, vec![("ok", json!(true)), ("err", Value::Null)]);
        assert!(on_controller(11, &req(TERM_ADMIN_RESULT, r#"{"ok":true}"#)).is_none());
        for (id, body) in [
            (HOST_CHAT_VISIBLE, r#"{"on":true}"#),
            (SHORTCUT_RUN, r#"{"req":1,"id":"win.taskmgr"}"#),
            (TERM_ADMIN, r#"{"ticket":"x"}"#),
        ] {
            assert!(on_controller(11, &req(id, body)).is_none(), "{id}");
        }
    }

    #[test]
    fn idle_policy_is_kept_per_session_and_older_hosts_give_unsupported() {
        let (a, b) = (0xA11CE_u64, 0xB0B_u64);
        forget(a);
        forget(b);
        // An older Host never sends `sense.idle`.
        assert_eq!(ffi_idle_policy(Some(a)), UNSUPPORTED_JSON);
        assert_eq!(ffi_idle_policy(None), UNSUPPORTED_JSON);
        let ev = on_controller(a, &req(IDLE, r#"{"min":30}"#)).unwrap();
        assert_eq!(ev.name, EV_IDLE_POLICY);
        assert_eq!(ev.fields, vec![("min", json!(30))]);
        on_controller(b, &req(IDLE, r#"{"min":null}"#)).unwrap();
        assert_eq!(idle_policy(a), Some(Some(30)));
        assert_eq!(idle_policy(b), Some(None));
        assert_eq!(ffi_idle_policy(Some(a)), r#"{"min":30}"#);
        assert_eq!(ffi_idle_policy(Some(b)), r#"{"min":null}"#);
        forget(a);
        forget(b);
        assert_eq!(idle_policy(a), None);
    }

    #[test]
    fn shortcut_run_is_recorded_without_content() {
        crate::sense::diag::sink::take();
        let no_keys = HostCtx {
            keyboard: false,
            ..SCREEN
        };
        on_host(&no_keys, &req(SHORTCUT_RUN, r#"{"req":5,"id":"win.taskmgr"}"#));
        let got = crate::sense::diag::sink::take();
        assert!(got.contains(&("shortcut".to_owned(), "run".to_owned())));
    }
}
