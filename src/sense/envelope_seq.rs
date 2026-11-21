//! Sense Remote: `last_seq`, the seq of the last envelope applied on this computer (plan SEQ).
//!
//! Windows: `HKEY_LOCAL_MACHINE\SOFTWARE\SenseRemote` → `EnvelopeSeq` (REG_QWORD), next to the
//! installed role, so a standard user can read it but not roll it back to replay an old envelope.
//! The `--server` process runs as SYSTEM and can write it. The uninstaller deletes the whole key,
//! so a reinstall starts from 0 and the panel re-signs its last set with a new seq.
//!
//! macOS (plan 2026-11-21 §3.1, §3.3): `envelope_seq` in the root-owned state file
//! (`mac_state`). Every process can read it; only root can store it, so the user process
//! forwards envelopes to the daemon, which verifies them again and stores the seq
//! (`mac_apply`). The uninstaller removes the state directory, so a reinstall starts from 0.
//!
//! Sense Remote (G2-5, G2-6): a value that exists but cannot be read is an error, not 0, and
//! `check_writable` runs before an envelope changes anything.

const REG_VALUE_ENVELOPE_SEQ: &str = "EnvelopeSeq";

/// Why `store_last_seq` did not write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// `seq` is not above the stored value: the counter never goes back.
    NotIncreasing { stored: u64, seq: u64 },
    Io(String),
    UnsupportedPlatform,
}

/// The counter only moves forward.
pub fn may_store(stored: u64, seq: u64) -> Result<(), StoreError> {
    if seq > stored {
        Ok(())
    } else {
        Err(StoreError::NotIncreasing { stored, seq })
    }
}

/// Sense Remote (G2-5): a read result → `last_seq`. Only "no key / no value" (fresh install) is 0;
/// any other error (access denied, wrong value type ...) is an error, so the caller applies
/// nothing instead of treating the counter as 0 and accepting an old envelope again.
pub fn seq_or_missing(result: std::io::Result<u64>) -> Result<u64, String> {
    match result {
        Ok(seq) => Ok(seq),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(err) => Err(err.to_string()),
    }
}

/// Last applied seq: 0 when none was stored (fresh install), an error when it cannot be read.
#[cfg(windows)]
pub fn read_last_seq() -> Result<u64, String> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    seq_or_missing(
        RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey(super::REG_SUBKEY)
            .and_then(|key| key.get_value::<u64, _>(REG_VALUE_ENVELOPE_SEQ)),
    )
}

/// Sense Remote (Mac M0): no state file is a fresh install (0); a file that cannot be used is an
/// error (G2-5), never 0.
#[cfg(target_os = "macos")]
pub fn read_last_seq() -> Result<u64, String> {
    seq_of(super::mac_state::read())
}

/// Pure part: one read of the state file → `last_seq`. No file (not installed) is 0, a file
/// that can not be used is an error (G2-5).
#[cfg(target_os = "macos")]
fn seq_of(read: Result<Option<super::mac_state::MacState>, String>) -> Result<u64, String> {
    Ok(read?.map_or(0, |state| state.envelope_seq))
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn read_last_seq() -> Result<u64, String> {
    Ok(0)
}

/// Sense Remote (G2-6): proves before anything is changed that the seq can be written: opens the
/// key for writing and writes the stored value back unchanged. An apply that could not store its
/// seq at the end is refused up front, with the computer untouched.
#[cfg(windows)]
pub fn check_writable() -> Result<(), StoreError> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey(super::REG_SUBKEY)
        .map_err(|err| StoreError::Io(err.to_string()))?;
    let stored = seq_or_missing(key.get_value::<u64, _>(REG_VALUE_ENVELOPE_SEQ))
        .map_err(StoreError::Io)?;
    if stored > 0 {
        key.set_value(REG_VALUE_ENVELOPE_SEQ, &stored)
            .map_err(|err| StoreError::Io(err.to_string()))?;
    }
    Ok(())
}

/// Sense Remote: rewrites the state unchanged; fails for every process but root.
#[cfg(target_os = "macos")]
pub fn check_writable() -> Result<(), StoreError> {
    super::mac_state::update(|_| {}).map_err(StoreError::Io)
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn check_writable() -> Result<(), StoreError> {
    Err(StoreError::UnsupportedPlatform)
}

/// Stores `seq` after the envelope was applied successfully. Never lowers the value.
#[cfg(windows)]
pub fn store_last_seq(seq: u64) -> Result<(), StoreError> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    may_store(read_last_seq().map_err(StoreError::Io)?, seq)?;
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey(super::REG_SUBKEY)
        .map_err(|err| StoreError::Io(err.to_string()))?;
    key.set_value(REG_VALUE_ENVELOPE_SEQ, &seq)
        .map_err(|err| StoreError::Io(err.to_string()))
}

/// Sense Remote: the comparison and the write happen inside one `mac_state` update (under its
/// lock), so two writers can not move the counter back.
#[cfg(target_os = "macos")]
pub fn store_last_seq(seq: u64) -> Result<(), StoreError> {
    store_seq_in(std::path::Path::new(super::mac_state::STATE_DIR), true, seq)
}

/// `store_last_seq` for the state in `dir` (`mac_state::update_in`; `require_root` is off only
/// in tests with a temporary directory).
#[cfg(target_os = "macos")]
fn store_seq_in(dir: &std::path::Path, require_root: bool, seq: u64) -> Result<(), StoreError> {
    let mut checked = Ok(());
    super::mac_state::update_in(dir, require_root, |state| {
        checked = may_store(state.envelope_seq, seq);
        if checked.is_ok() {
            state.envelope_seq = seq;
        }
    })
    .map_err(StoreError::Io)?;
    checked
}

#[cfg(not(any(windows, target_os = "macos")))]
pub fn store_last_seq(_seq: u64) -> Result<(), StoreError> {
    Err(StoreError::UnsupportedPlatform)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_only_moves_forward() {
        assert_eq!(may_store(0, 1), Ok(()));
        assert_eq!(may_store(41, 42), Ok(()));
        assert_eq!(
            may_store(42, 42),
            Err(StoreError::NotIncreasing { stored: 42, seq: 42 })
        );
        assert_eq!(
            may_store(42, 7),
            Err(StoreError::NotIncreasing { stored: 42, seq: 7 })
        );
    }

    // Sense Remote (K4-6): the macOS seq against a temporary state directory. The real
    // `/Library/Application Support/SenseRemote` is never read, so the result is the same on a
    // Mac with Sense Remote installed.
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_seq_lives_in_the_state_file() {
        use crate::sense::mac_state;
        let base = std::env::temp_dir().join(format!("sense-seq-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let dir = base.join("SenseRemote");
        let read = || seq_of(mac_state::read_in(&dir, false));
        // Not installed: 0.
        assert_eq!(read(), Ok(0));
        assert_eq!(store_seq_in(&dir, false, 7), Ok(()));
        assert_eq!(read(), Ok(7));
        // The counter never goes back, and a refused seq changes nothing.
        for seq in [7, 3] {
            assert_eq!(
                store_seq_in(&dir, false, seq),
                Err(StoreError::NotIncreasing { stored: 7, seq })
            );
        }
        assert_eq!(read(), Ok(7));
        assert_eq!(store_seq_in(&dir, false, 8), Ok(()));
        assert_eq!(read(), Ok(8));
        // The real rule: a process that is not root stores nothing.
        if unsafe { hbb_common::libc::geteuid() } != 0 {
            assert_eq!(
                store_seq_in(&dir, true, 9),
                Err(StoreError::Io(mac_state::ERR_NOT_ROOT.to_owned()))
            );
            assert_eq!(read(), Ok(8));
        }
        // A file that can not be used is an error, not 0 (G2-5), and is not written over.
        std::fs::write(dir.join(mac_state::STATE_FILE), "not json").unwrap();
        assert!(read().is_err());
        assert!(matches!(store_seq_in(&dir, false, 9), Err(StoreError::Io(_))));
        assert_eq!(
            std::fs::read_to_string(dir.join(mac_state::STATE_FILE)).unwrap(),
            "not json"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn only_a_missing_value_reads_as_zero() {
        use std::io::{Error, ErrorKind};
        assert_eq!(seq_or_missing(Ok(9)), Ok(9));
        assert_eq!(seq_or_missing(Err(Error::from(ErrorKind::NotFound))), Ok(0));
        // Access denied, a REG_DWORD / REG_SZ value (winreg: InvalidData) ... → not 0.
        for kind in [ErrorKind::PermissionDenied, ErrorKind::InvalidData, ErrorKind::Other] {
            assert!(seq_or_missing(Err(Error::from(kind))).is_err(), "{kind:?}");
        }
    }
}
