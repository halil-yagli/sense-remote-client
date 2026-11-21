//! Sense Remote (Mac M0, plan §3.2 / §3.4): state of the three macOS privacy permissions
//! (Screen Recording, Accessibility, Input Monitoring) for the setup wizard (M3), the home
//! screen (M7) and the heartbeat extension `mac_permissions` (M4).
//!
//! M0 is the skeleton only: `current` reports every permission as missing (the safe side: the
//! UI never shows "granted" for something that was not checked). M4 fills it in with the
//! existing checks, without prompting: `platform::macos::is_can_screen_recording(false)`,
//! `is_process_trusted(false)`, `is_can_input_monitoring(false)`.

use serde_derive::{Deserialize, Serialize};

/// Field names are the panel contract (`SenseHeartbeatExt.mac_permissions`) and the JSON of
/// the FFI `main_sense_mac_permissions`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct MacPermissions {
    pub screen_recording: bool,
    pub accessibility: bool,
    pub input_monitoring: bool,
}

/// Permissions of the calling process, read without showing a system prompt.
pub fn current() -> MacPermissions {
    MacPermissions::default()
}

/// `{"screen_recording":bool,"accessibility":bool,"input_monitoring":bool}`.
pub fn to_json(permissions: &MacPermissions) -> String {
    serde_json::to_string(permissions).unwrap_or_else(|_| "{}".to_owned())
}

/// FFI `main_sense_mac_permissions` on macOS.
pub fn current_json() -> String {
    to_json(&current())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_has_the_three_contract_fields() {
        let json = to_json(&MacPermissions {
            screen_recording: true,
            accessibility: false,
            input_monitoring: true,
        });
        assert_eq!(
            json,
            r#"{"screen_recording":true,"accessibility":false,"input_monitoring":true}"#
        );
        let back: MacPermissions = serde_json::from_str(&json).unwrap();
        assert!(back.screen_recording && !back.accessibility && back.input_monitoring);
    }

    #[test]
    fn skeleton_reports_nothing_as_granted() {
        assert_eq!(current(), MacPermissions::default());
    }
}
