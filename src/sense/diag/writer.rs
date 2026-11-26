//! Sense Remote (#103): the event file of this process. `sense-events/<process>.jsonl` in the
//! RustDesk log directory; it turns over at 1 MB and keeps three old files
//! (`<process>.1.jsonl` … `<process>.3.jsonl`). Lines go through a bounded queue to one writer
//! thread, so the caller never waits on the disk; a full queue drops the line (counted). The panic
//! hook writes directly ([`write_now`]): the process may end right after.

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{sync_channel, Receiver, SyncSender, TrySendError},
        Mutex,
    },
};

/// Directory of the event files, under the log directory of a profile.
pub const DIR: &str = "sense-events";
/// A file turns over at this size.
pub const MAX_FILE_BYTES: u64 = 1024 * 1024;
/// Old files kept next to the current one.
pub const KEEP_OLD: usize = 3;
const QUEUE: usize = 2048;

static SENDER: Mutex<Option<SyncSender<String>>> = Mutex::new(None);
/// Lines dropped because the queue was full (or the writer could not start).
pub static DROPPED: AtomicU64 = AtomicU64::new(0);

/// The event directory of this process's profile.
pub fn events_dir() -> PathBuf {
    hbb_common::config::Config::log_path().join(DIR)
}

pub fn file_path(dir: &Path, process: &str) -> PathBuf {
    dir.join(format!("{process}.jsonl"))
}

pub fn old_path(dir: &Path, process: &str, n: usize) -> PathBuf {
    dir.join(format!("{process}.{n}.jsonl"))
}

/// Starts the writer thread of `process` (once per process).
pub fn start(process: &str) {
    let mut guard = SENDER.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return;
    }
    let (tx, rx) = sync_channel::<String>(QUEUE);
    let dir = events_dir();
    let process = process.to_owned();
    let started = std::thread::Builder::new()
        .name("sense-diag-writer".to_owned())
        .spawn(move || run(rx, &dir, &process));
    match started {
        Ok(_) => *guard = Some(tx),
        Err(err) => hbb_common::log::warn!("Sense Remote: event writer not started: {err}"),
    }
}

/// Queues a finished line. Never blocks.
pub fn push(line: String) {
    let guard = SENDER.lock().unwrap_or_else(|e| e.into_inner());
    let Some(tx) = guard.as_ref() else {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    };
    match tx.try_send(line) {
        Ok(()) => {}
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn run(rx: Receiver<String>, dir: &Path, process: &str) {
    let mut file: Option<(fs::File, u64)> = None;
    while let Ok(line) = rx.recv() {
        if file.is_none() {
            file = open(dir, process);
        }
        let Some((handle, size)) = file.as_mut() else {
            continue;
        };
        let mut bytes = line.into_bytes();
        bytes.push(b'\n');
        if handle.write_all(&bytes).is_ok() {
            *size += bytes.len() as u64;
        }
        if *size >= MAX_FILE_BYTES {
            // Closed before the rename (Windows cannot rename a file this process holds open
            // without sharing; std opens with sharing, but closing first is simplest).
            file = None;
            rotate(dir, process);
        }
    }
}

fn open(dir: &Path, process: &str) -> Option<(fs::File, u64)> {
    fs::create_dir_all(dir).ok()?;
    let path = file_path(dir, process);
    let handle = fs::OpenOptions::new().create(true).append(true).open(&path).ok()?;
    let size = handle.metadata().map(|m| m.len()).unwrap_or(0);
    Some((handle, size))
}

/// `<p>.jsonl` -> `<p>.1.jsonl` -> … -> `<p>.KEEP_OLD.jsonl` (the oldest goes).
pub fn rotate(dir: &Path, process: &str) {
    let _ = fs::remove_file(old_path(dir, process, KEEP_OLD));
    for n in (1..KEEP_OLD).rev() {
        let _ = fs::rename(old_path(dir, process, n), old_path(dir, process, n + 1));
    }
    let _ = fs::rename(file_path(dir, process), old_path(dir, process, 1));
}

/// Appends one line now (panic hook): its own handle, no lock, no queue.
pub fn append_now(dir: &Path, process: &str, line: &str) -> bool {
    if fs::create_dir_all(dir).is_err() {
        return false;
    }
    let Ok(mut handle) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file_path(dir, process))
    else {
        return false;
    };
    let mut bytes = line.as_bytes().to_vec();
    bytes.push(b'\n');
    handle.write_all(&bytes).is_ok()
}

/// [`append_now`] in this process's event directory.
pub fn write_now(process: &str, line: &str) -> bool {
    append_now(&events_dir(), process, line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sense-diag-writer-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rotation_keeps_three_old_files() {
        let dir = temp_dir("rotate");
        for round in 0..5 {
            assert!(append_now(&dir, "server", &format!("satir {round}")));
            rotate(&dir, "server");
        }
        assert!(!file_path(&dir, "server").exists());
        assert_eq!(fs::read_to_string(old_path(&dir, "server", 1)).unwrap(), "satir 4\n");
        assert_eq!(fs::read_to_string(old_path(&dir, "server", 2)).unwrap(), "satir 3\n");
        assert_eq!(fs::read_to_string(old_path(&dir, "server", 3)).unwrap(), "satir 2\n");
        assert!(!old_path(&dir, "server", 4).exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_thread_appends_and_turns_over() {
        let dir = temp_dir("run");
        let (tx, rx) = sync_channel::<String>(16);
        let d = dir.clone();
        let handle = std::thread::spawn(move || run(rx, &d, "client"));
        let line = "x".repeat(4000);
        // Enough lines to pass 1 MB once.
        for _ in 0..(MAX_FILE_BYTES as usize / 4001 + 10) {
            tx.send(line.clone()).unwrap();
        }
        drop(tx);
        handle.join().unwrap();
        let old = fs::metadata(old_path(&dir, "client", 1)).unwrap().len();
        assert!(old >= MAX_FILE_BYTES && old < MAX_FILE_BYTES + 4001, "{old}");
        let cur = fs::read_to_string(file_path(&dir, "client")).unwrap();
        assert!(cur.lines().all(|l| l.len() == 4000));
        assert!(cur.lines().count() >= 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
