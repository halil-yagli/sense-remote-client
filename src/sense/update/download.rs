//! Sense Remote (update plan 2026-11-21, §3.6): downloading the installer. Package U2.
//!
//! - Source: only `Release::url`, which `manifest::verify` has tied to
//!   `API_SERVER + "/indir/" + file`. The panel's HTTP client is used (`hbb_common`, TLS); no
//!   proxy fallback, no other host, no redirect to another host.
//! - Target: the privileged folder (`super::apply::download_dir`): Windows
//!   `C:\ProgramData\SenseRemote\update\dl\` (ACL SYSTEM + Administrators only, reparse points
//!   refused), macOS a root 0700 `mktemp -d` folder.
//! - Stops as soon as more than `size` bytes arrive (`size_mismatch`); whole download at most
//!   `TIMEOUT_S` (`download_failed`); SHA-256 computed while streaming (`hash_mismatch`).
//! - `DISK_FACTOR × size` free bytes are needed before it starts (`disk_space`).
//! - Nothing of the response is logged but sizes and the result.

use super::{engine::DISK_FACTOR, UpdateError};
use std::path::PathBuf;

/// Whole download.
pub const TIMEOUT_S: u64 = 30 * 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub url: String,
    /// Expected SHA-256, lowercase hex.
    pub sha256: String,
    /// Expected size in bytes.
    pub size: u64,
    /// Privileged download folder.
    pub dir: PathBuf,
    /// File name inside `dir` (`Release::file`).
    pub file: String,
}

/// Downloads and checks one installer; `on_progress` gets 0–100. `Ok` = the file is complete
/// and matches size and SHA-256. U0: nothing is downloaded.
pub async fn fetch(
    request: &Request,
    on_progress: &(dyn Fn(u8) + Send + Sync),
) -> Result<PathBuf, UpdateError> {
    let _ = (request, on_progress);
    Err(UpdateError::Unsupported)
}

/// Room for the downloaded file, the verified copy and the backup.
pub fn enough_disk(free_bytes: u64, size: u64) -> bool {
    free_bytes >= size.saturating_mul(DISK_FACTOR)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disk_needs_three_times_the_size() {
        assert!(enough_disk(300, 100));
        assert!(!enough_disk(299, 100));
        assert!(!enough_disk(u64::MAX - 1, u64::MAX / 2));
        assert!(enough_disk(0, 0));
    }
}
