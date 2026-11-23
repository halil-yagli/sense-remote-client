//! Sense Remote (S9-b): ghost mode (privacy mode) without dialogs.
//!
//! RustDesk opens a dialog every time privacy mode turns on or off ("Enter / Exit privacy
//! mode") and for every failure. Sense Remote shows none of them: turning ghost mode on or off
//! is visible in the session itself, and a failure becomes a short status note there. The app
//! gets the note as the `sense_privacy_note` event with one of these codes and writes its own
//! (Turkish) text for it.

use base::message_proto::back_notification::PrivacyModeState;

/// Note code for a privacy mode state; `None` where nothing is to be said (on / off as asked).
pub fn code(state: PrivacyModeState) -> Option<&'static str> {
    use PrivacyModeState::*;
    Some(match state {
        PrvNotSupported => "unsupported",
        PrvOnFailedDenied => "denied",
        PrvOnFailedPlugin | PrvOnFailed => "on_failed",
        PrvOffFailed => "off_failed",
        PrvOffByPeer => "off_by_peer",
        PrvOffUnknown => "off_unknown",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turning_on_or_off_says_nothing() {
        assert_eq!(code(PrivacyModeState::PrvOnSucceeded), None);
        assert_eq!(code(PrivacyModeState::PrvOffSucceeded), None);
        assert_eq!(code(PrivacyModeState::PrvStateUnknown), None);
    }

    #[test]
    fn every_failure_has_a_note() {
        assert_eq!(code(PrivacyModeState::PrvNotSupported), Some("unsupported"));
        assert_eq!(code(PrivacyModeState::PrvOnFailedDenied), Some("denied"));
        assert_eq!(code(PrivacyModeState::PrvOnFailedPlugin), Some("on_failed"));
        assert_eq!(code(PrivacyModeState::PrvOnFailed), Some("on_failed"));
        assert_eq!(code(PrivacyModeState::PrvOffFailed), Some("off_failed"));
        assert_eq!(code(PrivacyModeState::PrvOffByPeer), Some("off_by_peer"));
        assert_eq!(code(PrivacyModeState::PrvOffUnknown), Some("off_unknown"));
    }
}
