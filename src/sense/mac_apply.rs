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
//! and the connection ids to close all come out of the signed payload; the panel's server time
//! is not passed on (validity is checked against the daemon's clock, plan R8). Nothing of an
//! envelope is logged: only the reason of a rejection and, once the signature is valid, its seq.
//!
//! Security review 2026-11-21:
//! - G4-2: the user process reports the seq it has *followed* (`Followed`), not the daemon's.
//!   When the daemon applied an envelope but its answer was lost, the panel therefore sends the
//!   envelope again; the daemon recognises the envelope it applied last (fully verified, seq
//!   equal to the stored one) and answers `Applied` again without writing, so the user process
//!   can catch up (settings, disconnect, role) and only then reports the seq.
//! - G4-3: with an installed role the daemon keeps its own values for the permission settings,
//!   the access settings and the identity when a user process syncs its config to root
//!   (`keep_root_options`, `keep_root_config`).
//! - G4-4: the call limit is per peer process (`CallLimiter`); a call that came too soon is
//!   answered with `busy` and does not take anything from other peers.
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
use hbb_common::log;
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

/// Limits of one `Apply` call; a call above them is ignored as a whole and logged.
pub const MAX_ENVELOPES: usize = 8;
pub const MAX_TOTAL_BYTES: usize = 64 * 1024;
/// At most one `Apply` call per peer process per this many milliseconds.
pub const MIN_CALL_INTERVAL_MS: u64 = 1000;
/// Peers the limiter remembers at once; more than that within one interval are `busy`.
pub const MAX_LIMITED_PEERS: usize = 64;
/// `Rejected.reason` of a call that came too soon (G4-4). Not an `envelope::Reason`: the user
/// process reports it as `apply_failed` and tries again with the next heartbeat.
pub const REASON_BUSY: &str = "busy";
/// How long the user process waits for the daemon's answer.
pub const DAEMON_TIMEOUT_MS: u64 = 5000;

/// Envelope settings macOS can not honour: accepted as part of the full set (G2-7) but never
/// written. Empty since Sürüm 9 (MAC-SONRA-15): macOS has the maintenance curtain, so the ghost
/// mode permission (`enable-privacy-mode`) is written as on Windows.
pub const MAC_UNSUPPORTED_OPTIONS: [&str; 0] = [];

/// Payload of `ipc::Data::SenseEnvelope`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseEnvelopeIpc {
    /// User process → daemon: raw envelope JSON as received from the panel (≤ `MAX_ENVELOPES`).
    /// Earlier builds also sent `server_time` (always `null`, never used); a message that still
    /// carries it is read as before, the field is ignored.
    Apply { envelopes: Vec<String> },
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

/// Sense Remote (G4-4): the call limit per peer process (pid of the IPC peer), so one local
/// process sending calls every second can not starve the agent's own call. Time is a
/// monotonic millisecond counter supplied by the caller.
#[derive(Debug, Default)]
pub struct CallLimiter {
    last_call_ms: HashMap<u32, u64>,
}

impl CallLimiter {
    /// True when `peer` may call now (and remembers the call).
    pub fn allow(&mut self, peer: u32, now_ms: u64) -> bool {
        // Entries older than the interval no longer limit anything.
        self.last_call_ms
            .retain(|_, at| now_ms.saturating_sub(*at) < MIN_CALL_INTERVAL_MS);
        if self.last_call_ms.contains_key(&peer) || self.last_call_ms.len() >= MAX_LIMITED_PEERS {
            return false;
        }
        self.last_call_ms.insert(peer, now_ms);
        true
    }
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

fn disconnect_ids(verified: &super::envelope::Verified) -> Vec<i32> {
    verified
        .body
        .disconnect
        .iter()
        .flatten()
        .filter_map(|id| i32::try_from(*id).ok())
        .collect()
}

/// Sense Remote (G4-2): the envelope the daemon applied last, sent again because the user
/// process never got the answer. It must pass the whole verification as it did the first time
/// (checked against the seq before it) and carry exactly the stored seq; then the daemon
/// answers `Applied` again and writes nothing. `role` = the role this envelope set, when it is
/// the installed one.
fn already_applied(
    item: &Value,
    ctx: &DaemonContext,
    installed: Option<SenseRole>,
    last_seq: u64,
) -> Option<SenseApplyOutcome> {
    let expect = Expect {
        iss: ctx.iss,
        did: ctx.did,
        duuid: ctx.duuid,
        now_s: ctx.now_s,
        last_seq: last_seq.checked_sub(1)?,
    };
    let verified = envelope_apply::check(item, ctx.keys, &expect, ctx.applies).ok()?;
    if verified.seq != last_seq {
        return None;
    }
    let role = verified
        .body
        .sense_role
        .map(|role| role.sense_role())
        .filter(|role| Some(*role) == installed);
    Some(SenseApplyOutcome::Applied {
        seq: last_seq,
        role: role.map(|role| role.as_str().to_owned()),
        disconnect: disconnect_ids(&verified),
    })
}

/// Daemon side, one envelope: full verification with the daemon's data, then the writes.
/// Either everything is stored (`Applied`) or nothing changed (`Rejected`; or `Applied` again
/// for the envelope applied last, see `already_applied`).
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
            Err(Rejection { reason, seq, .. }) => {
                if readable && reason == Reason::Replayed && seq == Some(last_seq) {
                    if let Some(outcome) = already_applied(&item, ctx, installed, last_seq) {
                        log::info!(
                            "Sense Remote: daemon was asked again for applied envelope {last_seq}"
                        );
                        return outcome;
                    }
                }
                return rejected(reason, seq);
            }
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
        disconnect: disconnect_ids(&verified),
    }
}

/// Daemon side, one `Apply` call. `allowed` = the peer's call limit (`CallLimiter::allow`).
/// A call over the size limits is ignored (empty answer); a call that came too soon is answered
/// with `busy` for every envelope (G4-4). In both cases nothing was read, verified or written.
pub fn apply_call<S: DaemonStore>(
    envelopes: &[String],
    allowed: bool,
    ctx: &DaemonContext,
    store: &mut S,
) -> Vec<SenseApplyOutcome> {
    if !within_limits(envelopes) {
        log::warn!(
            "Sense Remote: daemon ignored an envelope call (limits: {} envelopes)",
            envelopes.len()
        );
        return Vec::new();
    }
    if !allowed {
        log::warn!("Sense Remote: daemon ignored an envelope call (rate limit)");
        return envelopes
            .iter()
            .map(|_| SenseApplyOutcome::Rejected {
                reason: REASON_BUSY.to_owned(),
            })
            .collect();
    }
    envelopes
        .iter()
        .map(|raw| apply_one(raw, ctx, store))
        .collect()
}

/// Sense Remote (G4-2): how far the user process has followed the daemon: the seq of the last
/// envelope whose settings, disconnects and role it carried out itself, and the role it runs
/// with. Starts at the root state when the process starts (its config was just synced from
/// root); from then on only `follow` moves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Followed {
    pub seq: u64,
    pub role: Option<SenseRole>,
}

impl Followed {
    /// The seq this process checks envelopes against and reports as `applied_seq`: never ahead
    /// of the daemon's stored seq, and behind it while an applied envelope was not followed.
    pub fn reported(&self, root_seq: u64) -> u64 {
        self.seq.min(root_seq)
    }

    /// After this process carried out an envelope the daemon applied. Returns the role it ran
    /// with before (for the restart decision).
    pub fn follow(&mut self, applied: &AppliedByDaemon) -> Option<SenseRole> {
        let before = self.role;
        self.seq = self.seq.max(applied.seq);
        if applied.role.is_some() {
            self.role = applied.role;
        }
        before
    }
}

/// Sense Remote (G4-3): `Config` fields (serde names) the daemon does not take from a user
/// process once a role is installed: identity, key pair and the permanent password.
pub const PROTECTED_CONFIG_FIELDS: [&str; 5] = ["id", "enc_id", "password", "salt", "key_pair"];
/// Sense Remote (G4-3): options besides the envelope's allow list that decide who gets in.
pub const PROTECTED_ACCESS_OPTIONS: [&str; 3] = ["verification-method", "approve-mode", "whitelist"];

/// Options the daemon keeps its own value for: everything an envelope sets, plus the access
/// settings.
pub fn is_protected_option(key: &str) -> bool {
    is_protected_with(key, None)
}

/// Sense Remote (K27): like `is_protected_option`, but an optional Host setting the last applied
/// envelope did not carry (`marker` = root's `envelope::OPTION_MANAGED_EXT`) is free: the user's
/// change passes, matching the unlocked setting in the app.
pub fn is_protected_with(key: &str, marker: Option<&str>) -> bool {
    PROTECTED_ACCESS_OPTIONS.contains(&key) || super::envelope::is_panel_managed(key, marker)
}

/// Sense Remote (G4-3): the daemon protects its config when a Sense role that takes incoming
/// connections is installed, and also when the state can not be read (never less strict on an
/// error). `state` = the state file read: `Ok(None)` no Sense install, `Ok(Some(role))`.
pub fn sync_protected(state: Result<Option<Option<SenseRole>>, String>) -> bool {
    match state {
        Ok(None) => false,
        Ok(Some(role)) => role != Some(SenseRole::Controller),
        Err(_) => true,
    }
}

/// Sense Remote (G4-3): protected options of `incoming` (from a user process) are replaced by
/// root's own: its value, or no value when root has none. Other options pass.
pub fn keep_root_options(incoming: &mut HashMap<String, String>, root: &HashMap<String, String>) {
    let marker = root.get(super::envelope::OPTION_MANAGED_EXT).map(String::as_str);
    incoming.retain(|key, _| !is_protected_with(key, marker));
    for (key, value) in root {
        if is_protected_with(key, marker) {
            incoming.insert(key.clone(), value.clone());
        }
    }
}

/// Sense Remote (G4-3): the same for the named fields of a serialized `Config` (its
/// identity fields are private to `hbb_common`, so the daemon merges the serde form the IPC
/// already carries). False when either side is not an object; the caller then keeps root's.
pub fn keep_root_fields(incoming: &mut Value, root: &Value, fields: &[&str]) -> bool {
    let (Some(incoming), Some(root)) = (incoming.as_object_mut(), root.as_object()) else {
        return false;
    };
    for field in fields {
        match root.get(*field) {
            Some(value) => incoming.insert((*field).to_owned(), value.clone()),
            None => incoming.remove(*field),
        };
    }
    true
}

/// Sense Remote (G4-3, K4-10): `incoming` (the config a user process syncs) with `fields`
/// replaced by root's, through the serde form: serialize both → `keep_root_fields` →
/// deserialize. `Err` names the step that failed. It never carries the serde message: that
/// can quote a value (password, key), and the caller logs the error.
pub fn merge_root_fields<T>(incoming: &T, root: &T, fields: &[&str]) -> Result<T, &'static str>
where
    T: serde::Serialize + serde::de::DeserializeOwned,
{
    let mut merged = serde_json::to_value(incoming).map_err(|_| "serialize-incoming")?;
    let own = serde_json::to_value(root).map_err(|_| "serialize-root")?;
    if !keep_root_fields(&mut merged, &own, fields) {
        return Err("not-an-object");
    }
    serde_json::from_value(merged).map_err(|_| "deserialize-merged")
}

/// Sense Remote (G4-3, K4-10): what the daemon takes from a config sync. When the merge fails
/// nothing of the user's config is taken: root's own config is kept as it is, and the failure
/// is logged (throttled: a user process syncs again and again).
pub fn keep_root_config<T>(incoming: &T, root: T, fields: &[&str]) -> T
where
    T: serde::Serialize + serde::de::DeserializeOwned,
{
    match merge_root_fields(incoming, &root, fields) {
        Ok(merged) => merged,
        Err(step) => {
            hbb_common::throttled_log!(
                std::time::Duration::from_secs(60),
                error,
                "Sense Remote: config sync of a user process not merged ({step}), root config kept"
            );
            root
        }
    }
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
/// One call at a time (the lock also carries the per-peer rate limit). `peer_pid` = pid of the
/// IPC peer, only for the rate limit.
#[cfg(target_os = "macos")]
pub fn apply_in_daemon(envelopes: &[String], peer_pid: Option<u32>) -> Vec<SenseApplyOutcome> {
    use std::{
        sync::{Mutex, OnceLock},
        time::Instant,
    };
    static LIMITER: OnceLock<Mutex<(Instant, CallLimiter)>> = OnceLock::new();
    let mut limiter = LIMITER
        .get_or_init(|| Mutex::new((Instant::now(), CallLimiter::default())))
        .lock()
        .unwrap_or_else(|err| err.into_inner());
    let now_ms = limiter.0.elapsed().as_millis().min(u64::MAX as u128) as u64;
    // A peer without a readable pid shares one slot.
    let allowed = limiter.1.allow(peer_pid.unwrap_or(0), now_ms);
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
    apply_call(envelopes, allowed, &ctx, &mut RootStore)
}

/// Other platforms have no root daemon that applies envelopes: every envelope is rejected and
/// nothing changes.
#[cfg(not(target_os = "macos"))]
pub fn apply_in_daemon(envelopes: &[String], _peer_pid: Option<u32>) -> Vec<SenseApplyOutcome> {
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
    conn.send(&Data::SenseEnvelope(SenseEnvelopeIpc::Apply { envelopes }))
        .await
        .ok()?;
    match conn.next_timeout(DAEMON_TIMEOUT_MS).await {
        Ok(Some(Data::SenseEnvelope(SenseEnvelopeIpc::Result(outcomes)))) => Some(outcomes),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
