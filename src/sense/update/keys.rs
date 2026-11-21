//! Sense Remote (update plan 2026-11-21, §3.1): the two key lists an update needs.
//!
//! - Panel keys sign the release notice and the order: the existing `SENSE_ENVELOPE_KEYS`.
//! - Build keys sign the build statement: `SENSE_RELEASE_KEYS`, same `k=pub[,k=pub]` format,
//!   fixed at build time (`option_env!`). Only public keys; the private build key is a GitHub
//!   environment secret and never in the repository.
//!
//! Package U1 parses `BUILD_KEYS` (pattern and helpers of `envelope_keys`: `parse_keys`, parsed
//! once, a malformed value trusts nothing and is logged, a test stops such a build in CI).

use crate::sense::envelope_keys::{self, TrustedKey};

/// The value given to the build, `None` when the variable was not set.
pub const BUILD_KEYS: Option<&str> = option_env!("SENSE_RELEASE_KEYS");

/// Keys that may sign a release notice or an order.
pub fn panel_keys() -> &'static [TrustedKey] {
    envelope_keys::trusted_keys()
}

/// Keys that may sign a build statement. U0: none, so no release can pass.
pub fn release_keys() -> &'static [TrustedKey] {
    &[]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_trusts_no_build_key() {
        assert!(release_keys().is_empty());
    }
}
