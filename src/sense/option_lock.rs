//! Sense Remote (Sürüm 4, C3; plan 2026-11-23 §2.6, TK9 §4): "Panelden yönetilir" — whether a
//! setting is managed by the panel (or by the code) and so locked in the app.
//!
//! A key is locked when any of these holds:
//! (a) RustDesk's fixed options (`OVERWRITE_*_SETTINGS`, `src/sense.rs`
//!     `security_overwrite_settings`): the same answer as `main_is_option_fixed`;
//! (b) the code-level `HARD_SETTINGS` (the installed role's keys: `conn-type`,
//!     `disable-settings`, `disable-ab`);
//! (c) the keys the signed panel envelope may set (`envelope::ALLOWED_OPTIONS` and, since
//!     Sürüm 9, `EXTENDED_OPTIONS` + the `audio-input` option the panel's audio choice becomes,
//!     `envelope::is_panel_option`): only the panel writes them, so the app never offers to
//!     change them;
//! (d) the proxy keys (`sense::SOCKS_OPTION_KEYS`, decision #68 (5)): locked in
//!     `ui_interface::set_socks`, not pinned (a pinned `proxy-url` would turn the proxy on).

use hbb_common::config;

/// Pure: the decision, given what (a) and (b) say for the key and the stored
/// `envelope::OPTION_MANAGED_EXT` (`None` = not stored). An optional Host setting the last
/// envelope did not carry is free (Sürüm 9, K27); it keeps its last value.
pub fn locked(key: &str, fixed: bool, hard: bool, marker: Option<&str>) -> bool {
    fixed
        || hard
        || super::envelope::is_panel_managed(key, marker)
        || (super::SOCKS_LOCKED && super::SOCKS_OPTION_KEYS.contains(&key))
}

/// `main_sense_option_locked`.
pub fn ffi_option_locked(key: &str) -> bool {
    let fixed = crate::ui_interface::is_option_fixed(key);
    let hard = config::HARD_SETTINGS
        .read()
        .map(|hard| hard.contains_key(key))
        .unwrap_or(true);
    let marker = crate::ui_interface::get_option(super::envelope::OPTION_MANAGED_EXT);
    locked(key, fixed, hard, Some(marker.as_str()).filter(|m| !m.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_key_is_not_locked() {
        assert!(!locked("sense-test-no-such-option", false, false, None));
        assert!(!ffi_option_locked("sense-test-no-such-option"));
    }

    #[test]
    fn user_settings_of_the_c3_table_stay_open() {
        for key in [
            "enable-open-new-connections-in-tabs",
            "enable-confirm-closing-tabs",
            "keep-awake-during-outgoing-sessions",
            "allow-sync-clipboard-between-sessions",
            "view_style",
            "image_quality",
            "enable-hwcodec",
            "video-save-directory",
        ] {
            assert!(!locked(key, false, false, None), "{key}");
        }
    }

    #[test]
    fn overwrite_and_hard_keys_are_locked() {
        assert!(locked("api-server", true, false, None));
        assert!(locked("conn-type", false, true, None));
    }

    #[test]
    fn pinned_security_settings_are_locked() {
        // `is_option_fixed` reads the global maps; check the pinned list itself instead, the
        // way `apply_security_settings` writes it.
        for (key, _) in super::super::security_overwrite_settings() {
            assert!(locked(key, true, false, None), "{key}");
        }
        for key in ["enable-lan-discovery", "direct-server", "direct-access-port"] {
            assert!(
                super::super::security_overwrite_settings()
                    .iter()
                    .any(|(k, _)| *k == key),
                "{key}"
            );
        }
    }

    #[test]
    fn panel_envelope_keys_are_locked() {
        for (key, _) in super::super::envelope::ALLOWED_OPTIONS {
            assert!(locked(key, false, false, None), "{key}");
        }
        // The two the C3 table shows: "Hareketsiz bağlantıyı kes" and the Host wallpaper.
        assert!(locked("allow-auto-disconnect", false, false, None));
        assert!(locked("auto-disconnect-timeout", false, false, None));
        assert!(locked("allow-remove-wallpaper", false, false, None));
    }

    // Sürüm 9, paket A: the panel-managed Host settings are locked in the app as well.
    #[test]
    fn extended_host_settings_are_locked() {
        for (key, _) in super::super::envelope::EXTENDED_OPTIONS {
            assert!(locked(key, false, false, None), "{key}");
        }
        for key in [
            "audio-input",
            "keep-awake-during-incoming-sessions",
            "relay-fallback-delay",
            "disable-udp",
        ] {
            assert!(locked(key, false, false, None), "{key}");
        }
        // The macOS daemon keeps its own value for them too (`mac_apply::is_protected_option`).
        for key in ["audio-input", "disable-udp", "keep-awake-during-incoming-sessions"] {
            assert!(super::super::mac_apply::is_protected_option(key), "{key}");
        }
        // Not managed: stays open (the Controller-side counterpart and the user's own settings).
        assert!(!locked("keep-awake-during-outgoing-sessions", false, false, None));
        assert!(!locked("voice-call-input", false, false, None));
    }

    // K27: a setting the panel stopped managing is free again; the others stay locked.
    #[test]
    fn unmanaged_extended_settings_are_free() {
        use crate::sense::envelope::{managed_ext_marker, EXTENDED_OPTIONS};
        use std::collections::BTreeMap;
        let one: BTreeMap<String, String> = [("relay-fallback-delay".to_owned(), "5".to_owned())].into();
        let marker = managed_ext_marker(&one);
        assert_eq!(marker, "v1:relay-fallback-delay");
        assert!(locked("relay-fallback-delay", false, false, Some(&marker)));
        for key in ["audio-input", "keep-awake-during-incoming-sessions", "disable-udp"] {
            assert!(!locked(key, false, false, Some(&marker)), "{key}");
        }
        // No extended key at all: all four are free, the base permissions stay locked.
        let none = managed_ext_marker(&BTreeMap::new());
        assert_eq!(none, "v1:");
        for (key, _) in EXTENDED_OPTIONS {
            assert!(!locked(key, false, false, Some(&none)), "{key}");
        }
        assert!(!locked("audio-input", false, false, Some(&none)));
        assert!(locked("allow-remove-wallpaper", false, false, Some(&none)));
        assert!(locked(crate::sense::envelope::OPTION_MANAGED_EXT, false, false, Some(&none)));
        // The audio choice carries `audio-input` with it.
        let audio: BTreeMap<String, String> = [("sense-audio-input".to_owned(), String::new())].into();
        assert!(locked("audio-input", false, false, Some(&managed_ext_marker(&audio))));
        // Nothing stored yet, or not understood: as before, locked.
        assert!(locked("disable-udp", false, false, None));
        assert!(locked("disable-udp", false, false, Some("junk")));
        // Fixed and hard keys do not depend on the marker.
        assert!(locked("disable-udp", true, false, Some(&none)));
    }

    #[test]
    fn proxy_is_locked() {
        for key in ["proxy-url", "proxy-username", "proxy-password"] {
            assert!(locked(key, false, false, None), "{key}");
        }
    }
}
