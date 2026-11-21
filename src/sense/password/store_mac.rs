//! Sense Remote (permanent password plan §3.9, U12): macOS local record
//! `/Library/Application Support/SenseRemote/access.json` (root:wheel 0644, `state.json` rules;
//! never the password or its hash). U9: nothing is stored.

pub const ACCESS_FILE: &str = "/Library/Application Support/SenseRemote/access.json";

/// `(changed_at, last ack JSON, ack_at)`. U9: `None`.
pub fn read() -> Option<(i64, Option<String>, Option<i64>)> {
    None
}
