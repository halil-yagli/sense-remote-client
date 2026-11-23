//! Sense Remote (Sürüm 4, C5 / H6; plan 2026-11-23 §2.6 and "Ek"): data for the tray menu and the
//! operating-system notification of a new chat message.
//! - D3e: the Controller's last 3 connections; the Host's menu has only "Aç".
//! - D3e (Ek, #62): a real Windows / macOS notification instead of the in-app card.
//!
//! Skeleton (D3-0): no recent connections, no notification (`unsupported`).

/// `main_sense_tray_recent`: `[{peer_id, name, at}]`, newest first, at most 3.
pub fn ffi_tray_recent() -> String {
    "[]".to_owned()
}

/// `main_sense_notify`: "" when the system showed the notification, otherwise a code
/// (`unsupported` until D3e; the UI keeps its in-app card).
pub fn ffi_notify(_title: &str, _body: &str) -> String {
    "unsupported".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_has_no_recent_list_and_no_notification() {
        let recent: serde_json::Value = serde_json::from_str(&ffi_tray_recent()).unwrap();
        assert_eq!(recent, serde_json::json!([]));
        assert_eq!(ffi_notify("Sense Remote", "Yeni mesaj"), "unsupported");
    }
}
