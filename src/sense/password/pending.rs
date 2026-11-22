//! Sense Remote (permanent password plan §2.1, §3.3 step 9): the one pending nonce of the
//! privileged process. In memory only; 10 minutes on the monotonic clock (`Instant`, so moving
//! the wall clock neither extends nor shortens it); dropped after 5 failed grant checks; used up
//! on success; a new `begin` replaces it. Compared in constant time.

use super::grant::GrantError;
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::{self, randombytes::randombytes_into, utils::memcmp},
};
use std::time::{Duration, Instant};

/// Failed grant checks after which the pending nonce is dropped.
pub const MAX_FAILED_CHECKS: u32 = 5;
/// Lifetime of a pending nonce (= the request's `exp - iat`).
pub const LIFETIME: Duration = Duration::from_secs(super::PASSWORD_REQUEST_TTL_S as u64);

struct Entry {
    nonce: String,
    started: Instant,
    failures: u32,
}

#[derive(Default)]
pub struct Pending {
    current: Option<Entry>,
}

// The nonce is a capability: never in Debug output.
impl std::fmt::Debug for Pending {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Pending")
            .field("pending", &self.current.is_some())
            .finish()
    }
}

impl Pending {
    /// A new random nonce (16 bytes, unpadded base64url) that replaces any pending one. `None`
    /// only when the random source can not be used.
    pub fn begin(&mut self, now: Instant) -> Option<String> {
        if sodiumoxide::init().is_err() {
            return None;
        }
        let mut bytes = [0u8; 16];
        randombytes_into(&mut bytes);
        Some(self.begin_with(bytes, now))
    }

    /// `begin` with given bytes (tests).
    pub(super) fn begin_with(&mut self, bytes: [u8; 16], now: Instant) -> String {
        let nonce = URL_SAFE_NO_PAD.encode(bytes);
        self.current = Some(Entry {
            nonce: nonce.clone(),
            started: now,
            failures: 0,
        });
        nonce
    }

    /// Drops the nonce once its lifetime is over.
    fn expire(&mut self, now: Instant) {
        if self
            .current
            .as_ref()
            .is_some_and(|e| now.saturating_duration_since(e.started) >= LIFETIME)
        {
            self.current = None;
        }
    }

    pub fn is_pending(&mut self, now: Instant) -> bool {
        self.expire(now);
        self.current.is_some()
    }

    /// Step 9: `Ok` when `nonce` is the pending one and has not expired. A mismatch counts as a
    /// failed check. The nonce stays pending; `consume` uses it up.
    pub fn matches(&mut self, nonce: &str, now: Instant) -> Result<(), GrantError> {
        self.expire(now);
        let Some(entry) = self.current.as_ref() else {
            return Err(GrantError::NoPending);
        };
        let equal = entry.nonce.len() == nonce.len()
            && sodiumoxide::init().is_ok()
            && memcmp(entry.nonce.as_bytes(), nonce.as_bytes());
        if equal {
            Ok(())
        } else {
            self.record_failure(now);
            Err(GrantError::NonceMismatch)
        }
    }

    /// A failed grant check against the pending nonce.
    pub fn record_failure(&mut self, now: Instant) {
        self.expire(now);
        if let Some(entry) = self.current.as_mut() {
            entry.failures += 1;
            if entry.failures >= MAX_FAILED_CHECKS {
                self.current = None;
            }
        }
    }

    /// Success: the nonce is used up (single use).
    pub fn consume(&mut self) {
        self.current = None;
    }

    pub fn cancel(&mut self) {
        self.current = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OTHER: &str = "b3RoZXItdGVzdC1ub25jZQ";

    #[test]
    fn nothing_is_pending_at_first() {
        let mut pending = Pending::default();
        let now = Instant::now();
        assert!(!pending.is_pending(now));
        assert_eq!(pending.matches(OTHER, now), Err(GrantError::NoPending));
    }

    #[test]
    fn begin_makes_a_canonical_random_nonce() {
        let mut pending = Pending::default();
        let now = Instant::now();
        let a = pending.begin(now).unwrap();
        assert!(super::super::grant::is_nonce(&a), "{a}");
        let b = pending.begin(now).unwrap();
        assert_ne!(a, b);
        // The new one replaces the old one.
        assert_eq!(pending.matches(&a, now), Err(GrantError::NonceMismatch));
        assert_eq!(pending.matches(&b, now), Ok(()));
        assert!(!format!("{pending:?}").contains(&b));
    }

    #[test]
    fn single_use() {
        let mut pending = Pending::default();
        let now = Instant::now();
        let nonce = pending.begin_with(*b"sense-test-nonce", now);
        assert_eq!(nonce, "c2Vuc2UtdGVzdC1ub25jZQ");
        assert_eq!(pending.matches(&nonce, now), Ok(()));
        pending.consume();
        assert_eq!(pending.matches(&nonce, now), Err(GrantError::NoPending));
    }

    #[test]
    fn lifetime_is_ten_minutes_on_the_monotonic_clock() {
        let mut pending = Pending::default();
        let start = Instant::now();
        let nonce = pending.begin_with(*b"sense-test-nonce", start);
        let almost = start + LIFETIME - Duration::from_secs(1);
        assert_eq!(pending.matches(&nonce, almost), Ok(()));
        assert_eq!(pending.matches(&nonce, start + LIFETIME), Err(GrantError::NoPending));
        assert!(!pending.is_pending(start + LIFETIME));
    }

    #[test]
    fn dropped_after_five_failed_checks() {
        let mut pending = Pending::default();
        let now = Instant::now();
        let nonce = pending.begin_with(*b"sense-test-nonce", now);
        for _ in 0..MAX_FAILED_CHECKS - 1 {
            assert_eq!(pending.matches(OTHER, now), Err(GrantError::NonceMismatch));
        }
        assert_eq!(pending.matches(&nonce, now), Ok(()));
        pending.record_failure(now); // fifth failure
        assert_eq!(pending.matches(&nonce, now), Err(GrantError::NoPending));
    }

    #[test]
    fn cancel_drops_it() {
        let mut pending = Pending::default();
        let now = Instant::now();
        let nonce = pending.begin_with(*b"sense-test-nonce", now);
        pending.cancel();
        assert_eq!(pending.matches(&nonce, now), Err(GrantError::NoPending));
    }
}
