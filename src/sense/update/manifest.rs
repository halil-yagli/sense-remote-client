//! Sense Remote (update plan 2026-11-21, §3.1–§3.3): the signed release notice and the build
//! statement inside it. Package U1 implements `verify`; pure, no clock, no globals.
//!
//! Transport is the envelope's `{k, p, s}`: `k` = first 8 bytes of SHA-256(raw public key) as
//! hex, `p` = payload bytes as unpadded base64url (at most `MAX_SIGNED_P_CHARS`), `s` = 64-byte
//! Ed25519 signature as base64url. Signed data = prefix ‖ the bytes of `p`. The payload is not
//! canonicalised again, but the bytes of `p` MUST be JCS (RFC 8785) canonical JSON (bytes =
//! canonical(decoded value)): a BOM, a duplicate or unsorted key, whitespace, `3.0` / `1e7`
//! forms, a needless escape or a lone surrogate is `bad_payload`. Payloads are strict
//! (`deny_unknown_fields` at every level); every limit is the panel's
//! (`packages/shared/src/release.ts`).
//!
//! Order of the checks (plan §3.3; the panel's `verifyRelease` follows steps 0–11 too):
//!  0. the panel and build key lists overlap (same `k` or same public key) → `keys_overlap`
//!     (the two-signature rule must not collapse into one)
//!  1. shape `{k,p,s}`, `p` ≤ 8192 characters → `malformed`
//!  2. `k` is a panel key → `unknown_key`
//!  3. strict base64url, 64-byte signature → `malformed`
//!  4. Ed25519 with `RELEASE_SIGNING_PREFIX` → `bad_signature`
//!  5. JCS canonical JSON + schema (including `iat ≤ exp ≤ iat + RELEASE_TTL_S`) → `bad_payload`
//!  6. `iss` → `wrong_issuer`
//!  7. `iat - 300 ≤ now ≤ exp + 300` (local clock) → `not_yet_valid` / `expired`
//!  8. `platform` is this build's → `wrong_platform`
//!  9. `file == installer_file_name(version, platform)` and
//!     `url == api_server + "/indir/" + file`; `notes_url`, when given,
//!     `== api_server + "/#surum-" + version` (all compared as raw strings, whole string; no
//!     URL parser, no normalising) → `bad_url`
//! 10. `build`: `k` is a build key (`build_unknown_key`), signature with `BUILD_SIGNING_PREFIX`
//!     (`build_bad_signature`), canonical JSON + `BuildStatement` schema (`build_bad_payload`)
//! 11. `build` equals the notice in `version`, `platform`, `file`, `sha256`, `size`
//!     → `build_mismatch`
//! 12. not newer than the installed version: ignored silently, not an error. This step is
//!     `Release::is_newer_than`, so that `verify` stays identical to the panel's.
//!
//! A rejected notice changes nothing; the reason goes to the heartbeat as
//! `update.error = manifest_invalid` + `error_detail = <reason>`.

use crate::sense::envelope_keys::TrustedKey;
use serde_json::Value;

/// Domain separation (§3.1): signed data = prefix (ASCII) ‖ payload bytes.
pub const RELEASE_SIGNING_PREFIX: &[u8] = b"sense-remote/release/v1\n";
pub const BUILD_SIGNING_PREFIX: &[u8] = b"sense-remote/build/v1\n";
/// `RELEASE_TTL_S`: `exp = iat + 7 days`.
pub const RELEASE_TTL_S: i64 = 7 * 86_400;
/// `MAX_INSTALLER_BYTES`: 512 MiB.
pub const MAX_INSTALLER_BYTES: u64 = 536_870_912;
/// `MAX_SIGNED_P_CHARS`: limit of `p` for all three signed kinds.
pub const MAX_SIGNED_P_CHARS: usize = 8_192;
/// `MAX_URL_CHARS`: `url` / `notes_url` start with `http://` or `https://`, are printable ASCII
/// (0x21–0x7E) only and at most this long.
pub const MAX_URL_CHARS: usize = 2_048;
/// `MAX_UNIX_SECONDS`: time fields are 0..=this (a time written in milliseconds fails the schema).
pub const MAX_UNIX_SECONDS: i64 = 9_999_999_999;
/// `MAX_RUN_ID`: 2^53 − 1.
pub const MAX_RUN_ID: u64 = 9_007_199_254_740_991;
/// `RELEASE_CLOCK_SKEW_S`: allowed clock difference for `iat` / `exp`, seconds (as for envelopes).
pub const CLOCK_SKEW_S: i64 = 300;
/// The only place installers are downloaded from: `api_server + DOWNLOAD_PATH + file`.
pub const DOWNLOAD_PATH: &str = "/indir/";
/// The only form of `notes_url`: `api_server + NOTES_ANCHOR + version`.
pub const NOTES_ANCHOR: &str = "/#surum-";
pub const PLATFORM_WINDOWS: &str = "windows-x64";
pub const PLATFORM_MACOS: &str = "macos-arm64";

wire_enum!(
    /// Why a release notice or an order was refused (§3.3), in the order of the checks: the
    /// panel's `ReleaseRejectReason`, then the names only `UpdateOrderRejectReason` has. The
    /// names are reported as `error_detail` (`^[a-z_]{1,32}$`). `keys_overlap`,
    /// `wrong_platform`, `bad_url` and the four `build_*` are only produced for notices; the
    /// last four (`wrong_device`, `version_mismatch`, `release_mismatch`, `downgrade`) only for
    /// orders.
    Reason {
        KeysOverlap => "keys_overlap",
        Malformed => "malformed",
        UnknownKey => "unknown_key",
        BadSignature => "bad_signature",
        BadPayload => "bad_payload",
        WrongIssuer => "wrong_issuer",
        NotYetValid => "not_yet_valid",
        Expired => "expired",
        WrongPlatform => "wrong_platform",
        BadUrl => "bad_url",
        BuildUnknownKey => "build_unknown_key",
        BuildBadSignature => "build_bad_signature",
        BuildBadPayload => "build_bad_payload",
        BuildMismatch => "build_mismatch",
        WrongDevice => "wrong_device",
        VersionMismatch => "version_mismatch",
        ReleaseMismatch => "release_mismatch",
        Downgrade => "downgrade",
    }
);

/// `BuildStatement` (§3.2): what the tag build signed with the build key for one installer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildStatement {
    /// Key id of the build key that signed it.
    pub k: String,
    pub version: u32,
    pub platform: String,
    pub file: String,
    pub sha256: String,
    pub size: u64,
    /// The tagged commit, 40 hex characters.
    pub commit: String,
    /// GitHub Actions run, for tracing only.
    pub run_id: u64,
    pub iat: i64,
}

/// A verified `ReleasePayload` (§3.2), steps 0–11 passed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    /// Key id of the panel key that signed it.
    pub k: String,
    pub version: u32,
    pub platform: String,
    pub file: String,
    pub url: String,
    /// Lowercase hex.
    pub sha256: String,
    pub size: u64,
    pub notes_url: Option<String>,
    pub published_at: i64,
    pub iat: i64,
    pub exp: i64,
    pub build: BuildStatement,
}

impl Release {
    /// Step 12: only a version above the installed one is offered or installed.
    pub fn is_newer_than(&self, installed: u32) -> bool {
        self.version > installed
    }
}

/// What this computer expects; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    /// Panel host, `envelope::expected_issuer()`.
    pub iss: &'a str,
    /// `sense::API_SERVER` of this build, without a trailing slash.
    pub api_server: &'a str,
    /// `report::platform()` of this build.
    pub platform: &'a str,
    /// Local clock, Unix seconds (never the server's time).
    pub now_s: i64,
}

/// Steps 0–11. `panel_keys` = `keys::panel_keys()`, `build_keys` = `keys::release_keys()`.
/// U0: nothing is trusted yet, every notice is refused.
pub fn verify(
    release: &Value,
    panel_keys: &[TrustedKey],
    build_keys: &[TrustedKey],
    expect: &Expect,
) -> Result<Release, Reason> {
    let _ = (release, panel_keys, build_keys, expect);
    Err(Reason::UnknownKey)
}

/// `installerFileName` of the site (`apps/site/src/config/downloads.ts`): the one file name a
/// version has on a platform. `None` for another platform or a version outside 1..=999_999.
pub fn installer_file_name(version: u32, platform: &str) -> Option<String> {
    if version == 0 || version > super::MAX_VERSION {
        return None;
    }
    match platform {
        PLATFORM_WINDOWS => Some(format!("SenseRemote-Kurulum-{version}.exe")),
        PLATFORM_MACOS => Some(format!("SenseRemote-{version}.dmg")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefixes_separate_the_domains() {
        let envelope = crate::sense::envelope::SIGNING_PREFIX;
        let order = crate::sense::update::order::UPDATE_ORDER_SIGNING_PREFIX;
        let all = [envelope, RELEASE_SIGNING_PREFIX, order, BUILD_SIGNING_PREFIX];
        assert_eq!(RELEASE_SIGNING_PREFIX, b"sense-remote/release/v1\n");
        assert_eq!(BUILD_SIGNING_PREFIX, b"sense-remote/build/v1\n");
        assert_eq!(order, b"sense-remote/update-order/v1\n");
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert!(!a.starts_with(b) && !b.starts_with(a));
            }
        }
    }

    #[test]
    fn reason_names_fit_error_detail() {
        for reason in Reason::ALL {
            let name = reason.as_str();
            assert!(name.len() <= 32, "{name}");
            assert!(name.bytes().all(|b| b == b'_' || b.is_ascii_lowercase()), "{name}");
        }
    }

    #[test]
    fn installer_file_names() {
        assert_eq!(
            installer_file_name(3, PLATFORM_WINDOWS).as_deref(),
            Some("SenseRemote-Kurulum-3.exe")
        );
        assert_eq!(
            installer_file_name(999_999, PLATFORM_MACOS).as_deref(),
            Some("SenseRemote-999999.dmg")
        );
        assert_eq!(installer_file_name(0, PLATFORM_WINDOWS), None);
        assert_eq!(installer_file_name(1_000_000, PLATFORM_WINDOWS), None);
        assert_eq!(installer_file_name(3, "linux-x64"), None);
    }

    // U0: fail closed until U1 verifies.
    #[test]
    fn skeleton_refuses_every_notice() {
        let expect = Expect {
            iss: "panel.example",
            api_server: "https://panel.example",
            platform: PLATFORM_WINDOWS,
            now_s: 1_795_000_000,
        };
        let notice = serde_json::json!({ "k": "0000000000000000", "p": "e30", "s": "x" });
        assert_eq!(verify(&notice, &[], &[], &expect), Err(Reason::UnknownKey));
    }
}
