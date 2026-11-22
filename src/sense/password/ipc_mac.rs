//! Sense Remote (permanent password plan §2.1, §3.7, U12): macOS.
//!
//! The user `--server` (main IPC) forwards `Begin`, `Set`, `Cancel` and `StatusQuery` to the
//! root daemon over `_service` (`forward`). The daemon (`on_service_ipc`) trusts nothing from
//! that process (M5): it makes and keeps the nonce itself, signs the request with the root key
//! pair, checks the grant with the panel keys built into its own binary, the `id` of the root
//! config, the machine uuid and its own clock (§3.3), and only then writes the permanent
//! password into the root `Config` (the only way in: G4-3 still keeps `SyncConfig(Some)` from
//! touching it). On success it stores `access.json` with a signed ack and answers the hashed
//! storage value + salt, which the user `--server` takes over with
//! `Config::set_permanent_password_storage_for_sync`, so the process that checks incoming
//! connections uses the new password without a restart (plan §12-4). The UI never gets the
//! storage value.
//!
//! Limits in the daemon (U9 review: a new process must not reset them):
//! - per second, in two separate buckets (U12 review M2: a status poll or a cancel never makes
//!   the next `Begin`/`Set` `busy`): one call per peer process, `MAX_CALLS_PER_UID` for all
//!   processes of one uid, `MAX_CALLS_PER_SECOND` in total (`busy`);
//! - `Begin` `MAX_BEGINS_PER_HOUR` per rolling hour for the whole daemon (`rate_limited`);
//! - `Set` `MAX_SETS_PER_NONCE` per pending nonce, then the nonce is dropped (`no_pending`).
//!
//! Nothing of a grant, a password, a nonce or a storage value is logged; only answer codes.
//! The decision logic (`Daemon::handle`) is pure over `DaemonEnv`, so it is tested on every
//! platform; `RootEnv` (unix) wires it to the root config, `access.json` and the role file.
//! MAC-SONRA: checked on a device with the rest of the Mac password flow (M-K1/M-K2).

use super::{
    ack::{sign_ack, PasswordAckPayload},
    grant::{check_for_set, GrantContext},
    pending::Pending,
    request::{incoming_role, sign_request, PasswordRequestPayload},
    status::{status_from, AccessRecord, AccessStatus},
    SensePasswordIpc, SensePasswordSecret, UNSUPPORTED,
};
use crate::sense::{envelope_keys::TrustedKey, SenseRole};
use hbb_common::log;
use std::{
    collections::{HashMap, VecDeque},
    time::{Duration, Instant},
};

/// Calls of one peer process per second.
pub const MAX_CALLS_PER_PID: u32 = 1;
/// Calls of all processes of one uid together per second.
pub const MAX_CALLS_PER_UID: u32 = 3;
/// Calls of everyone together per second.
pub const MAX_CALLS_PER_SECOND: u32 = 8;
/// Peers (processes or uids) tracked within one second; more new ones are `busy`.
pub const MAX_LIMITED_PEERS: usize = 64;
/// `Begin` calls per rolling hour, whole daemon (§3.7: "saatte 6").
pub const MAX_BEGINS_PER_HOUR: usize = 6;
/// `Set` calls per pending nonce (§3.7: "en çok 10").
pub const MAX_SETS_PER_NONCE: u32 = 10;
const CALL_WINDOW: Duration = Duration::from_secs(1);
const BEGIN_WINDOW: Duration = Duration::from_secs(3600);

/// Answer codes of this module (the others come from `grant`).
pub const BUSY: &str = "busy";
pub const RATE_LIMITED: &str = "rate_limited";
pub const NOT_INCOMING: &str = "not_incoming";
pub const NO_PENDING: &str = "no_pending";
pub const WRITE_FAILED: &str = "write_failed";
pub const IPC_FAILED: &str = "ipc_failed";

/// User `--server` → daemon timeouts; below the UI's own (`ui::IPC_*_MS`).
const DAEMON_BEGIN_MS: u64 = 4_000;
const DAEMON_SET_MS: u64 = 12_000;
const DAEMON_STATUS_MS: u64 = 800;
/// The user `--server` keeps the daemon's status this long (§8 U12: 60 s cache).
pub const STATUS_CACHE: Duration = Duration::from_secs(60);

// ---------------------------------------------------------------------------------------------
// Daemon (root): limits
// ---------------------------------------------------------------------------------------------

/// Per-second call limit over fixed one-second windows, per pid, per uid and in total. A peer
/// without a readable pid or uid shares one slot (`u32::MAX`), so hiding them does not help.
#[derive(Debug, Default)]
pub struct CallLimiter {
    window: Option<Instant>,
    total: u32,
    by_pid: HashMap<u32, u32>,
    by_uid: HashMap<u32, u32>,
}

impl CallLimiter {
    pub fn allow(&mut self, pid: Option<u32>, uid: Option<u32>, now: Instant) -> bool {
        if self
            .window
            .map_or(true, |start| now.saturating_duration_since(start) >= CALL_WINDOW)
        {
            self.window = Some(now);
            self.total = 0;
            self.by_pid.clear();
            self.by_uid.clear();
        }
        let pid = pid.unwrap_or(u32::MAX);
        let uid = uid.unwrap_or(u32::MAX);
        let pid_calls = self.by_pid.get(&pid).copied().unwrap_or(0);
        let uid_calls = self.by_uid.get(&uid).copied().unwrap_or(0);
        let too_many_peers = (pid_calls == 0 && self.by_pid.len() >= MAX_LIMITED_PEERS)
            || (uid_calls == 0 && self.by_uid.len() >= MAX_LIMITED_PEERS);
        if pid_calls >= MAX_CALLS_PER_PID
            || uid_calls >= MAX_CALLS_PER_UID
            || self.total >= MAX_CALLS_PER_SECOND
            || too_many_peers
        {
            return false;
        }
        self.total += 1;
        self.by_pid.insert(pid, pid_calls + 1);
        self.by_uid.insert(uid, uid_calls + 1);
        true
    }
}

/// `Begin` limit for the whole daemon over a rolling hour (not per peer: a fresh process gets
/// no fresh allowance).
#[derive(Debug, Default)]
pub struct BeginLimiter {
    started: VecDeque<Instant>,
}

impl BeginLimiter {
    pub fn allow(&mut self, now: Instant) -> bool {
        while self
            .started
            .front()
            .is_some_and(|at| now.saturating_duration_since(*at) >= BEGIN_WINDOW)
        {
            self.started.pop_front();
        }
        if self.started.len() >= MAX_BEGINS_PER_HOUR {
            return false;
        }
        self.started.push_back(now);
        true
    }
}

// ---------------------------------------------------------------------------------------------
// Daemon (root): decisions
// ---------------------------------------------------------------------------------------------

/// What the daemon reads and writes around a decision. Everything comes from the daemon itself
/// (root config, root state file, its own binary, its own clock), never from the peer.
pub trait DaemonEnv {
    /// Installed role (root state file). `Err` = present but unreadable.
    fn role(&mut self) -> Result<Option<SenseRole>, String>;
    /// `iss`, `rid`, `duuid` and the local time the grant must name (§3.3 steps 6–8).
    fn grant_context(&mut self) -> GrantContext;
    /// Panel keys built into this binary (`SENSE_ENVELOPE_KEYS`).
    fn keys(&self) -> &[TrustedKey];
    /// `(platform, Sense version)` for the request; `None` = a build the panel does not know.
    fn build(&self) -> Option<(&'static str, u32)>;
    /// The device's Ed25519 secret key (RustDesk key pair of the root config).
    fn secret_key(&mut self) -> Vec<u8>;
    fn has_permanent_password(&mut self) -> bool;
    /// §3.3 step 11. `Ok((storage, salt))` = the hashed storage value now in the root config.
    fn write_password(
        &mut self,
        password: &SensePasswordSecret,
    ) -> Result<(SensePasswordSecret, String), String>;
    fn read_record(&mut self) -> Result<Option<AccessRecord>, String>;
    fn write_record(&mut self, record: &AccessRecord) -> Result<(), String>;
}

/// The daemon's in-memory state: the one pending nonce and the limits. `changes` limits
/// `Begin`/`Set`, `queries` `StatusQuery`/`Cancel` (separate buckets, M2).
#[derive(Debug, Default)]
pub struct Daemon {
    pending: Pending,
    changes: CallLimiter,
    queries: CallLimiter,
    begins: BeginLimiter,
    sets_for_nonce: u32,
}

/// A `Set` whose grant passed (§3.3 steps 1–10, nonce used up): left to do are the write
/// (step 11) and the record (12). Run after the daemon's lock is released (U12 review M5), so
/// the trusted-device snapshot and the config write never run under it.
pub struct SetWork {
    grant: super::grant::PasswordGrantPayload,
    first: bool,
    now: i64,
    password: SensePasswordSecret,
}

impl std::fmt::Debug for SetWork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SetWork")
    }
}

/// What the daemon decided under its lock.
#[derive(Debug)]
pub enum Decision {
    Reply(Option<SensePasswordIpc>),
    Write(SetWork),
}

impl SetWork {
    /// Steps 11–12, outside the daemon's lock.
    pub fn run<E: DaemonEnv>(self, env: &mut E) -> SensePasswordIpc {
        let (storage, salt) = match env.write_password(&self.password) {
            Ok(written) => written,
            Err(err) => {
                log::error!("Sense Remote: permanent password not written: {err}");
                return set_result(WRITE_FAILED);
            }
        };
        let ack = sign_ack(
            &PasswordAckPayload::for_grant(&self.grant, self.first, self.now),
            &env.secret_key(),
        );
        if ack.is_err() {
            log::error!("Sense Remote: password ack not signed");
        }
        if let Err(err) = env.write_record(&AccessRecord::after_change(self.now, ack.ok())) {
            // The password is in place; only the panel's "changed" line waits for the next one.
            log::error!("Sense Remote: access record not written: {err}");
        }
        log::info!("Sense Remote: permanent password changed by the daemon");
        SensePasswordIpc::SetResult {
            code: String::new(),
            storage: Some(storage),
            salt: Some(salt),
        }
    }
}

fn set_result(code: &str) -> SensePasswordIpc {
    SensePasswordIpc::SetResult {
        code: code.to_owned(),
        storage: None,
        salt: None,
    }
}

/// The answer of a call refused before it was looked at (`busy`) or for a role that takes no
/// incoming connections.
fn refusal(message: &SensePasswordIpc, code: &str) -> Option<SensePasswordIpc> {
    match message {
        SensePasswordIpc::Begin => Some(SensePasswordIpc::Request(Err(code.to_owned()))),
        SensePasswordIpc::Set { .. } => Some(set_result(code)),
        _ => None,
    }
}

impl Daemon {
    /// One `_service` message decided and done in one go (tests). The daemon itself calls
    /// `decide` under its lock and runs the write after releasing it.
    pub fn handle<E: DaemonEnv>(
        &mut self,
        message: SensePasswordIpc,
        pid: Option<u32>,
        uid: Option<u32>,
        now: Instant,
        env: &mut E,
    ) -> Option<SensePasswordIpc> {
        match self.decide(message, pid, uid, now, env) {
            Decision::Reply(reply) => reply,
            Decision::Write(work) => Some(work.run(env)),
        }
    }

    /// One `_service` message. `Reply(None)` = no answer (`Cancel`, answer kinds, calls over
    /// the limit that have no answer kind).
    pub fn decide<E: DaemonEnv>(
        &mut self,
        message: SensePasswordIpc,
        pid: Option<u32>,
        uid: Option<u32>,
        now: Instant,
        env: &mut E,
    ) -> Decision {
        // Answer kinds never come from a client (`sense_service_accepts` already drops them).
        if !matches!(
            message,
            SensePasswordIpc::Begin
                | SensePasswordIpc::Set { .. }
                | SensePasswordIpc::Cancel
                | SensePasswordIpc::StatusQuery
        ) {
            return Decision::Reply(None);
        }
        let bucket = match message {
            SensePasswordIpc::Begin | SensePasswordIpc::Set { .. } => &mut self.changes,
            _ => &mut self.queries,
        };
        if !bucket.allow(pid, uid, now) {
            log::warn!("Sense Remote: password call refused (rate limit)");
            return Decision::Reply(refusal(&message, BUSY));
        }
        match message {
            SensePasswordIpc::StatusQuery => Decision::Reply(Some(SensePasswordIpc::Status(
                self.status(env).to_json(),
            ))),
            SensePasswordIpc::Cancel => {
                self.pending.cancel();
                self.sets_for_nonce = 0;
                Decision::Reply(None)
            }
            SensePasswordIpc::Begin => {
                Decision::Reply(Some(SensePasswordIpc::Request(self.begin(now, env))))
            }
            SensePasswordIpc::Set { grant, password } => {
                match self.check_set(&grant, &password, now, env) {
                    Ok(work) => Decision::Write(work),
                    Err(code) => Decision::Reply(Some(set_result(&code))),
                }
            }
            _ => Decision::Reply(None),
        }
    }

    fn status<E: DaemonEnv>(&mut self, env: &mut E) -> AccessStatus {
        let record = env.read_record().unwrap_or_else(|err| {
            log::warn!("Sense Remote: access record not readable: {err}");
            None
        });
        let now = env.grant_context().now;
        status_from(env.has_permanent_password(), record.as_ref(), now)
    }

    fn incoming<E: DaemonEnv>(env: &mut E) -> Result<&'static str, &'static str> {
        match env.role() {
            Ok(Some(role)) => incoming_role(role).ok_or(NOT_INCOMING),
            Ok(None) => Err(NOT_INCOMING),
            Err(err) => {
                log::warn!("Sense Remote: password call refused, role not readable: {err}");
                Err(UNSUPPORTED)
            }
        }
    }

    fn begin<E: DaemonEnv>(&mut self, now: Instant, env: &mut E) -> Result<String, String> {
        let role = Self::incoming(env)?;
        let (platform, version) = env.build().ok_or(UNSUPPORTED)?;
        if !self.begins.allow(now) {
            log::warn!("Sense Remote: password unlock refused (hourly limit)");
            return Err(RATE_LIMITED.to_owned());
        }
        let nonce = self.pending.begin(now).ok_or(UNSUPPORTED)?;
        self.sets_for_nonce = 0;
        let ctx = env.grant_context();
        let payload =
            PasswordRequestPayload::new(&ctx.rid, &ctx.duuid, &nonce, role, platform, version, ctx.now);
        let signed = sign_request(&payload, &env.secret_key());
        if let Err(err) = signed {
            log::warn!("Sense Remote: password request not signed: {err}");
            self.pending.cancel();
        }
        signed.map_err(|_| UNSUPPORTED.to_owned())
    }

    /// §3.3 steps 1–10 under the lock; `Err` = the answer code. On `Ok` the nonce is used up
    /// (single use), whatever the write does.
    fn check_set<E: DaemonEnv>(
        &mut self,
        grant: &str,
        password: &SensePasswordSecret,
        now: Instant,
        env: &mut E,
    ) -> Result<SetWork, String> {
        Self::incoming(env)?;
        if !self.pending.is_pending(now) {
            return Err(NO_PENDING.to_owned());
        }
        self.sets_for_nonce += 1;
        if self.sets_for_nonce > MAX_SETS_PER_NONCE {
            log::warn!("Sense Remote: pending password unlock dropped (too many attempts)");
            self.pending.cancel();
            return Err(NO_PENDING.to_owned());
        }
        let ctx = env.grant_context();
        let first = !env.has_permanent_password();
        let grant = check_for_set(grant, password, env.keys(), &ctx, &mut self.pending, now)
            .map_err(|code| {
                log::warn!("Sense Remote: permanent password not changed: {code}");
                code
            })?;
        Ok(SetWork {
            grant,
            first,
            now: ctx.now,
            password: password.clone(),
        })
    }
}

/// Daemon (root), `_service` channel; blocking, called off the async loop. `None` = no answer.
/// Only macOS acts; elsewhere (Linux has a `_service` channel too) and while the feature is off
/// every request is `unsupported`.
pub fn on_service_ipc(
    message: SensePasswordIpc,
    peer_pid: Option<u32>,
    peer_uid: Option<u32>,
) -> Option<SensePasswordIpc> {
    #[cfg(target_os = "macos")]
    if super::SUPPORTED {
        use std::sync::{Mutex, OnceLock};
        static DAEMON: OnceLock<Mutex<Daemon>> = OnceLock::new();
        let decision = DAEMON
            .get_or_init(|| Mutex::new(Daemon::default()))
            .lock()
            .unwrap_or_else(|err| err.into_inner())
            .decide(message, peer_pid, peer_uid, Instant::now(), &mut root::RootEnv);
        // U12 review M5: the lock guard was a temporary of the statement above and is gone;
        // the write (trusted-device snapshot, config store) runs outside it.
        return match decision {
            Decision::Reply(reply) => reply,
            Decision::Write(work) => Some(work.run(&mut root::RootEnv)),
        };
    }
    let _ = (peer_pid, peer_uid);
    super::unsupported_answer(&message)
}

/// The daemon's real surroundings. `cfg(unix)` so Linux CI compiles it; only macOS calls it.
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod root {
    use super::*;
    use hbb_common::config::Config;

    pub struct RootEnv;

    impl DaemonEnv for RootEnv {
        fn role(&mut self) -> Result<Option<SenseRole>, String> {
            crate::sense::installed_role_state()
        }
        fn grant_context(&mut self) -> GrantContext {
            GrantContext {
                iss: crate::sense::envelope::expected_issuer(),
                rid: Config::get_id(),
                duuid: crate::encode64(hbb_common::get_uuid()),
                now: hbb_common::get_time() / 1000,
            }
        }
        fn keys(&self) -> &[TrustedKey] {
            crate::sense::envelope_keys::trusted_keys()
        }
        fn build(&self) -> Option<(&'static str, u32)> {
            Some((
                crate::sense::report::platform()?,
                crate::sense::report::app_version()?,
            ))
        }
        fn secret_key(&mut self) -> Vec<u8> {
            Config::get_key_pair().0
        }
        fn has_permanent_password(&mut self) -> bool {
            Config::has_permanent_password()
        }
        fn write_password(
            &mut self,
            password: &SensePasswordSecret,
        ) -> Result<(SensePasswordSecret, String), String> {
            use crate::trusted_devices::config::{changes_password, set_password, update_auth};
            if password.expose().is_empty() {
                return Err("empty".to_owned());
            }
            // The same call as the main IPC's `permanent-password` write (trusted-device
            // snapshot first), run on the runtime this blocking thread came from.
            let affected = changes_password(password.expose());
            let value = password.clone();
            let handle = hbb_common::tokio::runtime::Handle::try_current()
                .map_err(|_| "no runtime".to_owned())?;
            let written = handle
                .block_on(update_auth(affected, move || set_password(value.expose())))
                .map_err(|err| err.to_string())?;
            if !written || !Config::has_local_permanent_password() {
                return Err("not stored".to_owned());
            }
            let (storage, salt) = Config::get_local_permanent_password_storage_and_salt();
            Ok((SensePasswordSecret::new(storage), salt))
        }
        fn read_record(&mut self) -> Result<Option<AccessRecord>, String> {
            super::super::store_mac::read()
        }
        fn write_record(&mut self, record: &AccessRecord) -> Result<(), String> {
            super::super::store_mac::write(record)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// User `--server`: forwarding
// ---------------------------------------------------------------------------------------------

/// The daemon's last status as the user `--server` saw it.
struct CachedStatus {
    at: Instant,
    status: AccessStatus,
}

fn status_cache() -> &'static std::sync::Mutex<Option<CachedStatus>> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<Option<CachedStatus>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(Default::default)
}

fn cached_status(now: Instant, max_age: Duration) -> Option<AccessStatus> {
    let cache = status_cache().lock().unwrap_or_else(|err| err.into_inner());
    cache
        .as_ref()
        .filter(|cached| now.saturating_duration_since(cached.at) < max_age)
        .map(|cached| cached.status.clone())
}

fn store_status(status: Option<AccessStatus>, now: Instant) {
    let mut cache = status_cache().lock().unwrap_or_else(|err| err.into_inner());
    *cache = status.map(|status| CachedStatus { at: now, status });
}

/// Keeps only the daemon answer that fits the request; anything else counts as no answer.
pub fn fitting_reply(request: &SensePasswordIpc, reply: SensePasswordIpc) -> Option<SensePasswordIpc> {
    let fits = matches!(
        (request, &reply),
        (SensePasswordIpc::Begin, SensePasswordIpc::Request(_))
            | (SensePasswordIpc::Set { .. }, SensePasswordIpc::SetResult { .. })
            | (SensePasswordIpc::StatusQuery, SensePasswordIpc::Status(_))
    );
    fits.then_some(reply)
}

/// The user `--server`'s side of a daemon `SetResult`: on success the storage value and salt
/// go into this process's config (`store`); the UI gets the code only, never the storage.
pub fn take_set_result(
    reply: SensePasswordIpc,
    store: impl FnOnce(&str, &str) -> Result<(), String>,
) -> SensePasswordIpc {
    let SensePasswordIpc::SetResult { code, storage, salt } = reply else {
        return set_result(IPC_FAILED);
    };
    if code.is_empty() {
        match (storage, salt) {
            (Some(storage), Some(salt)) => {
                if let Err(err) = store(storage.expose(), &salt) {
                    // Root has the new password and the ack; this process takes it over from
                    // root at its next start (plan §12-4).
                    log::error!("Sense Remote: new password storage not taken over: {err}");
                }
            }
            _ => log::error!("Sense Remote: daemon changed the password without a storage value"),
        }
    }
    set_result(&code)
}

/// What the main IPC answers when the daemon was not reached or answered something else.
fn no_daemon(request: &SensePasswordIpc) -> Option<SensePasswordIpc> {
    match request {
        SensePasswordIpc::Begin => Some(SensePasswordIpc::Request(Err(IPC_FAILED.to_owned()))),
        SensePasswordIpc::Set { .. } => Some(set_result(IPC_FAILED)),
        _ => None,
    }
}

/// User `--server` → daemon; `None` when the daemon was not reached or did not answer in time.
#[cfg(target_os = "macos")]
async fn ask_daemon(message: &SensePasswordIpc, timeout_ms: Option<u64>) -> Option<SensePasswordIpc> {
    use crate::ipc::{self, Data};
    // Only a peer with uid 0 is accepted as the daemon.
    let mut conn = ipc::connect_trusted_device_service(1000).await.ok()?;
    conn.send(&Data::SensePassword(message.clone())).await.ok()?;
    match conn.next_timeout(timeout_ms?).await {
        Ok(Some(Data::SensePassword(reply))) => fitting_reply(message, reply),
        _ => None,
    }
}

#[cfg(not(target_os = "macos"))]
async fn ask_daemon(_message: &SensePasswordIpc, _timeout_ms: Option<u64>) -> Option<SensePasswordIpc> {
    None
}

/// User `--server`, main IPC: forwards to the daemon and passes its answer back.
pub async fn forward(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
    if !super::SUPPORTED {
        return super::unsupported_answer(&message);
    }
    match &message {
        SensePasswordIpc::StatusQuery => {
            let now = Instant::now();
            if let Some(status) = cached_status(now, STATUS_CACHE) {
                return Some(SensePasswordIpc::Status(status.to_json()));
            }
            let status = refresh_status().await?;
            Some(SensePasswordIpc::Status(status.to_json()))
        }
        SensePasswordIpc::Begin => ask_daemon(&message, Some(DAEMON_BEGIN_MS))
            .await
            .or_else(|| no_daemon(&message)),
        SensePasswordIpc::Set { .. } => {
            let reply = ask_daemon(&message, Some(DAEMON_SET_MS)).await;
            // Whatever happened, the next status comes fresh from the daemon.
            store_status(None, Instant::now());
            match reply {
                Some(reply) => Some(take_set_result(reply, |storage, salt| {
                    hbb_common::config::Config::set_permanent_password_storage_for_sync(storage, salt)
                        .map(|_| ())
                        .map_err(|err| err.to_string())
                })),
                None => no_daemon(&message),
            }
        }
        SensePasswordIpc::Cancel => {
            ask_daemon(&message, None).await;
            None
        }
        SensePasswordIpc::Request(_) | SensePasswordIpc::SetResult { .. } | SensePasswordIpc::Status(_) => {
            None
        }
    }
}

/// Asks the daemon for its status and keeps it (`STATUS_CACHE`).
async fn refresh_status() -> Option<AccessStatus> {
    let reply = ask_daemon(&SensePasswordIpc::StatusQuery, Some(DAEMON_STATUS_MS)).await;
    let status = match reply {
        Some(SensePasswordIpc::Status(json)) => serde_json::from_str::<AccessStatus>(&json).ok(),
        _ => None,
    };
    if status.is_some() {
        store_status(status.clone(), Instant::now());
    }
    status
}

/// `sense.access` for the heartbeat on macOS (the user `--server` sends it): the daemon's
/// status from the cache; an older one starts a refresh for the next heartbeat. `None` while
/// nothing is known or the feature is off. To be called from `status::heartbeat_ext`.
pub fn heartbeat_ext() -> Option<AccessStatus> {
    if !super::SUPPORTED {
        return None;
    }
    let now = Instant::now();
    let fresh = cached_status(now, STATUS_CACHE);
    if fresh.is_none() {
        if let Ok(handle) = hbb_common::tokio::runtime::Handle::try_current() {
            handle.spawn(async {
                refresh_status().await;
            });
        }
    }
    // A heartbeat carries what is known, up to a few cache periods old.
    fresh.or_else(|| cached_status(now, STATUS_CACHE * 5))
}

#[cfg(test)]
mod tests;
