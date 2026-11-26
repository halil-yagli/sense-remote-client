//! Sense Remote: verification of signed panel envelopes (wave 2, plan §2.4 / §3.3 / §3.7).
//!
//! The panel signs permission sets with Ed25519; the heartbeat answer carries them in
//! `sense_envelopes`. Only an envelope that passes every step below may change settings:
//!
//! 1. envelope shape `{k, p, s}` (unknown field, bad base64url alphabet / length → `malformed`)
//! 2. `k` is one of the keys built into this client (`unknown_key`)
//! 3. `p` and `s` decode as strict unpadded base64url, `s` is 64 bytes (`malformed`)
//! 4. Ed25519 over `"sense-remote/envelope/v1\n" ‖ p bytes` (`bad_signature`)
//! 5. the signed bytes are JSON matching the payload schema, no unknown field at any level
//!    (`bad_payload`); the bytes are never re-canonicalized
//! 6. `iss` is our panel (`wrong_issuer`); `did` + `duuid` are this computer (`wrong_device`)
//! 7. `nbf - 300 <= now <= exp + 300` (`not_yet_valid`, `expired`)
//! 8. `seq > last_seq` (`replayed`)
//! 9. `typ == "strategy"` (`unsupported_type`; signed updates come in wave 3b)
//! 10. every `config_options` entry is on the allow list (`not_allowed`, the whole envelope)
//!
//! Steps 1–8 are the same, in the same order, as the panel's `verifyEnvelope`
//! (`packages/shared/src/envelope-node.ts`); the shared test vector proves both agree.
//! Everything here is pure: keys, expectations and time come from the caller.

use super::{envelope_keys::TrustedKey, SenseRole};
use base::config::keys;
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
use std::{collections::BTreeMap, sync::OnceLock};

/// Domain separation: signed data = this prefix (ASCII) ‖ payload bytes.
pub const SIGNING_PREFIX: &[u8] = b"sense-remote/envelope/v1\n";
/// Allowed clock difference for `nbf` / `exp`, seconds.
pub const CLOCK_SKEW_S: i64 = 300;
/// Same limit as the panel's schema (`Base64Url.max(65_536)`).
const MAX_PAYLOAD_CHARS: usize = 65_536;
const SIGNATURE_CHARS: usize = 86;
/// The panel's numbers are JavaScript numbers: integers beyond this fail its schema.
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
const MAX_DISCONNECT: usize = 64;

/// Why an envelope was not applied. Names are the panel's `EnvelopeErrorReason` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongIssuer,
    WrongDevice,
    NotYetValid,
    Expired,
    Replayed,
    NotAllowed,
    UnsupportedType,
    /// Not produced here: the applier (I4) uses it on platforms that only verify (macOS).
    UnsupportedPlatform,
    /// Not produced here: the applier (I4) uses it when writing the settings failed.
    ApplyFailed,
}

impl Reason {
    pub const ALL: [Reason; 13] = [
        Reason::Malformed,
        Reason::UnknownKey,
        Reason::BadSignature,
        Reason::BadPayload,
        Reason::WrongIssuer,
        Reason::WrongDevice,
        Reason::NotYetValid,
        Reason::Expired,
        Reason::Replayed,
        Reason::NotAllowed,
        Reason::UnsupportedType,
        Reason::UnsupportedPlatform,
        Reason::ApplyFailed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Malformed => "malformed",
            Reason::UnknownKey => "unknown_key",
            Reason::BadSignature => "bad_signature",
            Reason::BadPayload => "bad_payload",
            Reason::WrongIssuer => "wrong_issuer",
            Reason::WrongDevice => "wrong_device",
            Reason::NotYetValid => "not_yet_valid",
            Reason::Expired => "expired",
            Reason::Replayed => "replayed",
            Reason::NotAllowed => "not_allowed",
            Reason::UnsupportedType => "unsupported_type",
            Reason::UnsupportedPlatform => "unsupported_platform",
            Reason::ApplyFailed => "apply_failed",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.as_str() == value)
    }
}

/// A rejected envelope, with what could be read of it for the `envelope_error` report:
/// `k` once the envelope shape is valid, `seq` only once the signature and payload are.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rejection {
    pub reason: Reason,
    pub k: Option<String>,
    pub seq: Option<u64>,
}

impl Rejection {
    fn new(reason: Reason, k: Option<&str>, seq: Option<u64>) -> Self {
        Self {
            reason,
            k: k.map(str::to_owned),
            seq,
        }
    }
}

/// What this computer expects; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    /// Panel host, see `issuer_of`.
    pub iss: &'a str,
    /// Own RustDesk ID.
    pub did: &'a str,
    /// Own uuid, in the form the heartbeat sends.
    pub duuid: &'a str,
    /// Local clock, Unix seconds (never the server's time).
    pub now_s: i64,
    /// Last successfully applied seq, 0 if none.
    pub last_seq: u64,
}

/// Role the panel may set. Sense Remote (wave 3, K-ROL-2): all three roles; the panel sends
/// `controller` only to computers that report the `role_all` capability (this build).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PanelRole {
    Host,
    Controller,
    HostController,
}

impl PanelRole {
    pub fn sense_role(self) -> SenseRole {
        match self {
            PanelRole::Host => SenseRole::Host,
            PanelRole::Controller => SenseRole::Controller,
            PanelRole::HostController => SenseRole::Both,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StrategyBody {
    /// Already checked against the allow list when returned from `verify`.
    pub config_options: BTreeMap<String, String>,
    #[serde(default, deserialize_with = "present")]
    pub disconnect: Option<Vec<i64>>,
    pub revision: i64,
    #[serde(default, deserialize_with = "present")]
    pub sense_role: Option<PanelRole>,
}

/// A verified strategy envelope, ready to apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    pub k: String,
    pub seq: u64,
    pub nonce: String,
    pub iat: i64,
    pub nbf: i64,
    pub exp: i64,
    pub body: StrategyBody,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)] // fields are only validated: updates are not applied yet (wave 3b)
struct UpdateBody {
    app_version: i64,
    platform: String,
    url: String,
    sha256: String,
    size: i64,
    install_window: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload<B> {
    v: i64,
    #[allow(dead_code)]
    typ: String,
    iss: String,
    did: String,
    duuid: String,
    seq: i64,
    nonce: String,
    iat: i64,
    nbf: i64,
    exp: i64,
    body: B,
}

/// Optional field that must be the right type when present (`null` is rejected, like zod's
/// `.optional()`).
fn present<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    T::deserialize(d).map(Some)
}

fn is_safe_int(value: i64) -> bool {
    (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value)
}

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl<B> Payload<B> {
    fn base_is_valid(&self) -> bool {
        self.v == 1
            && !self.iss.is_empty()
            && !self.did.is_empty()
            && !self.duuid.is_empty()
            && !self.nonce.is_empty()
            && self.seq > 0
            && [self.seq, self.iat, self.nbf, self.exp]
                .into_iter()
                .all(is_safe_int)
    }
}

impl StrategyBody {
    fn is_valid(&self) -> bool {
        is_safe_int(self.revision)
            && self.disconnect.as_ref().map_or(true, |ids| {
                ids.len() <= MAX_DISCONNECT && ids.iter().copied().all(is_safe_int)
            })
    }
}

impl UpdateBody {
    fn is_valid(&self) -> bool {
        self.app_version > 0
            && is_safe_int(self.app_version)
            && matches!(self.platform.as_str(), "windows-x64" | "macos-arm64")
            && url::Url::parse(&self.url).is_ok_and(|u| u.scheme() == "https" && u.has_host())
            && is_sha256_hex(&self.sha256)
            && self.size > 0
            && is_safe_int(self.size)
            && matches!(
                self.install_window.as_str(),
                "idle" | "night_03_05" | "now" | "manual"
            )
    }
}

enum Parsed {
    Strategy(Payload<StrategyBody>),
    Update(Payload<UpdateBody>),
}

impl Parsed {
    fn base(&self) -> (&str, &str, &str, i64, i64, i64) {
        match self {
            Parsed::Strategy(p) => (&p.iss, &p.did, &p.duuid, p.seq, p.nbf, p.exp),
            Parsed::Update(p) => (&p.iss, &p.did, &p.duuid, p.seq, p.nbf, p.exp),
        }
    }
}

/// Step 5: schema of the signed bytes (the panel's `EnvelopePayload`).
fn parse_payload(bytes: &[u8]) -> Option<Parsed> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let typ = value.get("typ")?.as_str()?.to_owned();
    match typ.as_str() {
        "strategy" => {
            let p: Payload<StrategyBody> = serde_json::from_value(value).ok()?;
            (p.base_is_valid() && p.body.is_valid()).then_some(Parsed::Strategy(p))
        }
        "update" => {
            let p: Payload<UpdateBody> = serde_json::from_value(value).ok()?;
            (p.base_is_valid() && p.body.is_valid()).then_some(Parsed::Update(p))
        }
        _ => None,
    }
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, envelopes cannot be verified");
        }
        ok
    })
}

fn signature_ok(public_key: &[u8; 32], payload: &[u8], signature: &[u8; 64]) -> bool {
    if !sodium_ready() {
        return false;
    }
    let Ok(signature) = Signature::from_bytes(signature) else {
        return false;
    };
    let mut signed = Vec::with_capacity(SIGNING_PREFIX.len() + payload.len());
    signed.extend_from_slice(SIGNING_PREFIX);
    signed.extend_from_slice(payload);
    verify_detached(&signature, &signed, &PublicKey(*public_key))
}

/// Steps 1–8 (the panel's `verifyEnvelope`). Pure; `keys` are the trusted keys.
fn verify_signed(
    envelope: &Value,
    keys: &[TrustedKey],
    expect: &Expect,
) -> Result<(String, Parsed), Rejection> {
    let malformed = |k: Option<&str>| Rejection::new(Reason::Malformed, k, None);
    // 1. Shape: exactly {k, p, s}, all strings in the panel's alphabet and lengths.
    let object = envelope.as_object().ok_or_else(|| malformed(None))?;
    if object.len() != 3 {
        return Err(malformed(None));
    }
    let field = |name: &str| object.get(name).and_then(Value::as_str);
    let (Some(k), Some(p), Some(s)) = (field("k"), field("p"), field("s")) else {
        return Err(malformed(None));
    };
    if !super::envelope_keys::is_key_id(k)
        || p.is_empty()
        || p.len() > MAX_PAYLOAD_CHARS
        || !is_base64url_alphabet(p)
        || s.len() != SIGNATURE_CHARS
        || !is_base64url_alphabet(s)
    {
        return Err(malformed(None));
    }
    // 2. Known key.
    let key = keys
        .iter()
        .find(|key| key.k == k)
        .ok_or_else(|| Rejection::new(Reason::UnknownKey, Some(k), None))?;
    // 3. Strict base64url (no padding, no stray trailing bits), 64-byte signature.
    let payload = URL_SAFE_NO_PAD.decode(p).map_err(|_| malformed(Some(k)))?;
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(s)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or_else(|| malformed(Some(k)))?;
    // 4. Signature over prefix ‖ payload bytes, exactly as received.
    if !signature_ok(&key.public_key, &payload, &signature) {
        return Err(Rejection::new(Reason::BadSignature, Some(k), None));
    }
    // 5. Payload schema.
    let parsed =
        parse_payload(&payload).ok_or_else(|| Rejection::new(Reason::BadPayload, Some(k), None))?;
    let (iss, did, duuid, seq, nbf, exp) = parsed.base();
    let seq = seq as u64; // > 0, checked by the schema
    let reject = |reason| Err(Rejection::new(reason, Some(k), Some(seq)));
    // 6. Issuer and device binding.
    if iss != expect.iss {
        return reject(Reason::WrongIssuer);
    }
    if did != expect.did || duuid != expect.duuid {
        return reject(Reason::WrongDevice);
    }
    // 7. Validity window with clock skew allowance.
    if expect.now_s < nbf.saturating_sub(CLOCK_SKEW_S) {
        return reject(Reason::NotYetValid);
    }
    if expect.now_s > exp.saturating_add(CLOCK_SKEW_S) {
        return reject(Reason::Expired);
    }
    // 8. Replay protection.
    if seq <= expect.last_seq {
        return reject(Reason::Replayed);
    }
    Ok((k.to_owned(), parsed))
}

/// Full client check (steps 1–10). `Ok` = safe to apply; the caller stores `seq` as the new
/// `last_seq` only after applying succeeded.
pub fn verify(envelope: &Value, keys: &[TrustedKey], expect: &Expect) -> Result<Verified, Rejection> {
    let (k, parsed) = verify_signed(envelope, keys, expect)?;
    let payload = match parsed {
        Parsed::Strategy(payload) => payload,
        // 9. Signed update packages are wave 3b.
        Parsed::Update(payload) => {
            return Err(Rejection::new(
                Reason::UnsupportedType,
                Some(&k),
                Some(payload.seq as u64),
            ))
        }
    };
    let seq = payload.seq as u64;
    // 10. Allow list: one bad key or value rejects the whole envelope.
    if !check_allowed(&payload.body.config_options) {
        return Err(Rejection::new(Reason::NotAllowed, Some(&k), Some(seq)));
    }
    Ok(Verified {
        k,
        seq,
        nonce: payload.nonce,
        iat: payload.iat,
        nbf: payload.nbf,
        exp: payload.exp,
        body: payload.body,
    })
}

/// `verify` with the keys built into this client (`SENSE_ENVELOPE_KEYS`).
pub fn verify_with_build_keys(envelope: &Value, expect: &Expect) -> Result<Verified, Rejection> {
    verify(envelope, super::envelope_keys::trusted_keys(), expect)
}

/// Rule for one allowed `config_options` key (plan §3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OptionRule {
    /// Only `""` (`access-mode`: custom permissions, never `full` / `view`).
    Empty,
    /// `Y` or `N`.
    YesNo,
    /// `""` or a decimal without leading zero (1–4 ASCII digits), `MIN_MINUTES..=MAX_MINUTES`.
    Minutes,
}

pub const MIN_MINUTES: u16 = 5;
pub const MAX_MINUTES: u16 = 1440;

/// Only settings the panel can always undo (plan K-İZİN): nothing that could stop the
/// heartbeat, change servers / identity, hide the connection window or lock out remote access.
pub const ALLOWED_OPTIONS: [(&str, OptionRule); 16] = [
    (keys::OPTION_ACCESS_MODE, OptionRule::Empty),
    (keys::OPTION_ENABLE_KEYBOARD, OptionRule::YesNo),
    (keys::OPTION_ENABLE_CLIPBOARD, OptionRule::YesNo),
    (keys::OPTION_ENABLE_FILE_TRANSFER, OptionRule::YesNo),
    (keys::OPTION_ENABLE_AUDIO, OptionRule::YesNo),
    (keys::OPTION_ENABLE_REMOTE_RESTART, OptionRule::YesNo),
    (keys::OPTION_ENABLE_RECORD_SESSION, OptionRule::YesNo),
    (keys::OPTION_ENABLE_BLOCK_INPUT, OptionRule::YesNo),
    (keys::OPTION_ENABLE_PRIVACY_MODE, OptionRule::YesNo),
    (keys::OPTION_ENABLE_TERMINAL, OptionRule::YesNo),
    (keys::OPTION_ENABLE_TUNNEL, OptionRule::YesNo),
    (keys::OPTION_ENABLE_CAMERA, OptionRule::YesNo),
    (keys::OPTION_ENABLE_REMOTE_PRINTER, OptionRule::YesNo),
    (keys::OPTION_ALLOW_REMOVE_WALLPAPER, OptionRule::YesNo),
    (keys::OPTION_ALLOW_AUTO_DISCONNECT, OptionRule::YesNo),
    (keys::OPTION_AUTO_DISCONNECT_TIMEOUT, OptionRule::Minutes),
];

impl OptionRule {
    pub fn accepts(self, value: &str) -> bool {
        match self {
            OptionRule::Empty => value.is_empty(),
            OptionRule::YesNo => value == "Y" || value == "N",
            OptionRule::Minutes => {
                // Same as the panel's `int_or_empty` (`^[1-9][0-9]{0,3}$`): one spelling per
                // value, so "030" is not accepted as 30.
                value.is_empty()
                    || (value.len() <= 4
                        && !value.starts_with('0')
                        && value.bytes().all(|b| b.is_ascii_digit())
                        && value
                            .parse::<u16>()
                            .is_ok_and(|m| (MIN_MINUTES..=MAX_MINUTES).contains(&m)))
            }
        }
    }
}

/// Sense Remote (Sürüm 9, paket A): the panel-managed Host settings. They are OPTIONAL in an
/// envelope (`is_full_set` still asks for `ALLOWED_OPTIONS` only): an envelope without them keeps
/// the computer's behaviour as it is, and the panel adds them only for a computer that reports
/// `report::CAP_HOST_OPTS` (a build without this list refuses an unknown key with `not_allowed`).
/// `SENSE_AUDIO_INPUT` is a Sense-side name: `envelope_apply::host_options` turns it into the
/// RustDesk options before anything is written.
pub const SENSE_AUDIO_INPUT: &str = "sense-audio-input";
pub const EXTENDED_OPTIONS: [(&str, ExtendedRule); 4] = [
    (SENSE_AUDIO_INPUT, ExtendedRule::AudioInput),
    (keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS, ExtendedRule::YesNo),
    (keys::OPTION_RELAY_FALLBACK_DELAY, ExtendedRule::Seconds),
    (keys::OPTION_DISABLE_UDP, ExtendedRule::YesNo),
];

pub const MIN_RELAY_DELAY_S: u16 = 1;
pub const MAX_RELAY_DELAY_S: u16 = 30;

/// Rule for one `EXTENDED_OPTIONS` key (the same spelling as the panel's `EXTENDED_OPTIONS`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtendedRule {
    /// `Y` or `N`.
    YesNo,
    /// `""` (default: system sound), `system` (the system's default input device) or `off`.
    AudioInput,
    /// `""` or a decimal without leading zero (1-2 ASCII digits), `MIN_RELAY_DELAY_S..=MAX_RELAY_DELAY_S`.
    Seconds,
}

impl ExtendedRule {
    pub fn accepts(self, value: &str) -> bool {
        match self {
            ExtendedRule::YesNo => value == "Y" || value == "N",
            ExtendedRule::AudioInput => matches!(value, "" | "system" | "off"),
            ExtendedRule::Seconds => {
                value.is_empty()
                    || (value.len() <= 2
                        && !value.starts_with('0')
                        && value.bytes().all(|b| b.is_ascii_digit())
                        && value.parse::<u16>().is_ok_and(|s| {
                            (MIN_RELAY_DELAY_S..=MAX_RELAY_DELAY_S).contains(&s)
                        }))
            }
        }
    }
}

/// The options the app writes for `SENSE_AUDIO_INPUT` besides itself: the RustDesk key.
pub const OPTION_AUDIO_INPUT: &str = "audio-input";

/// True when only the panel writes this key: `ALLOWED_OPTIONS`, `EXTENDED_OPTIONS` and the RustDesk
/// option `SENSE_AUDIO_INPUT` becomes. The app never offers to change these, and on macOS the
/// daemon keeps its own value for them.
pub fn is_panel_option(key: &str) -> bool {
    key == OPTION_AUDIO_INPUT
        || ALLOWED_OPTIONS.iter().any(|(allowed, _)| *allowed == key)
        || EXTENDED_OPTIONS.iter().any(|(allowed, _)| *allowed == key)
}

/// True when every key is on the allow list (base or extended) and every value fits its rule.
pub fn check_allowed(config_options: &BTreeMap<String, String>) -> bool {
    config_options.iter().all(|(key, value)| {
        ALLOWED_OPTIONS
            .iter()
            .any(|(allowed, rule)| allowed == key && rule.accepts(value))
            || EXTENDED_OPTIONS
                .iter()
                .any(|(allowed, rule)| allowed == key && rule.accepts(value))
    })
}

/// `iss` the panel signs with: the host (+ non-default port) of its address, lowercase — the
/// same as `new URL(origin).host` for the panel's `ALAN_ADI`.
pub fn issuer_of(api_server: &str) -> String {
    let (rest, default_port) = if let Some(rest) = api_server.strip_prefix("https://") {
        (rest, ":443")
    } else if let Some(rest) = api_server.strip_prefix("http://") {
        (rest, ":80")
    } else {
        (api_server, "")
    };
    let host = rest.to_ascii_lowercase();
    match host.strip_suffix(default_port) {
        Some(stripped) if !default_port.is_empty() => stripped.to_owned(),
        _ => host,
    }
}

/// Our panel's `iss` (from the build-time `API_SERVER`).
pub fn expected_issuer() -> String {
    issuer_of(super::API_SERVER)
}

#[cfg(test)]
mod tests;
// Sense Remote: the shared test vector made by the panel (`envelope-v1.json`, copied verbatim).
#[cfg(test)]
mod vector;
