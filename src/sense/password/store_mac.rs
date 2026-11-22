//! Sense Remote (permanent password plan §3.9, U12): macOS local record
//! `/Library/Application Support/SenseRemote/access.json`, root:wheel 0644:
//!
//! ```json
//! {"v":1,"changed_at":1800000000,"ack":{"k":"…","p":"…","s":"…"},"ack_at":1800000000}
//! ```
//!
//! Never the password or its hash (those stay in RustDesk's own root `Config`). Reading and
//! writing follow the `state.json` rules of `mac_state`: `lstat` (no symlink), owner uid 0,
//! `mode & 022 == 0`, `flock`, temp file → `fsync` → `rename`; a file that breaks them is an
//! error, never a value, and is not overwritten. Only root (the daemon) writes. The state
//! directory is the installer's (`mac_state::STATE_DIR`); this store never creates it.
//!
//! The file code is `cfg(unix)` with a test door (`read_in` / `write_in`, `require_root`), so
//! the rules are tested on Linux CI as well; only macOS uses it for real.

use super::status::AccessRecord;
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;

/// The state directory (`mac_state::STATE_DIR`; that module is macOS-only).
pub const STATE_DIR: &str = "/Library/Application Support/SenseRemote";
/// File name inside `STATE_DIR`.
pub const ACCESS_FILE_NAME: &str = "access.json";
pub const ACCESS_FILE: &str = "/Library/Application Support/SenseRemote/access.json";
/// Value of `v` this build reads and writes.
pub const ACCESS_VERSION: u32 = 1;

/// Content of `access.json` (§3.9). The rest of the code uses the shared
/// `status::AccessRecord` (U12 review M3); `read`/`write` convert at the file boundary.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccessFile {
    pub v: u32,
    /// Last change of the permanent password, Unix seconds (device clock).
    pub changed_at: i64,
    /// Signed `PasswordAckPayload` envelope `{k,p,s}` of that change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ack: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ack_at: Option<i64>,
}

impl AccessFile {
    pub fn new(changed_at: i64, ack: Option<Value>) -> Self {
        Self {
            v: ACCESS_VERSION,
            changed_at,
            ack_at: ack.as_ref().map(|_| changed_at),
            ack,
        }
    }
}

impl From<&AccessFile> for AccessRecord {
    fn from(file: &AccessFile) -> Self {
        AccessRecord {
            changed_at: file.changed_at,
            ack: file.ack.as_ref().map(Value::to_string),
            ack_at: file.ack_at,
        }
    }
}

impl From<&AccessRecord> for AccessFile {
    /// An ack that is not a `{k,p,s}` object is not stored (nor its time).
    fn from(record: &AccessRecord) -> Self {
        let ack = record
            .ack
            .as_deref()
            .and_then(|ack| serde_json::from_str::<Value>(ack).ok())
            .filter(is_ack);
        AccessFile {
            v: ACCESS_VERSION,
            changed_at: record.changed_at,
            ack_at: ack.as_ref().and(record.ack_at),
            ack,
        }
    }
}

fn is_ack(ack: &Value) -> bool {
    ["k", "p", "s"].iter().all(|key| ack[key].is_string())
        && ack.as_object().is_some_and(|o| o.len() == 3)
}

/// Bytes of the file → record. Anything that is not exactly our format is an error.
pub fn parse(bytes: &[u8]) -> Result<AccessFile, String> {
    let record: AccessFile =
        serde_json::from_slice(bytes).map_err(|err| format!("bad-json: {err}"))?;
    if record.v != ACCESS_VERSION {
        return Err(format!("unknown-version: {}", record.v));
    }
    if record.ack.as_ref().is_some_and(|ack| !is_ack(ack)) {
        return Err("bad-ack".to_owned());
    }
    Ok(record)
}

/// `Ok(None)` = nothing stored. `Err` = unreadable or breaking the rules. macOS only.
pub fn read() -> Result<Option<AccessRecord>, String> {
    #[cfg(target_os = "macos")]
    {
        files::read_in(std::path::Path::new(STATE_DIR), true)
            .map(|file| file.as_ref().map(AccessRecord::from))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(super::UNSUPPORTED.to_owned())
    }
}

/// Root only; the state directory must already exist (installed app). macOS only.
pub fn write(record: &AccessRecord) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        files::write_in(std::path::Path::new(STATE_DIR), &AccessFile::from(record), true)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = record;
        Err(super::UNSUPPORTED.to_owned())
    }
}

/// The `state.json` rules for `access.json`.
#[cfg(unix)]
pub mod files {
    use super::{parse, AccessFile, ACCESS_FILE_NAME};
    use hbb_common::{libc, log};
    use std::{
        fs::{self, File, OpenOptions, Permissions},
        io::{ErrorKind, Read, Write},
        os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        os::unix::io::AsRawFd,
        path::Path,
    };

    pub const ERR_NOT_ROOT: &str = "not-root";
    const LOCK_FILE: &str = ".access.lock";
    const TEMP_FILE: &str = ".access.json.tmp";
    const FILE_MODE: u32 = 0o644;
    /// Group or others may not write: they could fake a change record or an ack.
    const FORBIDDEN_MODE_BITS: u32 = 0o022;
    /// The real file is well under 4 KiB (one ack ≤ 2 KiB).
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
    pub fn read_in(dir: &Path, require_root: bool) -> Result<Option<AccessFile>, String> {
        match fs::symlink_metadata(dir) {
            Ok(meta) => check_node("dir", &meta, true, require_root)?,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(format!("stat-dir: {err}")),
        }
        let path = dir.join(ACCESS_FILE_NAME);
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
        // The rule again on the file really opened, not only on the name checked above.
        let meta = file.metadata().map_err(|err| format!("stat-file: {err}"))?;
        check_node("file", &meta, false, require_root)?;
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|err| format!("read-file: {err}"))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("file-too-large".to_owned());
        }
        parse(&bytes).map(Some)
    }

    /// Writes `record` atomically under `flock`. The directory must exist and follow the rule;
    /// an existing file that breaks it is not overwritten.
    pub fn write_in(dir: &Path, record: &AccessFile, require_root: bool) -> Result<(), String> {
        // SAFETY: geteuid has no arguments and cannot fail.
        if require_root && unsafe { libc::geteuid() } != 0 {
            return Err(ERR_NOT_ROOT.to_owned());
        }
        let meta = fs::symlink_metadata(dir).map_err(|err| format!("stat-dir: {err}"))?;
        check_node("dir", &meta, true, require_root)?;
        let _lock = lock(dir)?;
        // A planted file (symlink, other owner, writable by others) stays an error.
        match read_in(dir, require_root) {
            Ok(_) => {}
            // Our own broken content (e.g. an older format) may be replaced; a node that
            // breaks the ownership rules may not.
            Err(err) if err.starts_with("bad-") || err.starts_with("unknown-version") => {}
            Err(err) => return Err(err),
        }
        let mut bytes = serde_json::to_vec(record).map_err(|err| format!("encode: {err}"))?;
        bytes.push(b'\n');
        let temp = dir.join(TEMP_FILE);
        let written = write_temp(&temp, &bytes, require_root).and_then(|()| {
            fs::rename(&temp, dir.join(ACCESS_FILE_NAME)).map_err(|err| format!("rename: {err}"))
        });
        if written.is_err() {
            let _ = fs::remove_file(&temp);
            return written;
        }
        if let Err(err) = File::open(dir).and_then(|dir| dir.sync_all()) {
            log::warn!("Sense Remote: access record directory not synced: {err}");
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
        // The umask may have narrowed the mode: the user `--server` reads nothing here, but
        // the rule is the same as `state.json`.
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
    use serde_json::json;

    fn ack() -> Value {
        json!({"k": "94d01a580be13482", "p": "cA", "s": "cw"})
    }

    #[test]
    fn record_round_trip_and_strict_parse() {
        let record = AccessFile::new(1_800_000_000, Some(ack()));
        assert_eq!(record.ack_at, Some(1_800_000_000));
        let bytes = serde_json::to_vec(&record).unwrap();
        assert_eq!(parse(&bytes).unwrap(), record);
        // No ack: no `ack`/`ack_at` in the file.
        let plain = serde_json::to_value(AccessFile::new(5, None)).unwrap();
        assert_eq!(plain, json!({"v": 1, "changed_at": 5}));
        for bad in [
            r#"{"v":2,"changed_at":1}"#,
            r#"{"changed_at":1}"#,
            r#"{"v":1,"changed_at":1,"ack":{"k":"a","p":"b"}}"#,
            r#"{"v":1,"changed_at":1,"ack":{"k":"a","p":"b","s":"c","x":"d"}}"#,
            r#"{"v":1,"changed_at":1,"ack":"text"}"#,
            "not json",
        ] {
            assert!(parse(bad.as_bytes()).is_err(), "{bad}");
        }
    }

    #[test]
    fn converts_to_and_from_the_shared_record() {
        let record = AccessRecord::after_change(7, Some(ack().to_string()));
        let file = AccessFile::from(&record);
        assert_eq!(file, AccessFile::new(7, Some(ack())));
        assert_eq!(AccessRecord::from(&file), record);
        // An ack that is not {k,p,s} is not stored.
        let odd = AccessRecord::after_change(7, Some("not json".to_owned()));
        assert_eq!(AccessFile::from(&odd), AccessFile::new(7, None));
        assert_eq!(AccessRecord::from(&AccessFile::new(7, None)), AccessRecord::after_change(7, None));
    }

    #[test]
    fn never_holds_a_password_field() {
        let text = serde_json::to_string(&AccessFile::new(1, Some(ack()))).unwrap();
        for word in ["password", "salt", "storage"] {
            assert!(!text.contains(word), "{text}");
        }
    }

    #[cfg(unix)]
    mod file_rules {
        use super::super::{files::*, *};
        use serde_json::json;
        use std::{
            fs,
            os::unix::fs::{symlink, PermissionsExt},
            path::PathBuf,
            sync::atomic::{AtomicUsize, Ordering},
        };

        struct Sandbox(PathBuf);

        impl Sandbox {
            fn new() -> Self {
                static NEXT: AtomicUsize = AtomicUsize::new(0);
                let dir = std::env::temp_dir().join(format!(
                    "sense-access-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::SeqCst)
                ));
                let _ = fs::remove_dir_all(&dir);
                fs::create_dir_all(&dir).unwrap();
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
                Self(dir)
            }
            fn file(&self) -> PathBuf {
                self.0.join(ACCESS_FILE_NAME)
            }
        }

        impl Drop for Sandbox {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }

        #[test]
        fn attrs_rule() {
            assert!(check_attrs("file", false, true, 0, 0o644, true).is_ok());
            assert_eq!(
                check_attrs("file", true, false, 0, 0o644, true).unwrap_err(),
                "file-is-symlink"
            );
            assert_eq!(
                check_attrs("file", false, true, 501, 0o644, true).unwrap_err(),
                "file-owner-not-root"
            );
            for mode in [0o664, 0o646, 0o666] {
                assert_eq!(
                    check_attrs("file", false, true, 0, mode, true).unwrap_err(),
                    "file-writable-by-others"
                );
            }
            assert_eq!(
                check_attrs("dir", false, false, 0, 0o755, true).unwrap_err(),
                "dir-wrong-kind"
            );
        }

        #[test]
        fn write_then_read_with_mode_0644() {
            let sandbox = Sandbox::new();
            assert_eq!(read_in(&sandbox.0, false).unwrap(), None);
            let record = AccessFile::new(1_800_000_000, Some(json!({"k":"a","p":"b","s":"c"})));
            write_in(&sandbox.0, &record, false).unwrap();
            assert_eq!(read_in(&sandbox.0, false).unwrap(), Some(record));
            let mode = fs::metadata(sandbox.file()).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o644);
            // No temp file left behind.
            assert!(!sandbox.0.join(".access.json.tmp").exists());
        }

        #[test]
        fn symlink_is_refused_and_not_replaced() {
            let sandbox = Sandbox::new();
            let target = sandbox.0.join("elsewhere.json");
            fs::write(&target, r#"{"v":1,"changed_at":1}"#).unwrap();
            symlink(&target, sandbox.file()).unwrap();
            assert_eq!(read_in(&sandbox.0, false).unwrap_err(), "file-is-symlink");
            let err = write_in(&sandbox.0, &AccessFile::new(2, None), false).unwrap_err();
            assert_eq!(err, "file-is-symlink");
            // The link and its target are untouched.
            assert!(fs::symlink_metadata(sandbox.file()).unwrap().file_type().is_symlink());
            assert_eq!(fs::read_to_string(&target).unwrap(), r#"{"v":1,"changed_at":1}"#);
        }

        #[test]
        fn file_writable_by_others_is_refused() {
            let sandbox = Sandbox::new();
            fs::write(sandbox.file(), r#"{"v":1,"changed_at":1}"#).unwrap();
            fs::set_permissions(sandbox.file(), fs::Permissions::from_mode(0o666)).unwrap();
            assert_eq!(
                read_in(&sandbox.0, false).unwrap_err(),
                "file-writable-by-others"
            );
            assert!(write_in(&sandbox.0, &AccessFile::new(2, None), false).is_err());
        }

        #[test]
        fn directory_writable_by_others_is_refused() {
            let sandbox = Sandbox::new();
            fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o777)).unwrap();
            assert_eq!(
                read_in(&sandbox.0, false).unwrap_err(),
                "dir-writable-by-others"
            );
            assert!(write_in(&sandbox.0, &AccessFile::new(2, None), false).is_err());
        }

        #[test]
        fn own_broken_content_is_replaced() {
            let sandbox = Sandbox::new();
            fs::write(sandbox.file(), "garbage").unwrap();
            fs::set_permissions(sandbox.file(), fs::Permissions::from_mode(0o644)).unwrap();
            assert!(read_in(&sandbox.0, false).is_err());
            write_in(&sandbox.0, &AccessFile::new(3, None), false).unwrap();
            assert_eq!(read_in(&sandbox.0, false).unwrap(), Some(AccessFile::new(3, None)));
        }

        #[test]
        fn missing_directory_is_not_created() {
            let sandbox = Sandbox::new();
            let missing = sandbox.0.join("missing");
            assert_eq!(read_in(&missing, false).unwrap(), None);
            assert!(write_in(&missing, &AccessFile::new(1, None), false).is_err());
            assert!(!missing.exists());
        }

        #[test]
        fn non_root_may_not_write_for_real() {
            // SAFETY: geteuid has no arguments and cannot fail.
            if unsafe { hbb_common::libc::geteuid() } == 0 {
                return;
            }
            let sandbox = Sandbox::new();
            assert_eq!(
                write_in(&sandbox.0, &AccessFile::new(1, None), true).unwrap_err(),
                ERR_NOT_ROOT
            );
        }
    }
}
