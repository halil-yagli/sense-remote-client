//! Sense Remote (update plan 2026-11-21, §3.2–§3.3): the signed update order, the panel's
//! "install this version on this computer". Pure: keys, time and the held release come from the
//! caller.
//!
//! An order does not use the envelope `seq` counter. Replay protection: it is bound to this
//! computer (`did`, `duuid`) and to one file (`platform`, `sha256`: when a version number is
//! published again with another file, an old order can not make the new file install), lives
//! at most `ORDER_TTL_S` (48 hours; a cancel is an unsigned hint, so a suppressed cancel lasts
//! at most that long), and its version must be above the installed one.
//!
//! Order of the checks (plan §3.3; names are the panel's `UpdateOrderRejectReason`): steps 1–5
//! of `manifest` with `UPDATE_ORDER_SIGNING_PREFIX` and the panel keys (`malformed`,
//! `unknown_key`, `bad_signature`, `bad_payload`: JCS canonical JSON + schema, including
//! `iat ≤ exp ≤ iat + ORDER_TTL_S`) → `iss` (`wrong_issuer`) → `did` / `duuid`
//! (`wrong_device`) → time as step 7 (`not_yet_valid` / `expired`) → a valid (not expired)
//! release is held and `order.version` equals its version (`version_mismatch`, also when no
//! release is held) → `order.platform` and `order.sha256` equal the held release's
//! (`release_mismatch`) → `version > installed` (`downgrade`). When one heartbeat answer
//! carries both, the release is handled first.
//!
//! A rejected order changes nothing; the reason goes to the heartbeat as
//! `update.error = order_invalid` + `error_detail = <reason>`.

use super::manifest::{
    check_time, is_platform, is_sha256_hex, is_unix_seconds, is_version, open_signed, within_ttl,
    Reason, Release, CLOCK_SKEW_S,
};
use crate::sense::envelope_keys::TrustedKey;
use serde_derive::Deserialize;
use serde_json::Value;

/// Domain separation (§3.1).
pub const UPDATE_ORDER_SIGNING_PREFIX: &[u8] = b"sense-remote/update-order/v1\n";
/// `ORDER_TTL_S`: `exp = iat + 48 hours`; an order is never signed again, an expired one is
/// `expired`.
pub const ORDER_TTL_S: i64 = 2 * 86_400;

wire_enum!(
    /// `UpdateWindow`: `idle` = as soon as no connection is active; `night` = 03:00–05:00 local
    /// time and no connection. "Güncelle" in the app is always `idle`. Sense Remote: `now` = at
    /// once, open sessions are closed first; the panel sends it only to a computer whose
    /// heartbeat has `update_now` (older builds refuse an unknown window).
    Window {
        Idle => "idle",
        Night => "night",
        Now => "now",
    }
);

/// A verified `UpdateOrderPayload`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Order {
    /// Key id of the panel key that signed it.
    pub k: String,
    /// `UpdateOrderId`.
    pub oid: String,
    pub version: u32,
    /// File binding: the published file at the time the order was given.
    pub platform: String,
    /// Lowercase hex.
    pub sha256: String,
    pub window: Window,
    pub iat: i64,
    pub exp: i64,
}

/// What this computer expects; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    /// Panel host, `envelope::expected_issuer()`.
    pub iss: &'a str,
    /// Own RustDesk ID.
    pub did: &'a str,
    /// Own uuid, in the form the heartbeat sends.
    pub duuid: &'a str,
    /// Local clock, Unix seconds.
    pub now_s: i64,
    /// The valid release this computer holds, if any.
    pub release: Option<&'a Release>,
    /// Installed Sense version.
    pub installed: u32,
}

/// Verifies an order in the order of §3.3. `panel_keys` = `keys::panel_keys()`.
pub fn verify(order: &Value, panel_keys: &[TrustedKey], expect: &Expect) -> Result<Order, Reason> {
    let (k, value) = open_signed(order, panel_keys, UPDATE_ORDER_SIGNING_PREFIX)?;
    let w: OrderWire = serde_json::from_value(value)
        .ok()
        .filter(OrderWire::is_valid)
        .ok_or(Reason::BadPayload)?;
    if w.iss != expect.iss {
        return Err(Reason::WrongIssuer);
    }
    if w.did != expect.did || w.duuid != expect.duuid {
        return Err(Reason::WrongDevice);
    }
    check_time(w.iat, w.exp, expect.now_s)?;
    let version = w.version as u32; // 1..=MAX_VERSION, checked by the schema
    // A held release that has expired since is no release (the caller should drop it anyway).
    let held = expect
        .release
        .filter(|release| expect.now_s <= release.exp + CLOCK_SKEW_S);
    let Some(held) = held.filter(|release| release.version == version) else {
        return Err(Reason::VersionMismatch);
    };
    if w.platform != held.platform || w.sha256 != held.sha256 {
        return Err(Reason::ReleaseMismatch);
    }
    if version <= expect.installed {
        return Err(Reason::Downgrade);
    }
    Ok(Order {
        k,
        oid: w.oid,
        version,
        platform: w.platform,
        sha256: w.sha256,
        window: Window::parse(&w.window).ok_or(Reason::BadPayload)?,
        iat: w.iat,
        exp: w.exp,
    })
}

/// `UpdateOrderPayload` (§3.2), every limit written out.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OrderWire {
    v: i64,
    typ: String,
    iss: String,
    did: String,
    duuid: String,
    oid: String,
    version: i64,
    platform: String,
    sha256: String,
    window: String,
    iat: i64,
    exp: i64,
}

impl OrderWire {
    fn is_valid(&self) -> bool {
        self.v == 1
            && self.typ == "update_order"
            && !self.iss.is_empty()
            && !self.did.is_empty()
            && !self.duuid.is_empty()
            && is_order_id(&self.oid)
            && is_version(self.version)
            && is_platform(&self.platform)
            && is_sha256_hex(&self.sha256)
            && Window::parse(&self.window).is_some()
            && is_unix_seconds(self.iat)
            && is_unix_seconds(self.exp)
            && within_ttl(self.iat, self.exp, ORDER_TTL_S)
    }
}

/// `UpdateOrderId`: `^upd_[A-Za-z0-9_-]{16,32}$`.
pub fn is_order_id(value: &str) -> bool {
    match value.strip_prefix("upd_") {
        Some(rest) => {
            (16..=32).contains(&rest.len())
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn order_ids() {
        assert!(is_order_id("upd_0123456789abcdef"));
        assert!(is_order_id(&format!("upd_{}", "A-_z".repeat(8))));
        for bad in [
            "",
            "upd_",
            "upd_0123456789abcde",
            "UPD_0123456789abcdef",
            "ord_0123456789abcdef",
            "upd_0123456789abcde!",
            "upd_0123456789abcdeğ",
        ] {
            assert!(!is_order_id(bad), "{bad}");
        }
        assert!(!is_order_id(&format!("upd_{}", "a".repeat(33))));
    }

    // Same numbers as the panel's `release.ts`.
    #[test]
    fn lifetimes_match_the_contract() {
        assert_eq!(ORDER_TTL_S, 172_800);
        assert_eq!(crate::sense::update::manifest::RELEASE_TTL_S, 604_800);
    }

    #[test]
    fn window_names() {
        assert_eq!(Window::parse("idle"), Some(Window::Idle));
        assert_eq!(Window::Night.as_str(), "night");
        assert_eq!(Window::parse("now"), Some(Window::Now));
        assert_eq!(Window::Now.as_str(), "now");
        assert_eq!(Window::parse("later"), None);
        assert_eq!(Window::parse(""), None);
    }
}
