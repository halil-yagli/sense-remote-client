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
//! only apply the actions. Bodies still owned by later packages answer "not supported":
//! shortcuts (FAV-Ç, `shortcuts`), admin terminal (ÇK, `term_admin`), chat card capture (ÇK).

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
/// C → H `{req: u32, id: string}`: run one favourite shortcut.
pub const SHORTCUT_RUN: &str = "sense.shortcut-run";
/// H → C `{req, ok, err?}`.
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

/// Largest body taken or sent (the ticket is at most 2048 characters).
pub const MAX_BODY: usize = 4096;
const MAX_ID: usize = 64;
const MAX_CODE: usize = 32;

/// One known Sense message.
#[derive(Debug, Clone, PartialEq)]
pub enum PeerMsg {
    HostChatVisible { on: bool },
    Idle { min: Option<u32> },
    ShortcutRun { req: u32, id: String },
    ShortcutResult { req: u32, ok: bool, err: Option<String> },
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
}
#[derive(Deserialize, Serialize)]
struct RunResultBody {
    req: u32,
    ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    err: Option<String>,
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
            .filter(|b| valid_shortcut_id(&b.id))
            .map(|b| PeerMsg::ShortcutRun { req: b.req, id: b.id }),
        SHORTCUT_RESULT => body::<RunResultBody>(content)
            .filter(|b| valid_code(&b.err))
            .map(|b| PeerMsg::ShortcutResult {
                req: b.req,
                ok: b.ok,
                err: b.err,
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
            PeerMsg::ShortcutRun { req, id } => serde_json::to_value(RunBody {
                req: *req,
                id: id.clone(),
            }),
            PeerMsg::ShortcutResult { req, ok, err } => serde_json::to_value(RunResultBody {
                req: *req,
                ok: *ok,
                err: err.clone(),
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
}

/// What the Host connection does with a message.
#[derive(Debug, Clone, PartialEq)]
pub enum HostAction {
    /// Answer the Controller over the same connection.
    Reply(PeerMsg),
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
        // ÇK: tell the CM (`sense-cm-capture` Y/N) and always set it back to N when the
        // connection ends; until both exist the card keeps its capture setting.
        PeerMsg::HostChatVisible { .. } => Vec::new(),
        PeerMsg::ShortcutRun { req, id } => {
            let result = if !ctx.remote || !ctx.keyboard {
                Err(super::shortcuts::RunError::NoPermission)
            } else {
                super::shortcuts::run(&id)
            };
            let err = result.err().map(|e| e.code().to_owned());
            super::diag::kinds::shortcut_run(&id, err.is_none(), err.as_deref());
            vec![HostAction::Reply(PeerMsg::ShortcutResult {
                req,
                ok: err.is_none(),
                err,
            })]
        }
        PeerMsg::TermAdmin { ticket } => {
            let result = if ctx.terminal {
                super::term_admin::check_ticket(&ticket)
            } else {
                Err(super::term_admin::Refusal::Unsupported)
            };
            let err = result.err().map(|e| e.code().to_owned());
            super::diag::kinds::term_admin(err.is_none(), err.as_deref());
            vec![HostAction::Reply(PeerMsg::TermAdminResult {
                ok: err.is_none(),
                err,
            })]
        }
        // Messages for the Controller arriving at a Host: ignored.
        PeerMsg::Idle { .. } | PeerMsg::ShortcutResult { .. } | PeerMsg::TermAdminResult { .. } => {
            Vec::new()
        }
    }
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

/// The session ended: forget what it was told (ÇK calls it when the session closes).
#[allow(dead_code)]
pub fn forget(sid: u64) {
    idle_policies()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&sid);
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
        PeerMsg::ShortcutResult { req, ok, err } => Some(UiEvent {
            name: EV_SHORTCUT_RESULT,
            fields: vec![("req", json!(req)), ("ok", json!(ok)), ("err", json!(err))],
        }),
        PeerMsg::TermAdminResult { ok, err } => Some(UiEvent {
            name: EV_TERM_ADMIN_RESULT,
            fields: vec![("ok", json!(ok)), ("err", json!(err))],
        }),
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
    };

    fn reply(actions: Vec<HostAction>) -> PeerMsg {
        assert_eq!(actions.len(), 1, "{actions:?}");
        match actions.into_iter().next().unwrap() {
            HostAction::Reply(m) => m,
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
                id: "win.taskmgr".to_owned()
            })
        );
        assert_eq!(
            parse(SHORTCUT_RESULT, br#"{"req":7,"ok":false,"err":"some_new_code"}"#),
            Parsed::Msg(PeerMsg::ShortcutResult {
                req: 7,
                ok: false,
                err: Some("some_new_code".to_owned())
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
            },
            PeerMsg::ShortcutResult {
                req: 3,
                ok: true,
                err: None,
            },
            PeerMsg::ShortcutResult {
                req: 4,
                ok: false,
                err: Some("needs_admin".to_owned()),
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
        };
        assert_eq!(ok.body(), json!({"req": 1, "ok": true}));
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
                remote: false,
                terminal: true,
                keyboard: true,
            },
        ] {
            assert_eq!(
                reply(on_host(&ctx, &run)),
                PeerMsg::ShortcutResult {
                    req: 5,
                    ok: false,
                    err: Some("no_permission".to_owned())
                }
            );
        }
        // Until the catalogue exists (FAV-Ç) no id is known.
        assert_eq!(
            reply(on_host(&SCREEN, &run)),
            PeerMsg::ShortcutResult {
                req: 5,
                ok: false,
                err: Some("unknown_id".to_owned())
            }
        );
    }

    #[test]
    fn term_admin_answers_and_records_no_ticket() {
        crate::sense::diag::sink::take();
        let ticket = req(TERM_ADMIN, r#"{"ticket":"aaa.bbb.ccc"}"#);
        let term = HostCtx {
            remote: false,
            terminal: true,
            keyboard: false,
        };
        for ctx in [term, SCREEN] {
            assert_eq!(
                reply(on_host(&ctx, &ticket)),
                PeerMsg::TermAdminResult {
                    ok: false,
                    err: Some("unsupported".to_owned())
                }
            );
        }
        let got = crate::sense::diag::sink::take();
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|(c, k)| c == "term" && k == "admin"));
    }

    #[test]
    fn host_ignores_controller_messages_and_chat_visible_waits_for_ck() {
        for (id, body) in [
            (IDLE, r#"{"min":30}"#),
            (SHORTCUT_RESULT, r#"{"req":1,"ok":true}"#),
            (TERM_ADMIN_RESULT, r#"{"ok":true}"#),
            (HOST_CHAT_VISIBLE, r#"{"on":true}"#),
        ] {
            assert!(on_host(&SCREEN, &req(id, body)).is_empty(), "{id}");
        }
    }

    #[test]
    fn controller_turns_answers_into_ui_events() {
        let ev = on_controller(11, &req(SHORTCUT_RESULT, r#"{"req":2,"ok":false,"err":"failed"}"#)).unwrap();
        assert_eq!(ev.name, EV_SHORTCUT_RESULT);
        assert_eq!(
            ev.fields,
            vec![("req", json!(2)), ("ok", json!(false)), ("err", json!("failed"))]
        );
        let ev = on_controller(11, &req(TERM_ADMIN_RESULT, r#"{"ok":true}"#)).unwrap();
        assert_eq!(ev.name, EV_TERM_ADMIN_RESULT);
        assert_eq!(ev.fields, vec![("ok", json!(true)), ("err", Value::Null)]);
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
        on_host(&SCREEN, &req(SHORTCUT_RUN, r#"{"req":5,"id":"win.taskmgr"}"#));
        let got = crate::sense::diag::sink::take();
        assert_eq!(got, vec![("shortcut".to_owned(), "run".to_owned())]);
    }
}
