//! Sense Remote (Sürüm 4, S4 / H2; plan 2026-11-23 §2.6): changing this computer's role from the
//! app. Flow (D3b): Sense sign-in with purpose `role` → `POST /api/sense/role-change` → the
//! strategy envelope the panel answers goes to `--server` through the existing `envelope_apply`
//! path, which writes the role (HKLM / state.json) and restarts; the role reaches the panel with
//! the next heartbeat. The user can never write the role by hand.
//!
//! Skeleton (D3-0): every call answers `unsupported`; nothing changes.

use serde_json::{json, Value};

const UNSUPPORTED: &str = "unsupported";

/// `main_sense_role_status`: `{roles: [..], pending: null | {target, stage}, error}`.
pub fn ffi_role_status() -> String {
    json!({ "roles": [], "pending": Value::Null, "error": UNSUPPORTED }).to_string()
}

/// `main_sense_role_change_begin`: starts the sign-in for `target` ("host" / "controller" /
/// "host_controller"); later `{pairing_code, url, expires_at}`.
pub fn ffi_role_change_begin(_target: &str) -> String {
    json!({ "error": UNSUPPORTED }).to_string()
}

/// `main_sense_role_change_status`: `{stage, error: null | "admin_denied" | "role_change_denied" |
/// "last_role" | "timeout" | "network"}`.
pub fn ffi_role_change_status() -> String {
    json!({ "stage": Value::Null, "error": UNSUPPORTED }).to_string()
}

/// `main_sense_role_change_cancel`.
pub fn ffi_role_change_cancel() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    #[test]
    fn skeleton_answers_unsupported_and_changes_nothing() {
        let status = parse(&ffi_role_status());
        assert_eq!(status["roles"], json!([]));
        assert!(status["pending"].is_null());
        assert_eq!(status["error"], UNSUPPORTED);
        assert_eq!(parse(&ffi_role_change_begin("controller"))["error"], UNSUPPORTED);
        let change = parse(&ffi_role_change_status());
        assert!(change["stage"].is_null());
        assert_eq!(change["error"], UNSUPPORTED);
        ffi_role_change_cancel();
    }
}
