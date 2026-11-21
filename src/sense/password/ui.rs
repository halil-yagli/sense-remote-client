//! Sense Remote (permanent password plan §3.7, U10): UI-process side of the seven FFI calls. The
//! grant is held in memory only and dropped after `Set` and when it expires; the Controller's
//! saved app sign-in is not touched. Every answer is JSON or a code; no password, token or key
//! is ever returned. U9: the safe defaults (`unsupported`).

use crate::sense::SenseRole;
use serde_json::{json, Value};

/// `main_sense_password_status`.
pub fn status() -> String {
    status_value(super::SUPPORTED, crate::sense::installed_role()).to_string()
}

fn role_name(role: Option<SenseRole>) -> &'static str {
    match role {
        Some(SenseRole::Host) => "host",
        Some(SenseRole::Both) => "both",
        Some(SenseRole::Controller) => "controller",
        None => "none",
    }
}

/// Pure part of `status`. U9: nothing is known yet (`perm_set` null), always locked.
fn status_value(supported: bool, role: Option<SenseRole>) -> Value {
    json!({
        "supported": supported,
        "role": role_name(role),
        "perm_set": null,
        "changed_at": null,
        "stage": "locked",
        "until": null,
        "user": null,
    })
}

/// `main_sense_password_begin`.
pub fn begin() -> String {
    json!({"ok": false, "error": super::UNSUPPORTED}).to_string()
}

/// `main_sense_password_login_status` (same shape as the setup sign-in).
pub fn login_status() -> String {
    json!({"state": "failed", "error": super::UNSUPPORTED}).to_string()
}

/// `main_sense_password_unlock`.
pub fn unlock() -> String {
    json!({"ok": false, "error": super::UNSUPPORTED}).to_string()
}

/// `main_sense_password_check`: "" or a rule code (hint only; the privileged process decides).
pub fn check(password: &str) -> String {
    match super::rule::check(password, &hbb_common::config::Config::get_id()) {
        Ok(()) => String::new(),
        Err(code) => code.to_owned(),
    }
}

/// `main_sense_password_set`: "" or an error code.
pub fn set(password: String) -> String {
    let _ = super::SensePasswordSecret::new(password);
    super::UNSUPPORTED.to_owned()
}

/// `main_sense_password_cancel`.
pub fn cancel() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_while_off() {
        for (role, name) in [
            (None, "none"),
            (Some(SenseRole::Host), "host"),
            (Some(SenseRole::Both), "both"),
            (Some(SenseRole::Controller), "controller"),
        ] {
            let value = status_value(false, role);
            assert_eq!(value["supported"], false);
            assert_eq!(value["role"], name);
            assert_eq!(value["stage"], "locked");
            assert!(value["perm_set"].is_null());
        }
    }

    #[test]
    fn every_call_is_unsupported_while_off() {
        let begin: Value = serde_json::from_str(&begin()).unwrap();
        assert_eq!(begin, json!({"ok": false, "error": "unsupported"}));
        let unlock: Value = serde_json::from_str(&unlock()).unwrap();
        assert_eq!(unlock["ok"], false);
        assert_eq!(set("Deneme-Sifre-12".to_owned()), "unsupported");
    }
}
