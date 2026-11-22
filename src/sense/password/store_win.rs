//! Sense Remote (permanent password plan §3.9, U11): Windows local record under
//! `HKLM\SOFTWARE\SenseRemote\Access` (`PasswordChangedAt`, `LastAck`, `LastAckAt`; never the
//! password or its hash). U9: nothing is stored.

/// Registry subkey of the record (ACL as `Role` / `Setup`).
pub const ACCESS_SUBKEY: &str = "SOFTWARE\\SenseRemote\\Access";

/// `(changed_at, last ack JSON, ack_at)`. U9: `None`.
pub fn read() -> Option<(i64, Option<String>, Option<i64>)> {
    None
}
