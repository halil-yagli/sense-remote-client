//! Sense Remote (Mac M5, plan 2026-11-21 §3.3): applying signed panel envelopes on macOS through
//! the root daemon.
//!
//! On macOS the `--server` process (which receives the heartbeat answer) runs as the session
//! user and can not write the root-owned state file; only the daemon (`service`, root) can. The
//! user process is NOT trusted: it forwards the raw envelopes over the `_service` IPC channel,
//! the daemon verifies each one again with its own data (panel keys built into the daemon's
//! binary, `id` of the root config, the machine uuid, `mac_state.envelope_seq`, its own clock,
//! full-set rule G2-7) and applies it in the Windows order (writable check → settings → role →
//! seq, undo on error; `envelope_apply::apply_steps`).
//!
//! What the daemon takes from the user process is only the envelope text. Role, settings, seq
//! and the connection ids to close all come out of the signed payload; `server_time` is not
//! used (validity is checked against the daemon's clock, plan R8). Nothing of an envelope is
//! logged: only the reason of a rejection and, once the signature is valid, its seq.
//!
//! Layout: the decision logic (`apply_call`, `apply_one`, `settle`, the limits) is pure and
//! takes its surroundings as `DaemonContext` + `DaemonStore`, so it is tested on every platform;
//! the macOS-only part (`RootStore`, `apply_in_daemon`, `request_daemon`) only wires it to the
//! state file, the root `Config` and the IPC.

use super::{
    envelope::{Expect, Reason, Rejection},
    envelope_apply::{self, ApplySteps},
    envelope_keys::TrustedKey,
    SenseRole,
};
use base::config::keys;
use hbb_common::log;
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

/// Limits of one `Apply` call; a call above them is ignored as a whole and logged.
pub const MAX_ENVELOPES: usize = 8;
pub const MAX_TOTAL_BYTES: usize = 64 * 1024;
/// At most one `Apply` call per this many milliseconds.
pub const MIN_CALL_INTERVAL_MS: u64 = 1000;
/// How long the user process waits for the daemon's answer.
pub const DAEMON_TIMEOUT_MS: u64 = 5000;

/// Envelope settings macOS can not honour: there is no maintenance curtain on macOS (privacy
/// mode is off in `privacy_mode.rs`, the `curtain` capability is not reported), so the key is
/// accepted as part of the full set (G2-7) but never written.
pub const MAC_UNSUPPORTED_OPTIONS: [&str; 1] = [keys::OPTION_ENABLE_PRIVACY_MODE];

/// Payload of `ipc::Data::SenseEnvelope`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseEnvelopeIpc {
    /// User process → daemon: raw envelope JSON as received from the panel (≤ `MAX_ENVELOPES`)
    /// and the server time of the heartbeat answer.
    Apply {
        envelopes: Vec<String>,
        server_time: Option<i64>,
    },
    /// Daemon → user process: one outcome per envelope, in order. Empty when the call was
    /// ignored (limits).
    Result(Vec<SenseApplyOutcome>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseApplyOutcome {
    /// Applied and stored by the daemon. `role` = the new role when it changed
    /// (`host|controller|both`); `disconnect` = connection ids the user process must close.
    Applied {
        seq: u64,
        role: Option<String>,
        disconnect: Vec<i32>,
    },
    /// Nothing was changed. `reason` uses the names of `envelope::Reason::as_str`.
    Rejected { reason: String },
}

/// Pure part of the limits: count and total size of one `Apply` call.
pub fn within_limits(envelopes: &[String]) -> bool {
    envelopes.len() <= MAX_ENVELOPES
        && envelopes.iter().map(String::len).sum::<usize>() <= MAX_TOTAL_BYTES
}

/// Pure part of the rate limit. `since_last_ms` = time since the previous accepted call,
/// `None` for the first one.
pub fn call_allowed(since_last_ms: Option<u64>) -> bool {
    since_last_ms.map_or(true, |ms| ms >= MIN_CALL_INTERVAL_MS)
}

/// The settings of an envelope that are written on this platform.
pub fn applicable_options(
    config_options: &BTreeMap<String, String>,
    macos: bool,
) -> BTreeMap<String, String> {
    config_options
        .iter()
        .filter(|(key, _)| !(macos && MAC_UNSUPPORTED_OPTIONS.contains(&key.as_str())))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// What the daemon checks an envelope against. All of it is the daemon's own data; nothing
/// here comes from the IPC peer.
#[derive(Debug, Clone, Copy)]
pub struct DaemonContext<'a> {
    pub keys: &'a [TrustedKey],
    pub iss: &'a str,
    pub did: &'a str,
    pub duuid: &'a str,
    pub now_s: i64,
    /// `envelope_apply::APPLIES` of this build.
    pub applies: bool,
    /// Drops `MAC_UNSUPPORTED_OPTIONS` before writing.
    pub macos: bool,
}

/// The daemon's reads and writes (state file + root `Config`), injected so that the decisions
/// are tested without root and without macOS.
pub trait DaemonStore {
    /// Installed role and last applied seq. `Err` when the state can not be read (G2-5: that is
    /// not seq 0).
    fn read_state(&mut self) -> Result<(Option<SenseRole>, u64), String>;
    fn check_writable(&mut self) -> Result<(), String>;
    fn options(&mut self) -> HashMap<String, String>;
    fn set_options(&mut self, options: &BTreeMap<String, String>) -> Result<(), String>;
    fn restore_options(&mut self, snapshot: HashMap<String, String>);
    fn store_role(&mut self, role: SenseRole) -> Result<(), String>;
    fn store_seq(&mut self, seq: u64) -> Result<(), String>;
}

struct Steps<'a, S: DaemonStore> {
    store: &'a mut S,
    options: BTreeMap<String, String>,
    seq: u64,
}

impl<S: DaemonStore> ApplySteps for Steps<'_, S> {
    type Snapshot = HashMap<String, String>;

    fn check_writable(&mut self) -> Result<(), String> {
        self.store.check_writable()
    }
    fn snapshot(&mut self) -> Self::Snapshot {
        self.store.options()
    }
    fn set_options(&mut self) -> Result<(), String> {
        self.store.set_options(&self.options)
    }
    fn restore_options(&mut self, snapshot: Self::Snapshot) {
        self.store.restore_options(snapshot)
    }
    fn store_role(&mut self, role: SenseRole) -> Result<(), String> {
        self.store.store_role(role)
    }
    fn store_seq(&mut self) -> Result<(), String> {
        self.store.store_seq(self.seq)
    }
}

fn rejected(reason: Reason, seq: Option<u64>) -> SenseApplyOutcome {
    // The reason and the seq of a signed payload only; never the envelope itself.
    log::warn!(
        "Sense Remote: daemon rejected a panel envelope: {} (seq {seq:?})",
        reason.as_str()
    );
    SenseApplyOutcome::Rejected {
        reason: reason.as_str().to_owned(),
    }
}

/// Daemon side, one envelope: full verification with the daemon's data, then the writes.
/// Either everything is stored (`Applied`) or nothing changed (`Rejected`).
pub fn apply_one<S: DaemonStore>(
    raw: &str,
    ctx: &DaemonContext,
    store: &mut S,
) -> SenseApplyOutcome {
    let Ok(item) = serde_json::from_str::<Value>(raw) else {
        return rejected(Reason::Malformed, None);
    };
    // Read for every envelope: the previous one of the same call may have moved the seq.
    let state = store.read_state();
    if let Err(err) = &state {
        log::error!("Sense Remote: daemon can not read the Sense state: {err}");
    }
    let readable = state.is_ok();
    let (installed, last_seq) = state.unwrap_or((None, 0));
    let expect = Expect {
        iss: ctx.iss,
        did: ctx.did,
        duuid: ctx.duuid,
        now_s: ctx.now_s,
        last_seq,
    };
    let verified =
        match envelope_apply::check_stored(&item, ctx.keys, &expect, ctx.applies, readable) {
            Ok(verified) => verified,
            Err(Rejection { reason, seq, .. }) => return rejected(reason, seq),
        };
    let seq = verified.seq;
    let new_role = match envelope_apply::role_change(installed, verified.body.sense_role) {
        Ok(new_role) => new_role,
        Err(reason) => return rejected(reason, Some(seq)),
    };
    let mut steps = Steps {
        store,
        options: applicable_options(&verified.body.config_options, ctx.macos),
        seq,
    };
    if let Err(reason) = envelope_apply::apply_steps(&mut steps, installed, new_role) {
        return rejected(reason, Some(seq));
    }
    log::info!("Sense Remote: daemon applied panel envelope {seq}");
    SenseApplyOutcome::Applied {
        seq,
        role: new_role.map(|role| role.as_str().to_owned()),
        disconnect: verified
            .body
            .disconnect
            .iter()
            .flatten()
            .filter_map(|id| i32::try_from(*id).ok())
            .collect(),
    }
}

/// Daemon side, one `Apply` call. `since_last_ms` as in `call_allowed`. `None` = the call was
/// ignored (too soon, too many, too large): nothing was read, verified or written.
pub fn apply_call<S: DaemonStore>(
    envelopes: &[String],
    since_last_ms: Option<u64>,
    ctx: &DaemonContext,
    store: &mut S,
) -> Option<Vec<SenseApplyOutcome>> {
    if !call_allowed(since_last_ms) {
        log::warn!("Sense Remote: daemon ignored an envelope call (rate limit)");
        return None;
    }
    if !within_limits(envelopes) {
        log::warn!(
            "Sense Remote: daemon ignored an envelope call (limits: {} envelopes)",
            envelopes.len()
        );
        return None;
    }
    Some(
        envelopes
            .iter()
            .map(|raw| apply_one(raw, ctx, store))
            .collect(),
    )
}

/// User process: what the daemon did with one forwarded envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedByDaemon {
    pub seq: u64,
    /// New role when it changed.
    pub role: Option<SenseRole>,
    pub disconnect: Vec<i32>,
}

/// User process: pairs the envelopes it forwarded (`k`, `seq` from its own check) with the
/// daemon's answer. `answer` = `None` when the daemon was not reached or did not answer. Only an
/// `Applied` for the same seq counts as applied; everything else is a rejection for the next
/// heartbeat's `envelope_error` (`apply_failed` when the daemon gave no usable outcome).
pub fn settle(
    forwarded: &[(String, u64)],
    answer: Option<&[SenseApplyOutcome]>,
) -> Vec<Result<AppliedByDaemon, Rejection>> {
    forwarded
        .iter()
        .enumerate()
        .map(|(index, (k, seq))| {
            let reject = |reason| {
                Err(Rejection {
                    reason,
                    k: Some(k.clone()),
                    seq: Some(*seq),
                })
            };
            match answer.and_then(|outcomes| outcomes.get(index)) {
                Some(SenseApplyOutcome::Applied {
                    seq: applied,
                    role,
                    disconnect,
                }) if applied == seq => Ok(AppliedByDaemon {
                    seq: *seq,
                    role: role.as_deref().and_then(SenseRole::parse),
                    disconnect: disconnect.clone(),
                }),
                Some(SenseApplyOutcome::Rejected { reason }) => {
                    reject(Reason::parse(reason).unwrap_or(Reason::ApplyFailed))
                }
                Some(SenseApplyOutcome::Applied { .. }) | None => reject(Reason::ApplyFailed),
            }
        })
        .collect()
}

/// Daemon side of one `Apply` call on macOS: the daemon's own identity, keys, clock and state.
/// One call at a time (the lock also carries the rate limit).
#[cfg(target_os = "macos")]
pub fn apply_in_daemon(envelopes: &[String], _server_time: Option<i64>) -> Vec<SenseApplyOutcome> {
    use std::{sync::Mutex, time::Instant};
    static LAST_CALL: Mutex<Option<Instant>> = Mutex::new(None);
    let mut last_call = LAST_CALL.lock().unwrap_or_else(|err| err.into_inner());
    let since_last_ms = (*last_call).map(|at| at.elapsed().as_millis().min(u64::MAX as u128) as u64);
    let iss = super::envelope::expected_issuer();
    let did = hbb_common::config::Config::get_id();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let ctx = DaemonContext {
        keys: super::envelope_keys::trusted_keys(),
        iss: &iss,
        did: &did,
        duuid: &duuid,
        now_s: hbb_common::get_time() / 1000,
        applies: envelope_apply::APPLIES,
        macos: true,
    };
    let outcomes = apply_call(envelopes, since_last_ms, &ctx, &mut RootStore);
    if outcomes.is_some() {
        *last_call = Some(Instant::now());
    }
    outcomes.unwrap_or_default()
}

/// Other platforms have no root daemon that applies envelopes: every envelope is rejected and
/// nothing changes.
#[cfg(not(target_os = "macos"))]
pub fn apply_in_daemon(envelopes: &[String], _server_time: Option<i64>) -> Vec<SenseApplyOutcome> {
    envelopes
        .iter()
        .take(MAX_ENVELOPES)
        .map(|_| SenseApplyOutcome::Rejected {
            reason: Reason::UnsupportedPlatform.as_str().to_owned(),
        })
        .collect()
}

/// The root-owned state file and the root `Config`. Every write fails for a process that is
/// not root (`mac_state::update`), so only the daemon gets past `check_writable`.
#[cfg(target_os = "macos")]
struct RootStore;

#[cfg(target_os = "macos")]
impl DaemonStore for RootStore {
    fn read_state(&mut self) -> Result<(Option<SenseRole>, u64), String> {
        Ok(super::mac_state::read()?
            .map_or((None, 0), |state| (state.role, state.envelope_seq)))
    }
    fn check_writable(&mut self) -> Result<(), String> {
        super::envelope_seq::check_writable().map_err(|err| format!("{err:?}"))
    }
    fn options(&mut self) -> HashMap<String, String> {
        hbb_common::config::Config::get_options()
    }
    fn set_options(&mut self, options: &BTreeMap<String, String>) -> Result<(), String> {
        crate::hbbs_http::sync::sense_set_envelope_options(
            options.clone().into_iter().collect(),
        )
    }
    fn restore_options(&mut self, snapshot: HashMap<String, String>) {
        hbb_common::config::Config::set_options(snapshot);
    }
    fn store_role(&mut self, role: SenseRole) -> Result<(), String> {
        super::mac_state::update(|state| state.role = Some(role))
    }
    fn store_seq(&mut self, seq: u64) -> Result<(), String> {
        super::envelope_seq::store_last_seq(seq).map_err(|err| format!("{err:?}"))
    }
}

/// User process → daemon. `None` when the daemon was not reached, is not root, or did not
/// answer with a result in time; the caller then reports `apply_failed` and changes nothing.
#[cfg(target_os = "macos")]
pub async fn request_daemon(envelopes: Vec<String>) -> Option<Vec<SenseApplyOutcome>> {
    use crate::ipc::{self, Data};
    if envelopes.is_empty() || !within_limits(&envelopes) {
        return None;
    }
    // Only a peer with uid 0 is accepted as the daemon.
    let mut conn = ipc::connect_trusted_device_service(1000).await.ok()?;
    conn.send(&Data::SenseEnvelope(SenseEnvelopeIpc::Apply {
        envelopes,
        server_time: None,
    }))
    .await
    .ok()?;
    match conn.next_timeout(DAEMON_TIMEOUT_MS).await {
        Ok(Some(Data::SenseEnvelope(SenseEnvelopeIpc::Result(outcomes)))) => Some(outcomes),
        _ => None,
    }
}

/// Called from `platform::macos::start_os_service` (root daemon). The daemon side needs no
/// start of its own: it is the `_service` IPC handler (`ipc.rs` → `apply_in_daemon`).
#[cfg(target_os = "macos")]
pub fn start_daemon_side() {}

#[cfg(test)]
mod tests;
