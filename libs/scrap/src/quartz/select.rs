//! Sense Remote (S11, M5): which macOS screen capture backend a capturer uses.
//!
//! RustDesk captures the Mac screen with `CGDisplayStream` (`capturer.rs`), which Apple deprecated
//! in macOS 14; from macOS 15 the system shows a recurring "wants to access your screen" prompt to
//! apps that use the old capture APIs. `sck.rs` adds a ScreenCaptureKit backend. Until it has been
//! tried on the team's Macs (macOS 14 and 15: picture, Retina, several screens, the ghost-mode
//! curtain), the old backend stays the default and the new one is opt-in:
//!
//! `sudo /Applications/SenseRemote.app/Contents/MacOS/SenseRemote --option sense-mac-capture sck`
//! (`auto` = ScreenCaptureKit from macOS 14, `cgds` = the old backend, empty = [`DEFAULT`]).
//!
//! Whatever is chosen, a ScreenCaptureKit failure falls back to `CGDisplayStream`
//! (`common/quartz.rs`): at once when the stream does not start, and for the rest of the process
//! after [`MAX_SCK_FAILURES`] failed streams.
//!
//! Pure and free of other crates: the root crate's unit tests include this file (`#[path]` in
//! `src/sense/mod.rs`), because CI runs only the root crate's tests and never on a Mac.

/// The option (RustDesk `Config` option) that picks the backend.
pub const OPTION: &str = "sense-mac-capture";

/// The capture backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// `CGDisplayStream` (RustDesk's original capturer).
    DisplayStream,
    /// ScreenCaptureKit (`SCStream`).
    ScreenCaptureKit,
}

/// What the option asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preference {
    DisplayStream,
    ScreenCaptureKit,
    /// ScreenCaptureKit from [`AUTO_MIN`], `CGDisplayStream` below it.
    Auto,
}

/// The preference when the option is empty or unknown. Proposed after the device test: `Auto`.
pub const DEFAULT: Preference = Preference::DisplayStream;

/// The first macOS with ScreenCaptureKit display streams.
pub const SCK_MIN: (u32, u32) = (12, 3);

/// The first macOS on which `Auto` uses ScreenCaptureKit: `CGDisplayStream` is deprecated there,
/// and ScreenCaptureKit on 12.x/13.x had known stream bugs.
pub const AUTO_MIN: (u32, u32) = (14, 0);

/// After this many failed ScreenCaptureKit streams in one process, only `CGDisplayStream` is used.
pub const MAX_SCK_FAILURES: u32 = 3;

/// Seconds a new ScreenCaptureKit stream may take to deliver its first picture before it counts
/// as failed (it always sends one complete frame at start, even for a still screen).
pub const FIRST_FRAME_TIMEOUT_SECS: u64 = 3;

/// Parses the option value; `None` for empty or unknown values.
pub fn parse_preference(value: &str) -> Option<Preference> {
    match value.trim().to_ascii_lowercase().as_str() {
        "sck" | "screencapturekit" => Some(Preference::ScreenCaptureKit),
        "cgds" | "displaystream" | "legacy" => Some(Preference::DisplayStream),
        "auto" => Some(Preference::Auto),
        _ => None,
    }
}

/// The backend for a new capturer.
///
/// `os` is the running macOS (major, minor), `sck_supported` whether ScreenCaptureKit could be
/// loaded, `option` the option value, `sck_failures` the failed ScreenCaptureKit streams so far.
pub fn choose(os: (u32, u32), sck_supported: bool, option: &str, sck_failures: u32) -> Backend {
    if !sck_supported || os < SCK_MIN || sck_failures >= MAX_SCK_FAILURES {
        return Backend::DisplayStream;
    }
    match parse_preference(option).unwrap_or(DEFAULT) {
        Preference::ScreenCaptureKit => Backend::ScreenCaptureKit,
        Preference::Auto if os >= AUTO_MIN => Backend::ScreenCaptureKit,
        _ => Backend::DisplayStream,
    }
}

/// Whether a ScreenCaptureKit stream has failed: it stopped, or no first picture came in time.
pub fn sck_failed(stopped: bool, got_frame: bool, elapsed_secs: u64) -> bool {
    stopped || (!got_frame && elapsed_secs >= FIRST_FRAME_TIMEOUT_SECS)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SONOMA: (u32, u32) = (14, 5);
    const SEQUOIA: (u32, u32) = (15, 1);

    #[test]
    fn default_keeps_the_old_backend_until_the_device_test() {
        assert_eq!(DEFAULT, Preference::DisplayStream);
        assert_eq!(choose(SEQUOIA, true, "", 0), Backend::DisplayStream);
        assert_eq!(choose(SONOMA, true, "bilinmeyen", 0), Backend::DisplayStream);
    }

    #[test]
    fn option_turns_screencapturekit_on() {
        assert_eq!(choose(SEQUOIA, true, "sck", 0), Backend::ScreenCaptureKit);
        assert_eq!(choose(SONOMA, true, " SCK ", 0), Backend::ScreenCaptureKit);
        assert_eq!(choose((12, 3), true, "screencapturekit", 0), Backend::ScreenCaptureKit);
        assert_eq!(choose(SEQUOIA, true, "cgds", 0), Backend::DisplayStream);
        assert_eq!(choose(SEQUOIA, true, "legacy", 0), Backend::DisplayStream);
    }

    #[test]
    fn auto_uses_screencapturekit_from_macos_14() {
        assert_eq!(choose((13, 6), true, "auto", 0), Backend::DisplayStream);
        assert_eq!(choose((14, 0), true, "auto", 0), Backend::ScreenCaptureKit);
        assert_eq!(choose(SEQUOIA, true, "auto", 0), Backend::ScreenCaptureKit);
        assert_eq!(choose((26, 0), true, "auto", 0), Backend::ScreenCaptureKit);
    }

    #[test]
    fn no_screencapturekit_below_12_3_or_when_it_cannot_load() {
        assert_eq!(choose((12, 2), true, "sck", 0), Backend::DisplayStream);
        assert_eq!(choose((11, 7), true, "sck", 0), Backend::DisplayStream);
        assert_eq!(choose(SEQUOIA, false, "sck", 0), Backend::DisplayStream);
    }

    #[test]
    fn repeated_failures_fall_back_for_the_process() {
        assert_eq!(choose(SEQUOIA, true, "sck", MAX_SCK_FAILURES - 1), Backend::ScreenCaptureKit);
        assert_eq!(choose(SEQUOIA, true, "sck", MAX_SCK_FAILURES), Backend::DisplayStream);
        assert_eq!(choose(SEQUOIA, true, "auto", 99), Backend::DisplayStream);
    }

    #[test]
    fn stream_failure_rule() {
        assert!(!sck_failed(false, false, 0));
        assert!(!sck_failed(false, false, FIRST_FRAME_TIMEOUT_SECS - 1));
        assert!(sck_failed(false, false, FIRST_FRAME_TIMEOUT_SECS));
        // A still screen sends no new pictures after the first one: not a failure.
        assert!(!sck_failed(false, true, 3600));
        assert!(sck_failed(true, true, 0));
    }
}
