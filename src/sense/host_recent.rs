//! Sense Remote (Sürüm 4, H2 "Son bağlantılar"; plan 2026-11-23 "Ek", #70): the Host's last
//! incoming connections — who, when, how long, how many screens.
//!
//! Kept by the `--server` process (the one that takes the connections) in a short list on this
//! computer: at most [`MAX`] entries, newest first, in the service's config directory
//! ([`FILE`]). Only the Controller's display name, start time, length and the most screens it
//! watched at once; no id, address, password or file name. The UI reads it over the main IPC
//! (`identity_set::SenseIdentityIpc::RecentQuery`, the service's own pipe on Windows).
//!
//! Recording: the connection calls [`started`] once it is authorized, [`screens`] when the
//! screens it watches change and [`ended`] when it closes. Those call points belong in
//! `src/server/connection.rs` (D3d1's file in Sürüm 4; added after it is merged).

use hbb_common::{config::Config, log};
use serde_derive::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Mutex, MutexGuard},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

/// Most entries kept.
pub const MAX: usize = 20;
/// File name in the `--server` process's config directory.
pub const FILE: &str = "sense_recent.json";
/// Longest name kept (the panel's name limit).
const MAX_NAME_CHARS: usize = 64;

/// One finished connection, as `main_sense_host_recent_conns` gives it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    /// Start, Unix seconds.
    pub at: i64,
    pub seconds: i64,
    pub screens: u32,
}

struct Open {
    name: String,
    at: i64,
    started: Instant,
    screens: u32,
}

static OPEN: Mutex<Option<HashMap<i32, Open>>> = Mutex::new(None);
/// The list, read from the file on first use.
static LIST: Mutex<Option<Vec<Entry>>> = Mutex::new(None);

// ---------------------------------------------------------------------------------------------
// Pure part
// ---------------------------------------------------------------------------------------------

/// Trimmed, control characters dropped, at most 64 characters.
fn clean_name(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_NAME_CHARS)
        .collect()
}

/// Adds `entry` in front and keeps the newest [`MAX`].
pub fn push(list: &mut Vec<Entry>, entry: Entry) {
    list.insert(0, entry);
    list.sort_by(|a, b| b.at.cmp(&a.at));
    list.truncate(MAX);
}

/// The stored list; anything unreadable counts as empty, broken entries are dropped.
pub fn parse(text: &str) -> Vec<Entry> {
    let mut list: Vec<Entry> = serde_json::from_str::<Vec<serde_json::Value>>(text)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| serde_json::from_value::<Entry>(item).ok())
        .filter(|entry| entry.at > 0 && entry.seconds >= 0)
        .map(|mut entry| {
            entry.name = clean_name(&entry.name);
            entry
        })
        .collect();
    list.sort_by(|a, b| b.at.cmp(&a.at));
    list.truncate(MAX);
    list
}

fn to_json(list: &[Entry]) -> String {
    serde_json::to_string(list).unwrap_or_else(|_| "[]".to_owned())
}

fn now_s() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------------------------
// `--server` process
// ---------------------------------------------------------------------------------------------

/// Sense Remote (B6): a lock a panicking thread poisoned is still taken; the list is plain data and a
/// connection must not panic because of another one.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn with_list<R>(f: impl FnOnce(&mut Vec<Entry>) -> R) -> R {
    let mut list = locked(&LIST);
    let list = list.get_or_insert_with(|| {
        std::fs::read_to_string(Config::path(FILE))
            .map(|text| parse(&text))
            .unwrap_or_default()
    });
    f(list)
}

/// A connection was authorized. `name` is the Controller's display name.
pub fn started(conn_id: i32, name: &str) {
    let open = Open {
        name: clean_name(name),
        at: now_s(),
        started: Instant::now(),
        screens: 0,
    };
    locked(&OPEN)
        .get_or_insert_with(HashMap::new)
        .insert(conn_id, open);
}

/// The connection now watches `count` screens; the most it watched at once is kept.
pub fn screens(conn_id: i32, count: usize) {
    if let Some(open) = locked(&OPEN)
        .get_or_insert_with(HashMap::new)
        .get_mut(&conn_id)
    {
        open.screens = open.screens.max(count.min(u32::MAX as usize) as u32);
    }
}

/// The connection closed: it goes into the list (and the file).
pub fn ended(conn_id: i32) {
    let Some(open) = locked(&OPEN)
        .get_or_insert_with(HashMap::new)
        .remove(&conn_id)
    else {
        return;
    };
    let entry = Entry {
        name: open.name,
        at: open.at,
        seconds: open.started.elapsed().as_secs() as i64,
        screens: open.screens,
    };
    with_list(|list| push(list, entry));
    // Sense Remote (B6): not on the connection's task (a slow disk would hold its loop).
    if let Err(err) = std::thread::Builder::new()
        .name("sense-recent".to_owned())
        .spawn(persist)
    {
        log::warn!("Sense Remote: recent connections not stored: {err}");
    }
}

static WRITE: Mutex<()> = Mutex::new(());

/// Writes the current list. One writer at a time, each writes the latest list, so a slow older
/// write can never leave an older list behind.
fn persist() {
    let _one = locked(&WRITE);
    let text = with_list(|list| to_json(list));
    if let Err(err) = write_atomic(&Config::path(FILE), &text) {
        log::warn!("Sense Remote: recent connections not stored: {err}");
    }
}

/// Temporary file, then rename: a crash leaves the old file or the new one, never half of one.
fn write_atomic(path: &std::path::Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path).map_err(|err| {
        let _ = std::fs::remove_file(&tmp);
        err
    })
}

/// `main_sense_host_recent_conns`: `[{name, at, seconds, screens}]`, newest first.
pub fn list_json() -> String {
    with_list(|list| to_json(list))
}

/// FFI (UI process): asks the `--server` process.
pub fn ffi_host_recent_conns() -> String {
    super::identity_set::ffi_host_recent_conns()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, at: i64) -> Entry {
        Entry {
            name: name.to_owned(),
            at,
            seconds: 60,
            screens: 2,
        }
    }

    #[test]
    fn keeps_the_newest_twenty() {
        let mut list = Vec::new();
        for at in 1..=25 {
            push(&mut list, entry("Ayşe", at));
        }
        assert_eq!(list.len(), MAX);
        assert_eq!(list.first().unwrap().at, 25);
        assert_eq!(list.last().unwrap().at, 6);
    }

    #[test]
    fn json_shape_matches_the_bridge() {
        let json: serde_json::Value =
            serde_json::from_str(&to_json(&[entry("Ayşe Y.", 1_795_000_000)])).unwrap();
        assert_eq!(
            json,
            serde_json::json!([{ "name": "Ayşe Y.", "at": 1_795_000_000, "seconds": 60, "screens": 2 }])
        );
        assert_eq!(to_json(&[]), "[]");
    }

    #[test]
    fn stored_file_is_checked() {
        assert_eq!(parse(""), vec![]);
        assert_eq!(parse("{}"), vec![]);
        let text = r#"[
            {"name":"A","at":10,"seconds":5,"screens":1},
            {"name":"B","at":0,"seconds":5,"screens":1},
            {"name":"C","at":30,"seconds":-1,"screens":1},
            {"name":"D","at":"x","seconds":5,"screens":1},
            {"name":" E\n","at":20,"seconds":5,"screens":3}
        ]"#;
        assert_eq!(
            parse(text),
            vec![
                Entry { name: "E".to_owned(), at: 20, seconds: 5, screens: 3 },
                Entry { name: "A".to_owned(), at: 10, seconds: 5, screens: 1 },
            ]
        );
    }

    #[test]
    fn poisoned_lock_is_still_usable() {
        let mutex = std::sync::Arc::new(Mutex::new(5));
        let m = mutex.clone();
        let _ = std::thread::spawn(move || {
            let _guard = m.lock().unwrap();
            panic!("poison it");
        })
        .join();
        assert!(mutex.is_poisoned());
        assert_eq!(*locked(&mutex), 5);
    }

    #[test]
    fn write_replaces_the_file_whole() {
        let dir = std::env::temp_dir().join(format!("sense-recent-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(FILE);
        write_atomic(&path, "[1]").unwrap();
        write_atomic(&path, "[2]").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "[2]");
        assert!(!path.with_extension("json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_are_cleaned() {
        assert_eq!(clean_name("  Ayşe\tY. "), "AyşeY.");
        assert_eq!(clean_name(&"ş".repeat(70)).chars().count(), MAX_NAME_CHARS);
    }

    #[test]
    fn open_connection_keeps_the_most_screens() {
        // Only the in-memory part (no `ended`, which writes the file).
        started(-7, " Ayşe ");
        screens(-7, 2);
        screens(-7, 1);
        screens(-8, 4); // unknown connection: nothing
        let open = OPEN.lock().unwrap();
        let open = open.as_ref().unwrap().get(&-7).unwrap();
        assert_eq!((open.name.as_str(), open.screens), ("Ayşe", 2));
    }
}
