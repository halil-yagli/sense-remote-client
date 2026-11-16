//! Sense Remote: `last_seq`, the seq of the last envelope applied on this computer (plan SEQ).
//!
//! Windows: `HKEY_LOCAL_MACHINE\SOFTWARE\SenseRemote` → `EnvelopeSeq` (REG_QWORD), next to the
//! installed role, so a standard user can read it but not roll it back to replay an old envelope.
//! The `--server` process runs as SYSTEM and can write it. The uninstaller deletes the whole key,
//! so a reinstall starts from 0 and the panel re-signs its last set with a new seq.
//!
//! MAC-SONRA-9: root-owned file under `/Library/Application Support/SenseRemote/`. Until then
//! macOS reads 0 and refuses to store (envelopes are verified there but not applied).

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

/// Last applied seq, 0 when none was stored (fresh install) or it cannot be read.
#[cfg(windows)]
pub fn last_seq() -> u64 {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(super::REG_SUBKEY)
        .and_then(|key| key.get_value::<u64, _>(REG_VALUE_ENVELOPE_SEQ))
        .unwrap_or(0)
}

#[cfg(not(windows))]
pub fn last_seq() -> u64 {
    0
}

/// Stores `seq` after the envelope was applied successfully. Never lowers the value.
#[cfg(windows)]
pub fn store_last_seq(seq: u64) -> Result<(), StoreError> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    may_store(last_seq(), seq)?;
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey(super::REG_SUBKEY)
        .map_err(|err| StoreError::Io(err.to_string()))?;
    key.set_value(REG_VALUE_ENVELOPE_SEQ, &seq)
        .map_err(|err| StoreError::Io(err.to_string()))
}

#[cfg(not(windows))]
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
}
