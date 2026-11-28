//! Sense Remote (Sürüm 12, #169, plan 2026-11-28 §2.2, §2.4): the employee's own settings
//! ("kişiye özel ayarlar") kept by the panel (`GET/PUT /api/sense/prefs`): favourites, key
//! bindings, recent items, view preferences. FAV-Ç.
//!
//! Rules (contract):
//! - read from the local cache at once, then sync with the panel in the background; a change from
//!   the panel is announced with the session-less event `sense_prefs_changed`;
//! - a write goes to the cache and a pending queue first and is sent with `base_rev`; offline it
//!   waits for the next sync;
//! - on 409 the panel value wins for the slots whose revision moved (V9); the other slots of the
//!   same request are sent again ("birleştir");
//! - the cache file is per employee (`sense_prefs_<hash of the e-mail>.json`), deleted at
//!   sign-out, and holds preferences only (never a key or token);
//! - window position, audio devices and the recording folder stay on the computer (not here);
//! - the first sync moves the computer's old view settings (quality, scale) to the account once,
//!   only where the account has no value yet.
//!
//! Also here: `main_sense_custom_shortcut_request` (`POST /api/sense/shortcuts/custom`).

use hbb_common::{
    config::{Config, LocalConfig},
    log,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

/// Flutter session-less event when the stored preferences changed (after a sync).
pub const EV_PREFS_CHANGED: &str = "sense_prefs_changed";

pub const PATH_PREFS: &str = "/api/sense/prefs";
pub const PATH_CUSTOM: &str = "/api/sense/shortcuts/custom";
const CACHE_PREFIX: &str = "sense_prefs_";
const CACHE_SUFFIX: &str = ".json";
/// The panel's `PREFS_MAX_PUT_ENTRIES` and `PREFS_MAX_VALUE_BYTES`.
pub const MAX_PUT: usize = 16;
pub const MAX_VALUE_BYTES: usize = 8_192;
/// A read syncs at most this often (a write always does).
const SYNC_EVERY: Duration = Duration::from_secs(30);
/// Largest custom shortcut request body taken from the UI.
const MAX_CUSTOM_BODY: usize = 4_096;

/// Allowed keys and their systems (the panel's `PREF_KEY_OS`; new keys only at the end).
pub const KEYS: [(&str, &[&str]); 6] = [
    ("fav.items", &["win", "mac", "linux"]),
    ("fav.recent", &["win", "mac", "linux"]),
    ("keys.bindings", &["any"]),
    ("view.quality", &["any"]),
    ("view.scale", &["any"]),
    ("view.ghost_start", &["any"]),
];

pub fn os_ok(os: &str) -> bool {
    matches!(os, "win" | "mac" | "linux" | "any")
}

pub fn key_os_ok(os: &str, key: &str) -> bool {
    KEYS.iter().any(|(k, systems)| *k == key && systems.contains(&os))
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cached {
    pub os: String,
    pub key: String,
    pub value: Value,
    pub rev: u64,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    pub os: String,
    pub key: String,
    pub value: Value,
    pub base_rev: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cache {
    pub v: u8,
    #[serde(default)]
    pub entries: Vec<Cached>,
    /// Approved custom shortcuts as the panel lists them (display only, no target).
    #[serde(default)]
    pub custom: Vec<Value>,
    #[serde(default)]
    pub pending: Vec<Pending>,
    /// The old view settings were looked at once (moved or not needed).
    #[serde(default)]
    pub migrated: bool,
}

impl Default for Cache {
    fn default() -> Self {
        Cache {
            v: 1,
            entries: Vec::new(),
            custom: Vec::new(),
            pending: Vec::new(),
            migrated: false,
        }
    }
}

fn slot_eq(a_os: &str, a_key: &str, b_os: &str, b_key: &str) -> bool {
    a_os == b_os && a_key == b_key
}

/// Whether a stored slot belongs to the answer for `os` (its own slots plus `any`).
fn in_view(slot_os: &str, os: &str) -> bool {
    slot_os == os || slot_os == "any"
}

impl Cache {
    fn rev_of(&self, os: &str, key: &str) -> u64 {
        self.entries
            .iter()
            .find(|e| slot_eq(&e.os, &e.key, os, key))
            .map_or(0, |e| e.rev)
    }

    /// `{entries, custom}` for `os`; a pending write shows its new value.
    pub fn view(&self, os: &str) -> Value {
        let mut entries: Vec<Cached> = self
            .entries
            .iter()
            .filter(|e| in_view(&e.os, os))
            .cloned()
            .collect();
        for p in self.pending.iter().filter(|p| in_view(&p.os, os)) {
            match entries.iter_mut().find(|e| slot_eq(&e.os, &e.key, &p.os, &p.key)) {
                Some(e) => e.value = p.value.clone(),
                None => entries.push(Cached {
                    os: p.os.clone(),
                    key: p.key.clone(),
                    value: p.value.clone(),
                    rev: 0,
                    updated_at: String::new(),
                }),
            }
        }
        let custom: Vec<&Value> = self
            .custom
            .iter()
            .filter(|c| os == "any" || c.get("os").and_then(Value::as_str) == Some(os))
            .collect();
        json!({ "entries": entries, "custom": custom })
    }

    /// Local writes: into the pending queue (a slot already waiting keeps its `base_rev`).
    pub fn stage(&mut self, writes: Vec<(String, String, Value)>) {
        for (os, key, value) in writes {
            if let Some(p) = self
                .pending
                .iter_mut()
                .find(|p| slot_eq(&p.os, &p.key, &os, &key))
            {
                p.value = value;
                continue;
            }
            let base_rev = self.rev_of(&os, &key);
            self.pending.push(Pending {
                os,
                key,
                value,
                base_rev,
            });
        }
    }

    /// The panel's answer to `GET ?os=`: its slots of `os` and `any` replace the cached ones, its
    /// custom list replaces the one of `os`. True when something changed.
    pub fn apply_get(&mut self, os: &str, entries: Vec<Cached>, custom: Vec<Value>) -> bool {
        let before = (self.entries.clone(), self.custom.clone());
        self.entries.retain(|e| !in_view(&e.os, os));
        self.entries.extend(
            entries
                .into_iter()
                .filter(|e| in_view(&e.os, os) && key_os_ok(&e.os, &e.key)),
        );
        self.custom
            .retain(|c| os != "any" && c.get("os").and_then(Value::as_str) != Some(os));
        self.custom.extend(
            custom
                .into_iter()
                .filter(|c| os == "any" || c.get("os").and_then(Value::as_str) == Some(os)),
        );
        (self.entries.clone(), self.custom.clone()) != before
    }

    /// 200 to a PUT of `sent`: the new revisions. A slot written again meanwhile stays pending
    /// on top of the new revision.
    pub fn apply_put_ok(&mut self, sent: &[Pending], revs: &[(String, String, u64)]) {
        for p in sent {
            let Some((_, _, rev)) = revs.iter().find(|(o, k, _)| slot_eq(o, k, &p.os, &p.key)) else {
                continue;
            };
            match self.entries.iter_mut().find(|e| slot_eq(&e.os, &e.key, &p.os, &p.key)) {
                Some(e) => {
                    e.value = p.value.clone();
                    e.rev = *rev;
                }
                None => self.entries.push(Cached {
                    os: p.os.clone(),
                    key: p.key.clone(),
                    value: p.value.clone(),
                    rev: *rev,
                    updated_at: String::new(),
                }),
            }
            if let Some(i) = self.pending.iter().position(|q| slot_eq(&q.os, &q.key, &p.os, &p.key)) {
                if self.pending[i].value == p.value {
                    self.pending.remove(i);
                } else {
                    self.pending[i].base_rev = *rev;
                }
            }
        }
    }

    /// 409 to a PUT of `sent` with the panel's `current` values: where the revision moved the
    /// panel wins and the local write is dropped (V9); the rest stays pending. True when a cached
    /// value changed.
    pub fn apply_conflict(&mut self, sent: &[Pending], current: Vec<Cached>) -> bool {
        let mut changed = false;
        for p in sent {
            let cur = current.iter().find(|c| slot_eq(&c.os, &c.key, &p.os, &p.key));
            let cur_rev = cur.map_or(0, |c| c.rev);
            if cur_rev == p.base_rev {
                continue;
            }
            self.pending.retain(|q| !slot_eq(&q.os, &q.key, &p.os, &p.key));
            self.entries.retain(|e| !slot_eq(&e.os, &e.key, &p.os, &p.key));
            if let Some(c) = cur {
                self.entries.push(c.clone());
            }
            changed = true;
        }
        changed
    }
}

/// `main_sense_prefs_set` body `{entries: [{os, key, value}]}` (pure check, the panel checks the
/// value shapes again).
pub fn parse_set(json: &str) -> Result<Vec<(String, String, Value)>, &'static str> {
    let body: Value = serde_json::from_str(json).map_err(|_| "invalid")?;
    let list = body.get("entries").and_then(Value::as_array).ok_or("invalid")?;
    if list.is_empty() || list.len() > MAX_PUT {
        return Err("invalid");
    }
    let mut out: Vec<(String, String, Value)> = Vec::new();
    for e in list {
        let os = e.get("os").and_then(Value::as_str).ok_or("invalid")?;
        let key = e.get("key").and_then(Value::as_str).ok_or("invalid")?;
        let value = e.get("value").cloned().ok_or("invalid")?;
        if !key_os_ok(os, key) || value.to_string().len() > MAX_VALUE_BYTES {
            return Err("invalid");
        }
        if out.iter().any(|(o, k, _)| o == os && k == key) {
            return Err("invalid");
        }
        out.push((os.to_owned(), key.to_owned(), value));
    }
    Ok(out)
}

/// The PUT body for the first [`MAX_PUT`] pending writes.
pub fn put_body(pending: &[Pending]) -> (Vec<Pending>, Value) {
    let sent: Vec<Pending> = pending.iter().take(MAX_PUT).cloned().collect();
    let body = json!({ "entries": sent });
    (sent, body)
}

fn cached_list(v: Option<&Value>) -> Vec<Cached> {
    v.and_then(Value::as_array)
        .map(|l| {
            l.iter()
                .filter_map(|e| serde_json::from_value::<Cached>(e.clone()).ok())
                .filter(|e| key_os_ok(&e.os, &e.key))
                .collect()
        })
        .unwrap_or_default()
}

/// The panel's answer to a GET: `(entries, custom)`, `None` when it is not one.
pub fn parse_get(status: u16, body: &str) -> Option<(Vec<Cached>, Vec<Value>)> {
    if status != 200 {
        return None;
    }
    let v: Value = serde_json::from_str(body).ok()?;
    v.get("entries")?.as_array()?;
    let custom = v
        .get("custom")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|c| c.get("id").and_then(Value::as_str).is_some())
        .take(50)
        .collect();
    Some((cached_list(v.get("entries")), custom))
}

#[derive(Debug, PartialEq)]
pub enum PutAnswer {
    Ok(Vec<(String, String, u64)>),
    Conflict(Vec<Cached>),
    /// 400: the panel refused the values; they are dropped (they would never pass).
    Invalid,
    /// Network, 401, 429, 5xx: kept for later.
    Later,
}

pub fn parse_put(status: u16, body: &str) -> PutAnswer {
    let v: Option<Value> = serde_json::from_str(body).ok();
    match status {
        200 => {
            let revs = v
                .as_ref()
                .and_then(|v| v.get("entries"))
                .and_then(Value::as_array)
                .map(|l| {
                    l.iter()
                        .filter_map(|e| {
                            Some((
                                e.get("os")?.as_str()?.to_owned(),
                                e.get("key")?.as_str()?.to_owned(),
                                e.get("rev")?.as_u64()?,
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            PutAnswer::Ok(revs)
        }
        409 if v.as_ref().and_then(|v| v.get("error")).and_then(Value::as_str)
            == Some("rev_conflict") =>
        {
            PutAnswer::Conflict(cached_list(v.as_ref().and_then(|v| v.get("current"))))
        }
        400 => PutAnswer::Invalid,
        _ => PutAnswer::Later,
    }
}

/// Cache file name of an employee (no e-mail in the name).
pub fn cache_name(email: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(email.trim().to_lowercase().as_bytes());
    format!("{CACHE_PREFIX}{}{CACHE_SUFFIX}", &hex::encode(digest)[..16])
}

/// The computer's old view settings as account values, only for slots the account (and the
/// queue) does not have yet. `image_quality`, `custom-fps`, `view_style` are RustDesk's user
/// defaults.
pub fn migration(cache: &Cache, image_quality: &str, custom_fps: &str, view_style: &str) -> Vec<(String, String, Value)> {
    let has = |key: &str| {
        cache.entries.iter().any(|e| e.os == "any" && e.key == key)
            || cache.pending.iter().any(|p| p.os == "any" && p.key == key)
    };
    let mut out = Vec::new();
    if !has("view.quality") {
        let value = match image_quality {
            "best" | "balanced" | "low" => Some(json!({ "mode": image_quality })),
            "custom" => custom_fps
                .trim()
                .parse::<u32>()
                .ok()
                .filter(|f| (1..=120).contains(f))
                .map(|fps| json!({ "mode": "custom", "fps": fps })),
            _ => None,
        };
        if let Some(v) = value {
            out.push(("any".to_owned(), "view.quality".to_owned(), v));
        }
    }
    if !has("view.scale") {
        let mode = match view_style {
            "adaptive" => Some("fit"),
            "original" => Some("original"),
            _ => None,
        };
        if let Some(mode) = mode {
            out.push(("any".to_owned(), "view.scale".to_owned(), json!({ "mode": mode })));
        }
    }
    out
}

/// The custom shortcut request as the panel takes it. The list's "yalnız bu bilgisayar" comes
/// as `scope: person` with `scope_ref` = this peer's id; the panel calls that `device` (#171).
pub fn custom_body(json: &str) -> Result<Value, &'static str> {
    if json.len() > MAX_CUSTOM_BODY {
        return Err("invalid");
    }
    let v: Value = serde_json::from_str(json).map_err(|_| "invalid")?;
    let text = |k: &str| v.get(k).and_then(Value::as_str);
    let (Some(os), Some(kind), Some(label), Some(target), Some(scope)) =
        (text("os"), text("kind"), text("label"), text("target"), text("scope"))
    else {
        return Err("invalid");
    };
    let scope_ref = text("scope_ref").filter(|s| !s.is_empty());
    let scope = match (scope, scope_ref) {
        ("person", Some(_)) => "device",
        (s, _) => s,
    };
    if !matches!(os, "win" | "mac" | "linux")
        || !matches!(kind, "program" | "folder" | "url")
        || !matches!(scope, "person" | "project" | "all" | "device")
        || super::shortcuts::custom::target_problem(os, kind, target).is_some()
    {
        return Err("invalid");
    }
    let mut body = json!({ "os": os, "kind": kind, "label": label, "target": target, "scope": scope });
    if matches!(scope, "project" | "device") {
        let Some(r) = scope_ref else {
            return Err("invalid");
        };
        body["scope_ref"] = json!(r);
    }
    Ok(body)
}

/// The panel's answer to the custom request: `{id, status}` or `{error}`.
pub fn custom_answer(status: u16, body: &str) -> Value {
    let v: Option<Value> = serde_json::from_str(body).ok();
    if status == 202 {
        if let Some(id) = v.as_ref().and_then(|v| v.get("id")).and_then(Value::as_str) {
            return json!({ "id": id, "status": "pending" });
        }
    }
    let code = v
        .as_ref()
        .and_then(|v| v.get("error"))
        .and_then(Value::as_str)
        .filter(|c| matches!(*c, "token_invalid" | "rate_limited" | "invalid" | "too_many"))
        .unwrap_or("panel_error");
    json!({ "error": code })
}

// ------------------------------------------------------------------ state (not pure)

struct Session {
    token: String,
    email: String,
}

fn session() -> Option<Session> {
    let token = LocalConfig::get_option("access_token");
    if token.is_empty() {
        return None;
    }
    let email = super::grants::session_email(&LocalConfig::get_option("user_info"))?;
    Some(Session { token, email })
}

struct State {
    email: String,
    cache: Cache,
}

fn state() -> &'static Mutex<Option<State>> {
    static STATE: OnceLock<Mutex<Option<State>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

fn last_sync() -> &'static Mutex<HashMap<String, Instant>> {
    static LAST: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    LAST.get_or_init(Default::default)
}

static SYNCING: AtomicBool = AtomicBool::new(false);

fn cache_path(email: &str) -> std::path::PathBuf {
    Config::path(cache_name(email))
}

fn load(email: &str) -> Cache {
    std::fs::read_to_string(cache_path(email))
        .ok()
        .and_then(|text| serde_json::from_str::<Cache>(&text).ok())
        .filter(|c| c.v == 1)
        .unwrap_or_default()
}

fn save(email: &str, cache: &Cache) {
    let path = cache_path(email);
    let tmp = path.with_extension("json.tmp");
    let result = serde_json::to_vec(cache)
        .map_err(|e| e.to_string())
        .and_then(|bytes| std::fs::write(&tmp, bytes).map_err(|e| e.to_string()))
        .and_then(|()| std::fs::rename(&tmp, &path).map_err(|e| e.to_string()));
    if let Err(err) = result {
        log::warn!("Sense Remote: preferences cache not written: {err}");
    }
}

/// Signed out: every employee's cache goes (contract: deleted at sign-out).
fn clear_all() {
    *state().lock().unwrap_or_else(|e| e.into_inner()) = None;
    last_sync().lock().unwrap_or_else(|e| e.into_inner()).clear();
    let Some(dir) = Config::path(cache_name("x")).parent().map(|p| p.to_path_buf()) else {
        return;
    };
    let Ok(read) = std::fs::read_dir(&dir) else {
        return;
    };
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(CACHE_PREFIX)
            && (name.ends_with(CACHE_SUFFIX) || name.ends_with(".json.tmp"))
        {
            if std::fs::remove_file(entry.path()).is_ok() {
                log::info!("Sense Remote: preferences cache removed at sign-out");
            }
        }
    }
}

/// Runs `f` on the signed-in employee's cache (loaded on first use, or after a switch).
fn with_cache<R>(email: &str, f: impl FnOnce(&mut Cache) -> R) -> R {
    let mut guard = state().lock().unwrap_or_else(|e| e.into_inner());
    if guard.as_ref().map(|s| s.email.as_str()) != Some(email) {
        *guard = Some(State {
            email: email.to_owned(),
            cache: load(email),
        });
    }
    let st = guard.as_mut().expect("state set above");
    f(&mut st.cache)
}

fn request(method: &str, path: &str, token: &str, body: Option<String>) -> Option<(u16, String)> {
    let mut header = serde_json::Map::new();
    header.insert("Authorization".to_owned(), Value::String(format!("Bearer {token}")));
    header.insert("Content-Type".to_owned(), Value::String("application/json".to_owned()));
    let url = format!("{}{path}", super::api_server());
    let response = crate::http_request_sync(url, method.to_owned(), body, Value::Object(header).to_string())
        .map_err(|err| log::debug!("Sense Remote: preferences request failed: {err}"))
        .ok()?;
    let v: Value = serde_json::from_str(&response).ok()?;
    let status = v.get("status_code").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok())?;
    let body = v.get("body").and_then(Value::as_str).unwrap_or("").to_owned();
    Some((status, body))
}

fn push_changed() {
    #[cfg(feature = "flutter")]
    {
        let event = json!({ "name": EV_PREFS_CHANGED }).to_string();
        for channel in crate::flutter::get_global_event_channels() {
            crate::flutter::push_global_event(&channel, event.clone());
        }
    }
}

fn user_default(key: &str) -> String {
    hbb_common::config::UserDefaultConfig::load().get(key)
}

/// Sends the pending writes (a few rounds: after a partial conflict the rest goes again).
fn flush(s: &Session) -> bool {
    let mut changed = false;
    for _ in 0..3 {
        let (sent, body) = with_cache(&s.email, |c| put_body(&c.pending));
        if sent.is_empty() {
            break;
        }
        let Some((status, text)) = request("PUT", PATH_PREFS, &s.token, Some(body.to_string())) else {
            break;
        };
        let answer = parse_put(status, &text);
        let keep_going = with_cache(&s.email, |c| {
            let go = match answer {
                PutAnswer::Ok(revs) => {
                    c.apply_put_ok(&sent, &revs);
                    true
                }
                PutAnswer::Conflict(current) => {
                    changed |= c.apply_conflict(&sent, current);
                    true
                }
                PutAnswer::Invalid => {
                    log::warn!("Sense Remote: panel refused {} preference value(s)", sent.len());
                    c.pending.retain(|q| !sent.iter().any(|p| p == q));
                    true
                }
                PutAnswer::Later => false,
            };
            save(&s.email, c);
            go
        });
        if !keep_going {
            if status == 401 {
                log::info!("Sense Remote: preferences: sign-in token refused");
            }
            break;
        }
    }
    changed
}

/// One background sync for `os`: read, move old settings once, send pending writes.
fn sync(os: String) {
    if SYNCING.swap(true, Ordering::AcqRel) {
        return;
    }
    let result = std::panic::catch_unwind(|| {
        let Some(s) = session() else {
            return false;
        };
        let mut changed = false;
        if let Some((status, text)) = request("GET", &format!("{PATH_PREFS}?os={os}"), &s.token, None) {
            match parse_get(status, &text) {
                Some((entries, custom)) => {
                    let migrate = with_cache(&s.email, |c| {
                        changed |= c.apply_get(&os, entries, custom);
                        let writes = if c.migrated {
                            Vec::new()
                        } else {
                            c.migrated = true;
                            migration(
                                c,
                                &user_default("image_quality"),
                                &user_default("custom-fps"),
                                &user_default("view_style"),
                            )
                        };
                        if !writes.is_empty() {
                            log::info!("Sense Remote: old view settings moved to the account");
                            c.stage(writes.clone());
                        }
                        save(&s.email, c);
                        writes
                    });
                    changed |= !migrate.is_empty();
                }
                None => log::debug!("Sense Remote: preferences read answered {status}"),
            }
        }
        changed |= flush(&s);
        changed
    });
    SYNCING.store(false, Ordering::Release);
    if matches!(result, Ok(true)) {
        push_changed();
    }
}

fn sync_in_background(os: &str, force: bool) {
    {
        let mut last = last_sync().lock().unwrap_or_else(|e| e.into_inner());
        let due = force || last.get(os).map_or(true, |t| t.elapsed() >= SYNC_EVERY);
        if !due {
            return;
        }
        last.insert(os.to_owned(), Instant::now());
    }
    let os = os.to_owned();
    std::thread::spawn(move || sync(os));
}

/// `main_sense_prefs_get(os)`: `{entries, custom}` from the cache at once (synced in the
/// background), `{"error": "invalid" | "signed_out"}`.
pub fn ffi_get(os: &str) -> String {
    if !os_ok(os) {
        return json!({ "error": "invalid" }).to_string();
    }
    let Some(s) = session() else {
        clear_all();
        return json!({ "error": "signed_out" }).to_string();
    };
    let view = with_cache(&s.email, |c| c.view(os));
    sync_in_background(os, false);
    view.to_string()
}

/// `main_sense_prefs_set(json)`: "" when stored (sent in the background), else `invalid` |
/// `signed_out`.
pub fn ffi_set(json: &str) -> String {
    let Some(s) = session() else {
        clear_all();
        return "signed_out".to_owned();
    };
    let writes = match parse_set(json) {
        Ok(w) => w,
        Err(code) => return code.to_owned(),
    };
    let os = writes
        .iter()
        .map(|(o, _, _)| o.as_str())
        .find(|o| *o != "any")
        .unwrap_or("any")
        .to_owned();
    with_cache(&s.email, |c| {
        c.stage(writes);
        save(&s.email, c);
    });
    sync_in_background(&os, true);
    String::new()
}

/// `main_sense_custom_shortcut_request(json)`: `{id, status: "pending"}` or `{error}`
/// (`invalid`, `signed_out`, `network`, a panel code). Blocking (called off the UI thread).
pub fn ffi_custom_shortcut_request(json: &str) -> String {
    let Some(s) = session() else {
        return json!({ "error": "signed_out" }).to_string();
    };
    let body = match custom_body(json) {
        Ok(b) => b,
        Err(code) => return json!({ "error": code }).to_string(),
    };
    match request("POST", PATH_CUSTOM, &s.token, Some(body.to_string())) {
        Some((status, text)) => custom_answer(status, &text).to_string(),
        None => json!({ "error": "network" }).to_string(),
    }
}

#[cfg(test)]
mod tests;
