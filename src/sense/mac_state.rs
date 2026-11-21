//! Sense Remote (Mac M1, plan 2026-11-21 §3.1): the root-owned state file on macOS, the
//! counterpart of `HKLM\SOFTWARE\SenseRemote` on Windows (installed role, setup info, last
//! envelope seq).
//!
//! `/Library/Application Support/SenseRemote/state.json`, directory `root:wheel 0755`, file
//! `root:wheel 0644`: every process reads it, only root (installer step, daemon) writes it.
//!
//! ```json
//! {"v":1,"role":"host|controller|both","setup":"<SetupInfo hex>","envelope_seq":0}
//! ```
//!
//! Read (the counterpart of the HKLM ACL): `lstat`; the directory and the file are no symlinks,
//! owned by uid 0 and `mode & 0o022 == 0`, otherwise `Err` (G2-5: a value that cannot be trusted
//! is not 0). Broken JSON, an unknown `v`, an unknown role and a non-hex `setup` are `Err` too;
//! unknown fields are ignored. A missing directory or file is `Ok(None)` (not installed).
//!
//! Update: only root (`Err("not-root")` otherwise). Read-modify-write under `flock` on `.lock`,
//! temp file in the same directory (`0644`) → `fsync` → `rename`, so a reader sees the old or
//! the new file, never half of one. `envelope_seq` never goes back (`envelope_seq::may_store`).
//!
//! The checks are plain functions over (kind, uid, mode) and bytes, so the tests cover them
//! with a temporary directory and `require_root = false`.

use super::SenseRole;
use hbb_common::{libc, log};
use serde_derive::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions, Permissions},
    io::{ErrorKind, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    },
    path::Path,
};

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
/// Kept from the M0 skeleton (no longer returned).
pub const ERR_UNSUPPORTED: &str = "unsupported";
/// `update` result when the closure lowered `envelope_seq`; nothing is written.
pub const ERR_SEQ_BACK: &str = "seq-not-increasing";

/// Temp file the new content is written to before the rename. One name is enough: there is
/// one writer at a time (lock), and a leftover of a crashed writer is removed first.
const TEMP_FILE: &str = ".state.json.tmp";
const DIR_MODE: u32 = 0o755;
const FILE_MODE: u32 = 0o644;
/// Group or others may not write: they could change the role or roll the seq back.
const FORBIDDEN_MODE_BITS: u32 = 0o022;
/// The real file is a few hundred bytes; a bigger one is not ours.
const MAX_STATE_BYTES: u64 = 16 * 1024;
/// `SetupInfo::encode()` is at most 4096 characters; this keeps the file under the limit above.
const MAX_SETUP_HEX_CHARS: usize = 8192;

/// Content of the state file. `setup_hex` is `SetupInfo::encode()` (only `0-9a-f`; no project
/// names, K-YEREL); empty when none was stored.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MacState {
    pub role: Option<SenseRole>,
    pub setup_hex: String,
    pub envelope_seq: u64,
}

/// The file as JSON. `v` is required; the other fields default, unknown ones are ignored.
#[derive(Debug, Serialize, Deserialize)]
struct Stored {
    v: u32,
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    setup: String,
    #[serde(default)]
    envelope_seq: u64,
}

/// The installed state; `Ok(None)` when the file does not exist (not installed).
pub fn read() -> Result<Option<MacState>, String> {
    read_in(Path::new(STATE_DIR), true)
}

/// Test door: reads `dir/state.json`. `require_root` = the owner must be uid 0 (off only in
/// tests with a temporary directory).
pub fn read_in(dir: &Path, require_root: bool) -> Result<Option<MacState>, String> {
    match fs::symlink_metadata(dir) {
        Ok(meta) => check_node("dir", &meta, true, require_root)?,
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(format!("stat-dir: {err}")),
    }
    match read_file(&dir.join(STATE_FILE), require_root)? {
        Some(bytes) => parse(&bytes).map(Some),
        None => Ok(None),
    }
}

/// Reads, lets `f` change and writes the state back atomically. Only root.
pub fn update(f: impl FnOnce(&mut MacState)) -> Result<(), String> {
    update_in(Path::new(STATE_DIR), true, f)
}

/// Test door: like `update` in `dir`. `require_root` = the caller must be root and the file
/// root-owned.
///
/// Creates the directory when it is missing (first install) and always writes, also when `f`
/// changed nothing: `envelope_seq::check_writable` relies on that to prove the state can be
/// stored. A state file that cannot be read is not overwritten (`Err`); the uninstaller
/// removes the directory.
pub fn update_in(
    dir: &Path,
    require_root: bool,
    f: impl FnOnce(&mut MacState),
) -> Result<(), String> {
    if require_root && !is_root() {
        return Err(ERR_NOT_ROOT.to_owned());
    }
    ensure_dir(dir, require_root)?;
    // Held until this function returns: the read below and the rename are one step for
    // every other writer.
    let _lock = lock_dir(dir)?;
    let stored = read_in(dir, require_root)?.unwrap_or_default();
    let mut state = stored.clone();
    f(&mut state);
    check_seq(stored.envelope_seq, state.envelope_seq)?;
    write_atomic(dir, &encode(&state)?, require_root)
}

/// The counter stays or moves forward; a lower value is refused.
fn check_seq(stored: u64, new: u64) -> Result<(), String> {
    if new == stored {
        return Ok(());
    }
    super::envelope_seq::may_store(stored, new).map_err(|_| ERR_SEQ_BACK.to_owned())
}

/// Bytes of the file → state. Everything that is not exactly our format is an error.
fn parse(bytes: &[u8]) -> Result<MacState, String> {
    let stored: Stored =
        serde_json::from_slice(bytes).map_err(|err| format!("bad-json: {err}"))?;
    if stored.v != STATE_VERSION {
        return Err(format!("unknown-version: {}", stored.v));
    }
    let role = match stored.role.as_deref() {
        None | Some("") => None,
        Some(value) => Some(SenseRole::parse(value).ok_or_else(|| "bad-role".to_owned())?),
    };
    check_setup_hex(&stored.setup)?;
    Ok(MacState {
        role,
        setup_hex: stored.setup,
        envelope_seq: stored.envelope_seq,
    })
}

/// State → bytes of the file.
fn encode(state: &MacState) -> Result<Vec<u8>, String> {
    check_setup_hex(&state.setup_hex)?;
    let stored = Stored {
        v: STATE_VERSION,
        role: state.role.map(|role| role.as_str().to_owned()),
        setup: state.setup_hex.clone(),
        envelope_seq: state.envelope_seq,
    };
    let mut json = serde_json::to_vec(&stored).map_err(|err| format!("encode: {err}"))?;
    json.push(b'\n');
    Ok(json)
}

/// `setup` is `SetupInfo::encode()`: lowercase hex only, so it is safe wherever it is passed on.
fn check_setup_hex(hex: &str) -> Result<(), String> {
    let allowed = |c: u8| c.is_ascii_digit() || (b'a'..=b'f').contains(&c);
    if hex.len() > MAX_SETUP_HEX_CHARS || !hex.bytes().all(allowed) {
        return Err("bad-setup".to_owned());
    }
    Ok(())
}

/// The rule of plan §3.1 for the directory (`want_dir`) and the file, on `lstat` values:
/// the right kind (a symlink is neither), owner root, not writable by group or others.
fn check_attrs(
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

fn check_node(
    what: &str,
    meta: &fs::Metadata,
    want_dir: bool,
    require_root: bool,
) -> Result<(), String> {
    let kind = meta.file_type();
    let is_wanted_kind = if want_dir { kind.is_dir() } else { kind.is_file() };
    check_attrs(
        what,
        kind.is_symlink(),
        is_wanted_kind,
        meta.uid(),
        meta.mode(),
        require_root,
    )
}

/// Content of the state file; `None` when it does not exist.
fn read_file(path: &Path, require_root: bool) -> Result<Option<Vec<u8>>, String> {
    match fs::symlink_metadata(path) {
        Ok(meta) => check_node("file", &meta, false, require_root)?,
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(format!("stat-file: {err}")),
    }
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        // Removed between the two calls (uninstall).
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(format!("open-file: {err}")),
    };
    // The same rule on the file that was really opened, not only on the name checked above.
    let meta = file.metadata().map_err(|err| format!("stat-file: {err}"))?;
    check_node("file", &meta, false, require_root)?;
    let mut bytes = Vec::new();
    file.take(MAX_STATE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("read-file: {err}"))?;
    if bytes.len() as u64 > MAX_STATE_BYTES {
        return Err("file-too-large".to_owned());
    }
    Ok(Some(bytes))
}

fn is_root() -> bool {
    // SAFETY: geteuid has no arguments and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

/// The directory exists and follows the rule; created `0755` (root:wheel) when missing.
fn ensure_dir(dir: &Path, require_root: bool) -> Result<(), String> {
    match fs::symlink_metadata(dir) {
        Ok(meta) => return check_node("dir", &meta, true, require_root),
        Err(err) if err.kind() == ErrorKind::NotFound => {}
        Err(err) => return Err(format!("stat-dir: {err}")),
    }
    match fs::DirBuilder::new().mode(DIR_MODE).create(dir) {
        Ok(()) => {
            // The umask may have narrowed the mode, and a new directory gets the group of its
            // parent on macOS (`admin` under /Library/Application Support), not wheel.
            fs::set_permissions(dir, Permissions::from_mode(DIR_MODE))
                .map_err(|err| format!("chmod-dir: {err}"))?;
            if require_root {
                chown_root_path(dir)?;
            }
        }
        // Another writer created it at the same moment; it is checked below like any other.
        Err(err) if err.kind() == ErrorKind::AlreadyExists => {}
        Err(err) => return Err(format!("create-dir: {err}")),
    }
    let meta = fs::symlink_metadata(dir).map_err(|err| format!("stat-dir: {err}"))?;
    check_node("dir", &meta, true, require_root)
}

fn chown_root_path(path: &Path) -> Result<(), String> {
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| "chown: bad path".to_owned())?;
    // SAFETY: `c_path` is a valid NUL-terminated string that lives across the call.
    if unsafe { libc::lchown(c_path.as_ptr(), 0, 0) } != 0 {
        return Err(format!("chown: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

fn chown_root_file(file: &File) -> Result<(), String> {
    // SAFETY: the descriptor belongs to `file`, which is open for the whole call.
    if unsafe { libc::fchown(file.as_raw_fd(), 0, 0) } != 0 {
        return Err(format!("chown: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

/// Exclusive `flock` on `dir/.lock`; released when the returned file is dropped. Every caller
/// opens the file itself, so two threads of one process exclude each other as well.
fn lock_dir(dir: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(FILE_MODE)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join(LOCK_FILE))
        .map_err(|err| format!("open-lock: {err}"))?;
    loop {
        // SAFETY: the descriptor belongs to `file`, which is open for the whole call.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(file);
        }
        let err = std::io::Error::last_os_error();
        if err.kind() != ErrorKind::Interrupted {
            return Err(format!("lock: {err}"));
        }
    }
}

/// Temp file → fsync → rename over `state.json`. On an error the old file stays as it was and
/// no temp file is left behind.
fn write_atomic(dir: &Path, bytes: &[u8], require_root: bool) -> Result<(), String> {
    let temp = dir.join(TEMP_FILE);
    let written = write_temp(&temp, bytes, require_root).and_then(|()| {
        fs::rename(&temp, dir.join(STATE_FILE)).map_err(|err| format!("rename: {err}"))
    });
    if written.is_err() {
        let _ = fs::remove_file(&temp);
        return written;
    }
    // Makes the rename itself durable. The new file is complete either way, so this only logs.
    if let Err(err) = File::open(dir).and_then(|dir| dir.sync_all()) {
        log::warn!("Sense Remote: state directory not synced: {err}");
    }
    Ok(())
}

fn write_temp(temp: &Path, bytes: &[u8], require_root: bool) -> Result<(), String> {
    // Left by a writer that crashed; we hold the lock, so it belongs to nobody. `remove_file`
    // removes a symlink itself, and `create_new` (O_EXCL) never writes through one.
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
    // The umask may have narrowed the mode: every user has to read the role.
    file.set_permissions(Permissions::from_mode(FILE_MODE))
        .map_err(|err| format!("chmod-temp: {err}"))?;
    if require_root {
        chown_root_file(&file)?;
    }
    file.sync_all().map_err(|err| format!("sync-temp: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::PathBuf,
        sync::atomic::{AtomicUsize, Ordering},
    };

    /// A fresh directory under the temp dir, removed again on drop. `state` is the state
    /// directory inside it (not created).
    struct Sandbox {
        base: PathBuf,
        state: PathBuf,
    }

    impl Sandbox {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let base = std::env::temp_dir().join(format!(
                "sense-mac-state-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            ));
            let _ = fs::remove_dir_all(&base);
            fs::create_dir_all(&base).unwrap();
            let state = base.join("SenseRemote");
            Self { base, state }
        }

        /// Creates the state directory `0755` with `content` as a `0644` state file.
        fn with_file(content: &str) -> Self {
            let sandbox = Self::new();
            fs::create_dir(&sandbox.state).unwrap();
            chmod(&sandbox.state, DIR_MODE);
            fs::write(sandbox.file(), content).unwrap();
            chmod(&sandbox.file(), FILE_MODE);
            sandbox
        }

        fn file(&self) -> PathBuf {
            self.state.join(STATE_FILE)
        }

        fn read(&self) -> Result<Option<MacState>, String> {
            read_in(&self.state, false)
        }

        fn update(&self, f: impl FnOnce(&mut MacState)) -> Result<(), String> {
            update_in(&self.state, false, f)
        }

        fn names(&self) -> Vec<String> {
            let mut names: Vec<String> = fs::read_dir(&self.state)
                .unwrap()
                .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.base);
        }
    }

    fn chmod(path: &Path, mode: u32) {
        fs::set_permissions(path, Permissions::from_mode(mode)).unwrap();
    }

    fn mode_of(path: &Path) -> u32 {
        fs::symlink_metadata(path).unwrap().mode() & 0o7777
    }

    const VALID: &str = r#"{"v":1,"role":"both","setup":"7b7d","envelope_seq":42}"#;

    fn valid_state() -> MacState {
        MacState {
            role: Some(SenseRole::Both),
            setup_hex: "7b7d".to_owned(),
            envelope_seq: 42,
        }
    }

    #[test]
    fn missing_directory_or_file_is_not_installed() {
        let sandbox = Sandbox::new();
        assert_eq!(sandbox.read(), Ok(None));
        fs::create_dir(&sandbox.state).unwrap();
        chmod(&sandbox.state, DIR_MODE);
        assert_eq!(sandbox.read(), Ok(None));
    }

    #[test]
    fn valid_file_gives_its_fields() {
        let sandbox = Sandbox::with_file(VALID);
        assert_eq!(sandbox.read(), Ok(Some(valid_state())));
    }

    #[test]
    fn parse_accepts_only_our_format() {
        assert_eq!(parse(VALID.as_bytes()), Ok(valid_state()));
        // Fields other than `v` default; unknown fields are ignored; no role = not installed.
        assert_eq!(parse(br#"{"v":1}"#), Ok(MacState::default()));
        assert_eq!(
            parse(br#"{"v":1,"role":null,"later":{"a":[1]},"envelope_seq":7}"#),
            Ok(MacState {
                envelope_seq: 7,
                ..Default::default()
            })
        );
        for (role, expected) in [
            ("host", SenseRole::Host),
            ("controller", SenseRole::Controller),
            ("both", SenseRole::Both),
        ] {
            let json = format!(r#"{{"v":1,"role":"{role}"}}"#);
            assert_eq!(parse(json.as_bytes()).unwrap().role, Some(expected), "{role}");
        }
        // The whole u64 range survives.
        let json = format!(r#"{{"v":1,"envelope_seq":{}}}"#, u64::MAX);
        assert_eq!(parse(json.as_bytes()).unwrap().envelope_seq, u64::MAX);

        for broken in [
            "",
            "{",
            "[]",
            "null",
            r#"{"role":"host"}"#,
            r#"{"v":"1"}"#,
            r#"{"v":1,"envelope_seq":-1}"#,
            r#"{"v":1,"envelope_seq":"3"}"#,
            r#"{"v":1,"envelope_seq":1.5}"#,
            r#"{"v":1,"role":7}"#,
        ] {
            let err = parse(broken.as_bytes()).unwrap_err();
            assert!(err.starts_with("bad-json"), "{broken}: {err}");
        }
        for version in [0, 2, 99] {
            let json = format!(r#"{{"v":{version},"role":"host"}}"#);
            let err = parse(json.as_bytes()).unwrap_err();
            assert!(err.starts_with("unknown-version"), "{version}: {err}");
        }
        assert_eq!(
            parse(br#"{"v":1,"role":"admin"}"#),
            Err("bad-role".to_owned())
        );
        for setup in ["7B7D", "zz", "7b 7d", "7b7d; rm -rf /", "\u{131}"] {
            let json = serde_json::json!({ "v": 1, "setup": setup }).to_string();
            assert_eq!(
                parse(json.as_bytes()),
                Err("bad-setup".to_owned()),
                "{setup}"
            );
        }
    }

    #[test]
    fn encode_and_parse_round_trip() {
        for state in [
            MacState::default(),
            valid_state(),
            MacState {
                role: Some(SenseRole::Host),
                setup_hex: "0123456789abcdef".repeat(256),
                envelope_seq: u64::MAX,
            },
        ] {
            let bytes = encode(&state).unwrap();
            assert!(bytes.len() as u64 <= MAX_STATE_BYTES);
            assert_eq!(parse(&bytes), Ok(state));
        }
        let bad = MacState {
            setup_hex: "\"}".to_owned(),
            ..Default::default()
        };
        assert_eq!(encode(&bad), Err("bad-setup".to_owned()));
        let long = MacState {
            setup_hex: "a".repeat(MAX_SETUP_HEX_CHARS + 1),
            ..Default::default()
        };
        assert_eq!(encode(&long), Err("bad-setup".to_owned()));
    }

    #[test]
    fn attribute_rule() {
        let ok = |uid, mode, require_root| check_attrs("file", false, true, uid, mode, require_root);
        assert_eq!(ok(0, 0o100644, true), Ok(()));
        assert_eq!(ok(0, 0o100600, true), Ok(()));
        assert_eq!(ok(0, 0o040755, true), Ok(()));
        assert_eq!(ok(501, 0o100644, false), Ok(()));
        assert_eq!(ok(501, 0o100644, true), Err("file-owner-not-root".to_owned()));
        for mode in [0o100664, 0o100646, 0o100666, 0o040775, 0o040757, 0o041777] {
            for require_root in [false, true] {
                assert_eq!(
                    ok(0, mode, require_root),
                    Err("file-writable-by-others".to_owned()),
                    "{mode:o}"
                );
            }
        }
        assert_eq!(
            check_attrs("dir", true, false, 0, 0o120755, true),
            Err("dir-is-symlink".to_owned())
        );
        assert_eq!(
            check_attrs("dir", false, false, 0, 0o100644, true),
            Err("dir-wrong-kind".to_owned())
        );
    }

    #[test]
    fn broken_json_and_unknown_version_are_errors_not_empty() {
        for content in ["{\"v\":1,", "", r#"{"v":2,"role":"host"}"#, r#"{"role":"host"}"#] {
            let sandbox = Sandbox::with_file(content);
            assert!(sandbox.read().is_err(), "{content}");
            // An unusable file is not replaced by an update either.
            let mut called = false;
            assert!(sandbox.update(|_| called = true).is_err(), "{content}");
            assert!(!called);
            assert_eq!(fs::read_to_string(sandbox.file()).unwrap(), content);
        }
    }

    #[test]
    fn file_writable_by_group_or_others_is_refused() {
        for mode in [0o664, 0o646, 0o666] {
            let sandbox = Sandbox::with_file(VALID);
            chmod(&sandbox.file(), mode);
            assert_eq!(
                sandbox.read(),
                Err("file-writable-by-others".to_owned()),
                "{mode:o}"
            );
            assert!(sandbox.update(|state| state.envelope_seq += 1).is_err());
            assert_eq!(fs::read_to_string(sandbox.file()).unwrap(), VALID);
        }
    }

    #[test]
    fn directory_writable_by_group_or_others_is_refused() {
        for mode in [0o775, 0o757, 0o777] {
            let sandbox = Sandbox::with_file(VALID);
            chmod(&sandbox.state, mode);
            assert_eq!(
                sandbox.read(),
                Err("dir-writable-by-others".to_owned()),
                "{mode:o}"
            );
            assert_eq!(
                sandbox.update(|state| state.envelope_seq += 1),
                Err("dir-writable-by-others".to_owned())
            );
            assert_eq!(sandbox.names(), [STATE_FILE]);
        }
    }

    #[test]
    fn symlinked_file_is_refused() {
        let sandbox = Sandbox::with_file(VALID);
        let real = sandbox.base.join("real.json");
        fs::rename(sandbox.file(), &real).unwrap();
        std::os::unix::fs::symlink(&real, sandbox.file()).unwrap();
        assert_eq!(sandbox.read(), Err("file-is-symlink".to_owned()));
        assert!(sandbox.update(|state| state.envelope_seq += 1).is_err());
        // Neither the link nor its target was touched.
        assert!(fs::symlink_metadata(sandbox.file())
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(fs::read_to_string(&real).unwrap(), VALID);
    }

    #[test]
    fn symlinked_directory_is_refused() {
        let sandbox = Sandbox::with_file(VALID);
        let real = sandbox.base.join("real");
        fs::rename(&sandbox.state, &real).unwrap();
        std::os::unix::fs::symlink(&real, &sandbox.state).unwrap();
        assert_eq!(sandbox.read(), Err("dir-is-symlink".to_owned()));
        assert_eq!(
            sandbox.update(|state| state.envelope_seq += 1),
            Err("dir-is-symlink".to_owned())
        );
        assert_eq!(fs::read_to_string(real.join(STATE_FILE)).unwrap(), VALID);
    }

    #[test]
    fn something_else_under_the_file_name_is_refused() {
        let sandbox = Sandbox::new();
        fs::create_dir(&sandbox.state).unwrap();
        chmod(&sandbox.state, DIR_MODE);
        fs::create_dir(sandbox.file()).unwrap();
        chmod(&sandbox.file(), DIR_MODE);
        assert_eq!(sandbox.read(), Err("file-wrong-kind".to_owned()));
        // And a file where the directory should be.
        let other = Sandbox::new();
        fs::write(&other.state, VALID).unwrap();
        chmod(&other.state, FILE_MODE);
        assert_eq!(other.read(), Err("dir-wrong-kind".to_owned()));
        assert_eq!(other.update(|_| {}), Err("dir-wrong-kind".to_owned()));
    }

    #[test]
    fn oversized_file_is_refused() {
        let padding = " ".repeat(MAX_STATE_BYTES as usize);
        let sandbox = Sandbox::with_file(&format!("{VALID}{padding}"));
        assert_eq!(sandbox.read(), Err("file-too-large".to_owned()));
    }

    #[test]
    fn update_creates_directory_and_file_with_the_modes() {
        let sandbox = Sandbox::new();
        sandbox
            .update(|state| {
                assert_eq!(*state, MacState::default());
                state.role = Some(SenseRole::Host);
                state.setup_hex = "7b7d".to_owned();
            })
            .unwrap();
        assert_eq!(mode_of(&sandbox.state), DIR_MODE);
        assert_eq!(mode_of(&sandbox.file()), FILE_MODE);
        assert_eq!(
            fs::read_to_string(sandbox.file()).unwrap(),
            "{\"v\":1,\"role\":\"host\",\"setup\":\"7b7d\",\"envelope_seq\":0}\n"
        );
        assert_eq!(
            sandbox.read(),
            Ok(Some(MacState {
                role: Some(SenseRole::Host),
                setup_hex: "7b7d".to_owned(),
                envelope_seq: 0,
            }))
        );
    }

    #[test]
    fn update_keeps_what_the_closure_does_not_touch() {
        let sandbox = Sandbox::with_file(VALID);
        // A reinstall: new role and setup, the seq stays (plan §3.2).
        sandbox
            .update(|state| {
                assert_eq!(*state, valid_state());
                state.role = Some(SenseRole::Controller);
                state.setup_hex = "7b22617d".to_owned();
            })
            .unwrap();
        assert_eq!(
            sandbox.read(),
            Ok(Some(MacState {
                role: Some(SenseRole::Controller),
                setup_hex: "7b22617d".to_owned(),
                envelope_seq: 42,
            }))
        );
        // The no-op update of `check_writable` leaves the content as it is.
        let before = fs::read(sandbox.file()).unwrap();
        sandbox.update(|_| {}).unwrap();
        assert_eq!(fs::read(sandbox.file()).unwrap(), before);
    }

    #[test]
    fn update_never_lowers_the_seq() {
        let sandbox = Sandbox::with_file(VALID);
        for lower in [41, 7, 0] {
            assert_eq!(
                sandbox.update(|state| {
                    state.envelope_seq = lower;
                    state.role = Some(SenseRole::Host);
                }),
                Err(ERR_SEQ_BACK.to_owned())
            );
            // Nothing of the refused update was written, the role neither.
            assert_eq!(sandbox.read(), Ok(Some(valid_state())));
        }
        sandbox.update(|state| state.envelope_seq = 42).unwrap();
        sandbox.update(|state| state.envelope_seq = 43).unwrap();
        assert_eq!(sandbox.read().unwrap().unwrap().envelope_seq, 43);
        assert_eq!(check_seq(5, 5), Ok(()));
        assert_eq!(check_seq(5, 6), Ok(()));
        assert_eq!(check_seq(5, 4), Err(ERR_SEQ_BACK.to_owned()));
    }

    #[test]
    fn update_refuses_a_setup_that_is_not_hex() {
        let sandbox = Sandbox::with_file(VALID);
        assert_eq!(
            sandbox.update(|state| state.setup_hex = "$(id)".to_owned()),
            Err("bad-setup".to_owned())
        );
        assert_eq!(sandbox.read(), Ok(Some(valid_state())));
        assert_eq!(sandbox.names(), [LOCK_FILE, STATE_FILE]);
    }

    #[test]
    fn concurrent_updates_lose_nothing() {
        const THREADS: u64 = 8;
        const ROUNDS: u64 = 25;
        let sandbox = Sandbox::new();
        // Created up front here; the threads below also race on the lock file's creation.
        fs::create_dir(&sandbox.state).unwrap();
        chmod(&sandbox.state, DIR_MODE);
        let handles: Vec<_> = (0..THREADS)
            .map(|_| {
                let dir = sandbox.state.clone();
                std::thread::spawn(move || {
                    for _ in 0..ROUNDS {
                        update_in(&dir, false, |state| state.envelope_seq += 1).unwrap();
                        // A reader never sees a half-written file.
                        assert!(read_in(&dir, false).unwrap().is_some());
                    }
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(
            sandbox.read().unwrap().unwrap().envelope_seq,
            THREADS * ROUNDS
        );
        assert_eq!(sandbox.names(), [LOCK_FILE, STATE_FILE]);
    }

    #[test]
    fn concurrent_first_updates_create_the_directory_once() {
        let sandbox = Sandbox::new();
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let dir = sandbox.state.clone();
                std::thread::spawn(move || {
                    update_in(&dir, false, |state| state.envelope_seq += 1).unwrap()
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(sandbox.read().unwrap().unwrap().envelope_seq, 4);
    }

    #[test]
    fn no_temp_file_is_left_behind() {
        let sandbox = Sandbox::with_file(VALID);
        sandbox.update(|state| state.envelope_seq += 1).unwrap();
        assert_eq!(sandbox.names(), [LOCK_FILE, STATE_FILE]);
        // A leftover of a crashed writer (also as a symlink) is replaced, not written through.
        let outside = sandbox.base.join("outside");
        fs::write(&outside, "untouched").unwrap();
        std::os::unix::fs::symlink(&outside, sandbox.state.join(TEMP_FILE)).unwrap();
        sandbox.update(|state| state.envelope_seq += 1).unwrap();
        assert_eq!(sandbox.names(), [LOCK_FILE, STATE_FILE]);
        assert_eq!(fs::read_to_string(&outside).unwrap(), "untouched");
        assert_eq!(sandbox.read().unwrap().unwrap().envelope_seq, 44);
        assert_eq!(mode_of(&sandbox.file()), FILE_MODE);
    }

    #[test]
    fn failed_write_keeps_the_old_file_and_no_temp_file() {
        let sandbox = Sandbox::with_file(VALID);
        // The rename cannot replace a directory with a file.
        let temp = sandbox.state.join(TEMP_FILE);
        fs::remove_file(sandbox.file()).unwrap();
        fs::create_dir(sandbox.file()).unwrap();
        let err = write_atomic(&sandbox.state, b"{}", false).unwrap_err();
        assert!(err.starts_with("rename"), "{err}");
        assert!(!temp.exists());
        assert!(sandbox.file().is_dir());
    }

    #[test]
    fn only_root_updates_the_real_state() {
        if is_root() {
            return;
        }
        let sandbox = Sandbox::with_file(VALID);
        let mut called = false;
        assert_eq!(
            update_in(&sandbox.state, true, |_| called = true),
            Err(ERR_NOT_ROOT.to_owned())
        );
        assert!(!called);
        assert_eq!(fs::read_to_string(sandbox.file()).unwrap(), VALID);
        assert_eq!(sandbox.names(), [STATE_FILE]);
        // Not even the directory is created.
        let empty = Sandbox::new();
        assert_eq!(
            update_in(&empty.state, true, |_| {}),
            Err(ERR_NOT_ROOT.to_owned())
        );
        assert!(!empty.state.exists());
        // A state a user wrote is not the installed state.
        assert_eq!(
            read_in(&sandbox.state, true),
            Err("dir-owner-not-root".to_owned())
        );
        // The real path: no file on a computer without the installer, and no write.
        assert_eq!(update(|_| {}), Err(ERR_NOT_ROOT.to_owned()));
    }
}
