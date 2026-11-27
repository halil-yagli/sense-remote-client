// Sense Remote (#136, after #114): what the Controller-side recorder needs beyond the stock one.
//
// Root cause of "one recording, five pieces" (Slayer, v9, `Videos\SenseRemote`, 03:52:04–38):
// every time the Host rebuilt its encoder (ghost mode on/off, display switch, quality change)
// the new encoder's timestamps started again from zero; the stock recorder took the backwards
// timestamp as "a new file" (`Recorder::check_pts`). Both displays restarted together at
// 03:52:24 and 03:52:34, so each display's recording was cut in three. Here a backwards
// timestamp continues the same file instead: the output timestamp keeps growing by the real
// time that passed, and the first frame written after the jump is a key frame.
//
// It also counts the open recorders of a recording (so the "Kaydedildi" note comes after every
// file got its tail), finds the files a finished recording left, and reports, once per file,
// whether the recording really started.
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

/// What the UI hears from a display's recorder (`Recorder::sense_take_event`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SenseRecordEvent {
    /// A file was opened and its first frame went in. `part` is 1 for the display's first file,
    /// 2, 3 … when the picture size or codec changed mid-recording.
    Started {
        file: String,
        part: usize,
        codec: String,
        width: usize,
        height: usize,
    },
    /// The recording could not go on (`reason`: `klasor` folder could not be made, `dosya` the
    /// file / muxer could not be opened, `kodek` the codec cannot be recorded).
    Failed { reason: &'static str },
}

/// Output timestamp (ms) for a frame whose encoder timestamp went backwards: the last written
/// one plus the real time between the two frames (at least 1 ms, so it always grows). Returns the
/// offset to add to this and the following encoder timestamps.
pub fn continue_offset(last_out: i64, new_pts: i64, gap_ms: i64) -> i64 {
    last_out + gap_ms.max(1) - new_pts
}

/// Open recorders per recording folder; the recording is finished when it drops to zero.
static OPEN: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

pub(crate) fn opened(folder: &str) {
    let mut g = OPEN.lock().unwrap_or_else(|e| e.into_inner());
    *g.get_or_insert_with(HashMap::new)
        .entry(folder.to_owned())
        .or_insert(0) += 1;
}

pub(crate) fn closed(folder: &str) {
    let mut g = OPEN.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = g.as_mut() {
        if let Some(n) = m.get_mut(folder) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                m.remove(folder);
            }
        }
    }
}

/// Recorders of `folder` that have not written their file's tail yet.
pub fn open_recorders(folder: &str) -> usize {
    OPEN.lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .and_then(|m| m.get(folder).copied())
        .unwrap_or(0)
}

fn is_media(p: &Path) -> bool {
    p.is_file()
        && matches!(
            p.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(),
            Some("mp4") | Some("webm")
        )
}

/// The recording files in `dir`, in name order (`…_Ekran1.mp4`, `…_Ekran1_2.mp4`, `…_Ekran2.mp4`).
pub fn saved_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| is_media(p)).collect())
        .unwrap_or_default();
    files.sort();
    files
}

/// After a recording stopped (all its recorders closed): the files it left. A folder with no
/// recording in it (nothing reached the disk, or every piece was shorter than a second and was
/// removed) is deleted when it is empty, so no empty folder stays behind.
pub fn finish_folder(dir: &Path) -> Vec<PathBuf> {
    let files = saved_files(dir);
    if files.is_empty() {
        // `remove_dir` only removes an empty folder; anything else in it stays.
        std::fs::remove_dir(dir).ok();
    }
    files
}

// Tests: `src/sense/recording.rs` (the CI runs the main crate's tests only).
