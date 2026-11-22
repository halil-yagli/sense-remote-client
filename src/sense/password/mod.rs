//! Sense Remote (permanent password plan 2026-11-21): the permanent password is set inside the
//! app, after a Sense sign-in, and written only by the privileged process (Windows: SYSTEM
//! `--server`; macOS: root daemon) against a short-lived grant signed by the panel.
//!
//! U9 is the skeleton: the IPC/FFI types and the locks (`guard`). U10 adds the pure core: the
//! grant check (`grant`, §3.3), request and ack signing (`request`, `ack`), the pending nonce
//! (`pending`), the password rule (`rule`) and the UI side of the unlock (`ui`). Nothing changes
//! a password yet (`SUPPORTED` is false, the privileged side is U11/U12): every request is
//! answered `unsupported` and `caps` does not carry `password`.

use serde_derive::{Deserialize, Serialize};

pub mod ack;
pub mod grant;
pub mod guard;
pub mod ipc_mac;
pub mod ipc_win;
pub mod pending;
pub mod request;
pub mod rule;
pub mod status;
pub mod store_mac;
pub mod store_win;
// Only the Flutter UI has the sign-in (`hbbs_http::account`) and the password page.
#[cfg(feature = "flutter")]
pub mod ui;
// The shared test vector (`testdata/password-v1.json`, made by the panel).
#[cfg(test)]
mod vector;

/// Sense Remote (plan §8.1 U14): the one switch. True only once the grant check, the stores and
/// the UI are in (U10–U13).
pub const SUPPORTED: bool = false;

/// Capability in the signed report (`sense.caps`) when `SUPPORTED`.
pub const CAP_PASSWORD: &str = "password";

/// Signing domains (§3.1). Signed data = prefix ‖ bytes of `p`.
pub const PASSWORD_REQUEST_PREFIX: &[u8] = b"sense-remote/password-request/v1\n";
pub const PASSWORD_GRANT_PREFIX: &[u8] = b"sense-remote/password-grant/v1\n";
pub const PASSWORD_ACK_PREFIX: &[u8] = b"sense-remote/password-ack/v1\n";

/// Lifetimes in seconds (§3.2).
pub const PASSWORD_REQUEST_TTL_S: i64 = 600;
pub const PASSWORD_GRANT_TTL_S: i64 = 300;
pub const PASSWORD_ACK_REPORT_S: i64 = 86_400;
pub const MAX_PASSWORD_SIGNED_P_CHARS: usize = 2048;

/// What `--password` prints once a role is installed (plan §6.3).
pub const CLI_PASSWORD_REFUSED: &str =
    "Kalıcı şifre yalnız Sense Remote içinden, Sense doğrulamasıyla değiştirilir.";

/// Answer code while the feature is off (and on platforms without it).
pub const UNSUPPORTED: &str = "unsupported";

/// A new permanent password (UI → privileged process) or, on macOS, the hashed storage value
/// (daemon → `--server`). Debug and Display never show it; serde carries it as a plain string.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SensePasswordSecret(String);

impl SensePasswordSecret {
    pub fn new(value: String) -> Self {
        Self(value)
    }

    /// The value itself, for the one place that writes it.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

// Sense Remote (PR #50 note for U10): the bytes are overwritten before the memory is freed, so a
// dropped password does not linger in the heap. Zeros keep the `String` valid UTF-8.
impl SensePasswordSecret {
    fn wipe(&mut self) {
        // SAFETY: only zero bytes are written, which keeps the string valid UTF-8.
        let bytes = unsafe { self.0.as_mut_vec() };
        for byte in bytes.iter_mut() {
            // SAFETY: `byte` is a valid, aligned `&mut u8`; volatile so it is not optimized away.
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
        std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    }
}

impl Drop for SensePasswordSecret {
    fn drop(&mut self) {
        self.wipe();
    }
}

impl std::fmt::Debug for SensePasswordSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("***")
    }
}

impl std::fmt::Display for SensePasswordSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("***")
    }
}

/// Payload of `ipc::Data::SensePassword` (§3.7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SensePasswordIpc {
    /// UI → `--server` (macOS: `--server` → daemon): make a nonce, answer a signed request.
    Begin,
    /// Answer to `Begin`: the signed request JSON, or an error code.
    Request(Result<String, String>),
    /// UI → `--server` (macOS: → daemon): the panel's grant and the new password.
    Set {
        grant: String,
        password: SensePasswordSecret,
    },
    /// Answer to `Set`: "" or an error code. `storage`/`salt` only on macOS, daemon →
    /// `--server`, on success (the hashed storage value, never the password).
    SetResult {
        code: String,
        storage: Option<SensePasswordSecret>,
        salt: Option<String>,
    },
    /// Drop the pending nonce.
    Cancel,
    StatusQuery,
    /// Answer to `StatusQuery`: AccessStatus JSON.
    Status(String),
}

/// The answer while the feature is off: requests get `unsupported`, `Cancel` and the answer
/// kinds (which a client must not send) get none.
pub fn unsupported_answer(message: &SensePasswordIpc) -> Option<SensePasswordIpc> {
    match message {
        SensePasswordIpc::Begin => Some(SensePasswordIpc::Request(Err(UNSUPPORTED.to_owned()))),
        SensePasswordIpc::Set { .. } => Some(SensePasswordIpc::SetResult {
            code: UNSUPPORTED.to_owned(),
            storage: None,
            salt: None,
        }),
        SensePasswordIpc::StatusQuery => Some(SensePasswordIpc::Status(
            status::AccessStatus::default().to_json(),
        )),
        SensePasswordIpc::Cancel
        | SensePasswordIpc::Request(_)
        | SensePasswordIpc::SetResult { .. }
        | SensePasswordIpc::Status(_) => None,
    }
}

/// Main IPC channel (`""`), `--server` side. Windows: the SYSTEM `--server` decides
/// (`ipc_win`); macOS: the user `--server` forwards to the root daemon (`ipc_mac`). `None` = no
/// answer. The future must stay `Send`.
pub async fn on_main_ipc(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
    #[cfg(windows)]
    return ipc_win::on_ipc(message).await;
    #[cfg(target_os = "macos")]
    return ipc_mac::forward(message).await;
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = message;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_never_shows_in_debug_or_display() {
        let secret = SensePasswordSecret::new("Gizli-Deneme-42!".to_owned());
        let set = SensePasswordIpc::Set {
            grant: "{}".to_owned(),
            password: secret.clone(),
        };
        let result = SensePasswordIpc::SetResult {
            code: String::new(),
            storage: Some(secret.clone()),
            salt: None,
        };
        for text in [
            format!("{secret:?}"),
            format!("{secret}"),
            format!("{set:?}"),
            format!("{result:?}"),
            format!("{:?}", crate::ipc::Data::SensePassword(set.clone())),
        ] {
            assert!(!text.contains("Gizli"), "{text}");
        }
        assert_eq!(secret.expose(), "Gizli-Deneme-42!");
    }

    #[test]
    fn secret_is_wiped_on_drop() {
        let mut secret = SensePasswordSecret::new("Gizli".to_owned());
        secret.wipe(); // what `Drop` runs
        assert_eq!(secret.expose().as_bytes(), &[0u8; 5]);
    }

    #[test]
    fn secret_is_a_plain_string_on_the_wire() {
        let set = SensePasswordIpc::Set {
            grant: "g".to_owned(),
            password: SensePasswordSecret::new("abc".to_owned()),
        };
        let json = serde_json::to_value(&set).unwrap();
        assert_eq!(json["c"]["password"], "abc");
        let back: SensePasswordIpc = serde_json::from_value(json).unwrap();
        assert_eq!(back, set);
    }

    #[test]
    fn while_off_requests_are_unsupported_and_answers_are_ignored() {
        assert!(!SUPPORTED);
        assert_eq!(
            unsupported_answer(&SensePasswordIpc::Begin),
            Some(SensePasswordIpc::Request(Err("unsupported".to_owned())))
        );
        let set = SensePasswordIpc::Set {
            grant: "{}".to_owned(),
            password: SensePasswordSecret::new("x".to_owned()),
        };
        assert!(matches!(
            unsupported_answer(&set),
            Some(SensePasswordIpc::SetResult { code, storage: None, salt: None }) if code == "unsupported"
        ));
        let Some(SensePasswordIpc::Status(status)) =
            unsupported_answer(&SensePasswordIpc::StatusQuery)
        else {
            panic!("no status");
        };
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&status).unwrap(),
            serde_json::json!({"perm_set": false})
        );
        for ignored in [
            SensePasswordIpc::Cancel,
            SensePasswordIpc::Request(Ok("{}".to_owned())),
            SensePasswordIpc::SetResult {
                code: String::new(),
                storage: None,
                salt: None,
            },
            SensePasswordIpc::Status("{}".to_owned()),
        ] {
            assert_eq!(unsupported_answer(&ignored), None, "{ignored:?}");
        }
    }

    #[test]
    fn prefixes_are_separate_domains() {
        let prefixes = [
            PASSWORD_REQUEST_PREFIX,
            PASSWORD_GRANT_PREFIX,
            PASSWORD_ACK_PREFIX,
        ];
        for (i, a) in prefixes.iter().enumerate() {
            assert!(a.ends_with(b"/v1\n"));
            for b in &prefixes[i + 1..] {
                assert!(!a.starts_with(b) && !b.starts_with(a));
            }
        }
    }
}
