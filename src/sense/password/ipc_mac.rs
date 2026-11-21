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
//! - one call a second per peer process, `MAX_CALLS_PER_UID` a second for all processes of one
//!   uid, `MAX_CALLS_PER_SECOND` in total (`busy`);
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
    status::AccessStatus,
    store_mac::AccessRecord,
    SensePasswordIpc, SensePasswordSecret, PASSWORD_ACK_REPORT_S, UNSUPPORTED,
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

/// The daemon's in-memory state: the one pending nonce and the limits.
#[derive(Debug, Default)]
pub struct Daemon {
    pending: Pending,
    calls: CallLimiter,
    begins: BeginLimiter,
    sets_for_nonce: u32,
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

/// `AccessStatus` from the record: the ack only for `PASSWORD_ACK_REPORT_S` after it was made
/// (and not when its time lies in the future by more than the grant skew).
pub fn status_from(record: Option<&AccessRecord>, perm_set: bool, now: i64) -> AccessStatus {
    let ack = record.and_then(|record| {
        let at = record.ack_at?;
        let age = now.checked_sub(at)?;
        ((-super::grant::CLOCK_SKEW_BEFORE_S..=PASSWORD_ACK_REPORT_S).contains(&age))
            .then(|| record.ack.clone())
            .flatten()
    });
    AccessStatus {
        perm_set,
        changed_at: record.map(|record| record.changed_at),
        ack,
    }
}

impl Daemon {
    /// One `_service` message. `None` = no answer (`Cancel`, answer kinds, calls over the
    /// limit that have no answer kind).
    pub fn handle<E: DaemonEnv>(
        &mut self,
        message: SensePasswordIpc,
        pid: Option<u32>,
        uid: Option<u32>,
        now: Instant,
        env: &mut E,
    ) -> Option<SensePasswordIpc> {
        // Answer kinds never come from a client (`sense_service_accepts` already drops them).
        if !matches!(
            message,
            SensePasswordIpc::Begin
                | SensePasswordIpc::Set { .. }
                | SensePasswordIpc::Cancel
                | SensePasswordIpc::StatusQuery
        ) {
            return None;
        }
        if !self.calls.allow(pid, uid, now) {
            log::warn!("Sense Remote: password call refused (rate limit)");
            return refusal(&message, BUSY);
        }
        match message {
            SensePasswordIpc::StatusQuery => Some(SensePasswordIpc::Status(
                self.status(env).to_json(),
            )),
            SensePasswordIpc::Cancel => {
                self.pending.cancel();
                self.sets_for_nonce = 0;
                None
            }
            SensePasswordIpc::Begin => Some(SensePasswordIpc::Request(self.begin(now, env))),
            SensePasswordIpc::Set { grant, password } => {
                Some(self.set(&grant, &password, now, env))
            }
            _ => None,
        }
    }

    fn status<E: DaemonEnv>(&mut self, env: &mut E) -> AccessStatus {
        let record = env.read_record().unwrap_or_else(|err| {
            log::warn!("Sense Remote: access record not readable: {err}");
            None
        });
        let now = env.grant_context().now;
        status_from(record.as_ref(), env.has_permanent_password(), now)
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

    fn set<E: DaemonEnv>(
        &mut self,
        grant: &str,
        password: &SensePasswordSecret,
        now: Instant,
        env: &mut E,
    ) -> SensePasswordIpc {
        if let Err(code) = Self::incoming(env) {
            return set_result(code);
        }
        if !self.pending.is_pending(now) {
            return set_result(NO_PENDING);
        }
        self.sets_for_nonce += 1;
        if self.sets_for_nonce > MAX_SETS_PER_NONCE {
            log::warn!("Sense Remote: pending password unlock dropped (too many attempts)");
            self.pending.cancel();
            return set_result(NO_PENDING);
        }
        let ctx = env.grant_context();
        let first = !env.has_permanent_password();
        let payload = match check_for_set(grant, password, env.keys(), &ctx, &mut self.pending, now)
        {
            Ok(payload) => payload,
            Err(code) => {
                log::warn!("Sense Remote: permanent password not changed: {code}");
                return set_result(&code);
            }
        };
        // The nonce is used up from here on (single use), whatever the write does.
        let (storage, salt) = match env.write_password(password) {
            Ok(written) => written,
            Err(err) => {
                log::error!("Sense Remote: permanent password not written: {err}");
                return set_result(WRITE_FAILED);
            }
        };
        let ack = sign_ack(&PasswordAckPayload::for_grant(&payload, first, ctx.now), &env.secret_key())
            .ok()
            .and_then(|ack| serde_json::from_str(&ack).ok());
        if ack.is_none() {
            log::error!("Sense Remote: password ack not signed");
        }
        if let Err(err) = env.write_record(&AccessRecord::new(ctx.now, ack)) {
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
        let mut daemon = DAEMON
            .get_or_init(|| Mutex::new(Daemon::default()))
            .lock()
            .unwrap_or_else(|err| err.into_inner());
        return daemon.handle(message, peer_pid, peer_uid, Instant::now(), &mut root::RootEnv);
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
