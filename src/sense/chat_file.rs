//! Sense Remote (Sürüm 4, S5 / S12 / O11 / O12; plan 2026-11-23 §2.6 and "Ek"): files and the voice
//! call in the shared chat.
//! - D3d1: Controller → Host files over the open Remote connection (no second FileTransfer
//!   connection, S8), resume after a drop, the incoming folder (Downloads when unreachable).
//! - D3d2: Host → Controller files, a call started on the Host, microphone off, sound output
//!   choice and microphone level during a call.
//!
//! The chat and the file list live only in the connection's memory (S12); the audit log gets
//! counts only.
//!
//! How a chat file travels (D3d1, TK2 (A)+(C)):
//! 1. Controller: [`ffi_send_files`] hands RustDesk's own upload (`Data::SendFiles`) to the open
//!    Remote session. The destination is not a Host path but the mark [`INCOMING_MARK`] plus the
//!    file's name, so the Controller never chooses where the Host writes.
//! 2. Host, `server/connection.rs`: [`host_file_action`] lets only that marked upload (and its
//!    confirm / cancel) through on a Remote connection, and only when the Host allows files
//!    (permission and the one-way rule stay as they are).
//! 3. Host, `ui_cm_interface.rs`: [`host_resolve`] turns the mark into the incoming folder
//!    (Settings, Downloads when that cannot be written to) and picks "name (1).ext" instead of
//!    overwriting; nobody is asked.
//! 4. Controller, `client/io_loop.rs`: progress and results land in this module's job list; a
//!    dropped link marks running jobs "resume", and the next login of the same session starts
//!    them again from where they stopped (RustDesk's `.download` / `.digest` resume).

use crate::client::Data;
use base::{
    fs::JobType,
    message_proto::{file_action, FileAction},
};
use hbb_common::{config::LocalConfig, log};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicI32, Ordering},
        Mutex,
    },
};

/// Destination mark of a chat file: `sense:incoming/<name>`. The Host decides the folder.
pub const INCOMING_MARK: &str = "sense:incoming";

/// Local option holding the chosen incoming folder (same key the Settings screen used before
/// the core took it over, so an earlier choice is kept).
pub const INCOMING_DIR_OPTION: &str = "sense-incoming-dir";

/// Upper bound of the audit counts (`AuditConnSense`).
const AUDIT_MAX: u32 = 100_000;

// ---------------------------------------------------------------------------------------------
// Incoming folder
// ---------------------------------------------------------------------------------------------

/// Destination sent with a chat file named `name`.
pub fn incoming_target(name: &str) -> String {
    format!("{INCOMING_MARK}/{name}")
}

/// The file or folder name in a marked destination; `None` for any other path or an unsafe name.
pub fn parse_incoming(path: &str) -> Option<&str> {
    let name = path.strip_prefix(INCOMING_MARK)?.strip_prefix('/')?;
    safe_name(name).then_some(name)
}

/// One plain name: no separator, no drive, no "." / "..", no control character.
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name
            .chars()
            .any(|c| matches!(c, '/' | '\\' | ':') || c.is_control())
}

/// Whether files can be written into `dir` (it exists, is a folder and takes a new file).
fn writable_dir(dir: &Path) -> bool {
    if !dir.is_dir() {
        return false;
    }
    let probe = dir.join(format!(".sense-probe-{}", std::process::id()));
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    {
        Ok(_) => {
            std::fs::remove_file(&probe).ok();
            true
        }
        Err(e) => e.kind() == std::io::ErrorKind::AlreadyExists,
    }
}

/// The chosen folder when it can be used; `None` means Downloads.
fn usable_choice(chosen: &str) -> Option<PathBuf> {
    let chosen = chosen.trim();
    if chosen.is_empty() {
        return None;
    }
    let dir = PathBuf::from(chosen);
    (dir.is_absolute() && writable_dir(&dir)).then_some(dir)
}

/// The user's Downloads folder.
fn downloads_dir() -> PathBuf {
    dirs_next::download_dir()
        .or_else(|| dirs_next::home_dir().map(|h| h.join("Downloads")))
        .unwrap_or_else(std::env::temp_dir)
}

/// Folder incoming chat files are written to on this computer.
pub fn incoming_dir() -> PathBuf {
    usable_choice(&LocalConfig::get_option(INCOMING_DIR_OPTION)).unwrap_or_else(downloads_dir)
}

/// `main_sense_incoming_dir`: the chosen folder when it can be used; empty = Downloads.
pub fn ffi_incoming_dir() -> String {
    usable_choice(&LocalConfig::get_option(INCOMING_DIR_OPTION))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// `main_sense_set_incoming_dir`: empty goes back to Downloads.
pub fn ffi_set_incoming_dir(path: &str) {
    LocalConfig::set_option(INCOMING_DIR_OPTION.to_owned(), path.trim().to_owned());
}

/// "a.txt" + 1 → "a (1).txt"; ".env" → ".env (1)"; "a" → "a (1)".
pub fn numbered(name: &str, n: u32) -> String {
    match name.rfind('.') {
        Some(i) if i > 0 => format!("{} ({n}){}", &name[..i], &name[i..]),
        _ => format!("{name} ({n})"),
    }
}

/// `name`, or the first "name (N).ext" that is not taken.
pub fn free_name(name: &str, taken: impl Fn(&str) -> bool) -> String {
    if !taken(name) {
        return name.to_owned();
    }
    (1..10_000)
        .map(|n| numbered(name, n))
        .find(|c| !taken(c))
        .unwrap_or_else(|| numbered(name, std::process::id()))
}

fn is_sep(c: char) -> bool {
    c == '/' || (cfg!(windows) && c == '\\')
}

/// "sub/a.txt" → ("sub/", "a.txt").
fn split_leaf(rel: &str) -> (&str, &str) {
    match rel.rfind(is_sep) {
        Some(i) => (&rel[..=i], &rel[i + 1..]),
        None => ("", rel),
    }
}

/// Where a chat file lands in `dir` without overwriting anything.
/// - One file (`files` is a single entry with an empty name): a free name in `dir`. A file
///   that is half there (`.download`) does not count as taken, so a resumed transfer finds it.
/// - A folder: the folder keeps its name (a resumed one is written into again); each of its
///   files from `file_num` on that already exists gets a free name. A folder still being
///   written by another transfer here gets a free name.
///
/// `busy`: destinations of the transfers running on this connection.
pub fn host_write_target(
    dir: &Path,
    name: &str,
    files: &mut [(String, u64)],
    file_num: i32,
    busy: &[PathBuf],
) -> PathBuf {
    let in_use = |n: &str| {
        let p = dir.join(n);
        busy.contains(&p)
    };
    if files.len() == 1 && files[0].0.is_empty() {
        return dir.join(free_name(name, |n| dir.join(n).exists() || in_use(n)));
    }
    let folder = if file_num <= 0 && in_use(name) {
        free_name(name, |n| dir.join(n).exists() || in_use(n))
    } else {
        name.to_owned()
    };
    let base = dir.join(&folder);
    for (rel, _) in files.iter_mut().skip(file_num.max(0) as usize) {
        let (parent, leaf) = split_leaf(rel);
        let parent = parent.to_owned();
        let free = free_name(leaf, |n| base.join(format!("{parent}{n}")).exists());
        if free != leaf {
            *rel = format!("{parent}{free}");
        }
    }
    base
}

/// Host side of a new write (`ipc::FS::NewWrite` in the connection manager): a marked
/// destination becomes a real path in the incoming folder; any other path is returned as is.
pub fn host_resolve(
    path: String,
    files: &mut [(String, u64)],
    file_num: i32,
    busy: &[PathBuf],
) -> String {
    match parse_incoming(&path) {
        Some(name) => {
            let target = host_write_target(&incoming_dir(), name, files, file_num, busy);
            log::info!("sense chat file to the incoming folder");
            target.to_string_lossy().into_owned()
        }
        None => path,
    }
}

// ---------------------------------------------------------------------------------------------
// Host: which file actions a Remote connection takes
// ---------------------------------------------------------------------------------------------

/// What the Host does with a `FileAction` that arrives on a Remote (not file transfer)
/// connection.
#[derive(Debug, PartialEq, Eq)]
pub enum HostAction {
    /// A chat file: handle it like the file transfer connection would.
    Handle,
    /// A chat file while files are not allowed here: answer the job with an error.
    Refuse(i32),
    /// Anything else: ignored as before (browsing, reading, deleting, renaming stay off).
    Ignore,
}

/// `enabled`: the Host's file permission and the Controller's file option
/// (`Connection::file_transfer_enabled`).
pub fn host_file_action(enabled: bool, fa: &FileAction) -> HostAction {
    match fa.union.as_ref() {
        Some(file_action::Union::Receive(r)) if parse_incoming(&r.path).is_some() => {
            if enabled {
                HostAction::Handle
            } else {
                HostAction::Refuse(r.id)
            }
        }
        // Resume offsets and cancels of those jobs; they only reach this connection's own jobs.
        Some(file_action::Union::SendConfirm(_)) | Some(file_action::Union::Cancel(_))
            if enabled =>
        {
            HostAction::Handle
        }
        _ => HostAction::Ignore,
    }
}

/// Counts of one Host connection for the closing audit record (`AuditConnSense`): numbers only,
/// never text or names (S12).
#[derive(Debug, Default, Clone, Copy)]
pub struct ConnCounts {
    pub chat_messages: u32,
    pub files: u32,
}

impl ConnCounts {
    pub fn add_message(&mut self) {
        self.chat_messages = self.chat_messages.saturating_add(1);
    }

    pub fn add_file(&mut self) {
        self.files = self.files.saturating_add(1);
    }

    /// Value of `sense` in the closing `audit/conn` record.
    pub fn audit(&self) -> Value {
        json!({
            "chat_messages": self.chat_messages.min(AUDIT_MAX),
            "files": self.files.min(AUDIT_MAX),
        })
    }
}

// ---------------------------------------------------------------------------------------------
// Controller: the job list of each session (memory only)
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Run,
    Ok,
    Err,
    Resume,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            State::Run => "run",
            State::Ok => "ok",
            State::Err => "err",
            State::Resume => "resume",
        }
    }
}

#[derive(Debug, Clone)]
struct Job {
    id: i32,
    name: String,
    /// Local path being sent.
    local: String,
    total: u64,
    done: u64,
    /// File of the job to continue from.
    file_num: i32,
    state: State,
}

#[derive(Debug)]
struct SessionJobs {
    /// `LoginConfigHandler::session_id`: the same for every reconnect of one session, new for
    /// a new session. A closed session's jobs are never resumed.
    sid: u64,
    peer: String,
    jobs: Vec<Job>,
}

static SESSIONS: Mutex<Vec<SessionJobs>> = Mutex::new(Vec::new());

/// Job ids of chat files; far above the file manager's own counter.
static NEXT_ID: AtomicI32 = AtomicI32::new(0x5E_0000);

fn with_session<R>(sid: u64, f: impl FnOnce(&mut SessionJobs) -> R) -> Option<R> {
    let mut all = SESSIONS.lock().unwrap();
    all.iter_mut().find(|s| s.sid == sid).map(f)
}

fn with_job(sid: u64, id: i32, f: impl FnOnce(&mut Job)) {
    with_session(sid, |s| {
        if let Some(job) = s.jobs.iter_mut().find(|j| j.id == id) {
            f(job);
        }
    });
}

/// "image" / "video" / "doc" from the extension (the chat's file balloon).
fn kind_of(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "bmp" | "tif" | "tiff" => "image",
        "mp4" | "mov" | "avi" | "mkv" | "webm" | "m4v" | "wmv" => "video",
        _ => "doc",
    }
}

/// `session_sense_send_files`: starts each path as an upload on the open session (`send` puts
/// `Data` on that session's own channel — no new connection, S8). Returns the job ids.
pub fn ffi_send_files(sid: u64, peer: &str, paths: &[String], send: impl Fn(Data)) -> String {
    let mut ids = Vec::new();
    for path in paths {
        let Some(name) = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| safe_name(n))
        else {
            log::warn!("sense chat file: no usable name");
            continue;
        };
        let total = match base::fs::get_recursive_files(path, false) {
            Ok(files) => files.iter().map(|f| f.size).sum::<u64>(),
            Err(e) => {
                log::warn!("sense chat file not readable: {e}");
                continue;
            }
        };
        let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
        let job = Job {
            id,
            name: name.clone(),
            local: path.clone(),
            total,
            done: 0,
            file_num: 0,
            state: State::Run,
        };
        {
            let mut all = SESSIONS.lock().unwrap();
            match all.iter_mut().find(|s| s.sid == sid) {
                Some(s) => s.jobs.push(job),
                None => all.push(SessionJobs {
                    sid,
                    peer: peer.to_owned(),
                    jobs: vec![job],
                }),
            }
        }
        send(Data::SendFiles((
            id,
            JobType::Generic,
            path.clone(),
            incoming_target(&name),
            0,
            false,
            false,
        )));
        ids.push(id.to_string());
    }
    json!(ids).to_string()
}

/// `session_sense_file_jobs`: `[{id, name, kind, dir, done, total, state, path}]`.
pub fn ffi_file_jobs(sid: u64) -> String {
    let jobs = with_session(sid, |s| {
        s.jobs
            .iter()
            .map(|j| {
                let done = if j.state == State::Ok {
                    j.total
                } else {
                    j.done.min(j.total)
                };
                json!({
                    "id": j.id.to_string(),
                    "name": j.name,
                    "kind": kind_of(&j.name),
                    "dir": "out",
                    "done": done,
                    "total": j.total,
                    "state": j.state.as_str(),
                    "path": "",
                })
            })
            .collect::<Vec<_>>()
    })
    .unwrap_or_default();
    Value::Array(jobs).to_string()
}

/// Number of chat files of a session (sent and, from D3d2, received).
pub fn file_count(sid: u64) -> usize {
    with_session(sid, |s| s.jobs.len()).unwrap_or(0)
}

/// Drops the lists of sessions that are gone (`alive(sid, peer)` false): a closed connection's
/// file list is forgotten (S12).
pub fn forget_closed(alive: impl Fn(u64, &str) -> bool) {
    let known: Vec<(u64, String)> = SESSIONS
        .lock()
        .unwrap()
        .iter()
        .map(|s| (s.sid, s.peer.clone()))
        .collect();
    let gone: Vec<u64> = known
        .into_iter()
        .filter(|(sid, peer)| !alive(*sid, peer))
        .map(|(sid, _)| sid)
        .collect();
    if !gone.is_empty() {
        SESSIONS.lock().unwrap().retain(|s| !gone.contains(&s.sid));
    }
}

/// `io_loop`: bytes done of a running job.
pub fn on_progress(sid: u64, id: i32, finished: u64) {
    with_job(sid, id, |j| {
        if j.state == State::Run {
            j.done = finished;
        }
    });
}

/// `io_loop`: a job finished (`err` None) or failed.
pub fn on_status(sid: u64, id: i32, err: Option<&str>) {
    with_job(sid, id, |j| match err {
        None => {
            j.state = State::Ok;
            j.done = j.total;
        }
        Some(e) => {
            log::warn!("sense chat file {} failed: {e}", j.id);
            j.state = State::Err;
        }
    });
}

/// `io_loop`: the link dropped. Running jobs wait to resume; `live` gives the file each live
/// read job was at.
pub fn on_link_lost(sid: u64, live: &[(i32, i32)]) {
    with_session(sid, |s| {
        for j in s.jobs.iter_mut().filter(|j| j.state == State::Run) {
            if let Some((_, n)) = live.iter().find(|(id, _)| *id == j.id) {
                j.file_num = *n;
            }
            j.state = State::Resume;
        }
    });
}

/// `io_loop`: the session logged in again. Returns what restarts the jobs cut by the drop
/// (RustDesk's own `AddJob` + `ResumeJob`; the Host continues the `.download` file).
pub fn on_connected(sid: u64) -> Vec<Data> {
    with_session(sid, |s| {
        let mut out = Vec::new();
        for j in s.jobs.iter_mut().filter(|j| j.state == State::Resume) {
            j.state = State::Run;
            out.push(Data::AddJob((
                j.id,
                JobType::Generic,
                j.local.clone(),
                incoming_target(&j.name),
                j.file_num,
                false,
                false,
            )));
            out.push(Data::ResumeJob((j.id, false)));
        }
        out
    })
    .unwrap_or_default()
}

// ---------------------------------------------------------------------------------------------
// D3d2 (still skeleton)
// ---------------------------------------------------------------------------------------------

/// `main_sense_host_file_jobs` (Host side, same shape as `ffi_file_jobs`).
pub fn ffi_host_file_jobs() -> String {
    "[]".to_owned()
}

/// `main_sense_host_offer_files`: IDs of the offered transfers.
pub fn ffi_host_offer_files(_conn_id: i32, _paths: &[String]) -> String {
    "[]".to_owned()
}

/// `main_sense_host_start_call`: voice call started on the Host.
pub fn ffi_host_start_call(_conn_id: i32) {}

/// `main_sense_sound_outputs`: `{outputs: [..], output}`; `output` empty = system default.
pub fn ffi_sound_outputs() -> String {
    r#"{"outputs":[],"output":""}"#.to_owned()
}

/// `main_sense_set_call_output`: true when the call now plays on `device`.
pub fn ffi_set_call_output(_device: &str) -> bool {
    false
}

/// `session_sense_call_set_muted`: true when the microphone is now muted / open as asked.
pub fn ffi_call_set_muted(_muted: bool) -> bool {
    false
}

/// `session_sense_call_level`: microphone level 0.0–1.0 during a call; below 0 = unknown.
pub fn ffi_call_level() -> f64 {
    -1.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{
        FileRemoveFile, FileTransferCancel, FileTransferReceiveRequest,
        FileTransferSendConfirmRequest, FileTransferSendRequest, ReadDir,
    };
    use serde_json::{json, Value};
    use std::cell::RefCell;

    fn parse(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sense-chat-file-{tag}-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn receive(path: &str) -> FileAction {
        let mut fa = FileAction::new();
        fa.set_receive(FileTransferReceiveRequest {
            id: 7,
            path: path.to_owned(),
            ..Default::default()
        });
        fa
    }

    // ---- mark ----

    #[test]
    fn mark_round_trip_and_unsafe_names() {
        assert_eq!(incoming_target("a b.pdf"), "sense:incoming/a b.pdf");
        assert_eq!(parse_incoming("sense:incoming/a b.pdf"), Some("a b.pdf"));
        for bad in [
            "sense:incoming/",
            "sense:incoming/..",
            "sense:incoming/.",
            "sense:incoming/../x",
            "sense:incoming/a/b",
            "sense:incoming/a\\b",
            "sense:incoming/C:x",
            "sense:incoming/a\u{0}b",
            "sense:incomingx/a",
            "sense:incoming",
            "C:\\Users\\a\\x.txt",
            "/etc/passwd",
        ] {
            assert_eq!(parse_incoming(bad), None, "{bad}");
        }
    }

    // ---- names ----

    #[test]
    fn numbered_names() {
        assert_eq!(numbered("a.txt", 1), "a (1).txt");
        assert_eq!(numbered("a.tar.gz", 2), "a.tar (2).gz");
        assert_eq!(numbered(".env", 1), ".env (1)");
        assert_eq!(numbered("Rapor", 3), "Rapor (3)");
    }

    #[test]
    fn free_name_skips_taken_ones() {
        let taken = ["a.txt", "a (1).txt"];
        assert_eq!(free_name("a.txt", |n| taken.contains(&n)), "a (2).txt");
        assert_eq!(free_name("b.txt", |n| taken.contains(&n)), "b.txt");
    }

    #[test]
    fn single_file_never_overwrites() {
        let dir = temp_dir("single");
        std::fs::write(dir.join("a.txt"), b"old").unwrap();
        let mut files = vec![(String::new(), 0)];
        let target = host_write_target(&dir, "a.txt", &mut files, 0, &[]);
        assert_eq!(target, dir.join("a (1).txt"));
        // The existing file is untouched.
        assert_eq!(std::fs::read(dir.join("a.txt")).unwrap(), b"old");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn half_written_file_is_found_again_on_resume() {
        let dir = temp_dir("resume");
        std::fs::write(dir.join("big.iso.download"), b"part").unwrap();
        std::fs::write(dir.join("big.iso.digest"), b"{}").unwrap();
        let mut files = vec![(String::new(), 0)];
        assert_eq!(
            host_write_target(&dir, "big.iso", &mut files, 0, &[]),
            dir.join("big.iso")
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn same_name_twice_at_once_gets_two_files() {
        let dir = temp_dir("busy");
        let busy = vec![dir.join("a.txt")];
        let mut files = vec![(String::new(), 0)];
        assert_eq!(
            host_write_target(&dir, "a.txt", &mut files, 0, &busy),
            dir.join("a (1).txt")
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn folder_files_get_free_names_from_file_num_on() {
        let dir = temp_dir("folder");
        std::fs::create_dir_all(dir.join("Proje").join("alt")).unwrap();
        std::fs::write(dir.join("Proje").join("x.txt"), b"1").unwrap();
        std::fs::write(dir.join("Proje").join("alt").join("y.txt"), b"1").unwrap();
        let mut files = vec![
            ("x.txt".to_owned(), 0),
            ("alt/y.txt".to_owned(), 0),
            ("z.txt".to_owned(), 0),
        ];
        let base = host_write_target(&dir, "Proje", &mut files, 0, &[]);
        assert_eq!(base, dir.join("Proje"));
        assert_eq!(files[0].0, "x (1).txt");
        assert_eq!(files[1].0, "alt/y (1).txt");
        assert_eq!(files[2].0, "z.txt");

        // Resuming from file 1: file 0 is done and keeps its name.
        let mut files = vec![("x.txt".to_owned(), 0), ("w.txt".to_owned(), 0)];
        host_write_target(&dir, "Proje", &mut files, 1, &[]);
        assert_eq!(files[0].0, "x.txt");
        assert_eq!(files[1].0, "w.txt");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn other_paths_pass_unchanged() {
        let mut files = vec![(String::new(), 0)];
        assert_eq!(
            host_resolve("C:\\Users\\a\\x.txt".to_owned(), &mut files, 0, &[]),
            "C:\\Users\\a\\x.txt"
        );
    }

    #[test]
    fn unreachable_choice_falls_back_to_downloads() {
        assert_eq!(usable_choice(""), None);
        assert_eq!(usable_choice("relative/dir"), None);
        let missing = std::env::temp_dir().join(format!("sense-missing-{}", std::process::id()));
        assert_eq!(usable_choice(&missing.to_string_lossy()), None);
        let dir = temp_dir("choice");
        assert_eq!(usable_choice(&dir.to_string_lossy()), Some(dir.clone()));
        // A file is not a folder.
        let file = dir.join("f.txt");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(usable_choice(&file.to_string_lossy()), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    // ---- Host: file actions on a Remote connection ----

    #[test]
    fn remote_connection_takes_only_marked_uploads() {
        assert_eq!(
            host_file_action(true, &receive("sense:incoming/a.txt")),
            HostAction::Handle
        );
        // Any real Host path stays off, permission or not.
        assert_eq!(
            host_file_action(true, &receive("C:\\Windows\\a.txt")),
            HostAction::Ignore
        );
        assert_eq!(host_file_action(true, &receive("sense:incoming/../a")), HostAction::Ignore);

        let mut read = FileAction::new();
        read.set_read_dir(ReadDir {
            path: "C:\\".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &read), HostAction::Ignore);

        let mut send = FileAction::new();
        send.set_send(FileTransferSendRequest {
            id: 1,
            path: "sense:incoming/a.txt".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &send), HostAction::Ignore);

        let mut rm = FileAction::new();
        rm.set_remove_file(FileRemoveFile {
            id: 1,
            path: "sense:incoming/a.txt".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &rm), HostAction::Ignore);

        let mut confirm = FileAction::new();
        confirm.set_send_confirm(FileTransferSendConfirmRequest::default());
        assert_eq!(host_file_action(true, &confirm), HostAction::Handle);
        let mut cancel = FileAction::new();
        cancel.set_cancel(FileTransferCancel::default());
        assert_eq!(host_file_action(true, &cancel), HostAction::Handle);
    }

    #[test]
    fn files_off_refuses_the_upload() {
        assert_eq!(
            host_file_action(false, &receive("sense:incoming/a.txt")),
            HostAction::Refuse(7)
        );
        let mut confirm = FileAction::new();
        confirm.set_send_confirm(FileTransferSendConfirmRequest::default());
        assert_eq!(host_file_action(false, &confirm), HostAction::Ignore);
    }

    #[test]
    fn audit_has_numbers_only() {
        let mut c = ConnCounts::default();
        c.add_message();
        c.add_message();
        c.add_file();
        let v = c.audit();
        assert_eq!(v, json!({ "chat_messages": 2, "files": 1 }));
        for (_, value) in v.as_object().unwrap() {
            assert!(value.is_u64());
        }
        let big = ConnCounts {
            chat_messages: u32::MAX,
            files: 200_000,
        };
        assert_eq!(big.audit(), json!({ "chat_messages": 100_000, "files": 100_000 }));
    }

    // ---- Controller: job list ----

    #[test]
    fn send_uses_the_open_session_only() {
        let dir = temp_dir("send");
        let file = dir.join("rapor.pdf");
        std::fs::write(&file, vec![0u8; 1234]).unwrap();
        let sid = 0xA001;
        let sent = RefCell::new(Vec::new());
        let ids = ffi_send_files(
            sid,
            "123456789",
            &[file.to_string_lossy().into_owned(), dir.join("yok.txt").to_string_lossy().into_owned()],
            |d| sent.borrow_mut().push(d),
        );
        let ids = parse(&ids);
        assert_eq!(ids.as_array().unwrap().len(), 1, "a missing file starts nothing");
        let sent = sent.into_inner();
        assert_eq!(sent.len(), 1);
        // Only an upload on this session's channel: no new connection is opened (S8).
        match &sent[0] {
            Data::SendFiles((id, JobType::Generic, path, to, 0, false, false)) => {
                assert_eq!(ids[0], json!(id.to_string()));
                assert_eq!(path, &file.to_string_lossy());
                assert_eq!(to, "sense:incoming/rapor.pdf");
            }
            _ => panic!("unexpected Data"),
        }
        let jobs = parse(&ffi_file_jobs(sid));
        assert_eq!(jobs[0]["name"], "rapor.pdf");
        assert_eq!(jobs[0]["kind"], "doc");
        assert_eq!(jobs[0]["dir"], "out");
        assert_eq!(jobs[0]["total"], 1234);
        assert_eq!(jobs[0]["state"], "run");
        assert_eq!(file_count(sid), 1);
        forget_closed(|s, _| s != sid);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn dropped_link_resumes_on_next_login() {
        let dir = temp_dir("drop");
        let file = dir.join("film.mp4");
        std::fs::write(&file, vec![0u8; 4096]).unwrap();
        let sid = 0xA002;
        let ids = parse(&ffi_send_files(
            sid,
            "p",
            &[file.to_string_lossy().into_owned()],
            |_| {},
        ));
        let id: i32 = ids[0].as_str().unwrap().parse().unwrap();

        on_progress(sid, id, 1000);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["done"], 1000);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["kind"], "video");

        on_link_lost(sid, &[(id, 0)]);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "resume");
        // Another session's login does not touch it.
        assert!(on_connected(0xFFFF).is_empty());

        let again = on_connected(sid);
        assert_eq!(again.len(), 2);
        match (&again[0], &again[1]) {
            (
                Data::AddJob((a, JobType::Generic, path, to, 0, false, false)),
                Data::ResumeJob((b, false)),
            ) => {
                assert_eq!((*a, *b), (id, id));
                assert_eq!(path, &file.to_string_lossy());
                assert_eq!(to, "sense:incoming/film.mp4");
            }
            _ => panic!("unexpected Data"),
        }
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "run");
        // Resumed once only.
        assert!(on_connected(sid).is_empty());

        on_status(sid, id, None);
        let jobs = parse(&ffi_file_jobs(sid));
        assert_eq!(jobs[0]["state"], "ok");
        assert_eq!(jobs[0]["done"], 4096);
        // A finished job is not resumed by a later drop.
        on_link_lost(sid, &[]);
        assert!(on_connected(sid).is_empty());
        forget_closed(|s, _| s != sid);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn failed_job_and_closed_session() {
        let dir = temp_dir("fail");
        let file = dir.join("a.png");
        std::fs::write(&file, b"x").unwrap();
        let sid = 0xA003;
        let ids = parse(&ffi_send_files(sid, "p", &[file.to_string_lossy().into_owned()], |_| {}));
        let id: i32 = ids[0].as_str().unwrap().parse().unwrap();
        on_status(sid, id, Some("Permission denied"));
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "err");
        on_link_lost(sid, &[]);
        assert!(on_connected(sid).is_empty(), "a failed job is not retried");
        // The session closes: its list is gone (S12).
        forget_closed(|s, _| s != sid);
        assert_eq!(parse(&ffi_file_jobs(sid)), json!([]));
        assert_eq!(file_count(sid), 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn d3d2_still_skeleton() {
        let paths = vec!["C:\\a.txt".to_owned()];
        assert_eq!(parse(&ffi_host_file_jobs()), json!([]));
        assert_eq!(parse(&ffi_host_offer_files(1, &paths)), json!([]));
        ffi_host_start_call(1);
        assert_eq!(parse(&ffi_sound_outputs()), json!({ "outputs": [], "output": "" }));
        assert!(!ffi_set_call_output("Speakers"));
        assert!(!ffi_call_set_muted(true));
        assert!(ffi_call_level() < 0.0);
    }
}
