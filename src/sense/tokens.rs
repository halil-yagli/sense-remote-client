//! Sense Remote: design values the Rust side draws with (the maintenance curtain).
//!
//! Sense Remote: tokens.json T1 — these copy the design values (`design/tokens.json`, roadmap
//! T1 / H5) until the token generator also writes a Rust file; change them there first.
// Only the Windows curtain draws with them (MAC-SONRA-15).
#![cfg_attr(not(windows), allow(dead_code))]

/// Watched screen logo on the curtain (H5): green #00FFB6.
pub const WATCHED_GREEN: (u8, u8, u8) = (0x00, 0xFF, 0xB6);
/// Logo of a screen nobody watches: white.
pub const UNWATCHED_WHITE: (u8, u8, u8) = (0xFF, 0xFF, 0xFF);
/// Glow around the green logo, in px on a 1080 px screen (H5: 14 px).
pub const WATCHED_GLOW_PX: f32 = 14.0;
/// White ↔ green colour transition (H5: 0.4 s).
pub const WATCHED_TRANSITION_MS: u32 = 400;
