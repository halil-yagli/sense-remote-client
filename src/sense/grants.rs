//! Sense Remote (Sürüm 4, YH S11 app side; plan 2026-11-23 §2.4, §2.6): the signed per-person
//! permission envelope ("grants") the panel gives a signed-in Controller. The Controller screens
//! and the session buttons read it to lock what this person may not do.
//!
//! Same envelope shape and panel keys as the strategy envelope (`{k, p, s}`, Ed25519), but its own
//! signing prefix `sense-remote/grants/v1\n`: a strategy or update signature never counts as
//! grants (and the other way round). It does not touch the device `seq`; `rev` (never goes back)
//! and `exp` stop a replay. Checks, in the panel's order (`packages/shared/src/grants-node.ts`,
//! shared vector `testdata/grants-v1.json`):
//!
//! envelope shape → `k` known → p/s decode (s 64 bytes) → signature (grants prefix) → JSON +
//! schema (no unknown field, `typ` grants, perms from the app catalogue without repeats,
//! `0 < exp − iat ≤ 12 h`) → `iss` → `did` + `duuid` → `email` = signed-in e-mail (case
//! insensitive) → `iat − 300 ≤ now ≤ exp + 300` → `rev ≥ stored rev`.
//!
//! Where it comes from: the sign-in answer (`user.info.sense_grants`, read in
//! `hbbs_http/account.rs`) and `GET /api/sense/grants` every 10 s while the app runs (ETag
//! `"<rev>-<exp>"`, 304 when nothing changed) and when the window gets focus (Dart calls
//! `main_sense_grants_refresh`). A valid envelope is kept in `grants.json` in the user's config
//! folder (no secret in it: the envelope is signed public data). No envelope, an expired or an
//! unverifiable one → every permission is off. Signing out (empty `access_token`) deletes it.
//!
//! Hiding a button on the Controller is not the protection (plan §2.4 "Sınır"): the panel refuses
//! what a person may not do. Only the verification below is pure; keys, device, e-mail and time
//! come from the caller.

use super::envelope_keys::{self, TrustedKey};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config::{Config, LocalConfig},
    log,
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    sync::{Mutex, OnceLock},
    time::Duration,
};

/// Domain separation: signed data = this prefix (ASCII) ‖ payload bytes.
pub const SIGNING_PREFIX: &[u8] = b"sense-remote/grants/v1\n";
/// Same allowance as the strategy envelope.
pub const CLOCK_SKEW_S: i64 = super::envelope::CLOCK_SKEW_S;
/// `exp − iat` upper limit: 12 hours.
pub const MAX_LIFETIME_S: i64 = 12 * 3600;
/// The app permissions (panel `APP_PERMISSIONS`, `packages/shared/src/permissions.ts`), in
/// catalogue order. Panel permissions never come in a grants envelope.
pub const APP_PERMISSIONS: [&str; 8] = [
    "connect",
    "control",
    "file_transfer",
    "record_session",
    "privacy_mode",
    "restart_remote",
    "terminal_tunnel",
    "install_device",
];
/// Poll interval while the app runs (panel `GRANTS_POLL_INTERVAL_MS`).
pub const POLL_INTERVAL: Duration = Duration::from_secs(10);
const GRANTS_PATH: &str = "/api/sense/grants";
const STORE_FILE: &str = "grants.json";
const MAX_PAYLOAD_CHARS: usize = 65_536;
const SIGNATURE_CHARS: usize = 86;
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

/// Why an envelope was refused. Names are the panel's `GrantsRejectReason` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongIssuer,
    WrongDevice,
    WrongUser,
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
            Reason::WrongIssuer => "wrong_issuer",
            Reason::WrongDevice => "wrong_device",
            Reason::WrongUser => "wrong_user",
            Reason::NotYetValid => "not_yet_valid",
            Reason::Expired => "expired",
            Reason::Replayed => "replayed",
        }
    }
}

/// What this computer and this sign-in expect; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    /// Panel host (`envelope::expected_issuer`).
    pub iss: &'a str,
    /// Own RustDesk ID.
    pub did: &'a str,
    /// Own uuid, in the form the heartbeat sends.
    pub duuid: &'a str,
    /// E-mail of the signed-in account.
    pub email: &'a str,
    /// Local clock, Unix seconds.
    pub now_s: i64,
    /// `rev` of the stored envelope of this person, 0 if none.
    pub last_rev: u64,
}

/// A verified envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grants {
    /// Catalogue order, as signed.
    pub perms: Vec<String>,
    pub email: String,
    pub rev: u64,
    pub iat: i64,
    pub exp: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    v: i64,
    typ: String,
    iss: String,
    did: String,
    duuid: String,
    uid: String,
    email: String,
    perms: Vec<String>,
    rev: i64,
    iat: i64,
    exp: i64,
}

fn is_safe_int(value: i64) -> bool {
    (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value)
}

fn len_between(value: &str, min: usize, max: usize) -> bool {
    // zod counts UTF-16 units; the panel only signs ASCII here, where both agree.
    let n = value.encode_utf16().count();
    (min..=max).contains(&n)
}

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// zod 4 `z.email()` (its default pattern): local part of `A-Za-z0-9_'+-.` not starting with a
/// dot, no `..`, last character not a dot or `'`; domain labels of `A-Za-z0-9-` not starting with
/// `-`, at least one dot, top level two or more letters.
pub(crate) fn is_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    let local_ok = !local.is_empty()
        && !local.starts_with('.')
        && !local.contains("..")
        && local
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_'+-.".contains(&b))
        && local
            .bytes()
            .last()
            .is_some_and(|b| b.is_ascii_alphanumeric() || b"_+-".contains(&b));
    if !local_ok || value.contains("..") {
        return false;
    }
    let labels: Vec<&str> = domain.split('.').collect();
    let Some((tld, rest)) = labels.split_last() else {
        return false;
    };
    !rest.is_empty()
        && tld.len() >= 2
        && tld.bytes().all(|b| b.is_ascii_alphabetic())
        && rest.iter().all(|label| {
            label.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
                && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

impl Payload {
    /// The panel's `GrantsPayload` schema.
    fn is_valid(&self) -> bool {
        let perms_ok = self.perms.len() <= APP_PERMISSIONS.len()
            && self.perms.iter().all(|p| APP_PERMISSIONS.contains(&p.as_str()))
            && self
                .perms
                .iter()
                .enumerate()
                .all(|(i, p)| !self.perms[..i].contains(p));
        self.v == 1
            && self.typ == "grants"
            && len_between(&self.iss, 1, 253)
            && len_between(&self.did, 1, 64)
            && len_between(&self.duuid, 1, 128)
            && len_between(&self.uid, 1, 64)
            && len_between(&self.email, 1, 255)
            && is_email(&self.email)
            && perms_ok
            && self.rev > 0
            && self.iat >= 0
            && self.exp > 0
            && [self.rev, self.iat, self.exp].into_iter().all(is_safe_int)
            && self.exp > self.iat
            && self.exp - self.iat <= MAX_LIFETIME_S
    }
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, grants cannot be verified");
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
pub fn verify(envelope: &Value, keys: &[TrustedKey], expect: &Expect) -> Result<Grants, Reason> {
    // 1. Shape: exactly {k, p, s}, strings in the panel's alphabet and lengths.
    let object = envelope.as_object().ok_or(Reason::Malformed)?;
    if object.len() != 3 {
        return Err(Reason::Malformed);
    }
    let field = |name: &str| object.get(name).and_then(Value::as_str);
    let (Some(k), Some(p), Some(s)) = (field("k"), field("p"), field("s")) else {
        return Err(Reason::Malformed);
    };
    if !envelope_keys::is_key_id(k)
        || p.is_empty()
        || p.len() > MAX_PAYLOAD_CHARS
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
    // 4. Signature over the grants prefix ‖ payload bytes, exactly as received.
    if !signature_ok(&key.public_key, &payload, &signature) {
        return Err(Reason::BadSignature);
    }
    // 5. Schema of the signed bytes (never re-canonicalized).
    let payload: Payload = serde_json::from_slice(&payload).map_err(|_| Reason::BadPayload)?;
    if !payload.is_valid() {
        return Err(Reason::BadPayload);
    }
    // 6. Issuer, device, person.
    if payload.iss != expect.iss {
        return Err(Reason::WrongIssuer);
    }
    if payload.did != expect.did || payload.duuid != expect.duuid {
        return Err(Reason::WrongDevice);
    }
    if payload.email.to_lowercase() != expect.email.to_lowercase() {
        return Err(Reason::WrongUser);
    }
    // 7. Validity window with clock skew allowance.
    if expect.now_s < payload.iat.saturating_sub(CLOCK_SKEW_S) {
        return Err(Reason::NotYetValid);
    }
    if expect.now_s > payload.exp.saturating_add(CLOCK_SKEW_S) {
        return Err(Reason::Expired);
    }
    // 8. `rev` never goes back (same `rev` = same permissions with a new `exp`).
    let rev = payload.rev as u64; // > 0, checked by the schema
    if rev < expect.last_rev {
        return Err(Reason::Replayed);
    }
    Ok(Grants {
        perms: payload.perms,
        email: payload.email,
        rev,
        iat: payload.iat,
        exp: payload.exp,
    })
}

/// `If-None-Match` / `ETag` value: `"<rev>-<exp>"` (with the quotes).
pub fn etag(rev: u64, exp: i64) -> String {
    format!("\"{rev}-{exp}\"")
}

/// The `main_sense_grants` answer: `{state, perms, email, rev}`. `checked` is the stored envelope
/// checked again now (`None` = nothing stored); `rejected` is why the last envelope that arrived
/// was refused. Only `ok` carries permissions.
pub fn answer(checked: Option<Result<&Grants, Reason>>, rejected: Option<Reason>) -> Value {
    let closed = |state: &str| json!({ "state": state, "perms": [], "email": "", "rev": 0 });
    match checked {
        Some(Ok(g)) => json!({ "state": "ok", "perms": g.perms, "email": g.email, "rev": g.rev }),
        Some(Err(Reason::Expired)) => closed("expired"),
        Some(Err(_)) => closed("invalid"),
        None => match rejected {
            Some(Reason::Expired) => closed("expired"),
            Some(_) => closed("invalid"),
            None => closed("missing"),
        },
    }
}

/// What a `GET /api/sense/grants` answer means.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// 200 `{grants}`: check and keep it.
    Envelope(Value),
    /// 304: the stored envelope is still current.
    NotModified,
    /// 401 / 403: the key is gone or the person's access was closed — everything off now.
    Revoked,
    /// Network, rate limit, the panel cannot sign (409), an odd answer: keep what is stored (its
    /// own `exp` still ends it) and try again on the next poll.
    Retry,
}

pub fn outcome(status: u16, body: &str) -> Outcome {
    match status {
        200 => serde_json::from_str::<Value>(body)
            .ok()
            .and_then(|v| match v {
                Value::Object(mut map) if map.len() == 1 => map.remove("grants"),
                _ => None,
            })
            .map_or(Outcome::Retry, Outcome::Envelope),
        304 => Outcome::NotModified,
        401 | 403 => Outcome::Revoked,
        _ => Outcome::Retry,
    }
}

/// The e-mail of the signed-in account from `user_info` (`email`, else `name`: the panel puts the
/// full e-mail in `name`).
pub fn session_email(user_info: &str) -> Option<String> {
    let info: Value = serde_json::from_str(user_info).ok()?;
    ["email", "name"]
        .iter()
        .filter_map(|key| info.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(str::to_owned)
}

// ------------------------------------------------------------------ state (not pure)

/// `grants.json`: the last valid envelope of the signed-in person.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct Stored {
    v: u8,
    email: String,
    rev: u64,
    envelope: Value,
}

#[derive(Default)]
struct Memory {
    /// Envelope that came with the sign-in, checked on the next read (outside the sign-in lock).
    pending: Option<(String, Value)>,
    /// Why the last envelope that arrived was refused.
    rejected: Option<Reason>,
}

fn memory() -> &'static Mutex<Memory> {
    static MEMORY: OnceLock<Mutex<Memory>> = OnceLock::new();
    MEMORY.get_or_init(Default::default)
}

/// One fetch at a time (poll thread and focus refresh).
fn fetch_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(Default::default)
}

struct Session {
    token: String,
    email: String,
}

/// `None` when nobody is signed in (or the e-mail is unknown).
fn session() -> Option<Session> {
    let token = LocalConfig::get_option("access_token");
    if token.is_empty() {
        return None;
    }
    let email = session_email(&LocalConfig::get_option("user_info"))?;
    Some(Session { token, email })
}

fn signed_out() -> bool {
    LocalConfig::get_option("access_token").is_empty()
}

fn store_path() -> std::path::PathBuf {
    Config::path(STORE_FILE)
}

fn load() -> Option<Stored> {
    let text = std::fs::read_to_string(store_path()).ok()?;
    serde_json::from_str::<Stored>(&text)
        .ok()
        .filter(|stored| stored.v == 1)
}

fn save(stored: &Stored) {
    let path = store_path();
    let tmp = path.with_extension("json.tmp");
    let result = serde_json::to_vec(stored)
        .map_err(|e| e.to_string())
        .and_then(|bytes| std::fs::write(&tmp, bytes).map_err(|e| e.to_string()))
        .and_then(|_| std::fs::rename(&tmp, &path).map_err(|e| e.to_string()));
    if let Err(err) = result {
        log::warn!("Sense Remote: grants could not be stored: {err}");
    }
}

/// Signing out or another person: the stored envelope and every memory of it go.
fn forget() {
    let path = store_path();
    if path.exists() {
        if let Err(err) = std::fs::remove_file(&path) {
            log::warn!("Sense Remote: grants.json could not be removed: {err}");
        }
    }
    let mut memory = memory().lock().unwrap();
    memory.pending = None;
    memory.rejected = None;
}

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn check(envelope: &Value, email: &str, last_rev: u64) -> Result<Grants, Reason> {
    let iss = super::envelope::expected_issuer();
    let did = crate::ui_interface::get_id();
    let duuid = crate::ui_interface::get_uuid();
    verify(
        envelope,
        envelope_keys::trusted_keys(),
        &Expect {
            iss: &iss,
            did: &did,
            duuid: &duuid,
            email,
            now_s: now_s(),
            last_rev,
        },
    )
}

/// The stored envelope of [email], if any (another person's is removed).
fn stored_for(email: &str) -> Option<Stored> {
    let stored = load()?;
    if stored.email.to_lowercase() == email.to_lowercase() {
        Some(stored)
    } else {
        forget();
        None
    }
}

/// Checks a new envelope and keeps it when valid; a refused one is not kept (the stored one, if
/// still valid, stays) and only its reason is logged, never the envelope.
fn accept(envelope: Value, email: &str) {
    let last_rev = stored_for(email).map_or(0, |stored| stored.rev);
    match check(&envelope, email, last_rev) {
        Ok(grants) => {
            save(&Stored {
                v: 1,
                email: grants.email.clone(),
                rev: grants.rev,
                envelope,
            });
            memory().lock().unwrap().rejected = None;
        }
        Err(reason) => {
            log::warn!("Sense Remote: grants envelope refused: {}", reason.as_str());
            memory().lock().unwrap().rejected = Some(reason);
        }
    }
}

/// Brings the store in line with the sign-in: signed out → forget; an envelope from the sign-in
/// waiting → check it. Returns the session when someone is signed in.
fn sync_session() -> Option<Session> {
    let Some(session) = session() else {
        if signed_out() {
            forget();
        }
        return None;
    };
    let pending = memory().lock().unwrap().pending.take();
    if let Some((email, envelope)) = pending {
        if email.to_lowercase() == session.email.to_lowercase() {
            accept(envelope, &session.email);
        }
    }
    Some(session)
}

/// One `GET /api/sense/grants`.
fn fetch_once(session: &Session) {
    let stored = stored_for(&session.email)
        .and_then(|stored| check(&stored.envelope, &session.email, stored.rev).ok());
    let mut header = serde_json::Map::new();
    header.insert(
        "Authorization".to_owned(),
        Value::String(format!("Bearer {}", session.token)),
    );
    if let Some(grants) = &stored {
        header.insert(
            "If-None-Match".to_owned(),
            Value::String(etag(grants.rev, grants.exp)),
        );
    }
    let url = format!("{}{GRANTS_PATH}", super::api_server());
    let response = match crate::http_request_sync(
        url,
        "GET".to_owned(),
        None,
        Value::Object(header).to_string(),
    ) {
        Ok(response) => response,
        Err(err) => {
            log::debug!("Sense Remote: grants request failed: {err}");
            return;
        }
    };
    let parsed: Option<(u16, String)> = serde_json::from_str::<Value>(&response)
        .ok()
        .and_then(|v| {
            let status = u16::try_from(v.get("status_code")?.as_u64()?).ok()?;
            let body = v.get("body").and_then(Value::as_str).unwrap_or("").to_owned();
            Some((status, body))
        });
    let Some((status, body)) = parsed else {
        return;
    };
    match outcome(status, &body) {
        Outcome::Envelope(envelope) => accept(envelope, &session.email),
        Outcome::NotModified => {}
        Outcome::Revoked => {
            log::info!("Sense Remote: grants refused by the panel ({status}), everything off");
            forget();
        }
        Outcome::Retry => log::debug!("Sense Remote: grants answer {status}, trying later"),
    }
}

/// Asks the panel now; `wait` = wait for a running fetch instead of skipping.
fn refresh(wait: bool) {
    let Some(session) = sync_session() else {
        return;
    };
    let _guard = if wait {
        fetch_lock().lock().unwrap_or_else(|e| e.into_inner())
    } else {
        match fetch_lock().try_lock() {
            Ok(guard) => guard,
            Err(_) => return,
        }
    };
    fetch_once(&session);
}

/// Starts the 10 s poll once per process (the first time the app asks for grants or signs in).
fn ensure_poller() {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let spawned = std::thread::Builder::new()
            .name("sense-grants".to_owned())
            .spawn(|| loop {
                refresh(false);
                std::thread::sleep(POLL_INTERVAL);
            });
        if let Err(err) = spawned {
            log::error!("Sense Remote: grants poll could not start: {err}");
        }
    });
}

/// Called by the sign-in (`hbbs_http/account.rs`) after the token and `user_info` are kept. Only
/// notes the envelope (the sign-in holds a lock); the next read checks and stores it.
pub fn on_sign_in(email: &str, envelope: Option<&Value>) {
    let mut memory = memory().lock().unwrap();
    memory.rejected = None;
    memory.pending = envelope.map(|envelope| (email.trim().to_owned(), envelope.clone()));
}

/// `main_sense_grants`: `{state: "ok" | "missing" | "expired" | "invalid", perms: [..], email,
/// rev}`.
pub fn ffi_grants() -> String {
    ensure_poller();
    let Some(session) = sync_session() else {
        return answer(None, None).to_string();
    };
    let stored = stored_for(&session.email);
    let checked = stored
        .as_ref()
        .map(|stored| check(&stored.envelope, &session.email, stored.rev));
    let rejected = memory().lock().unwrap().rejected;
    answer(checked.as_ref().map(|r| r.as_ref().map_err(|e| *e)), rejected).to_string()
}

/// `main_sense_grants_refresh`: asks the panel at once (`GET /api/sense/grants`), e.g. when the
/// window gets focus or right after signing out (then it only removes the stored envelope).
pub fn ffi_grants_refresh() {
    ensure_poller();
    refresh(true);
}

#[cfg(test)]
#[path = "grants_tests.rs"]
mod tests;
