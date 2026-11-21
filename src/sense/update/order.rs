//! Sense Remote (update plan 2026-11-21, §3.2–§3.3): the signed update order, the panel's
//! "install this version on this computer". Package U1 implements `verify`; pure.
//!
//! An order does not use the envelope `seq` counter. Replay protection: it is bound to this
//! computer (`did`, `duuid`), lives at most `ORDER_TTL_S`, and its version must be above the
//! installed one.
//!
//! Order of the checks: steps 1–5 of `manifest` with `UPDATE_ORDER_SIGNING_PREFIX` and the
//! panel keys → `iss` (`wrong_issuer`) → `did` / `duuid` (`wrong_device`) → time as step 7
//! (`not_yet_valid` / `expired`) → a valid release is held and `order.version` equals its
//! version (`version_mismatch`, also when no release is held) → `version > installed`
//! (`downgrade`).
//!
//! A rejected order changes nothing; the reason goes to the heartbeat as
//! `update.error = order_invalid` + `error_detail = <reason>`.

use super::manifest::{Reason, Release};
use crate::sense::envelope_keys::TrustedKey;
use serde_json::Value;

/// Domain separation (§3.1).
pub const UPDATE_ORDER_SIGNING_PREFIX: &[u8] = b"sense-remote/update-order/v1\n";
/// `ORDER_TTL_S`: `exp = iat + 7 days`; an order is never signed again.
pub const ORDER_TTL_S: i64 = 7 * 86_400;

wire_enum!(
    /// `UpdateWindow`: `idle` = as soon as no connection is active; `night` = 03:00–05:00 local
    /// time and no connection. "Güncelle" in the app is always `idle`.
    Window {
        Idle => "idle",
        Night => "night",
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

/// U0: every order is refused.
pub fn verify(order: &Value, panel_keys: &[TrustedKey], expect: &Expect) -> Result<Order, Reason> {
    let _ = (order, panel_keys, expect);
    Err(Reason::UnknownKey)
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

    #[test]
    fn window_names() {
        assert_eq!(Window::parse("idle"), Some(Window::Idle));
        assert_eq!(Window::Night.as_str(), "night");
        assert_eq!(Window::parse("now"), None);
    }

    // U0: fail closed until U1 verifies.
    #[test]
    fn skeleton_refuses_every_order() {
        let expect = Expect {
            iss: "panel.example",
            did: "123456789",
            duuid: "dXVpZA==",
            now_s: 1_795_000_000,
            release: None,
            installed: 3,
        };
        let order = serde_json::json!({ "k": "0000000000000000", "p": "e30", "s": "x" });
        assert_eq!(verify(&order, &[], &expect), Err(Reason::UnknownKey));
    }
}
