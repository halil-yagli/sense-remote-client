//! Sense Remote (Mac M0 + M4, plan §3.2 / §3.4): state of the three macOS privacy permissions
//! (Screen Recording, Accessibility, Input Monitoring) for the setup wizard (M3), the home
//! screen (M7) and the heartbeat extension `mac_permissions` (M4, `report::heartbeat_base`).
//!
//! Read with RustDesk's existing checks and never with a prompt (`prompt = false`), so asking
//! every heartbeat shows nothing on the computer. macOS answers for the calling process: the
//! heartbeat is sent by the `--server` agent, the process that captures the screen and injects
//! input, so the panel sees the permissions that matter for a connection.
//!
//! Known macOS behaviour (to be checked on a device, plan §8): the Screen Recording answer of a
//! running process can stay at its old value until the process restarts; that is why the wizard
//! restarts the agent after the permission is given (`install_sense_restart_agent`).

/// Sense Remote: one definition for the panel contract (`SenseHeartbeatExt.mac_permissions`)
/// and the JSON of the FFI `main_sense_mac_permissions`; it lives in `report.rs` because that
/// file is compiled (and its contract tests run) on every platform.
pub use super::report::MacPermissions;

/// Permissions of the calling process, read without showing a system prompt.
pub fn current() -> MacPermissions {
    use crate::platform::macos;
    MacPermissions {
        screen_recording: macos::is_can_screen_recording(false),
        accessibility: macos::is_process_trusted(false),
        input_monitoring: macos::is_can_input_monitoring(false),
    }
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

    /// Whatever this machine answers, reading does not prompt or panic and the JSON keeps the
    /// contract shape.
    #[test]
    fn live_read_keeps_the_contract_shape() {
        let json = current_json();
        let back: MacPermissions = serde_json::from_str(&json).unwrap();
        assert_eq!(to_json(&back), json);
    }
}
