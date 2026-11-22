//! Sense Remote (permanent password plan §3.7, U11): Windows, SYSTEM `--server` side of the main
//! IPC. `Begin` (role + rate limit → signed request), `Set` (§3.3 steps 7–12), `Cancel`,
//! `StatusQuery`.
//!
//! The UI is not trusted: it only carries the request to the panel and the grant back. The
//! nonce lives here and nowhere else, the grant is checked here against this computer's
//! identity and the panel keys built into this client, and only then is the password written.
//!
//! The main channel's handler also runs in other processes that listen on it (a user process
//! can take over the main IPC while the service restarts, `ipc::get_id`): this acts only in the
//! SYSTEM `--server` process and answers `None` everywhere else. The UI checks the other way
//! round that the pipe is SYSTEM-owned with a restricted DACL before it sends a password
//! (`ipc::connect_main_system`).
//!
//! `Service` is the pure state machine (tested on every platform); `on_ipc` is the Windows glue
//! (config, registry, time).

use super::{
    grant::{check_for_set, GrantContext, PasswordGrantPayload},
    pending::Pending,
    request::{incoming_role, sign_request, PasswordRequestPayload},
    SensePasswordIpc, SensePasswordSecret, UNSUPPORTED,
};
use crate::sense::{envelope_keys::TrustedKey, SenseRole};
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

/// At most one `Begin` per second and `BEGINS_PER_HOUR` per hour (plan §3.7, G4-4 pattern).
pub const BEGIN_MIN_INTERVAL: Duration = Duration::from_secs(1);
pub const BEGINS_PER_HOUR: usize = 6;
/// At most this many `Set` per pending nonce; then the nonce is dropped (a weak password does
/// not count against the grant check, so this bounds retries on its own).
pub const MAX_SETS_PER_NONCE: u32 = 10;
const HOUR: Duration = Duration::from_secs(3600);

/// Answer codes of this side (§3.7).
pub const NOT_INCOMING: &str = "not_incoming";
pub const RATE_LIMITED: &str = "rate_limited";
pub const BUSY: &str = "busy";
pub const NO_PENDING: &str = "no_pending";
pub const WRITE_FAILED: &str = "write_failed";

/// The panel's role name when the installed role takes incoming connections. A role that can
/// not be read is no role.
pub fn incoming(role: &Result<Option<SenseRole>, String>) -> Option<&'static str> {
    match role {
        Ok(Some(role)) => incoming_role(*role),
        _ => None,
    }
}

/// What this build is (`report::platform`, `report::app_version`); a local build without them
/// can not make a valid request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Build {
    pub platform: Option<&'static str>,
    pub app_version: Option<u32>,
}

/// The privileged state: the one pending nonce and the rate limits. In memory only.
#[derive(Debug, Default)]
pub struct Service {
    pending: Pending,
    begins: VecDeque<Instant>,
    sets: u32,
}

impl Service {
    /// `Begin`: a fresh nonce (replacing any pending one) and the request signed with the
    /// device key. `Err` is the answer code.
    pub fn begin(
        &mut self,
        role: &Result<Option<SenseRole>, String>,
        ctx: &GrantContext,
        build: Build,
        secret_key: &[u8],
        now: Instant,
    ) -> Result<String, String> {
        let role = incoming(role).ok_or(NOT_INCOMING)?;
        let (Some(platform), Some(app_version)) = (build.platform, build.app_version) else {
            return Err(UNSUPPORTED.to_owned());
        };
        self.count_begin(now)?;
        let nonce = self.pending.begin(now).ok_or(BUSY)?;
        self.sets = 0;
        let payload = PasswordRequestPayload::new(
            &ctx.rid,
            &ctx.duuid,
            &nonce,
            role,
            platform,
            app_version,
            ctx.now,
        );
        sign_request(&payload, secret_key).map_err(|_| {
            // No request left this process: the nonce is of no use.
            self.pending.cancel();
            UNSUPPORTED.to_owned()
        })
    }

    fn count_begin(&mut self, now: Instant) -> Result<(), String> {
        while self
            .begins
            .front()
            .is_some_and(|at| now.saturating_duration_since(*at) >= HOUR)
        {
            self.begins.pop_front();
        }
        let too_soon = self
            .begins
            .back()
            .is_some_and(|at| now.saturating_duration_since(*at) < BEGIN_MIN_INTERVAL);
        if too_soon || self.begins.len() >= BEGINS_PER_HOUR {
            return Err(RATE_LIMITED.to_owned());
        }
        self.begins.push_back(now);
        Ok(())
    }

    /// `Set`, steps 7–10 (role, grant, nonce, rule). `Ok` = the nonce is used up and the caller
    /// writes the password (step 11) and the ack (12). `Err` is the answer code.
    pub fn check_set(
        &mut self,
        role: &Result<Option<SenseRole>, String>,
        grant: &str,
        password: &SensePasswordSecret,
        keys: &[TrustedKey],
        ctx: &GrantContext,
        now: Instant,
    ) -> Result<PasswordGrantPayload, String> {
        if incoming(role).is_none() {
            return Err(NOT_INCOMING.to_owned());
        }
        if self.pending.is_pending(now) {
            self.sets += 1;
            if self.sets > MAX_SETS_PER_NONCE {
                self.cancel();
                return Err(NO_PENDING.to_owned());
            }
        }
        check_for_set(grant, password, keys, ctx, &mut self.pending, now)
    }

    pub fn cancel(&mut self) {
        self.pending.cancel();
        self.sets = 0;
    }
}

/// The ack of a written change (step 12), signed with the device key; `None` when it can not be
/// signed (the change stands, the panel then sees no `device.password.changed`).
pub fn sign_ack_for(
    grant: &PasswordGrantPayload,
    first: bool,
    checked_at: i64,
    secret_key: &[u8],
) -> Option<String> {
    let ack = super::ack::PasswordAckPayload::for_grant(grant, first, checked_at);
    super::ack::sign_ack(&ack, secret_key).ok()
}

#[cfg(windows)]
pub use service::{is_service_process, on_ipc};

#[cfg(not(windows))]
pub async fn on_ipc(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
    super::unsupported_answer(&message)
}

#[cfg(windows)]
mod service {
    use super::*;
    use crate::sense::password::status::AccessRecord;
    use hbb_common::{config::Config, log, tokio::sync::Mutex};

    lazy_static::lazy_static! {
        static ref SERVICE: Mutex<Service> = Mutex::new(Service::default());
    }

    /// The process that may write the permanent password: `--server` running as SYSTEM.
    pub fn is_service_process() -> bool {
        crate::is_server() && crate::platform::is_root()
    }

    fn context() -> GrantContext {
        GrantContext {
            iss: crate::sense::envelope::expected_issuer(),
            rid: Config::get_id(),
            duuid: crate::encode64(hbb_common::get_uuid()),
            now: hbb_common::get_time() / 1000,
        }
    }

    pub async fn on_ipc(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
        if !is_service_process() {
            return None;
        }
        if !crate::sense::password::SUPPORTED {
            return crate::sense::password::unsupported_answer(&message);
        }
        match message {
            SensePasswordIpc::Begin => Some(SensePasswordIpc::Request(begin())),
            SensePasswordIpc::Set { grant, password } => Some(SensePasswordIpc::SetResult {
                code: set(grant, password).await,
                storage: None,
                salt: None,
            }),
            SensePasswordIpc::Cancel => {
                SERVICE.lock().await.cancel();
                None
            }
            SensePasswordIpc::StatusQuery => Some(SensePasswordIpc::Status(
                crate::sense::password::status::current().to_json(),
            )),
            // Answers: a client must not send them.
            SensePasswordIpc::Request(_)
            | SensePasswordIpc::SetResult { .. }
            | SensePasswordIpc::Status(_) => None,
        }
    }

    fn begin() -> Result<String, String> {
        let Ok(mut service) = SERVICE.try_lock() else {
            return Err(BUSY.to_owned());
        };
        let (secret_key, _) = Config::get_key_pair();
        let build = Build {
            platform: crate::sense::report::platform(),
            app_version: crate::sense::report::app_version(),
        };
        let result = service.begin(
            &crate::sense::installed_role_state(),
            &context(),
            build,
            &secret_key,
            Instant::now(),
        );
        match &result {
            Ok(_) => log::info!("Sense Remote: permanent password unlock requested"),
            Err(code) => log::warn!("Sense Remote: permanent password unlock refused: {code}"),
        }
        result
    }

    async fn set(grant: String, password: SensePasswordSecret) -> String {
        // Held across the write: one change at a time.
        let Ok(mut service) = SERVICE.try_lock() else {
            return BUSY.to_owned();
        };
        let ctx = context();
        let payload = match service.check_set(
            &crate::sense::installed_role_state(),
            &grant,
            &password,
            crate::sense::envelope_keys::trusted_keys(),
            &ctx,
            Instant::now(),
        ) {
            Ok(payload) => payload,
            Err(code) => {
                // Only the code: never the grant, the nonce or the password.
                log::warn!("Sense Remote: permanent password not changed: {code}");
                return code;
            }
        };
        let first = !Config::has_permanent_password();
        // Step 11: the same call as the main IPC's `permanent-password` write (trusted-device
        // snapshot first).
        let affected = crate::trusted_devices::config::changes_password(password.expose());
        let secret = password.clone();
        let written = crate::trusted_devices::config::update_auth(affected, move || {
            crate::trusted_devices::config::set_password(secret.expose())
        })
        .await;
        match written {
            Ok(true) => {}
            Ok(false) => {
                log::error!("Sense Remote: permanent password write refused by the config");
                return WRITE_FAILED.to_owned();
            }
            Err(err) => {
                log::error!("Sense Remote: permanent password write failed: {err}");
                return WRITE_FAILED.to_owned();
            }
        }
        // Step 12: local record and the signed ack for the heartbeat.
        let (secret_key, _) = Config::get_key_pair();
        let ack = sign_ack_for(&payload, first, ctx.now, &secret_key);
        if ack.is_none() {
            log::error!("Sense Remote: permanent password ack could not be signed");
        }
        if let Err(err) = crate::sense::password::store_win::write(&AccessRecord::after_change(
            ctx.now, ack,
        )) {
            log::error!("Sense Remote: permanent password record not stored: {err}");
        }
        log::info!("Sense Remote: permanent password changed with a panel grant");
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::{
        envelope_keys::key_id,
        password::{
            ack::PasswordAckPayload,
            grant::open_signed,
            request::sign_canonical,
            PASSWORD_ACK_PREFIX, PASSWORD_GRANT_PREFIX, PASSWORD_REQUEST_PREFIX,
        },
    };
    use hbb_common::{
        base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
        sodiumoxide::crypto::sign,
    };
    use serde_json::Value;

    const RID: &str = "123456789";
    const DUUID: &str = "dGVzdC11dWlk";
    const ISS: &str = "remote.example.test";
    const NOW: i64 = 1_800_000_000;
    const PASSWORD: &str = "Mavi-Kapi_47!tuz";
    const BUILD: Build = Build {
        platform: Some("windows-x64"),
        app_version: Some(3),
    };

    struct Keys {
        device: (sign::PublicKey, sign::SecretKey),
        panel: (sign::PublicKey, sign::SecretKey),
    }

    impl Keys {
        fn new() -> Self {
            Self {
                device: sign::gen_keypair(),
                panel: sign::gen_keypair(),
            }
        }

        fn trusted(public_key: &sign::PublicKey) -> TrustedKey {
            TrustedKey {
                k: key_id(&public_key.0),
                public_key: public_key.0,
            }
        }

        fn panel_keys(&self) -> Vec<TrustedKey> {
            vec![Self::trusted(&self.panel.0)]
        }

        /// What the panel does: a grant for the request's nonce, signed with the panel key.
        fn grant_for(&self, nonce: &str) -> String {
            let payload = PasswordGrantPayload {
                v: 1,
                typ: "password_grant".to_owned(),
                iss: ISS.to_owned(),
                rid: RID.to_owned(),
                duuid: DUUID.to_owned(),
                nonce: nonce.to_owned(),
                gid: "pwg_VGVzdEdyYW50MDAwMDAx".to_owned(),
                iat: NOW,
                exp: NOW + 300,
            };
            sign_canonical(PASSWORD_GRANT_PREFIX, &payload, &self.panel.1 .0).unwrap()
        }

        /// What the panel checks on a device-signed blob: device key, prefix.
        fn open_device<T: serde::de::DeserializeOwned>(&self, blob: &str, prefix: &[u8]) -> T {
            let blob: Value = serde_json::from_str(blob).unwrap();
            let bytes = open_signed(&blob, &[Self::trusted(&self.device.0)], prefix).unwrap();
            serde_json::from_slice(&bytes).unwrap()
        }
    }

    fn ctx() -> GrantContext {
        GrantContext {
            iss: ISS.to_owned(),
            rid: RID.to_owned(),
            duuid: DUUID.to_owned(),
            now: NOW,
        }
    }

    fn host() -> Result<Option<SenseRole>, String> {
        Ok(Some(SenseRole::Host))
    }

    fn secret(value: &str) -> SensePasswordSecret {
        SensePasswordSecret::new(value.to_owned())
    }

    /// `Begin` and the nonce the panel would read from the request.
    fn begin(service: &mut Service, keys: &Keys, now: Instant) -> String {
        let request = service.begin(&host(), &ctx(), BUILD, &keys.device.1 .0, now).unwrap();
        let payload: PasswordRequestPayload = keys.open_device(&request, PASSWORD_REQUEST_PREFIX);
        assert_eq!(payload.rid, RID);
        assert_eq!(payload.duuid, DUUID);
        assert_eq!(payload.role, "host");
        assert_eq!(payload.platform, "windows-x64");
        assert_eq!(payload.app_version, 3);
        assert_eq!((payload.iat, payload.exp), (NOW, NOW + 600));
        payload.nonce
    }

    #[test]
    fn unlock_set_and_ack_end_to_end() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let nonce = begin(&mut service, &keys, now);
        let grant = keys.grant_for(&nonce);
        let payload = service
            .check_set(&host(), &grant, &secret(PASSWORD), &keys.panel_keys(), &ctx(), now)
            .unwrap();
        assert_eq!(payload.nonce, nonce);
        // The ack the heartbeat carries: device-signed, the panel's checks pass.
        let ack = sign_ack_for(&payload, true, NOW, &keys.device.1 .0).unwrap();
        let ack: PasswordAckPayload = keys.open_device(&ack, PASSWORD_ACK_PREFIX);
        assert_eq!(ack, PasswordAckPayload::for_grant(&payload, true, NOW));
        assert!(ack.first);
        // Single use: the same grant again finds no pending nonce.
        assert_eq!(
            service.check_set(&host(), &grant, &secret(PASSWORD), &keys.panel_keys(), &ctx(), now),
            Err("no_pending".to_owned())
        );
    }

    #[test]
    fn controller_and_unreadable_role_are_not_incoming() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        for role in [
            Ok(Some(SenseRole::Controller)),
            Ok(None),
            Err("registry value not readable".to_owned()),
        ] {
            assert_eq!(
                service.begin(&role, &ctx(), BUILD, &keys.device.1 .0, now),
                Err("not_incoming".to_owned())
            );
            assert_eq!(
                service.check_set(&role, "{}", &secret(PASSWORD), &[], &ctx(), now),
                Err("not_incoming".to_owned())
            );
        }
        // Host + Controller takes incoming connections.
        let both = Ok(Some(SenseRole::Both));
        let request = service.begin(&both, &ctx(), BUILD, &keys.device.1 .0, now).unwrap();
        let payload: PasswordRequestPayload = keys.open_device(&request, PASSWORD_REQUEST_PREFIX);
        assert_eq!(payload.role, "host_controller");
    }

    #[test]
    fn grant_from_another_key_device_or_nonce_is_refused() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let nonce = begin(&mut service, &keys, now);
        let set = |service: &mut Service, grant: &str, ctx: &GrantContext| {
            service.check_set(&host(), grant, &secret(PASSWORD), &keys.panel_keys(), ctx, now)
        };
        // Signed by the device key (an attacker with the user's copy of it), not the panel.
        let forged = sign_canonical(
            PASSWORD_GRANT_PREFIX,
            &serde_json::from_slice::<PasswordGrantPayload>(
                &URL_SAFE_NO_PAD
                    .decode(
                        serde_json::from_str::<Value>(&keys.grant_for(&nonce)).unwrap()["p"]
                            .as_str()
                            .unwrap(),
                    )
                    .unwrap(),
            )
            .unwrap(),
            &keys.device.1 .0,
        )
        .unwrap();
        assert_eq!(set(&mut service, &forged, &ctx()), Err("grant_invalid:unknown_key".to_owned()));
        // Another computer.
        let mut other = ctx();
        other.rid = "987654321".to_owned();
        assert_eq!(
            set(&mut service, &keys.grant_for(&nonce), &other),
            Err("grant_invalid:wrong_device".to_owned())
        );
        // Another nonce (an old request).
        assert_eq!(
            set(&mut service, &keys.grant_for("b3RoZXItdGVzdC1ub25jZQ"), &ctx()),
            Err("nonce_mismatch".to_owned())
        );
        // Still pending after three failures: the right grant goes through.
        assert!(set(&mut service, &keys.grant_for(&nonce), &ctx()).is_ok());
    }

    #[test]
    fn weak_password_keeps_the_grant() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let nonce = begin(&mut service, &keys, now);
        let grant = keys.grant_for(&nonce);
        let keys_list = keys.panel_keys();
        assert_eq!(
            service.check_set(&host(), &grant, &secret("short"), &keys_list, &ctx(), now),
            Err("weak_password:length".to_owned())
        );
        assert!(service
            .check_set(&host(), &grant, &secret(PASSWORD), &keys_list, &ctx(), now)
            .is_ok());
    }

    #[test]
    fn sets_per_nonce_are_bounded() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let nonce = begin(&mut service, &keys, now);
        let grant = keys.grant_for(&nonce);
        let keys_list = keys.panel_keys();
        for _ in 0..MAX_SETS_PER_NONCE {
            assert_eq!(
                service.check_set(&host(), &grant, &secret("short"), &keys_list, &ctx(), now),
                Err("weak_password:length".to_owned())
            );
        }
        assert_eq!(
            service.check_set(&host(), &grant, &secret(PASSWORD), &keys_list, &ctx(), now),
            Err("no_pending".to_owned())
        );
        // A new `Begin` starts a new count.
        let nonce = begin(&mut service, &keys, now + Duration::from_secs(2));
        assert!(service
            .check_set(&host(), &keys.grant_for(&nonce), &secret(PASSWORD), &keys_list, &ctx(), now)
            .is_ok());
    }

    #[test]
    fn begin_is_rate_limited() {
        let keys = Keys::new();
        let mut service = Service::default();
        let start = Instant::now();
        let begin_at = |service: &mut Service, at: Instant| {
            service.begin(&host(), &ctx(), BUILD, &keys.device.1 .0, at)
        };
        assert!(begin_at(&mut service, start).is_ok());
        // Twice within a second.
        assert_eq!(
            begin_at(&mut service, start + Duration::from_millis(500)),
            Err("rate_limited".to_owned())
        );
        for i in 1..BEGINS_PER_HOUR as u64 {
            assert!(begin_at(&mut service, start + Duration::from_secs(i * 60)).is_ok());
        }
        // The seventh within the hour.
        assert_eq!(
            begin_at(&mut service, start + Duration::from_secs(59 * 60)),
            Err("rate_limited".to_owned())
        );
        // An hour after the first, one more.
        assert!(begin_at(&mut service, start + HOUR).is_ok());
    }

    #[test]
    fn cancel_and_a_new_begin_drop_the_old_nonce() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let first = begin(&mut service, &keys, now);
        let second = begin(&mut service, &keys, now + Duration::from_secs(2));
        assert_ne!(first, second);
        let keys_list = keys.panel_keys();
        assert_eq!(
            service.check_set(&host(), &keys.grant_for(&first), &secret(PASSWORD), &keys_list, &ctx(), now),
            Err("nonce_mismatch".to_owned())
        );
        service.cancel();
        assert_eq!(
            service.check_set(&host(), &keys.grant_for(&second), &secret(PASSWORD), &keys_list, &ctx(), now),
            Err("no_pending".to_owned())
        );
    }

    #[test]
    fn no_request_without_build_version_or_key() {
        let keys = Keys::new();
        let mut service = Service::default();
        let now = Instant::now();
        let local = Build {
            platform: Some("windows-x64"),
            app_version: None,
        };
        assert_eq!(
            service.begin(&host(), &ctx(), local, &keys.device.1 .0, now),
            Err("unsupported".to_owned())
        );
        assert_eq!(
            service.begin(&host(), &ctx(), BUILD, &[0u8; 10], now),
            Err("unsupported".to_owned())
        );
        // The nonce of the failed signature is not left pending.
        assert_eq!(
            service.check_set(&host(), &keys.grant_for("c2Vuc2UtdGVzdC1ub25jZQ"), &secret(PASSWORD), &keys.panel_keys(), &ctx(), now),
            Err("no_pending".to_owned())
        );
    }

    #[test]
    fn nothing_secret_in_debug_output() {
        let keys = Keys::new();
        let mut service = Service::default();
        let nonce = begin(&mut service, &keys, Instant::now());
        let text = format!("{service:?}");
        assert!(!text.contains(&nonce), "{text}");
    }

    #[test]
    fn off_windows_requests_stay_unsupported() {
        #[cfg(not(windows))]
        {
            let reply = hbb_common::tokio::runtime::Builder::new_current_thread()
                .build()
                .unwrap()
                .block_on(on_ipc(SensePasswordIpc::Begin));
            assert_eq!(reply, Some(SensePasswordIpc::Request(Err("unsupported".to_owned()))));
        }
    }
}
