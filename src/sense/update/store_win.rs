//! Sense Remote (update plan 2026-11-21, §3.6): the Windows store. Package U3.
//!
//! `HKLM\SOFTWARE\SenseRemote\Update` holds `store::Persisted` (one registry value per field,
//! names in `store.rs`); the key gets the same ACL as `Role` / `Setup` (administrators and
//! SYSTEM write, users read), with the helper the installer uses. `Version` sits next to
//! `Role`: the installer writes it (`sense::install_commands`, U0), U3 writes it after an
//! update. Only SYSTEM (`--server`, the guard) and the elevated installer write here.
//!
//! Compiled on every platform; the registry code is `cfg(windows)` (U3), elsewhere the
//! functions answer "unsupported".

use super::store::Persisted;

/// Subkey of HKLM with the update state.
pub const REG_SUBKEY_UPDATE: &str = "SOFTWARE\\SenseRemote\\Update";

/// U0: no store.
pub fn read() -> Result<Option<Persisted>, String> {
    Err(super::UNSUPPORTED.to_owned())
}

pub fn write(state: &Persisted) -> Result<(), String> {
    let _ = state;
    Err(super::UNSUPPORTED.to_owned())
}

/// HKLM `Version`; 0 when missing or not a version number. Reads what the installer wrote.
pub fn installed_version() -> u32 {
    crate::sense::installed_version().unwrap_or(0)
}

/// Writes HKLM `Version` after an update (SYSTEM). U0: not written.
pub fn store_installed_version(version: u32) -> Result<(), String> {
    let _ = version;
    Err(super::UNSUPPORTED.to_owned())
}
