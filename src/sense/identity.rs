//! Sense Remote (wave 3 review K3-2): the panel registers the device key that signs.
//!
//! The panel verifies every heartbeat report with the public key sent at registration. The
//! service (`--server`) signs with *its* `Config::get_key_pair()` and sends *its*
//! `Config::get_id()`. The setup process registers its own config's ID and key, which the
//! service only has if `--import-config` copied the setup process's config file. Upstream's
//! import (`core_main::import_config`) silently skips it when:
//! 1. the source is "empty" (`Config::is_empty()`: no RustDesk ID **or** no key pair). The
//!    setup process created the key pair (written by a background thread) but never an ID, so
//!    on a fresh computer the import was skipped: the service made its own ID and key pair;
//! 2. the source is not newer than the service's config file (reinstall: the service's file
//!    is usually newer than the setup user's);
//! 3. the source is not older than the installed executable.
//! The computer then connects, but the panel has another ID / key: every signed report fails
//! (`bad_signature`), roles and "Uygulandı" never arrive.
//!
//! Fix: before installing, the setup process stores its ID and key pair synchronously and
//! marks its config file as just written; the import condition lives here (`import_runs`) and
//! is tested; registration sends the ID and key of that same file.

use hbb_common::base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use std::time::SystemTime;

// Sense Remote (Mac M2, plan 2026-11-21 §3.2): macOS has no `--import-config`. The wizard runs
// one privileged script that creates root's config directory, copies this process's config
// (ID + key pair) into it and compares the copy; `mac_script` is the pure part (script text,
// allowed values, result codes). It is declared here, not in the macOS-only `install_mac`, so
// its tests run on every platform.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub mod mac_script;

/// Whether `--import-config` copies the setup process's config into the service's
/// (upstream rule, used by `core_main::import_config`).
pub fn import_runs(
    source_is_empty: bool,
    source_modified: SystemTime,
    target_modified: SystemTime,
    exe_time: SystemTime,
) -> Result<(), &'static str> {
    if source_is_empty {
        return Err("source has no ID or no key pair");
    }
    if source_modified <= target_modified {
        return Err("source is not newer than the service's config");
    }
    if source_modified >= exe_time {
        return Err("source is not older than the installed executable");
    }
    Ok(())
}

/// Install may start only when the setup process's config file has an ID and a key pair.
/// Sense Remote (Mac M2): macOS uses the same rule before the privileged copy; there it is the
/// whole copy decision (the script always replaces root's config with a complete source,
/// upstream's "newer than" conditions do not apply).
#[cfg_attr(not(any(windows, target_os = "macos")), allow(dead_code))]
pub fn stored_for_import(file_is_empty: bool) -> Result<(), &'static str> {
    if file_is_empty {
        Err("identity-store")
    } else {
        Ok(())
    }
}

/// Sense Remote (Mac M2): polls until the config file on disk is complete. `get_key_pair`
/// writes a new key pair from a background thread, so right after the first start the file
/// can still lack it; copying it then would hand root a config without the registered key.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn wait_stored_for_import(
    tries: u32,
    mut file_is_empty: impl FnMut() -> bool,
    mut pause: impl FnMut(),
) -> Result<(), &'static str> {
    for attempt in 0..tries {
        if stored_for_import(file_is_empty()).is_ok() {
            return Ok(());
        }
        if attempt + 1 < tries {
            pause();
        }
    }
    Err("identity-store")
}

/// Public device key as the panel stores it (`device_pk`); safe to log, it is public.
pub fn public_key_label(public_key: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(public_key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    fn t(s: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(s)
    }

    #[test]
    fn fresh_install_imports_a_complete_source() {
        // No service config yet (`get_modified_time` = UNIX_EPOCH); exe copied after the
        // setup process stored its config (the administrator prompt sits in between).
        assert_eq!(import_runs(false, t(100), UNIX_EPOCH, t(130)), Ok(()));
    }

    #[test]
    fn source_without_id_was_skipped_root_cause() {
        // Before K3-2 the setup process only had a key pair, no ID: `is_empty()`.
        assert!(import_runs(true, t(100), UNIX_EPOCH, t(130)).is_err());
        assert_eq!(stored_for_import(true), Err("identity-store"));
        assert_eq!(stored_for_import(false), Ok(()));
    }

    #[test]
    fn mac_copy_waits_for_the_key_pair_on_disk() {
        // Complete at once: no pause.
        let mut pauses = 0;
        assert_eq!(wait_stored_for_import(30, || false, || pauses += 1), Ok(()));
        assert_eq!(pauses, 0);
        // The background write lands before the third look.
        let mut looks = 0;
        let mut pauses = 0;
        let result = wait_stored_for_import(
            30,
            || {
                looks += 1;
                looks < 3
            },
            || pauses += 1,
        );
        assert_eq!((result, pauses), (Ok(()), 2));
        // Never complete: no copy, and no pause after the last look.
        let mut pauses = 0;
        assert_eq!(
            wait_stored_for_import(30, || true, || pauses += 1),
            Err("identity-store")
        );
        assert_eq!(pauses, 29);
        assert_eq!(wait_stored_for_import(0, || false, || ()), Err("identity-store"));
    }

    #[test]
    fn reinstall_needs_the_source_marked_as_just_written() {
        // Service config written at 500, setup user's file last written at 200: skipped.
        assert!(import_runs(false, t(200), t(500), t(900)).is_err());
        // `sense::install` marks the file as written at 800 (before the exe copy at 900).
        assert_eq!(import_runs(false, t(800), t(500), t(900)), Ok(()));
    }

    #[test]
    fn source_written_after_the_exe_copy_is_skipped() {
        assert!(import_runs(false, t(950), t(500), t(900)).is_err());
        assert!(import_runs(false, t(900), t(500), t(900)).is_err());
    }

    #[test]
    fn key_label_matches_the_panel_encoding() {
        let pk: Vec<u8> = (0u8..32).collect();
        let label = public_key_label(&pk);
        assert_eq!(label.len(), 43);
        assert_eq!(URL_SAFE_NO_PAD.decode(&label).unwrap(), pk);
    }
}
