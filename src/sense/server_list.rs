//! Sense Remote (Sürüm 11, SRV; design note `Calisma/plan/2026-11-27_s11-sunucu-secimi.md`): the
//! signed server list. The app learns its ID (hbbs) and relay (hbbr) servers from the panel, so a
//! server can be added or moved without a new build; without a valid list it uses the server built
//! into this build (`server.rs`), never RustDesk's.
//!
//! Same envelope shape and panel keys as the strategy envelope (`{k, p, s}`, Ed25519), but its own
//! signing prefix `sense-remote/servers/v1\n`, so no other signed object counts as a server list.
//! It does not touch the device `seq` (it never races the permission envelopes). Checks, in the
//! panel's order (`packages/shared/src/servers-node.ts`, shared vector `testdata/servers-v1.json`):
//!
//! envelope shape → `k` known → p/s decode (s 64 bytes) → signature (servers prefix) → JSON +
//! schema (no unknown field, `typ` servers, 1–8 servers, ids and priorities unique, addresses
//! `host[:port]` that are not RustDesk's or local, keys our format and not RustDesk's, ONE key for
//! the whole list, `0 < exp − iat ≤ 30 days`) → `iss` → `did` + `duuid` (this computer) →
//! `iat − 300 ≤ now ≤ exp + 300` → `rev` not older than the stored one (same `rev` only with a newer
//! `iat`: the panel re-signs before `exp`).
//!
//! Delivery: the heartbeat answer (`sense_servers`), only to a build that reports `sense.srv`. The
//! service stores the verified envelope as the option `sense-servers`; every reader (the service
//! itself, the UI process over IPC) verifies it again before use (signature and device; not time:
//! the last accepted list stays in use). A value written by hand is no list.

use super::envelope_keys::{self, TrustedKey};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config::Config,
    log,
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

/// Domain separation: signed data = this prefix (ASCII) ‖ payload bytes.
pub const SIGNING_PREFIX: &[u8] = b"sense-remote/servers/v1\n";
/// Same allowance as the strategy envelope.
pub const CLOCK_SKEW_S: i64 = super::envelope::CLOCK_SKEW_S;
/// `exp − iat` upper limit: 30 days.
pub const MAX_LIFETIME_S: i64 = 30 * 24 * 3600;
/// Servers in one list.
pub const MAX_SERVERS: usize = 8;
/// Heartbeat answer key carrying the envelope.
pub const KEY_ANSWER: &str = "sense_servers";
/// Heartbeat `sense` field: `{rev, exp}` of the stored list (`{0, 0}` without one).
pub const HEARTBEAT_FIELD: &str = "srv";
/// Option holding the verified envelope (JSON text). Not a secret: signed public data.
pub const OPTION_STORE: &str = "sense-servers";
/// Id of the built-in server in `effective` and in `sense.relay_rtt`; reserved, never a list id.
pub const BUILTIN_ID: &str = "builtin";
/// Where the list is received (the platforms whose `--server` sends the heartbeat).
pub const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));

const MAX_PAYLOAD_CHARS: usize = 65_536;
const SIGNATURE_CHARS: usize = 86;
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

/// Why a list was refused. Names are the panel's `ServersRejectReason` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongIssuer,
    WrongDevice,
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
            Reason::NotYetValid => "not_yet_valid",
            Reason::Expired => "expired",
            Reason::Replayed => "replayed",
        }
    }
}

/// One server of the list (the panel's `ServerEntry`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ServerEntry {
    pub id: String,
    /// Shown to people, e.g. "Türkiye (İstanbul)".
    pub name: String,
    /// hbbs, `host[:port]` (21116 when missing).
    pub rendezvous: String,
    /// hbbr, `host[:port]` (21117 when missing).
    pub relay: String,
    /// hbbs public key (base64 of 32 bytes); the same for every server of a list.
    pub key: String,
    /// 1 = first choice.
    pub priority: i64,
}

/// A verified list, servers in priority order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerList {
    pub rev: u64,
    pub iat: i64,
    pub exp: i64,
    pub servers: Vec<ServerEntry>,
}

/// What this computer expects; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    pub iss: &'a str,
    pub did: &'a str,
    pub duuid: &'a str,
    /// Local clock, Unix seconds; `None` skips the time window (re-checking the stored list).
    pub now_s: Option<i64>,
    /// `rev` and `iat` of the stored list, 0 if none.
    pub last_rev: u64,
    pub last_iat: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    v: i64,
    typ: String,
    iss: String,
    did: String,
    duuid: String,
    rev: i64,
    iat: i64,
    exp: i64,
    servers: Vec<ServerEntry>,
}

fn is_safe_int(value: i64) -> bool {
    (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value)
}

fn len_between(value: &str, min: usize, max: usize) -> bool {
    // zod counts UTF-16 units.
    let n = value.encode_utf16().count();
    (min..=max).contains(&n)
}

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// `id`: `^[a-z0-9-]{1,32}$`, not the reserved `BUILTIN_ID`.
fn is_server_id(value: &str) -> bool {
    value != BUILTIN_ID
        && (1..=32).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Shown name: 1–64 UTF-16 units, no control character, no space at either end (zod `trim()`).
fn is_server_name(value: &str) -> bool {
    let edge = |c: char| c.is_whitespace() || c == '\u{feff}';
    len_between(value, 1, 64)
        && !value.chars().any(char::is_control)
        && !value.starts_with(edge)
        && !value.ends_with(edge)
}

/// The host part (before an optional `:port`) is plain ASCII: letters, digits, dots, dashes. On
/// top of `server::is_valid_server`, like the panel's `isValidServerAddress`.
fn is_plain_host(value: &str) -> bool {
    let host = value.split(':').next().unwrap_or_default();
    !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// One address of a list: the panel's `ServerAddress` (≤ 253 characters).
pub fn is_list_address(value: &str) -> bool {
    value.len() <= 253 && is_plain_host(value) && super::server::is_valid_server(value)
}

/// The panel's `ServerList` rules.
fn is_valid_list(servers: &[ServerEntry]) -> bool {
    if servers.is_empty() || servers.len() > MAX_SERVERS {
        return false;
    }
    let entries_ok = servers.iter().all(|s| {
        is_server_id(&s.id)
            && is_server_name(&s.name)
            && is_list_address(&s.rendezvous)
            && is_list_address(&s.relay)
            && super::server::is_valid_key(&s.key)
            && (1..=99).contains(&s.priority)
    });
    let unique = servers.iter().enumerate().all(|(i, s)| {
        servers[..i]
            .iter()
            .all(|o| o.id != s.id && o.priority != s.priority)
    });
    let one_key = servers.iter().all(|s| s.key == servers[0].key);
    entries_ok && unique && one_key
}

impl Payload {
    /// The panel's `ServersPayload` schema.
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "servers"
            && len_between(&self.iss, 1, 253)
            && len_between(&self.did, 1, 64)
            && len_between(&self.duuid, 1, 128)
            && self.rev > 0
            && self.iat >= 0
            && self.exp > 0
            && [self.rev, self.iat, self.exp].into_iter().all(is_safe_int)
            && self.exp > self.iat
            && self.exp - self.iat <= MAX_LIFETIME_S
            && is_valid_list(&self.servers)
    }
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, server lists cannot be verified");
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
pub fn verify(envelope: &Value, keys: &[TrustedKey], expect: &Expect) -> Result<ServerList, Reason> {
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
    // 4. Signature over the servers prefix ‖ payload bytes, exactly as received.
    if !signature_ok(&key.public_key, &payload, &signature) {
        return Err(Reason::BadSignature);
    }
    // 5. Schema of the signed bytes (never re-canonicalized).
    let payload: Payload = serde_json::from_slice(&payload).map_err(|_| Reason::BadPayload)?;
    if !payload.is_valid() {
        return Err(Reason::BadPayload);
    }
    // 6. Issuer and device.
    if payload.iss != expect.iss {
        return Err(Reason::WrongIssuer);
    }
    if payload.did != expect.did || payload.duuid != expect.duuid {
        return Err(Reason::WrongDevice);
    }
    // 7. Validity window with clock skew allowance (not for the stored list).
    if let Some(now_s) = expect.now_s {
        if now_s < payload.iat.saturating_sub(CLOCK_SKEW_S) {
            return Err(Reason::NotYetValid);
        }
        if now_s > payload.exp.saturating_add(CLOCK_SKEW_S) {
            return Err(Reason::Expired);
        }
    }
    // 8. `rev` never goes back; the same `rev` only as a newer signature.
    let rev = payload.rev as u64; // > 0, checked by the schema
    if rev < expect.last_rev || (rev == expect.last_rev && payload.iat <= expect.last_iat) {
        return Err(Reason::Replayed);
    }
    let mut servers = payload.servers;
    servers.sort_by_key(|s| s.priority);
    Ok(ServerList {
        rev,
        iat: payload.iat,
        exp: payload.exp,
        servers,
    })
}

/// The server built into this build, shown as `server::SERVER_NAME`.
pub fn builtin() -> ServerEntry {
    ServerEntry {
        id: BUILTIN_ID.to_owned(),
        name: super::server::SERVER_NAME.to_owned(),
        rendezvous: super::server::RENDEZVOUS_SERVER.to_owned(),
        relay: super::server::RELAY_SERVER.to_owned(),
        key: super::server::RS_PUB_KEY.to_owned(),
        priority: 1,
    }
}

/// The servers to use, in priority order: the verified list, or the built-in server alone.
pub fn effective(list: Option<&ServerList>) -> Vec<ServerEntry> {
    match list {
        Some(list) if !list.servers.is_empty() => list.servers.clone(),
        _ => vec![builtin()],
    }
}

/// `sense.srv` for the heartbeat.
pub fn heartbeat_value(list: Option<&ServerList>) -> Value {
    match list {
        Some(list) => json!({ "rev": list.rev, "exp": list.exp }),
        None => json!({ "rev": 0, "exp": 0 }),
    }
}

/// Re-checks a stored envelope (signature, schema, issuer, device; not time or `rev`). `None` for
/// an empty, unreadable or forged value.
pub fn verify_stored(text: &str, keys: &[TrustedKey], iss: &str, did: &str, duuid: &str) -> Option<ServerList> {
    if text.trim().is_empty() {
        return None;
    }
    let envelope: Value = serde_json::from_str(text).ok()?;
    let expect = Expect {
        iss,
        did,
        duuid,
        now_s: None,
        last_rev: 0,
        last_iat: i64::MIN,
    };
    match verify(&envelope, keys, &expect) {
        Ok(list) => Some(list),
        Err(reason) => {
            log::warn!("Sense Remote: stored server list ignored ({})", reason.as_str());
            None
        }
    }
}

fn own_device() -> (String, String, String) {
    (
        super::envelope::expected_issuer(),
        Config::get_id(),
        crate::encode64(hbb_common::get_uuid()),
    )
}

/// Last stored text and its check, so the signature is verified once per change.
fn cache() -> &'static Mutex<Option<(String, Option<ServerList>)>> {
    static CACHE: OnceLock<Mutex<Option<(String, Option<ServerList>)>>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// The verified list of `text` (an `OPTION_STORE` value), cached.
pub fn list_of_stored(text: &str) -> Option<ServerList> {
    let mut cache = cache().lock().unwrap_or_else(|e| e.into_inner());
    if let Some((cached, list)) = cache.as_ref() {
        if cached == text {
            return list.clone();
        }
    }
    let (iss, did, duuid) = own_device();
    let list = verify_stored(text, envelope_keys::trusted_keys(), &iss, &did, &duuid);
    *cache = Some((text.to_owned(), list.clone()));
    list
}

/// This process's stored list (the service: its own option).
pub fn stored() -> Option<ServerList> {
    list_of_stored(&Config::get_option(OPTION_STORE))
}

/// The UI process: the service's stored list over IPC, verified here again.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub async fn stored_in_service() -> Option<ServerList> {
    let text = crate::ipc::get_option_async(OPTION_STORE).await;
    list_of_stored(&text)
}

/// Sync loop: `sense.srv` (unsigned, added after the report is signed).
pub fn extend_heartbeat(sense: &mut Value) {
    if !SUPPORTED {
        return;
    }
    if let Some(object) = sense.as_object_mut() {
        object.insert(HEARTBEAT_FIELD.to_owned(), heartbeat_value(stored().as_ref()));
    }
}

/// What the Host's registration depends on: the ID servers (in order) and the key.
pub fn registration(list: Option<&ServerList>) -> (Vec<String>, String) {
    let servers = effective(list);
    let key = servers.first().map(|s| s.key.clone()).unwrap_or_default();
    (servers.into_iter().map(|s| s.rendezvous).collect(), key)
}

/// What to do with the `sense_servers` value of an answer. Pure.
pub fn accept(value: &Value, keys: &[TrustedKey], expect: &Expect) -> Result<ServerList, Reason> {
    verify(value, keys, expect)
}

/// Sync loop: verifies and stores `sense_servers` from the heartbeat answer. A refused list is
/// logged and changes nothing.
pub fn on_answer(answer: &str) {
    if !SUPPORTED {
        return;
    }
    let Ok(answer) = serde_json::from_str::<Value>(answer) else {
        return;
    };
    let Some(value) = answer.get(KEY_ANSWER) else {
        return;
    };
    let current = stored();
    let (iss, did, duuid) = own_device();
    let expect = Expect {
        iss: &iss,
        did: &did,
        duuid: &duuid,
        now_s: Some(hbb_common::get_time() / 1000),
        last_rev: current.as_ref().map_or(0, |l| l.rev),
        last_iat: current.as_ref().map_or(0, |l| l.iat),
    };
    match accept(value, envelope_keys::trusted_keys(), &expect) {
        Ok(list) => {
            let ids: Vec<&str> = list.servers.iter().map(|s| s.id.as_str()).collect();
            log::info!(
                "Sense Remote: server list rev {} applied ({} servers: {})",
                list.rev,
                list.servers.len(),
                ids.join(",")
            );
            let before = registration(current.as_ref());
            Config::set_option(OPTION_STORE.to_owned(), value.to_string());
            // The Host registers on the listed ID servers with the list's key: re-register
            // when either changed.
            #[cfg(not(target_os = "ios"))]
            {
                if before != registration(Some(&list)) {
                    log::info!("Sense Remote: ID servers changed, re-registering");
                    crate::rendezvous_mediator::RendezvousMediator::restart();
                }
            }
        }
        Err(reason) => {
            log::warn!("Sense Remote: server list rejected ({})", reason.as_str());
        }
    }
}

#[cfg(test)]
mod tests {
    // Sense Remote: verification against the panel's shared vector (`servers-v1.json`, made by
    // `packages/shared/scripts/make-servers-vector.ts` with keys that existed only in memory;
    // public data only). Copied verbatim: update both repositories in the same change.
    use super::*;
    use crate::sense::envelope_keys::{key_id, parse_keys};

    const VECTOR: &str = include_str!("testdata/servers-v1.json");

    fn vector() -> Value {
        serde_json::from_str(VECTOR).expect("servers-v1.json is valid JSON")
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

    fn expect_of(e: &Value) -> Expect<'_> {
        Expect {
            iss: str_of(e, "iss"),
            did: str_of(e, "did"),
            duuid: str_of(e, "duuid"),
            now_s: Some(e["now_s"].as_i64().unwrap()),
            last_rev: e["last_rev"].as_u64().unwrap(),
            last_iat: e["last_iat"].as_i64().unwrap(),
        }
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
        assert_ne!(SIGNING_PREFIX, crate::sense::grants::SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::wol::SIGNING_PREFIX);
        assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
        assert_eq!(v["max_lifetime_s"].as_i64(), Some(MAX_LIFETIME_S));
        assert_eq!(v["max_servers"].as_u64(), Some(MAX_SERVERS as u64));
        assert!(!super::super::server::is_valid_key(str_of(&v, "rustdesk_key")));
        let keys = vector_keys(&v);
        assert_eq!(keys.len(), 2);
        for key in &keys {
            assert_eq!(key.k, key_id(&key.public_key));
        }
    }

    #[test]
    fn vector_cases_match() {
        let v = vector();
        let keys = vector_keys(&v);
        let cases = v["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 32);
        let mut failures = Vec::new();
        for case in cases {
            let name = str_of(case, "name");
            let wanted = str_of(case, "result");
            let got = verify(&case["envelope"], &keys, &expect_of(&case["expect"]));
            let got_name = match &got {
                Ok(_) => "ok",
                Err(reason) => reason.as_str(),
            };
            if got_name != wanted {
                failures.push(format!("{name}: expected {wanted}, got {got_name}"));
                continue;
            }
            if let Ok(list) = got {
                let mut signed: Vec<ServerEntry> =
                    serde_json::from_value(case["servers"].clone()).unwrap();
                signed.sort_by_key(|s| s.priority);
                assert_eq!(list.servers, signed, "{name}");
                assert_eq!(Some(list.rev), case["rev"].as_u64(), "{name}");
            }
        }
        assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
    }

    #[test]
    fn servers_come_in_priority_order() {
        let v = vector();
        let c = case(&v, "ok_two_unsorted");
        let list = verify(&c["envelope"], &vector_keys(&v), &expect_of(&c["expect"])).unwrap();
        let priorities: Vec<i64> = list.servers.iter().map(|s| s.priority).collect();
        assert_eq!(priorities, vec![1, 2]);
        assert_eq!(list.servers[0].name, "Türkiye (İstanbul)");
    }

    #[test]
    fn stored_list_is_checked_again_without_time() {
        let v = vector();
        let keys = vector_keys(&v);
        let c = case(&v, "ok_single");
        let e = &c["expect"];
        let text = c["envelope"].to_string();
        let (iss, did, duuid) = (str_of(e, "iss"), str_of(e, "did"), str_of(e, "duuid"));
        // Long expired: still the last accepted list.
        let list = verify_stored(&text, &keys, iss, did, duuid).expect("stored list verifies");
        assert_eq!(list.rev, 3);
        // Another computer's list, a forged one, garbage, nothing: no list.
        assert!(verify_stored(&text, &keys, iss, "987654321", duuid).is_none());
        let flipped = case(&v, "bad_signature_flipped")["envelope"].to_string();
        assert!(verify_stored(&flipped, &keys, iss, did, duuid).is_none());
        assert!(verify_stored("{\"x\":1}", &keys, iss, did, duuid).is_none());
        assert!(verify_stored("not json", &keys, iss, did, duuid).is_none());
        assert!(verify_stored("", &keys, iss, did, duuid).is_none());
        // No trusted key (a build without SENSE_ENVELOPE_KEYS): no list.
        assert!(verify_stored(&text, &[], iss, did, duuid).is_none());
    }

    #[test]
    fn without_a_list_the_builtin_server_is_used() {
        let only = effective(None);
        assert_eq!(only.len(), 1);
        let b = &only[0];
        assert_eq!(b.id, BUILTIN_ID);
        assert_eq!(b.rendezvous, super::super::server::RENDEZVOUS_SERVER);
        assert_eq!(b.relay, super::super::server::RELAY_SERVER);
        assert_eq!(b.key, super::super::server::RS_PUB_KEY);
        assert!(!is_server_id(BUILTIN_ID));
        // The built-in server passes the same address rules as a listed one.
        assert!(is_list_address(&b.rendezvous) && is_list_address(&b.relay));
        let empty = ServerList {
            rev: 1,
            iat: 0,
            exp: 1,
            servers: vec![],
        };
        assert_eq!(effective(Some(&empty)), only);
    }

    #[test]
    fn a_list_replaces_the_builtin_server() {
        let v = vector();
        let c = case(&v, "ok_single");
        let list = verify(&c["envelope"], &vector_keys(&v), &expect_of(&c["expect"])).unwrap();
        let servers = effective(Some(&list));
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].id, "tr1");
        assert!(servers.iter().all(|s| s.id != BUILTIN_ID));
    }

    #[test]
    fn heartbeat_field() {
        assert_eq!(heartbeat_value(None), json!({ "rev": 0, "exp": 0 }));
        let list = ServerList {
            rev: 4,
            iat: 10,
            exp: 20,
            servers: vec![builtin()],
        };
        assert_eq!(heartbeat_value(Some(&list)), json!({ "rev": 4, "exp": 20 }));
    }

    #[test]
    fn address_and_name_rules() {
        for ok in ["tr1.example.test", "192.0.2.10:21116", "A-b.c:1"] {
            assert!(is_list_address(ok), "{ok}");
        }
        for bad in [
            "rs-ny.rustdesk.com",
            "türkiye.test",
            "127.0.0.1",
            "a.test:0",
            "https://a.test",
            "",
        ] {
            assert!(!is_list_address(bad), "{bad}");
        }
        assert!(is_server_name("Türkiye (İstanbul)"));
        for bad in ["", " a", "a ", "a\u{7}b", "a\nb", &"x".repeat(65)] {
            assert!(!is_server_name(bad), "{bad:?}");
        }
        assert!(is_server_id("tr1") && is_server_id("yedek-2"));
        assert!(!is_server_id("TR1") && !is_server_id("") && !is_server_id(&"a".repeat(33)));
    }
}
