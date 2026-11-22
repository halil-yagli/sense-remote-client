//! Sense Remote (U12): the daemon's decisions over a fake root (`FakeRoot`), the limits and the
//! user `--server`'s handling of the daemon's answers. Every platform.

use super::*;
use crate::sense::password::PASSWORD_ACK_REPORT_S;
use crate::sense::{envelope_keys::key_id, password::grant::PasswordGrantPayload};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::crypto::sign,
};
use serde_json::Value;

const ISS: &str = "remote.example.test";
const RID: &str = "123456789";
const DUUID: &str = "dGVzdC11dWlk";
const NOW_S: i64 = 1_800_000_000;
const GID: &str = "pwg_VGVzdEdyYW50MDAwMDAx";
const GOOD: &str = "Mavi-Kapi_47!tuz";

/// The daemon's surroundings in memory. `password` is what a real root would hash and store.
struct FakeRoot {
    role: Result<Option<SenseRole>, String>,
    panel: Vec<TrustedKey>,
    device_pk: sign::PublicKey,
    device_sk: sign::SecretKey,
    password: Option<String>,
    password_writes: u32,
    write_fails: bool,
    record: Option<AccessRecord>,
    record_writes: u32,
}

impl FakeRoot {
    fn new(role: Option<SenseRole>, panel_pk: &sign::PublicKey) -> Self {
        let (device_pk, device_sk) = sign::gen_keypair();
        Self {
            role: Ok(role),
            panel: vec![TrustedKey {
                k: key_id(&panel_pk.0),
                public_key: panel_pk.0,
            }],
            device_pk,
            device_sk,
            password: None,
            password_writes: 0,
            write_fails: false,
            record: None,
            record_writes: 0,
        }
    }

    /// Nothing at all changed in the root.
    fn untouched(&self) -> bool {
        self.password.is_none()
            && self.password_writes == 0
            && self.record.is_none()
            && self.record_writes == 0
    }
}

impl DaemonEnv for FakeRoot {
    fn role(&mut self) -> Result<Option<SenseRole>, String> {
        self.role.clone()
    }
    fn grant_context(&mut self) -> GrantContext {
        GrantContext {
            iss: ISS.to_owned(),
            rid: RID.to_owned(),
            duuid: DUUID.to_owned(),
            now: NOW_S,
        }
    }
    fn keys(&self) -> &[TrustedKey] {
        &self.panel
    }
    fn build(&self) -> Option<(&'static str, u32)> {
        Some(("macos-arm64", 3))
    }
    fn secret_key(&mut self) -> Vec<u8> {
        self.device_sk.0.to_vec()
    }
    fn has_permanent_password(&mut self) -> bool {
        self.password.is_some()
    }
    fn write_password(
        &mut self,
        password: &SensePasswordSecret,
    ) -> Result<(SensePasswordSecret, String), String> {
        self.password_writes += 1;
        if self.write_fails {
            return Err("disk".to_owned());
        }
        self.password = Some(password.expose().to_owned());
        Ok((SensePasswordSecret::new(format!("00HASH-{}", self.password_writes)), "tuz".to_owned()))
    }
    fn read_record(&mut self) -> Result<Option<AccessRecord>, String> {
        Ok(self.record.clone())
    }
    fn write_record(&mut self, record: &AccessRecord) -> Result<(), String> {
        self.record_writes += 1;
        self.record = Some(record.clone());
        Ok(())
    }
}

/// A daemon with its own monotonic clock: every call is one second after the last, so the
/// per-second limit stays out of the way unless a test wants it.
struct Harness {
    daemon: Daemon,
    root: FakeRoot,
    panel_sk: sign::SecretKey,
    t: Instant,
    pid: u32,
}

impl Harness {
    fn new(role: Option<SenseRole>) -> Self {
        let (panel_pk, panel_sk) = sign::gen_keypair();
        Self {
            daemon: Daemon::default(),
            root: FakeRoot::new(role, &panel_pk),
            panel_sk,
            t: Instant::now(),
            pid: 4242,
        }
    }

    fn call(&mut self, message: SensePasswordIpc) -> Option<SensePasswordIpc> {
        self.t += Duration::from_secs(1);
        self.daemon
            .handle(message, Some(self.pid), Some(501), self.t, &mut self.root)
    }

    /// `Begin` → the nonce of the signed request.
    fn begin(&mut self) -> String {
        let Some(SensePasswordIpc::Request(Ok(request))) = self.call(SensePasswordIpc::Begin) else {
            panic!("no request");
        };
        let payload = open(&request, PASSWORD_REQUEST_PREFIX_FOR_TEST, &self.root.device_pk);
        payload["nonce"].as_str().unwrap().to_owned()
    }

    fn set(&mut self, grant: &str, password: &str) -> SensePasswordIpc {
        self.call(SensePasswordIpc::Set {
            grant: grant.to_owned(),
            password: SensePasswordSecret::new(password.to_owned()),
        })
        .unwrap()
    }

    fn grant(&self, nonce: &str) -> String {
        self.grant_with(nonce, RID, &self.panel_sk)
    }

    fn grant_with(&self, nonce: &str, rid: &str, key: &sign::SecretKey) -> String {
        let payload = PasswordGrantPayload {
            v: 1,
            typ: "password_grant".to_owned(),
            iss: ISS.to_owned(),
            rid: rid.to_owned(),
            duuid: DUUID.to_owned(),
            nonce: nonce.to_owned(),
            gid: GID.to_owned(),
            iat: NOW_S,
            exp: NOW_S + 300,
        };
        crate::sense::password::request::sign_canonical(
            crate::sense::password::PASSWORD_GRANT_PREFIX,
            &payload,
            &key.0,
        )
        .unwrap()
    }
}

const PASSWORD_REQUEST_PREFIX_FOR_TEST: &[u8] = crate::sense::password::PASSWORD_REQUEST_PREFIX;

/// Checks the device signature under `prefix` and returns the payload.
fn open(signed: &str, prefix: &[u8], pk: &sign::PublicKey) -> Value {
    let blob: Value = serde_json::from_str(signed).unwrap();
    assert_eq!(blob["k"], key_id(&pk.0));
    let p = URL_SAFE_NO_PAD.decode(blob["p"].as_str().unwrap()).unwrap();
    let s = URL_SAFE_NO_PAD.decode(blob["s"].as_str().unwrap()).unwrap();
    let mut data = prefix.to_vec();
    data.extend_from_slice(&p);
    let signature = sign::Signature::from_bytes(&s).ok().unwrap();
    assert!(sign::verify_detached(&signature, &data, pk), "bad signature");
    serde_json::from_slice(&p).unwrap()
}

fn code(reply: &SensePasswordIpc) -> &str {
    match reply {
        SensePasswordIpc::SetResult { code, .. } => code,
        other => panic!("not a SetResult: {other:?}"),
    }
}

fn status(h: &mut Harness) -> AccessStatus {
    let Some(SensePasswordIpc::Status(json)) = h.call(SensePasswordIpc::StatusQuery) else {
        panic!("no status");
    };
    serde_json::from_str(&json).unwrap()
}

#[test]
fn unlock_and_set_writes_root_once_with_a_signed_ack() {
    let mut h = Harness::new(Some(SenseRole::Host));
    assert_eq!(status(&mut h), AccessStatus::default());

    // The request is the daemon's own: its nonce, root identity, signed with the device key.
    let Some(SensePasswordIpc::Request(Ok(request))) = h.call(SensePasswordIpc::Begin) else {
        panic!("no request");
    };
    let payload = open(&request, PASSWORD_REQUEST_PREFIX_FOR_TEST, &h.root.device_pk);
    assert_eq!(payload["rid"], RID);
    assert_eq!(payload["duuid"], DUUID);
    assert_eq!(payload["role"], "host");
    assert_eq!(payload["platform"], "macos-arm64");
    assert_eq!(payload["exp"].as_i64().unwrap() - payload["iat"].as_i64().unwrap(), 600);
    let nonce = payload["nonce"].as_str().unwrap().to_owned();

    let grant = h.grant(&nonce);
    let reply = h.set(&grant, GOOD);
    let SensePasswordIpc::SetResult { code, storage, salt } = &reply else {
        panic!("{reply:?}");
    };
    assert_eq!(code, "");
    assert_eq!(storage.as_ref().unwrap().expose(), "00HASH-1");
    assert_eq!(salt.as_deref(), Some("tuz"));
    assert_eq!(h.root.password.as_deref(), Some(GOOD));

    // The record carries the ack, signed by the device key under the ack prefix.
    let record = h.root.record.clone().unwrap();
    assert_eq!(record.changed_at, NOW_S);
    let ack = open(
        record.ack.as_deref().unwrap(),
        crate::sense::password::PASSWORD_ACK_PREFIX,
        &h.root.device_pk,
    );
    assert_eq!(ack["gid"], GID);
    assert_eq!(ack["first"], true);
    assert_eq!(ack["rid"], RID);

    let now = status(&mut h);
    assert!(now.perm_set);
    assert_eq!(now.changed_at, Some(NOW_S));
    assert_eq!(now.ack, serde_json::from_str::<Value>(record.ack.as_deref().unwrap()).ok());

    // Single use: the same grant again changes nothing.
    assert_eq!(code_of(h.set(&grant, "Baska-Kapi_58?tuz")), "no_pending");
    assert_eq!(h.root.password_writes, 1);
    assert_eq!(h.root.password.as_deref(), Some(GOOD));

    // A second change is not the first one any more.
    let nonce = h.begin();
    let grant = h.grant(&nonce);
    assert_eq!(code_of(h.set(&grant, "Baska-Kapi_58?tuz")), "");
    let ack = open(
        &h.root.record.clone().unwrap().ack.unwrap(),
        crate::sense::password::PASSWORD_ACK_PREFIX,
        &h.root.device_pk,
    );
    assert_eq!(ack["first"], false);
}

fn code_of(reply: SensePasswordIpc) -> String {
    code(&reply).to_owned()
}

#[test]
fn a_forged_or_foreign_grant_changes_nothing_in_root() {
    let mut h = Harness::new(Some(SenseRole::Both));
    // No pending nonce yet: even a perfectly signed grant is refused.
    let early = h.grant("c2Vuc2UtdGVzdC1ub25jZQ");
    assert_eq!(code_of(h.set(&early, GOOD)), "no_pending");

    let nonce = h.begin();
    let (_, intruder_sk) = sign::gen_keypair();
    let cases = [
        ("not json".to_owned(), "grant_invalid:malformed"),
        ("{}".to_owned(), "grant_invalid:malformed"),
        (h.grant_with(&nonce, RID, &intruder_sk), "grant_invalid:unknown_key"),
        (h.grant_with(&nonce, "987654321", &h.panel_sk), "grant_invalid:wrong_device"),
        (h.grant("b3RoZXItdGVzdC1ub25jZQ"), "nonce_mismatch"),
    ];
    for (grant, expected) in &cases[..4] {
        assert_eq!(code_of(h.set(grant, GOOD)), *expected);
    }
    // The fifth failed check drops the nonce.
    assert_eq!(code_of(h.set(&cases[4].0, GOOD)), cases[4].1);
    assert_eq!(code_of(h.set(&h.grant(&nonce), GOOD)), "no_pending");
    assert!(h.root.untouched(), "root changed");
}

#[test]
fn weak_password_keeps_the_grant_and_ten_sets_drop_the_nonce() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let nonce = h.begin();
    let grant = h.grant(&nonce);
    assert_eq!(code_of(h.set(&grant, "aaaaaaaaaaaa")), "weak_password:repeated");
    assert_eq!(code_of(h.set(&grant, &format!("Mavi{RID}Kapi!"))), "weak_password:contains_id");
    assert!(h.root.untouched());
    assert_eq!(code_of(h.set(&grant, GOOD)), "");

    // Ten attempts per nonce, then it is gone.
    let nonce = h.begin();
    let grant = h.grant(&nonce);
    for _ in 0..MAX_SETS_PER_NONCE {
        assert_eq!(code_of(h.set(&grant, "kisa")), "weak_password:length");
    }
    assert_eq!(code_of(h.set(&grant, GOOD)), "no_pending");
    assert_eq!(h.root.password_writes, 1);
}

#[test]
fn a_failed_write_burns_the_nonce_and_stores_no_record() {
    let mut h = Harness::new(Some(SenseRole::Host));
    h.root.write_fails = true;
    let nonce = h.begin();
    let grant = h.grant(&nonce);
    assert_eq!(code_of(h.set(&grant, GOOD)), "write_failed");
    assert!(h.root.record.is_none());
    assert_eq!(code_of(h.set(&grant, GOOD)), "no_pending");
}

#[test]
fn only_incoming_roles_unlock() {
    for role in [None, Some(SenseRole::Controller)] {
        let mut h = Harness::new(role);
        assert_eq!(
            h.call(SensePasswordIpc::Begin),
            Some(SensePasswordIpc::Request(Err("not_incoming".to_owned())))
        );
        let grant = h.grant("c2Vuc2UtdGVzdC1ub25jZQ");
        assert_eq!(code_of(h.set(&grant, GOOD)), "not_incoming");
        assert!(h.root.untouched());
    }
    let mut h = Harness::new(Some(SenseRole::Host));
    h.root.role = Err("dir-is-symlink".to_owned());
    assert_eq!(
        h.call(SensePasswordIpc::Begin),
        Some(SensePasswordIpc::Request(Err("unsupported".to_owned())))
    );
    // The role changed away from Host after the unlock: the set is refused.
    let mut h = Harness::new(Some(SenseRole::Both));
    let nonce = h.begin();
    h.root.role = Ok(Some(SenseRole::Controller));
    assert_eq!(code_of(h.set(&h.grant(&nonce), GOOD)), "not_incoming");
    assert!(h.root.untouched());
}

#[test]
fn answer_kinds_from_a_client_are_ignored() {
    let mut h = Harness::new(Some(SenseRole::Host));
    for message in [
        SensePasswordIpc::Request(Ok("{}".to_owned())),
        SensePasswordIpc::SetResult {
            code: String::new(),
            storage: Some(SensePasswordSecret::new("00HASH".to_owned())),
            salt: Some("tuz".to_owned()),
        },
        SensePasswordIpc::Status("{}".to_owned()),
    ] {
        assert_eq!(h.call(message), None);
    }
    assert!(h.root.untouched());
}

#[test]
fn cancel_drops_the_pending_nonce() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let nonce = h.begin();
    assert_eq!(h.call(SensePasswordIpc::Cancel), None);
    assert_eq!(code_of(h.set(&h.grant(&nonce), GOOD)), "no_pending");
}

#[test]
fn call_limiter_counts_processes_uids_and_everyone() {
    let t = Instant::now();
    let mut limiter = CallLimiter::default();
    assert!(limiter.allow(Some(1), Some(501), t));
    // Same process again within the second.
    assert!(!limiter.allow(Some(1), Some(501), t));
    // New processes of the same uid: three in all, then busy.
    assert!(limiter.allow(Some(2), Some(501), t));
    assert!(limiter.allow(Some(3), Some(501), t));
    assert!(!limiter.allow(Some(4), Some(501), t));
    // Unknown pid/uid share one slot.
    assert!(limiter.allow(None, None, t));
    assert!(!limiter.allow(None, None, t));
    // Everyone together: at most `MAX_CALLS_PER_SECOND`.
    let mut limiter = CallLimiter::default();
    let allowed = (0..20u32)
        .filter(|i| limiter.allow(Some(100 + i), Some(600 + i), t))
        .count();
    assert_eq!(allowed, MAX_CALLS_PER_SECOND as usize);
    // The next second starts fresh.
    assert!(limiter.allow(Some(100), Some(600), t + CALL_WINDOW));
}

#[test]
fn begin_limit_is_per_daemon_not_per_process() {
    let mut h = Harness::new(Some(SenseRole::Host));
    for i in 0..MAX_BEGINS_PER_HOUR {
        h.pid = 1000 + i as u32; // a fresh process each time
        assert!(matches!(h.call(SensePasswordIpc::Begin), Some(SensePasswordIpc::Request(Ok(_)))));
    }
    h.pid = 9999;
    assert_eq!(
        h.call(SensePasswordIpc::Begin),
        Some(SensePasswordIpc::Request(Err("rate_limited".to_owned())))
    );
    // An hour after the first one, one more.
    h.t += BEGIN_WINDOW;
    assert!(matches!(h.call(SensePasswordIpc::Begin), Some(SensePasswordIpc::Request(Ok(_)))));
}

#[test]
fn calls_over_the_second_limit_are_busy() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let t = h.t;
    let begin = |h: &mut Harness| {
        h.daemon
            .handle(SensePasswordIpc::Begin, Some(7), Some(501), t, &mut h.root)
    };
    assert!(matches!(begin(&mut h), Some(SensePasswordIpc::Request(Ok(_)))));
    assert_eq!(begin(&mut h), Some(SensePasswordIpc::Request(Err("busy".to_owned()))));
    let set = h.daemon.handle(
        SensePasswordIpc::Set {
            grant: "{}".to_owned(),
            password: SensePasswordSecret::new(GOOD.to_owned()),
        },
        Some(7),
        Some(501),
        t,
        &mut h.root,
    );
    assert_eq!(code_of(set.unwrap()), "busy");
    assert!(h.root.untouched());
}

/// U12 review M2: a status poll or a cancel in the same second does not make the next
/// `Begin`/`Set` of that process `busy` (separate buckets).
#[test]
fn status_and_cancel_do_not_starve_begin_and_set() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let t = h.t;
    let at_once = |h: &mut Harness, message: SensePasswordIpc| {
        h.daemon.handle(message, Some(7), Some(501), t, &mut h.root)
    };
    // Status, then Begin, in the same second from the same process: both pass.
    assert!(matches!(
        at_once(&mut h, SensePasswordIpc::StatusQuery),
        Some(SensePasswordIpc::Status(_))
    ));
    let Some(SensePasswordIpc::Request(Ok(request))) = at_once(&mut h, SensePasswordIpc::Begin)
    else {
        panic!("begin was busy");
    };
    // The query bucket is spent for this second (a second status is busy: no answer) ...
    assert_eq!(at_once(&mut h, SensePasswordIpc::StatusQuery), None);
    // ... but a cancel from the same process still gets in next second, and so does the next
    // Begin of the change bucket.
    let payload = open(&request, PASSWORD_REQUEST_PREFIX_FOR_TEST, &h.root.device_pk);
    assert!(payload["nonce"].is_string());
    let next = t + Duration::from_secs(1);
    assert_eq!(
        h.daemon
            .handle(SensePasswordIpc::Cancel, Some(7), Some(501), next, &mut h.root),
        None
    );
    assert!(matches!(
        h.daemon
            .handle(SensePasswordIpc::Begin, Some(7), Some(501), next, &mut h.root),
        Some(SensePasswordIpc::Request(Ok(_)))
    ));
}

/// U12 review M5: the daemon decides under its lock and hands the write out; a refused grant
/// never becomes a write.
#[test]
fn decide_hands_the_write_out_of_the_lock() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let nonce = h.begin();
    let grant = h.grant(&nonce);
    h.t += Duration::from_secs(1);
    let decision = h.daemon.decide(
        SensePasswordIpc::Set {
            grant: grant.clone(),
            password: SensePasswordSecret::new(GOOD.to_owned()),
        },
        Some(h.pid),
        Some(501),
        h.t,
        &mut h.root,
    );
    let Decision::Write(work) = decision else {
        panic!("no write: {decision:?}");
    };
    // Nothing written while deciding; the nonce is already used up.
    assert!(h.root.untouched());
    assert!(!format!("{work:?}").contains(GOOD));
    assert_eq!(code_of(h.set(&grant, GOOD)), "no_pending");
    assert_eq!(code_of(work.run(&mut h.root)), "");
    assert_eq!(h.root.password.as_deref(), Some(GOOD));
    h.t += Duration::from_secs(1);
    let refused = h.daemon.decide(
        SensePasswordIpc::Set {
            grant,
            password: SensePasswordSecret::new(GOOD.to_owned()),
        },
        Some(h.pid),
        Some(501),
        h.t,
        &mut h.root,
    );
    assert!(matches!(refused, Decision::Reply(Some(_))));
}

#[test]
fn status_uses_the_shared_window() {
    let ack = r#"{"k":"a","p":"b","s":"c"}"#.to_owned();
    let record = AccessRecord::after_change(NOW_S, Some(ack));
    let at = |now| status_from(true, Some(&record), now);
    let value = serde_json::json!({"k": "a", "p": "b", "s": "c"});
    assert_eq!(at(NOW_S).ack, Some(value.clone()));
    assert_eq!(at(NOW_S + PASSWORD_ACK_REPORT_S - 1).ack, Some(value));
    assert_eq!(at(NOW_S + PASSWORD_ACK_REPORT_S).ack, None);
    assert_eq!(at(NOW_S - 3600).ack, None);
    assert_eq!(at(NOW_S + PASSWORD_ACK_REPORT_S + 1).changed_at, Some(NOW_S));
    assert_eq!(status_from(false, None, NOW_S), AccessStatus::default());
}

#[test]
fn user_server_takes_the_storage_and_gives_the_ui_only_the_code() {
    let ok = SensePasswordIpc::SetResult {
        code: String::new(),
        storage: Some(SensePasswordSecret::new("00HASH-1".to_owned())),
        salt: Some("tuz".to_owned()),
    };
    let mut taken = None;
    let reply = take_set_result(ok, |storage, salt| {
        taken = Some((storage.to_owned(), salt.to_owned()));
        Ok(())
    });
    // The user process now holds exactly what root stored.
    assert_eq!(taken, Some(("00HASH-1".to_owned(), "tuz".to_owned())));
    assert_eq!(reply, set_result(""));

    // A refusal never touches the user process's config.
    let refused = SensePasswordIpc::SetResult {
        code: "nonce_mismatch".to_owned(),
        storage: Some(SensePasswordSecret::new("00HASH-1".to_owned())),
        salt: Some("tuz".to_owned()),
    };
    let reply = take_set_result(refused, |_, _| panic!("stored on a refusal"));
    assert_eq!(reply, set_result("nonce_mismatch"));
    // A failing take-over still reports the change root made.
    assert_eq!(
        take_set_result(
            SensePasswordIpc::SetResult {
                code: String::new(),
                storage: Some(SensePasswordSecret::new("x".to_owned())),
                salt: Some("y".to_owned()),
            },
            |_, _| Err("bad".to_owned())
        ),
        set_result("")
    );
    assert_eq!(
        take_set_result(SensePasswordIpc::Status("{}".to_owned()), |_, _| panic!()),
        set_result("ipc_failed")
    );
}

#[test]
fn only_a_fitting_daemon_answer_is_passed_on() {
    let set = SensePasswordIpc::Set {
        grant: "g".to_owned(),
        password: SensePasswordSecret::new("p".to_owned()),
    };
    let request = SensePasswordIpc::Request(Ok("{}".to_owned()));
    let result = set_result("");
    let status = SensePasswordIpc::Status("{}".to_owned());
    assert!(fitting_reply(&SensePasswordIpc::Begin, request.clone()).is_some());
    assert!(fitting_reply(&SensePasswordIpc::Begin, result.clone()).is_none());
    assert!(fitting_reply(&set, result.clone()).is_some());
    assert!(fitting_reply(&set, status.clone()).is_none());
    assert!(fitting_reply(&SensePasswordIpc::StatusQuery, status).is_some());
    assert!(fitting_reply(&SensePasswordIpc::Cancel, result).is_none());
    assert_eq!(no_daemon(&set), Some(set_result("ipc_failed")));
    assert_eq!(
        no_daemon(&SensePasswordIpc::Begin),
        Some(SensePasswordIpc::Request(Err("ipc_failed".to_owned())))
    );
}

/// Only the macOS daemon acts (Linux has a `_service` channel too); on macOS only once U14
/// turns the feature on.
#[test]
fn elsewhere_or_while_off_the_service_answers_unsupported() {
    if cfg!(target_os = "macos") && crate::sense::password::SUPPORTED {
        return;
    }
    assert_eq!(
        on_service_ipc(SensePasswordIpc::Begin, Some(1), Some(0)),
        Some(SensePasswordIpc::Request(Err("unsupported".to_owned())))
    );
    if !crate::sense::password::SUPPORTED {
        assert_eq!(heartbeat_ext(), None);
    }
}

#[test]
fn the_daemon_state_shows_no_nonce() {
    let mut h = Harness::new(Some(SenseRole::Host));
    let nonce = h.begin();
    let text = format!("{:?}", h.daemon);
    assert!(!text.contains(&nonce), "{text}");
}
