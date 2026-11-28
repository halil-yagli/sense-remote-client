//! Sense Remote (Sürüm 12, FAV-Ç): running a shortcut on a Mac Host.
//!
//! Everything opens with `/usr/bin/open` as the console user: directly when this process is that
//! user, through `launchctl asuser <uid> sudo -u <user>` when it runs as root. No shell; the
//! arguments are the catalogue's fixed ones or an approved custom target.

use super::results::{self, Window};
use super::RunError;
use hbb_common::log;
use serde_json::Value;

const OPEN: &str = "/usr/bin/open";

fn user_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn open(args: &[&str]) -> Result<(), RunError> {
    let result = if crate::platform::macos::is_root() {
        let uid = crate::platform::macos::get_active_userid();
        let user = crate::platform::macos::get_active_username();
        if uid.is_empty() || !uid.bytes().all(|b| b.is_ascii_digit()) || !user_ok(&user) {
            log::warn!("Sense Remote: shortcut: no console user");
            return Err(RunError::Failed);
        }
        std::process::Command::new("/bin/launchctl")
            .args(["asuser", uid.as_str(), "/usr/bin/sudo", "-u", user.as_str(), OPEN])
            .args(args)
            .spawn()
    } else {
        std::process::Command::new(OPEN).args(args).spawn()
    };
    result.map(|_| ()).map_err(|err| {
        log::warn!("Sense Remote: shortcut did not start: {err}");
        RunError::Failed
    })
}

pub fn run_open(args: &[&str]) -> Result<(), RunError> {
    open(args)
}

/// `open ~/<sub>` of the console user.
pub fn open_home(sub: &str) -> Result<(), RunError> {
    let user = crate::platform::macos::get_active_username();
    if !user_ok(&user) {
        return Err(RunError::Failed);
    }
    let path = format!("/Users/{user}/{sub}");
    open(&[path.as_str()])
}

/// An approved custom shortcut (program, folder or https address).
pub fn open_target(target: &str) -> Result<(), RunError> {
    open(&[target])
}

/// `ping -c 4 -W 1000 -t 8 <target>`; the result body.
pub fn ping(target: &str) -> Result<Value, RunError> {
    let out = std::process::Command::new("/sbin/ping")
        .args(["-c", &results::PING_COUNT.to_string(), "-W", "1000", "-t", "8", target])
        .output()
        .map_err(|err| {
            log::warn!("Sense Remote: ping did not start: {err}");
            RunError::Failed
        })?;
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(results::parse_ping(&text, results::PING_COUNT).to_res())
}

/// Apps of the console user (`ps -axo pid=,uid=,comm=`; see [`super::results`] for the rest).
pub fn windows() -> Vec<Window> {
    let uid: u32 = crate::platform::macos::get_active_userid()
        .parse()
        .unwrap_or(u32::MAX);
    match std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,uid=,comm="])
        .output()
    {
        Ok(out) => super::mac_apps(&String::from_utf8_lossy(&out.stdout), uid),
        Err(err) => {
            log::warn!("Sense Remote: app list not read: {err}");
            Vec::new()
        }
    }
}

/// Force quit (SIGKILL) app `pid` (it was in the list a moment ago; checked by the caller).
pub fn close(pid: u32) -> Result<(), RunError> {
    let pid = i32::try_from(pid).map_err(|_| RunError::Failed)?;
    if unsafe { hbb_common::libc::kill(pid, hbb_common::libc::SIGKILL) } == 0 {
        Ok(())
    } else {
        Err(RunError::Failed)
    }
}
