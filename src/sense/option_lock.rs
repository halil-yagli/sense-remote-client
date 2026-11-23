//! Sense Remote (Sürüm 4, C3; plan 2026-11-23 §2.6): "Panelden yönetilir" — whether a setting is
//! managed by the panel and so locked in the app.
//!
//! Skeleton (D3-0): RustDesk's fixed options (`OVERWRITE_*_SETTINGS`), the same answer as
//! `main_is_option_fixed`. D3e adds the code-level `HARD_SETTINGS` and the keys the signed panel
//! envelope may set (`ALLOWED_OPTIONS`).

/// `main_sense_option_locked`.
pub fn ffi_option_locked(key: &str) -> bool {
    crate::ui_interface::is_option_fixed(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_key_is_not_locked() {
        assert!(!ffi_option_locked("sense-test-no-such-option"));
    }
}
