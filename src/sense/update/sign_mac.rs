//! Sense Remote (update plan 2026-11-21, §7): how the installed app is signed. Package U4.
//!
//! macOS keeps the privacy permissions (Screen Recording, Accessibility, Input Monitoring) of
//! an app only while a new version satisfies the designated requirement of the old one. An
//! ad-hoc signature is tied to one build, so every ad-hoc update loses them; a build signed
//! with the team's permanent self-signed certificate is expected to keep them (checked on a
//! device, §14). The panel and the app warn before updating a Mac Host unless `sign` is `cert`.
//!
//! U4 reads the kind from the running code's signature (`SecCode` flags: ad-hoc or not).
//! `extern "C"` declarations must use C types only: the bridge generator copies them into
//! `bridge_generated.h`.
//! MAC-SONRA: checked on a device.

use super::SignKind;

/// `sign` of the heartbeat's `update`. Windows: always `none`. U0: `unknown` elsewhere.
pub fn sign_kind() -> SignKind {
    if cfg!(windows) {
        SignKind::Unsigned
    } else {
        SignKind::Unknown
    }
}
