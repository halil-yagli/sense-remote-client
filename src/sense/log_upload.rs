//! Sense Remote (karar #84, #86): every computer keeps a developer diagnostic record of each
//! connection and sends it to the panel when the connection ends, so the team can read both
//! sides of a connection per computer, whether or not anything went wrong.
//!
//! What is recorded: the Rust log in detail (the log files already run at debug level) plus the
//! Dart / Flutter errors and `debugPrint` lines ([`dart_line`], written into the same log by every
//! window) plus a measurement line every ten seconds on the Controller (`sense-metrics`: fps,
//! speed, codec, path, loss). Nothing is recorded or sent outside a connection.
//!
//! When it sends (only after the panel announced `logs_v1` in the heartbeat answer):
//! 1. a Host desktop connection ends ([`host_started`] / [`host_closed`], from
//!    `src/server/connection.rs`), whatever happened; `conn_no_video` when no frame went out;
//! 2. a Controller session ends ([`controller_started`] / [`controller_ended`], from
//!    `src/client/io_loop.rs`): `session`, `conn_no_video`, or `conn_failed`. The UI process only
//!    tells the `--server` process over the main IPC (see [`SenseLogIpc`]);
//! 3. an update ended in `failed` ([`on_update_state`], from the heartbeat);
//! 4. the panel asked for it (`sense_log_request` in the heartbeat answer, [`on_answer`]).
//!
//! The record of a connection is what the log files got after it started: the `--server` notes
//! the file positions when the connection starts ([`snapshot_offsets`]) and reads from there when
//! it ends. It carries what ties both sides together: this side's session id, the other
//! computer's id, start and end, version, platform, role (`Meta`).
//!
//! Everything below runs in the `--server` process: it is the one that holds the device key
//! (Windows: SYSTEM) and can read the logs of the service profile and of the user profiles. The
//! UI process never sends a path: it only names the peer and the reason, and the `--server`
//! decides what is read.
//!
//! Size: every file at most 1 MB, 2 MB together (a request the panel takes up to 2 MB of text).
//! Everything is **cleaned first** ([`sanitize`]): passwords, tokens, keys, `Authorization`, long
//! secret-looking values, e-mail addresses and user folder names are masked. The body is signed
//! with the device key (`sense-remote/client-log/v1\n`, contract `client-api/client-log.ts`); the
//! signature covers the SHA-256 of every file text. At most 30 connection records and three
//! error-triggered sends per hour per computer (kept in the local config, so a restart loop
//! cannot get past it).
//!
//! Logs can still hold customer computer details (names, addresses): the panel stores them
//! encrypted, shows them to the system administrator only (hidden developer page) and deletes
//! them after 30 days. Nothing here logs a log line, a key or a path of another user.

use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config, log,
    sodiumoxide::{self, crypto::sign},
    tokio,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicI64, Ordering},
        Mutex,
    },
    time::{Duration, SystemTime},
};

/// Domain separation, same bytes as the panel (`CLIENT_LOG_SIGNING_PREFIX`).
pub const PREFIX: &[u8] = b"sense-remote/client-log/v1\n";
const PATH: &str = "/api/sense/logs";
/// `caps` entry of this build (`SENSE_CAPS.logs`).
pub const CAP_LOGS: &str = "logs";
/// `sense_panel_caps` entry the panel announces (`PANEL_CAPS.logsV1`).
pub const PANEL_CAP_LOGS: &str = "logs_v1";
/// Windows and macOS builds send logs (the platforms with a device key and an installer).
pub const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));

/// Contract: every file at most 256 KB, together 1 MB, at most 8 files.
pub const MAX_FILE_BYTES: usize = 1024 * 1024;
pub const MAX_TOTAL_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_FILES: usize = 8;
/// Error-triggered sends (update failed) per computer and hour.
pub const AUTO_PER_HOUR: usize = 3;
/// Session records (one per connection, whatever happened) per computer and hour.
pub const SESSION_PER_HOUR: usize = 30;
const WINDOW_S: i64 = 3600;
/// A panel request that failed is tried again no sooner than this.
const MANUAL_RETRY_S: i64 = 60;
/// Only log files written within this time are read (older ones are not about this problem).
const RECENT_S: u64 = 3 * 86_400;
/// Local config (`--server` process): Unix seconds of the automatic sends in the last hour,
/// comma separated; `ts` of the last request (the panel refuses a `ts` it has seen).
const OPTION_SENT: &str = "sense-log-sent";
const OPTION_SESSIONS: &str = "sense-log-sessions";
const OPTION_TS: &str = "sense-log-ts";
/// User profiles read next to the service profile (Windows).
#[cfg(windows)]
const MAX_PROFILES: usize = 8;
/// A value of this many token characters or more looks like a key or a token.
const LONG_TOKEN_CHARS: usize = 40;

/// The panel announced `logs_v1` in the last heartbeat answer.
static PANEL_LOGS: AtomicBool = AtomicBool::new(false);
/// One send at a time.
static SENDING: AtomicBool = AtomicBool::new(false);
/// Last panel request tried, Unix seconds (retry gap).
static LAST_MANUAL: AtomicI64 = AtomicI64::new(0);
/// Whether the last heartbeat said the update failed (a send happens on the change only).
static UPDATE_FAILED: AtomicBool = AtomicBool::new(false);
/// Serializes the read-modify-write of the local-config options.
static OPTIONS: Mutex<()> = Mutex::new(());

// ---------------------------------------------------------------------------------------------
// Reasons and IPC
// ---------------------------------------------------------------------------------------------

/// Contract `ClientLogReason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// A connection ended (whatever happened): the session record.
    Session,
    Manual,
    ConnNoVideo,
    ConnFailed,
    UpdateFailed,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Session => "session",
            Reason::Manual => "manual",
            Reason::ConnNoVideo => "conn_no_video",
            Reason::ConnFailed => "conn_failed",
            Reason::UpdateFailed => "update_failed",
        }
    }

    /// What the UI process may name when a Controller session ends: the three connection reasons.
    fn from_ipc(name: &str) -> Option<Reason> {
        match name {
            "session" => Some(Reason::Session),
            "conn_no_video" => Some(Reason::ConnNoVideo),
            "conn_failed" => Some(Reason::ConnFailed),
            _ => None,
        }
    }
}

/// `Data::SenseLog` (src/ipc.rs): UI process -> `--server`, no answer. The messages carry no
/// path and no text: the `--server` checks the values and decides what it reads. The Controller
/// session lives in the UI process; the logs and the device key are the `--server`'s, so the UI
/// tells it when a session starts (the log positions are noted then) and when it ends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseLogIpc {
    ControllerStart { sid: String, peer: String },
    ControllerEnd { sid: String, peer: String, reason: String },
}

/// Contract `conn_peer_id`: 1–64 characters; here only the characters an id can have.
pub fn clean_peer(peer: &str) -> Option<String> {
    let peer = peer.trim();
    let ok = !peer.is_empty()
        && peer.len() <= 64
        && peer
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.');
    ok.then(|| peer.to_owned())
}

// ---------------------------------------------------------------------------------------------
// Pure part: cleaning
// ---------------------------------------------------------------------------------------------

fn is_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.'
}

/// Names whose value must not be sent: `password`, `token`, `api_key`, `secretKey`, `key`,
/// `Authorization`, `cookie`, `private-key`, ... Not `keyboard` or `enable-keyboard` (permission
/// options are what the team needs to see).
pub fn is_secret_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    const WORDS: [&str; 20] = [
        "key",
        "keys",
        "pass",
        "pwd",
        "passwd",
        "password",
        "passphrase",
        "token",
        "tokens",
        "secret",
        "secrets",
        "auth",
        "authorization",
        "cookie",
        "credential",
        "credentials",
        "private",
        "sig",
        "signature",
        "otp",
    ];
    if lower
        .split(|c: char| !c.is_ascii_alphanumeric())
        .any(|part| WORDS.contains(&part) || part == "salt" || part == "bearer")
    {
        return true;
    }
    ["key", "token", "password", "passwd", "secret"]
        .iter()
        .any(|suffix| lower.ends_with(suffix))
}

fn is_auth_name(name: &str) -> bool {
    name.to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .any(|part| part == "auth" || part == "authorization" || part == "cookie")
}

/// End of the value that starts at `start` (a quoted value up to its closing quote, otherwise up
/// to a delimiter); `to_eol` takes the whole rest of the line (`Authorization: Bearer x`).
fn value_end(chars: &[char], start: usize, to_eol: bool) -> usize {
    if start >= chars.len() {
        return start;
    }
    if to_eol {
        return chars.len();
    }
    let first = chars[start];
    if first == '"' || first == '\'' {
        let mut k = start + 1;
        while k < chars.len() {
            if chars[k] == '\\' {
                k += 2;
                continue;
            }
            if chars[k] == first {
                return k + 1;
            }
            k += 1;
        }
        return chars.len();
    }
    let mut k = start;
    while k < chars.len()
        && !chars[k].is_whitespace()
        && !matches!(chars[k], ',' | ';' | '&' | ')' | '}' | ']' | '"' | '\'')
    {
        k += 1;
    }
    k
}

/// `name = value` / `name: value` / `"name":"value"` with a secret name: the value becomes `***`.
fn mask_key_values(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == ':' || c == '=' {
            let mut end = i;
            while end > 0 && chars[end - 1] == ' ' {
                end -= 1;
            }
            if end > 0 && (chars[end - 1] == '"' || chars[end - 1] == '\'') {
                end -= 1;
            }
            let mut start = end;
            while start > 0 && is_name_char(chars[start - 1]) {
                start -= 1;
            }
            let name: String = chars[start..end].iter().collect();
            if !name.is_empty() && is_secret_name(&name) {
                out.push(c);
                let mut k = i + 1;
                while k < chars.len() && chars[k] == ' ' {
                    out.push(' ');
                    k += 1;
                }
                if k >= chars.len() {
                    i = k;
                    continue;
                }
                let quote = chars[k];
                let stop = value_end(&chars, k, is_auth_name(&name));
                if (quote == '"' || quote == '\'') && stop > k + 1 && chars[stop - 1] == quote {
                    out.push(quote);
                    out.push_str("***");
                    out.push(quote);
                } else {
                    out.push_str("***");
                }
                i = stop;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// `Bearer <token>` anywhere in the line.
fn mask_bearer(line: &str) -> String {
    let lower = line.to_ascii_lowercase();
    let needle = "bearer ";
    let mut out = String::with_capacity(line.len());
    let mut from = 0;
    while let Some(pos) = lower[from..].find(needle) {
        let at = from + pos;
        let value_start = at + needle.len();
        out.push_str(&line[from..value_start]);
        let rest = &line[value_start..];
        let token_len = rest
            .find(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | '"' | '\''))
            .unwrap_or(rest.len());
        if token_len > 0 {
            out.push_str("***");
        }
        from = value_start + token_len;
    }
    out.push_str(&line[from..]);
    out
}

/// E-mail-like text (`name@host.tld`) becomes `***@***`.
fn mask_emails(line: &str) -> String {
    if !line.contains('@') {
        return line.to_owned();
    }
    let chars: Vec<char> = line.chars().collect();
    let local = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '%' | '+' | '-');
    let domain = |c: char| c.is_ascii_alphanumeric() || c == '.' || c == '-';
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    while i < chars.len() {
        if local(chars[i]) {
            // A run of local-part characters; it is an address when `@domain.tld` follows.
            let mut j = i;
            while j < chars.len() && local(chars[j]) {
                j += 1;
            }
            if j < chars.len() && chars[j] == '@' {
                let mut k = j + 1;
                while k < chars.len() && domain(chars[k]) {
                    k += 1;
                }
                let host: String = chars[j + 1..k].iter().collect();
                let host = host.trim_end_matches('.');
                let tld_ok = host
                    .rsplit_once('.')
                    .is_some_and(|(_, tld)| tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()));
                if tld_ok && !host.starts_with('.') {
                    out.push_str("***@***");
                    i = j + 1 + host.chars().count();
                    continue;
                }
            }
            out.extend(&chars[i..j]);
            i = j;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// A run of [`LONG_TOKEN_CHARS`] base64 / hex characters or more is a key or a token.
fn mask_long_tokens(line: &str) -> String {
    let token = |c: char| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '_' | '-');
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    while i < chars.len() {
        if token(chars[i]) {
            let mut j = i;
            while j < chars.len() && token(chars[j]) {
                j += 1;
            }
            if j - i >= LONG_TOKEN_CHARS {
                out.push_str("[uzun-deger]");
            } else {
                out.extend(&chars[i..j]);
            }
            i = j;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// `C:\Users\Ayse\...` -> `C:\Users\<kullanici>\...` (also `/Users/x/` and `/home/x/`).
fn mask_user_dirs(line: &str) -> String {
    let mut text = line.to_owned();
    for prefix in ["\\users\\", "/users/", "/home/"] {
        let mut out = String::with_capacity(text.len());
        let lower = text.to_ascii_lowercase();
        let mut from = 0;
        while let Some(pos) = lower[from..].find(prefix) {
            let at = from + pos;
            let name_start = at + prefix.len();
            out.push_str(&text[from..name_start]);
            let rest = &text[name_start..];
            let stops: &[char] = &['\\', '/', ' ', '"', '\''];
            let name_len = rest.find(stops).unwrap_or(rest.len());
            let name = &rest[..name_len];
            let keep = name.is_empty()
                || name.starts_with('<')
                || ["public", "default", "all users"].contains(&name.to_ascii_lowercase().as_str());
            if keep {
                out.push_str(name);
            } else {
                out.push_str("<kullanici>");
            }
            from = name_start + name_len;
        }
        out.push_str(&text[from..]);
        text = out;
    }
    text
}

/// The cleaning every line goes through before it leaves the computer.
pub fn sanitize_line(line: &str) -> String {
    let line: String = line
        .chars()
        .map(|c| if c.is_control() && c != '\t' { ' ' } else { c })
        .collect();
    let line = mask_key_values(&line);
    let line = mask_bearer(&line);
    let line = mask_emails(&line);
    let line = mask_long_tokens(&line);
    mask_user_dirs(&line)
}

/// [`sanitize_line`] for a whole text (lines joined with `\n`).
pub fn sanitize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for (n, line) in text.lines().enumerate() {
        if n > 0 {
            out.push('\n');
        }
        out.push_str(&sanitize_line(line));
    }
    if text.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// The last `max` bytes of `bytes` as text, starting at a line start when there is one.
pub fn tail_text(bytes: &[u8], max: usize) -> String {
    if bytes.len() <= max {
        return String::from_utf8_lossy(bytes).into_owned();
    }
    let cut = &bytes[bytes.len() - max..];
    let start = cut.iter().position(|b| *b == b'\n').map_or(0, |p| p + 1);
    let text = String::from_utf8_lossy(&cut[start..]).into_owned();
    text.trim_start_matches('\u{FFFD}').to_owned()
}

/// `text` shortened from the front to at most `max` bytes (at a line start when there is one).
pub fn fit_bytes(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut start = text.len() - max;
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    let cut = &text[start..];
    match cut.find('\n') {
        Some(p) => cut[p + 1..].to_owned(),
        None => cut.to_owned(),
    }
}

// ---------------------------------------------------------------------------------------------
// Pure part: rate limit, signing
// ---------------------------------------------------------------------------------------------

/// The stored automatic-send times.
pub fn parse_sent(value: &str) -> Vec<i64> {
    value
        .split(',')
        .filter_map(|part| part.trim().parse::<i64>().ok())
        .filter(|t| *t > 0)
        .collect()
}

fn recent(sent: &[i64], now: i64) -> Vec<i64> {
    // A time far in the future (clock set back) does not count as "recent" for ever.
    sent.iter()
        .copied()
        .filter(|t| now - *t < WINDOW_S && *t <= now.saturating_add(WINDOW_S))
        .collect()
}

/// At most [`AUTO_PER_HOUR`] automatic sends in the last hour.
pub fn auto_allowed(sent: &[i64], now: i64) -> bool {
    recent(sent, now).len() < AUTO_PER_HOUR
}

/// The list to store after a send at `now` (older entries dropped).
pub fn record_send(sent: &[i64], now: i64) -> Vec<i64> {
    let mut list = recent(sent, now);
    list.push(now);
    list
}

fn join_sent(list: &[i64]) -> String {
    list.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
}

/// One file of the request: a name (`server-sunucu.log`) and its cleaned text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogFile {
    pub name: String,
    pub text: String,
}

/// What ties the request to a connection (contract `ClientLogUpload`): the other computer, this
/// side's own session id, start and end (Unix s), version, platform and role. Every field may be
/// missing; the signature covers all of them (`null` when missing).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Meta {
    pub peer: Option<String>,
    pub session_id: Option<String>,
    pub started: Option<i64>,
    pub ended: Option<i64>,
    pub app_version: Option<u32>,
    pub platform: Option<String>,
    pub role: Option<String>,
}

/// Contract `ClientLogFile.name`: 1–64 characters of `A-Za-z0-9._-`.
pub fn is_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

fn sha256_hex(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// The bytes the device signs: prefix ‖ JCS({id, uuid, ts, reason, conn_peer_id, session_id,
/// started_at, ended_at, app_version, platform, role, files:[{name, sha256}]}); a missing
/// field is `null`.
pub fn signed_bytes(
    id: &str,
    uuid: &str,
    ts: i64,
    reason: &str,
    meta: &Meta,
    files: &[LogFile],
) -> Vec<u8> {
    let mut object = Map::new();
    object.insert("id".to_owned(), json!(id));
    object.insert("uuid".to_owned(), json!(uuid));
    object.insert("ts".to_owned(), json!(ts));
    object.insert("reason".to_owned(), json!(reason));
    object.insert("conn_peer_id".to_owned(), json!(meta.peer));
    object.insert("session_id".to_owned(), json!(meta.session_id));
    object.insert("started_at".to_owned(), json!(meta.started));
    object.insert("ended_at".to_owned(), json!(meta.ended));
    object.insert("app_version".to_owned(), json!(meta.app_version));
    object.insert("platform".to_owned(), json!(meta.platform));
    object.insert("role".to_owned(), json!(meta.role));
    let digests: Vec<Value> = files
        .iter()
        .map(|f| json!({ "name": f.name, "sha256": sha256_hex(&f.text) }))
        .collect();
    object.insert("files".to_owned(), Value::Array(digests));
    let mut bytes = PREFIX.to_vec();
    bytes.extend_from_slice(super::report::canonical_json(&Value::Object(object)).as_bytes());
    bytes
}

/// The request body (`ClientLogUpload`) with its signature; `None` without a usable 64-byte
/// Ed25519 secret key. The key never leaves this call.
pub fn signed_body(
    id: &str,
    uuid: &str,
    ts: i64,
    reason: &str,
    meta: &Meta,
    files: &[LogFile],
    secret_key: &[u8],
) -> Option<Value> {
    let secret_key = sign::SecretKey::from_slice(secret_key)?;
    sodiumoxide::init().ok()?;
    let signature = sign::sign_detached(&signed_bytes(id, uuid, ts, reason, meta, files), &secret_key);
    let mut body = Map::new();
    body.insert("id".to_owned(), json!(id));
    body.insert("uuid".to_owned(), json!(uuid));
    body.insert("ts".to_owned(), json!(ts));
    body.insert("reason".to_owned(), json!(reason));
    // Fields the computer has not got are left out (the panel's schema takes them as optional).
    let put = |body: &mut Map<String, Value>, name: &str, value: Value| {
        if !value.is_null() {
            body.insert(name.to_owned(), value);
        }
    };
    put(&mut body, "conn_peer_id", json!(meta.peer));
    put(&mut body, "session_id", json!(meta.session_id));
    put(&mut body, "started_at", json!(meta.started));
    put(&mut body, "ended_at", json!(meta.ended));
    put(&mut body, "app_version", json!(meta.app_version));
    put(&mut body, "platform", json!(meta.platform));
    put(&mut body, "role", json!(meta.role));
    let list: Vec<Value> = files
        .iter()
        .map(|f| json!({ "name": f.name, "text": f.text }))
        .collect();
    body.insert("files".to_owned(), Value::Array(list));
    body.insert("sig".to_owned(), json!(URL_SAFE_NO_PAD.encode(signature.to_bytes())));
    Some(Value::Object(body))
}

/// Per-file byte budget for `count` files: 1 MB, less when 2 MB would not hold them.
pub fn per_file_budget(count: usize) -> usize {
    MAX_FILE_BYTES.min(MAX_TOTAL_BYTES / count.max(1))
}

// ---------------------------------------------------------------------------------------------
// Reading the log files (`--server`)
// ---------------------------------------------------------------------------------------------

/// Where each kind of log lives under a profile's log directory (`core_main`: the directory is
/// named after the first command-line switch; the main UI writes into the directory itself).
/// Dart errors and `debugPrint` lines are written into these same files by `dart_line`, as
/// lines with the `dart` target, by whichever process the Flutter window runs in.
const SOURCES: [(&str, &str); 9] = [
    ("server", "server"),
    ("service", "service"),
    ("cm", "cm"),
    ("ui", ""),
    ("flutter", "flutter_ffi"),
    ("window", "multi-window"),
    ("connect", "connect"),
    ("tray", "tray"),
    ("update", "sense-update-guard"),
];

/// Log file positions at one moment (`path -> length`): a session reads what was written after.
pub type Offsets = HashMap<PathBuf, u64>;

/// A real directory, not a link (a link in a folder a user can write would send this process
/// somewhere else).
fn is_plain_dir(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|m| m.is_dir() && !m.file_type().is_symlink())
        .unwrap_or(false)
}

/// The newest `.log` files of `dir` (written within [`RECENT_S`]), newest first.
fn recent_log_files(dir: &Path, now: SystemTime) -> Vec<(PathBuf, u64)> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<(PathBuf, SystemTime, u64)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("log") {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() || meta.file_type().is_symlink() {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        let age = now.duration_since(modified).unwrap_or(Duration::ZERO);
        if age.as_secs() > RECENT_S {
            continue;
        }
        files.push((path, modified, meta.len()));
    }
    files.sort_by(|a, b| b.1.cmp(&a.1));
    files.into_iter().map(|(path, _, len)| (path, len)).collect()
}

/// The last `max` bytes of a file.
fn read_tail(path: &Path, len: u64, max: usize) -> Option<Vec<u8>> {
    let mut file = fs::File::open(path).ok()?;
    let start = len.saturating_sub(max as u64);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    file.take(max as u64).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// Recent text of a log directory, oldest line first, at most `budget` bytes: the newest file's
/// tail, and when it is short (the log just rotated) the end of the one before. With `since`
/// only what was written after those positions is read (a file the positions do not know, or
/// that is shorter than before, is read from its start).
fn read_recent(dir: &Path, budget: usize, now: SystemTime, since: Option<&Offsets>) -> Option<String> {
    if !is_plain_dir(dir) {
        return None;
    }
    let mut chunks: Vec<String> = Vec::new();
    let mut remaining = budget;
    for (path, len) in recent_log_files(dir, now) {
        if remaining == 0 {
            break;
        }
        let from = since
            .and_then(|offsets| offsets.get(&path).copied())
            .filter(|offset| *offset <= len)
            .unwrap_or(0);
        let span = (len - from) as usize;
        if span == 0 {
            continue;
        }
        // One byte more than the budget: a longer span is cut, and `tail_text` then moves the
        // cut to a line start.
        let Some(bytes) = read_tail(&path, len, span.min(remaining + 1)) else {
            continue;
        };
        let text = tail_text(&bytes, remaining);
        remaining = remaining.saturating_sub(text.len());
        if !text.trim().is_empty() {
            chunks.push(text);
        }
    }
    if chunks.is_empty() {
        return None;
    }
    chunks.reverse();
    Some(chunks.join("\n"))
}

/// `(tag, log directory)` of every profile this process may read: its own, and on Windows the
/// user profiles (the service reads what the UI processes write).
fn log_roots() -> Vec<(String, PathBuf)> {
    let own = config::Config::log_path();
    #[allow(unused_mut)]
    let mut roots = vec![("sunucu".to_owned(), own.clone())];
    #[cfg(windows)]
    {
        let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned());
        let users = PathBuf::from(format!("{drive}\\Users"));
        let app = hbb_common::config::APP_NAME.read().unwrap().clone();
        let mut found = 0;
        if let Ok(entries) = fs::read_dir(&users) {
            for entry in entries.flatten() {
                if found >= MAX_PROFILES {
                    break;
                }
                let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
                if ["public", "default", "default user", "all users"].contains(&name.as_str()) {
                    continue;
                }
                let dir = entry.path().join("AppData").join("Roaming").join(&app).join("log");
                if dir == own || !is_plain_dir(&entry.path()) {
                    continue;
                }
                found += 1;
                roots.push((format!("kullanici{found}"), dir));
            }
        }
    }
    roots
}

/// The directories to read, `(file name, directory)`, most useful first (a kind of log in every
/// profile before the next kind), within the first [`MAX_FILES`].
fn log_dirs() -> Vec<(String, PathBuf)> {
    let roots = log_roots();
    let mut dirs = Vec::new();
    for (label, sub) in SOURCES {
        for (tag, root) in &roots {
            let dir = if sub.is_empty() { root.clone() } else { root.join(sub) };
            dirs.push((format!("{label}-{tag}.log"), dir));
        }
    }
    dirs
}

/// Where every log file is now (a session started): the session later reads what came after.
pub fn snapshot_offsets(now: SystemTime) -> Offsets {
    let mut offsets = Offsets::new();
    for (_, dir) in log_dirs() {
        if !is_plain_dir(&dir) {
            continue;
        }
        for (path, len) in recent_log_files(&dir, now) {
            offsets.insert(path, len);
        }
    }
    offsets
}

/// The files of this request: cleaned, within the budgets, at most [`MAX_FILES`]. With `since`
/// only what was written after a session started.
pub fn collect_files(now: SystemTime, since: Option<&Offsets>) -> Vec<LogFile> {
    let mut raw: Vec<(String, String)> = Vec::new();
    for (name, dir) in log_dirs() {
        if raw.len() >= MAX_FILES {
            break;
        }
        if let Some(text) = read_recent(&dir, MAX_FILE_BYTES, now, since) {
            raw.push((name, text));
        }
    }
    let budget = per_file_budget(raw.len());
    raw.into_iter()
        .map(|(name, text)| LogFile {
            name,
            text: fit_bytes(&sanitize(&text), budget),
        })
        .filter(|file| is_file_name(&file.name) && !file.text.trim().is_empty())
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Sessions (`--server`)
// ---------------------------------------------------------------------------------------------

/// One connection being recorded: the other computer, when it started, which role this
/// computer had and where the log files were then.
struct Session {
    peer: Option<String>,
    started_s: i64,
    role: Option<String>,
    offsets: Offsets,
}

static SESSIONS: Mutex<Option<HashMap<String, Session>>> = Mutex::new(None);
/// Most sessions open at once (a leftover entry is dropped, oldest first).
const MAX_SESSIONS: usize = 32;

/// The connection key of a Host connection (its connection id) and of a Controller session
/// (the id the UI process made): separate name spaces.
fn host_key(conn_id: i32) -> String {
    format!("h{conn_id}")
}

fn controller_key(sid: &str) -> String {
    format!("c{sid}")
}

/// This computer's role as the contract names it.
fn own_role() -> Option<String> {
    super::installed_role().map(|role| role.as_str().to_owned())
}

/// `windows-x64` / `macos-arm64` like the release platforms; anything else `linux`.
pub fn platform_name() -> &'static str {
    if cfg!(windows) {
        "windows-x64"
    } else if cfg!(target_os = "macos") {
        "macos-arm64"
    } else {
        "linux"
    }
}

fn session_started(key: String, peer: Option<String>) {
    if !SUPPORTED || !PANEL_LOGS.load(Ordering::Relaxed) {
        return;
    }
    let now = SystemTime::now();
    let session = Session {
        peer,
        started_s: now_s(),
        role: own_role(),
        offsets: snapshot_offsets(now),
    };
    let mut guard = SESSIONS.lock().unwrap_or_else(|e| e.into_inner());
    let map = guard.get_or_insert_with(HashMap::new);
    if map.len() >= MAX_SESSIONS {
        if let Some(oldest) = map
            .iter()
            .min_by_key(|(_, s)| s.started_s)
            .map(|(key, _)| key.clone())
        {
            map.remove(&oldest);
        }
    }
    map.insert(key, session);
}

/// The connection is over: its record (the logs written since it started) goes to the panel.
/// A session whose start was not noted (the panel did not take logs then) sends nothing.
fn session_ended(key: &str, reason: Reason, peer: Option<String>) {
    let session = SESSIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .and_then(|map| map.remove(key));
    let Some(session) = session else {
        return;
    };
    if !SUPPORTED || !PANEL_LOGS.load(Ordering::Relaxed) {
        return;
    }
    let ended = now_s();
    let meta = Meta {
        peer: peer.or(session.peer),
        session_id: Some(key.to_owned()),
        started: Some(session.started_s),
        ended: Some(ended.max(session.started_s)),
        app_version: Some(super::update::current_version()),
        platform: Some(platform_name().to_owned()),
        role: session.role,
    };
    let offsets = session.offsets;
    let spawned = std::thread::Builder::new()
        .name("sense-log-upload".to_owned())
        .spawn(move || {
            if take_slot(OPTION_SESSIONS, SESSION_PER_HOUR, now_s()) {
                send_blocking(reason, meta, Some(&offsets));
            } else {
                log::info!("Sense Remote: session log skipped, {SESSION_PER_HOUR} an hour is the limit");
            }
        });
    if let Err(err) = spawned {
        log::warn!("Sense Remote: session log not started: {err}");
    }
}

// ---------------------------------------------------------------------------------------------
// Sending (`--server`)
// ---------------------------------------------------------------------------------------------

fn now_s() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Takes one of the hour's slots of the limiter kept under `option` (stored before sending, so a
/// crash loop is counted).
fn take_slot(option: &str, per_hour: usize, now: i64) -> bool {
    let _lock = OPTIONS.lock().unwrap_or_else(|e| e.into_inner());
    let sent = parse_sent(&config::LocalConfig::get_option(option));
    if recent(&sent, now).len() >= per_hour {
        return false;
    }
    config::LocalConfig::set_option(option.to_owned(), join_sent(&record_send(&sent, now)));
    true
}

/// `ts` of the next request: the clock, always above the last one sent.
fn next_ts() -> i64 {
    let _lock = OPTIONS.lock().unwrap_or_else(|e| e.into_inner());
    let last = super::report_sig::parse_reservation(&config::LocalConfig::get_option(OPTION_TS));
    let ts = super::report_sig::next_ts(last, now_s());
    config::LocalConfig::set_option(OPTION_TS.to_owned(), ts.to_string());
    ts
}

struct Flight;

impl Flight {
    fn begin() -> Option<Flight> {
        (!SENDING.swap(true, Ordering::SeqCst)).then_some(Flight)
    }
}

impl Drop for Flight {
    fn drop(&mut self) {
        SENDING.store(false, Ordering::SeqCst);
    }
}

/// Read, clean, sign and send. Blocking; runs on its own thread. Sessions of two connections
/// that end together wait for each other (one send at a time).
fn send_blocking(reason: Reason, meta: Meta, since: Option<&Offsets>) {
    let mut flight = Flight::begin();
    for _ in 0..30 {
        if flight.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
        flight = Flight::begin();
    }
    let Some(_flight) = flight else {
        return;
    };
    let files = collect_files(SystemTime::now(), since);
    if files.is_empty() {
        log::info!("Sense Remote: no log to send ({})", reason.as_str());
        return;
    }
    let id = config::Config::get_id();
    let uuid = crate::encode64(hbb_common::get_uuid());
    let (secret_key, _) = config::Config::get_key_pair();
    let ts = next_ts();
    let Some(body) = signed_body(&id, &uuid, ts, reason.as_str(), &meta, &files, &secret_key) else {
        log::warn!("Sense Remote: logs not sent, no device key");
        return;
    };
    let url = format!("{}{PATH}", super::api_server());
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(err) => {
            log::warn!("Sense Remote: logs not sent, no runtime: {err}");
            return;
        }
    };
    let answer = runtime.block_on(crate::common::post_request_with_status(url, body.to_string(), ""));
    // Only the outcome: never a log line, a key or a path.
    match answer {
        Ok((200, _)) => log::info!(
            "Sense Remote: {} log file(s) sent to the panel ({})",
            files.len(),
            reason.as_str()
        ),
        Ok((status, _)) => log::warn!("Sense Remote: logs not taken by the panel (status {status})"),
        Err(_) => log::warn!("Sense Remote: logs not sent, the panel is not reachable"),
    }
}

/// An error-triggered send (`--server` process): the panel takes logs, the hour's slots are not
/// used up. Never blocks the caller.
pub fn trigger_auto(reason: Reason, peer: Option<String>) {
    if !SUPPORTED || !PANEL_LOGS.load(Ordering::Relaxed) || reason == Reason::Manual {
        return;
    }
    let meta = Meta {
        peer,
        started: Some(now_s()),
        ended: Some(now_s()),
        app_version: Some(super::update::current_version()),
        platform: Some(platform_name().to_owned()),
        role: own_role(),
        ..Meta::default()
    };
    let spawned = std::thread::Builder::new()
        .name("sense-log-upload".to_owned())
        .spawn(move || {
            if take_slot(OPTION_SENT, AUTO_PER_HOUR, now_s()) {
                send_blocking(reason, meta, None);
            } else {
                log::info!("Sense Remote: log send skipped, {AUTO_PER_HOUR} an hour is the limit");
            }
        });
    if let Err(err) = spawned {
        log::warn!("Sense Remote: log send not started: {err}");
    }
}

/// The panel asked for the log (`sense_log_request`). Not counted in the hour's slots (the panel
/// limits it); a failed try is repeated no sooner than [`MANUAL_RETRY_S`].
fn trigger_manual() {
    if !SUPPORTED || !PANEL_LOGS.load(Ordering::Relaxed) || SENDING.load(Ordering::SeqCst) {
        return;
    }
    let now = now_s();
    if now - LAST_MANUAL.load(Ordering::SeqCst) < MANUAL_RETRY_S {
        return;
    }
    LAST_MANUAL.store(now, Ordering::SeqCst);
    let meta = Meta {
        started: Some(now),
        ended: Some(now),
        app_version: Some(super::update::current_version()),
        platform: Some(platform_name().to_owned()),
        role: own_role(),
        ..Meta::default()
    };
    let spawned = std::thread::Builder::new()
        .name("sense-log-upload".to_owned())
        .spawn(move || send_blocking(Reason::Manual, meta, None));
    if let Err(err) = spawned {
        log::warn!("Sense Remote: log send not started: {err}");
    }
}

// ---------------------------------------------------------------------------------------------
// Call points
// ---------------------------------------------------------------------------------------------

/// Whether the panel announced `logs_v1`. Same rule as `health_v2::panel_takes_v2`.
pub fn panel_takes_logs(caps: Option<&[String]>) -> bool {
    caps.is_some_and(|caps| caps.iter().any(|cap| cap == PANEL_CAP_LOGS))
}

/// Every parsed heartbeat answer (`hbbs_http/sync.rs`): the panel's capabilities and its request.
pub fn on_answer(panel_caps: Option<&[String]>, log_request: bool) {
    let on = panel_takes_logs(panel_caps);
    if PANEL_LOGS.swap(on, Ordering::Relaxed) != on {
        log::info!("Sense Remote: panel logs_v1 {}", if on { "on" } else { "off" });
    }
    if on && log_request {
        trigger_manual();
    }
}

/// A Host desktop connection was authorized (`src/server/connection.rs`): its record starts.
pub fn host_started(conn_id: i32, peer_id: &str) {
    session_started(host_key(conn_id), clean_peer(peer_id));
}

/// A Host connection closed: `remote` = an authorized desktop connection (not file transfer,
/// port forward, terminal), `video_sent` = a video frame went out. Every desktop connection
/// leaves its record; one that closed without a frame is marked `conn_no_video`.
pub fn host_closed(conn_id: i32, remote: bool, video_sent: bool, peer_id: &str) {
    if !remote {
        return;
    }
    let reason = if video_sent { Reason::Session } else { Reason::ConnNoVideo };
    session_ended(&host_key(conn_id), reason, clean_peer(peer_id));
}

/// Every heartbeat (`update::extend_heartbeat`): the send happens when the update turns `failed`.
pub fn on_update_state(failed: bool) {
    if failed {
        if !UPDATE_FAILED.swap(true, Ordering::SeqCst) {
            trigger_auto(Reason::UpdateFailed, None);
        }
    } else {
        UPDATE_FAILED.store(false, Ordering::SeqCst);
    }
}

/// UI process (`src/client/io_loop.rs`): a Controller session starts. Returns the session id the
/// end call needs; tells the `--server` process (which notes the log positions). Never blocks,
/// never sends a path.
pub fn controller_started(peer_id: &str) -> Option<String> {
    if !SUPPORTED {
        return None;
    }
    let peer = clean_peer(peer_id)?;
    static COUNTER: AtomicI64 = AtomicI64::new(0);
    let sid = format!("{}-{}", now_s(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let message = SenseLogIpc::ControllerStart {
        sid: sid.clone(),
        peer,
    };
    send_in_thread(message);
    Some(sid)
}

/// UI process: the Controller session `sid` ended for `reason` (`session`, `conn_no_video` or
/// `conn_failed`).
pub fn controller_ended(sid: &str, reason: Reason, peer_id: &str) {
    if !SUPPORTED || !matches!(reason, Reason::Session | Reason::ConnNoVideo | Reason::ConnFailed) {
        return;
    }
    let Some(peer) = clean_peer(peer_id) else {
        return;
    };
    send_in_thread(SenseLogIpc::ControllerEnd {
        sid: sid.to_owned(),
        peer,
        reason: reason.as_str().to_owned(),
    });
}

fn send_in_thread(message: SenseLogIpc) {
    let _ = std::thread::Builder::new()
        .name("sense-log-ipc".to_owned())
        .spawn(move || send_to_server(message));
}

/// UI -> `--server`. Windows: only the SYSTEM-owned main pipe (the service's `--server`), as for
/// the identity requests; macOS: the user `--server`.
#[tokio::main(flavor = "current_thread")]
async fn send_to_server(message: SenseLogIpc) {
    #[cfg(windows)]
    let mut conn = match crate::ipc::connect_main_system(1_000).await {
        Ok(conn) => conn,
        Err(err) => {
            log::debug!("Sense Remote: the main IPC is not served by the service: {err}");
            return;
        }
    };
    #[cfg(not(windows))]
    let Ok(mut conn) = crate::ipc::connect(1_000, "").await else {
        return;
    };
    let _ = conn.send(&crate::ipc::Data::SenseLog(message)).await;
}

/// Main IPC handler (`ipc::handle`): acts only in the `--server` process, only on clean ids and
/// the three connection reasons. No answer.
pub fn on_main_ipc(message: SenseLogIpc) {
    if !crate::is_server() {
        return;
    }
    match message {
        SenseLogIpc::ControllerStart { sid, peer } => {
            let (Some(sid), Some(peer)) = (clean_peer(&sid), clean_peer(&peer)) else {
                return;
            };
            session_started(controller_key(&sid), Some(peer));
        }
        SenseLogIpc::ControllerEnd { sid, peer, reason } => {
            let (Some(sid), Some(peer), Some(reason)) =
                (clean_peer(&sid), clean_peer(&peer), Reason::from_ipc(&reason))
            else {
                return;
            };
            session_ended(&controller_key(&sid), reason, Some(peer));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Dart lines
// ---------------------------------------------------------------------------------------------

/// Lines a window may send per second (a runaway `debugPrint` loop must not fill the disk).
const DART_LINES_PER_S: u32 = 300;
static DART_WINDOW: Mutex<(i64, u32)> = Mutex::new((0, 0));

fn dart_line_allowed(now: i64) -> bool {
    let mut window = DART_WINDOW.lock().unwrap_or_else(|e| e.into_inner());
    if window.0 != now {
        *window = (now, 0);
    }
    window.1 += 1;
    window.1 <= DART_LINES_PER_S
}

/// `main_sense_dart_log` (FFI): a Dart error or `debugPrint` line goes into this process's Rust
/// log, which is where the session record reads it from. `level` is `error`, `warn` or anything
/// else (debug). At most 4000 characters per line.
pub fn dart_line(level: &str, line: &str) {
    if !dart_line_allowed(now_s()) {
        return;
    }
    let line: String = line.chars().take(4000).collect();
    match level {
        "error" => log::error!(target: "dart", "{line}"),
        "warn" => log::warn!(target: "dart", "{line}"),
        _ => log::debug!(target: "dart", "{line}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verify(pk: &str, bytes: &[u8], sig: &str) -> bool {
        let pk = sign::PublicKey::from_slice(&URL_SAFE_NO_PAD.decode(pk).unwrap()).unwrap();
        let Ok(sig) = URL_SAFE_NO_PAD.decode(sig) else {
            return false;
        };
        let Ok(sig) = sign::Signature::from_bytes(&sig) else {
            return false;
        };
        sign::verify_detached(&sig, bytes, &pk)
    }

    // ---- cleaning ----

    #[test]
    fn passwords_tokens_and_keys_are_masked() {
        let cases = [
            ("login with password=hunter2 ok", "login with password=*** ok"),
            ("password: hunter2", "password: ***"),
            ("Password = \"hunter two\" end", "Password = \"***\" end"),
            (r#"{"password":"abc","user":"x"}"#, r#"{"password":"***","user":"x"}"#),
            ("token=abc123def, next=1", "token=***, next=1"),
            ("api_key=XYZ&other=1", "api_key=***&other=1"),
            ("secretKey: S3CR3T", "secretKey: ***"),
            ("key=abcd", "key=***"),
            ("Authorization: Bearer abc.def.ghi", "Authorization: ***"),
            ("authorization=Basic Zm9vOmJhcg==", "authorization=***"),
            ("Cookie: a=1; b=2", "Cookie: ***"),
            ("sent header bearer abc123 done", "sent header bearer *** done"),
            ("permanent-password=Y1", "permanent-password=***"),
        ];
        for (input, want) in cases {
            assert_eq!(sanitize_line(input), want, "{input}");
        }
    }

    #[test]
    fn permission_options_and_plain_words_stay() {
        for line in [
            "enable-keyboard=Y",
            "enable-file-transfer: N",
            "access-mode = full",
            "keyboard layout changed",
            "wrong password", // a word, no value
            "connected to 192.168.1.20:21116 in 12 ms",
            "time 12:30:45 role=host version=4",
            "update state=failed error=download_failed",
            "peer id 123456789 uuid 0b2c4d6e-1111-4222-8333-444455556666",
        ] {
            assert_eq!(sanitize_line(line), line, "{line}");
        }
    }

    #[test]
    fn secret_names() {
        for name in [
            "password", "Password", "api_key", "apiKey", "secret_key", "token", "access-token",
            "key", "private-key", "Authorization", "cookie", "otp", "sig", "salt", "client_secret",
        ] {
            assert!(is_secret_name(name), "{name}");
        }
        for name in ["keyboard", "enable-keyboard", "monkeyish", "version", "role", "error"] {
            assert!(!is_secret_name(name), "{name}");
        }
    }

    #[test]
    fn emails_are_masked() {
        assert_eq!(
            sanitize_line("login ayse.yilmaz+x@sensedepartment.com ok"),
            "login ***@*** ok"
        );
        assert_eq!(sanitize_line("a@b.cc and c_d@e-f.org."), "***@*** and ***@***.");
        // Not an address: no domain dot, no letters after it, or only an "@".
        for line in ["user@localhost", "@handle", "a@b.1", "mail me @ noon", "x@.com"] {
            assert_eq!(sanitize_line(line), line, "{line}");
        }
    }

    #[test]
    fn long_secret_looking_values_are_masked() {
        let key = "A".repeat(43);
        assert_eq!(sanitize_line(&format!("pk {key} done")), "pk [uzun-deger] done");
        let hex64 = "0123456789abcdef".repeat(4);
        assert_eq!(sanitize_line(&hex64), "[uzun-deger]");
        // 39 characters stay.
        let short = "B".repeat(39);
        assert_eq!(sanitize_line(&short), short);
    }

    #[test]
    fn user_names_in_paths_are_masked() {
        assert_eq!(
            sanitize_line(r"opened C:\Users\Ayse Y\AppData\Roaming\SenseRemote\log"),
            r"opened C:\Users\<kullanici> Y\AppData\Roaming\SenseRemote\log"
        );
        assert_eq!(
            sanitize_line(r"C:\Users\ayse\AppData\x and /Users/mehmet/Library/Logs and /home/ece/.config"),
            r"C:\Users\<kullanici>\AppData\x and /Users/<kullanici>/Library/Logs and /home/<kullanici>/.config"
        );
        assert_eq!(sanitize_line(r"C:\Users\Public\x"), r"C:\Users\Public\x");
    }

    #[test]
    fn control_characters_go_but_tabs_and_newlines_stay() {
        assert_eq!(sanitize("a\u{0}b\tc\r\nd\n"), "a b\tc\nd\n");
    }

    #[test]
    fn nothing_secret_survives_a_realistic_block() {
        let text = "\
[2026-11-24 10:00:00] login ok user=ayse@sensedepartment.com password=hunter2
POST /api/heartbeat Authorization: Bearer eyJhbGciOiJFZERTQSJ9.payload.signature
device key: pk=zZ0aQ9ZXq1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6A7B8
config option permanent-password=Abc12345 and api-key=1234
connected peer 123456789
";
        let out = sanitize(text);
        for secret in ["hunter2", "ayse@", "eyJhbGci", "zZ0aQ9", "Abc12345", "1234\n", "payload"] {
            assert!(!out.contains(secret), "{secret} in {out}");
        }
        assert!(out.contains("connected peer 123456789"));
        assert!(out.contains("POST /api/heartbeat"));
    }

    // ---- sizes ----

    #[test]
    fn tail_starts_at_a_line_and_fits() {
        let text = "line one\nline two\nline three\n";
        assert_eq!(tail_text(text.as_bytes(), 1000), text);
        let tail = tail_text(text.as_bytes(), 20);
        assert_eq!(tail, "line three\n");
        // No newline in the window: the window itself.
        assert_eq!(tail_text(b"abcdefghij", 4), "ghij");
        // A cut inside a multi-byte character leaves no broken character.
        let tail = tail_text("ş\nçç".as_bytes(), 3);
        assert!(!tail.contains('\u{FFFD}'));
    }

    #[test]
    fn fit_bytes_keeps_the_end_on_a_line_start() {
        let text = "aaaa\nbbbb\ncccc\n";
        assert_eq!(fit_bytes(text, 100), text);
        assert_eq!(fit_bytes(text, 10), "cccc\n");
        assert!(fit_bytes(&"ş".repeat(100), 51).len() <= 51);
        assert!(fit_bytes(&"x".repeat(1000), 10).len() <= 10);
    }

    #[test]
    fn budgets_follow_the_contract() {
        assert_eq!(per_file_budget(0), MAX_FILE_BYTES);
        assert_eq!(per_file_budget(1), MAX_FILE_BYTES);
        assert_eq!(per_file_budget(2), MAX_FILE_BYTES);
        assert_eq!(per_file_budget(4), MAX_TOTAL_BYTES / 4);
        assert_eq!(per_file_budget(8), MAX_TOTAL_BYTES / 8);
        for count in 1..=MAX_FILES {
            assert!(per_file_budget(count) * count <= MAX_TOTAL_BYTES);
        }
    }

    #[test]
    fn file_and_peer_names() {
        assert!(is_file_name("server-sunucu.log"));
        assert!(is_file_name("ui-kullanici2.log"));
        let long = "a".repeat(65);
        for bad in ["", "../x", "a b", "ş.log", long.as_str()] {
            assert!(!is_file_name(bad), "{bad}");
        }
        assert_eq!(clean_peer(" 123456789 "), Some("123456789".to_owned()));
        assert_eq!(clean_peer("a-b_c.d"), Some("a-b_c.d".to_owned()));
        let long = "1".repeat(65);
        for bad in ["", "   ", "a b", "x\ny", "../x", long.as_str()] {
            assert_eq!(clean_peer(bad), None, "{bad}");
        }
    }

    // ---- rate limit ----

    #[test]
    fn three_automatic_sends_an_hour() {
        let now = 1_795_000_000;
        let mut sent = Vec::new();
        for n in 0..AUTO_PER_HOUR as i64 {
            assert!(auto_allowed(&sent, now + n));
            sent = record_send(&sent, now + n);
        }
        assert!(!auto_allowed(&sent, now + 10));
        assert!(!auto_allowed(&sent, now + WINDOW_S - 1));
        // The first one leaves the window: one slot is free again.
        assert!(auto_allowed(&sent, now + WINDOW_S));
        let after = record_send(&sent, now + WINDOW_S);
        assert_eq!(after.len(), AUTO_PER_HOUR);
        assert!(!after.contains(&now));
    }

    #[test]
    fn stored_times_round_trip_and_junk_is_dropped() {
        let list = vec![1_795_000_000, 1_795_000_100];
        assert_eq!(parse_sent(&join_sent(&list)), list);
        assert_eq!(parse_sent("x, ,0,-5,1795000000"), vec![1_795_000_000]);
        assert!(parse_sent("").is_empty());
        // A time far ahead (clock changed) does not block for ever.
        let now = 1_795_000_000;
        assert!(auto_allowed(&[now + 10 * WINDOW_S; 5], now));
    }

    // ---- request body ----

    fn peer(id: &str) -> Meta {
        Meta {
            peer: Some(id.to_owned()),
            ..Meta::default()
        }
    }

    fn files() -> Vec<LogFile> {
        vec![
            LogFile { name: "server-sunucu.log".to_owned(), text: "line \"1\"\nş\n".to_owned() },
            LogFile { name: "cm-kullanici1.log".to_owned(), text: String::new() },
        ]
    }

    #[test]
    fn signed_bytes_are_the_documented_object() {
        let bytes = signed_bytes("123456789", "dXVpZA", 1_795_000_000, "conn_failed", &peer("987654321"), &files());
        let text = String::from_utf8(bytes).unwrap();
        let rest = text.strip_prefix("sense-remote/client-log/v1\n").unwrap();
        let object: Value = serde_json::from_str(rest).unwrap();
        assert_eq!(object["id"], "123456789");
        assert_eq!(object["reason"], "conn_failed");
        assert_eq!(object["conn_peer_id"], "987654321");
        assert_eq!(object["files"][0]["name"], "server-sunucu.log");
        assert_eq!(object["files"][0]["sha256"], sha256_hex("line \"1\"\nş\n"));
        // Keys sorted, no spaces (JCS), and the text itself is not in the signed bytes.
        assert!(rest.starts_with("{\"app_version\":null,\"conn_peer_id\":"));
        assert!(!rest.contains("line"));
        // No peer: null.
        let none = signed_bytes("1", "u", 1, "manual", &Meta::default(), &[]);
        let none = String::from_utf8(none).unwrap();
        assert!(none.contains("\"conn_peer_id\":null"));
        assert!(none.contains("\"files\":[]"));
    }

    #[test]
    fn sha256_is_the_known_digest() {
        assert_eq!(
            sha256_hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn signed_body_verifies_with_the_device_key() {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        let body = signed_body("123456789", "dXVpZA", 1_795_000_000, "conn_no_video", &peer("987654321"), &files(), &sk.0)
            .unwrap();
        let keys: Vec<&String> = body.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 7);
        for key in ["id", "uuid", "ts", "reason", "conn_peer_id", "files", "sig"] {
            assert!(body.get(key).is_some(), "{key}");
        }
        assert_eq!(body["files"][0]["text"], "line \"1\"\nş\n");
        assert_eq!(body["files"][0].as_object().unwrap().len(), 2);
        let sig = body["sig"].as_str().unwrap();
        assert_eq!(sig.len(), 86);
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let good = signed_bytes("123456789", "dXVpZA", 1_795_000_000, "conn_no_video", &peer("987654321"), &files());
        assert!(verify(&pk, &good, sig));
        // Another text, reason, peer or time: the signature no longer holds.
        let mut changed = files();
        changed[0].text.push('x');
        for other in [
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "conn_no_video", &peer("987654321"), &changed),
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "conn_failed", &peer("987654321"), &files()),
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "conn_no_video", &Meta::default(), &files()),
            signed_bytes("123456789", "dXVpZA", 1_795_000_001, "conn_no_video", &peer("987654321"), &files()),
        ] {
            assert!(!verify(&pk, &other, sig));
        }
        // No peer: the field is left out (the panel's schema is strict about unknown names only).
        let body = signed_body("1", "u", 1, "manual", &Meta::default(), &[], &sk.0).unwrap();
        assert!(body.get("conn_peer_id").is_none());
        // No key, no body.
        assert_eq!(signed_body("1", "u", 1, "manual", &Meta::default(), &[], &[]), None);
        assert_eq!(signed_body("1", "u", 1, "manual", &Meta::default(), &[], &[0u8; 32]), None);
    }

    // ---- gates ----

    #[test]
    fn panel_capability() {
        assert!(panel_takes_logs(Some(&["health_v2".to_owned(), "logs_v1".to_owned()])));
        assert!(!panel_takes_logs(Some(&["health_v2".to_owned()])));
        assert!(!panel_takes_logs(Some(&[])));
        assert!(!panel_takes_logs(None));
    }

    #[test]
    fn ipc_takes_only_the_three_connection_reasons() {
        assert_eq!(Reason::from_ipc("session"), Some(Reason::Session));
        assert_eq!(Reason::from_ipc("conn_no_video"), Some(Reason::ConnNoVideo));
        assert_eq!(Reason::from_ipc("conn_failed"), Some(Reason::ConnFailed));
        for other in ["manual", "update_failed", "crash", "", "CONN_FAILED"] {
            assert_eq!(Reason::from_ipc(other), None, "{other}");
        }
        assert_eq!(Reason::Session.as_str(), "session");
        assert_eq!(Reason::ConnNoVideo.as_str(), "conn_no_video");
        assert_eq!(Reason::UpdateFailed.as_str(), "update_failed");
    }

    #[test]
    fn ipc_messages_round_trip_and_carry_no_path() {
        for message in [
            SenseLogIpc::ControllerStart {
                sid: "1795000000-0".to_owned(),
                peer: "987654321".to_owned(),
            },
            SenseLogIpc::ControllerEnd {
                sid: "1795000000-0".to_owned(),
                peer: "987654321".to_owned(),
                reason: "session".to_owned(),
            },
        ] {
            let json = serde_json::to_string(&message).unwrap();
            assert_eq!(serde_json::from_str::<SenseLogIpc>(&json).unwrap(), message);
            assert!(!json.contains('\') && !json.contains('/'));
        }
    }

    #[test]
    fn session_keys_do_not_collide() {
        assert_eq!(host_key(7), "h7");
        assert_eq!(controller_key("1795-0"), "c1795-0");
        assert_ne!(host_key(1), controller_key("1"));
    }

    #[test]
    fn platform_names_are_release_platforms() {
        let name = platform_name();
        assert!(["windows-x64", "macos-arm64", "linux"].contains(&name));
        assert!(name.len() <= 32);
    }

    #[test]
    fn dart_lines_are_limited_per_second() {
        let now = 1_795_000_000;
        let mut taken = 0;
        for _ in 0..DART_LINES_PER_S + 50 {
            if dart_line_allowed(now) {
                taken += 1;
            }
        }
        assert_eq!(taken, DART_LINES_PER_S);
        // The next second starts over.
        assert!(dart_line_allowed(now + 1));
    }

    #[test]
    fn session_request_carries_all_fields_and_the_signature_covers_them() {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        let meta = Meta {
            peer: Some("987654321".to_owned()),
            session_id: Some("h12".to_owned()),
            started: Some(1_795_000_000),
            ended: Some(1_795_000_090),
            app_version: Some(6),
            platform: Some("windows-x64".to_owned()),
            role: Some("host".to_owned()),
        };
        let body = signed_body("1", "u", 1_795_000_100, "session", &meta, &files(), &sk.0).unwrap();
        for (key, want) in [
            ("session_id", json!("h12")),
            ("started_at", json!(1_795_000_000)),
            ("ended_at", json!(1_795_000_090)),
            ("app_version", json!(6)),
            ("platform", json!("windows-x64")),
            ("role", json!("host")),
            ("conn_peer_id", json!("987654321")),
            ("reason", json!("session")),
        ] {
            assert_eq!(body[key], want, "{key}");
        }
        let sig = body["sig"].as_str().unwrap();
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let good = signed_bytes("1", "u", 1_795_000_100, "session", &meta, &files());
        assert!(verify(&pk, &good, sig));
        // Every one of the fields is covered.
        let mut other = meta.clone();
        other.role = Some("controller".to_owned());
        assert!(!verify(&pk, &signed_bytes("1", "u", 1_795_000_100, "session", &other, &files()), sig));
        let mut other = meta.clone();
        other.ended = Some(1_795_000_091);
        assert!(!verify(&pk, &signed_bytes("1", "u", 1_795_000_100, "session", &other, &files()), sig));
        let mut other = meta;
        other.session_id = None;
        assert!(!verify(&pk, &signed_bytes("1", "u", 1_795_000_100, "session", &other, &files()), sig));
    }

    // ---- reading ----

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sense-log-upload-{name}-{}-{}",
            std::process::id(),
            now_s()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn read_recent_takes_the_newest_tail_and_skips_other_files() {
        let dir = temp_dir("recent");
        fs::write(dir.join("server_rCURRENT.log"), "one\ntwo\nthree\n").unwrap();
        fs::write(dir.join("notes.txt"), "not a log").unwrap();
        let text = read_recent(&dir, 1000, SystemTime::now(), None).unwrap();
        assert_eq!(text, "one\ntwo\nthree\n");
        // Budget smaller than the file: the end, whole lines only.
        let text = read_recent(&dir, 12, SystemTime::now(), None).unwrap();
        assert_eq!(text, "two\nthree\n");
        // Nothing recent: files older than the window are not about this problem.
        let far = SystemTime::now() + Duration::from_secs(RECENT_S + 3600);
        assert_eq!(read_recent(&dir, 1000, far, None), None);
        // A directory that does not exist, or is empty.
        assert_eq!(read_recent(&dir.join("none"), 1000, SystemTime::now(), None), None);
        let empty = temp_dir("empty");
        assert_eq!(read_recent(&empty, 1000, SystemTime::now(), None), None);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }

    #[test]
    fn read_recent_joins_two_files_oldest_first() {
        let dir = temp_dir("two");
        fs::write(dir.join("a_r2026-11-23.log"), "old1\nold2\n").unwrap();
        // Make the second one newer.
        std::thread::sleep(Duration::from_millis(1100));
        fs::write(dir.join("a_rCURRENT.log"), "new1\n").unwrap();
        let text = read_recent(&dir, 1000, SystemTime::now(), None).unwrap();
        assert_eq!(text, "old1\nold2\n\nnew1\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn links_are_not_followed() {
        let dir = temp_dir("link");
        let secret = temp_dir("secret");
        fs::write(secret.join("passwd.log"), "root:x:0:0\n").unwrap();
        std::os::unix::fs::symlink(secret.join("passwd.log"), dir.join("evil.log")).unwrap();
        assert_eq!(read_recent(&dir, 1000, SystemTime::now(), None), None);
        let linked_dir = temp_dir("linkdir").join("server");
        std::os::unix::fs::symlink(&secret, &linked_dir).unwrap();
        assert_eq!(read_recent(&linked_dir, 1000, SystemTime::now(), None), None);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&secret);
    }

    #[test]
    fn a_session_reads_only_what_came_after_its_start() {
        let dir = temp_dir("since");
        let old = dir.join("server_rCURRENT.log");
        fs::write(&old, "before 1\nbefore 2\n").unwrap();
        let mut offsets = Offsets::new();
        for (path, len) in recent_log_files(&dir, SystemTime::now()) {
            offsets.insert(path, len);
        }
        assert_eq!(offsets.get(&old), Some(&18));
        // Nothing written yet: nothing to read.
        assert_eq!(read_recent(&dir, 1000, SystemTime::now(), Some(&offsets)), None);
        // Appended during the session, and a file that did not exist at the start.
        let mut file = fs::OpenOptions::new().append(true).open(&old).unwrap();
        std::io::Write::write_all(&mut file, b"during 1\nduring 2\n").unwrap();
        fs::write(dir.join("server_r2026-11-24.log"), "rotated 1\n").unwrap();
        let text = read_recent(&dir, 1000, SystemTime::now(), Some(&offsets)).unwrap();
        assert!(text.contains("during 1\nduring 2\n"), "{text}");
        assert!(text.contains("rotated 1"), "{text}");
        assert!(!text.contains("before"), "{text}");
        // A file now shorter than at the start (replaced): read from its start.
        let mut stale = Offsets::new();
        stale.insert(old.clone(), 10_000);
        let text = read_recent(&dir, 1000, SystemTime::now(), Some(&stale)).unwrap();
        assert!(text.contains("before 1"), "{text}");
        let _ = fs::remove_dir_all(&dir);
    }
}
