//! Sense Remote (Sürüm 12, plan 2026-11-28 §2.1, §2.3; #160–#163, #171): favourite shortcuts
//! ("Sık kullanılanlar") on the Host.
//!
//! - [`catalog`]: the built-in catalogue, compiled in (same ids as the Controller's list);
//! - [`custom`]: approved custom shortcuts, only from the signed envelope (`sense_shortcuts`);
//! - [`results`]: the optional result body (`res`) of ping, window list and IP card (#171);
//! - `run_win` / `run_mac`: starting things as the signed-in user.
//!
//! Rules that never change: the command of an entry is fixed; from the Controller come only the
//! id and, for two entries, one checked argument (ping address, process id to close). A
//! `custom:` id runs only when it is in the signed list. The connection checks first that it
//! may type (keyboard permission, not "only watch"). The record gets the id and the outcome, never
//! the argument, a window name or command output.

pub mod catalog;
pub mod custom;
pub mod results;
#[cfg(target_os = "macos")]
mod run_mac;
#[cfg(windows)]
mod run_win;

use catalog::{Action, ArgUse, Os};
use serde_json::{json, Value};

/// Why the Host did not run a shortcut (contract codes, `sense.shortcut-result.err`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunError {
    UnknownId,
    NoPermission,
    UnsupportedOs,
    NeedsAdmin,
    Failed,
}

impl RunError {
    pub fn code(self) -> &'static str {
        match self {
            RunError::UnknownId => "unknown_id",
            RunError::NoPermission => "no_permission",
            RunError::UnsupportedOs => "unsupported_os",
            RunError::NeedsAdmin => "needs_admin",
            RunError::Failed => "failed",
        }
    }
}

/// One run the Host connection hands to a thread (ping and the window list take seconds).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub req: u32,
    pub id: String,
    pub arg: Option<String>,
}

/// What an id resolves to on this Host.
#[derive(Debug, Clone, PartialEq)]
pub enum Resolved {
    Builtin(&'static catalog::Entry),
    Custom(custom::Entry),
}

/// Pure resolution: built-in entry, approved custom entry, or the reason it cannot run here.
/// `host` is this computer's system (`None` = no catalogue: Linux and others).
pub fn resolve(id: &str, arg: Option<&str>, host: Option<Os>) -> Result<Resolved, RunError> {
    if custom::is_custom_id(id) {
        let host = host.ok_or(RunError::UnsupportedOs)?;
        if arg.is_some() {
            return Err(RunError::Failed);
        }
        return custom::find(id, host.code())
            .map(Resolved::Custom)
            .ok_or(RunError::UnknownId);
    }
    let entry = catalog::find(id).ok_or(RunError::UnknownId)?;
    if host != Some(entry.os()) {
        return Err(RunError::UnsupportedOs);
    }
    // `keys` entries are the Controller's to send.
    if entry.action == Action::Keys {
        return Err(RunError::UnsupportedOs);
    }
    match (entry.action.arg(), arg) {
        (ArgUse::None, Some(_)) | (ArgUse::Required, None) => return Err(RunError::Failed),
        (_, Some(a)) if results::arg_problem(a).is_some() => return Err(RunError::Failed),
        _ => {}
    }
    Ok(Resolved::Builtin(entry))
}

/// Host: runs `job` (blocking; on its own thread) and gives the answer to send. Records
/// `shortcut/run {id, ok, err}`.
pub fn run_job(job: &Job) -> super::peer_msg::PeerMsg {
    let result = resolve(&job.id, job.arg.as_deref(), Os::host())
        .and_then(|resolved| execute(&resolved, job.arg.as_deref()));
    let (ok, err, res) = match result {
        Ok(res) => (true, None, res),
        Err(e) => (false, Some(e.code().to_owned()), None),
    };
    super::diag::kinds::shortcut_run(&job.id, ok, err.as_deref());
    super::peer_msg::PeerMsg::ShortcutResult {
        req: job.req,
        ok,
        err,
        res,
    }
}

/// The (optional) result body of a resolved run.
fn execute(resolved: &Resolved, arg: Option<&str>) -> Result<Option<Value>, RunError> {
    match resolved {
        Resolved::Custom(entry) => platform::open_target(&entry.target).map(|()| None),
        Resolved::Builtin(entry) => match entry.action {
            Action::Keys => Err(RunError::UnsupportedOs),
            Action::IpCard => Ok(Some(ip_card())),
            Action::Ping => {
                let target = arg.and_then(results::ping_target).ok_or(RunError::Failed)?;
                platform::ping(target).map(Some)
            }
            Action::WindowList => match arg {
                None => Ok(Some(results::windows_res(platform::windows(), std::process::id()))),
                Some(a) => {
                    let pid = results::pid_arg(a).ok_or(RunError::Failed)?;
                    // Only a process that has a window of this session right now.
                    if pid == std::process::id() || !platform::windows().iter().any(|w| w.pid == pid) {
                        return Err(RunError::Failed);
                    }
                    platform::close(pid).map(|()| None)
                }
            },
            Action::Win(cmd) => platform::win(&cmd).map(|()| None),
            Action::Mac(args) => platform::mac(args).map(|()| None),
            Action::MacHome(sub) => platform::mac_home(sub).map(|()| None),
        },
    }
}

fn ip_card() -> Value {
    let networks = super::network::collect().unwrap_or_default();
    let adapters = super::health_v2::inventory_snapshot()
        .and_then(|inv| inv.network)
        .unwrap_or_default();
    if adapters.is_empty() {
        // Gateway / DNS come from the inventory; start reading it for the next time.
        super::health_v2::request_inventory();
    }
    results::ip_res(&networks, &adapters)
}

/// Apps of user `uid` from `ps -axo pid=,uid=,comm=` (pure, macOS): one entry per top-level
/// `.app` outside `/System/Library/CoreServices` (Finder, Dock …), named after the bundle.
pub fn mac_apps(ps: &str, uid: u32) -> Vec<results::Window> {
    let mut out = Vec::new();
    for line in ps.lines() {
        let line = line.trim_start();
        let mut parts = line.splitn(2, char::is_whitespace);
        let (Some(pid), Some(rest)) = (parts.next(), parts.next()) else {
            continue;
        };
        let rest = rest.trim_start();
        let mut parts = rest.splitn(2, char::is_whitespace);
        let (Some(owner), Some(path)) = (parts.next(), parts.next()) else {
            continue;
        };
        let (Ok(pid), Ok(owner)) = (pid.parse::<u32>(), owner.parse::<u32>()) else {
            continue;
        };
        let path = path.trim();
        if owner != uid
            || path.starts_with("/System/Library/CoreServices/")
            || path.matches(".app/").count() != 1
            || !path.contains(".app/Contents/MacOS/")
        {
            continue;
        }
        let Some(bundle) = path.split(".app/").next() else {
            continue;
        };
        let name = bundle.rsplit('/').next().unwrap_or(bundle);
        out.push(results::Window {
            pid,
            name: name.to_owned(),
            hung: false,
        });
    }
    out
}

/// `main_sense_shortcut_catalog(os)`: `[{id, cat, kind, admin, available}]` of the built-in
/// catalogue for `os` (`win` | `mac`); `[]` for any other (Linux has none, #163). Custom
/// shortcuts come with the preferences (`main_sense_prefs_get`, `custom`).
pub fn ffi_catalog(os: &str) -> String {
    let Some(os) = Os::from_code(os) else {
        return "[]".to_owned();
    };
    let list: Vec<Value> = catalog::of(os)
        .map(|e| {
            json!({
                "id": e.id,
                "cat": e.cat,
                "kind": e.kind(),
                "admin": e.admin,
                "available": true,
            })
        })
        .collect();
    Value::Array(list).to_string()
}

// The platform side; elsewhere every run is `unsupported_os` (resolve already refuses).
#[cfg(windows)]
mod platform {
    use super::{catalog::WinCmd, results::Window, run_win, RunError};
    use serde_json::Value;
    pub fn win(cmd: &WinCmd) -> Result<(), RunError> {
        run_win::run_cmd(cmd)
    }
    pub fn mac(_: &[&str]) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn mac_home(_: &str) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn open_target(target: &str) -> Result<(), RunError> {
        run_win::open_target(target)
    }
    pub fn ping(target: &str) -> Result<Value, RunError> {
        run_win::ping(target)
    }
    pub fn windows() -> Vec<Window> {
        run_win::windows()
    }
    pub fn close(pid: u32) -> Result<(), RunError> {
        run_win::close(pid)
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{catalog::WinCmd, results::Window, run_mac, RunError};
    use serde_json::Value;
    pub fn win(_: &WinCmd) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn mac(args: &[&str]) -> Result<(), RunError> {
        run_mac::run_open(args)
    }
    pub fn mac_home(sub: &str) -> Result<(), RunError> {
        run_mac::open_home(sub)
    }
    pub fn open_target(target: &str) -> Result<(), RunError> {
        run_mac::open_target(target)
    }
    pub fn ping(target: &str) -> Result<Value, RunError> {
        run_mac::ping(target)
    }
    pub fn windows() -> Vec<Window> {
        run_mac::windows()
    }
    pub fn close(pid: u32) -> Result<(), RunError> {
        run_mac::close(pid)
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
mod platform {
    use super::{catalog::WinCmd, results::Window, RunError};
    use serde_json::Value;
    pub fn win(_: &WinCmd) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn mac(_: &[&str]) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn mac_home(_: &str) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn open_target(_: &str) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn ping(_: &str) -> Result<Value, RunError> {
        Err(RunError::UnsupportedOs)
    }
    pub fn windows() -> Vec<Window> {
        Vec::new()
    }
    pub fn close(_: u32) -> Result<(), RunError> {
        Err(RunError::UnsupportedOs)
    }
}

#[cfg(test)]
mod tests;
