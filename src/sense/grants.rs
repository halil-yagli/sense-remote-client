//! Sense Remote (Sürüm 4, S11 app side; plan 2026-11-23 §2.6): the signed per-person permission
//! envelope ("grants") the panel gives a signed-in Controller. The session buttons and the
//! Controller screens read it to lock what this person may not do.
//!
//! Skeleton (D3-0): no envelope is read yet, so the answer is `missing` and every permission is
//! off (the safe side). D3a verifies the envelope (prefix, device, e-mail, `rev`, expiry), keeps
//! `grants.json` up to date and fills these bodies.

use serde_json::{json, Value};

/// `main_sense_grants`: `{state: "ok" | "missing" | "expired" | "invalid", perms: [..], email,
/// rev}`.
pub fn ffi_grants() -> String {
    missing().to_string()
}

/// `main_sense_grants_refresh`: asks the panel at once (`GET /api/sense/grants`). Nothing to ask
/// before D3a.
pub fn ffi_grants_refresh() {}

/// No envelope: nothing is allowed.
fn missing() -> Value {
    json!({ "state": "missing", "perms": [], "email": "", "rev": 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn without_an_envelope_everything_is_off() {
        let value: Value = serde_json::from_str(&ffi_grants()).unwrap();
        assert_eq!(value["state"], "missing");
        assert_eq!(value["perms"], json!([]));
        assert_eq!(value["email"], "");
        assert_eq!(value["rev"], 0);
        ffi_grants_refresh();
    }
}
