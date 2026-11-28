//! Sense Remote (Sürüm 12, FAV-Ç): running a shortcut on a Windows Host.
//!
//! The `--server` process runs as SYSTEM in the user's session (installed) or as the user
//! (portable). Commands start as the signed-in user in that session
//! (`run_exe_in_cur_session`: the user's token, never SYSTEM), so they see what the user sees and
//! nothing is elevated silently: a program that asks for elevation shows UAC on the Host (V8).
//! Ping, the window list and closing a window run in this process.

use super::catalog::{WinCmd, WinExe};
use super::results::{self, Window};
use super::RunError;
use hbb_common::log;
use serde_json::Value;
use std::os::windows::process::CommandExt;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// `LaunchProcessWin` copies the command line into a `MAX_PATH` buffer (with the NUL); a longer
/// one would abort the process, so it is refused before.
pub const MAX_CMDLINE: usize = 259;

fn system_root() -> String {
    std::env::var("SystemRoot")
        .ok()
        .filter(|s| !s.is_empty() && !s.contains('"'))
        .unwrap_or_else(|| r"C:\Windows".to_owned())
}

fn exe_path(exe: WinExe) -> String {
    format!(r"{}\{}", system_root(), exe.rel_path())
}

/// The command line `LaunchProcessWin` gets (pure).
pub fn cmdline(exe: &str, args: &str) -> String {
    format!("\"{exe}\" {args}")
}

fn spawn(exe: &str, args: &str, show: bool) -> Result<(), RunError> {
    if cmdline(exe, args).encode_utf16().count() >= MAX_CMDLINE {
        log::warn!("Sense Remote: shortcut command line too long");
        return Err(RunError::Failed);
    }
    let result = if crate::platform::windows::is_root() {
        // Installed: as the user of this process's session.
        crate::platform::windows::run_exe_in_cur_session(exe, vec![args], show).map(|_| ())
    } else {
        // Portable: this process already is the user.
        let mut cmd = std::process::Command::new(exe);
        cmd.raw_arg(args);
        if !show {
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        cmd.spawn().map(|_| ()).map_err(|e| e.into())
    };
    result.map_err(|err| {
        log::warn!("Sense Remote: shortcut did not start: {err}");
        RunError::Failed
    })
}

pub fn run_cmd(cmd: &WinCmd) -> Result<(), RunError> {
    spawn(&exe_path(cmd.exe), cmd.args, cmd.show)
}

/// An approved custom shortcut: opened by Explorer like a double click (program, folder or
/// https address). The target is quoted whole; it holds no `"` (checked).
pub fn open_target(target: &str) -> Result<(), RunError> {
    if target.contains('"') {
        return Err(RunError::Failed);
    }
    spawn(&format!(r"{}\explorer.exe", system_root()), &format!("\"{target}\""), true)
}

/// `ping -n 4 -w 1000 <target>` from this process (no window); the result body.
pub fn ping(target: &str) -> Result<Value, RunError> {
    let out = std::process::Command::new(format!(r"{}\System32\PING.EXE", system_root()))
        .args(["-n", &results::PING_COUNT.to_string(), "-w", "1000", target])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|err| {
            log::warn!("Sense Remote: ping did not start: {err}");
            RunError::Failed
        })?;
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(results::parse_ping(&text, results::PING_COUNT).to_res())
}

/// Visible top-level windows of the session: title, process, "not responding".
pub fn windows() -> Vec<Window> {
    use winapi::shared::minwindef::{BOOL, LPARAM, TRUE};
    use winapi::shared::windef::HWND;
    use winapi::um::winuser::{
        EnumWindows, GetWindow, GetWindowLongW, GetWindowTextLengthW, GetWindowTextW,
        GetWindowThreadProcessId, IsHungAppWindow, IsWindowVisible, GWL_EXSTYLE, GW_OWNER,
        WS_EX_TOOLWINDOW,
    };

    unsafe extern "system" fn each(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let list = &mut *(lparam as *mut Vec<Window>);
        if list.len() >= 256 {
            return TRUE;
        }
        if IsWindowVisible(hwnd) == 0 || !GetWindow(hwnd, GW_OWNER).is_null() {
            return TRUE;
        }
        if (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW != 0 {
            return TRUE;
        }
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return TRUE;
        }
        let mut buf = vec![0u16; len as usize + 1];
        let got = GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as _);
        if got <= 0 {
            return TRUE;
        }
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        list.push(Window {
            pid,
            name: String::from_utf16_lossy(&buf[..got as usize]),
            hung: IsHungAppWindow(hwnd) != 0,
        });
        TRUE
    }

    let mut list: Vec<Window> = Vec::new();
    unsafe {
        EnumWindows(Some(each), &mut list as *mut Vec<Window> as LPARAM);
    }
    list
}

/// Ends process `pid` (it was in the window list a moment ago; checked by the caller).
pub fn close(pid: u32) -> Result<(), RunError> {
    use winapi::um::handleapi::CloseHandle;
    use winapi::um::processthreadsapi::{OpenProcess, TerminateProcess};
    use winapi::um::winnt::PROCESS_TERMINATE;
    unsafe {
        let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
        if handle.is_null() {
            log::warn!("Sense Remote: window close: process not opened");
            return Err(RunError::Failed);
        }
        let ok = TerminateProcess(handle, 1) != 0;
        CloseHandle(handle);
        if ok {
            Ok(())
        } else {
            Err(RunError::Failed)
        }
    }
}
