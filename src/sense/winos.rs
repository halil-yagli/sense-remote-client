//! Sense Remote (Sürüm 11, Windows tarama `inceleme/2026-11-27_tarama-windows.md`): the
//! operating-system layer of the Windows Host. Pure rules first (tested on every platform, the
//! PR check runs on Linux), the Windows calls after them.
//!
//! - W1: a real uninstall removes the update guard task (`SenseRemoteUpdateGuard`) and the
//!   update copies under `<ProgramData>\SenseRemote\update`. Without this the guard ran every
//!   minute as SYSTEM on a computer the program was removed from. Session recordings
//!   (`<ProgramData>\SenseRemote\recording`) are user data and stay; the top folder goes only
//!   when it is empty. The folder is touched only when it is exactly the protected folder the
//!   updater makes (owner SYSTEM / Administrators, protected DACL, no link): a folder a user made
//!   beforehand could be swapped for a junction between the check and the delete.
//! - W4: at the lock screen / UAC the display configuration can not be read (`QueryDisplayConfig`
//!   answers `ERROR_ACCESS_DENIED` to a thread without access to the input desktop); the last good
//!   details are kept instead of sending empty ones.
//! - W5: the maintenance curtain and the Sense icon live on the `Default` desktop; Windows shows
//!   neither on the secure desktop (lock screen, sign-in screen, UAC). The `--server` tells the
//!   Controller when the Host's input desktop is not `Default` (`Misc.plugin_request`
//!   [`SECURE_DESKTOP_REQUEST`]), and records `ghost/secure_desktop`. A third-party window on the
//!   secure desktop is not possible without a credential provider (Windows design), so the
//!   Controller warning is what keeps the technician from assuming the screen is hidden.
//! - W19: "Installed apps" shows the Sense version (plain number) instead of RustDesk's.

use base::message_proto::{Message, Misc, PluginRequest};
use serde_json::json;
use std::collections::HashMap;

// ---------------------------------------------------------------------------------------------
// W1: uninstall cleanup
// ---------------------------------------------------------------------------------------------

/// Command line flag of the elevated cleanup step the uninstall script runs (before the
/// program folder is removed).
pub const UNINSTALL_CLEANUP_FLAG: &str = "--sense-uninstall-cleanup";

/// What is at a path, without following a link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirKind {
    Missing,
    Dir,
    /// A link, junction, other reparse point or a file: never followed, never deleted.
    Other,
}

/// Lines put in FRONT of the uninstall script: the guard task goes first (so it does not start
/// again while files are removed), then this program's cleanup step. `exe` is the installed
/// program, already checked for the elevated cmd (`None`: no cleanup step, the task line stays).
pub fn uninstall_pre_commands(exe: Option<&str>) -> String {
    let task = crate::sense::update::apply_win::GUARD_TASK;
    let mut out = format!("schtasks /Delete /TN \"{task}\" /F > nul 2>&1\r\n");
    if let Some(exe) = exe {
        out.push_str(&format!("\"{exe}\" {UNINSTALL_CLEANUP_FLAG}\r\n"));
    }
    out
}

/// Whether the uninstall may delete under `<ProgramData>\SenseRemote`: only a real folder with
/// the updater's protected security (`apply_win::is_expected_sddl`).
pub fn cleanup_allowed(top: DirKind, sddl: Option<&str>) -> bool {
    top == DirKind::Dir
        && sddl.is_some_and(crate::sense::update::apply_win::is_expected_sddl)
}

// ---------------------------------------------------------------------------------------------
// W4: last good display details
// ---------------------------------------------------------------------------------------------

/// A fresh, non-empty reading replaces `last`; an empty one (the configuration could not be
/// read) gives `last` back. The second value is true when `last` was used.
pub fn keep_last_good<T: Clone>(
    last: &mut Option<HashMap<String, T>>,
    fresh: HashMap<String, T>,
) -> (HashMap<String, T>, bool) {
    if !fresh.is_empty() {
        *last = Some(fresh.clone());
        return (fresh, false);
    }
    match last {
        Some(kept) => (kept.clone(), true),
        None => (fresh, false),
    }
}

// ---------------------------------------------------------------------------------------------
// W5: secure desktop
// ---------------------------------------------------------------------------------------------

/// `Misc.plugin_request` id (Host → Controller). Content: JSON `{"on": bool, "desktop": text,
/// "curtain": bool}`. Builds that do not know it (older Controllers) drop it (`io_loop`
/// `PluginRequest` arm falls through).
pub const SECURE_DESKTOP_REQUEST: &str = "sense.secure-desktop";
/// How often the input desktop is read (the video loop calls far more often).
pub const CHECK_EVERY_MS: i64 = 1_000;
/// While the Host stays on the secure desktop the notice is repeated, so a Controller that
/// connected meanwhile learns it too.
pub const RESEND_EVERY_MS: i64 = 5_000;

/// True for every input desktop other than the user's `Default` (`Winlogon`: lock screen,
/// sign-in screen, UAC; `Screen-saver`; `Disconnect`).
pub fn is_secure_desktop(name: &str) -> bool {
    !name.trim().eq_ignore_ascii_case("default")
}

/// The desktop name for the record and the message: the known names in lower case, anything
/// else `diger` (a name is never copied through as it came).
pub fn desktop_label(name: &str) -> &'static str {
    match name.trim().to_ascii_lowercase().as_str() {
        "default" => "default",
        "winlogon" => "winlogon",
        "screen-saver" => "screen-saver",
        "disconnect" => "disconnect",
        _ => "diger",
    }
}

/// A notice for the Controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DesktopNotice {
    pub on: bool,
    /// The state just changed (else a repeat while it stays on).
    pub changed: bool,
}

/// Throttled watch of the input desktop. Pure: the caller gives the time and the reading.
#[derive(Debug, Default)]
pub struct DesktopWatch {
    last_check: Option<i64>,
    on: bool,
    last_sent: Option<i64>,
}

impl DesktopWatch {
    pub const fn new() -> Self {
        Self { last_check: None, on: false, last_sent: None }
    }

    /// `read` is called at most once per [`CHECK_EVERY_MS`]; it gives `Some(secure)` or `None`
    /// when the desktop could not be read (no change then). Returns the notice to send.
    pub fn step(&mut self, now_ms: i64, read: impl FnOnce() -> Option<bool>) -> Option<DesktopNotice> {
        if self.last_check.is_some_and(|t| now_ms >= t && now_ms - t < CHECK_EVERY_MS) {
            return None;
        }
        self.last_check = Some(now_ms);
        let secure = read()?;
        if secure != self.on {
            self.on = secure;
            self.last_sent = Some(now_ms);
            return Some(DesktopNotice { on: secure, changed: true });
        }
        if self.on && self.last_sent.map_or(true, |t| now_ms < t || now_ms - t >= RESEND_EVERY_MS) {
            self.last_sent = Some(now_ms);
            return Some(DesktopNotice { on: true, changed: false });
        }
        None
    }
}

/// The message that tells the Controller.
pub fn secure_desktop_message(on: bool, desktop: &str, curtain: bool) -> Message {
    let content = json!({ "on": on, "desktop": desktop, "curtain": curtain }).to_string();
    let mut misc = Misc::new();
    misc.set_plugin_request(PluginRequest {
        id: SECURE_DESKTOP_REQUEST.to_owned(),
        content: content.into_bytes().into(),
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

// ---------------------------------------------------------------------------------------------
// W19: version in "Installed apps"
// ---------------------------------------------------------------------------------------------

/// `DisplayVersion` of the uninstall entry: the Sense version (plain number) when the build has
/// one, else RustDesk's (local builds without `SENSE_VERSION`). The `Version` value next to it
/// keeps RustDesk's number; nothing in this program reads `DisplayVersion`.
pub fn display_version(sense: Option<u32>, rustdesk: &str) -> String {
    match sense {
        Some(version) => version.to_string(),
        None => rustdesk.replace('-', "."),
    }
}

/// [`display_version`] of this build.
pub fn this_display_version() -> String {
    display_version(crate::sense::report::app_version(), crate::VERSION)
}

// ---------------------------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------------------------

#[cfg(windows)]
pub use win::{secure_desktop_tick, uninstall_cleanup};
#[cfg(windows)]
pub(super) use win::display_details_kept;

#[cfg(windows)]
mod win {
    use super::*;
    use hbb_common::log;
    use std::{
        path::{Path, PathBuf},
        sync::Mutex,
    };

    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as i64)
    }

    // ---- W1 ----

    fn dir_kind(path: &Path) -> Result<DirKind, String> {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 => {
                Ok(DirKind::Other)
            }
            Ok(meta) if meta.is_dir() => Ok(DirKind::Dir),
            Ok(_) => Ok(DirKind::Other),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(DirKind::Missing),
            Err(err) => Err(err.to_string()),
        }
    }

    /// `FOLDERID_ProgramData`, never an environment variable (same as the updater).
    fn program_data() -> Option<PathBuf> {
        use windows::Win32::{
            System::Com::CoTaskMemFree,
            UI::Shell::{FOLDERID_ProgramData, SHGetKnownFolderPath, KF_FLAG_DEFAULT},
        };
        let value =
            unsafe { SHGetKnownFolderPath(&FOLDERID_ProgramData, KF_FLAG_DEFAULT, None) }.ok()?;
        let path = unsafe { value.to_string() };
        unsafe { CoTaskMemFree(Some(value.0.cast())) };
        let path = PathBuf::from(path.ok()?);
        crate::sense::update::apply_win::is_safe_path(&path).then_some(path)
    }

    /// Owner + DACL of `path` as SDDL (the updater's `sddl_of`, read only).
    fn sddl_of(path: &Path) -> Result<String, String> {
        use windows::{
            core::{PCWSTR, PWSTR},
            Win32::{
                Foundation::{LocalFree, HLOCAL},
                Security::{
                    Authorization::{
                        ConvertSecurityDescriptorToStringSecurityDescriptorW,
                        GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT,
                    },
                    DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
                },
            },
        };
        let path_text = path.to_str().ok_or("path is not unicode")?;
        let wide_path = crate::platform::wide_string(path_text);
        let info = OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        let result = unsafe {
            GetNamedSecurityInfoW(
                PCWSTR(wide_path.as_ptr()),
                SE_FILE_OBJECT,
                info,
                None,
                None,
                None,
                None,
                &mut descriptor,
            )
        };
        if result.0 != 0 {
            return Err(format!("GetNamedSecurityInfoW: {}", result.0));
        }
        let mut text = PWSTR::null();
        let converted = unsafe {
            ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor,
                SDDL_REVISION_1,
                info,
                &mut text,
                None,
            )
        };
        let sddl = match converted {
            Ok(()) => {
                let value = unsafe { text.to_string() }.map_err(|err| err.to_string());
                unsafe { LocalFree(Some(HLOCAL(text.0.cast()))) };
                value
            }
            Err(err) => Err(err.to_string()),
        };
        unsafe { LocalFree(Some(HLOCAL(descriptor.0))) };
        sddl
    }

    /// `--sense-uninstall-cleanup` (elevated, from the uninstall script). Returns the exit code
    /// (0 = nothing left to do or done). Never fails the uninstall: the script goes on.
    pub fn uninstall_cleanup() -> i32 {
        use crate::sense::update::apply_win::{sense_data_dir, update_dir};
        let Some(program_data) = program_data() else {
            log::warn!("Sense Remote: uninstall cleanup: no ProgramData");
            return 1;
        };
        let top = sense_data_dir(&program_data);
        let kind = match dir_kind(&top) {
            Ok(DirKind::Missing) => return 0,
            Ok(kind) => kind,
            Err(err) => {
                log::warn!("Sense Remote: uninstall cleanup: {} not readable: {err}", top.display());
                return 1;
            }
        };
        let sddl = sddl_of(&top).ok();
        if !cleanup_allowed(kind, sddl.as_deref()) {
            // Not the updater's protected folder: left alone (see the module comment).
            log::warn!("Sense Remote: uninstall cleanup: {} is not the protected folder, left", top.display());
            return 1;
        }
        let update = update_dir(&program_data);
        let mut code = 0;
        match dir_kind(&update) {
            // std's remove_dir_all does not follow links inside (CVE-2022-21658 fix).
            Ok(DirKind::Dir) => {
                if let Err(err) = std::fs::remove_dir_all(&update) {
                    log::warn!("Sense Remote: uninstall cleanup: update copies not removed: {err}");
                    code = 1;
                }
            }
            Ok(DirKind::Missing) => {}
            Ok(DirKind::Other) => {
                log::warn!("Sense Remote: uninstall cleanup: {} is not a folder, left", update.display());
                code = 1;
            }
            Err(err) => {
                log::warn!("Sense Remote: uninstall cleanup: {err}");
                code = 1;
            }
        }
        // Only when empty: session recordings (`recording`) are the user's and stay.
        let _ = std::fs::remove_dir(&top);
        log::info!("Sense Remote: uninstall cleanup done ({code})");
        code
    }

    // ---- W4 ----

    static DISPLAYS_LAST_GOOD: Mutex<Option<HashMap<String, crate::sense::report::DisplayDetails>>> =
        Mutex::new(None);
    static DISPLAYS_KEPT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    /// `displays_win::query`: the fresh details, or the last good ones when none could be read
    /// (`error` = the API's code, logged once per stretch).
    pub(in crate::sense) fn display_details_kept(
        fresh: HashMap<String, crate::sense::report::DisplayDetails>,
        error: Option<i32>,
    ) -> HashMap<String, crate::sense::report::DisplayDetails> {
        use std::sync::atomic::Ordering;
        let mut last = DISPLAYS_LAST_GOOD.lock().unwrap_or_else(|e| e.into_inner());
        let (out, kept) = keep_last_good(&mut last, fresh);
        let was = DISPLAYS_KEPT.swap(kept, Ordering::SeqCst);
        if kept && !was {
            log::info!(
                "Sense Remote: display configuration not readable (code {}), last good details kept",
                error.unwrap_or(0)
            );
        } else if !kept && was {
            log::info!("Sense Remote: display configuration readable again");
        }
        out
    }

    // ---- W5 ----

    static WATCH: Mutex<DesktopWatch> = Mutex::new(DesktopWatch::new());

    /// Name of the desktop that receives user input (`Default`, `Winlogon`, …); `None` when it
    /// can not be opened (a user process at the secure desktop).
    fn input_desktop_name() -> Option<String> {
        use winapi::um::winuser::{CloseDesktop, GetUserObjectInformationW, OpenInputDesktop};
        const UOI_NAME: i32 = 2;
        const DESKTOP_READOBJECTS: u32 = 0x0001;
        unsafe {
            let desk = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS);
            if desk.is_null() {
                return None;
            }
            let mut buf = [0u16; 64];
            let mut needed = 0u32;
            let ok = GetUserObjectInformationW(
                desk as _,
                UOI_NAME,
                buf.as_mut_ptr() as _,
                (buf.len() * 2) as u32,
                &mut needed,
            );
            CloseDesktop(desk);
            if ok == 0 {
                return None;
            }
            let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
            Some(String::from_utf16_lossy(&buf[..len]))
        }
    }

    /// Called from the video loop of the `--server` (`video_service::run`): the message to send
    /// to the Controller(s) when the Host enters or stays on the secure desktop, or leaves it.
    pub fn secure_desktop_tick() -> Option<Message> {
        let mut label = "diger";
        let notice = WATCH.lock().unwrap_or_else(|e| e.into_inner()).step(now_ms(), || {
            let name = input_desktop_name()?;
            label = desktop_label(&name);
            Some(is_secure_desktop(&name))
        })?;
        let curtain = crate::sense::curtain::is_shown();
        if notice.changed {
            log::info!(
                "Sense Remote: input desktop {} (secure {}, curtain {curtain})",
                label,
                notice.on
            );
            crate::sense::diag::event(
                "ghost",
                "secure_desktop",
                json!({ "acik": notice.on, "masaustu": label, "perde": curtain }),
            );
        }
        Some(secure_desktop_message(notice.on, label, curtain))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uninstall_pre_commands_delete_the_guard_then_clean() {
        let lines = uninstall_pre_commands(Some("C:\\Program Files\\SenseRemote\\SenseRemote.exe"));
        assert_eq!(
            lines,
            "schtasks /Delete /TN \"SenseRemoteUpdateGuard\" /F > nul 2>&1\r\n\
             \"C:\\Program Files\\SenseRemote\\SenseRemote.exe\" --sense-uninstall-cleanup\r\n"
        );
        // Without a usable program path the task is still removed.
        assert_eq!(
            uninstall_pre_commands(None),
            "schtasks /Delete /TN \"SenseRemoteUpdateGuard\" /F > nul 2>&1\r\n"
        );
    }

    #[test]
    fn cleanup_only_in_the_protected_folder() {
        let ours = "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
        assert!(cleanup_allowed(DirKind::Dir, Some(ours)));
        assert!(cleanup_allowed(DirKind::Dir, Some("O:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)")));
        // A junction / file, a folder a user made (owner a user, users may write), unreadable.
        assert!(!cleanup_allowed(DirKind::Other, Some(ours)));
        assert!(!cleanup_allowed(DirKind::Missing, Some(ours)));
        assert!(!cleanup_allowed(
            DirKind::Dir,
            Some("O:S-1-5-21-1-2-3-1001D:(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FA;;;SY)")
        ));
        assert!(!cleanup_allowed(DirKind::Dir, Some("O:BAD:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;BU)")));
        assert!(!cleanup_allowed(DirKind::Dir, None));
    }

    #[test]
    fn last_good_details_survive_an_empty_reading() {
        let mut last = None;
        let fresh: HashMap<String, u32> = [("\\\\.\\DISPLAY1".to_owned(), 60)].into();
        assert_eq!(keep_last_good(&mut last, fresh.clone()), (fresh.clone(), false));
        // Lock screen: nothing readable → the last good details, marked as kept.
        assert_eq!(keep_last_good(&mut last, HashMap::new()), (fresh.clone(), true));
        // Unlocked: a new reading replaces them.
        let newer: HashMap<String, u32> = [("\\\\.\\DISPLAY1".to_owned(), 144)].into();
        assert_eq!(keep_last_good(&mut last, newer.clone()), (newer.clone(), false));
        assert_eq!(keep_last_good(&mut last, HashMap::new()), (newer, true));
        // Nothing ever read: empty stays empty.
        let mut never: Option<HashMap<String, u32>> = None;
        assert_eq!(keep_last_good(&mut never, HashMap::new()), (HashMap::new(), false));
    }

    #[test]
    fn secure_desktop_names() {
        assert!(!is_secure_desktop("Default"));
        assert!(!is_secure_desktop("default"));
        assert!(is_secure_desktop("Winlogon"));
        assert!(is_secure_desktop("Screen-saver"));
        assert!(is_secure_desktop("Disconnect"));
        assert_eq!(desktop_label("Winlogon"), "winlogon");
        assert_eq!(desktop_label("Default"), "default");
        assert_eq!(desktop_label("Gizli-Masaüstü"), "diger");
    }

    #[test]
    fn desktop_watch_tells_changes_and_repeats_while_on() {
        let mut w = DesktopWatch::new();
        // Default desktop: nothing to tell.
        assert_eq!(w.step(0, || Some(false)), None);
        // Throttled: not read again within a second.
        assert_eq!(w.step(500, || panic!("read too often")), None);
        // Lock screen.
        assert_eq!(w.step(1_000, || Some(true)), Some(DesktopNotice { on: true, changed: true }));
        assert_eq!(w.step(2_000, || Some(true)), None);
        // Unreadable reading: no change, no notice.
        assert_eq!(w.step(3_000, || None), None);
        // Repeated every 5 s while on (a Controller that connected meanwhile).
        assert_eq!(w.step(6_000, || Some(true)), Some(DesktopNotice { on: true, changed: false }));
        assert_eq!(w.step(7_000, || Some(true)), None);
        // Back to the user's desktop: told once.
        assert_eq!(w.step(8_000, || Some(false)), Some(DesktopNotice { on: false, changed: true }));
        assert_eq!(w.step(20_000, || Some(false)), None);
        // A clock that moved back does not freeze the watch.
        assert_eq!(w.step(5_000, || Some(true)), Some(DesktopNotice { on: true, changed: true }));
    }

    #[test]
    fn secure_desktop_message_shape() {
        let msg = secure_desktop_message(true, "winlogon", true);
        let request = msg.misc().plugin_request();
        assert_eq!(request.id, SECURE_DESKTOP_REQUEST);
        let content: serde_json::Value = serde_json::from_slice(&request.content).unwrap();
        assert_eq!(content, json!({ "on": true, "desktop": "winlogon", "curtain": true }));
    }

    #[test]
    fn display_version_is_the_sense_number() {
        assert_eq!(display_version(Some(11), "1.5.3"), "11");
        assert_eq!(display_version(None, "1.5.3"), "1.5.3");
        assert_eq!(display_version(None, "1.5.3-1"), "1.5.3.1");
    }
}
