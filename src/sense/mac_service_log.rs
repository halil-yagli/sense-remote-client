//! Sense Remote (Sürüm 11, tarama-mac M17): the root daemon's stdout / stderr files.
//!
//! launchd writes them (`daemon.plist`: `StandardOutPath`, `StandardErrorPath` under
//! `/var/log`) and nothing rotates them; on a Host that stays on for months they only grow. The
//! daemon's own log (hbb_common, rotated) is elsewhere; these files only get what is printed
//! (panics, `eprintln!`). The daemon keeps the last [`KEEP_BYTES`] of a file that grew over
//! [`MAX_BYTES`]: at start and once a day ([`start`]).
//!
//! launchd opens the files with `O_APPEND`, so after the cut its writes go to the new end.

use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
};

/// A file larger than this is cut.
pub const MAX_BYTES: u64 = 10 * 1024 * 1024;
/// What stays of it: the newest part.
pub const KEEP_BYTES: u64 = 1024 * 1024;

/// Pure: where the kept part starts in a file of `len` bytes whose last `keep` bytes are `tail`
/// (offset into `tail`): after the first line break, so no half line stays at the top. A tail
/// without a line break is kept whole.
pub fn cut_offset(tail: &[u8]) -> usize {
    match tail.iter().position(|&b| b == b'\n') {
        Some(at) if at + 1 < tail.len() => at + 1,
        _ => 0,
    }
}

/// Keeps the newest `keep` bytes of `path` (from a line start) when it is larger than `max`.
/// `Ok(true)` when cut. A symlink or anything but a regular file is left alone.
pub fn trim(path: &Path, max: u64, keep: u64) -> io::Result<bool> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_file() || meta.len() <= max {
        return Ok(false);
    }
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    let len = file.metadata()?.len();
    let keep = keep.min(len);
    file.seek(SeekFrom::Start(len - keep))?;
    let mut tail = Vec::with_capacity(keep as usize);
    Read::take(&mut file, keep).read_to_end(&mut tail)?;
    let tail = &tail[cut_offset(&tail)..];
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    file.write_all(tail)?;
    file.flush()?;
    Ok(true)
}

/// Cuts `paths` now and once a day in a background thread; returns at once. Errors (a file
/// that does not exist yet) are not reported more than once per file.
pub fn start(paths: Vec<String>) {
    let run = move || loop {
        for path in &paths {
            match trim(Path::new(path), MAX_BYTES, KEEP_BYTES) {
                Ok(true) => hbb_common::log::info!("Sense Remote: service log cut: {path}"),
                Ok(false) => {}
                Err(err) if err.kind() == io::ErrorKind::NotFound => {}
                Err(err) => hbb_common::log::warn!("Sense Remote: service log not cut: {path}: {err}"),
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(24 * 3600));
    };
    if let Err(err) = std::thread::Builder::new()
        .name("sense-service-log".to_owned())
        .spawn(run)
    {
        hbb_common::log::warn!("Sense Remote: service log trimming not started: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cut_starts_after_the_first_line_break() {
        assert_eq!(cut_offset(b"lf line\nnext\n"), 8);
        assert_eq!(cut_offset(b"\nnext"), 1);
        // No line break, or only at the very end: kept whole.
        assert_eq!(cut_offset(b"one long line"), 0);
        assert_eq!(cut_offset(b"only end\n"), 0);
        assert_eq!(cut_offset(b""), 0);
    }

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sense-service-log-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn large_file_keeps_its_newest_whole_lines() {
        let dir = temp("large");
        let path = dir.join("service.err");
        let mut body = String::new();
        for i in 0..200 {
            body.push_str(&format!("line {i:04}\n"));
        }
        fs::write(&path, &body).unwrap();
        // 200 lines of 10 bytes; keep 95 bytes = a half line + 9 whole lines.
        assert!(trim(&path, 1000, 95).unwrap());
        let kept = fs::read_to_string(&path).unwrap();
        assert!(kept.starts_with("line 0191\n"), "{kept}");
        assert!(kept.ends_with("line 0199\n"));
        assert_eq!(kept.lines().count(), 9);
        // Appending after the cut continues at the end.
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(b"after\n").unwrap();
        assert!(fs::read_to_string(&path).unwrap().ends_with("line 0199\nafter\n"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn small_missing_and_linked_files_are_left_alone() {
        let dir = temp("small");
        let path = dir.join("service.out");
        fs::write(&path, "short\n").unwrap();
        assert!(!trim(&path, 1000, 10).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), "short\n");
        assert_eq!(
            trim(&dir.join("none"), 0, 0).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        #[cfg(unix)]
        {
            let big = dir.join("big");
            fs::write(&big, vec![b'x'; 4000]).unwrap();
            let link = dir.join("link");
            std::os::unix::fs::symlink(&big, &link).unwrap();
            assert!(!trim(&link, 10, 5).unwrap());
            assert_eq!(fs::metadata(&big).unwrap().len(), 4000);
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
