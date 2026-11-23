//! Sense Remote (update plan 2026-11-21, §2.1-5, §3.7): the macOS root daemon's side of an
//! update. Package U4.
//!
//! On macOS the heartbeat answer arrives in the agent (`--server`, session user), which can
//! not install anything. It forwards the raw signed release and order plus the unsigned hint
//! to the daemon over the protected `_service` channel (`SenseUpdateIpc::Offer`); the user's
//! "Güncelle" goes the same way (`Install`). As for envelopes (M5) the daemon does NOT trust
//! the agent: it verifies everything again with the keys built into its own binary, the id of
//! the root config, the machine uuid and its own clock, and runs the engine itself.
//!
//! `_service` takes exactly `Offer`, `Install` and `StatusQuery` (`ipc.rs`,
//! `sense_service_accepts`); everything else closes the connection as before.
//! - `Offer`: at most `MAX_OFFER_BYTES` in total; a bad release or order changes nothing (the
//!   engine only gets the rejection reason); a valid release that is not newer than the
//!   installed version is ignored. Answer: `DaemonStatus(<UpdateStatus JSON>)`, the
//!   `sense.update` the agent puts into its next heartbeat (`agent_heartbeat_status`).
//! - `Install { version }`: `engine::check_install` against the engine's own (verified)
//!   release; answer `InstallAnswer(code)`. A local process can at most make a signed newer
//!   version install earlier.
//! - `StatusQuery` → `DaemonStatus(<GuiStatus JSON>)`.
//! - Call limit (`PeerLimiter`): one call per `MIN_CALL_INTERVAL_MS` per peer process and at
//!   most `MAX_CALLS_PER_UID` per interval for all processes of one uid together, so neither a
//!   new connection nor a new process resets it. A call above the limit gets no answer and
//!   changes nothing.
//!
//! The engine (`engine::next`, `State::restore`, `State::persisted`, `check_install`) is U2's;
//! the daemon's runner (`daemon_mac/runner.rs`) is the macOS counterpart of `runner.rs`: it
//! measures idle time with upstream's `has_no_active_conns_ipc` (which asks every session's
//! agent and starts its own runtime, so it runs only on the runner's own timer thread).
//!
//! Nothing of a release or order is logged, only reasons and version numbers.
//! Outside macOS `on_service_ipc` and `request_daemon` always answer `None` and `start` does
//! nothing (Linux has the `_service` channel too, but no Sense daemon).
//! MAC-SONRA: checked on a device with the rest of the Mac update (plan §14).

use super::{
    engine::Event,
    manifest::{self, Reason, Release},
    order, GuiStatus, Hint, SenseUpdateIpc, UpdateStatus, MAX_VERSION,
};
use crate::sense::envelope_keys::TrustedKey;
use serde_json::Value;
use std::collections::HashMap;

/// Limit of one `Offer` (release + order + hint text).
pub const MAX_OFFER_BYTES: usize = 24 * 1024;
/// Length of one call-limit interval.
pub const MIN_CALL_INTERVAL_MS: u64 = 1000;
/// Calls of all processes of one uid together within one interval (a session agent sends at
/// most an `Offer` per heartbeat and a `StatusQuery` per 5 s).
pub const MAX_CALLS_PER_UID: u32 = 3;
/// Peers (processes or uids) the limiter tracks within one interval; more are refused.
pub const MAX_LIMITED_PEERS: usize = 64;
/// How long the agent waits for the daemon's answer.
pub const DAEMON_TIMEOUT_MS: u64 = 5000;

/// What the daemon checks an offer against. All of it is the daemon's own data.
#[derive(Debug, Clone, Copy)]
pub struct DaemonCtx<'a> {
    pub panel_keys: &'a [TrustedKey],
    pub build_keys: &'a [TrustedKey],
    pub iss: &'a str,
    pub api_server: &'a str,
    /// `report::platform()`; `None` = a build the panel does not know, nothing is taken.
    pub platform: Option<&'a str>,
    pub did: &'a str,
    pub duuid: &'a str,
    pub now_s: i64,
    pub installed: u32,
}

/// What one accepted `_service` message asks of the daemon's engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Call {
    /// Engine events of an `Offer`, in order.
    Offer(Vec<Event>),
    /// "Güncelle" for this version (`engine::check_install` decides).
    Install(u32),
    Status,
}

fn offer_bytes(release: &str, order: Option<&str>, hint_oid: Option<&str>) -> usize {
    release.len() + order.map_or(0, str::len) + hint_oid.map_or(0, str::len)
}

/// Pure: the engine events of one `Offer`. `held` = the release the engine already holds
/// (verified earlier). Too big or an unknown platform → none.
pub fn offer_events(
    release: &str,
    order: Option<&str>,
    hint_release: Option<u32>,
    hint_oid: Option<&str>,
    ctx: &DaemonCtx,
    held: Option<&Release>,
) -> Vec<Event> {
    if offer_bytes(release, order, hint_oid) > MAX_OFFER_BYTES {
        hbb_common::log::warn!("Sense Remote: update offer too big, ignored");
        return Vec::new();
    }
    let Some(platform) = ctx.platform else {
        return Vec::new();
    };
    let mut events = Vec::new();
    let mut fresh = None;
    // `""` = the agent had no notice this time; the engine keeps the one it holds.
    if !release.is_empty() {
        let verified = serde_json::from_str::<Value>(release)
            .map_err(|_| Reason::Malformed)
            .and_then(|value| {
                let expect = manifest::Expect {
                    iss: ctx.iss,
                    api_server: ctx.api_server.trim_end_matches('/'),
                    platform,
                    now_s: ctx.now_s,
                };
                manifest::verify(&value, ctx.panel_keys, ctx.build_keys, &expect)
            });
        match verified {
            // Not newer than what is installed: nothing to offer (§3.3 step 12).
            Ok(release) if !release.is_newer_than(ctx.installed) => {}
            Ok(release) => {
                fresh = Some(release.clone());
                events.push(Event::Release(Ok(release)));
            }
            Err(reason) => {
                hbb_common::log::warn!("Sense Remote: update release refused: {}", reason.as_str());
                events.push(Event::Release(Err(reason)));
            }
        }
    }
    if let Some(text) = order {
        let verified = serde_json::from_str::<Value>(text)
            .map_err(|_| Reason::Malformed)
            .and_then(|value| {
                let expect = order::Expect {
                    iss: ctx.iss,
                    did: ctx.did,
                    duuid: ctx.duuid,
                    now_s: ctx.now_s,
                    release: fresh.as_ref().or(held),
                    installed: ctx.installed,
                };
                order::verify(&value, ctx.panel_keys, &expect)
            });
        if let Err(reason) = &verified {
            hbb_common::log::warn!("Sense Remote: update order refused: {}", reason.as_str());
        }
        events.push(Event::Order(verified));
    }
    let hint_release_ok = hint_release.map_or(true, |v| (1..=MAX_VERSION).contains(&v));
    let hint_oid_ok = hint_oid.map_or(true, order::is_order_id);
    if hint_release_ok && hint_oid_ok {
        events.push(Event::Hint(Hint {
            release: hint_release,
            oid: hint_oid.map(str::to_owned),
        }));
    }
    events
}

/// Pure: one `_service` message. `None` = no answer and nothing done (call limit, or a variant
/// the daemon does not take).
pub fn classify(
    message: &SenseUpdateIpc,
    allowed: bool,
    ctx: &DaemonCtx,
    held: Option<&Release>,
) -> Option<Call> {
    if !allowed {
        return None;
    }
    match message {
        SenseUpdateIpc::Offer {
            release,
            order,
            hint_release,
            hint_oid,
        } => Some(Call::Offer(offer_events(
            release,
            order.as_deref(),
            *hint_release,
            hint_oid.as_deref(),
            ctx,
            held,
        ))),
        SenseUpdateIpc::Install { version } => Some(Call::Install(*version)),
        SenseUpdateIpc::StatusQuery => Some(Call::Status),
        SenseUpdateIpc::Status(_)
        | SenseUpdateIpc::InstallRequest { .. }
        | SenseUpdateIpc::InstallAnswer(_)
        | SenseUpdateIpc::DaemonStatus(_)
        // Sense Remote (D3e): "Vazgeç" is not taken by the daemon yet.
        | SenseUpdateIpc::CancelRequest
        | SenseUpdateIpc::CancelAnswer(_) => None,
    }
}

/// The call limit (G4-4, strengthened): per peer process and per uid in total, over fixed
/// intervals of `MIN_CALL_INTERVAL_MS`. Time is a monotonic millisecond counter supplied by the
/// caller. A peer without a readable pid or uid shares one slot (`u32::MAX`).
#[derive(Debug, Default)]
pub struct PeerLimiter {
    window_start_ms: u64,
    by_pid: HashMap<u32, u32>,
    by_uid: HashMap<u32, u32>,
}

impl PeerLimiter {
    pub fn allow(&mut self, pid: Option<u32>, uid: Option<u32>, now_ms: u64) -> bool {
        if now_ms.saturating_sub(self.window_start_ms) >= MIN_CALL_INTERVAL_MS {
            self.window_start_ms = now_ms;
            self.by_pid.clear();
            self.by_uid.clear();
        }
        let pid = pid.unwrap_or(u32::MAX);
        let uid = uid.unwrap_or(u32::MAX);
        let pid_calls = self.by_pid.get(&pid).copied().unwrap_or(0);
        let uid_calls = self.by_uid.get(&uid).copied().unwrap_or(0);
        let new_peer = pid_calls == 0
            && (self.by_pid.len() >= MAX_LIMITED_PEERS || self.by_uid.len() >= MAX_LIMITED_PEERS);
        if pid_calls >= 1 || uid_calls >= MAX_CALLS_PER_UID || new_peer {
            return false;
        }
        self.by_pid.insert(pid, pid_calls + 1);
        self.by_uid.insert(uid, uid_calls + 1);
        true
    }
}

/// §7: a Mac Host (or Host + Controller) whose signature is not the team certificate loses its
/// privacy permissions with an update.
pub fn permission_warning(role: Option<crate::sense::SenseRole>, sign: super::SignKind) -> bool {
    use crate::sense::SenseRole;
    matches!(role, Some(SenseRole::Host | SenseRole::Both)) && sign != super::SignKind::Cert
}

/// The engine's GuiStatus with the macOS permission warning.
pub fn with_warning(mut status: GuiStatus, warning: bool) -> GuiStatus {
    status.mac_permission_warning = warning;
    status
}

/// Called by the `service` binary (root) before it enters its loop; returns at once.
pub fn start() {
    #[cfg(target_os = "macos")]
    runner::start();
}

/// Daemon side of the `_service` channel; blocking, called off the async loop. `None` = no
/// answer.
pub fn on_service_ipc(
    message: SenseUpdateIpc,
    peer_pid: Option<u32>,
    peer_uid: Option<u32>,
) -> Option<SenseUpdateIpc> {
    #[cfg(target_os = "macos")]
    {
        runner::on_service_ipc(message, peer_pid, peer_uid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (message, peer_pid, peer_uid);
        None
    }
}

/// Agent side: sends one message to the daemon and waits `DAEMON_TIMEOUT_MS` for its answer
/// (`DaemonStatus` or `InstallAnswer`). `None` = the daemon did not answer (or is not root, or
/// the offer is too big).
pub async fn request_daemon(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    #[cfg(target_os = "macos")]
    {
        use crate::ipc::{self, Data};
        if let SenseUpdateIpc::Offer {
            release,
            order,
            hint_oid,
            ..
        } = &message
        {
            if offer_bytes(release, order.as_deref(), hint_oid.as_deref()) > MAX_OFFER_BYTES {
                return None;
            }
        }
        // Only a peer with uid 0 is accepted as the daemon.
        let mut conn = ipc::connect_trusted_device_service(1000).await.ok()?;
        conn.send(&Data::SenseUpdate(message)).await.ok()?;
        match conn.next_timeout(DAEMON_TIMEOUT_MS).await {
            Ok(Some(Data::SenseUpdate(
                reply @ (SenseUpdateIpc::DaemonStatus(_) | SenseUpdateIpc::InstallAnswer(_)),
            ))) => Some(reply),
            _ => None,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = message;
        None
    }
}

/// Agent side of a heartbeat answer: forwards the `Offer` and keeps the daemon's
/// `sense.update` for the next heartbeat.
pub async fn forward_offer(offer: SenseUpdateIpc) {
    let status = match request_daemon(offer).await {
        Some(SenseUpdateIpc::DaemonStatus(json)) => serde_json::from_str::<UpdateStatus>(&json).ok(),
        _ => None,
    };
    *agent_status() = status;
}

fn agent_status() -> std::sync::MutexGuard<'static, Option<UpdateStatus>> {
    static STATUS: std::sync::Mutex<Option<UpdateStatus>> = std::sync::Mutex::new(None);
    STATUS.lock().unwrap_or_else(|err| err.into_inner())
}

/// macOS agent: the daemon's `sense.update` from the last answer; `None` before the first one
/// or when the daemon did not answer.
pub fn agent_heartbeat_status() -> Option<UpdateStatus> {
    agent_status().clone()
}

#[cfg(target_os = "macos")]
mod runner;

#[cfg(test)]
mod tests;
