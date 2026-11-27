//! Sense Remote (Sürüm 11, SRV; design note `Calisma/plan/2026-11-27_s11-sunucu-secimi.md`): which
//! server of the list (`server_list::effective`) a connection uses, and the measurements behind it.
//!
//! - ID server: every listed hbbs is asked in priority order; a server that failed recently waits at
//!   the end of the order for a back-off (30 s doubling up to 10 min), then is tried first again, so
//!   the first choice comes back by itself once it answers (`IdHealth`).
//! - Relay: the service measures the TCP connect time to every listed relay every 10 minutes
//!   (`RttBook`) and reports it in the heartbeat (`sense.relay_rtt`); the panel keeps the Host's last
//!   values. A Controller picks the relay with the lowest Controller + Host total (`pick_relay`);
//!   without the Host's values (an older Host refuses a relay it did not offer) or with a single
//!   server it keeps the relay the Host offered. A direct connection is still tried first.
//! - Kullanıcı #145: one server (Türkiye) for now — the measurements are only shown, nothing
//!   switches.
//!
//! Everything deciding is pure; time and measurements come from the caller.

use super::server_list::{ServerEntry, ServerList};
use hbb_common::{config::Config, log};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

/// Probe interval in the service.
pub const PROBE_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// First probe this long after the service started (the network is often not ready at boot).
pub const FIRST_PROBE_AFTER: Duration = Duration::from_secs(30);
/// One TCP connect attempt.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// Samples kept per relay; the smallest one counts (one slow connect is not the server's fault).
pub const SAMPLES_KEPT: usize = 3;
/// A Host measurement older than this is not used for picking.
pub const HOST_RTT_MAX_AGE_S: i64 = 30 * 60;
/// Own measurements older than this are not used for picking.
pub const OWN_RTT_MAX_AGE_S: i64 = 30 * 60;
/// ID server back-off after a failure: first and largest wait.
pub const BACKOFF_FIRST: Duration = Duration::from_secs(30);
pub const BACKOFF_MAX: Duration = Duration::from_secs(10 * 60);
/// Heartbeat `sense` field with the relay measurements.
pub const HEARTBEAT_FIELD: &str = "relay_rtt";
/// Option where the service leaves its measurements for the UI process: `{at, rtt:[{id, ms}]}`.
pub const OPTION_RTT: &str = "sense-relay-rtt";
/// Panel endpoint with the Host's last measurements.
const PEER_RELAYS_PATH: &str = "/api/sense/peer-relays";

// ---------------------------------------------------------------------------------------------
// ID server order
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Down {
    until: Instant,
    backoff: Duration,
}

/// Recent ID server failures (by server id).
#[derive(Debug, Default, Clone)]
pub struct IdHealth {
    down: HashMap<String, Down>,
}

impl IdHealth {
    /// A connect to `id` failed at `now`: it waits at the end of the order for a growing back-off.
    pub fn record_failure(&mut self, id: &str, now: Instant) {
        let backoff = match self.down.get(id) {
            Some(d) => (d.backoff * 2).min(BACKOFF_MAX),
            None => BACKOFF_FIRST,
        };
        self.down.insert(
            id.to_owned(),
            Down {
                until: now + backoff,
                backoff,
            },
        );
    }

    /// `id` answered: back to its place by priority.
    pub fn record_success(&mut self, id: &str) {
        self.down.remove(id);
    }

    fn is_down(&self, id: &str, now: Instant) -> bool {
        self.down.get(id).is_some_and(|d| now < d.until)
    }

    /// `servers` (priority order) with the ones still waiting moved to the end (priority order
    /// among them too). Nothing is dropped: a server that is down is still tried last.
    pub fn order(&self, servers: &[ServerEntry], now: Instant) -> Vec<ServerEntry> {
        let (mut up, down): (Vec<ServerEntry>, Vec<ServerEntry>) = servers
            .iter()
            .cloned()
            .partition(|s| !self.is_down(&s.id, now));
        up.extend(down);
        up
    }
}

fn id_health() -> &'static Mutex<IdHealth> {
    static HEALTH: OnceLock<Mutex<IdHealth>> = OnceLock::new();
    HEALTH.get_or_init(Default::default)
}

/// Lowercase `host:port` with the default port, like upstream's `check_port`.
pub fn with_port(server: &str, default_port: i32) -> String {
    let server = server.trim().to_ascii_lowercase();
    if server.contains(':') {
        server
    } else {
        format!("{server}:{default_port}")
    }
}

/// The ID servers to ask, in order, for the given list.
pub fn rendezvous_order(list: Option<&ServerList>, now: Instant) -> Vec<ServerEntry> {
    let servers = super::server_list::effective(list);
    id_health()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .order(&servers, now)
}

/// Notes the outcome of a connect to the ID server `rendezvous` (`host:port`).
pub fn note_rendezvous(list: Option<&ServerList>, rendezvous: &str, ok: bool) {
    let servers = super::server_list::effective(list);
    let target = with_port(rendezvous, hbb_common::config::RENDEZVOUS_PORT);
    let Some(server) = servers
        .iter()
        .find(|s| with_port(&s.rendezvous, hbb_common::config::RENDEZVOUS_PORT) == target)
    else {
        return;
    };
    let mut health = id_health().lock().unwrap_or_else(|e| e.into_inner());
    if ok {
        health.record_success(&server.id);
    } else {
        health.record_failure(&server.id, Instant::now());
        log::info!("Sense Remote: ID server {} unreachable, tried last for a while", server.id);
    }
}

/// Whether `rendezvous` (`host[:port]`) is one of the listed ID servers (or the built-in one).
pub fn is_listed_rendezvous(list: Option<&ServerList>, rendezvous: &str) -> bool {
    let target = with_port(rendezvous, hbb_common::config::RENDEZVOUS_PORT);
    super::server_list::effective(list)
        .iter()
        .any(|s| with_port(&s.rendezvous, hbb_common::config::RENDEZVOUS_PORT) == target)
}

/// Whether `relay` (`host[:port]`) is one of the listed relays (or the built-in one).
pub fn is_listed_relay(list: Option<&ServerList>, relay: &str) -> bool {
    let target = with_port(relay, hbb_common::config::RELAY_PORT);
    super::server_list::effective(list)
        .iter()
        .any(|s| with_port(&s.relay, hbb_common::config::RELAY_PORT) == target)
}

// ---------------------------------------------------------------------------------------------
// Host side (the service)
// ---------------------------------------------------------------------------------------------

/// ID servers the Host registers on: every listed one (the built-in one without a list).
pub fn host_rendezvous_servers() -> Vec<String> {
    rendezvous_hosts(super::server_list::stored().as_ref())
}

/// Pure part of `host_rendezvous_servers`.
pub fn rendezvous_hosts(list: Option<&ServerList>) -> Vec<String> {
    super::server_list::effective(list)
        .into_iter()
        .map(|s| s.rendezvous)
        .collect()
}

/// The relay the Host offers through the ID server `rendezvous`: the one listed with it. `None`
/// without a list (the pinned built-in relay stays, as before).
pub fn host_relay_for(rendezvous: &str) -> Option<String> {
    relay_listed_with(super::server_list::stored().as_ref(), rendezvous)
}

/// Pure part of `host_relay_for`.
pub fn relay_listed_with(list: Option<&ServerList>, rendezvous: &str) -> Option<String> {
    let list = list?;
    let target = with_port(rendezvous, hbb_common::config::RENDEZVOUS_PORT);
    list.servers
        .iter()
        .find(|s| with_port(&s.rendezvous, hbb_common::config::RENDEZVOUS_PORT) == target)
        .map(|s| s.relay.clone())
}

/// Whether the Host takes a relay request for `relay` it did not offer itself: only a relay of
/// the signed list (a Controller picked it by measurement). Without a list: no (as before).
pub fn host_accepts_relay(relay: &str) -> bool {
    let list = super::server_list::stored();
    list.is_some() && is_listed_relay(list.as_ref(), relay)
}

// ---------------------------------------------------------------------------------------------
// Relay measurements
// ---------------------------------------------------------------------------------------------

/// Last samples per relay (server id); `None` = not reachable in time.
#[derive(Debug, Default, Clone)]
pub struct RttBook {
    samples: HashMap<String, VecDeque<Option<u32>>>,
    /// Unix seconds of the last probe round.
    pub at: i64,
}

impl RttBook {
    /// Adds one probe round. Relays no longer listed are forgotten.
    pub fn add_round(&mut self, round: &[(String, Option<u32>)], at: i64) {
        self.samples.retain(|id, _| round.iter().any(|(r, _)| r == id));
        for (id, ms) in round {
            let samples = self.samples.entry(id.clone()).or_default();
            samples.push_back(*ms);
            while samples.len() > SAMPLES_KEPT {
                samples.pop_front();
            }
        }
        self.at = at;
    }

    /// Smallest kept sample of `id`; `None` when none of them reached the relay.
    pub fn best(&self, id: &str) -> Option<u32> {
        self.samples.get(id)?.iter().flatten().copied().min()
    }

    /// `[(id, best)]` in the order of `servers`.
    pub fn report(&self, servers: &[ServerEntry]) -> Vec<(String, Option<u32>)> {
        servers
            .iter()
            .filter(|s| self.samples.contains_key(&s.id))
            .map(|s| (s.id.clone(), self.best(&s.id)))
            .collect()
    }
}

/// `[{id, ms}]` (no `ms` when unreachable): the heartbeat and option form.
pub fn rtt_json(values: &[(String, Option<u32>)]) -> Value {
    Value::Array(
        values
            .iter()
            .map(|(id, ms)| match ms {
                Some(ms) => json!({ "id": id, "ms": ms }),
                None => json!({ "id": id }),
            })
            .collect(),
    )
}

/// Reads `[{id, ms}]` (unknown fields ignored, broken entries skipped).
pub fn rtt_from_json(value: &Value) -> HashMap<String, u32> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let id = item.get("id")?.as_str()?.to_owned();
                    let ms = u32::try_from(item.get("ms")?.as_u64()?).ok()?;
                    Some((id, ms))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn book() -> &'static Mutex<RttBook> {
    static BOOK: OnceLock<Mutex<RttBook>> = OnceLock::new();
    BOOK.get_or_init(Default::default)
}

/// Whether a probe round is due: never probed and `FIRST_PROBE_AFTER` since start, or the last
/// round is `PROBE_INTERVAL` old. Pure.
pub fn probe_due(started: Instant, last: Option<Instant>, now: Instant) -> bool {
    match last {
        None => now.saturating_duration_since(started) >= FIRST_PROBE_AFTER,
        Some(last) => now.saturating_duration_since(last) >= PROBE_INTERVAL,
    }
}

/// One TCP connect time to `relay` in ms (name resolved first, so DNS is not counted).
async fn probe_one(relay: &str) -> Option<u32> {
    let target = with_port(relay, hbb_common::config::RELAY_PORT);
    let addr = hbb_common::tokio::time::timeout(PROBE_TIMEOUT, hbb_common::tokio::net::lookup_host(target))
        .await
        .ok()?
        .ok()?
        .next()?;
    let start = Instant::now();
    let stream = hbb_common::tokio::time::timeout(PROBE_TIMEOUT, hbb_common::tokio::net::TcpStream::connect(addr))
        .await
        .ok()?
        .ok()?;
    let ms = start.elapsed().as_millis();
    drop(stream);
    u32::try_from(ms).ok()
}

/// Measures every relay of `servers` (sequentially: a handful, light).
pub async fn probe_round(servers: &[ServerEntry]) -> Vec<(String, Option<u32>)> {
    let mut round = Vec::with_capacity(servers.len());
    for s in servers {
        round.push((s.id.clone(), probe_one(&s.relay).await));
    }
    round
}

/// The service's sync loop, every heartbeat: starts a probe round in the background when due.
/// The result goes to the heartbeat (`extend_heartbeat`) and to `OPTION_RTT` for the UI process.
pub fn tick() {
    if !super::server_list::SUPPORTED {
        return;
    }
    static STATE: OnceLock<Mutex<(Instant, Option<Instant>, bool)>> = OnceLock::new();
    let state = STATE.get_or_init(|| Mutex::new((Instant::now(), None, false)));
    let now = Instant::now();
    {
        let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
        if s.2 || !probe_due(s.0, s.1, now) {
            return;
        }
        s.1 = Some(now);
        s.2 = true;
    }
    hbb_common::tokio::spawn(async move {
        let servers = super::server_list::effective(super::server_list::stored().as_ref());
        let round = probe_round(&servers).await;
        let at = hbb_common::get_time() / 1000;
        let report = {
            let mut book = book().lock().unwrap_or_else(|e| e.into_inner());
            book.add_round(&round, at);
            book.report(&servers)
        };
        let shown: Vec<String> = report
            .iter()
            .map(|(id, ms)| format!("{id}={}", ms.map_or("-".to_owned(), |ms| ms.to_string())))
            .collect();
        log::debug!("Sense Remote: relay rtt {}", shown.join(" "));
        Config::set_option(
            OPTION_RTT.to_owned(),
            json!({ "at": at, "rtt": rtt_json(&report) }).to_string(),
        );
        state.lock().unwrap_or_else(|e| e.into_inner()).2 = false;
    });
}

/// Sync loop: `sense.relay_rtt` (unsigned, added after the report is signed). Left out before the
/// first round.
pub fn extend_heartbeat(sense: &mut Value) {
    if !super::server_list::SUPPORTED {
        return;
    }
    let servers = super::server_list::effective(super::server_list::stored().as_ref());
    let report = book().lock().unwrap_or_else(|e| e.into_inner()).report(&servers);
    if report.is_empty() {
        return;
    }
    if let Some(object) = sense.as_object_mut() {
        object.insert(HEARTBEAT_FIELD.to_owned(), rtt_json(&report));
    }
}

/// `OPTION_RTT` text → measurements, if not older than `OWN_RTT_MAX_AGE_S` at `now_s`.
pub fn own_rtt_from_option(text: &str, now_s: i64) -> HashMap<String, u32> {
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return HashMap::new();
    };
    let at = value.get("at").and_then(Value::as_i64).unwrap_or(0);
    if now_s - at > OWN_RTT_MAX_AGE_S {
        return HashMap::new();
    }
    rtt_from_json(value.get("rtt").unwrap_or(&Value::Null))
}

/// The panel's `peer-relays` answer → the Host's measurements no older than `HOST_RTT_MAX_AGE_S`.
pub fn host_rtt_from_answer(body: &str, now_s: i64) -> HashMap<String, u32> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return HashMap::new();
    };
    value
        .get("relays")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let at = item.get("at")?.as_i64()?;
                    if now_s - at > HOST_RTT_MAX_AGE_S {
                        return None;
                    }
                    let id = item.get("id")?.as_str()?.to_owned();
                    let ms = u32::try_from(item.get("ms")?.as_u64()?).ok()?;
                    Some((id, ms))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The Controller (UI process): the Host's measurements from the panel; empty on any failure (no
/// sign-in, older panel, Host without measurements). Blocking.
pub fn fetch_host_rtt(peer_id: &str) -> HashMap<String, u32> {
    let token = hbb_common::config::LocalConfig::get_option("access_token");
    if token.is_empty() || !peer_id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return HashMap::new();
    }
    let header = json!({ "Authorization": format!("Bearer {token}") }).to_string();
    let url = format!("{}{PEER_RELAYS_PATH}?id={peer_id}", super::api_server());
    let Ok(response) = crate::http_request_sync(url, "GET".to_owned(), None, header) else {
        return HashMap::new();
    };
    let Ok(v) = serde_json::from_str::<Value>(&response) else {
        return HashMap::new();
    };
    if v.get("status_code").and_then(Value::as_u64) != Some(200) {
        return HashMap::new();
    }
    let body = v.get("body").and_then(Value::as_str).unwrap_or_default();
    host_rtt_from_answer(body, hbb_common::get_time() / 1000)
}

/// Which relay a Controller asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayChoice {
    /// `host[:port]` to request.
    pub relay: String,
    /// The listed server it belongs to, if any.
    pub server_id: Option<String>,
    /// Controller + Host ms when picked by measurement.
    pub total_ms: Option<u32>,
    /// `host_offered` | `single_server` | `no_host_rtt` | `no_common_rtt` | `lowest_total`.
    pub why: &'static str,
}

/// Picks the relay with the lowest Controller + Host total among `servers` measured by both;
/// otherwise the relay the Host offered. Ties go to the higher priority (earlier in `servers`).
/// Pure.
pub fn pick_relay(
    servers: &[ServerEntry],
    own: &HashMap<String, u32>,
    host: &HashMap<String, u32>,
    host_offered: &str,
) -> RelayChoice {
    let offered = |why| RelayChoice {
        relay: host_offered.to_owned(),
        server_id: servers
            .iter()
            .find(|s| {
                with_port(&s.relay, hbb_common::config::RELAY_PORT)
                    == with_port(host_offered, hbb_common::config::RELAY_PORT)
            })
            .map(|s| s.id.clone()),
        total_ms: None,
        why,
    };
    if host_offered.is_empty() {
        return offered("host_offered");
    }
    if servers.len() <= 1 {
        return offered("single_server");
    }
    if host.is_empty() {
        return offered("no_host_rtt");
    }
    let best = servers
        .iter()
        .filter_map(|s| Some((s, own.get(&s.id)? + host.get(&s.id)?)))
        .min_by_key(|(_, total)| *total);
    match best {
        Some((s, total)) => RelayChoice {
            relay: s.relay.clone(),
            server_id: Some(s.id.clone()),
            total_ms: Some(total),
            why: "lowest_total",
        },
        None => offered("no_common_rtt"),
    }
}

// ---------------------------------------------------------------------------------------------
// Per-connection state (Controller)
// ---------------------------------------------------------------------------------------------

/// The list this process uses: the service its own option, the UI process the service's over IPC.
pub async fn current_list() -> Option<ServerList> {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let list = if crate::is_server() {
        super::server_list::stored()
    } else {
        super::server_list::stored_in_service().await
    };
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let list = super::server_list::stored();
    *last_list().lock().unwrap_or_else(|e| e.into_inner()) = Some(list.clone());
    list
}

/// The list `current_list` found last (`None` before the first look), for synchronous readers.
fn last_list() -> &'static Mutex<Option<Option<ServerList>>> {
    static LAST: OnceLock<Mutex<Option<Option<ServerList>>>> = OnceLock::new();
    LAST.get_or_init(Default::default)
}

/// One connection attempt to a peer: ID servers where the peer was not found, and the one in use.
#[derive(Debug, Default, Clone)]
pub struct PeerAttempt {
    pub not_found: Vec<String>,
    pub rendezvous: Option<String>,
}

/// Whether a connect error means "the peer is not on this ID server" (another may know it).
pub fn is_not_found(err: &str) -> bool {
    err.contains("ID does not exist") || err.contains("Remote desktop is offline")
}

/// `servers` (already in order) without the ones that did not know the peer; the full order when
/// every server was asked. Pure.
pub fn order_without(servers: Vec<ServerEntry>, not_found: &[String]) -> Vec<ServerEntry> {
    let rest: Vec<ServerEntry> = servers
        .iter()
        .filter(|s| !not_found.contains(&s.id))
        .cloned()
        .collect();
    if rest.is_empty() {
        servers
    } else {
        rest
    }
}

fn attempts() -> &'static Mutex<HashMap<String, PeerAttempt>> {
    static MAP: OnceLock<Mutex<HashMap<String, PeerAttempt>>> = OnceLock::new();
    MAP.get_or_init(Default::default)
}

/// `client::start`: a new connection to `peer` begins (forgets the previous attempt).
pub fn begin_peer(peer: &str) {
    attempts()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(peer.to_owned(), PeerAttempt::default());
}

/// `client::_start`: the ID server to ask for `peer` and the others to try when it does not
/// answer, as `(host:port, [host:port], contained)` like `crate::get_rendezvous_server`.
pub async fn rendezvous_for_peer(peer: &str) -> (String, Vec<String>, bool) {
    let list = current_list().await;
    let not_found = attempts()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(peer)
        .map(|a| a.not_found.clone())
        .unwrap_or_default();
    let ordered = order_without(rendezvous_order(list.as_ref(), Instant::now()), &not_found);
    let mut hosts = ordered
        .iter()
        .map(|s| with_port(&s.rendezvous, hbb_common::config::RENDEZVOUS_PORT));
    let first = hosts
        .next()
        .unwrap_or_else(super::server::rendezvous_server_with_port);
    (first, hosts.collect(), true)
}

/// `client::_start_inner`: the first ID server answered (`first_ok`) or not, and which one is used.
pub async fn note_rendezvous_connect(peer: &str, first: &str, first_ok: bool, used: &str, used_ok: bool) {
    let list = current_list().await;
    note_rendezvous(list.as_ref(), first, first_ok);
    if used != first {
        note_rendezvous(list.as_ref(), used, used_ok);
    }
    if used_ok {
        if let Some(a) = attempts().lock().unwrap_or_else(|e| e.into_inner()).get_mut(peer) {
            a.rendezvous = Some(used.to_owned());
        }
    }
}

/// `client::start`: after an error, whether another listed ID server should be asked (the peer
/// was not found on this one and another is left). With one server: never.
pub async fn try_next_server(peer: &str, err: &str) -> bool {
    if !is_not_found(err) {
        return false;
    }
    let list = current_list().await;
    let servers = super::server_list::effective(list.as_ref());
    if servers.len() <= 1 {
        return false;
    }
    let mut map = attempts().lock().unwrap_or_else(|e| e.into_inner());
    let attempt = map.entry(peer.to_owned()).or_default();
    let Some(used) = attempt.rendezvous.take() else {
        return false;
    };
    let Some(server) = server_of_rendezvous(&servers, &used) else {
        return false;
    };
    if !attempt.not_found.contains(&server.id) {
        attempt.not_found.push(server.id.clone());
    }
    let left = servers.iter().any(|s| !attempt.not_found.contains(&s.id));
    if left {
        log::info!("Sense Remote: peer not on ID server {}, asking the next one", server.id);
    }
    left
}

/// `client::start`: connected; notes the server for the card and `conn/server`.
pub async fn connected(peer: &str, relay: bool) {
    let list = current_list().await;
    let used = attempts()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(peer)
        .and_then(|a| a.rendezvous.clone())
        .unwrap_or_else(super::server::rendezvous_server_with_port);
    note_session_server(list.as_ref(), peer, &used, relay);
}

/// `client::connect`: the relay to ask for. With one server (or no Host measurements) the relay
/// the Host offered; otherwise the lowest Controller + Host total (`pick_relay`).
pub async fn relay_to_request(peer: &str, host_offered: &str) -> String {
    let list = current_list().await;
    let servers = super::server_list::effective(list.as_ref());
    if servers.len() <= 1 || host_offered.is_empty() {
        return host_offered.to_owned();
    }
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let own_text = if crate::is_server() {
        Config::get_option(OPTION_RTT)
    } else {
        crate::ipc::get_option_async(OPTION_RTT).await
    };
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let own_text = Config::get_option(OPTION_RTT);
    let own = own_rtt_from_option(&own_text, hbb_common::get_time() / 1000);
    let peer_owned = peer.to_owned();
    let host = hbb_common::tokio::task::spawn_blocking(move || fetch_host_rtt(&peer_owned))
        .await
        .unwrap_or_default();
    let choice = pick_relay(&servers, &own, &host, host_offered);
    super::diag::event(
        "conn",
        "relay_pick",
        json!({ "sunucu": choice.server_id, "toplam_ms": choice.total_ms, "neden": choice.why }),
    );
    choice.relay
}

// ---------------------------------------------------------------------------------------------
// Connection card and diagnostics
// ---------------------------------------------------------------------------------------------

/// The server of the ID server a session used (by peer id), for the connection card.
fn session_servers() -> &'static Mutex<HashMap<String, (String, String)>> {
    static MAP: OnceLock<Mutex<HashMap<String, (String, String)>>> = OnceLock::new();
    MAP.get_or_init(Default::default)
}

/// The listed server whose ID server is `rendezvous`; the first one when unknown.
pub fn server_of_rendezvous(servers: &[ServerEntry], rendezvous: &str) -> Option<ServerEntry> {
    let target = with_port(rendezvous, hbb_common::config::RENDEZVOUS_PORT);
    servers
        .iter()
        .find(|s| with_port(&s.rendezvous, hbb_common::config::RENDEZVOUS_PORT) == target)
        .or_else(|| servers.first())
        .cloned()
}

/// Client: the connection to `peer_id` found the peer through `rendezvous`. Remembers the server
/// for the card and writes `conn/server` (server id and path; no address).
pub fn note_session_server(list: Option<&ServerList>, peer_id: &str, rendezvous: &str, relay: bool) {
    let servers = super::server_list::effective(list);
    let Some(server) = server_of_rendezvous(&servers, rendezvous) else {
        return;
    };
    super::diag::event(
        "conn",
        "server",
        json!({
            "sunucu": server.id.clone(),
            "yol": if relay { "relay" } else { "direct" },
            "liste": list.map(|l| l.rev),
        }),
    );
    session_servers()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(peer_id.to_owned(), (server.id, server.name));
}

/// The name of the server the session to `peer_id` uses ("Türkiye (İstanbul)"); the first server's
/// name before the connection is known.
pub fn session_server_name(peer_id: &str) -> String {
    if let Some((_, name)) = session_servers()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(peer_id)
    {
        return name.clone();
    }
    let last = last_list().lock().unwrap_or_else(|e| e.into_inner()).clone().flatten();
    super::server_list::effective(last.as_ref())
        .first()
        .map(|s| s.name.clone())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, priority: i64, relay: &str) -> ServerEntry {
        ServerEntry {
            id: id.to_owned(),
            name: format!("Sunucu {id}"),
            rendezvous: format!("{id}.example.test"),
            relay: relay.to_owned(),
            key: "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=".to_owned(),
            priority,
        }
    }

    fn rtt(pairs: &[(&str, u32)]) -> HashMap<String, u32> {
        pairs.iter().map(|(id, ms)| (id.to_string(), *ms)).collect()
    }

    fn ids(servers: &[ServerEntry]) -> Vec<&str> {
        servers.iter().map(|s| s.id.as_str()).collect()
    }

    #[test]
    fn primary_is_first_until_it_fails_and_comes_back_after_backoff() {
        let servers = vec![entry("tr1", 1, "tr1.example.test"), entry("b", 2, "b.example.test")];
        let mut h = IdHealth::default();
        let t0 = Instant::now();
        assert_eq!(ids(&h.order(&servers, t0)), ["tr1", "b"]);
        h.record_failure("tr1", t0);
        assert_eq!(ids(&h.order(&servers, t0)), ["b", "tr1"], "failed primary goes last");
        assert_eq!(ids(&h.order(&servers, t0 + BACKOFF_FIRST)), ["tr1", "b"], "tried first again");
        // Fails again: the wait doubles.
        h.record_failure("tr1", t0 + BACKOFF_FIRST);
        let t1 = t0 + BACKOFF_FIRST;
        assert_eq!(ids(&h.order(&servers, t1 + BACKOFF_FIRST)), ["b", "tr1"]);
        assert_eq!(ids(&h.order(&servers, t1 + BACKOFF_FIRST * 2)), ["tr1", "b"]);
        h.record_success("tr1");
        assert_eq!(ids(&h.order(&servers, t1)), ["tr1", "b"]);
    }

    #[test]
    fn backoff_stops_growing() {
        let mut h = IdHealth::default();
        let t = Instant::now();
        for _ in 0..20 {
            h.record_failure("a", t);
        }
        assert_eq!(h.down["a"].backoff, BACKOFF_MAX);
    }

    #[test]
    fn a_single_server_is_always_asked() {
        let servers = vec![entry("tr1", 1, "tr1.example.test")];
        let mut h = IdHealth::default();
        let t = Instant::now();
        h.record_failure("tr1", t);
        assert_eq!(ids(&h.order(&servers, t)), ["tr1"]);
    }

    #[test]
    fn lowest_total_wins() {
        let servers = vec![entry("tr1", 1, "tr1.example.test"), entry("b", 2, "b.example.test:21117")];
        let own = rtt(&[("tr1", 20), ("b", 90)]);
        let host = rtt(&[("tr1", 200), ("b", 30)]);
        let c = pick_relay(&servers, &own, &host, "tr1.example.test");
        assert_eq!(c.relay, "b.example.test:21117");
        assert_eq!(c.server_id.as_deref(), Some("b"));
        assert_eq!(c.total_ms, Some(120));
        assert_eq!(c.why, "lowest_total");
    }

    #[test]
    fn tie_goes_to_the_higher_priority() {
        let servers = vec![entry("tr1", 1, "tr1.example.test"), entry("b", 2, "b.example.test")];
        let both = rtt(&[("tr1", 50), ("b", 50)]);
        assert_eq!(pick_relay(&servers, &both, &both, "b.example.test").server_id.as_deref(), Some("tr1"));
    }

    #[test]
    fn host_offered_relay_without_host_measurements_or_with_one_server() {
        let two = vec![entry("tr1", 1, "tr1.example.test"), entry("b", 2, "b.example.test")];
        let own = rtt(&[("tr1", 20), ("b", 10)]);
        // Older Host (no measurements in the panel): only the relay it offered is safe.
        let c = pick_relay(&two, &own, &HashMap::new(), "tr1.example.test");
        assert_eq!((c.relay.as_str(), c.why), ("tr1.example.test", "no_host_rtt"));
        assert_eq!(c.server_id.as_deref(), Some("tr1"));
        // No relay measured by both sides.
        let c = pick_relay(&two, &rtt(&[("tr1", 20)]), &rtt(&[("b", 5)]), "tr1.example.test:21117");
        assert_eq!((c.relay.as_str(), c.why), ("tr1.example.test:21117", "no_common_rtt"));
        assert_eq!(c.server_id.as_deref(), Some("tr1"));
        // Kullanıcı #145: one server, nothing switches whatever the numbers.
        let one = vec![entry("tr1", 1, "tr1.example.test")];
        let c = pick_relay(&one, &own, &rtt(&[("tr1", 999)]), "tr1.example.test");
        assert_eq!((c.relay.as_str(), c.why), ("tr1.example.test", "single_server"));
        // Nothing offered: nothing invented.
        assert_eq!(pick_relay(&two, &own, &own, "").why, "host_offered");
    }

    #[test]
    fn book_keeps_the_smallest_of_the_last_samples() {
        let servers = vec![entry("tr1", 1, "x"), entry("b", 2, "y")];
        let mut book = RttBook::default();
        book.add_round(&[("tr1".into(), Some(80)), ("b".into(), None)], 1);
        book.add_round(&[("tr1".into(), Some(40)), ("b".into(), None)], 2);
        book.add_round(&[("tr1".into(), Some(60)), ("b".into(), Some(70))], 3);
        assert_eq!(book.best("tr1"), Some(40));
        assert_eq!(book.best("b"), Some(70));
        book.add_round(&[("tr1".into(), Some(90)), ("b".into(), None)], 4);
        assert_eq!(book.best("tr1"), Some(60), "only the last three count");
        assert_eq!(book.report(&servers), vec![("tr1".into(), Some(60)), ("b".into(), Some(70))]);
        // A relay that left the list is forgotten.
        book.add_round(&[("tr1".into(), Some(10))], 5);
        assert_eq!(book.report(&servers), vec![("tr1".into(), Some(10))]);
        assert_eq!(book.at, 5);
    }

    #[test]
    fn rtt_json_round_trip_and_age() {
        let values = vec![("tr1".to_owned(), Some(42)), ("b".to_owned(), None)];
        let json = rtt_json(&values);
        assert_eq!(json, json!([{ "id": "tr1", "ms": 42 }, { "id": "b" }]));
        assert_eq!(rtt_from_json(&json), rtt(&[("tr1", 42)]));
        let option = json!({ "at": 1000, "rtt": json }).to_string();
        assert_eq!(own_rtt_from_option(&option, 1000 + OWN_RTT_MAX_AGE_S), rtt(&[("tr1", 42)]));
        assert!(own_rtt_from_option(&option, 1001 + OWN_RTT_MAX_AGE_S).is_empty());
        assert!(own_rtt_from_option("", 0).is_empty());
    }

    #[test]
    fn host_answer_drops_old_and_broken_values() {
        let body = json!({ "relays": [
            { "id": "tr1", "ms": 35, "at": 1000 },
            { "id": "b", "ms": null, "at": 1000 },
            { "id": "old", "ms": 5, "at": 1000 - HOST_RTT_MAX_AGE_S - 1 },
        ] })
        .to_string();
        assert_eq!(host_rtt_from_answer(&body, 1000), rtt(&[("tr1", 35)]));
        assert!(host_rtt_from_answer("{}", 1000).is_empty());
        assert!(host_rtt_from_answer("not json", 1000).is_empty());
    }

    #[test]
    fn probe_schedule() {
        let start = Instant::now();
        assert!(!probe_due(start, None, start));
        assert!(probe_due(start, None, start + FIRST_PROBE_AFTER));
        let last = start + FIRST_PROBE_AFTER;
        assert!(!probe_due(start, Some(last), last + PROBE_INTERVAL - Duration::from_secs(1)));
        assert!(probe_due(start, Some(last), last + PROBE_INTERVAL));
    }

    #[test]
    fn listed_servers_only() {
        let list = ServerList {
            rev: 1,
            iat: 0,
            exp: 1,
            servers: vec![entry("tr1", 1, "tr1-relay.example.test")],
        };
        assert!(is_listed_relay(Some(&list), "TR1-relay.example.test:21117"));
        assert!(!is_listed_relay(Some(&list), "tr1-relay.example.test:21118"));
        assert!(!is_listed_relay(Some(&list), "rs-ny.rustdesk.com"));
        assert!(is_listed_rendezvous(Some(&list), "tr1.example.test:21116"));
        assert!(!is_listed_rendezvous(Some(&list), "other.example.test"));
        // Without a list: the built-in server.
        assert!(is_listed_rendezvous(None, super::super::server::RENDEZVOUS_SERVER));
        assert!(is_listed_relay(None, super::super::server::RELAY_SERVER));
    }

    #[test]
    fn not_found_moves_to_the_next_server_then_starts_over() {
        let servers = vec![entry("tr1", 1, "r1"), entry("b", 2, "r2")];
        assert!(is_not_found("ID does not exist"));
        assert!(is_not_found("Remote desktop is offline"));
        assert!(!is_not_found("Failed to connect via relay server"));
        assert_eq!(ids(&order_without(servers.clone(), &[])), ["tr1", "b"]);
        assert_eq!(ids(&order_without(servers.clone(), &["tr1".into()])), ["b"]);
        // Every server asked: the full order again (never an empty order).
        assert_eq!(ids(&order_without(servers, &["tr1".into(), "b".into()])), ["tr1", "b"]);
    }

    #[test]
    fn host_registers_on_every_listed_id_server() {
        assert_eq!(rendezvous_hosts(None), vec![super::super::server::RENDEZVOUS_SERVER.to_owned()]);
        let list = ServerList {
            rev: 1,
            iat: 0,
            exp: 1,
            servers: vec![entry("tr1", 1, "tr1-relay.example.test"), entry("b", 2, "b-relay.example.test")],
        };
        assert_eq!(rendezvous_hosts(Some(&list)), ["tr1.example.test", "b.example.test"]);
        assert_eq!(
            relay_listed_with(Some(&list), "b.example.test:21116").as_deref(),
            Some("b-relay.example.test")
        );
        assert_eq!(relay_listed_with(Some(&list), "other.test"), None);
        assert_eq!(relay_listed_with(None, "tr1.example.test"), None);
    }

    #[test]
    fn session_server_falls_back_to_the_first_listed() {
        let servers = vec![entry("tr1", 1, "r"), entry("b", 2, "r2")];
        assert_eq!(server_of_rendezvous(&servers, "b.example.test:21116").unwrap().id, "b");
        assert_eq!(server_of_rendezvous(&servers, "unknown.test").unwrap().id, "tr1");
        assert!(server_of_rendezvous(&[], "x").is_none());
    }
}
