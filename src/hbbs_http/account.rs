use super::HbbHttpResponse;
use crate::hbbs_http::create_http_client_with_url;
use hbb_common::{config::LocalConfig, log, ResultType};
use serde_derive::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};
use url::Url;

lazy_static::lazy_static! {
    static ref OIDC_SESSION: Arc<RwLock<OidcSession>> = Arc::new(RwLock::new(OidcSession::new()));
}

const QUERY_INTERVAL_SECS: f32 = 1.0;
const QUERY_TIMEOUT_SECS: u64 = 60 * 3;

const REQUESTING_ACCOUNT_AUTH: &str = "Requesting account auth";
const WAITING_ACCOUNT_AUTH: &str = "Waiting account auth";
const LOGIN_ACCOUNT_AUTH: &str = "Login account auth";

#[derive(Deserialize, Clone, Debug)]
pub struct OidcAuthUrl {
    code: String,
    url: Url,
    // Sense Remote: 6-digit pairing code from the panel (wave 3 K-GİRİŞ). The panel's approval
    // page shows the same code; the app and the setup wizard show it large so the employee can
    // compare them before approving. Older panels do not send it.
    #[serde(default)]
    pairing_code: Option<String>,
}

/// Sense Remote: why the client signs in (wave 3 K-GİRİŞ). The panel gives a token from an
/// `Install` login the right to register this computer (`POST /api/sense/enroll`, 30 min).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginPurpose {
    App,
    Install,
    // Sense Remote (permanent password plan §3.4): unlocking the permanent password; the token
    // is short-lived and never saved as the app sign-in.
    Password,
    // Sense Remote (Sürüm 4, S4 / TK4): changing this computer's role from the app; the token is
    // short-lived, single-use and never saved as the app sign-in.
    // Sense Remote (security review S4-2): the target role goes with the sign-in
    // (`sense.target_role`); the panel shows it on the approval page and the token then changes
    // to this role only (another role -> `role_scope`).
    Role(crate::sense::SenseRole),
}

impl LoginPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Install => "install",
            Self::Password => "password",
            Self::Role(_) => "role",
        }
    }

    /// Sense Remote (S4-2): contract `SenseRole` of the target, only for `Role`.
    pub fn target_role(self) -> Option<&'static str> {
        use crate::sense::SenseRole;
        match self {
            Self::Role(SenseRole::Host) => Some("host"),
            Self::Role(SenseRole::Controller) => Some("controller"),
            Self::Role(SenseRole::Both) => Some("host_controller"),
            _ => None,
        }
    }

    /// Sense Remote: the `sense` part of `POST /api/oidc/auth` (contract `OidcAuthBody.sense`).
    fn sense_body(self) -> serde_json::Value {
        let mut sense = serde_json::json!({ "v": 1, "purpose": self.as_str() });
        if let Some(target) = self.target_role() {
            sense["target_role"] = serde_json::json!(target);
        }
        sense
    }
}

/// Sense Remote: body of `POST /api/oidc/auth` with the `sense` part (contract v3 `OidcAuthBody`).
fn auth_request_body(
    op: &str,
    id: &str,
    uuid: &str,
    device_info: serde_json::Value,
    api_server: &str,
    purpose: LoginPurpose,
) -> serde_json::Value {
    serde_json::json!({
        "op": op,
        "id": id,
        "uuid": uuid,
        "deviceInfo": device_info,
        "apiDomain": api_server,
        "sense": purpose.sense_body(),
    })
}

/// Sense Remote: only six ASCII digits are shown; anything else is dropped (contract
/// `PairingCode`), so a malformed answer can never look like a code to compare.
pub fn valid_pairing_code(code: Option<&str>) -> Option<String> {
    let code = code?;
    (code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit())).then(|| code.to_owned())
}

#[derive(Debug, Deserialize, Serialize, Default, Clone)]
pub struct DeviceInfo {
    /// Linux , Windows , Android ...
    #[serde(default)]
    pub os: String,

    /// `browser` or `client`
    #[serde(default)]
    pub r#type: String,

    /// device name from rustdesk client,
    /// browser info(name + version) from browser
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WhitelistItem {
    data: String, // ip / device uuid
    info: DeviceInfo,
    exp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserInfo {
    #[serde(default, flatten)]
    pub settings: UserSettings,
    #[serde(default)]
    pub login_device_whitelist: Vec<WhitelistItem>,
    #[serde(default)]
    pub other: HashMap<String, String>,
    // Sense Remote (S11, D3a): the signed per-person grants envelope the panel sends with the
    // sign-in (`user.info.sense_grants`); checked and kept by `crate::sense::grants`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sense_grants: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserSettings {
    #[serde(default)]
    pub email_verification: bool,
    #[serde(default)]
    pub email_alarm_notification: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(i64)]
pub enum UserStatus {
    Disabled = 0,
    Normal = 1,
    Unverified = -1,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPayload {
    pub name: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub avatar: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub status: UserStatus,
    pub info: UserInfo,
    #[serde(default)]
    pub is_admin: bool,
    #[serde(default)]
    pub third_auth_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthBody {
    pub access_token: String,
    pub r#type: String,
    #[serde(default)]
    pub tfa_type: String,
    #[serde(default)]
    pub secret: String,
    pub user: UserPayload,
}

pub struct OidcSession {
    warmed_api_server: Option<String>,
    state_msg: &'static str,
    failed_msg: String,
    code_url: Option<OidcAuthUrl>,
    auth_body: Option<AuthBody>,
    auth_attempt: u64,
    running: bool,
    query_timeout: Duration,
}

#[derive(Serialize)]
pub struct AuthResult {
    pub state_msg: String,
    pub failed_msg: String,
    pub url: Option<String>,
    pub auth_body: Option<AuthBody>,
    // Sense Remote: pairing code to show while waiting for the browser (wave 3 K-GİRİŞ).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pairing_code: Option<String>,
}

impl Default for UserStatus {
    fn default() -> Self {
        UserStatus::Normal
    }
}

impl OidcSession {
    fn new() -> Self {
        Self {
            warmed_api_server: None,
            state_msg: REQUESTING_ACCOUNT_AUTH,
            failed_msg: "".to_owned(),
            code_url: None,
            auth_body: None,
            auth_attempt: 0,
            running: false,
            query_timeout: Duration::from_secs(QUERY_TIMEOUT_SECS),
        }
    }

    fn ensure_client(api_server: &str) {
        let mut write_guard = OIDC_SESSION.write().unwrap();
        if write_guard.warmed_api_server.as_deref() == Some(api_server) {
            return;
        }
        // This URL is used to detect the appropriate TLS implementation for the server.
        let login_option_url = format!("{}/api/login-options", api_server);
        let _ = create_http_client_with_url(&login_option_url);
        write_guard.warmed_api_server = Some(api_server.to_owned());
    }

    fn auth(
        api_server: &str,
        op: &str,
        id: &str,
        uuid: &str,
        purpose: LoginPurpose,
    ) -> ResultType<HbbHttpResponse<OidcAuthUrl>> {
        Self::ensure_client(api_server);
        // Sense Remote: the body also says why we sign in (`sense.purpose`).
        let body = auth_request_body(
            op,
            id,
            uuid,
            serde_json::to_value(crate::ui_interface::get_login_device_info())
                .unwrap_or_default(),
            api_server,
            purpose,
        )
        .to_string();
        let resp = crate::post_request_sync(format!("{}/api/oidc/auth", api_server), body, "")?;
        HbbHttpResponse::parse(&resp)
    }

    fn query(
        api_server: &str,
        code: &str,
        id: &str,
        uuid: &str,
    ) -> ResultType<HbbHttpResponse<AuthBody>> {
        let url = Url::parse_with_params(
            &format!("{}/api/oidc/auth-query", api_server),
            &[("code", code), ("id", id), ("uuid", uuid)],
        )?;
        Self::ensure_client(api_server);
        #[derive(Deserialize)]
        struct HttpResponseBody {
            body: String,
        }

        let resp =
            crate::http_request_sync(url.to_string(), "GET".to_owned(), None, "{}".to_owned())?;
        let resp = serde_json::from_str::<HttpResponseBody>(&resp)?;
        HbbHttpResponse::parse(&resp.body)
    }

    fn reset(&mut self) {
        self.state_msg = REQUESTING_ACCOUNT_AUTH;
        self.failed_msg = "".to_owned();
        self.running = false;
        self.code_url = None;
        self.auth_body = None;
    }

    fn before_task(&mut self) {
        self.reset();
        self.running = true;
    }

    fn after_task(&mut self) {
        self.running = false;
    }

    fn start_auth_attempt(&mut self) -> u64 {
        self.auth_attempt = self.auth_attempt.wrapping_add(1);
        self.auth_attempt
    }

    fn cancel_auth_attempt(&mut self) {
        self.auth_attempt = self.auth_attempt.wrapping_add(1);
    }

    fn is_current_auth_attempt(&self, auth_attempt: u64) -> bool {
        self.auth_attempt == auth_attempt
    }

    fn auth_attempt_is_current(auth_attempt: u64) -> bool {
        OIDC_SESSION
            .read()
            .unwrap()
            .is_current_auth_attempt(auth_attempt)
    }

    fn set_state_if_current(auth_attempt: u64, state_msg: &'static str, failed_msg: String) {
        let mut session = OIDC_SESSION.write().unwrap();
        if session.is_current_auth_attempt(auth_attempt) {
            session.set_state(state_msg, failed_msg);
        }
    }

    fn sleep(secs: f32) {
        std::thread::sleep(std::time::Duration::from_secs_f32(secs));
    }

    fn auth_task(
        api_server: String,
        op: String,
        id: String,
        uuid: String,
        remember_me: bool,
        auth_attempt: u64,
        purpose: LoginPurpose,
    ) {
        let auth_request_res = Self::auth(&api_server, &op, &id, &uuid, purpose);
        log::info!("Request oidc auth result: {:?}", &auth_request_res);
        if !Self::auth_attempt_is_current(auth_attempt) {
            return;
        }
        let code_url = match auth_request_res {
            Ok(HbbHttpResponse::<_>::Data(code_url)) => code_url,
            Ok(HbbHttpResponse::<_>::Error(err)) => {
                Self::set_state_if_current(auth_attempt, REQUESTING_ACCOUNT_AUTH, err);
                return;
            }
            Ok(_) => {
                Self::set_state_if_current(
                    auth_attempt,
                    REQUESTING_ACCOUNT_AUTH,
                    "Invalid auth response".to_owned(),
                );
                return;
            }
            Err(err) => {
                Self::set_state_if_current(auth_attempt, REQUESTING_ACCOUNT_AUTH, err.to_string());
                return;
            }
        };

        {
            let mut session = OIDC_SESSION.write().unwrap();
            if !session.is_current_auth_attempt(auth_attempt) {
                return;
            }
            session.set_state(WAITING_ACCOUNT_AUTH, "".to_owned());
            session.code_url = Some(code_url.clone());
        }

        let begin = Instant::now();
        let query_timeout = OIDC_SESSION.read().unwrap().query_timeout;
        while Self::auth_attempt_is_current(auth_attempt) && begin.elapsed() < query_timeout {
            let query_result = Self::query(&api_server, &code_url.code, &id, &uuid);
            if !Self::auth_attempt_is_current(auth_attempt) {
                return;
            }
            match query_result {
                Ok(HbbHttpResponse::<_>::Data(auth_body)) => {
                    let mut session = OIDC_SESSION.write().unwrap();
                    if !session.is_current_auth_attempt(auth_attempt) {
                        return;
                    }
                    if auth_body.r#type == "access_token" {
                        if remember_me {
                            LocalConfig::set_option(
                                "access_token".to_owned(),
                                auth_body.access_token.clone(),
                            );
                            LocalConfig::set_option(
                                "user_info".to_owned(),
                                serde_json::json!({
                                    "name": auth_body.user.name,
                                    "display_name": auth_body.user.display_name,
                                    "avatar": auth_body.user.avatar,
                                    "status": auth_body.user.status
                                })
                                .to_string(),
                            );
                            // Sense Remote (S11, D3a): note the grants envelope of this sign-in.
                            crate::sense::grants::on_sign_in(
                                auth_body
                                    .user
                                    .email
                                    .as_deref()
                                    .filter(|email| !email.is_empty())
                                    .unwrap_or(&auth_body.user.name),
                                auth_body.user.info.sense_grants.as_ref(),
                            );
                        }
                    }
                    session.set_state(LOGIN_ACCOUNT_AUTH, "".to_owned());
                    session.auth_body = Some(auth_body);
                    return;
                }
                Ok(HbbHttpResponse::<_>::Error(err)) => {
                    if err.contains("No authed oidc is found") {
                        // ignore, keep querying
                    } else {
                        Self::set_state_if_current(auth_attempt, WAITING_ACCOUNT_AUTH, err);
                        return;
                    }
                }
                Ok(_) => {
                    // ignore
                }
                Err(err) => {
                    log::trace!("Failed query oidc {}", err);
                    // ignore
                }
            }
            Self::sleep(QUERY_INTERVAL_SECS);
        }

        if begin.elapsed() >= query_timeout && Self::auth_attempt_is_current(auth_attempt) {
            Self::set_state_if_current(auth_attempt, WAITING_ACCOUNT_AUTH, "timeout".to_owned());
        }
    }

    fn set_state(&mut self, state_msg: &'static str, failed_msg: String) {
        self.state_msg = state_msg;
        self.failed_msg = failed_msg;
    }

    fn wait_stop_querying() {
        let wait_secs = 0.3;
        while OIDC_SESSION.read().unwrap().running {
            Self::sleep(wait_secs);
        }
    }

    pub fn account_auth(
        api_server: String,
        op: String,
        id: String,
        uuid: String,
        remember_me: bool,
    ) {
        Self::account_auth_for(api_server, op, id, uuid, remember_me, LoginPurpose::App)
    }

    /// Sense Remote: `account_auth` with a purpose. The setup wizard signs in with `Install`
    /// and `remember_me = false`: the token stays in memory until registration decides
    /// whether this computer may keep it (wave 3 K-KAYIT-b).
    pub fn account_auth_for(
        api_server: String,
        op: String,
        id: String,
        uuid: String,
        remember_me: bool,
        purpose: LoginPurpose,
    ) {
        let auth_attempt = OIDC_SESSION.write().unwrap().start_auth_attempt();
        Self::wait_stop_querying();
        {
            let mut session = OIDC_SESSION.write().unwrap();
            if !session.is_current_auth_attempt(auth_attempt) {
                return;
            }
            session.before_task();
        }
        std::thread::spawn(move || {
            Self::auth_task(api_server, op, id, uuid, remember_me, auth_attempt, purpose);
            OIDC_SESSION.write().unwrap().after_task();
        });
    }

    fn get_result_(&self) -> AuthResult {
        AuthResult {
            state_msg: self.state_msg.to_string(),
            failed_msg: self.failed_msg.clone(),
            url: self.code_url.as_ref().map(|x| x.url.to_string()),
            auth_body: self.auth_body.clone(),
            pairing_code: valid_pairing_code(
                self.code_url
                    .as_ref()
                    .and_then(|x| x.pairing_code.as_deref()),
            ),
        }
    }

    pub fn auth_cancel() {
        OIDC_SESSION.write().unwrap().cancel_auth_attempt();
    }

    pub fn get_result() -> AuthResult {
        OIDC_SESSION.read().unwrap().get_result_()
    }

    /// Sense Remote: the access token of the finished sign-in, kept only in memory (setup
    /// wizard; `remember_me = false`).
    pub fn sense_access_token() -> Option<String> {
        let session = OIDC_SESSION.read().unwrap();
        let body = session.auth_body.as_ref()?;
        (body.r#type == "access_token" && !body.access_token.is_empty())
            .then(|| body.access_token.clone())
    }

    /// Sense Remote: the signed-in user of the finished sign-in (name = e-mail).
    pub fn sense_user() -> Option<UserPayload> {
        let session = OIDC_SESSION.read().unwrap();
        session.auth_body.as_ref().map(|body| body.user.clone())
    }

    /// Sense Remote: stops a running sign-in and forgets a finished one (token and user) in
    /// this process.
    pub fn sense_forget_auth() {
        let mut session = OIDC_SESSION.write().unwrap();
        session.cancel_auth_attempt();
        session.state_msg = REQUESTING_ACCOUNT_AUTH;
        session.failed_msg = "".to_owned();
        session.code_url = None;
        session.auth_body = None;
    }
}

// Sense Remote: wave 3 K-GİRİŞ (login purpose and pairing code).
#[cfg(test)]
mod sense_tests {
    use super::*;

    #[test]
    fn auth_body_says_why_we_sign_in() {
        for (purpose, value) in [
            (LoginPurpose::App, "app"),
            (LoginPurpose::Install, "install"),
            (LoginPurpose::Password, "password"),
        ] {
            let body = auth_request_body(
                "Google",
                "123456789",
                "dXVpZA==",
                serde_json::json!({"os": "windows", "type": "client", "name": "pc"}),
                "https://remote.snsdpt.com",
                purpose,
            );
            assert_eq!(body["sense"], serde_json::json!({"v": 1, "purpose": value}));
            assert_eq!(body["op"], "Google");
            assert_eq!(body["id"], "123456789");
            assert_eq!(body["uuid"], "dXVpZA==");
            assert_eq!(body["deviceInfo"]["type"], "client");
            assert_eq!(body["apiDomain"], "https://remote.snsdpt.com");
        }
    }

    /// Sense Remote (S4-2): the role sign-in names its target (contract `SenseRole`); the other
    /// purposes never carry `target_role`.
    #[test]
    fn role_sign_in_names_the_target_role() {
        use crate::sense::SenseRole;
        for (role, wire) in [
            (SenseRole::Host, "host"),
            (SenseRole::Controller, "controller"),
            (SenseRole::Both, "host_controller"),
        ] {
            let body = auth_request_body(
                "Google",
                "123456789",
                "dXVpZA==",
                serde_json::json!({"os": "windows", "type": "client", "name": "pc"}),
                "https://remote.snsdpt.com",
                LoginPurpose::Role(role),
            );
            assert_eq!(
                body["sense"],
                serde_json::json!({"v": 1, "purpose": "role", "target_role": wire})
            );
        }
        for purpose in [LoginPurpose::App, LoginPurpose::Install, LoginPurpose::Password] {
            assert_eq!(purpose.target_role(), None);
            assert!(purpose.sense_body().get("target_role").is_none());
        }
    }

    #[test]
    fn auth_url_reads_pairing_code_and_older_answers() {
        let with: OidcAuthUrl = serde_json::from_str(
            r#"{"code":"c","url":"https://remote.snsdpt.com/onay/x","pairing_code":"482913"}"#,
        )
        .unwrap();
        assert_eq!(with.pairing_code.as_deref(), Some("482913"));
        let without: OidcAuthUrl =
            serde_json::from_str(r#"{"code":"c","url":"https://remote.snsdpt.com/x"}"#).unwrap();
        assert_eq!(without.pairing_code, None);
    }

    #[test]
    fn only_six_digits_are_shown_as_pairing_code() {
        assert_eq!(valid_pairing_code(Some("482913")), Some("482913".to_owned()));
        assert_eq!(valid_pairing_code(Some("000000")), Some("000000".to_owned()));
        for bad in ["", "48291", "4829134", "48291a", "482 913", " 482913", "４８２９１３"] {
            assert_eq!(valid_pairing_code(Some(bad)), None, "{bad:?}");
        }
        assert_eq!(valid_pairing_code(None), None);
    }

    #[test]
    fn result_carries_a_valid_pairing_code_only() {
        let mut session = OidcSession::new();
        session.code_url = Some(OidcAuthUrl {
            code: "c".to_owned(),
            url: Url::parse("https://remote.snsdpt.com/x").unwrap(),
            pairing_code: Some("123456".to_owned()),
        });
        let json = serde_json::to_value(session.get_result_()).unwrap();
        assert_eq!(json["pairing_code"], "123456");
        session.code_url.as_mut().unwrap().pairing_code = Some("12345x".to_owned());
        let json = serde_json::to_value(session.get_result_()).unwrap();
        assert!(json.get("pairing_code").is_none());
        session.code_url = None;
        assert_eq!(session.get_result_().pairing_code, None);
    }
}
