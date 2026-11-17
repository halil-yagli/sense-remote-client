//! Sense Remote: sign-in and registration from the setup wizard (wave 3 I6, plan K-GİRİŞ,
//! K-KAYIT, K-YEREL, K-R2-3).
//!
//! Flow (installer process, signed-in Sense employee):
//! 1. `login_start` signs in through the panel's OIDC flow with `sense.purpose = "install"`;
//!    the token stays in memory (`remember_me = false`). `login_status` gives the wizard the
//!    state, the approval URL and the 6-digit pairing code, never the token.
//! 2. `projects` lists the projects this employee can see (`/api/device-group/accessible`).
//! 3. `sense::install` runs `install_me`; then `enroll` registers the computer
//!    (`POST /api/sense/enroll`) with this computer's RustDesk ID, UUID and public key.
//! 4. Host: the token is dropped here and from the app's saved sign-in (the panel revokes it
//!    too). Controller / Host + Controller: the token is saved like a normal app sign-in.
//!
//! Registration failures leave the computer installed; the wizard offers "Yeniden dene", and
//! if the employee gives up, the computer appears as "onay bekleyen" with its first heartbeat.

use super::{
    clean_name, clean_text, report, SenseRole, MAX_LOCATION_CHARS, MAX_NOTE_CHARS,
    MAX_PROJECTS, MAX_PROJECT_CHARS,
};
use crate::hbbs_http::account::{AuthResult, LoginPurpose, OidcSession};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config::{Config, LocalConfig},
    log, tokio, ResultType,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Mutex;

/// OIDC provider name the panel offers (`oidc/Google`, contract `OIDC_OP`).
const OIDC_OP: &str = "Google";
const ENROLL_PATH: &str = "/api/sense/enroll";
const PROJECTS_PATH: &str = "/api/device-group/accessible";
const PROJECTS_PAGE_SIZE: usize = 100;
const PROJECTS_MAX_PAGES: usize = 10;
/// Panel error codes (contract `EnrollErrorCode`); the wizard translates them.
const ENROLL_ERRORS: [&str; 8] = [
    "token_invalid",
    "install_scope",
    "device_mismatch",
    "validation",
    "project_not_found",
    "uuid_mismatch",
    "rate_limited",
    "retry",
];

/// Role installed by this process (`sense::install`); registration sends this one, not what
/// the screen sends later.
static INSTALLED_ROLE: Mutex<Option<SenseRole>> = Mutex::new(None);

pub fn remember_installed_role(role: SenseRole) {
    *INSTALLED_ROLE.lock().unwrap() = Some(role);
}

fn installed_role() -> Option<SenseRole> {
    *INSTALLED_ROLE.lock().unwrap()
}

// ---------------------------------------------------------------------------------------------
// Sign-in
// ---------------------------------------------------------------------------------------------

pub fn login_start() {
    OidcSession::sense_forget_auth();
    OidcSession::account_auth_for(
        super::api_server(),
        OIDC_OP.to_owned(),
        crate::ui_interface::get_id(),
        crate::ui_interface::get_uuid(),
        false,
        LoginPurpose::Install,
    );
}

pub fn login_cancel() {
    OidcSession::sense_forget_auth();
}

pub fn is_signed_in() -> bool {
    OidcSession::sense_access_token().is_some()
}

/// JSON for the wizard: `{"state": "requesting" | "waiting" | "done" | "failed", ...}`.
pub fn login_status() -> String {
    login_status_value(&OidcSession::get_result(), &super::api_server()).to_string()
}

/// Pure part of `login_status`. The token never leaves Rust; the URL is passed on only when it
/// is a page of our panel (it is opened in the browser).
fn login_status_value(result: &AuthResult, api_server: &str) -> Value {
    if let Some(body) = &result.auth_body {
        if body.r#type != "access_token" || body.access_token.is_empty() {
            return json!({ "state": "failed", "error": "failed" });
        }
        return json!({
            "state": "done",
            "user": {
                "name": body.user.name,
                "display_name": body.user.display_name.clone().unwrap_or_default(),
            },
        });
    }
    if !result.failed_msg.is_empty() {
        let error = if result.failed_msg == "timeout" {
            "timeout"
        } else {
            "failed"
        };
        let detail: String = result.failed_msg.chars().take(200).collect();
        return json!({ "state": "failed", "error": error, "detail": detail });
    }
    match &result.url {
        Some(url) if url.starts_with(&format!("{api_server}/")) => json!({
            "state": "waiting",
            "url": url,
            "pairing_code": result.pairing_code,
        }),
        Some(_) => json!({ "state": "failed", "error": "failed" }),
        None => json!({ "state": "requesting" }),
    }
}

// ---------------------------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize)]
struct Project {
    id: String,
    name: String,
}

/// JSON for the wizard: `{"ok": true, "projects": [{id, name}]}` (panel order) or
/// `{"ok": false, "error": "token_invalid" | "network" | "retry"}`.
pub fn projects() -> String {
    let Some(token) = OidcSession::sense_access_token() else {
        return json!({ "ok": false, "error": "token_invalid" }).to_string();
    };
    let header = json!({ "Authorization": format!("Bearer {token}") }).to_string();
    let mut all: Vec<Project> = Vec::new();
    for page in 1..=PROJECTS_MAX_PAGES {
        let url = format!(
            "{}{PROJECTS_PATH}?current={page}&pageSize={PROJECTS_PAGE_SIZE}",
            super::api_server()
        );
        let response = match crate::http_request_sync(url, "GET".to_owned(), None, header.clone())
        {
            Ok(response) => response,
            Err(err) => {
                log::warn!("Sense Remote: project list failed: {err}");
                return json!({ "ok": false, "error": "network" }).to_string();
            }
        };
        let (status, body) = match split_http_response(&response) {
            Some(parts) => parts,
            None => return json!({ "ok": false, "error": "retry" }).to_string(),
        };
        if status == 401 || status == 403 {
            return json!({ "ok": false, "error": "token_invalid" }).to_string();
        }
        let Some((total, page_items)) = (status == 200)
            .then(|| parse_projects_page(&body))
            .flatten()
        else {
            return json!({ "ok": false, "error": "retry" }).to_string();
        };
        let last = page_items.len() < PROJECTS_PAGE_SIZE;
        for project in page_items {
            if !all.iter().any(|p| p.id == project.id) {
                all.push(project);
            }
        }
        if last || all.len() >= total {
            break;
        }
    }
    json!({ "ok": true, "projects": all }).to_string()
}

/// `http_request_sync` answers `{"status_code", "headers", "body"}`.
fn split_http_response(response: &str) -> Option<(u16, String)> {
    let value: Value = serde_json::from_str(response).ok()?;
    let status = u16::try_from(value.get("status_code")?.as_u64()?).ok()?;
    let body = value.get("body")?.as_str()?.to_owned();
    Some((status, body))
}

/// One page of `/api/device-group/accessible` (contract `PagedList<ClientDeviceGroup>`). Items
/// without a valid Sense project ID are skipped.
fn parse_projects_page(body: &str) -> Option<(usize, Vec<Project>)> {
    let value: Value = serde_json::from_str(body).ok()?;
    let total = usize::try_from(value.get("total")?.as_u64()?).ok()?;
    let items = value
        .get("data")?
        .as_array()?
        .iter()
        .filter_map(|item| {
            let name = item.get("name")?.as_str()?.trim();
            let id = item.get("sense")?.get("project_id")?.as_str()?;
            (is_project_id(id) && !name.is_empty() && !name.chars().any(char::is_control)).then(
                || Project {
                    id: id.to_owned(),
                    name: name.to_owned(),
                },
            )
        })
        .collect();
    Some((total, items))
}

/// Contract `ProjectId`: `prj_[0-9A-Za-z-]+`, at most 64 characters.
fn is_project_id(id: &str) -> bool {
    let allowed = |b: u8| b.is_ascii_alphanumeric() || b == b'-';
    id.len() <= 64
        && id
            .strip_prefix("prj_")
            .is_some_and(|rest| !rest.is_empty() && rest.bytes().all(allowed))
}

// ---------------------------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------------------------

/// What the wizard sends (`SenseEnrollRequest.toJson` in Dart).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct EnrollInput {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub project_ids: Vec<String>,
    #[serde(default)]
    pub new_projects: Vec<String>,
}

/// This computer as the panel knows it.
#[derive(Debug, Clone)]
struct Identity {
    id: String,
    uuid: String,
    platform: &'static str,
    app_version: u32,
    public_key: Vec<u8>,
}

/// Lower case as the panel compares names (`toLocaleLowerCase("tr")`): I → ı, İ → i.
fn tr_lower(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            'I' => out.push('ı'),
            'İ' => out.push('i'),
            c => out.extend(c.to_lowercase()),
        }
    }
    out
}

/// Body of `POST /api/sense/enroll` (contract v3 `EnrollBody`). Errors are keys the wizard
/// shows (`error-<key>`).
fn enroll_body(input: &EnrollInput, role: SenseRole, me: &Identity) -> Result<Value, &'static str> {
    let name = clean_name(&input.name)?;
    let location = clean_text(&input.location, MAX_LOCATION_CHARS, "invalid-location")?;
    let note = clean_text(&input.note, MAX_NOTE_CHARS, "invalid-note")?;
    let mut project_ids: Vec<String> = Vec::new();
    for id in &input.project_ids {
        let id = id.trim();
        if !is_project_id(id) {
            return Err("invalid-project");
        }
        if !project_ids.iter().any(|p| p == id) {
            project_ids.push(id.to_owned());
        }
    }
    let mut new_projects: Vec<String> = Vec::new();
    for project in &input.new_projects {
        let project = clean_text(project, MAX_PROJECT_CHARS, "invalid-project")?;
        if !project.is_empty()
            && !new_projects
                .iter()
                .any(|p| tr_lower(p) == tr_lower(&project))
        {
            new_projects.push(project);
        }
    }
    if project_ids.len() + new_projects.len() > MAX_PROJECTS {
        return Err("invalid-project");
    }
    if me.id.is_empty() || me.id.len() > 64 || me.uuid.is_empty() || me.uuid.len() > 128 {
        return Err("identity");
    }
    if me.public_key.len() != 32 {
        return Err("identity");
    }
    Ok(json!({
        "v": 1,
        "id": me.id,
        "uuid": me.uuid,
        "role": report::role_name(role),
        "platform": me.platform,
        "app_version": me.app_version,
        "name": name,
        "location": location,
        "note": note,
        "project_ids": project_ids,
        "new_projects": new_projects,
        "device_pk": URL_SAFE_NO_PAD.encode(&me.public_key),
    }))
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
struct EnrolledProject {
    #[serde(default, skip_serializing)]
    project_id: String,
    name: String,
    created: bool,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct EnrollResponse {
    #[allow(dead_code)]
    device_id: String,
    token_revoked: bool,
    projects: Vec<EnrolledProject>,
}

/// Panel answer → result or an error code (`ENROLL_ERRORS`). The panel never answers 5xx on
/// purpose; anything unexpected becomes `retry`.
fn parse_enroll_answer(status: u16, body: &str) -> Result<EnrollResponse, &'static str> {
    if (200..300).contains(&status) {
        return serde_json::from_str(body).map_err(|_| "retry");
    }
    let code = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("error")?.as_str().map(str::to_owned));
    if let Some(known) = code
        .as_deref()
        .and_then(|code| ENROLL_ERRORS.iter().find(|known| **known == code))
    {
        return Err(known);
    }
    Err(match status {
        401 => "token_invalid",
        429 => "rate_limited",
        _ => "retry",
    })
}

/// Whether this computer keeps the sign-in after registration (K-KAYIT-b): a Host never does.
fn keeps_sign_in(role: SenseRole, token_revoked: bool) -> bool {
    role != SenseRole::Host && !token_revoked
}

#[tokio::main(flavor = "current_thread")]
async fn post_json(url: String, body: String, header: String) -> ResultType<(u16, String)> {
    crate::common::post_request_with_status(url, body, &header).await
}

/// Registers this computer. JSON for the wizard: `{"ok": true, "projects": [{name, created}]}`
/// or `{"ok": false, "error": "<code>"}`.
pub fn enroll(input_json: &str) -> String {
    let error = |code: &str| json!({ "ok": false, "error": code }).to_string();
    let Some(role) = installed_role() else {
        return error("not-installed");
    };
    let Some(token) = OidcSession::sense_access_token() else {
        return error("token_invalid");
    };
    let Ok(input) = serde_json::from_str::<EnrollInput>(input_json) else {
        return error("validation");
    };
    let (Some(platform), Some(app_version)) = (report::platform(), report::app_version()) else {
        return error("build");
    };
    let me = Identity {
        id: crate::ui_interface::get_id(),
        uuid: crate::ui_interface::get_uuid(),
        platform,
        app_version,
        public_key: Config::get_key_pair().1,
    };
    let body = match enroll_body(&input, role, &me) {
        Ok(body) => body,
        Err(key) => return error(key),
    };
    let url = format!("{}{ENROLL_PATH}", super::api_server());
    let header = format!("Authorization: Bearer {token}");
    let (status, answer) = match post_json(url, body.to_string(), header) {
        Ok(answer) => answer,
        Err(err) => {
            log::warn!("Sense Remote: registration request failed: {err}");
            return error("network");
        }
    };
    match parse_enroll_answer(status, &answer) {
        Ok(answer) => {
            log::info!("Sense Remote: computer registered with the panel");
            if keeps_sign_in(role, answer.token_revoked) {
                save_sign_in(&token);
            } else {
                forget_sign_in();
            }
            json!({ "ok": true, "projects": answer.projects }).to_string()
        }
        Err(code) => {
            log::warn!("Sense Remote: registration refused: {code} (HTTP {status})");
            error(code)
        }
    }
}

/// Saves the sign-in for the installed app, like `remember_me` in `account.rs`.
fn save_sign_in(token: &str) {
    let Some(user) = OidcSession::sense_user() else {
        return;
    };
    LocalConfig::set_option("access_token".to_owned(), token.to_owned());
    LocalConfig::set_option(
        "user_info".to_owned(),
        json!({
            "name": user.name,
            "display_name": user.display_name,
            "avatar": user.avatar,
            "status": user.status,
        })
        .to_string(),
    );
}

/// Host (K-KAYIT-b): no panel token stays on this computer, not in memory and not in the
/// app's saved sign-in (an earlier Controller sign-in of this Windows user included).
fn forget_sign_in() {
    OidcSession::sense_forget_auth();
    for key in ["access_token", "user_info"] {
        if !LocalConfig::get_option(key).is_empty() {
            LocalConfig::set_option(key.to_owned(), String::new());
        }
    }
}

/// Leaving the wizard: a Host drops the sign-in also when registration was skipped.
pub fn finish() {
    if installed_role() == Some(SenseRole::Host) {
        forget_sign_in();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hbbs_http::account::{AuthBody, UserInfo, UserPayload, UserStatus};

    const API: &str = "https://remote.snsdpt.com";

    fn me() -> Identity {
        Identity {
            id: "123456789".to_owned(),
            uuid: "dXVpZC1vZi10aGlzLXBj".to_owned(),
            platform: "windows-x64",
            app_version: 1,
            public_key: (0u8..32).collect(),
        }
    }

    fn input() -> EnrollInput {
        EnrollInput {
            name: "  Galeri kioskı ".to_owned(),
            location: "Galeri 1".to_owned(),
            note: " 2 ekran ".to_owned(),
            project_ids: vec!["prj_a1".to_owned(), "prj_a1".to_owned(), "prj_B-2".to_owned()],
            new_projects: vec![
                " Yeni Müze ".to_owned(),
                "yeni müze".to_owned(),
                " ".to_owned(),
                "IŞIK".to_owned(),
                "ışık".to_owned(),
            ],
        }
    }

    #[test]
    fn body_matches_the_contract() {
        let body = enroll_body(&input(), SenseRole::Both, &me()).unwrap();
        let keys: Vec<&str> = body.as_object().unwrap().keys().map(String::as_str).collect();
        let mut expected = vec![
            "v", "id", "uuid", "role", "platform", "app_version", "name", "location", "note",
            "project_ids", "new_projects", "device_pk",
        ];
        let mut keys_sorted = keys.clone();
        keys_sorted.sort_unstable();
        expected.sort_unstable();
        assert_eq!(keys_sorted, expected);
        assert_eq!(body["v"], 1);
        assert_eq!(body["id"], "123456789");
        assert_eq!(body["uuid"], "dXVpZC1vZi10aGlzLXBj");
        assert_eq!(body["role"], "host_controller");
        assert_eq!(body["platform"], "windows-x64");
        assert_eq!(body["app_version"], 1);
        assert_eq!(body["name"], "Galeri kioskı");
        assert_eq!(body["location"], "Galeri 1");
        assert_eq!(body["note"], "2 ekran");
        assert_eq!(body["project_ids"], json!(["prj_a1", "prj_B-2"]));
        // Same name in other case (Turkish rules, like the panel) is sent once.
        assert_eq!(body["new_projects"], json!(["Yeni Müze", "IŞIK"]));
    }

    #[test]
    fn device_pk_is_unpadded_base64url_of_32_bytes() {
        let body = enroll_body(&input(), SenseRole::Host, &me()).unwrap();
        let pk = body["device_pk"].as_str().unwrap();
        assert_eq!(pk.len(), 43);
        assert!(pk
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
        assert_eq!(URL_SAFE_NO_PAD.decode(pk).unwrap(), (0u8..32).collect::<Vec<_>>());
        let mut short = me();
        short.public_key.pop();
        assert_eq!(enroll_body(&input(), SenseRole::Host, &short), Err("identity"));
    }

    #[test]
    fn roles_use_contract_names() {
        for (role, name) in [
            (SenseRole::Host, "host"),
            (SenseRole::Controller, "controller"),
            (SenseRole::Both, "host_controller"),
        ] {
            assert_eq!(enroll_body(&input(), role, &me()).unwrap()["role"], name);
        }
    }

    #[test]
    fn body_rejects_bad_input() {
        let mut bad = input();
        bad.name = " ".to_owned();
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-name"));
        let mut bad = input();
        bad.location = "l".repeat(MAX_LOCATION_CHARS + 1);
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-location"));
        let mut bad = input();
        bad.note = "n".repeat(MAX_NOTE_CHARS + 1);
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-note"));
        let too_long = format!("prj_{}", "a".repeat(61));
        for id in ["dev_1", "prj_", "prj_a b", "prj_ä", "PRJ_1", too_long.as_str()] {
            let mut bad = input();
            bad.project_ids = vec![id.to_owned()];
            assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-project"), "{id}");
        }
        let mut bad = input();
        bad.new_projects = vec!["p".repeat(MAX_PROJECT_CHARS + 1)];
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-project"));
        let mut bad = input();
        bad.new_projects = vec!["a\nb".to_owned()];
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-project"));
        let mut bad = input();
        bad.project_ids = (0..6).map(|i| format!("prj_{i}")).collect();
        bad.new_projects = (0..5).map(|i| format!("Yeni {i}")).collect();
        assert_eq!(enroll_body(&bad, SenseRole::Host, &me()), Err("invalid-project"));
        let mut ok = input();
        ok.project_ids = (0..5).map(|i| format!("prj_{i}")).collect();
        ok.new_projects = (0..5).map(|i| format!("Yeni {i}")).collect();
        assert!(enroll_body(&ok, SenseRole::Host, &me()).is_ok());
        let mut no_id = me();
        no_id.id.clear();
        assert_eq!(enroll_body(&input(), SenseRole::Host, &no_id), Err("identity"));
    }

    #[test]
    fn no_project_is_allowed() {
        let mut none = input();
        none.project_ids.clear();
        none.new_projects.clear();
        let body = enroll_body(&none, SenseRole::Controller, &me()).unwrap();
        assert_eq!(body["project_ids"], json!([]));
        assert_eq!(body["new_projects"], json!([]));
    }

    #[test]
    fn wizard_json_is_read_and_unknown_fields_are_ignored() {
        let input: EnrollInput = serde_json::from_str(
            r#"{"name":"K","location":"","note":"","project_ids":["prj_1"],"new_projects":[],"role":"host"}"#,
        )
        .unwrap();
        assert_eq!(input.project_ids, vec!["prj_1"]);
    }

    #[test]
    fn success_answer_is_read() {
        let answer = parse_enroll_answer(
            200,
            r#"{"device_id":"dev_1","token_revoked":true,"projects":[
                {"project_id":"prj_1","name":"Örnek Müze","created":false},
                {"project_id":"prj_2","name":"Yeni Müze","created":true}]}"#,
        )
        .unwrap();
        assert!(answer.token_revoked);
        assert_eq!(answer.projects.len(), 2);
        assert!(answer.projects[1].created);
        // The wizard gets names only (project IDs are not needed on screen).
        let shown = serde_json::to_value(&answer.projects).unwrap();
        assert_eq!(shown[0], json!({"name": "Örnek Müze", "created": false}));
        assert_eq!(parse_enroll_answer(200, "not json"), Err("retry"));
        assert_eq!(parse_enroll_answer(200, r#"{"device_id":"dev_1"}"#), Err("retry"));
    }

    #[test]
    fn error_answers_map_to_codes() {
        for (status, code) in [
            (401, "token_invalid"),
            (403, "install_scope"),
            (403, "device_mismatch"),
            (400, "validation"),
            (404, "project_not_found"),
            (409, "uuid_mismatch"),
            (429, "rate_limited"),
            (400, "retry"),
        ] {
            let body = json!({ "error": code }).to_string();
            assert_eq!(parse_enroll_answer(status, &body), Err(code), "{code}");
        }
        assert_eq!(parse_enroll_answer(401, ""), Err("token_invalid"));
        assert_eq!(parse_enroll_answer(429, "<html>"), Err("rate_limited"));
        assert_eq!(parse_enroll_answer(500, ""), Err("retry"));
        assert_eq!(parse_enroll_answer(502, r#"{"error":"bad_gateway"}"#), Err("retry"));
        assert_eq!(parse_enroll_answer(403, r#"{"error":"something_new"}"#), Err("retry"));
    }

    #[test]
    fn only_controllers_keep_the_sign_in() {
        assert!(!keeps_sign_in(SenseRole::Host, false));
        assert!(!keeps_sign_in(SenseRole::Host, true));
        assert!(keeps_sign_in(SenseRole::Controller, false));
        assert!(keeps_sign_in(SenseRole::Both, false));
        // The panel revoked it: never keep a dead token.
        assert!(!keeps_sign_in(SenseRole::Both, true));
    }

    #[test]
    fn project_pages_are_read() {
        let (total, items) = parse_projects_page(
            r#"{"total":3,"data":[
                {"name":"Örnek Müze","sense":{"project_id":"prj_1","sort_key":"V"}},
                {"name":"Upstream group"},
                {"name":"  ","sense":{"project_id":"prj_2","sort_key":"W"}},
                {"name":"Kötü","sense":{"project_id":"x_3","sort_key":"X"}},
                {"name":"Ekip","sense":{"project_id":"prj_4","sort_key":"Y"}}]}"#,
        )
        .unwrap();
        assert_eq!(total, 3);
        assert_eq!(
            items,
            vec![
                Project { id: "prj_1".to_owned(), name: "Örnek Müze".to_owned() },
                Project { id: "prj_4".to_owned(), name: "Ekip".to_owned() },
            ]
        );
        assert_eq!(parse_projects_page("[]"), None);
        assert_eq!(
            split_http_response(r#"{"status_code":200,"headers":{},"body":"{}"}"#),
            Some((200, "{}".to_owned()))
        );
        assert_eq!(split_http_response("nope"), None);
    }

    fn result() -> AuthResult {
        AuthResult {
            state_msg: String::new(),
            failed_msg: String::new(),
            url: None,
            auth_body: None,
            pairing_code: None,
        }
    }

    fn auth_body(kind: &str) -> AuthBody {
        AuthBody {
            access_token: "panel-issued-test-value".to_owned(),
            r#type: kind.to_owned(),
            tfa_type: String::new(),
            secret: String::new(),
            user: UserPayload {
                name: "ad.soyad@sensedepartment.com".to_owned(),
                display_name: Some("Ad Soyad".to_owned()),
                avatar: None,
                email: None,
                note: None,
                status: UserStatus::Normal,
                info: UserInfo::default(),
                is_admin: false,
                third_auth_type: None,
            },
        }
    }

    #[test]
    fn login_status_states() {
        assert_eq!(login_status_value(&result(), API), json!({"state": "requesting"}));

        let mut waiting = result();
        waiting.url = Some(format!("{API}/panel/istemci-onay/abc"));
        waiting.pairing_code = Some("482913".to_owned());
        assert_eq!(
            login_status_value(&waiting, API),
            json!({"state": "waiting", "url": format!("{API}/panel/istemci-onay/abc"),
                   "pairing_code": "482913"})
        );

        let mut timeout = waiting.clone_for_test();
        timeout.failed_msg = "timeout".to_owned();
        assert_eq!(login_status_value(&timeout, API)["error"], "timeout");
        let mut failed = result();
        failed.failed_msg = "Hesap kapalı".to_owned();
        let value = login_status_value(&failed, API);
        assert_eq!(value["error"], "failed");
        assert_eq!(value["detail"], "Hesap kapalı");
    }

    #[test]
    fn login_status_never_carries_the_token() {
        let mut done = result();
        done.auth_body = Some(auth_body("access_token"));
        let value = login_status_value(&done, API);
        assert_eq!(value["state"], "done");
        assert_eq!(value["user"]["name"], "ad.soyad@sensedepartment.com");
        assert_eq!(value["user"]["display_name"], "Ad Soyad");
        assert!(!value.to_string().contains("panel-issued-test-value"));
        let mut other = result();
        other.auth_body = Some(auth_body("email_check"));
        assert_eq!(login_status_value(&other, API)["state"], "failed");
    }

    #[test]
    fn only_panel_pages_are_opened() {
        for url in [
            "https://evil.test/x",
            "https://remote.snsdpt.com.evil.test/x",
            "https://remote.snsdpt.com",
            "file:///C:/x",
        ] {
            let mut r = result();
            r.url = Some(url.to_owned());
            assert_eq!(login_status_value(&r, API)["state"], "failed", "{url}");
        }
    }

    #[test]
    fn turkish_lower_case() {
        assert_eq!(tr_lower("IŞIK"), "ışık");
        assert_eq!(tr_lower("İzmir"), "izmir");
        assert_eq!(tr_lower("Örnek MÜZE"), "örnek müze");
    }

    impl AuthResult {
        fn clone_for_test(&self) -> AuthResult {
            AuthResult {
                state_msg: self.state_msg.clone(),
                failed_msg: self.failed_msg.clone(),
                url: self.url.clone(),
                auth_body: self.auth_body.clone(),
                pairing_code: self.pairing_code.clone(),
            }
        }
    }
}
