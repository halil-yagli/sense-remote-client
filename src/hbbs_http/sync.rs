use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

#[cfg(not(any(target_os = "ios")))]
use crate::{common::API_LOG_INTERVAL, ui_interface::get_builtin_option, Connection};
use hbb_common::{
    config::{self, Config, LocalConfig},
    log,
    tokio::{self, sync::broadcast, time::Instant},
};
use base::config::keys;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const TIME_HEARTBEAT: Duration = Duration::from_secs(15);
const UPLOAD_SYSINFO_TIMEOUT: Duration = Duration::from_secs(120);
const TIME_CONN: Duration = Duration::from_secs(3);

#[cfg(not(any(target_os = "ios")))]
lazy_static::lazy_static! {
    static ref SENDER : Mutex<broadcast::Sender<Vec<i32>>> = Mutex::new(start_hbbs_sync());
    static ref PRO: Arc<Mutex<bool>> = Default::default();
}

#[cfg(not(any(target_os = "ios")))]
pub fn start() {
    let _sender = SENDER.lock().unwrap();
}

#[cfg(not(target_os = "ios"))]
pub fn signal_receiver() -> broadcast::Receiver<Vec<i32>> {
    SENDER.lock().unwrap().subscribe()
}

#[cfg(not(any(target_os = "ios")))]
fn start_hbbs_sync() -> broadcast::Sender<Vec<i32>> {
    let (tx, _rx) = broadcast::channel::<Vec<i32>>(16);
    std::thread::spawn(move || start_hbbs_sync_async());
    return tx;
}

#[derive(Debug, Serialize, Deserialize)]
pub struct StrategyOptions {
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub config_options: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub extra: HashMap<String, String>,
}

struct InfoUploaded {
    uploaded: bool,
    url: String,
    last_uploaded: Option<Instant>,
    id: String,
    username: Option<String>,
}

impl Default for InfoUploaded {
    fn default() -> Self {
        Self {
            uploaded: false,
            url: "".to_owned(),
            last_uploaded: None,
            id: "".to_owned(),
            username: None,
        }
    }
}

impl InfoUploaded {
    fn uploaded(url: String, id: String, username: String) -> Self {
        Self {
            uploaded: true,
            url,
            last_uploaded: None,
            id,
            username: Some(username),
        }
    }
}

#[cfg(not(any(target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
async fn start_hbbs_sync_async() {
    let mut interval = crate::rustdesk_interval(tokio::time::interval_at(
        Instant::now() + TIME_CONN,
        TIME_CONN,
    ));
    let mut last_sent: Option<Instant> = None;
    let mut info_uploaded = InfoUploaded::default();
    let mut sysinfo_ver = "".to_owned();
    // Sense Remote: envelope state reported in every heartbeat (`sense.envelope_error`, ...).
    let mut sense_report = crate::sense::envelope_apply::Report::default();
    // Sense Remote (wave 3, K-R2-3): `ts` of the last signed report, kept strictly increasing.
    let mut sense_report_ts: Option<i64> = None;
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let url = heartbeat_url();
                let id = Config::get_id();
                if url.is_empty() {
                    *PRO.lock().unwrap() = false;
                    continue;
                }
                if config::option2bool("stop-service", &Config::get_option("stop-service")) {
                    continue;
                }
                let conns = Connection::alive_conns();
                if info_uploaded.uploaded && (url != info_uploaded.url || id != info_uploaded.id) {
                    info_uploaded.uploaded = false;
                    *PRO.lock().unwrap() = false;
                }
                // For Windows:
                // We can't skip uploading sysinfo when the username is empty, because the username may
                // always be empty before login. We also need to upload the other sysinfo info.
                //
                // https://github.com/rustdesk/rustdesk/discussions/8031
                // We still need to check the username after uploading sysinfo, because
                // 1. The username may be empty when logining in, and it can be fetched after a while.
                //    In this case, we need to upload sysinfo again.
                // 2. The username may be changed after uploading sysinfo, and we need to upload sysinfo again.
                //
                // The Windows session will switch to the last user session before the restart,
                // so it may be able to get the username before login.
                // But strangely, sometimes we can get the username before login,
                // we may not be able to get the username before login after the next restart.
                // Sense Remote: changed adapters / IP addresses → upload sysinfo again, so the
                // panel shows the current addresses (checked at most once a minute).
                if info_uploaded.uploaded
                    && crate::sense::report::network_check_due()
                    && tokio::task::spawn_blocking(crate::sense::report::network_changed_since_sysinfo)
                        .await
                        .unwrap_or(false)
                {
                    info_uploaded.uploaded = false;
                    log::info!("Sense Remote: network addresses changed, uploading sysinfo again");
                }
                let mut v = crate::get_sysinfo();
                let sys_username = v["username"].as_str().unwrap_or_default().to_string();
                // Though the username comparison is only necessary on Windows,
                // we still keep the comparison on other platforms for consistency.
                let need_upload = (!info_uploaded.uploaded || info_uploaded.username.as_ref() != Some(&sys_username)) &&
                    info_uploaded.last_uploaded.map(|x| x.elapsed() >= UPLOAD_SYSINFO_TIMEOUT).unwrap_or(true);
                if need_upload {
                    v["version"] = json!(crate::VERSION);
                    v["id"] = json!(id);
                    v["uuid"] = json!(crate::encode64(hbb_common::get_uuid()));
                    let ab_name = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_NAME);
                    if !ab_name.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_NAME] = json!(ab_name);
                    }
                    let ab_tag = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_TAG);
                    if !ab_tag.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_TAG] = json!(ab_tag);
                    }
                    let ab_alias = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_ALIAS);
                    if !ab_alias.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_ALIAS] = json!(ab_alias);
                    }
                    let ab_password = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD);
                    if !ab_password.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD] = json!(ab_password);
                    }
                    let ab_note = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_NOTE);
                    if !ab_note.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_NOTE] = json!(ab_note);
                    }
                    let username = get_builtin_option(keys::OPTION_PRESET_USERNAME);
                    if !username.is_empty() {
                        v[keys::OPTION_PRESET_USERNAME] = json!(username);
                    }
                    let strategy_name = get_builtin_option(keys::OPTION_PRESET_STRATEGY_NAME);
                    if !strategy_name.is_empty() {
                        v[keys::OPTION_PRESET_STRATEGY_NAME] = json!(strategy_name);
                    }
                    let device_group_name = get_builtin_option(keys::OPTION_PRESET_DEVICE_GROUP_NAME);
                    if !device_group_name.is_empty() {
                        v[keys::OPTION_PRESET_DEVICE_GROUP_NAME] = json!(device_group_name);
                    }
                    let device_username = Config::get_option(keys::OPTION_PRESET_DEVICE_USERNAME);
                    if !device_username.is_empty() {
                        v["username"] = json!(device_username);
                    }
                    let device_name = Config::get_option(keys::OPTION_PRESET_DEVICE_NAME);
                    if !device_name.is_empty() {
                        v["hostname"] = json!(device_name);
                    }
                    let note = Config::get_option(keys::OPTION_PRESET_NOTE);
                    if !note.is_empty() {
                        v[keys::OPTION_PRESET_NOTE] = json!(note);
                    }
                    // Sense Remote: role, Sense version, platform, displays, network addresses.
                    // Measuring blocks (DXGI, adapters), so off the async loop.
                    if let Ok(Some(sense)) = tokio::task::spawn_blocking(crate::sense::report::sysinfo_ext).await {
                        v["sense"] = sense;
                    }
                    let v = v.to_string();
                    let mut hash = "".to_owned();
                    if crate::is_public(&url) {
                        use sha2::{Digest, Sha256};
                        let mut hasher = Sha256::new();
                        hasher.update(url.as_bytes());
                        hasher.update(&v.as_bytes());
                        let res = hasher.finalize();
                        hash = hbb_common::base64::encode(&res[..]);
                        let old_hash = config::Status::get("sysinfo_hash");
                        let ver = config::Status::get("sysinfo_ver"); // sysinfo_ver is the version of sysinfo on server's side
                        if hash == old_hash {
                            // When the api doesn't exist, Ok("") will be returned in test.
                            let samever = match crate::post_request(url.replace("heartbeat", "sysinfo_ver"), "".to_owned(), "").await {
                                Ok(x)  => {
                                    sysinfo_ver = x.clone();
                                    *PRO.lock().unwrap() = true;
                                    x == ver
                                }
                                _ => {
                                    false // to make sure Pro can be assigned in below post for old
                                            // hbbs pro not supporting sysinfo_ver, use false for ensuring
                                }
                            };
                            if samever {
                                info_uploaded = InfoUploaded::uploaded(url.clone(), id.clone(), sys_username);
                                log::info!("sysinfo not changed, skip upload");
                                continue;
                            }
                        }
                    }
                    match crate::post_request(url.replace("heartbeat", "sysinfo"), v, "").await {
                        Ok(x)  => {
                            if x == "SYSINFO_UPDATED" {
                                info_uploaded = InfoUploaded::uploaded(url.clone(), id.clone(), sys_username);
                                log::info!("sysinfo updated");
                                if !hash.is_empty() {
                                    config::Status::set("sysinfo_hash", hash);
                                    config::Status::set("sysinfo_ver", sysinfo_ver.clone());
                                }
                                *PRO.lock().unwrap() = true;
                            } else if x == "ID_NOT_FOUND" {
                                info_uploaded.last_uploaded = None; // next heartbeat will upload sysinfo again
                            } else {
                                info_uploaded.last_uploaded = Some(Instant::now());
                            }
                        }
                        _ => {
                            info_uploaded.last_uploaded = Some(Instant::now());
                        }
                    }
                }
                if conns.is_empty() && last_sent.map(|x| x.elapsed() < TIME_HEARTBEAT).unwrap_or(false) {
                    continue;
                }
                last_sent = Some(Instant::now());
                let mut v = Value::default();
                v["id"] = json!(id);
                v["uuid"] = json!(crate::encode64(hbb_common::get_uuid()));
                v["ver"] = json!(hbb_common::get_version_number(crate::VERSION));
                if !conns.is_empty() {
                    v["conns"] = json!(conns);
                }
                let modified_at = LocalConfig::get_option("strategy_timestamp").parse::<i64>().unwrap_or(0);
                v["modified_at"] = json!(modified_at);
                // Sense Remote: `sense` = role, version, displays hash, health (once a minute),
                // plus the envelope state (applied_seq, envelope_error, clock_skew_s). Not sent
                // without an installed role.
                // G2-5: `applied_seq` is left out when the stored seq cannot be read.
                if let Ok(Some((mut sense, applied_seq))) = tokio::task::spawn_blocking(|| {
                    crate::sense::report::heartbeat_base()
                        .map(|sense| (sense, crate::sense::envelope_seq::read_last_seq().ok()))
                })
                .await
                {
                    sense_report.extend(&mut sense, applied_seq);
                    // Sense Remote (wave 3, K-R2-3 / G2-1): signed with the device key, last.
                    sense_sign_report(&mut sense, &id, &mut sense_report_ts);
                    v["sense"] = sense;
                }
                let response = crate::post_request(url.clone(), v.to_string(), "").await;
                if let Err(err) = &response {
                    hbb_common::throttled_log!(API_LOG_INTERVAL, warn, "Heartbeat failed: {err:?}");
                }
                // Sense Remote: only `sysinfo`, signed `sense_envelopes` and `sense_server_time`
                // are acted on. The unsigned upstream `strategy`, `disconnect` and `modified_at`
                // are never applied (anyone answering in the panel's name could set them).
                if let Ok(s) = response {
                    if let Some(answer) = crate::sense::envelope_apply::parse_answer(&s) {
                        if answer.sysinfo {
                            info_uploaded.uploaded = false;
                            config::Status::set("sysinfo_hash", "".to_owned());
                            log::info!("sysinfo required to forcely update");
                        }
                        if !answer.ignored.is_empty() {
                            hbb_common::throttled_log!(
                                API_LOG_INTERVAL,
                                warn,
                                "Sense Remote: heartbeat answer keys not applied: {:?}",
                                answer.ignored
                            );
                        }
                        sense_report.server_time(answer.server_time, now_s());
                        sense_handle_envelopes(&answer.envelopes, &id, &mut sense_report).await;
                    }
                }
            }
        }
    }
}

// Sense Remote (wave 3, K-R2-3 / G2-1): signs `sense`'s state fields with RustDesk's own device
// key (the panel has its public key from the enrolment). No key or no `applied_seq` -> no report;
// the panel then ignores the state fields. The secret key is never logged.
#[cfg(not(any(target_os = "ios")))]
fn sense_sign_report(sense: &mut Value, id: &str, last_ts: &mut Option<i64>) {
    let ts = crate::sense::report_sig::next_ts(*last_ts, now_s());
    let uuid = crate::encode64(hbb_common::get_uuid());
    let (secret_key, _) = Config::get_key_pair();
    if crate::sense::report_sig::sign_into(sense, id, &uuid, ts, &secret_key) {
        *last_ts = Some(ts);
    } else {
        hbb_common::throttled_log!(
            API_LOG_INTERVAL,
            warn,
            "Sense Remote: heartbeat report not signed (no device key or no applied_seq)"
        );
    }
}

// Sense Remote: local clock, Unix seconds (envelope validity uses only this, plan R8).
fn now_s() -> i64 {
    hbb_common::get_time() / 1000
}

// Sense Remote: verifies and applies the envelopes of one heartbeat answer, in order (the panel
// sends at most one). Only a verified envelope on a platform that applies them reaches
// `sense_apply`; every rejection goes to the next heartbeat's `envelope_error`. The registry reads
// and writes run off the async loop (K2-7).
#[cfg(not(any(target_os = "ios")))]
async fn sense_handle_envelopes(
    envelopes: &[Value],
    id: &str,
    report: &mut crate::sense::envelope_apply::Report,
) {
    for item in envelopes {
        let (item, id) = (item.clone(), id.to_owned());
        let Ok((last_seq, now, result)) =
            tokio::task::spawn_blocking(move || sense_check_and_apply(&item, &id)).await
        else {
            continue;
        };
        match result {
            Ok(seq) => {
                report.applied();
                log::info!("Sense Remote: panel envelope {seq} applied");
            }
            Err(rejection) => {
                let (reason, seq) = (rejection.reason, rejection.seq);
                if report.rejected(rejection, last_seq, now) {
                    // The panel resends a pending envelope with every heartbeat.
                    hbb_common::throttled_log!(
                        API_LOG_INTERVAL,
                        warn,
                        "Sense Remote: panel envelope rejected: {} (seq {seq:?})",
                        reason.as_str()
                    );
                }
            }
        }
    }
}

// Sense Remote: one envelope, blocking (registry). Returns (stored seq or 0, local time, result).
#[cfg(not(any(target_os = "ios")))]
fn sense_check_and_apply(
    item: &Value,
    id: &str,
) -> (u64, i64, Result<u64, crate::sense::envelope::Rejection>) {
    use crate::sense::{envelope, envelope_apply, envelope_keys, envelope_seq};
    // G2-5: an unreadable counter is not 0; the envelope is then refused (`check_stored`).
    let stored = envelope_seq::read_last_seq();
    if let Err(err) = &stored {
        log::error!("Sense Remote: reading the envelope seq failed: {err}");
    }
    let last_seq = stored.as_ref().map_or(0, |seq| *seq);
    let now = now_s();
    let iss = envelope::expected_issuer();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let expect = envelope::Expect {
        iss: &iss,
        did: id,
        duuid: &duuid,
        now_s: now,
        last_seq,
    };
    let result = envelope_apply::check_stored(
        item,
        envelope_keys::trusted_keys(),
        &expect,
        envelope_apply::APPLIES,
        stored.is_ok(),
    )
    .and_then(|verified| {
        sense_apply(&verified)
            .map(|()| verified.seq)
            .map_err(|reason| envelope::Rejection {
                reason,
                k: Some(verified.k.clone()),
                seq: Some(verified.seq),
            })
    });
    (last_seq, now, result)
}

// Sense Remote: the HKLM / `Config` side of `envelope_apply::apply_steps` (K2-2, G2-6).
#[cfg(not(any(target_os = "ios")))]
struct SenseApplySteps {
    options: HashMap<String, String>,
    seq: u64,
}

#[cfg(not(any(target_os = "ios")))]
impl crate::sense::envelope_apply::ApplySteps for SenseApplySteps {
    type Snapshot = HashMap<String, String>;

    fn check_writable(&mut self) -> Result<(), String> {
        crate::sense::envelope_seq::check_writable().map_err(|err| format!("{err:?}"))
    }

    fn snapshot(&mut self) -> HashMap<String, String> {
        Config::get_options()
    }

    fn set_options(&mut self) -> Result<(), String> {
        let options = merge_config_options(self.options.clone());
        // The allow list has no authentication key, so this never changes 2FA / trusted
        // devices; refuse rather than take upstream's async authentication path.
        if crate::trusted_devices::config::changes_authentication(&options) {
            return Err("envelope would change authentication settings".to_owned());
        }
        Config::set_options(options);
        Ok(())
    }

    fn restore_options(&mut self, snapshot: HashMap<String, String>) {
        Config::set_options(snapshot);
    }

    fn store_role(&mut self, role: crate::sense::SenseRole) -> Result<(), String> {
        crate::sense::store_role(role)
    }

    fn store_seq(&mut self) -> Result<(), String> {
        crate::sense::envelope_seq::store_last_seq(self.seq).map_err(|err| format!("{err:?}"))
    }
}

// Sense Remote: applies a verified envelope. Settings -> role (HKLM) -> `EnvelopeSeq`, all or
// nothing (`envelope_apply::apply_steps`); only then disconnect and the in-process role. A failed
// apply leaves the computer as it was and is retried with the panel's next envelope.
#[cfg(not(any(target_os = "ios")))]
fn sense_apply(
    verified: &crate::sense::envelope::Verified,
) -> Result<(), crate::sense::envelope::Reason> {
    use crate::sense::envelope_apply;
    let installed = crate::sense::installed_role();
    let new_role = envelope_apply::role_change(installed, verified.body.sense_role)?;
    // Allow list already checked; the upstream block list stays as defence in depth.
    let mut steps = SenseApplySteps {
        options: verified.body.config_options.clone().into_iter().collect(),
        seq: verified.seq,
    };
    envelope_apply::apply_steps(&mut steps, installed, new_role)?;
    if let Some(ids) = &verified.body.disconnect {
        let conns: Vec<i32> = ids.iter().filter_map(|id| i32::try_from(*id).ok()).collect();
        if !conns.is_empty() {
            SENDER.lock().unwrap().send(conns).ok();
        }
    }
    if let Some(role) = new_role {
        // This process now; the tray / UI processes read the stored role at their next start
        // (K2-6, deferred: see the PR).
        crate::sense::apply_role(Some(role));
        log::info!("Sense Remote: role changed to {}", role.as_str());
        // Sense Remote (wave 3, K-ROL-2): into or out of Controller, listening has to start or
        // stop; `--server` decides that only at start, so it exits and the Windows service
        // starts it again with the stored role (role and seq are already in HKLM).
        if envelope_apply::restart_needed(installed, role) && crate::is_server() {
            sense_restart_server();
        }
    }
    Ok(())
}

// Sense Remote (K-ROL-2): ends the `--server` process shortly after a role change, so the
// service (`run_service`: relaunch when the process has exited) starts it with the new role.
#[cfg(not(any(target_os = "ios")))]
fn sense_restart_server() {
    log::info!("Sense Remote: role change needs a server restart");
    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(2));
        std::process::exit(0);
    });
}

fn heartbeat_url() -> String {
    let url = crate::common::get_api_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    );
    if url.is_empty() || crate::is_public(&url) {
        return "".to_owned();
    }
    format!("{}/api/heartbeat", url)
}

const BLOCKED_CONFIG_OPTIONS: &[&str] = &[
    // Server endpoints and trust.
    keys::OPTION_CUSTOM_RENDEZVOUS_SERVER,
    "rendezvous-servers",
    keys::OPTION_API_SERVER,
    keys::OPTION_RELAY_SERVER,
    keys::OPTION_KEY,
    keys::OPTION_ICE_SERVERS,
    // Transport security.
    keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK,
    keys::OPTION_ALLOW_WEBSOCKET,
    keys::OPTION_WEBSOCKET_PORT,
    // Authentication and credentials.
    "2fa",
    "bot",
    keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD,
    keys::OPTION_ENABLE_TRUSTED_DEVICES,
    keys::OPTION_TRUSTED_DEVICE_EXPIRATION,
    // Deployment and address book metadata.
    keys::OPTION_PRESET_ADDRESS_BOOK_NAME,
    keys::OPTION_PRESET_ADDRESS_BOOK_TAG,
    keys::OPTION_PRESET_ADDRESS_BOOK_ALIAS,
    keys::OPTION_PRESET_ADDRESS_BOOK_NOTE,
    keys::OPTION_PRESET_DEVICE_NAME,
    keys::OPTION_PRESET_DEVICE_USERNAME,
    keys::OPTION_PRESET_NOTE,
    // Recording location and service state.
    keys::OPTION_WINDOWS_SERVICE_VIDEO_SAVE_DIRECTORY,
    "stop-service",
    "reg_recovery",
];

fn filter_config_options(options: &mut HashMap<String, String>) {
    let rejected: Vec<_> = BLOCKED_CONFIG_OPTIONS
        .iter()
        .copied()
        .filter(|key| options.contains_key(*key))
        .collect();
    if !rejected.is_empty() {
        hbb_common::throttled_log!(
            crate::common::API_LOG_INTERVAL,
            warn,
            "Rejected heartbeat strategy options: {rejected:?}"
        );
    }
    options.retain(|key, _| !BLOCKED_CONFIG_OPTIONS.contains(&key.as_str()));
}

// Sense Remote: the synchronous part of `handle_config_options` (block list + merge into the
// current options), shared with the envelope apply (`SenseApplySteps::set_options`).
fn merge_config_options(mut config_options: HashMap<String, String>) -> HashMap<String, String> {
    filter_config_options(&mut config_options);
    let mut options = Config::get_options();
    let default_settings = config::DEFAULT_SETTINGS.read().unwrap().clone();
    config_options
        .iter()
        .map(|(k, v)| {
            // Priority: user config > default advanced options.
            // Only when default advanced options are also empty, remove user option (fallback to built-in default);
            // otherwise insert an empty value so user config remains present.
            if v.is_empty() && default_settings.get(k).map_or("", |v| v).is_empty() {
                options.remove(k);
            } else {
                options.insert(k.to_string(), v.to_string());
            }
        })
        .count();
    options
}

// Sense Remote: no caller any more (plain heartbeat `strategy` is never applied; envelopes go
// through `SenseApplySteps`). Kept to stay close to upstream.
#[allow(dead_code)]
async fn handle_config_options(
    config_options: HashMap<String, String>,
) -> hbb_common::ResultType<()> {
    let options = merge_config_options(config_options);
    if crate::trusted_devices::config::changes_authentication(&options) {
        let current = Config::get_options();
        let mut non_auth_options = options.clone();
        for key in [
            "2fa",
            keys::OPTION_ENABLE_TRUSTED_DEVICES,
            keys::OPTION_TRUSTED_DEVICE_EXPIRATION,
        ] {
            match current.get(key) {
                Some(value) => {
                    non_auth_options.insert(key.to_owned(), value.clone());
                }
                None => {
                    non_auth_options.remove(key);
                }
            }
        }
        // Authentication update failures must not block unrelated strategy options.
        Config::set_options(non_auth_options);
        return crate::trusted_devices::config::update_options(options).await;
    }
    Config::set_options(options);
    Ok(())
}

#[allow(unused)]
#[cfg(not(any(target_os = "ios")))]
pub fn is_pro() -> bool {
    PRO.lock().unwrap().clone()
}

// Fire-and-forget by design: the switch flow must not block on this POST.
// If the device clock is outside the server's accepted window, the server
// returns its current Unix time and this task re-signs and retries once.
#[cfg(feature = "flutter")]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn register_switch_grant(switch_uuid: String) {
    tokio::spawn(async move {
        let api_server = crate::ui_interface::get_api_server();
        if api_server.is_empty() || crate::is_public(&api_server) {
            return;
        }
        use hbb_common::sodiumoxide::crypto::{hash::sha256, sign};
        let switch_code = crate::encode64(sha256::hash(switch_uuid.as_bytes()).0);
        let switch_code_verifier = switch_code_verifier(&switch_code);
        let timestamp = (hbb_common::get_time() / 1000).to_string();
        let id = Config::get_id();
        let kp = Config::get_key_pair();
        let Some(sk) = sign::SecretKey::from_slice(&kp.0) else {
            log::error!("Failed to register switch grant: no device key");
            return;
        };
        let url = format!("{}/api/switch-grant", api_server);
        let mut timestamp = timestamp;
        for attempt in 0..2 {
            let signature = sign::sign_detached(
                &switch_grant_signed_msg(&id, &switch_code_verifier, &timestamp),
                &sk,
            );
            let body = json!({
                "id": &id,
                "switch_code_verifier": &switch_code_verifier,
                "timestamp": &timestamp,
                "signature": crate::encode64(signature.to_bytes()),
            })
            .to_string();
            let response = match crate::post_request(url.clone(), body, "").await {
                Ok(response) => response,
                Err(e) => {
                    log::error!("Failed to register switch grant: {}", e);
                    return;
                }
            };
            let response = match serde_json::from_str::<Value>(&response) {
                Ok(response) => response,
                Err(e) => {
                    log::error!("Failed to register switch grant: invalid response: {}", e);
                    return;
                }
            };
            match response.get("accepted").and_then(Value::as_bool) {
                Some(true) => return,
                Some(false) => {}
                None => {
                    log::error!("Failed to register switch grant: missing accepted response");
                    return;
                }
            }
            let Some(server_time) = response["server_time"].as_i64() else {
                log::error!("Failed to register switch grant: rejected by server");
                return;
            };
            if attempt == 0 {
                log::warn!("Switch grant timestamp rejected, retrying with server time");
                timestamp = server_time.to_string();
            } else {
                log::error!("Failed to register switch grant after retrying with server time");
            }
        }
    });
}

#[cfg(feature = "flutter")]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn switch_code_verifier(switch_code: &str) -> String {
    use hbb_common::sodiumoxide::crypto::hash::sha256;

    let prefix = b"switch-grant-verifier\0";
    let mut msg = Vec::with_capacity(prefix.len() + switch_code.len());
    msg.extend_from_slice(prefix);
    msg.extend_from_slice(switch_code.as_bytes());
    crate::encode64(sha256::hash(&msg).0)
}

#[cfg(feature = "flutter")]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn switch_grant_signed_msg(id: &str, switch_code_verifier: &str, timestamp: &str) -> Vec<u8> {
    let mut msg =
        Vec::with_capacity(13 + id.len() + 1 + switch_code_verifier.len() + 1 + timestamp.len());
    msg.extend_from_slice(b"switch-grant\0");
    msg.extend_from_slice(id.as_bytes());
    msg.push(0);
    msg.extend_from_slice(switch_code_verifier.as_bytes());
    msg.push(0);
    msg.extend_from_slice(timestamp.as_bytes());
    msg
}

#[cfg(all(
    test,
    feature = "flutter",
    not(any(target_os = "android", target_os = "ios"))
))]
mod tests {
    use super::{switch_code_verifier, switch_grant_signed_msg};

    #[test]
    fn test_switch_code_verifier_is_not_raw_switch_code() {
        let switch_code = "code-abc";
        let verifier = switch_code_verifier(switch_code);
        assert_ne!(verifier, switch_code);
        assert_eq!(verifier, switch_code_verifier(switch_code));
        assert_eq!(
            verifier,
            "dMIn3uiPe77XodFB5IKi7PrKJ7l7+zVquNn0ObSaHQc="
        );
    }

    #[test]
    fn test_switch_grant_signed_msg_layout() {
        let expected: Vec<u8> = [
            &b"switch-grant\0"[..],
            b"id1",
            b"\0",
            b"c1",
            b"\0",
            b"1700000000",
        ]
        .concat();
        assert_eq!(switch_grant_signed_msg("id1", "c1", "1700000000"), expected);
    }
}

#[cfg(test)]
mod strategy_tests {
    use super::{filter_config_options, HashMap};

    #[test]
    fn strategy_cannot_replace_or_clear_server_trust_and_credentials() {
        for value in ["attacker", "Y", "N", ""] {
            let mut options = [
                "custom-rendezvous-server",
                "rendezvous-servers",
                "api-server",
                "relay-server",
                "key",
                "ice-servers",
                "allow-insecure-tls-fallback",
                "allow-websocket",
                "websocket-port",
                "2fa",
                "bot",
                "preset-address-book-password",
                "enable-trusted-devices",
                "trusted-device-expiration-days",
                "preset-address-book-name",
                "preset-address-book-tag",
                "preset-address-book-alias",
                "preset-address-book-note",
                "preset-device-name",
                "preset-device-username",
                "preset-note",
                "windows-service-video-save-directory",
                "stop-service",
                "reg_recovery",
            ]
            .into_iter()
            .map(|key| (key.to_owned(), value.to_owned()))
            .collect::<HashMap<_, _>>();
            options.insert("enable-clipboard".to_owned(), "N".to_owned());
            options.insert("allow-auto-disconnect".to_owned(), String::new());
            filter_config_options(&mut options);
            assert_eq!(
                options,
                HashMap::from([
                    ("enable-clipboard".to_owned(), "N".to_owned()),
                    ("allow-auto-disconnect".to_owned(), String::new()),
                ])
            );
        }
    }

    #[test]
    fn existing_and_unknown_policy_options_are_preserved() {
        let policy_keys = [
            // Existing server strategy options.
            "access-mode",
            "enable-keyboard",
            "enable-remote-printer",
            "enable-clipboard",
            "enable-file-transfer",
            "enable-audio",
            "enable-terminal",
            "enable-tunnel",
            "enable-remote-restart",
            "enable-record-session",
            "enable-block-input",
            "enable-privacy-mode",
            "enable-camera",
            "allow-remote-config-modification",
            "approve-mode",
            "verification-method",
            "temporary-password-length",
            "allow-numeric-one-time-password",
            "allow-hide-cm",
            "enable-lan-discovery",
            "direct-server",
            "direct-access-port",
            "whitelist",
            "id-whitelist",
            "allow-auto-disconnect",
            "auto-disconnect-timeout",
            "allow-remove-wallpaper",
            // Security policy controls.
            "allow-only-conn-window-open",
            "allow-scope-violation-close",
            "allow-scope-violation-alarm",
            // Future strategy option.
            "future-strategy-option",
        ];
        for value in ["Y", "N", ""] {
            let mut options: HashMap<_, _> = policy_keys
                .into_iter()
                .map(|key| (key.to_owned(), value.to_owned()))
                .collect();
            let expected = options.clone();
            filter_config_options(&mut options);
            assert_eq!(options, expected);
        }
    }
}
