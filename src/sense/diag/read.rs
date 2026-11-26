//! Sense Remote (#103): the event lines of a time window, for an upload (`--server`). Every event
//! file of every profile the `--server` reads (current and turned-over files) is read, each line
//! is checked and cleaned again (`line::clean_event_line`), lines of the window are merged in
//! time order into one file, `sense-events.jsonl` (contract §1). A window is `[from, to)` in Unix
//! ms: consecutive chunks of a session neither lose nor repeat a line.

use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// File name of the merged events in an upload.
pub const UPLOAD_NAME: &str = "sense-events.jsonl";
/// A file is read up to this many bytes (a little over the turn-over size).
const MAX_READ: u64 = super::writer::MAX_FILE_BYTES + 64 * 1024;
/// Event files read per directory at most (processes x (1 + old files)).
const MAX_FILES_PER_DIR: usize = 64;

/// The lines of `texts` whose time is in `[from_ms, to_ms)`, cleaned, in time order (stable for
/// equal times).
pub fn select_lines<'a>(texts: impl IntoIterator<Item = &'a str>, from_ms: i64, to_ms: i64) -> Vec<(i64, String)> {
    let mut lines: Vec<(i64, String)> = texts
        .into_iter()
        .flat_map(|text| text.lines())
        .filter_map(super::line::clean_event_line)
        .filter(|(t, _)| *t >= from_ms && *t < to_ms)
        .collect();
    lines.sort_by_key(|(t, _)| *t);
    lines
}

/// Joined with `\n`, at most `budget` bytes: the newest lines are kept when not all fit.
pub fn join_fit(lines: &[(i64, String)], budget: usize) -> String {
    let mut used = 0usize;
    let mut start = lines.len();
    while start > 0 {
        let len = lines[start - 1].1.len() + 1;
        if used + len > budget {
            break;
        }
        used += len;
        start -= 1;
    }
    let mut out = String::with_capacity(used);
    for (_, line) in &lines[start..] {
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Event files of `dir` that may hold lines at or after `from_ms` (written since then).
fn event_files(dir: &Path, from_ms: i64) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if !crate::sense::log_upload::is_plain_dir(dir) {
        return out;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return out;
    };
    let from = UNIX_EPOCH + Duration::from_millis(from_ms.max(0) as u64);
    for entry in entries.flatten() {
        if out.len() >= MAX_FILES_PER_DIR {
            break;
        }
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() || crate::sense::log_upload::is_link(&meta) {
            continue;
        }
        // A file last written before the window holds nothing of it (a minute of slack for
        // clocks and the writer's queue).
        let fresh = meta
            .modified()
            .map(|m| m + Duration::from_secs(60) >= from)
            .unwrap_or(true);
        if fresh {
            out.push(path);
        }
    }
    out
}

fn read_text(path: &Path) -> Option<String> {
    let file = fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take(MAX_READ).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// The merged event text of `[from_ms, to_ms)` from `dirs`, at most `budget` bytes; `None` when
/// there is no line.
pub fn collect(dirs: &[PathBuf], from_ms: i64, to_ms: i64, budget: usize) -> Option<String> {
    let texts: Vec<String> = dirs
        .iter()
        .flat_map(|dir| event_files(dir, from_ms))
        .filter_map(|path| read_text(&path))
        .collect();
    let lines = select_lines(texts.iter().map(String::as_str), from_ms, to_ms);
    let text = join_fit(&lines, budget);
    (!text.is_empty()).then_some(text)
}

/// Unix ms of `time`.
pub fn unix_ms(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::diag::line::build_line;
    use serde_json::json;

    fn ev(t: i64, k: &str) -> String {
        build_line(t, "conn", k, "client", None, &json!({"ms": t})).unwrap()
    }

    #[test]
    fn a_window_takes_its_lines_in_time_order() {
        let a = format!("{}\n{}\n{}\n", ev(30, "c"), ev(10, "a"), ev(50, "e"));
        let b = format!("{}\nbozuk satir\n{}\n", ev(20, "b"), ev(40, "d"));
        let lines = select_lines([a.as_str(), b.as_str()], 10, 50);
        let ts: Vec<i64> = lines.iter().map(|(t, _)| *t).collect();
        assert_eq!(ts, vec![10, 20, 30, 40]);
    }

    #[test]
    fn chunks_split_a_session_without_loss_or_repeat() {
        let text: String = (0..1000).map(|t| ev(t * 7, "rtt") + "\n").collect();
        let cuts = [0i64, 1234, 2500, 2501, 5000, 7000];
        let mut seen = Vec::new();
        for pair in cuts.windows(2) {
            seen.extend(select_lines([text.as_str()], pair[0], pair[1]).into_iter().map(|(t, _)| t));
        }
        let all: Vec<i64> = (0..1000).map(|t| t * 7).collect();
        assert_eq!(seen, all);
    }

    #[test]
    fn the_newest_lines_are_kept_within_the_budget() {
        // Two-digit times: every line has the same length.
        let lines: Vec<(i64, String)> = (10..100).map(|t| (t, ev(t, "rtt"))).collect();
        let one = lines[0].1.len() + 1;
        let text = join_fit(&lines, one * 10 + 3);
        assert_eq!(text.lines().count(), 10);
        assert!(text.len() <= one * 10 + 3);
        assert!(text.ends_with(&format!("{}\n", lines[89].1)));
        assert_eq!(join_fit(&lines, 5), "");
        assert_eq!(join_fit(&lines, usize::MAX).lines().count(), 90);
    }

    #[test]
    fn collect_reads_every_event_file_of_every_directory() {
        let base = std::env::temp_dir().join(format!("sense-diag-read-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let (one, two) = (base.join("bir"), base.join("iki"));
        fs::create_dir_all(&one).unwrap();
        fs::create_dir_all(&two).unwrap();
        let now = unix_ms(SystemTime::now());
        fs::write(one.join("server.jsonl"), format!("{}\n", ev(now - 1000, "a"))).unwrap();
        fs::write(one.join("server.1.jsonl"), format!("{}\n", ev(now - 2000, "b"))).unwrap();
        fs::write(two.join("client.jsonl"), format!("{}\n{}\n", ev(now - 1500, "c"), ev(now + 5000, "later"))).unwrap();
        fs::write(two.join("server.log"), format!("{}\n", ev(now - 1200, "not-an-event-file"))).unwrap();
        let text = collect(&[one.clone(), two.clone(), base.join("yok")], now - 10_000, now, 1 << 20).unwrap();
        let kinds: Vec<String> = text
            .lines()
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()["k"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(kinds, vec!["b", "c", "a"]);
        assert!(collect(&[one, two], now + 60_000, now + 70_000, 1 << 20).is_none());
        let _ = fs::remove_dir_all(&base);
    }
}
