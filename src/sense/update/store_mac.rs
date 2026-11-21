//! Sense Remote (update plan 2026-11-21, §3.6): the macOS store. Package U4.
//!
//! `/Library/Application Support/SenseRemote/update.json` holds `store::Persisted` as JSON,
//! root:wheel 0644. Reading and writing follow the `state.json` rules of `mac_state`: `lstat`
//! (no symlink), owner uid 0, `mode & 022 == 0`, `flock`, temp file → `rename`; a file that
//! breaks them is an error, never a value. Only root (the daemon, the guard) writes. The state
//! directory itself is the installer's (`mac_state`); this store never creates it.
//! The installed version is `SenseRemoteVersion` in
//! `/Applications/SenseRemote.app/Contents/Info.plist`, put there by the packaging script as a
//! string (U5).
//!
//! The file code is `cfg(unix)` with a test door (`read_in` / `write_in`, `require_root`), so
//! the rules are tested on Linux as well; only macOS uses it for real.
//! MAC-SONRA: checked on a device with the rest of the Mac update (plan §14).

use super::store::Persisted;

/// File name inside `mac_state::STATE_DIR`.
pub const UPDATE_FILE: &str = "update.json";
/// `Info.plist` key with the Sense version number.
pub const INFO_PLIST_VERSION_KEY: &str = "SenseRemoteVersion";

/// The state directory (`mac_state::STATE_DIR`; that module is macOS-only).
#[cfg(target_os = "macos")]
const STATE_DIR: &str = "/Library/Application Support/SenseRemote";

/// `Ok(None)` = nothing stored. `Err` = unreadable or breaking the rules.
pub fn read() -> Result<Option<Persisted>, String> {
    #[cfg(target_os = "macos")]
    {
        files::read_in(std::path::Path::new(STATE_DIR), true)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(super::UNSUPPORTED.to_owned())
    }
}

/// Root only; the state directory must already exist (installed app).
pub fn write(state: &Persisted) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        files::write_in(std::path::Path::new(STATE_DIR), state, true)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = state;
        Err(super::UNSUPPORTED.to_owned())
    }
}

/// `SenseRemoteVersion` of the installed bundle; 0 when missing or not a version number.
pub fn installed_version() -> u32 {
    #[cfg(target_os = "macos")]
    {
        let app = format!("/Applications/{}.app", crate::get_app_name());
        bundle_version(std::path::Path::new(&app)).unwrap_or(0)
    }
    #[cfg(not(target_os = "macos"))]
    {
        0
    }
}

/// `SenseRemoteVersion` of the bundle at `app` (`PlistBuddy`, like upstream's
/// `read_bundle_plist_value`); `None` when missing or not a version number.
#[cfg(target_os = "macos")]
pub fn bundle_version(app: &std::path::Path) -> Option<u32> {
    let output = std::process::Command::new("/usr/libexec/PlistBuddy")
        .arg("-c")
        .arg(format!("Print :{INFO_PLIST_VERSION_KEY}"))
        .arg(app.join("Contents/Info.plist"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_plist_version(&String::from_utf8_lossy(&output.stdout))
}

/// Pure: the plist string → a contract version (1..=999_999, plain digits, no sign or space
/// inside). `PlistBuddy` ends its output with a line break.
pub fn parse_plist_version(text: &str) -> Option<u32> {
    let text = text.trim();
    if text.is_empty() || text.len() > 6 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let version: u32 = text.parse().ok()?;
    (1..=super::MAX_VERSION).contains(&version).then_some(version)
}

/// The `state.json` rules for `update.json`.
#[cfg(unix)]
pub mod files {
    use super::{Persisted, UPDATE_FILE};
    use hbb_common::{libc, log};
    use std::{
        fs::{self, File, OpenOptions, Permissions},
        io::{ErrorKind, Read, Write},
        os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        os::unix::io::AsRawFd,
        path::Path,
    };

    pub const ERR_NOT_ROOT: &str = "not-root";
    const LOCK_FILE: &str = ".update.lock";
    const TEMP_FILE: &str = ".update.json.tmp";
    const FILE_MODE: u32 = 0o644;
    /// Group or others may not write: they could fake a healthy installation or a rollback.
    const FORBIDDEN_MODE_BITS: u32 = 0o022;
    /// The real file is a few hundred bytes.
    const MAX_BYTES: u64 = 16 * 1024;

    /// Pure rule on `lstat` values (the same as `mac_state::check_attrs`).
    pub fn check_attrs(
        what: &str,
        is_symlink: bool,
        is_wanted_kind: bool,
        uid: u32,
        mode: u32,
        require_root: bool,
    ) -> Result<(), String> {
        if is_symlink {
            return Err(format!("{what}-is-symlink"));
        }
        if !is_wanted_kind {
            return Err(format!("{what}-wrong-kind"));
        }
        if require_root && uid != 0 {
            return Err(format!("{what}-owner-not-root"));
        }
        if mode & FORBIDDEN_MODE_BITS != 0 {
            return Err(format!("{what}-writable-by-others"));
        }
        Ok(())
    }

    fn check_node(what: &str, meta: &fs::Metadata, dir: bool, root: bool) -> Result<(), String> {
        let kind = meta.file_type();
        let wanted = if dir { kind.is_dir() } else { kind.is_file() };
        check_attrs(what, kind.is_symlink(), wanted, meta.uid(), meta.mode(), root)
    }

    /// `Ok(None)` when the directory or the file does not exist.
    pub fn read_in(dir: &Path, require_root: bool) -> Result<Option<Persisted>, String> {
        match fs::symlink_metadata(dir) {
            Ok(meta) => check_node("dir", &meta, true, require_root)?,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(format!("stat-dir: {err}")),
        }
        let path = dir.join(UPDATE_FILE);
        match fs::symlink_metadata(&path) {
            Ok(meta) => check_node("file", &meta, false, require_root)?,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(format!("stat-file: {err}")),
        }
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => file,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(format!("open-file: {err}")),
        };
        // The rule again on the file really opened.
        let meta = file.metadata().map_err(|err| format!("stat-file: {err}"))?;
        check_node("file", &meta, false, require_root)?;
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|err| format!("read-file: {err}"))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("file-too-large".to_owned());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|err| format!("bad-json: {err}"))
    }

    /// Writes `state` atomically under `flock`. The directory must exist and follow the rule;
    /// an existing file that breaks it is not overwritten.
    pub fn write_in(dir: &Path, state: &Persisted, require_root: bool) -> Result<(), String> {
        // SAFETY: geteuid has no arguments and cannot fail.
        if require_root && unsafe { libc::geteuid() } != 0 {
            return Err(ERR_NOT_ROOT.to_owned());
        }
        let meta = fs::symlink_metadata(dir).map_err(|err| format!("stat-dir: {err}"))?;
        check_node("dir", &meta, true, require_root)?;
        let _lock = lock(dir)?;
        // A planted file (symlink, other owner) stays an error instead of being replaced.
        read_in(dir, require_root)?;
        let mut bytes = serde_json::to_vec(state).map_err(|err| format!("encode: {err}"))?;
        bytes.push(b'\n');
        let temp = dir.join(TEMP_FILE);
        let written = write_temp(&temp, &bytes, require_root).and_then(|()| {
            fs::rename(&temp, dir.join(UPDATE_FILE)).map_err(|err| format!("rename: {err}"))
        });
        if written.is_err() {
            let _ = fs::remove_file(&temp);
            return written;
        }
        if let Err(err) = File::open(dir).and_then(|dir| dir.sync_all()) {
            log::warn!("Sense Remote: update state directory not synced: {err}");
        }
        Ok(())
    }

    fn lock(dir: &Path) -> Result<File, String> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(dir.join(LOCK_FILE))
            .map_err(|err| format!("open-lock: {err}"))?;
        loop {
            // SAFETY: the descriptor belongs to `file`, open for the whole call.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(file);
            }
            let err = std::io::Error::last_os_error();
            if err.kind() != ErrorKind::Interrupted {
                return Err(format!("lock: {err}"));
            }
        }
    }

    fn write_temp(temp: &Path, bytes: &[u8], require_root: bool) -> Result<(), String> {
        // A crashed writer's leftover; we hold the lock. `create_new` never follows a link.
        match fs::remove_file(temp) {
            Ok(()) => {}
            Err(err) if err.kind() == ErrorKind::NotFound => {}
            Err(err) => return Err(format!("remove-temp: {err}")),
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(FILE_MODE)
            .custom_flags(libc::O_NOFOLLOW)
            .open(temp)
            .map_err(|err| format!("create-temp: {err}"))?;
        file.write_all(bytes)
            .map_err(|err| format!("write-temp: {err}"))?;
        file.set_permissions(Permissions::from_mode(FILE_MODE))
            .map_err(|err| format!("chmod-temp: {err}"))?;
        // SAFETY: the descriptor belongs to `file`, open for the whole call.
        if require_root && unsafe { libc::fchown(file.as_raw_fd(), 0, 0) } != 0 {
            return Err(format!("chown: {}", std::io::Error::last_os_error()));
        }
        file.sync_all().map_err(|err| format!("sync-temp: {err}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_versions() {
        assert_eq!(parse_plist_version("3\n"), Some(3));
        assert_eq!(parse_plist_version(" 999999 "), Some(999_999));
        for bad in ["", "0", "1000000", "3.0", "+3", "-3", "3 4", "v3", "0x3", "3\n4"] {
            assert_eq!(parse_plist_version(bad), None, "{bad:?}");
        }
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn other_platforms_have_no_mac_store() {
        assert_eq!(read(), Err(crate::sense::update::UNSUPPORTED.to_owned()));
        assert_eq!(installed_version(), 0);
    }

    #[cfg(unix)]
    mod files_rules {
        use super::super::{files::*, UPDATE_FILE};
        use crate::sense::update::store::{Persisted, StoredState};
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            path::PathBuf,
            sync::atomic::{AtomicUsize, Ordering},
        };

        struct Sandbox(PathBuf);

        impl Sandbox {
            fn new() -> Self {
                static NEXT: AtomicUsize = AtomicUsize::new(0);
                let dir = std::env::temp_dir().join(format!(
                    "sense-update-store-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::SeqCst)
                ));
                let _ = fs::remove_dir_all(&dir);
                fs::create_dir_all(&dir).unwrap();
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
                Self(dir)
            }
            fn file(&self) -> PathBuf {
                self.0.join(UPDATE_FILE)
            }
        }

        impl Drop for Sandbox {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }

        fn installing() -> Persisted {
            serde_json::from_str(
                r#"{"state":"installing","target":4,"from":3,"from_id":"123456789",
                   "from_key_hash":"ab","source":"panel","attempts":1,"started_at":1795000000}"#,
            )
            .unwrap()
        }

        #[test]
        fn round_trip_and_mode() {
            let sandbox = Sandbox::new();
            assert_eq!(read_in(&sandbox.0, false), Ok(None));
            write_in(&sandbox.0, &installing(), false).unwrap();
            assert_eq!(read_in(&sandbox.0, false), Ok(Some(installing())));
            let mode = fs::metadata(sandbox.file()).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o644);
            let mut done = installing();
            done.state = StoredState::Installed;
            done.healthy_at = Some(1_795_000_100);
            write_in(&sandbox.0, &done, false).unwrap();
            assert_eq!(read_in(&sandbox.0, false), Ok(Some(done)));
            // No temp file is left behind.
            assert!(!sandbox.0.join(".update.json.tmp").exists());
        }

        #[test]
        fn missing_directory_is_nothing_but_not_writable() {
            let sandbox = Sandbox::new();
            let missing = sandbox.0.join("absent");
            assert_eq!(read_in(&missing, false), Ok(None));
            assert!(write_in(&missing, &installing(), false).is_err());
        }

        #[test]
        fn symlink_is_refused() {
            let sandbox = Sandbox::new();
            let elsewhere = sandbox.0.join("elsewhere.json");
            fs::write(&elsewhere, r#"{"state":"installed"}"#).unwrap();
            std::os::unix::fs::symlink(&elsewhere, sandbox.file()).unwrap();
            assert_eq!(read_in(&sandbox.0, false), Err("file-is-symlink".to_owned()));
            // Not replaced either.
            assert!(write_in(&sandbox.0, &installing(), false).is_err());
            assert!(fs::symlink_metadata(sandbox.file()).unwrap().file_type().is_symlink());
        }

        #[test]
        fn writable_by_others_is_refused() {
            let sandbox = Sandbox::new();
            write_in(&sandbox.0, &installing(), false).unwrap();
            fs::set_permissions(sandbox.file(), fs::Permissions::from_mode(0o666)).unwrap();
            assert_eq!(
                read_in(&sandbox.0, false),
                Err("file-writable-by-others".to_owned())
            );
            fs::set_permissions(sandbox.file(), fs::Permissions::from_mode(0o644)).unwrap();
            fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o777)).unwrap();
            assert_eq!(
                read_in(&sandbox.0, false),
                Err("dir-writable-by-others".to_owned())
            );
        }

        #[test]
        fn owner_rule() {
            // The pure rule: a file of another user is refused when root is required.
            assert_eq!(
                check_attrs("file", false, true, 501, 0o644, true),
                Err("file-owner-not-root".to_owned())
            );
            assert_eq!(check_attrs("file", false, true, 0, 0o644, true), Ok(()));
            assert_eq!(
                check_attrs("file", false, false, 0, 0o644, true),
                Err("file-wrong-kind".to_owned())
            );
            // A real file of this (non-root) test user with the root rule on.
            // SAFETY: geteuid has no arguments and cannot fail.
            if unsafe { hbb_common::libc::geteuid() } != 0 {
                let sandbox = Sandbox::new();
                write_in(&sandbox.0, &installing(), false).unwrap();
                assert_eq!(
                    read_in(&sandbox.0, true),
                    Err("dir-owner-not-root".to_owned())
                );
                assert_eq!(
                    write_in(&sandbox.0, &installing(), true),
                    Err(ERR_NOT_ROOT.to_owned())
                );
            }
        }

        #[test]
        fn broken_content_is_an_error() {
            let sandbox = Sandbox::new();
            for bad in ["", "{", r#"{"state":"paused"}"#, r#"{"state":"idle","x":1}"#] {
                fs::write(sandbox.file(), bad).unwrap();
                fs::set_permissions(sandbox.file(), fs::Permissions::from_mode(0o644)).unwrap();
                assert!(read_in(&sandbox.0, false).is_err(), "{bad:?}");
            }
            fs::write(sandbox.file(), "x".repeat(17 * 1024)).unwrap();
            assert_eq!(read_in(&sandbox.0, false), Err("file-too-large".to_owned()));
        }
    }
}
