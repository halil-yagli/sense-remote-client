//! Sense Remote (update plan 2026-11-21, §3.1–§3.3): the signed release notice and the build
//! statement inside it. Package U1 implements `verify`; pure, no clock, no globals.
//!
//! Transport is the envelope's `{k, p, s}`: `k` = first 8 bytes of SHA-256(raw public key) as
//! hex, `p` = payload bytes as unpadded base64url (at most `MAX_SIGNED_P_CHARS`), `s` = 64-byte
//! Ed25519 signature as base64url. Signed data = prefix ‖ the bytes of `p`; the payload is never
//! canonicalised again. Payloads are strict (`deny_unknown_fields` at every level).
//!
//! Order of the checks (the panel's `verifyRelease` follows steps 1–11 too):
//!  1. shape `{k,p,s}` → `malformed`
//!  2. `k` is a panel key → `unknown_key`
//!  3. strict base64url, 64-byte signature → `malformed`
//!  4. Ed25519 with `RELEASE_SIGNING_PREFIX` → `bad_signature`
//!  5. schema → `bad_payload`
//!  6. `iss` → `wrong_issuer`
//!  7. `iat - 300 ≤ now ≤ exp + 300` (local clock) → `not_yet_valid` / `expired`
//!  8. `platform` is this build's → `wrong_platform`
//!  9. `file == installer_file_name(version, platform)`, `url == api_server + "/indir/" + file`
//!     (whole string), `notes_url` (if any) starts with `api_server` → `bad_url`
//! 10. `build`: `k` is a build key (`build_unknown_key`), signature with `BUILD_SIGNING_PREFIX`
//!     (`build_bad_signature`), `BuildStatement` schema (`build_bad_payload`)
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
/// Allowed clock difference for `iat` / `exp`, seconds (as for envelopes).
pub const CLOCK_SKEW_S: i64 = 300;
/// The only place installers are downloaded from: `api_server + DOWNLOAD_PATH + file`.
pub const DOWNLOAD_PATH: &str = "/indir/";
pub const PLATFORM_WINDOWS: &str = "windows-x64";
pub const PLATFORM_MACOS: &str = "macos-arm64";

wire_enum!(
    /// Why a release notice or an order was refused (§3.3). The names are reported as
    /// `error_detail` (`^[a-z_]{1,32}$`); the last three are only produced for orders.
    Reason {
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

/// A verified `ReleasePayload` (§3.2), steps 1–11 passed.
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

/// Steps 1–11. `panel_keys` = `keys::panel_keys()`, `build_keys` = `keys::release_keys()`.
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
