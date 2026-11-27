//! Sense Remote (Mac M0 + M4): per-display details on macOS for the panel's display info, the
//! counterpart of `displays_win`.
//!
//! Only raw values are read here; turning them into the panel contract is in `report.rs` (pure
//! functions, tested on every platform because this file is compiled on macOS only).
//!
//! Sources: CoreGraphics for the size and the current mode (refresh rate, backing scale) and
//! `NSScreen` for the monitor name (`localizedName`) and, where the mode reports no refresh
//! rate, `maximumFramesPerSecond`. The functions are declared here, like `displays_win` does,
//! so no crate API has to be relied on.
//!
//! Not read: the connection type (HDMI / DisplayPort; needs extra privileges on macOS, plan
//! §1.2), bit depth, color format, HDR and the panel's native resolution. They are not sent.
//!
//! Sürüm 11 (tarama-mac M6): `NSScreen` belongs to AppKit's main thread; the heartbeat thread
//! reads it through `curtain_mac::screens_on_main` (main thread, short timeout) and not itself.
//!
//! Order: the list is keyed by display id and merged into `scrap::Display::all()` (the list
//! the controller sees) in `report::collect_displays`, so index and order are scrap's. Both
//! use `CGGetOnlineDisplayList`.

use super::report::{self, DisplayDetails};
use std::{collections::HashMap, ffi::c_void};

const MAX_DISPLAYS: usize = 32;
/// How long the heartbeat waits for the main thread to read `NSScreen` (M6).
const SCREENS_TIMEOUT_MS: u32 = 500;
/// kCGErrorSuccess
const CG_SUCCESS: i32 = 0;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGGetOnlineDisplayList(max_displays: u32, displays: *mut u32, count: *mut u32) -> i32;
    // Width / height of the display in the units of `CGDisplayBounds` (points), rotation applied.
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
    fn CGDisplayCopyDisplayMode(display: u32) -> *mut c_void;
    fn CGDisplayModeGetRefreshRate(mode: *mut c_void) -> f64;
    fn CGDisplayModeGetPixelWidth(mode: *mut c_void) -> usize;
    fn CGDisplayModeGetWidth(mode: *mut c_void) -> usize;
    fn CGDisplayModeRelease(mode: *mut c_void);
}

/// What `NSScreen` knows about one display.
struct Screen {
    name: Option<String>,
    max_fps: Option<i64>,
}

/// Ids of the online displays, in the order `scrap::Display::all()` lists them.
fn online_ids() -> Vec<u32> {
    let mut ids = [0u32; MAX_DISPLAYS];
    let mut count: u32 = 0;
    let result =
        unsafe { CGGetOnlineDisplayList(MAX_DISPLAYS as u32, ids.as_mut_ptr(), &mut count) };
    if result != CG_SUCCESS {
        return Vec::new();
    }
    ids[..(count as usize).min(MAX_DISPLAYS)].to_vec()
}

/// `NSScreen` values by display id, read on the main thread. Empty where there is no window
/// server session or the main thread did not answer in time.
fn screens() -> HashMap<u32, Screen> {
    super::curtain_mac::screens_on_main(SCREENS_TIMEOUT_MS)
        .into_iter()
        .take(MAX_DISPLAYS)
        .map(|s| {
            (
                s.display_id,
                Screen {
                    name: s.name,
                    max_fps: s.max_fps,
                },
            )
        })
        .collect()
}

/// Details of every online display, keyed by the name `scrap::Display::name()` returns on
/// macOS (the `CGDirectDisplayID` as a decimal string). Values that can not be read stay
/// `None` and are not sent.
pub fn query() -> HashMap<String, DisplayDetails> {
    let screens = screens();
    let mut out = HashMap::new();
    for display in online_ids() {
        let screen = screens.get(&display);
        let mut details = DisplayDetails {
            name: screen.and_then(|s| s.name.clone()),
            ..Default::default()
        };
        let points = unsafe { (CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)) };
        let mut mode_hz = 0.0;
        let mode = unsafe { CGDisplayCopyDisplayMode(display) };
        if !mode.is_null() {
            unsafe {
                mode_hz = CGDisplayModeGetRefreshRate(mode);
                details.scale = report::mac_scale(
                    CGDisplayModeGetPixelWidth(mode),
                    CGDisplayModeGetWidth(mode),
                );
                CGDisplayModeRelease(mode);
            }
        }
        details.refresh = report::mac_refresh(mode_hz, screen.and_then(|s| s.max_fps));
        details.pixel_size = report::mac_pixel_size(points, details.scale);
        out.insert(display.to_string(), details);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Plan M4 / risk 7: the details are found for every display of the list the controller
    /// sees, and both lists have the same order (a headless runner may have no display at all).
    #[test]
    fn same_displays_and_order_as_scrap() {
        let Ok(list) = scrap::Display::all() else {
            return;
        };
        let scrap_names: Vec<String> = list.iter().map(|d| d.name()).collect();
        let own_names: Vec<String> = online_ids().iter().map(|id| id.to_string()).collect();
        // scrap reads at most 16 displays.
        let n = scrap_names.len().min(own_names.len());
        assert_eq!(scrap_names[..n], own_names[..n]);
        let details = query();
        for name in &scrap_names[..n] {
            assert!(details.contains_key(name), "{name}");
        }
    }

    #[test]
    fn live_values_are_plausible() {
        for (name, d) in query() {
            assert!(name.parse::<u32>().is_ok());
            if let Some(scale) = d.scale {
                assert!((1.0..=4.0).contains(&scale), "{scale}");
            }
            if let Some((numerator, denominator)) = d.refresh {
                assert!(numerator > 0 && denominator == 1000);
            }
            assert!(d.output_technology.is_none() && d.advanced_color.is_none());
        }
    }
}
