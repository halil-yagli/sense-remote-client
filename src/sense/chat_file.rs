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
//!
//! Host → Controller (D3d2, TK2 (B)):
//! 1. Host card: [`ffi_host_offer_files`] gives each file an offer id and hands id + path to
//!    the connection ([`CM_OFFER`] over the CM channel).
//! 2. Host, `server/connection.rs`: the connection keeps that path in its own list (the white
//!    list, [`conn_offer`]) and tells the Controller only id, name and size
//!    (`Misc.plugin_request`, id [`OFFER_REQUEST`]); the path never leaves the Host.
//! 3. Controller, `client/io_loop.rs`: [`on_offer`] pulls it with RustDesk's own download
//!    (`Data::SendFiles`, `is_remote`) into the incoming folder under a free name. The source
//!    is the mark `sense:offer/<id>/<name>`.
//! 4. Host: [`host_file_action`] lets a read (`FileAction::Send`) through only when its mark
//!    names an offer of this connection and the job id is that offer id; any other path stays
//!    off. The one-way rule and the file permission still apply.
//!
//! Resume of a Host file (Y3): with the offer the Host gives the Controller a random resume key
//! and keeps (path, key) in memory for [`RESUME_TTL_MS`] ([`conn_offer`]). A dropped link keeps
//! the half-written `.download`; at the next login of the same session the Controller asks for
//! `sense:offer-resume/<id>/<key>/<name>` and [`host_file_action`] opens that read for the key
//! alone (no peer, no other path; anything else is refused). RustDesk's `.digest` check decides
//! what part is already right. A folder, an old Host without key, an expired wait or a closed
//! session ends it and removes the half-written files.
//!
//! Closing audit (Y5): [`ConnCounts::audit`] adds `recording_s` and `reason` (the panel's
//! `AuditConnSense`, no other fields).
//!
//! Call (D3d2): the Host card starts a call (`ipc::Data::StartVoiceCall` to its connection, a
//! `VoiceCallRequest` to the Controller); the Controller answers with its own call buttons.
//! Microphone off, microphone level and the sound output work in the process that captures /
//! plays the call: the Controller app itself, or on the Host the server process (the Host card
//! sends them over the CM channel, the level comes back the same way).

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
        atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering},
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
    /// A file the Host offered (D3d2): read it from this real path.
    Offer(String),
    /// A chat file while files are not allowed here: answer the job with an error.
    Refuse(i32),
    /// Anything else: ignored as before (browsing, reading, deleting, renaming stay off).
    Ignore,
}

/// `enabled`: the Host's file permission and the Controller's file option
/// (`Connection::file_transfer_enabled`). `offers`: (offer id, real path) the Host card offered
/// on this connection — the only files a Controller may read (white list).
pub fn host_file_action(enabled: bool, fa: &FileAction, offers: &[(i32, String)]) -> HostAction {
    match fa.union.as_ref() {
        Some(file_action::Union::Receive(r)) if parse_incoming(&r.path).is_some() => {
            if enabled {
                HostAction::Handle
            } else {
                HostAction::Refuse(r.id)
            }
        }
        Some(file_action::Union::Send(s))
            if JobType::from_proto(s.file_type) == JobType::Generic =>
        {
            // The job id must be the offer id the mark names, and the offer must be ours.
            let offered = parse_offer(&s.path)
                .filter(|(id, _)| *id == s.id)
                .and_then(|(id, _)| offers.iter().find(|(o, _)| *o == id));
            match offered {
                Some((_, path)) if enabled => HostAction::Offer(path.clone()),
                Some(_) => HostAction::Refuse(s.id),
                None => match parse_resume(&s.path).filter(|(id, _, _)| *id == s.id) {
                    // Y3: a Controller continues a read the dropped link cut. Only the key the
                    // Host gave with that offer opens it; anything else is refused, so the
                    // Controller's job ends instead of waiting.
                    Some((id, key, _)) => match resumable_find(id, key, now_ms()) {
                        Some(path) if enabled => HostAction::Offer(path),
                        _ => HostAction::Refuse(s.id),
                    },
                    None => HostAction::Ignore,
                },
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
    /// Total seconds the Controller recorded this connection (`None`: never recorded). Only
    /// the length is kept, never the recording (S7-b, S12).
    pub recording_s: Option<u64>,
    /// Why the connection closed, as the panel's `ConnCloseReason` (O14); `None` when unknown.
    pub reason: Option<&'static str>,
}

/// Longest `recording_s` the panel takes (31 days).
const RECORDING_MAX_S: u64 = 31 * 86_400;

/// The panel's closing reason (`host_ended`, `idle`, `peer_gone`, `controller`) of the text
/// `Connection::on_close` was given; `None` for any other text (the panel then shows none).
pub fn close_reason_code(text: &str) -> Option<&'static str> {
    match text {
        "Peer close" | "Closed manually by the peer" => Some("controller"),
        "connection manager" | "connection manager window closed" | "stop service" => {
            Some("host_ended")
        }
        "auto disconnect" => Some("idle"),
        "Timeout" | "Reset by the peer" => Some("peer_gone"),
        _ => None,
    }
}

impl ConnCounts {
    pub fn add_message(&mut self) {
        self.chat_messages = self.chat_messages.saturating_add(1);
    }

    pub fn add_file(&mut self) {
        self.files = self.files.saturating_add(1);
    }

    /// A recording of `secs` seconds ended (Y5, S12: "Kayıt alındı · süre").
    pub fn add_recording(&mut self, secs: u64) {
        self.recording_s = Some(self.recording_s.unwrap_or(0).saturating_add(secs));
    }

    /// The connection closes with `text` (the first reason wins; unknown texts leave it unset).
    pub fn set_close_reason(&mut self, text: &str) {
        if self.reason.is_none() {
            self.reason = close_reason_code(text);
        }
    }

    /// Value of `sense` in the closing `audit/conn` record. Numbers and a reason code only; the
    /// panel's `AuditConnSense` is strict, so no other field may ever be added here.
    pub fn audit(&self) -> Value {
        let mut v = json!({
            "chat_messages": self.chat_messages.min(AUDIT_MAX),
            "files": self.files.min(AUDIT_MAX),
        });
        if let Some(secs) = self.recording_s {
            v["recording_s"] = json!(secs.min(RECORDING_MAX_S));
        }
        if let Some(reason) = self.reason {
            v["reason"] = json!(reason);
        }
        v
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
    /// From the Host (D3d2): `local` is where it is saved.
    incoming: bool,
    /// Local path being sent, or (incoming) being written.
    local: String,
    total: u64,
    done: u64,
    /// File of the job to continue from.
    file_num: i32,
    state: State,
    /// Why it ended with an error ("" while none): shown to the person, never sent anywhere.
    error: &'static str,
    /// Incoming only: the Host's resume key of this offer ("" from a Host that sends none).
    key: String,
    /// Incoming only: when the link cut it (ms since the epoch); the partial file is kept until
    /// [`RESUME_TTL_MS`] after that.
    cut_at: u64,
    /// Incoming only: it was restarted after a cut; if the Host refuses, the partial goes.
    resumed: bool,
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

fn add_job(sid: u64, peer: &str, job: Job) {
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
        add_job(
            sid,
            peer,
            Job {
                id,
                name: name.clone(),
                incoming: false,
                local: path.clone(),
                total,
                done: 0,
                file_num: 0,
                state: State::Run,
                error: "",
                key: String::new(),
                cut_at: 0,
                resumed: false,
            },
        );
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

/// Cut downloads of the Host that waited longer than [`RESUME_TTL_MS`] (at `now`, ms) end:
/// their half-written file is removed.
fn sweep_expired(now: u64) {
    let mut all = SESSIONS.lock().unwrap();
    for j in all.iter_mut().flat_map(|s| s.jobs.iter_mut()) {
        if j.incoming && j.state == State::Resume && now.saturating_sub(j.cut_at) > RESUME_TTL_MS
        {
            j.state = State::Err;
            j.error = ERR_LINK_LOST;
            discard_partial(Path::new(&j.local));
        }
    }
}

/// `session_sense_file_jobs`: `[{id, name, kind, dir, done, total, state, path}]`.
pub fn ffi_file_jobs(sid: u64) -> String {
    sweep_expired(now_ms());
    let jobs = with_session(sid, |s| {
        s.jobs
            .iter()
            .map(|j| {
                let done = if j.state == State::Ok {
                    j.total
                } else {
                    j.done.min(j.total)
                };
                let mut row = job_json(
                    j.id,
                    &j.name,
                    j.incoming,
                    done,
                    j.total,
                    j.state,
                    if j.incoming { j.local.as_str() } else { "" },
                );
                row["error"] = json!(j.error);
                row
            })
            .collect::<Vec<_>>()
    })
    .unwrap_or_default();
    Value::Array(jobs).to_string()
}

/// One row of `session_sense_file_jobs` / `main_sense_host_file_jobs`.
fn job_json(
    id: i32,
    name: &str,
    incoming: bool,
    done: u64,
    total: u64,
    state: State,
    path: &str,
) -> Value {
    json!({
        "id": id.to_string(),
        "name": name,
        "kind": kind_of(name),
        "dir": if incoming { "in" } else { "out" },
        "done": done,
        "total": total,
        "state": state.as_str(),
        "path": path,
    })
}

/// Number of chat files of a session (sent and received).
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
        let mut all = SESSIONS.lock().unwrap();
        // A closed session never resumes: what its cut downloads left on disk goes (Y3).
        for j in all
            .iter()
            .filter(|s| gone.contains(&s.sid))
            .flat_map(|s| s.jobs.iter())
            .filter(|j| j.incoming && j.state == State::Resume)
        {
            discard_partial(Path::new(&j.local));
        }
        all.retain(|s| !gone.contains(&s.sid));
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
            j.error = ERR_FAILED;
            // The Host would not (or could not) continue it: no half-written file stays.
            if j.incoming && j.resumed {
                discard_partial(Path::new(&j.local));
            }
        }
    });
}

/// `error` of a transfer the other side or the disk ended.
pub const ERR_FAILED: &str = "failed";
/// `error` of a file from the Host that a dropped link cut and that could not continue (an old
/// Host without resume key, a folder, or [`RESUME_TTL_MS`] passed): the half-written file is
/// removed, the Host offers it again.
pub const ERR_LINK_LOST: &str = "link_lost_not_resumed";

/// Removes what a cut download from the Host left at `local`: the half-written `.download`
/// (and its `.digest`) of a file, or the folder this offer created. Only paths of an
/// unfinished incoming job reach here; the folder name was free when the offer came.
pub fn discard_partial(local: &Path) {
    let with = |ext: &str| {
        let mut p = local.as_os_str().to_owned();
        p.push(ext);
        PathBuf::from(p)
    };
    for p in [with(".download"), with(".digest")] {
        if p.is_file() {
            if let Err(e) = std::fs::remove_file(&p) {
                log::warn!("sense chat file: half-written file not removed: {e}");
            }
        }
    }
    if local.is_dir() {
        if let Err(e) = std::fs::remove_dir_all(local) {
            log::warn!("sense chat file: half-written folder not removed: {e}");
        }
    }
}

/// How long a cut download of a Host file keeps its half-written file waiting for the same
/// session to log in again (Host and Controller use the same limit), Y3.
pub const RESUME_TTL_MS: u64 = 15 * 60 * 1000;

/// `io_loop`: the link dropped. Running jobs wait to resume; `live` gives the file each live
/// read job was at. A single file the Host offered keeps its half-written `.download` and
/// continues at the next login of the session (Y3); a folder, or a file of a Host that sent no
/// resume key, ends with [`ERR_LINK_LOST`] and its half-written files are removed.
pub fn on_link_lost(sid: u64, live: &[(i32, i32)]) {
    let now = now_ms();
    with_session(sid, |s| {
        for j in s.jobs.iter_mut().filter(|j| j.state == State::Run) {
            if j.incoming {
                if j.key.is_empty() || Path::new(&j.local).is_dir() {
                    j.state = State::Err;
                    j.error = ERR_LINK_LOST;
                    discard_partial(Path::new(&j.local));
                } else {
                    j.state = State::Resume;
                    j.cut_at = now;
                }
                continue;
            }
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
    sweep_expired(now_ms());
    with_session(sid, |s| {
        let mut out = Vec::new();
        for j in s.jobs.iter_mut().filter(|j| j.state == State::Resume) {
            j.state = State::Run;
            if j.incoming {
                // From the Host: the same offer again, by its resume key; RustDesk's resume
                // (`.download` + `.digest`) checks the part already written.
                j.resumed = true;
                out.push(Data::AddJob((
                    j.id,
                    JobType::Generic,
                    resume_source(j.id, &j.key, &j.name),
                    j.local.clone(),
                    0,
                    false,
                    true,
                )));
                out.push(Data::ResumeJob((j.id, true)));
                continue;
            }
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
// D3d2: Host → Controller files (offer + white list)
// ---------------------------------------------------------------------------------------------

/// Source mark of an offered file: `sense:offer/<offer id>/<name>`. The real path stays on
/// the Host.
pub const OFFER_MARK: &str = "sense:offer";

/// Source mark of a continued download: `sense:offer-resume/<offer id>/<key>/<name>` (Y3).
pub const RESUME_MARK: &str = "sense:offer-resume";

/// `Misc.plugin_request` id of an offer (Host → Controller). RustDesk builds without the plugin
/// framework ignore it.
pub const OFFER_REQUEST: &str = "sense.file-offer";

/// Offer ids (also the Controller's job id of the download): a range of their own, away from
/// the Controller's chat ids ([`NEXT_ID`]) and the file manager's counter.
pub const OFFER_FIRST: i32 = 0x5F_0000;
const OFFER_END: i32 = 0x60_0000;

/// CM channel (`ipc::Data::Config`) names between the Host card and its connection.
/// Host card → connection: `{id, path, name, total}` of an offer.
pub const CM_OFFER: &str = "sense-offer";
/// Connection → Host card: `{id, ok}` when a read the CM did not run itself ends (Windows reads
/// in the CM; the end is seen by the connection).
pub const CM_OFFER_END: &str = "sense-offer-end";
/// Host card → connection: "Y" / "N" (microphone off during the call).
pub const CM_CALL_MUTED: &str = "sense-call-muted";
/// Host card → connection: sound output of the call ("" = system default).
pub const CM_CALL_OUTPUT: &str = "sense-call-output";
/// Connection → Host card: microphone level 0–1000 (once a second during a call).
pub const CM_CALL_LEVEL: &str = "sense-call-level";

fn is_offer_id(id: i32) -> bool {
    (OFFER_FIRST..OFFER_END).contains(&id)
}

/// Source the Controller asks for.
pub fn offer_source(id: i32, name: &str) -> String {
    format!("{OFFER_MARK}/{id}/{name}")
}

/// (offer id, name) of an offer mark; `None` for any other path.
pub fn parse_offer(path: &str) -> Option<(i32, &str)> {
    let rest = path.strip_prefix(OFFER_MARK)?.strip_prefix('/')?;
    let (id, name) = rest.split_once('/')?;
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let id: i32 = id.parse().ok()?;
    (is_offer_id(id) && safe_name(name)).then_some((id, name))
}

/// Source the Controller asks for when it continues a cut download: the offer id and the
/// resume key the Host gave with the offer (Y3).
pub fn resume_source(id: i32, key: &str, name: &str) -> String {
    format!("{RESUME_MARK}/{id}/{key}/{name}")
}

/// (offer id, key, name) of a resume mark; `None` for any other path.
pub fn parse_resume(path: &str) -> Option<(i32, &str, &str)> {
    let rest = path.strip_prefix(RESUME_MARK)?.strip_prefix('/')?;
    let (id, rest) = rest.split_once('/')?;
    let (key, name) = rest.split_once('/')?;
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let id: i32 = id.parse().ok()?;
    (is_offer_id(id) && valid_key(key) && safe_name(name)).then_some((id, key, name))
}

/// A resume key: 32 lower-case hex digits (16 random bytes).
fn valid_key(k: &str) -> bool {
    k.len() == 32 && k.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn new_key() -> Option<String> {
    use hbb_common::sodiumoxide::{self, randombytes::randombytes_into};
    if sodiumoxide::init().is_err() {
        return None;
    }
    let mut bytes = [0u8; 16];
    randombytes_into(&mut bytes);
    Some(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// One offer the Host kept after the connection that made it ended (server process, memory
/// only): the Controller that was given `key` may read it again until [`RESUME_TTL_MS`].
struct Resumable {
    id: i32,
    key: String,
    path: String,
    at: u64,
}

static RESUMABLE: Mutex<Vec<Resumable>> = Mutex::new(Vec::new());
/// At most this many offers wait for a resume (the oldest go first).
const RESUMABLE_MAX: usize = 256;

fn resumable_put(id: i32, key: &str, path: &str, now: u64) {
    let mut all = RESUMABLE.lock().unwrap();
    all.retain(|r| r.id != id && now.saturating_sub(r.at) <= RESUME_TTL_MS);
    if all.len() >= RESUMABLE_MAX {
        all.remove(0);
    }
    all.push(Resumable {
        id,
        key: key.to_owned(),
        path: path.to_owned(),
        at: now,
    });
}

/// Real path of offer `id` when `key` is its resume key and it has not expired.
fn resumable_find(id: i32, key: &str, now: u64) -> Option<String> {
    let mut all = RESUMABLE.lock().unwrap();
    all.retain(|r| now.saturating_sub(r.at) <= RESUME_TTL_MS);
    all.iter()
        .find(|r| r.id == id && r.key == key)
        .map(|r| r.path.clone())
}

fn resumable_drop(ids: &[i32]) {
    RESUMABLE.lock().unwrap().retain(|r| !ids.contains(&r.id));
}

/// One file of the Host card's list (CM process). Memory only (S12).
#[derive(Debug, Clone)]
struct HostJob {
    conn_id: i32,
    id: i32,
    name: String,
    /// From the Controller (Controller → Host, D3d1); otherwise offered here.
    incoming: bool,
    /// Where an incoming file is saved; empty for an offer.
    path: String,
    total: u64,
    done: u64,
    state: State,
}

static HOST_JOBS: Mutex<Vec<HostJob>> = Mutex::new(Vec::new());
static NEXT_OFFER: AtomicI32 = AtomicI32::new(OFFER_FIRST);

fn next_offer_id() -> i32 {
    let n = NEXT_OFFER.fetch_add(1, Ordering::SeqCst);
    OFFER_FIRST + (n - OFFER_FIRST).rem_euclid(OFFER_END - OFFER_FIRST)
}

/// Host card: offers `paths` on connection `conn_id`; `send` hands the offer to the connection
/// (false: the connection is gone). Returns the offer ids.
pub fn host_offer(conn_id: i32, paths: &[String], send: impl Fn(String) -> bool) -> String {
    let mut ids = Vec::new();
    for path in paths {
        let Some(name) = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| safe_name(n))
        else {
            log::warn!("sense chat file offer: no usable name");
            continue;
        };
        if !Path::new(path).is_absolute() {
            continue;
        }
        let total = match base::fs::get_recursive_files(path, false) {
            Ok(files) => files.iter().map(|f| f.size).sum::<u64>(),
            Err(e) => {
                log::warn!("sense chat file offer not readable: {e}");
                continue;
            }
        };
        let id = next_offer_id();
        let sent = send(
            json!({ "id": id, "path": path, "name": name, "total": total }).to_string(),
        );
        HOST_JOBS.lock().unwrap().push(HostJob {
            conn_id,
            id,
            name,
            incoming: false,
            path: String::new(),
            total,
            done: 0,
            state: if sent { State::Run } else { State::Err },
        });
        ids.push(id.to_string());
    }
    json!(ids).to_string()
}

/// `main_sense_host_offer_files`: the offer ids.
pub fn ffi_host_offer_files(conn_id: i32, paths: &[String]) -> String {
    host_offer(conn_id, paths, |offer| {
        crate::ui_cm_interface::sense_to_conn(
            conn_id,
            crate::ipc::Data::Config((CM_OFFER.to_owned(), Some(offer))),
        )
    })
}

/// Host card (`handle_fs` new write): a chat file from the Controller is saved at `path`.
pub fn host_job_in(conn_id: i32, id: i32, path: &str, total: u64) {
    let name = Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut all = HOST_JOBS.lock().unwrap();
    match all
        .iter_mut()
        .find(|j| j.conn_id == conn_id && j.id == id && j.incoming)
    {
        // The same job again (resume from a later file).
        Some(j) => j.state = State::Run,
        None => all.push(HostJob {
            conn_id,
            id,
            name,
            incoming: true,
            path: path.to_owned(),
            total,
            done: 0,
            state: State::Run,
        }),
    }
}

fn host_job_update(conn_id: Option<i32>, id: i32, f: impl Fn(&mut HostJob)) {
    let mut all = HOST_JOBS.lock().unwrap();
    for j in all
        .iter_mut()
        .filter(|j| j.id == id && conn_id.map_or(true, |c| c == j.conn_id))
    {
        f(j);
    }
}

/// Host card: RustDesk's transfer log (`cm_file_transfer_log` "transfer": one job or a list of
/// jobs, as serialized by `fs::serialize_transfer_job(s)`) moves the Host's file rows.
pub fn host_transfer_log(action: &str, log: &str) {
    if action != "transfer" || HOST_JOBS.lock().unwrap().is_empty() {
        return;
    }
    let Ok(v) = serde_json::from_str::<Value>(log) else {
        return;
    };
    let items = match v {
        Value::Array(a) => a,
        o => vec![o],
    };
    for it in items {
        let Some(id) = it["id"].as_i64().and_then(|i| i32::try_from(i).ok()) else {
            continue;
        };
        let conn_id = it["conn_id"]
            .as_i64()
            .and_then(|c| i32::try_from(c).ok())
            .filter(|c| *c != 0);
        let finished = it["finished_size"].as_u64();
        let done = it["done"].as_bool() == Some(true);
        let failed = it["cancel"].as_bool() == Some(true)
            || it["error"].as_str().map_or(false, |e| !e.is_empty());
        host_job_update(conn_id, id, |j| {
            if j.state != State::Run {
                return;
            }
            if let Some(f) = finished {
                j.done = f;
            }
            if failed {
                j.state = State::Err;
            } else if done {
                j.state = State::Ok;
                j.done = j.total;
            }
        });
    }
}

/// Host card: a message of its connection on the CM channel (`ipc::Data::Config`). True when
/// it was one of ours.
pub fn host_from_conn(conn_id: i32, name: &str, value: Option<&str>) -> bool {
    match name {
        CM_CALL_LEVEL => {
            match value.and_then(|v| v.parse::<u32>().ok()) {
                Some(l) => store_level(l.min(1000) as f32 / 1000.0),
                None => LEVEL_AT.store(0, Ordering::SeqCst),
            }
            true
        }
        CM_OFFER_END => {
            if let Some(v) = value.and_then(|v| serde_json::from_str::<Value>(v).ok()) {
                if let Some(id) = v["id"].as_i64().and_then(|i| i32::try_from(i).ok()) {
                    let ok = v["ok"].as_bool() == Some(true);
                    host_job_update(Some(conn_id), id, |j| {
                        if j.state == State::Run {
                            j.state = if ok { State::Ok } else { State::Err };
                            if ok {
                                j.done = j.total;
                            }
                        }
                    });
                }
            }
            true
        }
        _ => false,
    }
}

/// Host card: connection `conn_id` ended; its file list is gone (S12).
pub fn host_forget(conn_id: i32) {
    HOST_JOBS.lock().unwrap().retain(|j| j.conn_id != conn_id);
}

/// `main_sense_host_file_jobs`: both directions, same shape as `session_sense_file_jobs`.
pub fn ffi_host_file_jobs() -> String {
    let all = HOST_JOBS.lock().unwrap();
    let rows: Vec<Value> = all
        .iter()
        .map(|j| {
            let done = if j.state == State::Ok {
                j.total
            } else {
                j.done.min(j.total)
            };
            job_json(j.id, &j.name, j.incoming, done, j.total, j.state, &j.path)
        })
        .collect();
    Value::Array(rows).to_string()
}

/// Connection (Host, server process): an offer of its Host card ([`CM_OFFER`]). Returns
/// (offer id, real path) for the white list and what the Controller is told (no path).
pub fn conn_offer(raw: &str) -> Option<(i32, String, Vec<u8>)> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let id = i32::try_from(v["id"].as_i64()?).ok()?;
    let path = v["path"].as_str()?;
    let name = v["name"].as_str()?;
    let total = v["total"].as_u64().unwrap_or(0);
    let same_name = Path::new(path)
        .file_name()
        .map_or(false, |n| n.to_string_lossy() == name);
    if !is_offer_id(id) || !safe_name(name) || !Path::new(path).is_absolute() || !same_name {
        log::warn!("sense chat file offer refused: not a valid offer");
        return None;
    }
    let mut content = json!({ "id": id, "name": name, "total": total });
    // Y3: the key lets the same Controller continue this read after a dropped link; the Host
    // path still never leaves the Host.
    if let Some(key) = new_key() {
        resumable_put(id, &key, path, now_ms());
        content["key"] = json!(key);
    }
    Some((id, path.to_owned(), content.to_string().into_bytes()))
}

/// Connection: the Controller started reading offer `id` (white list entry in use).
pub fn offer_reading(reading: &mut Vec<i32>, id: i32) {
    if !reading.contains(&id) {
        reading.push(id);
    }
}

/// Connection: an offer whose read ended (done, failed or cancelled: `still_reading` false)
/// leaves the white list; it cannot be read a second time.
pub fn prune_offers(
    offers: &mut Vec<(i32, String)>,
    reading: &mut Vec<i32>,
    still_reading: impl Fn(i32) -> bool,
) {
    let ended: Vec<i32> = reading
        .iter()
        .copied()
        .filter(|id| !still_reading(*id))
        .collect();
    if ended.is_empty() {
        return;
    }
    reading.retain(|id| !ended.contains(id));
    offers.retain(|(id, _)| !ended.contains(id));
    // An offer whose read ended (done, failed, cancelled) cannot be resumed either.
    resumable_drop(&ended);
}

/// The message that tells the Controller about an offer.
pub fn offer_message(content: Vec<u8>) -> base::message_proto::Message {
    use base::message_proto::{Message, Misc, PluginRequest};
    let mut misc = Misc::new();
    misc.set_plugin_request(PluginRequest {
        id: OFFER_REQUEST.to_owned(),
        content: content.into(),
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

/// Controller (`io_loop`): the Host offers a file. Returns the download that pulls it into the
/// incoming folder (same open session, no second connection — S8); `None` for anything that
/// is not a valid new offer.
pub fn on_offer(sid: u64, peer: &str, content: &[u8]) -> Option<Data> {
    on_offer_into(sid, peer, content, &incoming_dir())
}

fn on_offer_into(sid: u64, peer: &str, content: &[u8], dir: &Path) -> Option<Data> {
    let v: Value = serde_json::from_slice(content).ok()?;
    let id = i32::try_from(v["id"].as_i64()?).ok()?;
    let name = v["name"].as_str()?.to_owned();
    let total = v["total"].as_u64().unwrap_or(0);
    if !is_offer_id(id) || !safe_name(&name) {
        log::warn!("sense chat file: invalid offer ignored");
        return None;
    }
    // A Host that sends no (valid) key cannot be resumed: a cut then ends the download.
    let key = v["key"]
        .as_str()
        .filter(|k| valid_key(k))
        .unwrap_or_default()
        .to_owned();
    let (known, busy) = with_session(sid, |s| {
        (
            s.jobs.iter().any(|j| j.id == id),
            s.jobs
                .iter()
                .filter(|j| j.incoming)
                .map(|j| PathBuf::from(&j.local))
                .collect::<Vec<_>>(),
        )
    })
    .unwrap_or_default();
    if known {
        return None;
    }
    // A half-written ".download" of an earlier transfer counts as taken (a new offer never
    // continues it; only the cut job itself does, by its resume key).
    let taken = |n: &str| {
        let p = dir.join(n);
        p.exists() || dir.join(format!("{n}.download")).exists() || busy.contains(&p)
    };
    let target = dir.join(free_name(&name, taken));
    let local = target.to_string_lossy().into_owned();
    add_job(
        sid,
        peer,
        Job {
            id,
            name: name.clone(),
            incoming: true,
            local: local.clone(),
            total,
            done: 0,
            file_num: 0,
            state: State::Run,
            error: "",
            key,
            cut_at: 0,
            resumed: false,
        },
    );
    log::info!("sense chat file from the Host to the incoming folder");
    Some(Data::SendFiles((
        id,
        JobType::Generic,
        offer_source(id, &name),
        local,
        0,
        false,
        true,
    )))
}

// ---------------------------------------------------------------------------------------------
// D3d2: call controls (microphone off, level, sound output)
// ---------------------------------------------------------------------------------------------

/// A call microphone is open in this process (`audio_service` voice call input device).
static CALL_MIC: AtomicBool = AtomicBool::new(false);
static MUTED: AtomicBool = AtomicBool::new(false);
/// Microphone level 0–1000 and when it was measured (ms since the epoch).
static LEVEL: AtomicU32 = AtomicU32::new(0);
static LEVEL_AT: AtomicU64 = AtomicU64::new(0);
/// A level older than this is unknown.
const LEVEL_FRESH_MS: u64 = 2500;
/// Sound output of the call; empty = system default.
static OUTPUT: Mutex<String> = Mutex::new(String::new());
static OUTPUT_CHANGED: AtomicBool = AtomicBool::new(false);

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn store_level(v: f32) {
    let v = if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
    LEVEL.store((v * 1000.0).round() as u32, Ordering::SeqCst);
    LEVEL_AT.store(now_ms(), Ordering::SeqCst);
}

/// `audio_service`: the voice call input device was set (`Some`) or cleared. The end of a
/// call opens the microphone again for the next one.
pub fn set_call_mic(on: bool) {
    CALL_MIC.store(on, Ordering::SeqCst);
    if !on {
        MUTED.store(false, Ordering::SeqCst);
        LEVEL.store(0, Ordering::SeqCst);
        LEVEL_AT.store(0, Ordering::SeqCst);
    }
}

/// Microphone off in this process (the Controller app, or the Host's server process).
pub fn set_muted(muted: bool) {
    MUTED.store(muted, Ordering::SeqCst);
}

/// The audio capture callback's view of the call microphone: measures the level and, when the
/// microphone is off, passes silence instead of the samples. Does nothing outside a call.
pub struct MicTap {
    active: bool,
    muted: bool,
    peak: f32,
}

impl MicTap {
    pub fn new() -> Self {
        Self {
            active: CALL_MIC.load(Ordering::Relaxed),
            muted: MUTED.load(Ordering::Relaxed),
            peak: 0.0,
        }
    }

    #[inline]
    pub fn sample(&mut self, s: f32) -> f32 {
        if !self.active {
            return s;
        }
        let a = s.abs();
        if a > self.peak && a.is_finite() {
            self.peak = a;
        }
        if self.muted {
            0.0
        } else {
            s
        }
    }
}

impl Drop for MicTap {
    fn drop(&mut self) {
        if self.active {
            // Falls back slowly, so a once-a-second reading still shows speech.
            let old = LEVEL.load(Ordering::Relaxed) as f32 / 1000.0;
            let level = if self.muted { 0.0 } else { self.peak.max(old - 0.02) };
            store_level(level);
        }
    }
}

/// Microphone level 0.0–1.0; below 0 = unknown (no call, or nothing measured lately).
pub fn call_level() -> f64 {
    let at = LEVEL_AT.load(Ordering::SeqCst);
    if at == 0 || now_ms().saturating_sub(at) > LEVEL_FRESH_MS {
        return -1.0;
    }
    LEVEL.load(Ordering::SeqCst) as f64 / 1000.0
}

/// Connection (Host, server process): the level for the Host card, while measured.
pub fn level_for_cm() -> Option<String> {
    let l = call_level();
    (l >= 0.0).then(|| ((l * 1000.0).round() as u32).to_string())
}

/// Connection (Host, server process): a call setting of the Host card on the CM channel. True
/// when it was one of ours.
pub fn conn_call_setting(name: &str, value: Option<&str>) -> bool {
    match name {
        CM_CALL_MUTED => {
            set_muted(value == Some("Y"));
            true
        }
        CM_CALL_OUTPUT => {
            set_output(value.unwrap_or(""));
            true
        }
        _ => false,
    }
}

fn set_output(device: &str) {
    let mut o = OUTPUT.lock().unwrap();
    if *o != device {
        *o = device.to_owned();
        OUTPUT_CHANGED.store(true, Ordering::SeqCst);
    }
}

/// Audio playback thread: the call's sound output changed since the last look.
pub fn take_output_change() -> bool {
    OUTPUT_CHANGED.swap(false, Ordering::SeqCst)
}

/// Audio playback: the chosen sound output, when it is connected; `None` = system default.
#[cfg(not(target_os = "linux"))]
pub fn call_output_device(host: &cpal::Host) -> Option<cpal::Device> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let name = OUTPUT.lock().unwrap().clone();
    if name.is_empty() {
        return None;
    }
    let found = host
        .output_devices()
        .ok()?
        .find(|d| d.name().map_or(false, |n| n == name));
    if found.is_none() {
        log::warn!("sense call output not found, using the default one");
    }
    found
}

/// Runs `work` on its own thread and waits at most `limit` for its answer; empty on time-out.
#[cfg_attr(target_os = "linux", allow(dead_code))]
fn within(
    limit: std::time::Duration,
    work: impl FnOnce() -> Vec<String> + Send + 'static,
) -> Vec<String> {
    let (tx, rx) = std::sync::mpsc::channel();
    if std::thread::Builder::new()
        .name("sense-sound-outputs".to_owned())
        .spawn(move || {
            let _ = tx.send(work());
        })
        .is_err()
    {
        return Vec::new();
    }
    rx.recv_timeout(limit).unwrap_or_default()
}

/// Names of this computer's sound outputs.
fn output_names() -> Vec<String> {
    #[cfg(not(target_os = "linux"))]
    {
        // Sense Remote (B7): counting the devices is a driver call that can hang; wait a few
        // seconds, then answer with no devices (the thread is left behind).
        within(std::time::Duration::from_secs(3), || {
            use cpal::traits::{DeviceTrait, HostTrait};
            let mut out = Vec::new();
            if let Ok(devices) = cpal::default_host().output_devices() {
                for d in devices {
                    if d.default_output_config().is_err() {
                        continue;
                    }
                    if let Ok(name) = d.name() {
                        if !out.contains(&name) {
                            out.push(name);
                        }
                    }
                }
            }
            out
        })
    }
    #[cfg(target_os = "linux")]
    {
        Vec::new()
    }
}

/// Sound outputs + the chosen one ("" when it is the default or no longer connected).
fn sound_outputs_json(outputs: Vec<String>, chosen: &str) -> String {
    let output = if outputs.iter().any(|o| o == chosen) {
        chosen
    } else {
        ""
    };
    json!({ "outputs": outputs, "output": output }).to_string()
}

/// Whether `device` can be chosen ("" = system default, always).
fn output_choosable(outputs: &[String], device: &str) -> bool {
    device.is_empty() || outputs.iter().any(|o| o == device)
}

/// `main_sense_host_start_call`: voice call started on the Host (the Controller answers).
pub fn ffi_host_start_call(conn_id: i32) {
    if !crate::ui_cm_interface::sense_to_conn(conn_id, crate::ipc::Data::StartVoiceCall) {
        log::warn!("sense call: no such connection");
    }
}

/// `main_sense_sound_outputs`: `{outputs: [..], output}`; `output` empty = system default.
pub fn ffi_sound_outputs() -> String {
    let chosen = OUTPUT.lock().unwrap().clone();
    sound_outputs_json(output_names(), &chosen)
}

/// `main_sense_set_call_output`: true when the call now plays on `device` ("" = default). On the
/// Host the card's connections play it (server process), so it is passed on to them.
pub fn ffi_set_call_output(device: &str) -> bool {
    if !output_choosable(&output_names(), device) {
        return false;
    }
    set_output(device);
    crate::ui_cm_interface::sense_to_all(crate::ipc::Data::Config((
        CM_CALL_OUTPUT.to_owned(),
        Some(device.to_owned()),
    )));
    true
}

/// `session_sense_call_set_muted`: true when the microphone is now muted / open as asked. On
/// the Host the microphone is captured by the server process, so it is passed on.
pub fn ffi_call_set_muted(muted: bool) -> bool {
    set_muted(muted);
    crate::ui_cm_interface::sense_to_all(crate::ipc::Data::Config((
        CM_CALL_MUTED.to_owned(),
        Some(if muted { "Y" } else { "N" }.to_owned()),
    )));
    true
}

/// `session_sense_call_level`: microphone level 0.0–1.0 during a call; below 0 = unknown.
pub fn ffi_call_level() -> f64 {
    call_level()
}

#[cfg(test)]
mod tests {
    #[test]
    fn hanging_device_listing_gives_up() {
        use std::time::{Duration, Instant};
        let started = Instant::now();
        let out = within(Duration::from_millis(100), || {
            std::thread::sleep(Duration::from_secs(30));
            vec!["x".to_owned()]
        });
        assert!(out.is_empty());
        assert!(started.elapsed() < Duration::from_secs(10));
        let out = within(Duration::from_secs(5), || vec!["a".to_owned()]);
        assert_eq!(out, vec!["a".to_owned()]);
    }

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
            host_file_action(true, &receive("sense:incoming/a.txt"), &[]),
            HostAction::Handle
        );
        // Any real Host path stays off, permission or not.
        assert_eq!(
            host_file_action(true, &receive("C:\\Windows\\a.txt"), &[]),
            HostAction::Ignore
        );
        assert_eq!(host_file_action(true, &receive("sense:incoming/../a"), &[]), HostAction::Ignore);

        let mut read = FileAction::new();
        read.set_read_dir(ReadDir {
            path: "C:\\".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &read, &[]), HostAction::Ignore);

        let mut send = FileAction::new();
        send.set_send(FileTransferSendRequest {
            id: 1,
            path: "sense:incoming/a.txt".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &send, &[]), HostAction::Ignore);

        let mut rm = FileAction::new();
        rm.set_remove_file(FileRemoveFile {
            id: 1,
            path: "sense:incoming/a.txt".to_owned(),
            ..Default::default()
        });
        assert_eq!(host_file_action(true, &rm, &[]), HostAction::Ignore);

        let mut confirm = FileAction::new();
        confirm.set_send_confirm(FileTransferSendConfirmRequest::default());
        assert_eq!(host_file_action(true, &confirm, &[]), HostAction::Handle);
        let mut cancel = FileAction::new();
        cancel.set_cancel(FileTransferCancel::default());
        assert_eq!(host_file_action(true, &cancel, &[]), HostAction::Handle);
    }

    #[test]
    fn files_off_refuses_the_upload() {
        assert_eq!(
            host_file_action(false, &receive("sense:incoming/a.txt"), &[]),
            HostAction::Refuse(7)
        );
        let mut confirm = FileAction::new();
        confirm.set_send_confirm(FileTransferSendConfirmRequest::default());
        assert_eq!(host_file_action(false, &confirm, &[]), HostAction::Ignore);
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
            ..Default::default()
        };
        assert_eq!(big.audit(), json!({ "chat_messages": 100_000, "files": 100_000 }));
    }

    #[test]
    fn audit_carries_recording_length_and_close_reason() {
        let mut c = ConnCounts::default();
        c.add_message();
        // Never recorded, reason unknown: the record is what it was (old panels and new agree).
        assert_eq!(c.audit(), json!({ "chat_messages": 1, "files": 0 }));
        // Two recordings add up; a recording shorter than a second still counts as taken.
        c.add_recording(90);
        c.add_recording(0);
        c.add_recording(30);
        c.set_close_reason("Peer close");
        // The first reason wins; unknown texts change nothing.
        c.set_close_reason("auto disconnect");
        let v = c.audit();
        assert_eq!(
            v,
            json!({ "chat_messages": 1, "files": 0, "recording_s": 120, "reason": "controller" })
        );
        // Only the fields the panel's strict `AuditConnSense` knows.
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(|k| k.as_str()).collect();
        assert!(keys
            .iter()
            .all(|k| ["chat_messages", "files", "recording_s", "reason"].contains(k)));
        let mut z = ConnCounts::default();
        z.add_recording(0);
        assert_eq!(z.audit()["recording_s"], 0);
        z.add_recording(u64::MAX);
        assert_eq!(z.audit()["recording_s"], 31 * 86_400);
    }

    #[test]
    fn close_reason_codes_are_the_panels() {
        for (text, code) in [
            ("Peer close", Some("controller")),
            ("connection manager", Some("host_ended")),
            ("connection manager window closed", Some("host_ended")),
            ("stop service", Some("host_ended")),
            ("auto disconnect", Some("idle")),
            ("Timeout", Some("peer_gone")),
            ("Reset by the peer", Some("peer_gone")),
            ("web console", None),
            ("End", None),
            ("", None),
        ] {
            assert_eq!(close_reason_code(text), code, "{text}");
        }
        // A reason never set stays out of the record; the first known one is kept.
        let mut c = ConnCounts::default();
        c.set_close_reason("End");
        assert!(c.audit().get("reason").is_none());
        c.set_close_reason("Timeout");
        c.set_close_reason("Peer close");
        assert_eq!(c.audit()["reason"], "peer_gone");
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
    fn offer_mark_round_trip_and_bad_marks() {
        let id = OFFER_FIRST + 5;
        let src = offer_source(id, "rapor.pdf");
        assert_eq!(src, format!("sense:offer/{id}/rapor.pdf"));
        assert_eq!(parse_offer(&src), Some((id, "rapor.pdf")));
        for bad in [
            format!("sense:offer/{}/a.txt", OFFER_FIRST - 1),
            format!("sense:offer/{OFFER_END}/a.txt"),
            format!("sense:offer/+{id}/a.txt"),
            format!("sense:offer/{id}/../x"),
            format!("sense:offer/{id}/a/b"),
            format!("sense:offer/{id}/"),
            format!("sense:offer/{id}"),
            format!("sense:offerx/{id}/a"),
            "sense:incoming/a.txt".to_owned(),
            "C:\\Users\\a\\x.txt".to_owned(),
        ] {
            assert_eq!(parse_offer(&bad), None, "{bad}");
        }
    }

    fn send(id: i32, path: &str) -> FileAction {
        let mut fa = FileAction::new();
        fa.set_send(FileTransferSendRequest {
            id,
            path: path.to_owned(),
            ..Default::default()
        });
        fa
    }

    #[test]
    fn host_reads_only_what_it_offered() {
        let id = OFFER_FIRST + 7;
        let offers = vec![(id, "C:\\Users\\a\\rapor.pdf".to_owned())];
        let mark = offer_source(id, "rapor.pdf");
        assert_eq!(
            host_file_action(true, &send(id, &mark), &offers),
            HostAction::Offer("C:\\Users\\a\\rapor.pdf".to_owned())
        );
        // Files off: the read is refused, not ignored.
        assert_eq!(host_file_action(false, &send(id, &mark), &offers), HostAction::Refuse(id));
        // Another job id than the offer's.
        assert_eq!(host_file_action(true, &send(id + 1, &mark), &offers), HostAction::Ignore);
        // An offer of another connection (not in this list).
        let other = offer_source(id + 1, "rapor.pdf");
        assert_eq!(host_file_action(true, &send(id + 1, &other), &offers), HostAction::Ignore);
        // Any real Host path, even the offered one.
        assert_eq!(
            host_file_action(true, &send(id, "C:\\Users\\a\\rapor.pdf"), &offers),
            HostAction::Ignore
        );
        assert_eq!(
            host_file_action(true, &send(id, "C:\\Windows\\win.ini"), &offers),
            HostAction::Ignore
        );
        // Nothing offered: nothing read.
        assert_eq!(host_file_action(true, &send(id, &mark), &[]), HostAction::Ignore);
    }

    #[test]
    fn offer_leaves_the_white_list_when_its_read_ends() {
        let (a, b, c) = (OFFER_FIRST + 40, OFFER_FIRST + 41, OFFER_FIRST + 42);
        let mut offers = vec![
            (a, "/h/a.txt".to_owned()),
            (b, "/h/b.txt".to_owned()),
            (c, "/h/c.txt".to_owned()),
        ];
        let mut reading = Vec::new();
        offer_reading(&mut reading, a);
        offer_reading(&mut reading, b);
        offer_reading(&mut reading, a);
        assert_eq!(reading, vec![a, b]);
        // a still reads, b ended; c was never read and stays offered.
        prune_offers(&mut offers, &mut reading, |id| id == a);
        assert_eq!(reading, vec![a]);
        assert_eq!(offers.iter().map(|(i, _)| *i).collect::<Vec<_>>(), vec![a, c]);
        // The ended offer cannot be read again.
        let mark = offer_source(b, "b.txt");
        assert_eq!(host_file_action(true, &send(b, &mark), &offers), HostAction::Ignore);
        prune_offers(&mut offers, &mut reading, |_| false);
        assert_eq!(offers.iter().map(|(i, _)| *i).collect::<Vec<_>>(), vec![c]);
        assert!(reading.is_empty());
    }

    #[test]
    fn offer_travels_without_the_host_path() {
        let host_dir = temp_dir("offer-host");
        let file = host_dir.join("plan.pdf");
        std::fs::write(&file, vec![0u8; 2048]).unwrap();
        let conn_id = 9101;
        let sent = RefCell::new(Vec::new());
        let ids = parse(&host_offer(
            conn_id,
            &[
                file.to_string_lossy().into_owned(),
                host_dir.join("yok.txt").to_string_lossy().into_owned(),
            ],
            |m| {
                sent.borrow_mut().push(m);
                true
            },
        ));
        assert_eq!(ids.as_array().unwrap().len(), 1, "a missing file is not offered");
        let id: i32 = ids[0].as_str().unwrap().parse().unwrap();
        assert!(is_offer_id(id));

        // Host card list: an outgoing row.
        let rows = parse(&ffi_host_file_jobs());
        let row = rows
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == json!(id.to_string()))
            .unwrap()
            .clone();
        assert_eq!(row["dir"], "out");
        assert_eq!(row["state"], "run");
        assert_eq!(row["total"], 2048);

        // Connection: white list entry, and what the Controller hears has no path.
        let (oid, path, content) = conn_offer(&sent.borrow()[0]).unwrap();
        assert_eq!(oid, id);
        assert_eq!(path, file.to_string_lossy());
        let told: Value = serde_json::from_slice(&content).unwrap();
        // Y3: a resume key rides with the offer (never the path).
        let key = told["key"].as_str().unwrap().to_owned();
        assert!(valid_key(&key));
        assert_eq!(
            told,
            json!({ "id": id, "name": "plan.pdf", "total": 2048, "key": key })
        );
        let msg = offer_message(content.clone());
        assert_eq!(msg.misc().plugin_request().id, OFFER_REQUEST);

        // Controller: pulls it into its incoming folder under a free name.
        let in_dir = temp_dir("offer-ctrl");
        std::fs::write(in_dir.join("plan.pdf"), b"old").unwrap();
        let sid = 0xB001;
        match on_offer_into(sid, "p", &content, &in_dir) {
            Some(Data::SendFiles((jid, JobType::Generic, from, to, 0, false, true))) => {
                assert_eq!(jid, id);
                assert_eq!(from, offer_source(id, "plan.pdf"));
                assert_eq!(PathBuf::from(&to), in_dir.join("plan (1).pdf"));
            }
            _ => panic!("unexpected Data"),
        }
        // The same offer twice starts nothing.
        assert!(on_offer_into(sid, "p", &content, &in_dir).is_none());
        let jobs = parse(&ffi_file_jobs(sid));
        assert_eq!(jobs[0]["dir"], "in");
        assert_eq!(jobs[0]["name"], "plan.pdf");
        assert_eq!(
            PathBuf::from(jobs[0]["path"].as_str().unwrap()),
            in_dir.join("plan (1).pdf")
        );
        assert_eq!(file_count(sid), 1);
        on_progress(sid, id, 1024);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["done"], 1024);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["error"], "");
        // Y3: a drop keeps the half-written file; the job waits and continues at the next login
        // of the same session, by the key of the offer.
        let part = in_dir.join("plan (1).pdf.download");
        std::fs::write(&part, b"half").unwrap();
        on_link_lost(sid, &[]);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "resume");
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["error"], "");
        assert!(part.exists());
        assert!(on_connected(0xFFFF).is_empty());
        let again = on_connected(sid);
        assert_eq!(again.len(), 2);
        let src = resume_source(id, &key, "plan.pdf");
        match (&again[0], &again[1]) {
            (
                Data::AddJob((a, JobType::Generic, from, to, 0, false, true)),
                Data::ResumeJob((b, true)),
            ) => {
                assert_eq!((*a, *b), (id, id));
                assert_eq!(from, &src);
                assert_eq!(PathBuf::from(to), in_dir.join("plan (1).pdf"));
            }
            _ => panic!("unexpected Data"),
        }
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "run");
        assert!(on_connected(sid).is_empty(), "resumed once only");

        // Host, new connection (empty white list): the key opens the read of that offer only.
        assert_eq!(
            host_file_action(true, &send(id, &src), &[]),
            HostAction::Offer(file.to_string_lossy().into_owned())
        );
        assert_eq!(host_file_action(false, &send(id, &src), &[]), HostAction::Refuse(id));
        let wrong = resume_source(id, &"0".repeat(32), "plan.pdf");
        assert_eq!(host_file_action(true, &send(id, &wrong), &[]), HostAction::Refuse(id));
        assert_eq!(host_file_action(true, &send(id + 1, &src), &[]), HostAction::Ignore);
        // Once its read ends the offer is gone for good.
        let mut offers = Vec::new();
        let mut reading = vec![id];
        prune_offers(&mut offers, &mut reading, |_| false);
        assert_eq!(host_file_action(true, &send(id, &src), &[]), HostAction::Refuse(id));

        // The Host refuses a continue (it restarted): the job ends and no half file stays.
        on_status(sid, id, Some("Permission denied"));
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "err");
        assert!(!part.exists());
        assert_eq!(std::fs::read(in_dir.join("plan.pdf")).unwrap(), b"old");
        assert!(on_connected(sid).is_empty());
        forget_closed(|s, _| s != sid);

        host_forget(conn_id);
        assert!(!parse(&ffi_host_file_jobs())
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == json!(id.to_string())));
        std::fs::remove_dir_all(&host_dir).ok();
        std::fs::remove_dir_all(&in_dir).ok();
    }

    #[test]
    fn discard_partial_removes_only_the_cut_download() {
        let dir = temp_dir("discard");
        // A file: its ".download" and ".digest" go, a finished neighbour stays.
        std::fs::write(dir.join("a.bin.download"), b"x").unwrap();
        std::fs::write(dir.join("a.bin.digest"), b"{}").unwrap();
        std::fs::write(dir.join("b.bin"), b"done").unwrap();
        discard_partial(&dir.join("a.bin"));
        assert!(!dir.join("a.bin.download").exists());
        assert!(!dir.join("a.bin.digest").exists());
        assert!(dir.join("b.bin").exists());
        // A folder this offer created goes with what is in it.
        std::fs::create_dir_all(dir.join("Proje (1)").join("alt")).unwrap();
        std::fs::write(dir.join("Proje (1)").join("alt").join("x.download"), b"x").unwrap();
        discard_partial(&dir.join("Proje (1)"));
        assert!(!dir.join("Proje (1)").exists());
        // Nothing there: nothing happens.
        discard_partial(&dir.join("yok.txt"));
        assert!(dir.join("b.bin").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    fn offer_content(id: i32, name: &str, key: Option<&str>) -> Vec<u8> {
        let mut v = json!({ "id": id, "name": name, "total": 100 });
        if let Some(k) = key {
            v["key"] = json!(k);
        }
        v.to_string().into_bytes()
    }

    #[test]
    fn cut_download_without_key_or_of_a_folder_is_removed() {
        let dir = temp_dir("nokey");
        let sid = 0xB101;
        // An old Host sends no key: the cut ends it, as before.
        let old = OFFER_FIRST + 900;
        assert!(on_offer_into(sid, "p", &offer_content(old, "a.bin", None), &dir).is_some());
        std::fs::write(dir.join("a.bin.download"), b"x").unwrap();
        // A folder offer cannot continue (the file it was at is unknown).
        let folder = OFFER_FIRST + 901;
        let key = "ab".repeat(16);
        assert!(on_offer_into(sid, "p", &offer_content(folder, "Proje", Some(&key)), &dir).is_some());
        std::fs::create_dir_all(dir.join("Proje").join("alt")).unwrap();
        std::fs::write(dir.join("Proje").join("alt").join("x.download"), b"x").unwrap();
        // A key that is not 32 hex digits counts as none.
        let bad = OFFER_FIRST + 902;
        assert!(on_offer_into(sid, "p", &offer_content(bad, "b.bin", Some("XYZ")), &dir).is_some());
        std::fs::write(dir.join("b.bin.download"), b"x").unwrap();

        on_link_lost(sid, &[]);
        for row in parse(&ffi_file_jobs(sid)).as_array().unwrap() {
            assert_eq!(row["state"], "err");
            assert_eq!(row["error"], ERR_LINK_LOST);
        }
        assert!(!dir.join("a.bin.download").exists());
        assert!(!dir.join("Proje").exists());
        assert!(!dir.join("b.bin.download").exists());
        assert!(on_connected(sid).is_empty());
        forget_closed(|s, _| s != sid);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn cut_download_is_cleaned_after_the_wait_or_when_the_session_closes() {
        let dir = temp_dir("ttl");
        let key = "cd".repeat(16);
        // Waited too long: the next list read ends it and removes the half file.
        let sid = 0xB102;
        let id = OFFER_FIRST + 910;
        assert!(on_offer_into(sid, "p", &offer_content(id, "c.bin", Some(&key)), &dir).is_some());
        std::fs::write(dir.join("c.bin.download"), b"x").unwrap();
        on_link_lost(sid, &[]);
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["state"], "resume");
        assert!(dir.join("c.bin.download").exists());
        with_job(sid, id, |j| j.cut_at = 0);
        let rows = parse(&ffi_file_jobs(sid));
        assert_eq!(rows[0]["state"], "err");
        assert_eq!(rows[0]["error"], ERR_LINK_LOST);
        assert!(!dir.join("c.bin.download").exists());
        assert!(on_connected(sid).is_empty());
        forget_closed(|s, _| s != sid);

        // The session closes while it waits: nothing stays on disk.
        let sid2 = 0xB103;
        let id2 = OFFER_FIRST + 911;
        assert!(on_offer_into(sid2, "p", &offer_content(id2, "d.bin", Some(&key)), &dir).is_some());
        std::fs::write(dir.join("d.bin.download"), b"x").unwrap();
        std::fs::write(dir.join("d.bin.digest"), b"{}").unwrap();
        on_link_lost(sid2, &[]);
        assert!(dir.join("d.bin.download").exists());
        forget_closed(|s, _| s != sid2);
        assert!(!dir.join("d.bin.download").exists());
        assert!(!dir.join("d.bin.digest").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resume_marks_and_keys() {
        let key = "0123456789abcdef".repeat(2);
        let id = OFFER_FIRST + 920;
        let src = resume_source(id, &key, "film.mp4");
        assert_eq!(src, format!("sense:offer-resume/{id}/{key}/film.mp4"));
        assert_eq!(parse_resume(&src), Some((id, key.as_str(), "film.mp4")));
        // A resume mark is never an offer mark, nor the other way round.
        assert_eq!(parse_offer(&src), None);
        assert_eq!(parse_resume(&offer_source(id, "film.mp4")), None);
        for bad in [
            format!("sense:offer-resume/{}/{key}/a.txt", OFFER_FIRST - 1),
            format!("sense:offer-resume/{id}/{}/a.txt", "AB".repeat(16)),
            format!("sense:offer-resume/{id}/{}/a.txt", "ab".repeat(15)),
            format!("sense:offer-resume/{id}/{key}/../x"),
            format!("sense:offer-resume/{id}/{key}/a/b"),
            format!("sense:offer-resume/{id}/{key}/"),
            format!("sense:offer-resume/{id}//a.txt"),
            format!("sense:offer-resume/+{id}/{key}/a.txt"),
        ] {
            assert_eq!(parse_resume(&bad), None, "{bad}");
        }
        // A key made on the Host is valid and different each time.
        let (a, b) = (new_key().unwrap(), new_key().unwrap());
        assert!(valid_key(&a) && valid_key(&b));
        assert_ne!(a, b);
    }

    #[test]
    fn host_keeps_a_resumable_offer_only_for_a_while() {
        let id = OFFER_FIRST + 930;
        let key = "ef".repeat(16);
        let now = now_ms();
        resumable_put(id, &key, "/h/film.mp4", now);
        assert_eq!(resumable_find(id, &key, now), Some("/h/film.mp4".to_owned()));
        assert_eq!(resumable_find(id, &"00".repeat(16), now), None, "wrong key");
        assert_eq!(resumable_find(id + 1, &key, now), None, "other offer");
        // Expired entries are gone, whoever asks.
        resumable_put(id, &key, "/h/film.mp4", now.saturating_sub(RESUME_TTL_MS + 1));
        assert_eq!(resumable_find(id, &key, now), None);
        // An ended read drops it.
        resumable_put(id, &key, "/h/film.mp4", now);
        resumable_drop(&[id]);
        assert_eq!(resumable_find(id, &key, now), None);
    }

    #[test]
    fn failed_job_has_its_reason() {
        let dir = temp_dir("reason");
        let file = dir.join("a.txt");
        std::fs::write(&file, b"x").unwrap();
        let sid = 0xB003;
        let ids = parse(&ffi_send_files(sid, "p", &[file.to_string_lossy().into_owned()], |_| {}));
        let id: i32 = ids[0].as_str().unwrap().parse().unwrap();
        on_status(sid, id, Some("disk full"));
        assert_eq!(parse(&ffi_file_jobs(sid))[0]["error"], ERR_FAILED);
        forget_closed(|s, _| s != sid);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn bad_offers_are_refused() {
        let id = OFFER_FIRST + 20;
        let path = if cfg!(windows) { "C:\\Users\\a\\x.txt" } else { "/home/a/x.txt" };
        let ok = json!({ "id": id, "path": path, "name": "x.txt", "total": 1 });
        assert!(conn_offer(&ok.to_string()).is_some());
        for bad in [
            json!({ "id": OFFER_FIRST - 1, "path": path, "name": "x.txt" }),
            json!({ "id": id, "path": "x.txt", "name": "x.txt" }),
            json!({ "id": id, "path": path, "name": "y.txt" }),
            json!({ "id": id, "path": path, "name": "../x.txt" }),
            json!({ "id": id, "name": "x.txt" }),
        ] {
            assert!(conn_offer(&bad.to_string()).is_none(), "{bad}");
        }
        assert!(conn_offer("not json").is_none());
        // Controller side.
        let dir = temp_dir("offer-bad");
        for bad in [
            json!({ "id": 5, "name": "a.txt" }),
            json!({ "id": id, "name": "a/b.txt" }),
            json!({ "id": id, "name": ".." }),
        ] {
            assert!(on_offer_into(0xB002, "p", bad.to_string().as_bytes(), &dir).is_none());
        }
        assert!(on_offer_into(0xB002, "p", b"[]", &dir).is_none());
        assert_eq!(file_count(0xB002), 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn offer_to_a_gone_connection_fails_at_once() {
        let dir = temp_dir("offer-gone");
        let file = dir.join("a.txt");
        std::fs::write(&file, b"x").unwrap();
        let ids = parse(&host_offer(9102, &[file.to_string_lossy().into_owned()], |_| false));
        let id = ids[0].as_str().unwrap().to_owned();
        let rows = parse(&ffi_host_file_jobs());
        let row = rows.as_array().unwrap().iter().find(|r| r["id"] == json!(id)).unwrap();
        assert_eq!(row["state"], "err");
        host_forget(9102);
        std::fs::remove_dir_all(&dir).ok();
    }

    fn host_row(id: i32) -> Value {
        parse(&ffi_host_file_jobs())
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == json!(id.to_string()))
            .cloned()
            .unwrap_or(Value::Null)
    }

    #[test]
    fn host_rows_follow_the_transfer_log() {
        // Controller → Host: saved in the incoming folder.
        let (conn, a, b, c) = (9103, 0x5E_7001, 0x5E_7002, OFFER_FIRST + 30);
        host_job_in(conn, a, "/in/a.bin", 100);
        host_job_in(conn, b, "/in/b.bin", 50);
        assert_eq!(host_row(a)["dir"], "in");
        assert_eq!(host_row(a)["path"], "/in/a.bin");
        assert_eq!(host_row(a)["name"], "a.bin");
        // The array RustDesk sends after each block.
        host_transfer_log(
            "transfer",
            &json!([{ "id": a, "conn_id": conn, "finished_size": 40, "total_size": 100 }])
                .to_string(),
        );
        assert_eq!(host_row(a)["done"], 40);
        assert_eq!(host_row(a)["state"], "run");
        // Another connection's job of the same id is not touched.
        host_transfer_log(
            "transfer",
            &json!({ "id": a, "conn_id": conn + 1, "done": true }).to_string(),
        );
        assert_eq!(host_row(a)["state"], "run");
        // Done, error.
        host_transfer_log(
            "transfer",
            &json!({ "id": a, "conn_id": conn, "done": true, "cancel": false, "error": "" })
                .to_string(),
        );
        assert_eq!(host_row(a)["state"], "ok");
        assert_eq!(host_row(a)["done"], 100);
        host_transfer_log(
            "transfer",
            &json!({ "id": b, "conn_id": conn, "done": false, "cancel": false, "error": "disk full" })
                .to_string(),
        );
        assert_eq!(host_row(b)["state"], "err");
        // Other log kinds and broken text are ignored.
        host_transfer_log("remove", "{}");
        host_transfer_log("transfer", "not json");

        // Host → Controller read the connection saw end (Windows: read in the CM).
        HOST_JOBS.lock().unwrap().push(HostJob {
            conn_id: conn,
            id: c,
            name: "c.txt".to_owned(),
            incoming: false,
            path: String::new(),
            total: 10,
            done: 0,
            state: State::Run,
        });
        let end = json!({ "id": c, "ok": true }).to_string();
        assert!(host_from_conn(conn, CM_OFFER_END, Some(end.as_str())));
        assert_eq!(host_row(c)["state"], "ok");
        assert_eq!(host_row(c)["done"], 10);
        assert!(!host_from_conn(conn, "audio-input", Some("x")));

        // The connection ends: the list is gone (S12).
        host_forget(conn);
        assert_eq!(host_row(a), Value::Null);
        assert_eq!(host_row(c), Value::Null);
    }

    #[test]
    fn microphone_off_level_and_output() {
        // Outside a call the samples pass untouched and nothing is measured.
        set_call_mic(false);
        let mut tap = MicTap::new();
        assert_eq!(tap.sample(0.5), 0.5);
        drop(tap);
        assert!(call_level() < 0.0);
        assert_eq!(level_for_cm(), None);

        // In a call: the level is measured.
        set_call_mic(true);
        let mut tap = MicTap::new();
        assert_eq!(tap.sample(-0.6), -0.6);
        assert_eq!(tap.sample(0.2), 0.2);
        drop(tap);
        assert!((call_level() - 0.6).abs() < 0.01);
        assert_eq!(level_for_cm().as_deref(), Some("600"));

        // Microphone off: silence goes out, the level shows 0.
        assert!(conn_call_setting(CM_CALL_MUTED, Some("Y")));
        let mut tap = MicTap::new();
        assert_eq!(tap.sample(0.9), 0.0);
        drop(tap);
        assert_eq!(call_level(), 0.0);
        assert!(conn_call_setting(CM_CALL_MUTED, Some("N")));
        let mut tap = MicTap::new();
        assert_eq!(tap.sample(0.3), 0.3);
        drop(tap);

        // The Host card gets the level from its connection.
        assert!(host_from_conn(1, CM_CALL_LEVEL, Some("250")));
        assert!((call_level() - 0.25).abs() < 0.001);

        // The call ends: the microphone is open again for the next one, the level unknown.
        set_muted(true);
        set_call_mic(false);
        set_call_mic(true);
        let mut tap = MicTap::new();
        assert_eq!(tap.sample(0.4), 0.4);
        drop(tap);
        set_call_mic(false);
        assert!(call_level() < 0.0);

        // Sound output: a change is taken once by the playback.
        take_output_change();
        assert!(conn_call_setting(CM_CALL_OUTPUT, Some("Kulaklık")));
        assert!(take_output_change());
        assert!(!take_output_change());
        assert!(conn_call_setting(CM_CALL_OUTPUT, Some("Kulaklık")));
        assert!(!take_output_change(), "the same output again changes nothing");
        assert!(conn_call_setting(CM_CALL_OUTPUT, None));
        assert!(take_output_change());
        assert!(!conn_call_setting("voice-call-input", Some("x")));
    }

    #[test]
    fn sound_output_list() {
        let outs = vec!["Hoparlör".to_owned(), "Kulaklık".to_owned()];
        assert_eq!(
            parse(&sound_outputs_json(outs.clone(), "Kulaklık")),
            json!({ "outputs": ["Hoparlör", "Kulaklık"], "output": "Kulaklık" })
        );
        // A chosen output that is no longer connected shows as the default.
        assert_eq!(parse(&sound_outputs_json(outs.clone(), "USB"))["output"], "");
        assert!(output_choosable(&outs, ""));
        assert!(output_choosable(&outs, "Hoparlör"));
        assert!(!output_choosable(&outs, "USB"));
    }
}
