//! Sense Remote (Sürüm 12, #157, plan 2026-11-28 §2.1–§2.4): the admin terminal ("yönetici
//! terminali") without the Windows administrator name and password.
//!
//! Flow:
//! 1. Controller (Rust, never Dart): `session_sense_term_admin_begin` asks the panel for a ticket
//!    (`POST /api/sense/term-admin {peer_id}`, the employee's sign-in token). The panel checks
//!    everything on its side (active, Yönetici role, `terminal_tunnel` permission, device in the
//!    employee's projects, device policy `terminal: true`) and writes the audit record
//!    (`terminal.admin_ticket` / `terminal.admin_refused`).
//! 2. The ticket goes to the Host over the open terminal connection (`sense.term-admin`), before
//!    the terminal is opened.
//! 3. Host: [`check_ticket`] — Windows, installed service, local `enable-terminal` on, then the
//!    signature and the payload ([`verify`]), then the nonce is remembered
//!    ([`NONCE_MEMORY_S`]). Accepted: the connection's terminal runs with the service's rights
//!    (`connection.rs`), the Host card shows "Yönetici terminali açık" ([`CM_KEY`]).
//! 4. The answer `sense.term-admin-result {ok, err?}` reaches the UI as `sense_term_admin_result`;
//!    an older Host never answers, so after [`ANSWER_TIMEOUT`] the UI gets `unsupported` and
//!    keeps the old flow (K9).
//!
//! Ticket (panel `packages/shared/src/client-api/term-admin.ts`, shared vector
//! `testdata/term-admin-v1.json`): `<k>.<p>.<s>` — k key id (16 lowercase hex) of the panel's
//! envelope key, p the JCS payload bytes base64url, s the 64-byte Ed25519 signature base64url
//! (86 characters); signed data = [`SIGNING_PREFIX`] ‖ payload bytes. Payload
//! `{v:1, purpose:"term-admin", host, uid, email, iat, exp, nonce}` with `0 < exp − iat ≤ 60`.
//!
//! The ticket never reaches Dart, the event record or a log: only codes do.

use super::envelope_keys::{self, TrustedKey};
use super::peer_msg::{self, PeerMsg, UiEvent};
use base::message_proto::Message;
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    log,
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

/// Signing domain (panel `TERM_ADMIN_SIGNING_PREFIX`): no other signed object counts as a ticket.
pub const SIGNING_PREFIX: &[u8] = b"sense-remote/term-admin/v1\n";
/// Same allowance as the strategy envelope (`TERM_ADMIN_CLOCK_SKEW_S`).
pub const CLOCK_SKEW_S: i64 = super::envelope::CLOCK_SKEW_S;
/// `exp − iat` upper limit; the panel signs `exp = iat + 60`.
pub const MAX_LIFETIME_S: i64 = 60;
/// A used nonce is remembered at least this long: a ticket is accepted at most in
/// `iat − skew … exp + skew` (660 s).
pub const NONCE_MEMORY_S: i64 = MAX_LIFETIME_S + 2 * CLOCK_SKEW_S;
/// Longest ticket (panel `TERM_ADMIN_TICKET_MAX`).
pub const TICKET_MAX: usize = 2048;
/// Nonces remembered at most; when full (and nothing expired) further tickets are refused as
/// replays: failing closed is safer than forgetting a nonce early.
pub const NONCE_KEEP: usize = 256;
/// Controller: how long to wait for the Host's answer before telling the UI `unsupported`.
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// Panel route of the ticket.
pub const PATH: &str = "/api/sense/term-admin";
/// CM channel key (`ipc::Data::Config`): the connection's terminal runs as admin; value = the
/// employee's e-mail from the ticket (the Host card shows it).
pub const CM_KEY: &str = "sense-term-admin";

const SIGNATURE_CHARS: usize = 86;
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
/// Panel error codes (`TermAdminErrorCode`); anything else becomes `panel_error`.
const PANEL_ERRORS: [&str; 7] = [
    "token_invalid",
    "not_admin",
    "no_terminal_permission",
    "device_not_accessible",
    "policy_terminal_off",
    "signing_unavailable",
    "rate_limited",
];

/// Why the Host refused a ticket (contract codes, `sense.term-admin-result.err`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    BadSig,
    Expired,
    Replay,
    WrongHost,
    PolicyOff,
    Unsupported,
}

impl Refusal {
    pub fn code(self) -> &'static str {
        match self {
            Refusal::BadSig => "bad_sig",
            Refusal::Expired => "expired",
            Refusal::Replay => "replay",
            Refusal::WrongHost => "wrong_host",
            Refusal::PolicyOff => "policy_off",
            Refusal::Unsupported => "unsupported",
        }
    }
}

/// The verifier's reason, in check order (panel `TermAdminRejectReason`, vector `result`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongHost,
    NotYetValid,
    Expired,
    Replayed,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Malformed => "malformed",
            Reason::UnknownKey => "unknown_key",
            Reason::BadSignature => "bad_signature",
            Reason::BadPayload => "bad_payload",
            Reason::WrongHost => "wrong_host",
            Reason::NotYetValid => "not_yet_valid",
            Reason::Expired => "expired",
            Reason::Replayed => "replayed",
        }
    }

    /// The code the peer gets (panel `TERM_ADMIN_PEER_ERROR`).
    pub fn refusal(self) -> Refusal {
        match self {
            Reason::Malformed | Reason::UnknownKey | Reason::BadSignature | Reason::BadPayload => {
                Refusal::BadSig
            }
            Reason::WrongHost => Refusal::WrongHost,
            Reason::NotYetValid | Reason::Expired => Refusal::Expired,
            Reason::Replayed => Refusal::Replay,
        }
    }
}

/// What the Host expects; all supplied by the caller.
pub struct Expect<'a> {
    /// This computer's RustDesk id.
    pub host: &'a str,
    /// Local clock, Unix seconds.
    pub now_s: i64,
    /// True when the nonce was used in the last [`NONCE_MEMORY_S`].
    pub seen: &'a dyn Fn(&str) -> bool,
}

/// An accepted ticket: who asked (for the Host card) and its nonce (to remember).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub uid: String,
    pub email: String,
    pub nonce: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    v: i64,
    purpose: String,
    host: String,
    uid: String,
    email: String,
    iat: i64,
    exp: i64,
    nonce: String,
}

fn len_between(value: &str, min: usize, max: usize) -> bool {
    // zod counts UTF-16 units.
    (min..=max).contains(&value.encode_utf16().count())
}

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Panel `TermAdminNonce`: 16 bytes, unpadded base64url, canonical last character.
fn is_nonce(value: &str) -> bool {
    value.len() == 22
        && is_base64url_alphabet(value)
        && matches!(value.as_bytes()[21], b'A' | b'Q' | b'g' | b'w')
}

fn is_safe_int(value: i64) -> bool {
    (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value)
}

impl Payload {
    /// Panel `TermAdminPayload` schema.
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.purpose == "term-admin"
            && len_between(&self.host, 1, 64)
            && len_between(&self.uid, 1, 64)
            && len_between(&self.email, 3, 254)
            && is_nonce(&self.nonce)
            && self.iat >= 0
            && self.exp > 0
            && is_safe_int(self.iat)
            && is_safe_int(self.exp)
            && self.exp > self.iat
            && self.exp - self.iat <= MAX_LIFETIME_S
    }
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, admin tickets cannot be verified");
        }
        ok
    })
}

fn signature_ok(public_key: &[u8; 32], payload: &[u8], signature: &[u8; 64]) -> bool {
    if !sodium_ready() {
        return false;
    }
    let Ok(signature) = Signature::from_bytes(signature) else {
        return false;
    };
    let mut signed = Vec::with_capacity(SIGNING_PREFIX.len() + payload.len());
    signed.extend_from_slice(SIGNING_PREFIX);
    signed.extend_from_slice(payload);
    verify_detached(&signature, &signed, &PublicKey(*public_key))
}

/// Every check, in the panel's order. Pure; `keys` are the trusted panel keys.
pub fn verify(ticket: &str, keys: &[TrustedKey], expect: &Expect) -> Result<Grant, Reason> {
    // 1. Shape.
    if ticket.len() > TICKET_MAX {
        return Err(Reason::Malformed);
    }
    let parts: Vec<&str> = ticket.split('.').collect();
    let &[k, p, s] = parts.as_slice() else {
        return Err(Reason::Malformed);
    };
    if !envelope_keys::is_key_id(k)
        || p.is_empty()
        || !is_base64url_alphabet(p)
        || s.len() != SIGNATURE_CHARS
        || !is_base64url_alphabet(s)
    {
        return Err(Reason::Malformed);
    }
    // 2. Known key.
    let key = keys.iter().find(|key| key.k == k).ok_or(Reason::UnknownKey)?;
    // 3. Strict base64url, 64-byte signature.
    let payload = URL_SAFE_NO_PAD.decode(p).map_err(|_| Reason::Malformed)?;
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(s)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(Reason::Malformed)?;
    // 4. Signature over the term-admin prefix ‖ payload bytes, exactly as received.
    if !signature_ok(&key.public_key, &payload, &signature) {
        return Err(Reason::BadSignature);
    }
    // 5. Schema of the signed bytes.
    let payload: Payload = serde_json::from_slice(&payload).map_err(|_| Reason::BadPayload)?;
    if !payload.is_valid() {
        return Err(Reason::BadPayload);
    }
    // 6. This computer.
    if payload.host != expect.host {
        return Err(Reason::WrongHost);
    }
    // 7. Validity window with the clock skew allowance.
    if expect.now_s < payload.iat.saturating_sub(CLOCK_SKEW_S) {
        return Err(Reason::NotYetValid);
    }
    if expect.now_s > payload.exp.saturating_add(CLOCK_SKEW_S) {
        return Err(Reason::Expired);
    }
    // 8. Once.
    if (expect.seen)(payload.nonce.as_str()) {
        return Err(Reason::Replayed);
    }
    Ok(Grant {
        uid: payload.uid,
        email: payload.email,
        nonce: payload.nonce,
    })
}

// ---------------------------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------------------------

/// Used nonces with the time they may be forgotten (in memory only).
#[derive(Debug, Default)]
pub struct NonceMemory {
    until: HashMap<String, i64>,
}

impl NonceMemory {
    fn prune(&mut self, now_s: i64) {
        self.until.retain(|_, until| *until > now_s);
    }

    pub fn contains(&self, nonce: &str) -> bool {
        self.until.contains_key(nonce)
    }

    /// False when full: the ticket is then refused.
    fn remember(&mut self, nonce: &str, now_s: i64) -> bool {
        if self.until.len() >= NONCE_KEEP {
            return false;
        }
        self.until
            .insert(nonce.to_owned(), now_s.saturating_add(NONCE_MEMORY_S));
        true
    }
}

/// What the Host connection knows about itself when a ticket arrives.
#[derive(Debug, Clone, Copy)]
pub struct HostSide<'a> {
    /// Windows, installed service, terminal not opened yet on this connection.
    pub capable: bool,
    /// Local `enable-terminal` is on (panel policy applied).
    pub terminal_enabled: bool,
    pub host: &'a str,
    pub now_s: i64,
}

/// Host check (pure apart from `memory`): platform → local policy → ticket → nonce.
pub fn check_with(
    ticket: &str,
    side: &HostSide,
    keys: &[TrustedKey],
    memory: &mut NonceMemory,
) -> Result<Grant, Refusal> {
    if !side.capable {
        return Err(Refusal::Unsupported);
    }
    if !side.terminal_enabled {
        return Err(Refusal::PolicyOff);
    }
    memory.prune(side.now_s);
    let seen = |nonce: &str| memory.contains(nonce);
    let grant = verify(
        ticket,
        keys,
        &Expect {
            host: side.host,
            now_s: side.now_s,
            seen: &seen,
        },
    )
    .map_err(|reason| {
        log::warn!("Sense Remote: admin terminal ticket refused: {}", reason.as_str());
        reason.refusal()
    })?;
    if !memory.remember(&grant.nonce, side.now_s) {
        log::warn!("Sense Remote: admin terminal ticket refused: nonce memory full");
        return Err(Refusal::Replay);
    }
    Ok(grant)
}

fn nonce_memory() -> &'static Mutex<NonceMemory> {
    static MEMORY: OnceLock<Mutex<NonceMemory>> = OnceLock::new();
    MEMORY.get_or_init(Default::default)
}

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Host: checks a ticket with this computer's id, clock and the trusted panel keys.
pub fn check_ticket(ticket: &str, capable: bool, terminal_enabled: bool) -> Result<Grant, Refusal> {
    // The id is read only when the ticket is looked at.
    let host = if capable && terminal_enabled {
        hbb_common::config::Config::get_id()
    } else {
        String::new()
    };
    let mut memory = nonce_memory().lock().unwrap_or_else(|e| e.into_inner());
    check_with(
        ticket,
        &HostSide {
            capable,
            terminal_enabled,
            host: &host,
            now_s: now_s(),
        },
        envelope_keys::trusted_keys(),
        &mut memory,
    )
}

/// Platforms where the admin terminal runs without the Windows sign-in (Mac: never, as in v11).
pub const SUPPORTED: bool = cfg!(windows);

/// The e-mail as the Host card may show it: printable, at most 254 characters.
pub fn card_name(email: &str) -> String {
    email
        .chars()
        .filter(|c| !c.is_control())
        .take(254)
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------------------------

/// Sessions waiting for the Host's answer, with the time the ticket was sent.
fn pending() -> &'static Mutex<HashMap<u64, Instant>> {
    static PENDING: OnceLock<Mutex<HashMap<u64, Instant>>> = OnceLock::new();
    PENDING.get_or_init(Default::default)
}

fn lock_pending() -> std::sync::MutexGuard<'static, HashMap<u64, Instant>> {
    pending().lock().unwrap_or_else(|e| e.into_inner())
}

/// The Host's answer arrived: true when this session was waiting for it (only then the UI hears
/// about it; a late or unasked answer is dropped).
pub fn take_pending(sid: u64) -> bool {
    lock_pending().remove(&sid).is_some()
}

/// The session closed.
pub fn forget(sid: u64) {
    lock_pending().remove(&sid);
}

fn result_event(ok: bool, err: Option<&str>) -> UiEvent {
    UiEvent {
        name: peer_msg::EV_TERM_ADMIN_RESULT,
        fields: vec![("ok", json!(ok)), ("err", json!(err))],
    }
}

/// Reads the panel's answer (pure): the ticket, or an error code (`TermAdminErrorCode`,
/// `panel_error` for anything else).
pub fn parse_answer(status: u16, body: &str) -> Result<String, String> {
    let value: Option<Value> = serde_json::from_str(body).ok();
    if status == 200 {
        let ticket = value
            .as_ref()
            .and_then(|v| v.get("ticket"))
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty() && t.len() <= TICKET_MAX && t.split('.').count() == 3);
        return ticket.map(str::to_owned).ok_or_else(|| "panel_error".to_owned());
    }
    let code = value
        .as_ref()
        .and_then(|v| v.get("error"))
        .and_then(Value::as_str)
        .filter(|c| PANEL_ERRORS.contains(c));
    Err(code.unwrap_or("panel_error").to_owned())
}

/// `POST /api/sense/term-admin` with the employee's token. The ticket is not logged.
fn fetch_ticket(peer_id: &str, token: &str) -> Result<String, String> {
    let mut header = serde_json::Map::new();
    header.insert("Authorization".to_owned(), Value::String(format!("Bearer {token}")));
    header.insert("Content-Type".to_owned(), Value::String("application/json".to_owned()));
    let url = format!("{}{PATH}", super::api_server());
    let body = json!({ "peer_id": peer_id }).to_string();
    let response = crate::http_request_sync(
        url,
        "POST".to_owned(),
        Some(body),
        Value::Object(header).to_string(),
    )
    .map_err(|err| {
        log::debug!("Sense Remote: admin ticket request failed: {err}");
        "network".to_owned()
    })?;
    let v: Value = serde_json::from_str(&response).map_err(|_| "network".to_owned())?;
    let status = v
        .get("status_code")
        .and_then(Value::as_u64)
        .and_then(|s| u16::try_from(s).ok())
        .ok_or_else(|| "network".to_owned())?;
    let result = parse_answer(status, v.get("body").and_then(Value::as_str).unwrap_or(""));
    if let Err(code) = &result {
        log::info!("Sense Remote: admin ticket not given: {code}");
    }
    result
}

/// What `begin` needs to know about the session.
pub struct Session<'a> {
    pub sid: u64,
    pub peer_id: &'a str,
    pub is_terminal: bool,
    /// The employee's sign-in token (`access_token`); `None` = signed out.
    pub token: Option<String>,
}

/// Checks that can be answered at once: "" to go on, otherwise the code.
pub fn begin_check(session: &Session) -> &'static str {
    if !session.is_terminal {
        return "not_terminal";
    }
    if session.peer_id.is_empty() {
        return "no_session";
    }
    if session.token.is_none() {
        return "signed_out";
    }
    if lock_pending().contains_key(&session.sid) {
        return "busy";
    }
    ""
}

/// Fetches and sends (the slow half of `begin`, on its own thread). The UI hears only errors here;
/// the Host's answer comes through `peer_msg::on_controller`.
pub fn fetch_and_send(
    sid: u64,
    peer_id: &str,
    token: &str,
    fetch: impl FnOnce(&str, &str) -> Result<String, String>,
    send: impl FnOnce(Message) -> bool,
) -> Option<UiEvent> {
    let ticket = match fetch(peer_id, token) {
        Ok(ticket) => ticket,
        Err(code) => {
            forget(sid);
            return Some(result_event(false, Some(code.as_str())));
        }
    };
    let msg = PeerMsg::TermAdmin { ticket }.to_message();
    if !send(msg) {
        forget(sid);
        return Some(result_event(false, Some("no_session")));
    }
    None
}

/// No answer in time (an older Host ignores the message): `unsupported`, once.
pub fn expire(sid: u64, sent_at: Instant) -> Option<UiEvent> {
    let mut map = lock_pending();
    if map.get(&sid) == Some(&sent_at) {
        map.remove(&sid);
        return Some(result_event(false, Some(Refusal::Unsupported.code())));
    }
    None
}

/// `session_sense_term_admin_begin`: "" when the request started (the answer comes as the event
/// `sense_term_admin_result`), otherwise `not_terminal` | `no_session` | `signed_out` | `busy`.
pub fn begin<S, P>(session: Session, send: S, push: P) -> String
where
    S: FnOnce(Message) -> bool + Send + 'static,
    P: Fn(UiEvent) + Send + 'static,
{
    let code = begin_check(&session);
    if !code.is_empty() {
        return code.to_owned();
    }
    let sid = session.sid;
    let peer_id = session.peer_id.to_owned();
    let token = session.token.unwrap_or_default();
    let sent_at = Instant::now();
    lock_pending().insert(sid, sent_at);
    std::thread::spawn(move || {
        if let Some(ev) = fetch_and_send(sid, &peer_id, &token, fetch_ticket, send) {
            push(ev);
            return;
        }
        std::thread::sleep(ANSWER_TIMEOUT);
        if let Some(ev) = expire(sid, sent_at) {
            log::info!("Sense Remote: admin terminal: no answer from the Host (older version)");
            push(ev);
        }
    });
    String::new()
}

#[cfg(test)]
pub fn mark_pending_for_test(sid: u64) {
    lock_pending().insert(sid, Instant::now());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::envelope_keys::{key_id, parse_keys};

    const VECTOR: &str = include_str!("testdata/term-admin-v1.json");

    fn vector() -> Value {
        serde_json::from_str(VECTOR).expect("term-admin-v1.json is valid JSON")
    }

    fn str_of<'a>(value: &'a Value, field: &str) -> &'a str {
        value[field]
            .as_str()
            .unwrap_or_else(|| panic!("{field} is a string"))
    }

    fn vector_keys(v: &Value) -> Vec<TrustedKey> {
        let entries: Vec<String> = v["keys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|key| format!("{}={}", str_of(key, "k"), str_of(key, "public_key")))
            .collect();
        parse_keys(&entries.join(",")).expect("vector keys parse as SENSE_ENVELOPE_KEYS")
    }

    fn case<'a>(v: &'a Value, name: &str) -> &'a Value {
        v["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == name)
            .unwrap_or_else(|| panic!("case {name}"))
    }

    #[test]
    fn vector_constants_match() {
        let v = vector();
        assert_eq!(v["v"], 1);
        assert_eq!(str_of(&v, "prefix").as_bytes(), SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::envelope::SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::wol::SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::grants::SIGNING_PREFIX);
        assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
        assert_eq!(v["max_lifetime_s"].as_i64(), Some(MAX_LIFETIME_S));
        assert_eq!(v["nonce_memory_s"].as_i64(), Some(NONCE_MEMORY_S));
        assert_eq!(NONCE_MEMORY_S, 660);
        for key in &vector_keys(&v) {
            assert_eq!(key.k, key_id(&key.public_key));
        }
    }

    #[test]
    fn vector_cases_match() {
        let v = vector();
        let keys = vector_keys(&v);
        let cases = v["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 28);
        let mut failures = Vec::new();
        let mut covered = std::collections::HashSet::new();
        for c in cases {
            let name = str_of(c, "name");
            let wanted = str_of(c, "result");
            let e = &c["expect"];
            let seen: Vec<String> = serde_json::from_value(e["seen"].clone()).unwrap();
            let seen_fn = |n: &str| seen.iter().any(|s| s == n);
            let got = verify(
                str_of(c, "ticket"),
                &keys,
                &Expect {
                    host: str_of(e, "host"),
                    now_s: e["now_s"].as_i64().unwrap(),
                    seen: &seen_fn,
                },
            );
            let got_name = match &got {
                Ok(_) => "ok",
                Err(reason) => reason.as_str(),
            };
            covered.insert(got_name);
            if got_name != wanted {
                failures.push(format!("{name}: expected {wanted}, got {got_name}"));
                continue;
            }
            if let Ok(grant) = got {
                assert_eq!(grant.uid, str_of(c, "uid"), "{name}");
                assert_eq!(grant.email, str_of(c, "email"), "{name}");
                assert_eq!(grant.nonce, str_of(c, "nonce"), "{name}");
            }
        }
        assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
        for reason in [
            "ok",
            "malformed",
            "unknown_key",
            "bad_signature",
            "bad_payload",
            "wrong_host",
            "not_yet_valid",
            "expired",
            "replayed",
        ] {
            assert!(covered.contains(reason), "{reason} not covered");
        }
    }

    #[test]
    fn reasons_map_to_the_peer_codes_of_the_contract() {
        let all = [
            (Reason::Malformed, "bad_sig"),
            (Reason::UnknownKey, "bad_sig"),
            (Reason::BadSignature, "bad_sig"),
            (Reason::BadPayload, "bad_sig"),
            (Reason::WrongHost, "wrong_host"),
            (Reason::NotYetValid, "expired"),
            (Reason::Expired, "expired"),
            (Reason::Replayed, "replay"),
        ];
        for (reason, code) in all {
            assert_eq!(reason.refusal().code(), code, "{reason:?}");
        }
        for (r, code) in [
            (Refusal::BadSig, "bad_sig"),
            (Refusal::Expired, "expired"),
            (Refusal::Replay, "replay"),
            (Refusal::WrongHost, "wrong_host"),
            (Refusal::PolicyOff, "policy_off"),
            (Refusal::Unsupported, "unsupported"),
        ] {
            assert_eq!(r.code(), code);
        }
    }

    fn side(now_s: i64) -> HostSide<'static> {
        HostSide {
            capable: true,
            terminal_enabled: true,
            host: "123456789",
            now_s,
        }
    }

    #[test]
    fn host_accepts_once_and_remembers_the_nonce_for_660_s() {
        let v = vector();
        let keys = vector_keys(&v);
        let ticket = str_of(case(&v, "ok"), "ticket");
        let mut memory = NonceMemory::default();
        let now = 1_800_000_005;
        let grant = check_with(ticket, &side(now), &keys, &mut memory).unwrap();
        assert_eq!(grant.email, "calisan@example.test");
        // The same ticket again: replay, even at the very end of its window.
        assert_eq!(check_with(ticket, &side(now + 1), &keys, &mut memory), Err(Refusal::Replay));
        assert_eq!(
            check_with(ticket, &side(1_800_000_360), &keys, &mut memory),
            Err(Refusal::Replay)
        );
        // After the memory time the nonce is forgotten, but the ticket has long expired.
        assert_eq!(
            check_with(ticket, &side(now + NONCE_MEMORY_S + 1), &keys, &mut memory),
            Err(Refusal::Expired)
        );
        assert!(memory.until.is_empty());
    }

    #[test]
    fn host_refuses_before_looking_at_the_ticket() {
        let v = vector();
        let keys = vector_keys(&v);
        let ticket = str_of(case(&v, "ok"), "ticket");
        let mut memory = NonceMemory::default();
        let now = 1_800_000_005;
        let off = HostSide {
            capable: false,
            ..side(now)
        };
        assert_eq!(check_with(ticket, &off, &keys, &mut memory), Err(Refusal::Unsupported));
        let policy = HostSide {
            terminal_enabled: false,
            ..side(now)
        };
        assert_eq!(check_with(ticket, &policy, &keys, &mut memory), Err(Refusal::PolicyOff));
        // Refused tickets do not use up the nonce.
        assert!(memory.until.is_empty());
        assert!(check_with(ticket, &side(now), &keys, &mut memory).is_ok());
    }

    #[test]
    fn host_codes_for_each_kind_of_bad_ticket() {
        let v = vector();
        let keys = vector_keys(&v);
        let now = 1_800_000_005;
        for (name, code) in [
            ("bad_signature_envelope_prefix", Refusal::BadSig),
            ("unknown_key", Refusal::BadSig),
            ("malformed_two_parts", Refusal::BadSig),
            ("wrong_host", Refusal::WrongHost),
        ] {
            let mut memory = NonceMemory::default();
            let ticket = str_of(case(&v, name), "ticket");
            assert_eq!(check_with(ticket, &side(now), &keys, &mut memory), Err(code), "{name}");
        }
        let mut memory = NonceMemory::default();
        let ticket = str_of(case(&v, "ok"), "ticket");
        assert_eq!(
            check_with(ticket, &side(1_800_000_361), &keys, &mut memory),
            Err(Refusal::Expired)
        );
        // No trusted key in the build: nothing is accepted.
        assert_eq!(check_with(ticket, &side(now), &[], &mut memory), Err(Refusal::BadSig));
    }

    #[test]
    fn a_full_nonce_memory_fails_closed() {
        let v = vector();
        let keys = vector_keys(&v);
        let now = 1_800_000_005;
        let mut memory = NonceMemory::default();
        for i in 0..NONCE_KEEP {
            assert!(memory.remember(&format!("n{i}"), now));
        }
        let ticket = str_of(case(&v, "ok"), "ticket");
        assert_eq!(check_with(ticket, &side(now), &keys, &mut memory), Err(Refusal::Replay));
    }

    #[test]
    fn card_name_drops_control_characters() {
        assert_eq!(card_name("a\u{7}b@c.d\n"), "ab@c.d");
        assert_eq!(card_name(&"x".repeat(400)).len(), 254);
    }

    #[test]
    fn panel_answers() {
        let ticket = "4e548b8ad40c0f20.e30.sig";
        assert_eq!(parse_answer(200, &json!({ "ticket": ticket }).to_string()), Ok(ticket.to_owned()));
        assert_eq!(parse_answer(200, "{}"), Err("panel_error".to_owned()));
        assert_eq!(parse_answer(200, r#"{"ticket":"no-dots"}"#), Err("panel_error".to_owned()));
        for code in PANEL_ERRORS {
            assert_eq!(
                parse_answer(403, &json!({ "error": code }).to_string()),
                Err(code.to_owned())
            );
        }
        assert_eq!(parse_answer(500, "oops"), Err("panel_error".to_owned()));
        assert_eq!(
            parse_answer(400, r#"{"error":"Something Else"}"#),
            Err("panel_error".to_owned())
        );
    }

    fn session(sid: u64, token: Option<&str>) -> Session<'static> {
        Session {
            sid,
            peer_id: "123456789",
            is_terminal: true,
            token: token.map(str::to_owned),
        }
    }

    #[test]
    fn begin_checks() {
        let sid = 0x7E57_0001;
        forget(sid);
        assert_eq!(begin_check(&session(sid, Some("t"))), "");
        assert_eq!(begin_check(&session(sid, None)), "signed_out");
        let screen = Session {
            is_terminal: false,
            ..session(sid, Some("t"))
        };
        assert_eq!(begin_check(&screen), "not_terminal");
        let no_peer = Session {
            peer_id: "",
            ..session(sid, Some("t"))
        };
        assert_eq!(begin_check(&no_peer), "no_session");
        lock_pending().insert(sid, Instant::now());
        assert_eq!(begin_check(&session(sid, Some("t"))), "busy");
        forget(sid);
    }

    #[test]
    fn fetch_and_send_passes_the_ticket_only_to_the_peer() {
        let sid = 0x7E57_0002;
        lock_pending().insert(sid, Instant::now());
        let mut sent = None;
        let ev = fetch_and_send(
            sid,
            "123456789",
            "TOKEN",
            |peer, token| {
                assert_eq!((peer, token), ("123456789", "TOKEN"));
                Ok("k.p.s".to_owned())
            },
            |m| {
                sent = Some(m);
                true
            },
        );
        assert!(ev.is_none());
        let msg = sent.unwrap();
        let p = msg.misc().plugin_request();
        assert_eq!(p.id, peer_msg::TERM_ADMIN);
        assert_eq!(
            peer_msg::parse(&p.id, &p.content),
            peer_msg::Parsed::Msg(PeerMsg::TermAdmin {
                ticket: "k.p.s".to_owned()
            })
        );
        // Still waiting for the Host.
        assert!(take_pending(sid));
        assert!(!take_pending(sid));
    }

    #[test]
    fn fetch_errors_reach_the_ui_without_the_ticket() {
        let sid = 0x7E57_0003;
        lock_pending().insert(sid, Instant::now());
        let ev = fetch_and_send(sid, "1", "T", |_, _| Err("not_admin".to_owned()), |_| true).unwrap();
        assert_eq!(ev.name, peer_msg::EV_TERM_ADMIN_RESULT);
        assert_eq!(ev.fields, vec![("ok", json!(false)), ("err", json!("not_admin"))]);
        assert!(!take_pending(sid));
        lock_pending().insert(sid, Instant::now());
        let ev = fetch_and_send(sid, "1", "T", |_, _| Ok("a.b.c".to_owned()), |_| false).unwrap();
        assert_eq!(ev.fields, vec![("ok", json!(false)), ("err", json!("no_session"))]);
        assert!(!take_pending(sid));
    }

    #[test]
    fn an_older_host_times_out_as_unsupported_once() {
        let sid = 0x7E57_0004;
        let sent_at = Instant::now();
        lock_pending().insert(sid, sent_at);
        let ev = expire(sid, sent_at).unwrap();
        assert_eq!(ev.fields, vec![("ok", json!(false)), ("err", json!("unsupported"))]);
        assert!(expire(sid, sent_at).is_none());
        // A newer request of the same session is not expired by the old timer.
        let newer = Instant::now() + Duration::from_millis(1);
        lock_pending().insert(sid, newer);
        assert!(expire(sid, sent_at).is_none());
        assert!(take_pending(sid));
    }
}
