//! Sense Remote (Sürüm 4, S3 / H1; plan 2026-11-23 §2.3, §2.6, D3c): the computer's name and
//! location, changed on the Host. The Host is the only place they change; the panel shows them
//! read-only.
//!
//! Flow: UI (`main_sense_identity_set`) → main IPC (`Data::SenseIdentitySet`) → `--server`:
//! 1. checks the name (1–64 characters, no control character) and the location id (`loc_…`);
//! 2. signs `POST /api/sense/device-info` with the **device key** (RustDesk's Ed25519 key pair,
//!    the one registered at enrolment and used for the heartbeat report; its own signing prefix
//!    `sense-remote/device-info/v1\n`, contract `client-api/device-info.ts`);
//! 3. only when the panel took it (200): stores name, location name and location id locally —
//!    Windows: the SYSTEM `--server` writes HKLM `Setup`; macOS: the user `--server` asks the root
//!    daemon (`_service` channel, `Store`) to write `state.json`. Without the panel nothing is
//!    stored, so the computer and the panel never disagree; the UI says "panel ulaşılamıyor" and
//!    the user tries again.
//!
//! Why `--server` and not the UI (plan §2.3, deviation from the TK report): a Host-only computer
//! has no Sense sign-in, and on Windows only SYSTEM holds the device key and may write HKLM.
//!
//! The location list comes with the heartbeat answer (`sense_locations`, read by
//! `report::locations_from_answer`), only when the `sense.loc_rev` the computer sends is not the
//! panel's current one. It is kept in the `--server` memory: after a restart no `loc_rev` is sent
//! and the panel sends the list again.
//!
//! The same IPC message carries the H2 "Son bağlantılar" query (`RecentQuery`): the list lives in
//! the `--server` process too (`host_recent`).
//!
//! Karar #93: the name and location can be edited in the panel too. The panel announces
//! `name_push` in `sense_panel_caps` and, while this computer reports an `id_rev` that is not its
//! current one, sends `sense_identity: {rev, name, location_id}` in the heartbeat answer. A Host
//! with a newer `rev` than the one it applied writes the values locally exactly as the Host window
//! does (`store` + `update_builtin`, so the Host window shows them) and reports the new `rev` as
//! `sense.id_rev`. A change made on the Host window still goes out through the signed
//! `device-info` (above); the panel keeps the newer of the two per field and answers with the
//! winner, which is what gets stored. Only for a panel that announces `name_push`; the location must
//! be one the panel's list names (or the stored one).
//!
//! Nothing here logs a name, a location or a key.

use super::{report::SenseLocations, SenseRole};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config, log,
    sodiumoxide::{self, crypto::sign},
    tokio,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::sync::Mutex;

/// Domain separation, same bytes as the panel (`DEVICE_INFO_SIGNING_PREFIX`).
pub const PREFIX: &[u8] = b"sense-remote/device-info/v1\n";
const PATH: &str = "/api/sense/device-info";
/// Contract `DeviceInfoName`: at most 64 characters.
pub const MAX_NAME_CHARS: usize = 64;
/// Same as `sense::MAX_LOCATION_CHARS` (the installer's limit for the stored location name).
const MAX_LOCATION_CHARS: usize = 96;
/// `ts` of the last request sent (local config of the `--server` process): the panel refuses a
/// `ts` that is not above the last one it took (`replayed`).
const OPTION_INFO_TS: &str = "sense-info-ts";
/// The registry value / state field the installer writes (`sense::REG_VALUE_SETUP`).
#[cfg(windows)]
const SETUP_VALUE: &str = "Setup";
/// Karar #93: heartbeat answer field with the name / location edited in the panel (contract
/// `SenseIdentityPush`), and the panel capability that announces it.
pub const KEY_IDENTITY: &str = "sense_identity";
pub const CAP_NAME_PUSH: &str = "name_push";
/// `rev` of the last panel edit applied here (local config of the `--server` process).
const OPTION_IDENTITY_REV: &str = "sense-identity-rev";
/// `rev` is a panel time in ms (JavaScript safe integer).
const MAX_IDENTITY_REV: u64 = 9_007_199_254_740_991;
/// A panel edit and a Host edit never write at the same time.
static IDENTITY_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
/// A heartbeat answer older than this does not count as "panel reachable" any more.
const PANEL_FRESH_S: u64 = 90;
/// UI waits for `--server`: the POST (panel) plus the local write.
const SET_TIMEOUT_MS: u64 = 20_000;
const QUERY_TIMEOUT_MS: u64 = 3_000;

// Error codes for the UI (`senseIdentityErrorText` in Dart).
const ERR_INVALID: &str = "invalid";
const ERR_NETWORK: &str = "network";
const ERR_LOCATION: &str = "location_not_in_project";
const ERR_UNAVAILABLE: &str = "unavailable";
const ERR_STORE: &str = "store";
const ERR_OTHER: &str = "other";

/// `Data::SenseIdentitySet` (src/ipc.rs).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseIdentityIpc {
    /// UI → `--server`: `main_sense_identity`.
    Query,
    /// UI → `--server`: `main_sense_identity_set`.
    Set { name: String, location_id: String },
    /// UI → `--server`: `main_sense_host_recent_conns` (H2).
    RecentQuery,
    /// `--server` → UI: the JSON answer to one of the three above.
    Answer(String),
    /// macOS, user `--server` → root daemon (`_service`): store what the panel took.
    Store {
        name: String,
        location: String,
        location_id: String,
    },
    /// Root daemon → user `--server`: stored or not.
    Stored(bool),
}

// ---------------------------------------------------------------------------------------------
// Pure part
// ---------------------------------------------------------------------------------------------

/// Contract `LocationId`: `loc_[0-9A-Za-z-]+`, at most 64 characters.
pub fn is_location_id(id: &str) -> bool {
    let allowed = |b: u8| b.is_ascii_alphanumeric() || b == b'-';
    id.len() <= 64
        && id
            .strip_prefix("loc_")
            .is_some_and(|rest| !rest.is_empty() && rest.bytes().all(allowed))
}

/// Contract `DeviceInfoName`: trimmed, 1–64 characters, no control character.
pub fn clean_name(name: &str) -> Option<String> {
    let name = name.trim();
    let ok = !name.is_empty()
        && name.chars().count() <= MAX_NAME_CHARS
        && !name.chars().any(char::is_control);
    ok.then(|| name.to_owned())
}

/// `""` (no location) or a valid location id; `None` = invalid.
fn clean_location_id(location_id: &str) -> Option<Option<String>> {
    let location_id = location_id.trim();
    if location_id.is_empty() {
        Some(None)
    } else if is_location_id(location_id) {
        Some(Some(location_id.to_owned()))
    } else {
        None
    }
}

/// Name and location as stored on the computer: the installer's `Setup` JSON (`SetupInfo`:
/// `name`, `location`) plus the location id this module adds. `SetupInfo` ignores the extra
/// field, so the installer's reader keeps working.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct StoredIdentity {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub location: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub location_id: String,
}

impl StoredIdentity {
    /// Hex of the JSON, the form `Setup` / `setup_hex` hold.
    pub fn encode(&self) -> String {
        hex::encode(serde_json::to_vec(self).unwrap_or_default())
    }

    pub fn decode(value: &str) -> Option<Self> {
        serde_json::from_slice(&hex::decode(value.trim()).ok()?).ok()
    }

    /// The values a `Store` may write: name as the panel took it, location name and id clean.
    fn checked(name: &str, location: &str, location_id: &str) -> Option<Self> {
        let location = location.trim();
        let location_ok = location.chars().count() <= MAX_LOCATION_CHARS
            && !location.chars().any(char::is_control);
        Some(Self {
            name: clean_name(name)?,
            location: location_ok.then(|| location.to_owned())?,
            location_id: clean_location_id(location_id)?.unwrap_or_default(),
        })
    }
}

/// The location id of the stored identity: its own, or (installs before Sürüm 4 stored only the
/// name) the one location in the list with exactly that name.
fn stored_location_id(stored: &StoredIdentity, locations: Option<&SenseLocations>) -> String {
    if !stored.location_id.is_empty() {
        return stored.location_id.clone();
    }
    let name = stored.location.trim();
    if name.is_empty() {
        return String::new();
    }
    let mut same = locations
        .map(|list| list.items.iter().filter(|(_, n)| n == name).collect::<Vec<_>>())
        .unwrap_or_default();
    match (same.pop(), same.is_empty()) {
        (Some((id, _)), true) => id.clone(),
        _ => String::new(),
    }
}

/// Name to store for the chosen location: from the panel's list, else the stored one when the
/// id is the stored one; nothing for no location.
fn location_name_for(
    location_id: Option<&str>,
    locations: Option<&SenseLocations>,
    stored: &StoredIdentity,
) -> String {
    let Some(location_id) = location_id else {
        return String::new();
    };
    if let Some((_, name)) = locations
        .and_then(|list| list.items.iter().find(|(id, _)| id == location_id))
    {
        return name.clone();
    }
    if stored_location_id(stored, locations) == location_id {
        return stored.location.clone();
    }
    String::new()
}

/// A name / location edit made in the panel (`sense_identity`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelPush {
    pub rev: u64,
    pub name: String,
    pub location_id: Option<String>,
}

/// Reads `sense_identity` out of a heartbeat answer body. `None` unless the same answer announces
/// `name_push` and the field has the contract's shape (name and location id pass the same rules
/// as an edit made here).
pub fn push_from_answer(body: &str) -> Option<PanelPush> {
    let answer: Value = serde_json::from_str(body).ok()?;
    let announced = answer
        .get("sense_panel_caps")?
        .as_array()?
        .iter()
        .any(|cap| cap.as_str() == Some(CAP_NAME_PUSH));
    if !announced {
        return None;
    }
    let push = answer.get(KEY_IDENTITY)?.as_object()?;
    let rev = push
        .get("rev")?
        .as_u64()
        .filter(|rev| (1..=MAX_IDENTITY_REV).contains(rev))?;
    let name = clean_name(push.get("name")?.as_str()?)?;
    let location_id = match push.get("location_id")? {
        Value::Null => None,
        Value::String(id) if is_location_id(id) => Some(id.clone()),
        _ => return None,
    };
    Some(PanelPush {
        rev,
        name,
        location_id,
    })
}

/// What to store for a panel edit: `None` when it is not newer than the one applied, or its
/// location is neither on the panel's list nor the stored one (the list comes with the same
/// answer when it changed, so the next heartbeat tries again).
pub fn plan_push(
    push: &PanelPush,
    applied_rev: u64,
    locations: Option<&SenseLocations>,
    stored: &StoredIdentity,
) -> Option<StoredIdentity> {
    if push.rev <= applied_rev {
        return None;
    }
    let location = match push.location_id.as_deref() {
        None => String::new(),
        Some(id) => match locations.and_then(|list| list.items.iter().find(|(item, _)| item == id)) {
            Some((_, name)) => name.clone(),
            None if stored_location_id(stored, locations) == id => stored.location.clone(),
            None => return None,
        },
    };
    StoredIdentity::checked(&push.name, &location, push.location_id.as_deref().unwrap_or(""))
}

/// `main_sense_identity`: `{name, location_id, location_name, locations: [{id, name}], panel:
/// "ok" | "unreachable" | null}`. Without a list from the panel the stored location is the only
/// choice (so the tile still shows it).
pub fn identity_json(
    stored: &StoredIdentity,
    locations: Option<&SenseLocations>,
    panel_ok: Option<bool>,
) -> Value {
    let location_id = stored_location_id(stored, locations);
    let location_name = match locations
        .and_then(|list| list.items.iter().find(|(id, _)| !location_id.is_empty() && *id == location_id))
    {
        Some((_, name)) => name.clone(),
        None => stored.location.clone(),
    };
    let mut list: Vec<Value> = locations
        .map(|list| {
            list.items
                .iter()
                .map(|(id, name)| json!({ "id": id, "name": name }))
                .collect()
        })
        .unwrap_or_default();
    if list.is_empty() && !location_name.is_empty() {
        list.push(json!({ "id": location_id, "name": location_name }));
    }
    json!({
        "name": stored.name,
        "location_id": location_id,
        "location_name": location_name,
        "locations": list,
        "panel": match panel_ok {
            Some(true) => json!("ok"),
            Some(false) => json!("unreachable"),
            None => Value::Null,
        },
    })
}

/// The bytes the device signs: prefix ‖ JCS({id, uuid, ts, name, location_id}).
pub fn signed_bytes(id: &str, uuid: &str, ts: i64, name: &str, location_id: Option<&str>) -> Vec<u8> {
    let mut object = Map::new();
    object.insert("id".to_owned(), json!(id));
    object.insert("uuid".to_owned(), json!(uuid));
    object.insert("ts".to_owned(), json!(ts));
    object.insert("name".to_owned(), json!(name));
    object.insert("location_id".to_owned(), json!(location_id));
    let mut bytes = PREFIX.to_vec();
    bytes.extend_from_slice(super::report::canonical_json(&Value::Object(object)).as_bytes());
    bytes
}

/// The request body (`DeviceInfoBody`) with its signature; `None` without a usable 64-byte
/// Ed25519 secret key. The key never leaves this call.
pub fn signed_body(
    id: &str,
    uuid: &str,
    ts: i64,
    name: &str,
    location_id: Option<&str>,
    secret_key: &[u8],
) -> Option<Value> {
    let secret_key = sign::SecretKey::from_slice(secret_key)?;
    sodiumoxide::init().ok()?;
    let signature = sign::sign_detached(&signed_bytes(id, uuid, ts, name, location_id), &secret_key);
    Some(json!({
        "id": id,
        "uuid": uuid,
        "ts": ts,
        "name": name,
        "location_id": location_id,
        "sig": URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    }))
}

/// The panel's answer → `(name, location_id)` it stored, or the error code for the UI. A 200
/// whose body can not be read keeps what was sent (the panel took it).
pub fn map_answer(
    answer: Result<(u16, String), ()>,
    sent_name: &str,
    sent_location: Option<&str>,
) -> Result<(String, Option<String>), &'static str> {
    let (status, body) = answer.map_err(|_| ERR_NETWORK)?;
    let body: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    match status {
        200 => {
            let name = body
                .get("name")
                .and_then(Value::as_str)
                .and_then(clean_name)
                .unwrap_or_else(|| sent_name.to_owned());
            let location = match body.get("location_id") {
                Some(Value::String(id)) if is_location_id(id) => Some(id.clone()),
                Some(Value::Null) => None,
                _ => sent_location.map(str::to_owned),
            };
            Ok((name, location))
        }
        status if status >= 500 => Err(ERR_NETWORK),
        400 => match body.get("error").and_then(Value::as_str) {
            Some("location_not_in_project") => Err(ERR_LOCATION),
            Some("validation") => Err(ERR_INVALID),
            _ => Err(ERR_OTHER),
        },
        _ => Err(ERR_OTHER),
    }
}

fn error(code: &str) -> String {
    json!({ "error": code }).to_string()
}

fn is_host(role: Option<SenseRole>) -> bool {
    matches!(role, Some(SenseRole::Host | SenseRole::Both))
}

// ---------------------------------------------------------------------------------------------
// `--server` state: location list and panel reachability, from the heartbeat
// ---------------------------------------------------------------------------------------------

struct PanelState {
    locations: Option<SenseLocations>,
    /// Last heartbeat answered (true) or failed (false), with its time.
    last: Option<(bool, std::time::Instant)>,
}

static STATE: Mutex<PanelState> = Mutex::new(PanelState {
    locations: None,
    last: None,
});

/// Sync loop (`hbbs_http/sync.rs`), after every heartbeat: `body` is the answer, `None` when the
/// panel was not reached.
pub fn on_heartbeat_answer(body: Option<&str>) {
    let list = body.and_then(super::report::locations_from_answer);
    let mut state = STATE.lock().unwrap();
    state.last = Some((body.is_some(), std::time::Instant::now()));
    if let Some(list) = list {
        state.locations = Some(list);
    }
}

/// Sync loop: `sense.loc_rev`, the version of the list held (left out without one). Unsigned,
/// added after the report is signed.
pub fn extend_heartbeat(sense: &mut Value) {
    let rev = STATE.lock().unwrap().locations.as_ref().map(|list| list.rev);
    if let (Some(rev), Some(object)) = (rev, sense.as_object_mut()) {
        object.insert("loc_rev".to_owned(), json!(rev));
    }
}

/// Sync loop: `sense.id_rev`, the panel edit applied here (0 = none). Only for a panel that
/// announces `name_push`; the panel sends nothing to a computer that reports no `id_rev`.
pub fn extend_heartbeat_rev(sense: &mut Value) {
    if !super::report_sig::panel_has(CAP_NAME_PUSH) {
        return;
    }
    if let Some(object) = sense.as_object_mut() {
        object.insert("id_rev".to_owned(), json!(applied_rev()));
    }
}

fn applied_rev() -> u64 {
    config::LocalConfig::get_option(OPTION_IDENTITY_REV)
        .parse()
        .unwrap_or(0)
}

fn locations() -> Option<SenseLocations> {
    STATE.lock().unwrap().locations.clone()
}

fn panel_ok() -> Option<bool> {
    let state = STATE.lock().unwrap();
    let (ok, at) = state.last?;
    Some(ok && at.elapsed().as_secs() <= PANEL_FRESH_S)
}

fn note_panel(ok: bool) {
    STATE.lock().unwrap().last = Some((ok, std::time::Instant::now()));
}

// ---------------------------------------------------------------------------------------------
// Local storage
// ---------------------------------------------------------------------------------------------

#[cfg(windows)]
fn read_stored() -> Option<StoredIdentity> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let value = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(super::REG_SUBKEY)
        .ok()?
        .get_value::<String, _>(SETUP_VALUE)
        .ok()?;
    StoredIdentity::decode(&value)
}

#[cfg(target_os = "macos")]
fn read_stored() -> Option<StoredIdentity> {
    let state = super::mac_state::read().ok()??;
    StoredIdentity::decode(&state.setup_hex)
}

#[cfg(not(any(windows, target_os = "macos")))]
fn read_stored() -> Option<StoredIdentity> {
    None
}

/// Windows: the SYSTEM `--server` writes HKLM `Setup`.
#[cfg(windows)]
async fn store(identity: StoredIdentity) -> Result<(), String> {
    let hex = identity.encode();
    tokio::task::spawn_blocking(move || {
        use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
        let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
            .create_subkey(super::REG_SUBKEY)
            .map_err(|err| err.to_string())?;
        key.set_value(SETUP_VALUE, &hex).map_err(|err| err.to_string())
    })
    .await
    .map_err(|err| err.to_string())?
}

/// macOS: the user `--server` can not write the root-owned state file; the daemon does.
#[cfg(target_os = "macos")]
async fn store(identity: StoredIdentity) -> Result<(), String> {
    use crate::ipc::Data;
    // Only a peer with uid 0 is accepted as the daemon.
    let mut conn = crate::ipc::connect_trusted_device_service(1_000)
        .await
        .map_err(|err| err.to_string())?;
    let message = SenseIdentityIpc::Store {
        name: identity.name,
        location: identity.location,
        location_id: identity.location_id,
    };
    conn.send(&Data::SenseIdentitySet(message))
        .await
        .map_err(|err| err.to_string())?;
    match conn.next_timeout(5_000).await {
        Ok(Some(Data::SenseIdentitySet(SenseIdentityIpc::Stored(true)))) => Ok(()),
        Ok(Some(Data::SenseIdentitySet(SenseIdentityIpc::Stored(false)))) => {
            Err("daemon refused".to_owned())
        }
        _ => Err("no daemon answer".to_owned()),
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
async fn store(_identity: StoredIdentity) -> Result<(), String> {
    Err("unsupported platform".to_owned())
}

/// The running process's built-in `sense-name` / `sense-location` (read once at start
/// otherwise), so other readers see the new values without a restart.
fn update_builtin(identity: &StoredIdentity) {
    let mut builtin = config::BUILTIN_SETTINGS.write().unwrap();
    builtin.insert(super::OPTION_SENSE_NAME.to_owned(), identity.name.clone());
    builtin.insert(super::OPTION_SENSE_LOCATION.to_owned(), identity.location.clone());
}

/// macOS root daemon, `_service` channel: `Store` only, values checked again here. A user
/// process could send this directly; it changes no more than the Host user may change in the
/// app (the name shown on this computer), never the panel, a permission or a key.
#[cfg(target_os = "macos")]
pub fn on_service_ipc(message: SenseIdentityIpc) -> Option<SenseIdentityIpc> {
    let SenseIdentityIpc::Store {
        name,
        location,
        location_id,
    } = message
    else {
        return None;
    };
    let Some(identity) = StoredIdentity::checked(&name, &location, &location_id) else {
        log::warn!("Sense Remote: identity store refused, values out of the rules");
        return Some(SenseIdentityIpc::Stored(false));
    };
    if !is_host(super::installed_role()) {
        return Some(SenseIdentityIpc::Stored(false));
    }
    let hex = identity.encode();
    let result = super::mac_state::update(|state| state.setup_hex = hex);
    if let Err(err) = &result {
        log::error!("Sense Remote: identity not stored in the state file: {err}");
    }
    Some(SenseIdentityIpc::Stored(result.is_ok()))
}

// ---------------------------------------------------------------------------------------------
// `--server`, main IPC
// ---------------------------------------------------------------------------------------------

/// Main IPC handler (`ipc::handle`): answers the UI's three requests; anything else gets no
/// answer.
pub async fn on_main_ipc(message: SenseIdentityIpc) -> Option<SenseIdentityIpc> {
    match message {
        SenseIdentityIpc::Query => {
            let stored = tokio::task::spawn_blocking(read_stored)
                .await
                .ok()
                .flatten()
                .unwrap_or_default();
            let answer = identity_json(&stored, locations().as_ref(), panel_ok());
            Some(SenseIdentityIpc::Answer(answer.to_string()))
        }
        SenseIdentityIpc::Set { name, location_id } => {
            Some(SenseIdentityIpc::Answer(set_in_server(&name, &location_id).await))
        }
        SenseIdentityIpc::RecentQuery => {
            Some(SenseIdentityIpc::Answer(super::host_recent::list_json()))
        }
        SenseIdentityIpc::Answer(_) | SenseIdentityIpc::Store { .. } | SenseIdentityIpc::Stored(_) => {
            None
        }
    }
}

/// Sync loop, right after `on_heartbeat_answer` (which has taken the location list of the same
/// answer): applies a name / location edited in the panel to this Host, as the Host window would.
/// Does nothing unless this is a Host, the panel announces `name_push` and the edit is newer.
pub async fn apply_pushed(body: Option<&str>) {
    let Some(push) = body.and_then(push_from_answer) else {
        return;
    };
    if !is_host(super::installed_role()) {
        return;
    }
    let _guard = IDENTITY_LOCK.lock().await;
    let stored = tokio::task::spawn_blocking(read_stored)
        .await
        .ok()
        .flatten()
        .unwrap_or_default();
    let Some(next) = plan_push(&push, applied_rev(), locations().as_ref(), &stored) else {
        return;
    };
    if next != stored {
        if let Err(err) = store(next.clone()).await {
            log::error!("Sense Remote: panel name / location not stored here: {err}");
            return;
        }
        update_builtin(&next);
        log::info!("Sense Remote: name / location changed in the panel and applied here");
    }
    config::LocalConfig::set_option(OPTION_IDENTITY_REV.to_owned(), push.rev.to_string());
}

async fn set_in_server(name: &str, location_id: &str) -> String {
    if !is_host(super::installed_role()) {
        return error(ERR_UNAVAILABLE);
    }
    let _guard = IDENTITY_LOCK.lock().await;
    let (Some(name), Some(location_id)) = (clean_name(name), clean_location_id(location_id)) else {
        return error(ERR_INVALID);
    };
    let stored = tokio::task::spawn_blocking(read_stored)
        .await
        .ok()
        .flatten()
        .unwrap_or_default();
    let list = locations();
    let location_name = location_name_for(location_id.as_deref(), list.as_ref(), &stored);

    let id = config::Config::get_id();
    let uuid = crate::encode64(hbb_common::get_uuid());
    let (secret_key, _) = config::Config::get_key_pair();
    let ts = next_ts();
    let Some(body) = signed_body(&id, &uuid, ts, &name, location_id.as_deref(), &secret_key) else {
        log::warn!("Sense Remote: device-info not sent, no device key");
        return error(ERR_OTHER);
    };
    let url = format!("{}{PATH}", super::api_server());
    let answer = crate::common::post_request_with_status(url, body.to_string(), "")
        .await
        .map_err(|_| ());
    note_panel(matches!(&answer, Ok((status, _)) if *status < 500));
    let status = answer.as_ref().map(|(status, _)| *status).ok();
    let (name, location_id) = match map_answer(answer, &name, location_id.as_deref()) {
        Ok(taken) => taken,
        Err(code) => {
            // Only the outcome, never the name or the location.
            log::warn!("Sense Remote: device-info not taken ({code}, status {status:?})");
            return error(code);
        }
    };
    let identity = StoredIdentity {
        name,
        location: location_name,
        location_id: location_id.unwrap_or_default(),
    };
    if let Err(err) = store(identity.clone()).await {
        log::error!("Sense Remote: device-info taken by the panel but not stored here: {err}");
        return error(ERR_STORE);
    }
    update_builtin(&identity);
    log::info!("Sense Remote: name / location changed on the Host and sent to the panel");
    json!({ "ok": true }).to_string()
}

/// `ts` of the next request: the clock, always above the last one sent (stored before sending).
fn next_ts() -> i64 {
    let last = super::report_sig::parse_reservation(&config::LocalConfig::get_option(OPTION_INFO_TS));
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let ts = super::report_sig::next_ts(last, now);
    config::LocalConfig::set_option(OPTION_INFO_TS.to_owned(), ts.to_string());
    ts
}

// ---------------------------------------------------------------------------------------------
// UI side (FFI)
// ---------------------------------------------------------------------------------------------

/// UI → `--server`. Windows: only a SYSTEM-owned main pipe (the service's `--server`), as for
/// the permanent password; macOS: the user `--server`.
#[tokio::main(flavor = "current_thread")]
async fn ipc_call(message: SenseIdentityIpc, timeout_ms: u64) -> Option<String> {
    #[cfg(windows)]
    let mut conn = match crate::ipc::connect_main_system(1_000).await {
        Ok(conn) => conn,
        Err(err) => {
            log::warn!("Sense Remote: the main IPC is not served by the service: {err}");
            return None;
        }
    };
    #[cfg(not(windows))]
    let mut conn = crate::ipc::connect(1_000, "").await.ok()?;
    conn.send(&crate::ipc::Data::SenseIdentitySet(message)).await.ok()?;
    match conn.next_timeout(timeout_ms).await {
        Ok(Some(crate::ipc::Data::SenseIdentitySet(SenseIdentityIpc::Answer(answer)))) => {
            Some(answer)
        }
        _ => None,
    }
}

/// `main_sense_identity`: `{name, location_id, location_name, locations: [{id, name}], panel:
/// "ok" | "unreachable" | null}`. Without the service: the stored values, no list, `panel` null.
pub fn ffi_identity() -> String {
    if let Some(answer) = ipc_call(SenseIdentityIpc::Query, QUERY_TIMEOUT_MS) {
        return answer;
    }
    identity_json(&read_stored().unwrap_or_default(), None, None).to_string()
}

/// `main_sense_identity_set`: `{ok: true}` or `{error: "invalid" | "network" |
/// "location_not_in_project" | "unavailable" | "store" | "other"}`.
pub fn ffi_identity_set(name: &str, location_id: &str) -> String {
    let (Some(name), Some(location_id)) = (clean_name(name), clean_location_id(location_id)) else {
        return error(ERR_INVALID);
    };
    let message = SenseIdentityIpc::Set {
        name,
        location_id: location_id.unwrap_or_default(),
    };
    let Some(answer) = ipc_call(message, SET_TIMEOUT_MS) else {
        return error(ERR_UNAVAILABLE);
    };
    if serde_json::from_str::<Value>(&answer).ok().and_then(|v| v.get("ok").cloned())
        == Some(json!(true))
    {
        if let Some(stored) = read_stored() {
            update_builtin(&stored);
        }
    }
    answer
}

/// `main_sense_host_recent_conns` (H2): `[{name, at, seconds, screens}]`, newest first; `[]`
/// without the service.
pub fn ffi_host_recent_conns() -> String {
    ipc_call(SenseIdentityIpc::RecentQuery, QUERY_TIMEOUT_MS).unwrap_or_else(|| "[]".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VECTOR: &str = include_str!("testdata/device-info-v1.json");

    fn list(items: &[(&str, &str)]) -> SenseLocations {
        SenseLocations {
            rev: 9,
            items: items
                .iter()
                .map(|(id, name)| ((*id).to_owned(), (*name).to_owned()))
                .collect(),
        }
    }

    fn stored(name: &str, location: &str, location_id: &str) -> StoredIdentity {
        StoredIdentity {
            name: name.to_owned(),
            location: location.to_owned(),
            location_id: location_id.to_owned(),
        }
    }

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

    /// The panel made and checked this vector (`verifyDeviceInfoSignature`); the client's bytes
    /// must be the same, byte for byte, and the panel's signature must verify on them.
    #[test]
    fn signed_bytes_match_the_panel_vector() {
        let vector: Value = serde_json::from_str(VECTOR).unwrap();
        assert_eq!(vector["prefix"].as_str().unwrap().as_bytes(), PREFIX);
        let pk = vector["device_pk"].as_str().unwrap();
        let cases = vector["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 3);
        for case in cases {
            let body = &case["body"];
            let bytes = signed_bytes(
                body["id"].as_str().unwrap(),
                body["uuid"].as_str().unwrap(),
                body["ts"].as_i64().unwrap(),
                body["name"].as_str().unwrap(),
                body["location_id"].as_str(),
            );
            let sig = body["sig"].as_str().unwrap();
            match case["signed_text"].as_str() {
                Some(text) => {
                    assert_eq!(String::from_utf8(bytes.clone()).unwrap(), text, "{}", case["name"]);
                    assert!(verify(pk, &bytes, sig), "{}", case["name"]);
                }
                None => assert!(!verify(pk, &bytes, sig), "{}", case["name"]),
            }
        }
    }

    #[test]
    fn signed_body_verifies_with_the_device_key() {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        let body = signed_body("123456789", "dXVpZA", 1_795_000_000, "Kiosk", Some("loc_1"), &sk.0)
            .unwrap();
        let keys: Vec<&String> = body.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 6);
        for key in ["id", "uuid", "ts", "name", "location_id", "sig"] {
            assert!(body.get(key).is_some(), "{key}");
        }
        let sig = body["sig"].as_str().unwrap();
        assert_eq!(sig.len(), 86);
        let pk = URL_SAFE_NO_PAD.encode(pk.0);
        let bytes = signed_bytes("123456789", "dXVpZA", 1_795_000_000, "Kiosk", Some("loc_1"));
        assert!(verify(&pk, &bytes, sig));
        // Another name, another location or no location: the signature no longer holds.
        for other in [
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "Kiosk 2", Some("loc_1")),
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "Kiosk", Some("loc_2")),
            signed_bytes("123456789", "dXVpZA", 1_795_000_000, "Kiosk", None),
            signed_bytes("123456789", "dXVpZA", 1_795_000_001, "Kiosk", Some("loc_1")),
        ] {
            assert!(!verify(&pk, &other, sig));
        }
        // No key, no body.
        assert_eq!(signed_body("1", "u", 1, "K", None, &[]), None);
        assert_eq!(signed_body("1", "u", 1, "K", None, &[0u8; 32]), None);
        let body = signed_body("1", "u", 1, "K", None, &sk.0).unwrap();
        assert_eq!(body["location_id"], Value::Null);
    }

    #[test]
    fn name_and_location_id_rules() {
        assert_eq!(clean_name("  Kiosk 1 "), Some("Kiosk 1".to_owned()));
        assert_eq!(clean_name(&"ş".repeat(64)), Some("ş".repeat(64)));
        for bad in ["", "   ", "a\tb", "a\nb", "\u{7f}"] {
            assert_eq!(clean_name(bad), None, "{bad:?}");
        }
        assert_eq!(clean_name(&"a".repeat(65)), None);

        assert!(is_location_id("loc_01JX-a"));
        for bad in ["", "loc_", "loc_a b", "prj_1", "LOC_1", "loc_ş"] {
            assert!(!is_location_id(bad), "{bad}");
        }
        assert!(!is_location_id(&format!("loc_{}", "a".repeat(61))));
        assert!(is_location_id(&format!("loc_{}", "a".repeat(60))));
        assert_eq!(clean_location_id(" "), Some(None));
        assert_eq!(clean_location_id(" loc_1 "), Some(Some("loc_1".to_owned())));
        assert_eq!(clean_location_id("Galeri 1"), None);
    }

    #[test]
    fn panel_answers_map_to_ui_codes() {
        let ok = |body: &str| map_answer(Ok((200, body.to_owned())), "Sent", Some("loc_s"));
        assert_eq!(
            ok(r#"{"name":"Kiosk","location_id":"loc_1"}"#),
            Ok(("Kiosk".to_owned(), Some("loc_1".to_owned())))
        );
        assert_eq!(ok(r#"{"name":"Kiosk","location_id":null}"#), Ok(("Kiosk".to_owned(), None)));
        // A 200 that can not be read keeps what was sent.
        assert_eq!(ok("not json"), Ok(("Sent".to_owned(), Some("loc_s".to_owned()))));
        let err = |status: u16, body: &str| map_answer(Ok((status, body.to_owned())), "S", None);
        assert_eq!(err(400, r#"{"error":"location_not_in_project"}"#), Err(ERR_LOCATION));
        assert_eq!(err(400, r#"{"error":"validation"}"#), Err(ERR_INVALID));
        assert_eq!(err(400, r#"{"error":"future"}"#), Err(ERR_OTHER));
        assert_eq!(err(401, r#"{"error":"bad_signature"}"#), Err(ERR_OTHER));
        assert_eq!(err(404, r#"{"error":"not_found"}"#), Err(ERR_OTHER));
        assert_eq!(err(409, r#"{"error":"replayed"}"#), Err(ERR_OTHER));
        assert_eq!(err(429, r#"{"error":"rate_limited"}"#), Err(ERR_OTHER));
        assert_eq!(err(502, "Bad gateway"), Err(ERR_NETWORK));
        assert_eq!(map_answer(Err(()), "S", None), Err(ERR_NETWORK));
    }

    #[test]
    fn stored_identity_stays_readable_by_the_installer() {
        let identity = stored("Kiosk", "Galeri 1", "loc_1");
        let hex = identity.encode();
        assert!(hex.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(StoredIdentity::decode(&hex), Some(identity));
        // `SetupInfo` (the installer's reader) takes it, ignoring the id.
        let info = crate::sense::SetupInfo::decode(&hex).unwrap();
        assert_eq!((info.name.as_str(), info.location.as_str()), ("Kiosk", "Galeri 1"));
        // What the installer wrote is read as an identity without an id.
        let installer = crate::sense::SetupInfo {
            name: "Kiosk".to_owned(),
            location: "Galeri 1".to_owned(),
        }
        .encode()
        .unwrap();
        assert_eq!(StoredIdentity::decode(&installer), Some(stored("Kiosk", "Galeri 1", "")));
        // No id, no field.
        assert!(!String::from_utf8(hex::decode(stored("K", "", "").encode()).unwrap())
            .unwrap()
            .contains("location_id"));
        assert_eq!(StoredIdentity::decode("zz"), None);
    }

    #[test]
    fn store_checks_values_again() {
        assert_eq!(
            StoredIdentity::checked(" Kiosk ", " Galeri 1 ", "loc_1"),
            Some(stored("Kiosk", "Galeri 1", "loc_1"))
        );
        assert_eq!(StoredIdentity::checked("Kiosk", "", ""), Some(stored("Kiosk", "", "")));
        assert_eq!(StoredIdentity::checked("", "G", "loc_1"), None);
        assert_eq!(StoredIdentity::checked("K", "G\n1", "loc_1"), None);
        assert_eq!(StoredIdentity::checked("K", &"g".repeat(97), ""), None);
        assert_eq!(StoredIdentity::checked("K", "G", "Galeri"), None);
    }

    #[test]
    fn identity_answer_shape() {
        let panel = list(&[("loc_1", "Galeri 1"), ("loc_2", "Giriş")]);
        // Stored id, list from the panel.
        let v = identity_json(&stored("Kiosk", "Galeri 1", "loc_1"), Some(&panel), Some(true));
        assert_eq!(
            v,
            json!({
                "name": "Kiosk",
                "location_id": "loc_1",
                "location_name": "Galeri 1",
                "locations": [{"id": "loc_1", "name": "Galeri 1"}, {"id": "loc_2", "name": "Giriş"}],
                "panel": "ok",
            })
        );
        // The panel renamed the location: its name wins.
        let v = identity_json(&stored("Kiosk", "Eski ad", "loc_2"), Some(&panel), Some(false));
        assert_eq!(v["location_name"], "Giriş");
        assert_eq!(v["panel"], "unreachable");
        // Before Sürüm 4 only the name was stored: found by its name.
        let v = identity_json(&stored("Kiosk", "Giriş", ""), Some(&panel), None);
        assert_eq!(v["location_id"], "loc_2");
        assert_eq!(v["panel"], Value::Null);
        // Two locations with that name: no guess.
        let twice = list(&[("loc_1", "Giriş"), ("loc_2", "Giriş")]);
        assert_eq!(identity_json(&stored("K", "Giriş", ""), Some(&twice), None)["location_id"], "");
        // No list yet: the stored location is the only choice.
        let v = identity_json(&stored("Kiosk", "Galeri 1", ""), None, None);
        assert_eq!(v["locations"], json!([{"id": "", "name": "Galeri 1"}]));
        assert_eq!(v["location_name"], "Galeri 1");
        // Nothing stored.
        let v = identity_json(&StoredIdentity::default(), None, None);
        assert_eq!(v["locations"], json!([]));
        assert_eq!(v["name"], "");
    }

    #[test]
    fn location_name_to_store() {
        let panel = list(&[("loc_1", "Galeri 1")]);
        let old = stored("K", "Depo", "loc_9");
        assert_eq!(location_name_for(Some("loc_1"), Some(&panel), &old), "Galeri 1");
        assert_eq!(location_name_for(Some("loc_9"), Some(&panel), &old), "Depo");
        assert_eq!(location_name_for(Some("loc_9"), None, &old), "Depo");
        assert_eq!(location_name_for(Some("loc_5"), Some(&panel), &old), "");
        assert_eq!(location_name_for(None, Some(&panel), &old), "");
    }

    #[test]
    fn heartbeat_state() {
        // One test owns the static state (tests run in parallel otherwise).
        let mut sense = json!({ "v": 1 });
        extend_heartbeat(&mut sense);
        assert_eq!(sense.get("loc_rev"), None, "no list, no loc_rev");
        assert_eq!(panel_ok(), None);

        on_heartbeat_answer(None);
        assert_eq!(panel_ok(), Some(false));
        on_heartbeat_answer(Some(r#"{"sense_server_time":1}"#));
        assert_eq!(panel_ok(), Some(true));
        assert_eq!(locations(), None);

        on_heartbeat_answer(Some(
            r#"{"sense_locations":{"rev":42,"items":[{"id":"loc_1","name":"Galeri 1"}]}}"#,
        ));
        assert_eq!(locations(), Some(SenseLocations { rev: 42, items: list(&[("loc_1", "Galeri 1")]).items }));
        let mut sense = json!({ "v": 1 });
        extend_heartbeat(&mut sense);
        assert_eq!(sense["loc_rev"], 42);
        // An answer without the field keeps the list (it is still current).
        on_heartbeat_answer(Some("{}"));
        assert_eq!(locations().unwrap().rev, 42);
        // Not reached: the list stays, the panel is unreachable.
        on_heartbeat_answer(None);
        assert_eq!(locations().unwrap().rev, 42);
        assert_eq!(panel_ok(), Some(false));
    }

    fn push_body(rev: u64, name: &str, location_id: Option<&str>) -> String {
        json!({
            "sense_panel_caps": ["health_v2", "name_push"],
            "sense_identity": { "rev": rev, "name": name, "location_id": location_id },
        })
        .to_string()
    }

    #[test]
    fn panel_push_is_read_only_when_announced_and_well_formed() {
        let ok = push_from_answer(&push_body(5, " Salon 1 ", Some("loc_1"))).unwrap();
        assert_eq!(
            ok,
            PanelPush { rev: 5, name: "Salon 1".to_owned(), location_id: Some("loc_1".to_owned()) }
        );
        assert_eq!(push_from_answer(&push_body(5, "Kiosk", None)).unwrap().location_id, None);
        // Not announced (older panel) or no field: nothing.
        let silent = json!({ "sense_identity": { "rev": 5, "name": "K", "location_id": null } });
        assert_eq!(push_from_answer(&silent.to_string()), None);
        assert_eq!(push_from_answer(r#"{"sense_panel_caps":["name_push"]}"#), None);
        assert_eq!(push_from_answer("{}"), None);
        assert_eq!(push_from_answer("nope"), None);
        // Out-of-contract values.
        for bad in [
            push_body(0, "K", None),
            push_body(5, "", None),
            push_body(5, &"x".repeat(65), None),
            push_body(5, "a\u{7}b", None),
            push_body(5, "K", Some("kok_1")),
            push_body(5, "K", Some("loc_")),
            push_body(MAX_IDENTITY_REV + 1, "K", None),
        ] {
            assert_eq!(push_from_answer(&bad), None, "{bad}");
        }
        let wrong_shape = json!({
            "sense_panel_caps": ["name_push"],
            "sense_identity": { "rev": -1, "name": "K", "location_id": null },
        });
        assert_eq!(push_from_answer(&wrong_shape.to_string()), None);
    }

    #[test]
    fn panel_push_plan() {
        let panel = list(&[("loc_1", "Galeri 1"), ("loc_2", "Galeri 2")]);
        let old = stored("Eski", "Galeri 1", "loc_1");
        let push = |rev, name: &str, loc: Option<&str>| PanelPush {
            rev,
            name: name.to_owned(),
            location_id: loc.map(str::to_owned),
        };
        // Newer edit: name and the location NAME from the panel's list.
        assert_eq!(
            plan_push(&push(7, "Yeni", Some("loc_2")), 3, Some(&panel), &old),
            Some(stored("Yeni", "Galeri 2", "loc_2"))
        );
        // No location.
        assert_eq!(
            plan_push(&push(7, "Yeni", None), 3, Some(&panel), &old),
            Some(stored("Yeni", "", ""))
        );
        // Not newer than the applied one (replay / equal): nothing.
        assert_eq!(plan_push(&push(3, "Yeni", None), 3, Some(&panel), &old), None);
        assert_eq!(plan_push(&push(2, "Yeni", None), 3, Some(&panel), &old), None);
        // A location the panel's list does not name: not applied (retried when the list comes).
        assert_eq!(plan_push(&push(7, "Yeni", Some("loc_9")), 3, Some(&panel), &old), None);
        assert_eq!(plan_push(&push(7, "Yeni", Some("loc_9")), 3, None, &old), None);
        // Without a list the stored location is still a valid choice.
        assert_eq!(
            plan_push(&push(7, "Yeni", Some("loc_1")), 3, None, &old),
            Some(stored("Yeni", "Galeri 1", "loc_1"))
        );
        // Values the store would refuse (location name too long) are refused here too.
        let long_name = "g".repeat(MAX_LOCATION_CHARS + 1);
        let long = list(&[("loc_3", long_name.as_str())]);
        assert_eq!(plan_push(&push(7, "Yeni", Some("loc_3")), 3, Some(&long), &old), None);
    }

    #[test]
    fn ipc_message_round_trip() {
        for message in [
            SenseIdentityIpc::Query,
            SenseIdentityIpc::Set {
                name: "Kiosk".to_owned(),
                location_id: "loc_1".to_owned(),
            },
            SenseIdentityIpc::RecentQuery,
            SenseIdentityIpc::Answer("{}".to_owned()),
            SenseIdentityIpc::Store {
                name: "K".to_owned(),
                location: "G".to_owned(),
                location_id: String::new(),
            },
            SenseIdentityIpc::Stored(true),
        ] {
            let data = crate::ipc::Data::SenseIdentitySet(message.clone());
            let text = serde_json::to_string(&data).unwrap();
            match serde_json::from_str::<crate::ipc::Data>(&text).unwrap() {
                crate::ipc::Data::SenseIdentitySet(back) => assert_eq!(back, message),
                other => panic!("{other:?}"),
            }
        }
    }

    #[test]
    fn answers_only_the_ui_requests() {
        // `on_main_ipc` gives nothing back for the daemon's or its own messages.
        let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
        for message in [
            SenseIdentityIpc::Answer("{}".to_owned()),
            SenseIdentityIpc::Stored(true),
            SenseIdentityIpc::Store {
                name: "K".to_owned(),
                location: String::new(),
                location_id: String::new(),
            },
        ] {
            assert_eq!(rt.block_on(on_main_ipc(message)), None);
        }
    }
}
