//! Sense Remote (update plan 2026-11-21, §8): the one-time manual move from version 2, which
//! has no updater. Package U7.
//!
//! - Windows: the new setup file sees an older installed version
//!   (`super::installed_version`), shows the short "Güncelleme" screen and, after the Windows
//!   administrator prompt, runs itself with `--sense-upgrade-local` (`apply_win::upgrade_local`:
//!   backup + guard + `update_me`, `source = manual`).
//! - macOS: after the new app was dragged over the old one, "Sürüm 3'e geçişi tamamla": an
//!   administrator prompt, `chown -R root:wheel` + `chmod -R go-w` (G4-1), daemon and agent
//!   `kickstart -k`, then the permissions step.
//! - No sign-in and no registration on either platform: `enroll` is never called, the ID, the
//!   device key and the role stay. Never a downgrade.

/// Result codes of `upgrade_in_place` (FFI `install_sense_upgrade_in_place`).
pub const OK: &str = "";
pub const CANCELLED: &str = "cancelled";
pub const NOT_INSTALLED: &str = "not_installed";
pub const NOT_NEWER: &str = "not_newer";
pub const FAILED: &str = "failed";

/// Runs the manual move from the setup screen and returns one of the codes above.
/// U0: nothing is done, `failed`.
pub fn upgrade_in_place() -> String {
    FAILED.to_owned()
}
