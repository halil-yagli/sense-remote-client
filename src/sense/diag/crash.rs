//! Sense Remote (#103, contract §2 `crash`): how the `--server` knows, at its next start, that the
//! previous run did not end well, and what it then sends.
//!
//! 1. **Panic flag** — the panic hook of any process writes `sense-events/<process>.panic`
//!    (`{"t", "p", "s"}`). The `--server` reads the flags of every profile it reads logs from and
//!    sends the events before the newest one it has not handled yet (handled time kept in the
//!    local config, so nothing is written into a user's folder).
//! 2. **Open session** — while a connection's record is open the `--server` keeps
//!    `sense-events/acik/<key>.json` in its own profile (who, since when, where its chunks stopped).
//!    A marker found at start means the run ended with a connection open (crash, power loss, a
//!    killed service): that connection's remaining record goes with the same session id.
//!
//! Paths inside a marker are only used as keys to compare with what the `--server` lists itself;
//! nothing read here is opened as a path.

use serde_derive::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};

/// Sub-directory of the open-session markers.
const OPEN_DIR: &str = "acik";
/// At most this many markers are read at start (one crash send each, the hour limit decides).
const MAX_OPEN: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanicFlag {
    pub t: i64,
    pub p: String,
    #[serde(default)]
    pub s: Option<String>,
}

pub fn flag_path(dir: &Path, process: &str) -> PathBuf {
    dir.join(format!("{process}.panic"))
}

/// Panic hook: overwrites the flag of this process. Best effort.
pub fn write_panic_flag(dir: &Path, t: i64, process: &str, session: Option<&str>) {
    let flag = PanicFlag {
        t,
        p: process.to_owned(),
        s: session.map(str::to_owned),
    };
    if let Ok(text) = serde_json::to_string(&flag) {
        let _ = fs::create_dir_all(dir);
        let _ = fs::write(flag_path(dir, process), text);
    }
}

/// A flag file's text; `None` when it is not one (or names something odd).
pub fn parse_flag(text: &str) -> Option<PanicFlag> {
    if text.len() > 1024 {
        return None;
    }
    let flag: PanicFlag = serde_json::from_str(text.trim()).ok()?;
    let ok = flag.t > 0
        && super::line::is_process(&flag.p)
        && flag.s.as_deref().map_or(true, super::line::is_session);
    ok.then_some(flag)
}

/// The newest flag newer than `seen` among `flags` (pure).
pub fn newest_unseen(flags: &[PanicFlag], seen: i64) -> Option<PanicFlag> {
    flags
        .iter()
        .filter(|f| f.t > seen)
        .max_by_key(|f| f.t)
        .cloned()
}

/// Every flag in `dir` (plain files only; links are not followed).
pub fn read_flags(dir: &Path) -> Vec<PanicFlag> {
    let mut out = Vec::new();
    if !crate::sense::log_upload::is_plain_dir(dir) {
        return out;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten().take(64) {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("panic") {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() || crate::sense::log_upload::is_link(&meta) || meta.len() > 1024 {
            continue;
        }
        if let Some(flag) = fs::read_to_string(&path).ok().as_deref().and_then(parse_flag) {
            out.push(flag);
        }
    }
    out
}

/// What the `--server` keeps about an open connection record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenSession {
    /// The session id sent to the panel (`session_id`).
    pub sid: String,
    pub peer: Option<String>,
    pub started_s: i64,
    pub role: Option<String>,
    /// Events before this (Unix ms) were already sent in a chunk.
    pub cut_ms: i64,
    /// Log file positions after the last chunk (`path -> length`).
    #[serde(default)]
    pub offsets: HashMap<String, u64>,
}

fn open_path(dir: &Path, sid: &str) -> Option<PathBuf> {
    super::line::is_session(sid).then(|| dir.join(OPEN_DIR).join(format!("{sid}.json")))
}

pub fn write_open(dir: &Path, session: &OpenSession) {
    let Some(path) = open_path(dir, &session.sid) else {
        return;
    };
    let _ = fs::create_dir_all(dir.join(OPEN_DIR));
    if let Ok(text) = serde_json::to_string(session) {
        let _ = fs::write(path, text);
    }
}

pub fn remove_open(dir: &Path, sid: &str) {
    if let Some(path) = open_path(dir, sid) {
        let _ = fs::remove_file(path);
    }
}

/// Reads and removes the markers left by the previous run (newest first, at most [`MAX_OPEN`];
/// the rest are removed unread).
pub fn take_open(dir: &Path) -> Vec<OpenSession> {
    let open = dir.join(OPEN_DIR);
    let mut out = Vec::new();
    if !crate::sense::log_upload::is_plain_dir(&open) {
        return out;
    }
    let Ok(entries) = fs::read_dir(&open) else {
        return out;
    };
    for entry in entries.flatten().take(256) {
        let path = entry.path();
        let ok_meta = fs::symlink_metadata(&path)
            .map(|m| m.is_file() && !crate::sense::log_upload::is_link(&m) && m.len() <= 256 * 1024)
            .unwrap_or(false);
        let session = ok_meta
            .then(|| fs::read_to_string(&path).ok())
            .flatten()
            .and_then(|text| serde_json::from_str::<OpenSession>(&text).ok())
            .filter(|s| super::line::is_session(&s.sid) && s.started_s > 0);
        let _ = fs::remove_file(&path);
        if let Some(session) = session {
            out.push(session);
        }
    }
    out.sort_by(|a, b| b.started_s.cmp(&a.started_s));
    out.truncate(MAX_OPEN);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sense-diag-crash-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn panic_flags_round_trip_and_the_newest_unseen_wins() {
        let dir = temp_dir("flags");
        write_panic_flag(&dir, 1000, "server", Some("h1-2"));
        write_panic_flag(&dir, 3000, "client", None);
        fs::write(dir.join("bozuk.panic"), "not json").unwrap();
        fs::write(dir.join("server.jsonl"), "{}").unwrap();
        let flags = read_flags(&dir);
        assert_eq!(flags.len(), 2);
        assert_eq!(newest_unseen(&flags, 0).unwrap().p, "client");
        assert_eq!(newest_unseen(&flags, 2000).unwrap().t, 3000);
        assert!(newest_unseen(&flags, 3000).is_none());
        let server = flags.iter().find(|f| f.p == "server").unwrap();
        assert_eq!(server.s.as_deref(), Some("h1-2"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn odd_flags_are_refused() {
        assert!(parse_flag(r#"{"t":5,"p":"server"}"#).is_some());
        assert!(parse_flag(r#"{"t":0,"p":"server"}"#).is_none());
        assert!(parse_flag(r#"{"t":5,"p":"../x"}"#).is_none());
        assert!(parse_flag(r#"{"t":5,"p":"server","s":"a b"}"#).is_none());
        assert!(parse_flag(&"x".repeat(2000)).is_none());
    }

    #[test]
    fn open_markers_are_taken_once() {
        let dir = temp_dir("open");
        let mut a = OpenSession {
            sid: "h1764150000-1".to_owned(),
            peer: Some("123456789".to_owned()),
            started_s: 1_764_150_000,
            cut_ms: 1_764_150_300_000,
            ..Default::default()
        };
        a.offsets.insert("server.log".to_owned(), 42);
        write_open(&dir, &a);
        let b = OpenSession {
            sid: "c1764150100-0".to_owned(),
            started_s: 1_764_150_100,
            ..Default::default()
        };
        write_open(&dir, &b);
        remove_open(&dir, &b.sid);
        // A bad id never becomes a path.
        write_open(&dir, &OpenSession { sid: "../../x".to_owned(), started_s: 1, ..Default::default() });
        let taken = take_open(&dir);
        assert_eq!(taken, vec![a]);
        assert!(take_open(&dir).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }
}
