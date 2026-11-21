//! Sense Remote (Mac M0, plan M4): per-display details on macOS for the panel's display info,
//! the counterpart of `displays_win`.
//!
//! M0 is the skeleton only (empty map, so no display is reported on macOS, as before). M4
//! fills this file in with CoreGraphics (`CGGetActiveDisplayList`, `CGDisplayBounds`,
//! `CGDisplayCopyDisplayMode` for the refresh rate, main display) and calls it from
//! `report::collect_displays`. The connection type (HDMI / DP) can not be read without extra
//! privileges on macOS and is not sent.

use super::report::DisplayDetails;
use std::collections::HashMap;

/// Details of every active display, keyed by the name `scrap::Display::name()` returns on
/// macOS (the `CGDirectDisplayID` as a decimal string), so the list order and index stay
/// those of `scrap::Display::all()` (what the controller sees). Values that can not be read
/// stay `None` and are not sent.
pub fn query() -> HashMap<String, DisplayDetails> {
    HashMap::new()
}

#[cfg(test)]
mod tests {
    #[test]
    fn skeleton_reports_no_display() {
        assert!(super::query().is_empty());
    }
}
