//! Sense Remote (update plan 2026-11-21, §3.1–§3.3): the signed release notice and the build
//! statement inside it. Pure: keys, clock and expectations come from the caller; no globals.
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

use super::keys::lists_overlap;
use crate::sense::envelope_keys::{is_key_id, TrustedKey};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    log,
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::Deserialize;
use serde_json::Value;
use std::sync::OnceLock;

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
pub fn verify(
    release: &Value,
    panel_keys: &[TrustedKey],
    build_keys: &[TrustedKey],
    expect: &Expect,
) -> Result<Release, Reason> {
    // 0.
    if lists_overlap(panel_keys, build_keys) {
        return Err(Reason::KeysOverlap);
    }
    // 1–5.
    let (k, value) = open_signed(release, panel_keys, RELEASE_SIGNING_PREFIX)?;
    let w: ReleaseWire = serde_json::from_value(value)
        .ok()
        .filter(ReleaseWire::is_valid)
        .ok_or(Reason::BadPayload)?;
    // 6–7.
    if w.iss != expect.iss {
        return Err(Reason::WrongIssuer);
    }
    check_time(w.iat, w.exp, expect.now_s)?;
    // 8.
    if w.platform != expect.platform {
        return Err(Reason::WrongPlatform);
    }
    // 9. Raw strings, whole string: another host, path, `..`, query, port or scheme all differ.
    let version = w.version as u32; // 1..=MAX_VERSION, checked by the schema
    let url = format!("{}{DOWNLOAD_PATH}{}", expect.api_server, w.file);
    let notes = format!("{}{NOTES_ANCHOR}{version}", expect.api_server);
    if installer_file_name(version, &w.platform).as_deref() != Some(w.file.as_str())
        || w.url != url
        || w.notes_url.as_ref().is_some_and(|n| *n != notes)
    {
        return Err(Reason::BadUrl);
    }
    // 10. The panel's `BUILD_REASON`: a bad inner base64url counts as a bad signature.
    let build = verify_build(&w.build, build_keys).map_err(|reason| match reason {
        Reason::UnknownKey => Reason::BuildUnknownKey,
        Reason::BadPayload => Reason::BuildBadPayload,
        _ => Reason::BuildBadSignature,
    })?;
    // 11.
    if build.version != version
        || build.platform != w.platform
        || build.file != w.file
        || build.sha256 != w.sha256
        || build.size != w.size as u64
    {
        return Err(Reason::BuildMismatch);
    }
    Ok(Release {
        k,
        version,
        platform: w.platform,
        file: w.file,
        url: w.url,
        sha256: w.sha256,
        size: w.size as u64,
        notes_url: w.notes_url,
        published_at: w.published_at,
        iat: w.iat,
        exp: w.exp,
        build,
    })
}

/// A build statement on its own (the panel's `verifyBuild`): steps 1–5 with
/// `BUILD_SIGNING_PREFIX` and the build keys; only `malformed`, `unknown_key`, `bad_signature`
/// and `bad_payload`.
pub fn verify_build(build: &Value, build_keys: &[TrustedKey]) -> Result<BuildStatement, Reason> {
    let (k, value) = open_signed(build, build_keys, BUILD_SIGNING_PREFIX)?;
    let w: BuildWire = serde_json::from_value(value)
        .ok()
        .filter(BuildWire::is_valid)
        .ok_or(Reason::BadPayload)?;
    Ok(BuildStatement {
        k,
        version: w.version as u32,
        platform: w.platform,
        file: w.file,
        sha256: w.sha256,
        size: w.size as u64,
        commit: w.commit,
        run_id: w.run_id as u64,
        iat: w.iat,
    })
}

/// Step 7 (and the order's time step): `iat - 300 ≤ now ≤ exp + 300`, local clock.
pub(super) fn check_time(iat: i64, exp: i64, now_s: i64) -> Result<(), Reason> {
    if now_s < iat - CLOCK_SKEW_S {
        return Err(Reason::NotYetValid);
    }
    if now_s > exp + CLOCK_SKEW_S {
        return Err(Reason::Expired);
    }
    Ok(())
}

// ---- Signed objects: steps 1–5, shared with `order` ------------------------------------------

/// The panel's `Envelope` schema limits (`envelope.ts`).
const ENVELOPE_MAX_P_CHARS: usize = 65_536;
const SIGNATURE_CHARS: usize = 86;

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The `Envelope` schema: exactly `{k, p, s}`, `k` a key id, `p` 1..=65536 and `s` 86 base64url
/// characters.
fn envelope_shape(value: &Value) -> Option<(&str, &str, &str)> {
    let object = value.as_object().filter(|o| o.len() == 3)?;
    let field = |name: &str| object.get(name).and_then(Value::as_str);
    let (k, p, s) = (field("k")?, field("p")?, field("s")?);
    let ok = is_key_id(k)
        && (1..=ENVELOPE_MAX_P_CHARS).contains(&p.len())
        && is_base64url_alphabet(p)
        && s.len() == SIGNATURE_CHARS
        && is_base64url_alphabet(s);
    ok.then_some((k, p, s))
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, updates cannot be verified");
        }
        ok
    })
}

fn signature_ok(prefix: &[u8], public_key: &[u8; 32], payload: &[u8], signature: &[u8; 64]) -> bool {
    if !sodium_ready() {
        return false;
    }
    let Ok(signature) = Signature::from_bytes(signature) else {
        return false;
    };
    let mut signed = Vec::with_capacity(prefix.len() + payload.len());
    signed.extend_from_slice(prefix);
    signed.extend_from_slice(payload);
    verify_detached(&signature, &signed, &PublicKey(*public_key))
}

/// Steps 1–5 without the schema: shape and `p` limit (`malformed`), key (`unknown_key`), strict
/// base64url and 64-byte signature (`malformed`), signature over prefix ‖ payload bytes
/// (`bad_signature`), JCS canonical JSON (`bad_payload`). Returns the key id and the value.
pub(super) fn open_signed(
    blob: &Value,
    keys: &[TrustedKey],
    prefix: &[u8],
) -> Result<(String, Value), Reason> {
    let (k, p, s) = envelope_shape(blob)
        .filter(|(_, p, _)| p.len() <= MAX_SIGNED_P_CHARS)
        .ok_or(Reason::Malformed)?;
    let key = keys.iter().find(|key| key.k == k).ok_or(Reason::UnknownKey)?;
    // No padding, no stray trailing bits: the same as the panel's round-trip check.
    let payload = URL_SAFE_NO_PAD.decode(p).map_err(|_| Reason::Malformed)?;
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(s)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(Reason::Malformed)?;
    if !signature_ok(prefix, &key.public_key, &payload, &signature) {
        return Err(Reason::BadSignature);
    }
    let value = parse_canonical(&payload).ok_or(Reason::BadPayload)?;
    Ok((k.to_owned(), value))
}

/// The payload only when its bytes are the JCS (RFC 8785) form of the value they decode to.
/// BOM, invalid UTF-8, a lone surrogate (serde_json refuses both), whitespace, unsorted or
/// duplicate keys (the value keeps one), `3.0` / `1e7` and needless escapes all differ.
fn parse_canonical(bytes: &[u8]) -> Option<Value> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let mut canonical = String::with_capacity(bytes.len());
    write_canonical(&value, &mut canonical)?;
    (canonical.as_bytes() == bytes).then_some(value)
}

/// JCS for the values these payloads may hold. Every number of the schemas is an integer, so a
/// non-integer is refused here instead of reproducing ECMAScript float printing; the result is
/// `bad_payload` either way.
fn write_canonical(value: &Value, out: &mut String) -> Option<()> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => out.push_str(&i.to_string()),
            (None, Some(u)) => out.push_str(&u.to_string()),
            _ => return None,
        },
        // serde_json escapes `"`, `\` and controls exactly as JCS does (short forms, else
        // lowercase `\u00xx`) and writes everything else as is.
        Value::String(s) => out.push_str(&serde_json::to_string(s).ok()?),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            // JCS sorts by UTF-16 code units, not by UTF-8 bytes.
            let mut entries: Vec<_> = map.iter().collect();
            entries.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
            out.push('{');
            for (i, (key, item)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).ok()?);
                out.push(':');
                write_canonical(item, out)?;
            }
            out.push('}');
        }
    }
    Some(())
}

// ---- Schemas (`release.ts`; every limit written out) -----------------------------------------

/// Optional field that must have the right type when present: `null` is refused, as zod's
/// `.optional()` does.
fn present<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    T::deserialize(d).map(Some)
}

pub(super) fn is_version(value: i64) -> bool {
    (1..=i64::from(super::MAX_VERSION)).contains(&value)
}

pub(super) fn is_unix_seconds(value: i64) -> bool {
    (0..=MAX_UNIX_SECONDS).contains(&value)
}

pub(super) fn is_platform(value: &str) -> bool {
    value == PLATFORM_WINDOWS || value == PLATFORM_MACOS
}

pub(super) fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// `iat ≤ exp ≤ iat + ttl` (both already in 0..=MAX_UNIX_SECONDS).
pub(super) fn within_ttl(iat: i64, exp: i64, ttl: i64) -> bool {
    iat <= exp && exp - iat <= ttl
}

fn is_size(value: i64) -> bool {
    (1..=MAX_INSTALLER_BYTES as i64).contains(&value)
}

/// `InstallerFile`: `^SenseRemote-(Kurulum-[1-9][0-9]{0,5}\.exe|[1-9][0-9]{0,5}\.dmg)$`.
fn is_installer_file(value: &str) -> bool {
    let number = |digits: &str| {
        (1..=6).contains(&digits.len())
            && !digits.starts_with('0')
            && digits.bytes().all(|b| b.is_ascii_digit())
    };
    let Some(rest) = value.strip_prefix("SenseRemote-") else {
        return false;
    };
    match rest.strip_prefix("Kurulum-") {
        Some(exe) => exe.strip_suffix(".exe").is_some_and(number),
        None => rest.strip_suffix(".dmg").is_some_and(number),
    }
}

/// `ReleaseUrl`: at most 2048 characters, `^https?://[\x21-\x7e]+$`. No URL parser on purpose.
fn is_release_url(value: &str) -> bool {
    let rest = value
        .strip_prefix("https://")
        .or_else(|| value.strip_prefix("http://"));
    value.len() <= MAX_URL_CHARS
        && rest.is_some_and(|rest| {
            !rest.is_empty() && rest.bytes().all(|b| (0x21..=0x7e).contains(&b))
        })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildWire {
    v: i64,
    typ: String,
    version: i64,
    platform: String,
    file: String,
    sha256: String,
    size: i64,
    commit: String,
    run_id: i64,
    iat: i64,
}

impl BuildWire {
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "build"
            && is_version(self.version)
            && is_platform(&self.platform)
            && is_installer_file(&self.file)
            && is_sha256_hex(&self.sha256)
            && is_size(self.size)
            && self.commit.len() == 40
            && self.commit.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
            && (1..=MAX_RUN_ID as i64).contains(&self.run_id)
            && is_unix_seconds(self.iat)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReleaseWire {
    v: i64,
    typ: String,
    iss: String,
    version: i64,
    platform: String,
    file: String,
    url: String,
    sha256: String,
    size: i64,
    /// `Envelope`; its shape is part of this schema (`bad_payload`), its signature is step 10.
    build: Value,
    #[serde(default, deserialize_with = "present")]
    notes_url: Option<String>,
    published_at: i64,
    iat: i64,
    exp: i64,
}

impl ReleaseWire {
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "release"
            && !self.iss.is_empty()
            && is_version(self.version)
            && is_platform(&self.platform)
            && is_installer_file(&self.file)
            && is_release_url(&self.url)
            && is_sha256_hex(&self.sha256)
            && is_size(self.size)
            && envelope_shape(&self.build).is_some()
            && self.notes_url.as_deref().map_or(true, is_release_url)
            && [self.published_at, self.iat, self.exp]
                .into_iter()
                .all(is_unix_seconds)
            && within_ttl(self.iat, self.exp, RELEASE_TTL_S)
    }
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
mod vector;

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


    #[test]
    fn canonical_json_is_jcs() {
        for ok in [
            r#"{"a":1,"b":[true,null,"x"]}"#,
            r#"{"b":{"c":-5,"d":"\n\u001f\"\\"},"é":0}"#,
            // UTF-16 order: U+1F600 (surrogates D83D…) sorts before U+FB01.
            "{\"\u{1F600}\":1,\"\u{FB01}\":2}",
            "\"\u{7f}\u{2028}\"",
        ] {
            assert!(parse_canonical(ok.as_bytes()).is_some(), "{ok}");
        }
        for bad in [
            r#"{"b":1,"a":2}"#,
            r#"{"a":1,"a":1}"#,
            r#"{"a": 1}"#,
            r#"{"a":3.0}"#,
            r#"{"a":1e7}"#,
            r#"{"a":1.5}"#,
            r#"{"a":-0}"#,
            r#"{"a":"a"}"#,
            r#"{"a":"\/"}"#,
            r#"{"a":"\ud800"}"#,
            "\u{feff}{\"a\":1}",
            "{\"\u{FB01}\":2,\"\u{1F600}\":1}",
        ] {
            assert!(parse_canonical(bad.as_bytes()).is_none(), "{bad}");
        }
        assert!(parse_canonical(b"{\"a\":\"\xff\"}").is_none());
    }

    #[test]
    fn schema_strings() {
        assert!(is_installer_file("SenseRemote-Kurulum-3.exe"));
        assert!(is_installer_file("SenseRemote-999999.dmg"));
        for bad in [
            "SenseRemote-Kurulum-03.exe",
            "SenseRemote-Kurulum-1000000.exe",
            "SenseRemote-Kurulum-.exe",
            "SenseRemote-3.exe",
            "SenseRemote-Kurulum-3.dmg",
            "SenseRemote-0.dmg",
            "senseremote-3.dmg",
            "SenseRemote-3.dmg\n",
        ] {
            assert!(!is_installer_file(bad), "{bad}");
        }
        assert!(is_release_url("https://a"));
        assert!(is_release_url("http://127.0.0.1:21114/indir/x"));
        assert!(is_release_url(&format!("https://{}", "a".repeat(MAX_URL_CHARS - 8))));
        for bad in [
            "https://".to_owned(),
            "ftp://a".to_owned(),
            "//a".to_owned(),
            "https://a b".to_owned(),
            "https://a\t".to_owned(),
            " https://a".to_owned(),
            "https://ä".to_owned(),
            format!("https://{}", "a".repeat(MAX_URL_CHARS - 7)),
        ] {
            assert!(!is_release_url(&bad), "{bad}");
        }
    }

    #[test]
    fn time_window_edges() {
        assert_eq!(check_time(1_000, 2_000, 700), Ok(()));
        assert_eq!(check_time(1_000, 2_000, 699), Err(Reason::NotYetValid));
        assert_eq!(check_time(1_000, 2_000, 2_300), Ok(()));
        assert_eq!(check_time(1_000, 2_000, 2_301), Err(Reason::Expired));
    }
}
