//! Sense Remote (Sürüm 12, #169, plan 2026-11-28 §2.2, §2.4): the employee's own settings
//! ("kişiye özel ayarlar") kept by the panel (`GET/PUT /api/sense/prefs`): favourites, key
//! bindings, recent items, view preferences. Skeleton from ÇK-0; FAV-Ç fills it.
//!
//! Rules for FAV-Ç (contract): read from the local cache first, then the panel; offline writes
//! go to the cache and a pending queue and are sent with `base_rev` later; on 409 the panel value
//! wins. The cache file is per employee, deleted at sign-out, and holds preferences only (never a
//! key or token). Window position, audio devices and the recording folder stay on the computer.

/// Flutter session-less event when the stored preferences changed (after a sync).
pub const EV_PREFS_CHANGED: &str = "sense_prefs_changed";

/// `main_sense_prefs_get(os)`: `{entries, custom}` from the cache; for now `unsupported`.
pub fn ffi_get(os: &str) -> String {
    let _ = os;
    super::peer_msg::UNSUPPORTED_JSON.to_owned()
}

/// `main_sense_prefs_set(json)`: "" when stored; for now `unsupported`.
pub fn ffi_set(json: &str) -> String {
    let _ = json;
    "unsupported".to_owned()
}

/// `main_sense_custom_shortcut_request(json)`: the request id as JSON; for now `unsupported`.
pub fn ffi_custom_shortcut_request(json: &str) -> String {
    let _ = json;
    super::peer_msg::UNSUPPORTED_JSON.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_answers_unsupported() {
        let v: serde_json::Value = serde_json::from_str(&ffi_get("win")).unwrap();
        assert_eq!(v["error"], "unsupported");
        assert_eq!(ffi_set("{}"), "unsupported");
        let v: serde_json::Value = serde_json::from_str(&ffi_custom_shortcut_request("{}")).unwrap();
        assert_eq!(v["error"], "unsupported");
    }
}
