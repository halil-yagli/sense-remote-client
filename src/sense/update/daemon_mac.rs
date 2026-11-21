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
//!   engine only gets the rejection reason).
//! - `Install { version }`: only against the valid release the daemon holds, and only for a
//!   version above the installed one; a local process can at most make a signed newer version
//!   install earlier.
//! - All three are answered with `DaemonStatus(GuiStatus JSON)`.
//! - At most one call per `MIN_CALL_INTERVAL_MS` per peer PROCESS (`peer_pid`, like G4-4),
//!   not per connection: opening a new connection must not reset the limit. A call that came
//!   too soon gets no answer and changes nothing.
//!
//! The runner: one worker thread owns the engine (`engine::next`) and performs its actions
//! (download, verify, install, persist). It runs outside any async runtime, because the
//! upstream "no active connection" check (`has_no_active_conns_ipc`) starts its own. The IPC
//! handler only verifies and queues events. At start the worker runs the new version's
//! self-check (§5.3) first.
//!
//! Nothing of a release or order is logged, only reasons and version numbers.
//!
//! The decisions (`offer_events`, `install_events`, `handle`, `gui_status`) are pure and tested
//! on every platform. Outside macOS `on_service_ipc` and `request_daemon` always answer `None`
//! and `start` does nothing (Linux has the `_service` channel too, but no Sense daemon).
//! MAC-SONRA: checked on a device with the rest of the Mac update (plan §14).

use super::{
    engine::{self, Event},
    manifest::{self, Reason, Release},
    order::{self, Order},
    store::{Persisted, StoredState},
    GuiStatus, Hint, LastResult, SenseUpdateIpc, MAX_VERSION,
};
use crate::sense::envelope_keys::TrustedKey;
use serde_json::Value;

/// Limit of one `Offer` (release + order + hint text).
pub const MAX_OFFER_BYTES: usize = 24 * 1024;
/// At most one call per peer process per this many milliseconds (the limiter of
/// `mac_apply`, which uses the same interval).
pub const MIN_CALL_INTERVAL_MS: u64 = crate::sense::mac_apply::MIN_CALL_INTERVAL_MS;
/// How long the agent waits for the daemon's answer.
pub const DAEMON_TIMEOUT_MS: u64 = 5000;
/// Timer of the worker when no event comes.
pub const TICK_MS: u64 = 15_000;

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

/// The verified release and order the daemon holds. Only `offer_events` sets them, only after
/// verification.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Held {
    pub release: Option<Release>,
    pub order: Option<Order>,
}

fn offer_bytes(release: &str, order: Option<&str>, hint_oid: Option<&str>) -> usize {
    release.len() + order.map_or(0, str::len) + hint_oid.map_or(0, str::len)
}

/// Pure: the engine events of one `Offer`. Too big or an unknown platform → none.
pub fn offer_events(
    release: &str,
    order: Option<&str>,
    hint_release: Option<u32>,
    hint_oid: Option<&str>,
    ctx: &DaemonCtx,
    held: &mut Held,
) -> Vec<Event> {
    if offer_bytes(release, order, hint_oid) > MAX_OFFER_BYTES {
        hbb_common::log::warn!("Sense Remote: update offer too big, ignored");
        return Vec::new();
    }
    let Some(platform) = ctx.platform else {
        return Vec::new();
    };
    let mut events = Vec::new();
    // An empty release text = the agent had only an order or a hint this time.
    if !release.is_empty() {
        let verified = serde_json::from_str::<Value>(release)
            .map_err(|_| Reason::Malformed)
            .and_then(|value| {
                let expect = manifest::Expect {
                    iss: ctx.iss,
                    api_server: ctx.api_server,
                    platform,
                    now_s: ctx.now_s,
                };
                manifest::verify(&value, ctx.panel_keys, ctx.build_keys, &expect)
            });
        match &verified {
            Ok(release) => held.release = Some(release.clone()),
            Err(reason) => {
                hbb_common::log::warn!("Sense Remote: update release refused: {}", reason.as_str())
            }
        }
        events.push(Event::Release(verified));
    }
    if let Some(order) = order {
        let verified = serde_json::from_str::<Value>(order)
            .map_err(|_| Reason::Malformed)
            .and_then(|value| {
                let expect = order::Expect {
                    iss: ctx.iss,
                    did: ctx.did,
                    duuid: ctx.duuid,
                    now_s: ctx.now_s,
                    release: held.release.as_ref(),
                    installed: ctx.installed,
                };
                order::verify(&value, ctx.panel_keys, &expect)
            });
        match &verified {
            Ok(order) => held.order = Some(order.clone()),
            Err(reason) => {
                hbb_common::log::warn!("Sense Remote: update order refused: {}", reason.as_str())
            }
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

/// Pure: `Install { version }` becomes the engine's request only for the held, verified
/// release of exactly that version, and only when it is newer than the installed one.
pub fn install_events(version: u32, held: &Held, installed: u32) -> Vec<Event> {
    match &held.release {
        Some(release) if release.version == version && release.is_newer_than(installed) => {
            vec![Event::InstallRequested { version }]
        }
        _ => Vec::new(),
    }
}

/// Pure: one `_service` message. `None` = no answer and nothing queued (call limit, or a
/// variant the daemon does not take); `Some(events)` = queue them and answer with the status.
pub fn handle(
    message: &SenseUpdateIpc,
    allowed: bool,
    ctx: &DaemonCtx,
    held: &mut Held,
) -> Option<Vec<Event>> {
    if !allowed {
        return None;
    }
    match message {
        SenseUpdateIpc::Offer {
            release,
            order,
            hint_release,
            hint_oid,
        } => Some(offer_events(
            release,
            order.as_deref(),
            *hint_release,
            hint_oid.as_deref(),
            ctx,
            held,
        )),
        SenseUpdateIpc::Install { version } => {
            Some(install_events(*version, held, ctx.installed))
        }
        SenseUpdateIpc::StatusQuery => Some(Vec::new()),
        SenseUpdateIpc::Status(_)
        | SenseUpdateIpc::InstallRequest { .. }
        | SenseUpdateIpc::DaemonStatus(_) => None,
    }
}

/// Pure: GuiStatus (§3.7) from the engine's state and the stored record.
pub fn gui_status(
    state: &engine::State,
    current: u32,
    checked_at: Option<i64>,
    mac_permission_warning: bool,
    stored: Option<&Persisted>,
) -> GuiStatus {
    let mut status = GuiStatus::idle(current);
    status.state = state.phase;
    status.target = state.release.as_ref().map(|release| release.version);
    status.source = state.source;
    status.progress_pct = state.progress_pct;
    status.error = state.error;
    status.error_detail = state
        .error_detail
        .clone()
        .filter(|detail| super::is_error_detail(detail));
    status.notes_url = state.release.as_ref().and_then(|r| r.notes_url.clone());
    status.checked_at = checked_at;
    status.mac_permission_warning = mac_permission_warning;
    status.last_result = stored.and_then(last_result);
    status
}

/// The outcome of the last installation, when the record holds one.
pub fn last_result(stored: &Persisted) -> Option<LastResult> {
    let at = match stored.state {
        StoredState::Installed => stored.healthy_at.or(stored.started_at),
        StoredState::Failed | StoredState::RolledBack => stored.started_at,
        _ => None,
    }?;
    Some(LastResult {
        state: stored.state.reported(),
        from: stored.from?,
        to: stored.target?,
        at,
    })
}

/// §7: a Mac Host (or Host + Controller) whose signature is not the team certificate loses its
/// privacy permissions with an update.
pub fn permission_warning(role: Option<crate::sense::SenseRole>, sign: super::SignKind) -> bool {
    use crate::sense::SenseRole;
    matches!(role, Some(SenseRole::Host | SenseRole::Both)) && sign != super::SignKind::Cert
}

/// Called by the `service` binary (root) before it enters its loop; returns at once.
pub fn start() {
    #[cfg(target_os = "macos")]
    runner::start();
}

/// Daemon side of the `_service` channel; blocking, called off the async loop. `None` = no
/// answer.
pub fn on_service_ipc(message: SenseUpdateIpc, peer_pid: Option<u32>) -> Option<SenseUpdateIpc> {
    #[cfg(target_os = "macos")]
    {
        runner::on_service_ipc(message, peer_pid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (message, peer_pid);
        None
    }
}

/// Agent side: sends one message to the daemon and waits `DAEMON_TIMEOUT_MS` for its answer.
/// `None` = the daemon did not answer (or is not root, or the offer is too big).
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
            Ok(Some(Data::SenseUpdate(reply @ SenseUpdateIpc::DaemonStatus(_)))) => Some(reply),
            _ => None,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = message;
        None
    }
}

#[cfg(target_os = "macos")]
mod runner;

#[cfg(test)]
mod tests;
