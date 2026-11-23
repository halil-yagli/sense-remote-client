//! Sense Remote (Sürüm 4, C3; plan 2026-11-23 §2.6, TK9 §4): "Panelden yönetilir" — whether a
//! setting is managed by the panel (or by the code) and so locked in the app.
//!
//! A key is locked when any of these holds:
//! (a) RustDesk's fixed options (`OVERWRITE_*_SETTINGS`, `src/sense.rs`
//!     `security_overwrite_settings`): the same answer as `main_is_option_fixed`;
//! (b) the code-level `HARD_SETTINGS` (the installed role's keys: `conn-type`,
//!     `disable-settings`, `disable-ab`);
//! (c) the keys the signed panel envelope may set (`envelope::ALLOWED_OPTIONS`): only the panel
//!     writes them, so the app never offers to change them;
//! (d) the proxy keys (`sense::SOCKS_OPTION_KEYS`, decision #68 (5)): locked in
//!     `ui_interface::set_socks`, not pinned (a pinned `proxy-url` would turn the proxy on).

use hbb_common::config;

/// Pure: the decision, given what (a) and (b) say for the key.
pub fn locked(key: &str, fixed: bool, hard: bool) -> bool {
    fixed
        || hard
        || super::envelope::ALLOWED_OPTIONS
            .iter()
            .any(|(allowed, _)| *allowed == key)
        || (super::SOCKS_LOCKED && super::SOCKS_OPTION_KEYS.contains(&key))
}

/// `main_sense_option_locked`.
pub fn ffi_option_locked(key: &str) -> bool {
    let fixed = crate::ui_interface::is_option_fixed(key);
    let hard = config::HARD_SETTINGS
        .read()
        .map(|hard| hard.contains_key(key))
        .unwrap_or(true);
    locked(key, fixed, hard)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_key_is_not_locked() {
        assert!(!locked("sense-test-no-such-option", false, false));
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
            assert!(!locked(key, false, false), "{key}");
        }
    }

    #[test]
    fn overwrite_and_hard_keys_are_locked() {
        assert!(locked("api-server", true, false));
        assert!(locked("conn-type", false, true));
    }

    #[test]
    fn pinned_security_settings_are_locked() {
        // `is_option_fixed` reads the global maps; check the pinned list itself instead, the
        // way `apply_security_settings` writes it.
        for (key, _) in super::super::security_overwrite_settings() {
            assert!(locked(key, true, false), "{key}");
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
            assert!(locked(key, false, false), "{key}");
        }
        // The two the C3 table shows: "Hareketsiz bağlantıyı kes" and the Host wallpaper.
        assert!(locked("allow-auto-disconnect", false, false));
        assert!(locked("auto-disconnect-timeout", false, false));
        assert!(locked("allow-remove-wallpaper", false, false));
    }

    #[test]
    fn proxy_is_locked() {
        for key in ["proxy-url", "proxy-username", "proxy-password"] {
            assert!(locked(key, false, false), "{key}");
        }
    }
}
