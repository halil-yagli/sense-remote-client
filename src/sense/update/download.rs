//! Sense Remote (update plan 2026-11-21, §3.6): downloading the installer. Package U2.
//!
//! - Source: only `Release::url`, which `manifest::verify` has tied to
//!   `API_SERVER + "/indir/" + file`. The panel's HTTP client is used (`hbb_common`, TLS with
//!   certificate checks); no other host: a redirect that ends on another origin is refused.
//! - Target: the privileged folder, made safe once per download
//!   (`super::apply::prepare_download_dir`): Windows `C:\ProgramData\SenseRemote\update\dl\` (ACL SYSTEM + Administrators only, reparse points
//!   refused), macOS a root 0700 `mktemp -d` folder. Written as `<file>.part`, renamed to
//!   `<file>` only when complete and matching; any failure removes the part.
//! - Stops as soon as more than `size` bytes arrive (`size_mismatch`; a shorter body is
//!   `size_mismatch` too); whole download at most `TIMEOUT_S` (`download_failed`); SHA-256
//!   computed while streaming (`hash_mismatch`).
//! - `DISK_FACTOR × size` free bytes are needed before it starts (`disk_space`, the engine).
//! - Nothing of the response is logged but sizes and the result.

use super::{engine::DISK_FACTOR, UpdateError};
use hbb_common::{log, tokio};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

/// Whole download.
pub const TIMEOUT_S: u64 = 30 * 60;
/// Suffix of the file while it is written.
pub const PART_SUFFIX: &str = ".part";

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
/// and matches size and SHA-256.
pub async fn fetch(
    request: &Request,
    on_progress: &(dyn Fn(u8) + Send + Sync),
) -> Result<PathBuf, UpdateError> {
    let client = if request.url.starts_with("https://") {
        crate::hbbs_http::create_http_client_async_with_url_strict(&request.url)
            .await
            .map_err(|err| {
                log::warn!("Sense Remote: update download client: {err}");
                UpdateError::DownloadFailed
            })?
    } else {
        // Only a build whose `API_SERVER` is plain http (local tests) gets here: the notice's
        // `url` must start with this build's `API_SERVER` (`manifest`, step 9).
        crate::hbbs_http::create_http_client_async(hbb_common::tls::TlsType::Rustls, false)
    };
    fetch_with(&client, request, Duration::from_secs(TIMEOUT_S), on_progress).await
}

/// `fetch` with a given client and time limit (tests use a local server).
pub async fn fetch_with(
    client: &reqwest::Client,
    request: &Request,
    limit: Duration,
    on_progress: &(dyn Fn(u8) + Send + Sync),
) -> Result<PathBuf, UpdateError> {
    if !is_plain_file_name(&request.file) {
        return Err(UpdateError::DownloadFailed);
    }
    let part = request.dir.join(format!("{}{PART_SUFFIX}", request.file));
    let target = request.dir.join(&request.file);
    let result = match tokio::time::timeout(limit, fetch_into(client, request, &part, on_progress))
        .await
    {
        Ok(result) => result,
        Err(_) => Err(UpdateError::DownloadFailed),
    };
    let result = result.and_then(|()| {
        std::fs::rename(&part, &target).map_err(|_| UpdateError::DownloadFailed)
    });
    match result {
        Ok(()) => {
            log::info!("Sense Remote: update downloaded, {} bytes", request.size);
            Ok(target)
        }
        Err(err) => {
            let _ = std::fs::remove_file(&part);
            log::warn!("Sense Remote: update download failed: {}", err.as_str());
            Err(err)
        }
    }
}

async fn fetch_into(
    client: &reqwest::Client,
    request: &Request,
    part: &Path,
    on_progress: &(dyn Fn(u8) + Send + Sync),
) -> Result<(), UpdateError> {
    let failed = |_| UpdateError::DownloadFailed;
    let mut response = client.get(&request.url).send().await.map_err(failed)?;
    if !response.status().is_success() || !same_origin(response.url().as_str(), &request.url) {
        return Err(UpdateError::DownloadFailed);
    }
    if response
        .content_length()
        .is_some_and(|length| length != request.size)
    {
        return Err(UpdateError::SizeMismatch);
    }
    let _ = std::fs::remove_file(part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(part)
        .map_err(|_| UpdateError::DownloadFailed)?;
    let mut check = Check::new(request.size);
    let mut shown = 0;
    on_progress(shown);
    while let Some(chunk) = response.chunk().await.map_err(failed)? {
        check.push(&chunk)?;
        file.write_all(&chunk).map_err(|_| UpdateError::DownloadFailed)?;
        let pct = check.progress();
        if pct != shown {
            shown = pct;
            on_progress(pct);
        }
    }
    file.sync_all().map_err(|_| UpdateError::DownloadFailed)?;
    check.finish(&request.sha256)
}

/// Size and SHA-256 of a byte stream, checked while it arrives.
pub struct Check {
    size: u64,
    received: u64,
    hasher: Sha256,
}

impl Check {
    pub fn new(size: u64) -> Self {
        Self {
            size,
            received: 0,
            hasher: Sha256::new(),
        }
    }

    /// `size_mismatch` as soon as more than `size` bytes came.
    pub fn push(&mut self, chunk: &[u8]) -> Result<(), UpdateError> {
        self.received = self.received.saturating_add(chunk.len() as u64);
        if self.received > self.size {
            return Err(UpdateError::SizeMismatch);
        }
        self.hasher.update(chunk);
        Ok(())
    }

    pub fn progress(&self) -> u8 {
        if self.size == 0 {
            return 100;
        }
        (u128::from(self.received) * 100 / u128::from(self.size)).min(100) as u8
    }

    pub fn finish(self, sha256: &str) -> Result<(), UpdateError> {
        if self.received != self.size {
            return Err(UpdateError::SizeMismatch);
        }
        if !hex::encode(self.hasher.finalize()).eq_ignore_ascii_case(sha256) {
            return Err(UpdateError::HashMismatch);
        }
        Ok(())
    }
}

/// Size and SHA-256 of a downloaded file once more (blocking).
pub fn verify_file(path: &Path, size: u64, sha256: &str) -> Result<(), UpdateError> {
    let mut file = std::fs::File::open(path).map_err(|_| UpdateError::DownloadFailed)?;
    let mut check = Check::new(size);
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| UpdateError::DownloadFailed)?;
        if read == 0 {
            break;
        }
        check.push(&buffer[..read])?;
    }
    check.finish(sha256)
}

/// Room for the downloaded file, the verified copy and the backup.
pub fn enough_disk(free_bytes: u64, size: u64) -> bool {
    free_bytes >= size.saturating_mul(DISK_FACTOR)
}

/// Free bytes on the volume holding `dir`.
pub fn free_bytes(dir: &Path) -> Option<u64> {
    let disks = hbb_common::sysinfo::Disks::new_with_refreshed_list();
    let mounts: Vec<(PathBuf, u64)> = disks
        .list()
        .iter()
        .map(|disk| (disk.mount_point().to_path_buf(), disk.available_space()))
        .collect();
    free_on(&mounts, dir)
}

/// The deepest mount point that holds `path`.
pub fn free_on(mounts: &[(PathBuf, u64)], path: &Path) -> Option<u64> {
    mounts
        .iter()
        .filter(|(mount, _)| path.starts_with(mount))
        .max_by_key(|(mount, _)| mount.components().count())
        .map(|(_, free)| *free)
}

/// A single file name: no separator, no `..`, nothing hidden or empty.
pub fn is_plain_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

/// Scheme, host and port equal (after redirects the answer must still come from the panel).
pub fn same_origin(a: &str, b: &str) -> bool {
    match (url::Url::parse(a), url::Url::parse(b)) {
        (Ok(a), Ok(b)) => {
            a.scheme() == b.scheme()
                && a.host_str() == b.host_str()
                && a.port_or_known_default() == b.port_or_known_default()
        }
        _ => false,
    }
}

#[cfg(test)]
#[path = "download_tests.rs"]
mod tests;
