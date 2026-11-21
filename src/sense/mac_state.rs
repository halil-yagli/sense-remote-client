//! Sense Remote (Mac M0, plan §3.1): the root-owned state file on macOS, the counterpart of
//! `HKLM\SOFTWARE\SenseRemote` on Windows (installed role, setup info, last envelope seq).
//!
//! `/Library/Application Support/SenseRemote/state.json`, directory `root:wheel 0755`, file
//! `root:wheel 0644`: every process reads it, only root (installer step, daemon) writes it.
//!
//! ```json
//! {"v":1,"role":"host|controller|both","setup":"<SetupInfo hex>","envelope_seq":0}
//! ```
//!
//! M0 is the skeleton only: the signatures below are the contract the other Mac packages build
//! on; the bodies have safe defaults (nothing is read, nothing is written), so macOS behaves as
//! before (no role). M1 fills this file in:
//! - read: `lstat`; the file and the directory are no symlinks, owned by uid 0 and
//!   `mode & 0o022 == 0`, otherwise `Err` (G2-5: an unreadable value is not 0); unknown `v` and
//!   broken JSON are `Err`; a missing file is `Ok(None)`.
//! - update: only root (`Err("not-root")` otherwise); read-modify-write under `flock` on
//!   `.lock`, temp file in the same directory (`0644`) → `fsync` → `rename`; `envelope_seq`
//!   never goes back (`envelope_seq::may_store`).

use super::SenseRole;
use std::path::Path;

/// Directory of the state file. The uninstaller removes it, so a reinstall starts at seq 0.
pub const STATE_DIR: &str = "/Library/Application Support/SenseRemote";
/// File name inside `STATE_DIR`.
pub const STATE_FILE: &str = "state.json";
/// Lock file inside `STATE_DIR` (`flock`) for read-modify-write.
pub const LOCK_FILE: &str = ".lock";
/// Value of `v` this build reads and writes.
pub const STATE_VERSION: u32 = 1;

/// `update` / `update_in` result when the caller is not root.
pub const ERR_NOT_ROOT: &str = "not-root";
/// Skeleton result until M1 implements writing.
pub const ERR_UNSUPPORTED: &str = "unsupported";

/// Content of the state file. `setup_hex` is `SetupInfo::encode()` (only `0-9a-f`; no project
/// names, K-YEREL); empty when none was stored.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MacState {
    pub role: Option<SenseRole>,
    pub setup_hex: String,
    pub envelope_seq: u64,
}

/// The installed state; `Ok(None)` when the file does not exist (not installed).
pub fn read() -> Result<Option<MacState>, String> {
    read_in(Path::new(STATE_DIR), true)
}

/// Test door: reads `dir/state.json`. `require_root` = the owner must be uid 0 (off only in
/// tests with a temporary directory).
pub fn read_in(_dir: &Path, _require_root: bool) -> Result<Option<MacState>, String> {
    // M1: lstat checks + JSON. Until then nothing is installed on macOS.
    Ok(None)
}

/// Reads, lets `f` change and writes the state back atomically. Only root.
pub fn update(f: impl FnOnce(&mut MacState)) -> Result<(), String> {
    update_in(Path::new(STATE_DIR), true, f)
}

/// Test door: like `update` in `dir`. `require_root` = the caller must be root and the file
/// root-owned.
pub fn update_in(
    _dir: &Path,
    _require_root: bool,
    _f: impl FnOnce(&mut MacState),
) -> Result<(), String> {
    // M1: flock + temp file + fsync + rename. Until then nothing is written.
    Err(ERR_UNSUPPORTED.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Skeleton defaults (M1 replaces this test with the §3.1 ones).
    #[test]
    fn skeleton_reads_nothing_and_writes_nothing() {
        let dir = std::env::temp_dir();
        assert_eq!(read_in(&dir, false), Ok(None));
        let mut called = false;
        assert_eq!(
            update_in(&dir, false, |_| called = true),
            Err(ERR_UNSUPPORTED.to_owned())
        );
        assert!(!called);
    }
}
