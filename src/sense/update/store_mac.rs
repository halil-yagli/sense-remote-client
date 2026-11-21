//! Sense Remote (update plan 2026-11-21, §3.6): the macOS store. Package U4.
//!
//! `/Library/Application Support/SenseRemote/update.json` holds `store::Persisted` as JSON,
//! root:wheel 0644. Reading and writing follow the `state.json` rules of `mac_state`: `lstat`
//! (no symlink), owner uid 0, `mode & 022 == 0`, `flock`, temp file → `rename`; a file that
//! breaks them is an error, never a value. Only root (the daemon, the guard) writes.
//! The installed version is `SenseRemoteVersion` in
//! `/Applications/SenseRemote.app/Contents/Info.plist`, put there by the packaging script.
//!
//! Compiled on every platform; the file code is `cfg(target_os = "macos")` (U4).
//! MAC-SONRA: checked on a device with the rest of the Mac update (plan §14).

use super::store::Persisted;

/// File name inside `mac_state::STATE_DIR`.
pub const UPDATE_FILE: &str = "update.json";
/// `Info.plist` key with the Sense version number.
pub const INFO_PLIST_VERSION_KEY: &str = "SenseRemoteVersion";

/// U0: no store.
pub fn read() -> Result<Option<Persisted>, String> {
    Err(super::UNSUPPORTED.to_owned())
}

pub fn write(state: &Persisted) -> Result<(), String> {
    let _ = state;
    Err(super::UNSUPPORTED.to_owned())
}

/// `SenseRemoteVersion` of the installed bundle; 0 when missing. U0: not read yet.
pub fn installed_version() -> u32 {
    0
}
