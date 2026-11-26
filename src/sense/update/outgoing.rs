//! Sense Remote (B1, #77): an open Controller session (outgoing connection) of a macOS user
//! must keep the root updater from installing, also when that user has no `--server` (so no
//! main IPC listener to carry `ControllingSessionCount`, which `idle_ipc` counts as idle).
//!
//! The Flutter app of that user writes a small marker file; the root daemon reads it for the
//! sessions without a listener. The file is `<pid> <count>` in `/tmp` (the root daemon cannot
//! see the user's temp dir), named per uid. The reader trusts it only when it is a plain file
//! owned by that uid and the process is alive, so a stale file left by a crash never blocks
//! updates for ever. A forged file can only delay an update, never cause one.
//!
//! S9 P5 (#96): a living process is not enough (the pid can be reused, or the app hangs with
//! its session gone). The app rewrites the file every `controlling::REFRESH_S` while a session
//! is open, so its modification time says "still open"; a file older than `controlling::TTL_S`
//! is ignored like a dead process's.

use std::path::PathBuf;

/// Pure: where the marker of `uid` lives.
pub fn marker_path(uid: u32) -> PathBuf {
    PathBuf::from(format!("/tmp/.sense-remote-outgoing-{uid}"))
}

/// Pure: the marker's content.
pub fn render(pid: u32, count: usize) -> String {
    format!("{pid} {count}\n")
}

/// Pure: `(pid, count)` of a marker, `None` when it is malformed.
pub fn parse(content: &str) -> Option<(u32, usize)> {
    let mut parts = content.split_whitespace();
    let pid = parts.next()?.parse().ok()?;
    let count = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((pid, count))
}

/// Pure: does this marker content mean an open outgoing session of a living process?
pub fn is_active(content: &str, pid_alive: impl Fn(u32) -> bool) -> bool {
    match parse(content) {
        Some((pid, count)) => count > 0 && pid_alive(pid),
        None => false,
    }
}

/// Pure: is a marker last written `age_s` seconds ago still fresh?
pub fn fresh_enough(age_s: u64) -> bool {
    age_s < super::controlling::TTL_S as u64
}

/// The user's app: publish the current number of Controller sessions (`0` removes the marker).
#[cfg(unix)]
pub fn publish(count: usize) {
    use std::io::Write;
    let uid = unsafe { hbb_common::libc::getuid() };
    let path = marker_path(uid);
    if count == 0 {
        let _ = std::fs::remove_file(&path);
        return;
    }
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    let written = std::fs::File::create(&tmp)
        .and_then(|mut file| file.write_all(render(std::process::id(), count).as_bytes()))
        // `rename` replaces whatever is at `path` (also a planted link) instead of following it.
        .and_then(|()| std::fs::rename(&tmp, &path));
    if let Err(err) = written {
        let _ = std::fs::remove_file(&tmp);
        hbb_common::log::warn!("Sense Remote: outgoing-session marker not written: {err}");
    }
}

#[cfg(unix)]
fn pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let rc = unsafe { hbb_common::libc::kill(pid as hbb_common::libc::pid_t, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(hbb_common::libc::EPERM)
}

/// The root daemon: does `uid` have an open Controller session?
#[cfg(unix)]
pub fn uid_has_outgoing(uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    let path = marker_path(uid);
    let Ok(meta) = std::fs::symlink_metadata(&path) else {
        return false;
    };
    if !meta.is_file() || meta.uid() != uid || meta.len() > 64 {
        return false;
    }
    let age_s = meta
        .modified()
        .ok()
        .and_then(|t| std::time::SystemTime::now().duration_since(t).ok())
        .map_or(0, |d| d.as_secs());
    if !fresh_enough(age_s) {
        hbb_common::log::info!(
            "[sense-update] wait neden=outgoing_session_marker_stale uid={uid} age_s={age_s}; ignored"
        );
        return false;
    }
    std::fs::read_to_string(&path).is_ok_and(|content| is_active(&content, pid_alive))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_round_trips() {
        assert_eq!(parse(&render(4242, 2)), Some((4242, 2)));
        assert_eq!(marker_path(501), PathBuf::from("/tmp/.sense-remote-outgoing-501"));
    }

    #[test]
    fn malformed_markers_are_not_active() {
        for bad in ["", "12", "a 1", "12 b", "12 1 3", "-1 1"] {
            assert_eq!(parse(bad), None, "{bad:?}");
            assert!(!is_active(bad, |_| true), "{bad:?}");
        }
    }

    #[test]
    fn old_marker_is_not_fresh() {
        assert!(fresh_enough(0));
        assert!(fresh_enough(super::super::controlling::TTL_S as u64 - 1));
        assert!(!fresh_enough(super::super::controlling::TTL_S as u64));
        assert!(!fresh_enough(86_400));
    }

    #[test]
    fn active_needs_a_count_and_a_living_process() {
        assert!(is_active("10 1\n", |pid| pid == 10));
        assert!(!is_active("10 0\n", |_| true));
        assert!(!is_active("10 1\n", |_| false));
    }

    #[cfg(unix)]
    #[test]
    fn real_marker_on_disk() {
        let uid = unsafe { hbb_common::libc::getuid() };
        assert!(!uid_has_outgoing(uid) || marker_path(uid).exists());
        publish(1);
        assert!(uid_has_outgoing(uid));
        publish(0);
        assert!(!uid_has_outgoing(uid));
        // Another uid's marker is not ours.
        assert!(!uid_has_outgoing(uid.wrapping_add(1_000_003)));
    }

    #[cfg(unix)]
    #[test]
    fn dead_process_marker_is_ignored() {
        assert!(pid_alive(std::process::id()));
        assert!(!pid_alive(0));
    }
}
