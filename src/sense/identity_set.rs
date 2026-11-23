//! Sense Remote (Sürüm 4, S3 / H1; plan 2026-11-23 §2.6): the computer's name and location,
//! changed on the Host. Flow (D3c): UI → IPC → `--server` writes HKLM `Setup` / macOS state.json
//! and sends the signed `POST /api/sense/device-info`; the location list comes from the
//! heartbeat answer (`sense.locations`).
//!
//! Skeleton (D3-0): no list and nothing saved; every call answers `unsupported`.

use serde_json::{json, Value};

const UNSUPPORTED: &str = "unsupported";

/// `main_sense_identity`: `{name, location_id, location_name, locations: [{id, name}], panel:
/// "ok" | "unreachable"}`.
pub fn ffi_identity() -> String {
    json!({
        "name": "",
        "location_id": "",
        "location_name": "",
        "locations": [],
        "panel": Value::Null,
        "error": UNSUPPORTED,
    })
    .to_string()
}

/// `main_sense_identity_set`: `{ok: true}` or `{error: "invalid" | "network" |
/// "location_not_in_project"}`.
pub fn ffi_identity_set(_name: &str, _location_id: &str) -> String {
    json!({ "error": UNSUPPORTED }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_has_no_list_and_saves_nothing() {
        let identity: Value = serde_json::from_str(&ffi_identity()).unwrap();
        assert_eq!(identity["locations"], json!([]));
        assert_eq!(identity["name"], "");
        assert_eq!(identity["error"], UNSUPPORTED);
        let set: Value = serde_json::from_str(&ffi_identity_set("Kiosk", "loc_1")).unwrap();
        assert_eq!(set, json!({ "error": UNSUPPORTED }));
    }
}
