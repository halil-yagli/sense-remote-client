//! Sense Remote (permanent password plan §3.9, U11): Windows local record under
//! `HKLM\SOFTWARE\SenseRemote\Access` (`PasswordChangedAt`, `LastAck`, `LastAckAt`; never the
//! password or its hash). Only the SYSTEM `--server` writes it. The key sits under the
//! `SenseRemote` key the elevated installer made (`Role`, `Setup`) and inherits its ACL:
//! administrators and SYSTEM write, standard users read (the ack is signed, not secret).

use super::status::AccessRecord;

/// Registry subkey of the record (ACL as `Role` / `Setup`).
pub const ACCESS_SUBKEY: &str = "SOFTWARE\\SenseRemote\\Access";
pub const VALUE_CHANGED_AT: &str = "PasswordChangedAt";
pub const VALUE_LAST_ACK: &str = "LastAck";
pub const VALUE_LAST_ACK_AT: &str = "LastAckAt";

/// The registry stores QWORDs; the record keeps Unix seconds. A negative time (a clock before
/// 1970) is not stored.
fn to_qword(value: i64) -> Option<u64> {
    u64::try_from(value).ok()
}

fn from_qword(value: u64) -> Option<i64> {
    i64::try_from(value)
        .ok()
        .filter(|v| *v <= super::grant::MAX_UNIX_SECONDS)
}

/// The record of the last change; `None` when there was none (or it can not be read).
#[cfg(windows)]
pub fn read() -> Option<AccessRecord> {
    read_in(ACCESS_SUBKEY)
}

/// Replaces the record (SYSTEM `--server` only).
#[cfg(windows)]
pub fn write(record: &AccessRecord) -> Result<(), String> {
    write_in(ACCESS_SUBKEY, record)
}

#[cfg(not(windows))]
pub fn read() -> Option<AccessRecord> {
    None
}

// Sense Remote: the subkey is a parameter so a test can use its own key, never the product's.
#[cfg(windows)]
fn read_in(subkey: &str) -> Option<AccessRecord> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let key = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(subkey).ok()?;
    let changed_at = from_qword(key.get_value::<u64, _>(VALUE_CHANGED_AT).ok()?)?;
    let ack = key.get_value::<String, _>(VALUE_LAST_ACK).ok();
    let ack_at = key
        .get_value::<u64, _>(VALUE_LAST_ACK_AT)
        .ok()
        .and_then(from_qword);
    // An ack without its time (or the other way round) is not reported.
    let (ack, ack_at) = match (ack, ack_at) {
        (Some(ack), Some(at)) => (Some(ack), Some(at)),
        _ => (None, None),
    };
    Some(AccessRecord {
        changed_at,
        ack,
        ack_at,
    })
}

#[cfg(windows)]
fn write_in(subkey: &str, record: &AccessRecord) -> Result<(), String> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let changed_at = to_qword(record.changed_at).ok_or("changed_at before 1970")?;
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey(subkey)
        .map_err(|err| format!("registry key not writable: {:?}", err.kind()))?;
    let set = |result: std::io::Result<()>| {
        result.map_err(|err| format!("registry value not writable: {:?}", err.kind()))
    };
    // The old ack goes first, so a half-written record never pairs a new time with an old ack.
    let _ = key.delete_value(VALUE_LAST_ACK);
    let _ = key.delete_value(VALUE_LAST_ACK_AT);
    set(key.set_value(VALUE_CHANGED_AT, &changed_at))?;
    if let (Some(ack), Some(at)) = (&record.ack, record.ack_at.and_then(to_qword)) {
        set(key.set_value(VALUE_LAST_ACK, ack))?;
        set(key.set_value(VALUE_LAST_ACK_AT, &at))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_map_to_qwords_and_back() {
        assert_eq!(to_qword(1_800_000_000), Some(1_800_000_000));
        assert_eq!(to_qword(-1), None);
        assert_eq!(from_qword(1_800_000_000), Some(1_800_000_000));
        assert_eq!(from_qword(u64::MAX), None);
        assert_eq!(from_qword(10_000_000_000), None); // milliseconds, not seconds
    }

    #[test]
    fn the_record_lives_under_the_role_key() {
        assert!(ACCESS_SUBKEY.starts_with(crate::sense::REG_SUBKEY));
        assert_eq!(ACCESS_SUBKEY, "SOFTWARE\\SenseRemote\\Access");
    }

    // Windows CI (elevated runner): write and read back in a test key, never the product's.
    #[cfg(windows)]
    #[test]
    fn record_round_trip_in_hklm() {
        use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
        if !crate::platform::is_elevated(None).unwrap_or(false) {
            // Writing HKLM needs an administrator; only a local, not elevated run may skip.
            assert!(std::env::var_os("GITHUB_ACTIONS").is_none(), "CI runs elevated");
            return;
        }
        let subkey = format!("SOFTWARE\\SenseRemoteTest-{}\\Access", std::process::id());
        let parent = subkey.rsplit_once('\\').unwrap().0.to_owned();
        let with_ack = AccessRecord::after_change(1_800_000_000, Some("{\"k\":\"x\"}".to_owned()));
        let written = write_in(&subkey, &with_ack);
        let back = read_in(&subkey);
        let without_ack = AccessRecord::after_change(1_800_000_100, None);
        let rewritten = write_in(&subkey, &without_ack);
        let back2 = read_in(&subkey);
        let _ = RegKey::predef(HKEY_LOCAL_MACHINE).delete_subkey_all(&parent);
        assert_eq!(written, Ok(()));
        assert_eq!(back, Some(with_ack));
        assert_eq!(rewritten, Ok(()));
        // The old ack does not stay next to the new time.
        assert_eq!(back2, Some(without_ack));
        assert_eq!(read_in(&subkey), None);
    }
}
