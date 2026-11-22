//! Sense Remote (permanent password plan §2.1, §3.3 step 9): the one pending nonce of the
//! privileged process (in memory, 10 minutes, dropped after 5 failed grant checks, used up on
//! success). U9: nothing is ever pending; U10 implements it.

/// Failed grant checks after which the pending nonce is dropped.
pub const MAX_FAILED_CHECKS: u32 = 5;

#[derive(Debug, Default)]
pub struct Pending {
    _private: (),
}

impl Pending {
    /// A new nonce (base64url, 16 bytes) that replaces any pending one. U9: none.
    pub fn begin(&mut self, now: i64) -> Option<String> {
        let _ = now;
        None
    }

    /// Step 9: `Ok` when `nonce` is the pending one and has not expired. U9: `no_pending`.
    pub fn matches(&mut self, nonce: &str, now: i64) -> Result<(), super::grant::GrantError> {
        let _ = (nonce, now);
        Err(super::grant::GrantError::NoPending)
    }

    pub fn cancel(&mut self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_pending_while_off() {
        let mut pending = Pending::default();
        assert_eq!(pending.begin(0), None);
        assert_eq!(
            pending.matches("AAAAAAAAAAAAAAAAAAAAAA", 0),
            Err(super::super::grant::GrantError::NoPending)
        );
    }
}
