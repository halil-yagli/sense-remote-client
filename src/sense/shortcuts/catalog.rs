//! Sense Remote (Sürüm 12, #160, #161, #163; plan 2026-11-28 §2.3): the built-in shortcut
//! catalogue, compiled in. The ids are the same as the Controller's list
//! (`flutter/lib/sense/screens/session/lists/favorites/catalog.dart`, FAV-A); a test reads that
//! file and compares ids, groups and the `keys` entries.
//!
//! Every command is a fixed string. Nothing from the Controller is added to it except where an
//! entry says so: the ping address and the window to close (both checked by
//! [`super::results::arg_problem`] and passed as one argument, never through a shell).
//!
//! `keys` entries (Ctrl+Alt+Del, lock, Win+D) are sent as keys by the Controller; the Host never
//! runs them.

/// The system an id belongs to (`win.` / `mac.`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Win,
    Mac,
}

impl Os {
    pub fn code(self) -> &'static str {
        match self {
            Os::Win => "win",
            Os::Mac => "mac",
        }
    }

    pub fn from_code(code: &str) -> Option<Os> {
        match code {
            "win" => Some(Os::Win),
            "mac" => Some(Os::Mac),
            _ => None,
        }
    }

    /// The system this build runs on, if it has a catalogue.
    pub fn host() -> Option<Os> {
        if cfg!(windows) {
            Some(Os::Win)
        } else if cfg!(target_os = "macos") {
            Some(Os::Mac)
        } else {
            None
        }
    }
}

/// Windows programs a command starts (full path built at run time from `SystemRoot`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinExe {
    Cmd,
    PowerShell,
    Ipconfig,
    Shutdown,
}

impl WinExe {
    /// Path under `%SystemRoot%`.
    pub fn rel_path(self) -> &'static str {
        match self {
            WinExe::Cmd => r"System32\cmd.exe",
            WinExe::PowerShell => r"System32\WindowsPowerShell\v1.0\powershell.exe",
            WinExe::Ipconfig => r"System32\ipconfig.exe",
            WinExe::Shutdown => r"System32\shutdown.exe",
        }
    }
}

/// A fixed Windows command line, run as the signed-in user in their session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WinCmd {
    pub exe: WinExe,
    /// Everything after the program, exactly as passed (no Controller input).
    pub args: &'static str,
    /// false = a console tool that runs hidden.
    pub show: bool,
}

/// What the Host does for an id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// The Controller sends keys itself.
    Keys,
    Win(WinCmd),
    /// `/usr/bin/open` with these arguments, as the console user.
    Mac(&'static [&'static str]),
    /// `/usr/bin/open <home>/<sub>` (the user's own folder).
    MacHome(&'static str),
    /// The IP card (address, gateway, DNS) as the result body.
    IpCard,
    /// Ping the address the Controller typed; counts as the result body.
    Ping,
    /// Without an argument the window / app list; with a process id, closes that one.
    WindowList,
}

impl Action {
    /// Whether the entry takes the Controller's argument (`required` = it must have one).
    pub fn arg(self) -> ArgUse {
        match self {
            Action::Ping => ArgUse::Required,
            Action::WindowList => ArgUse::Optional,
            _ => ArgUse::None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgUse {
    None,
    Optional,
    Required,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub id: &'static str,
    /// Group code, the same as the Controller's `SenseFavGroup` names.
    pub cat: &'static str,
    /// Windows asks for elevation (UAC on the Host, V8: never silent).
    pub admin: bool,
    pub action: Action,
}

impl Entry {
    pub fn os(&self) -> Os {
        if self.id.starts_with("mac.") {
            Os::Mac
        } else {
            Os::Win
        }
    }

    pub fn kind(&self) -> &'static str {
        if self.action == Action::Keys {
            "keys"
        } else {
            "exec"
        }
    }
}

const fn win(id: &'static str, cat: &'static str, args: &'static str) -> Entry {
    Entry {
        id,
        cat,
        admin: false,
        action: Action::Win(WinCmd {
            exe: WinExe::Cmd,
            args,
            show: true,
        }),
    }
}

const fn win_admin(id: &'static str, cat: &'static str, args: &'static str) -> Entry {
    let mut e = win(id, cat, args);
    e.admin = true;
    e
}

const fn hidden(id: &'static str, cat: &'static str, exe: WinExe, args: &'static str) -> Entry {
    Entry {
        id,
        cat,
        admin: false,
        action: Action::Win(WinCmd {
            exe,
            args,
            show: false,
        }),
    }
}

const fn special(id: &'static str, cat: &'static str, action: Action) -> Entry {
    Entry {
        id,
        cat,
        admin: false,
        action,
    }
}

const fn mac(id: &'static str, cat: &'static str, args: &'static [&'static str]) -> Entry {
    Entry {
        id,
        cat,
        admin: false,
        action: Action::Mac(args),
    }
}

// `cmd /d /c start "" <target>`: the shell opens the target the way a double click does (a
// program that asks for elevation shows UAC on the Host). `/d` skips AutoRun.
const PS: WinExe = WinExe::PowerShell;

/// The whole catalogue, in the Controller's order. Linux has none (#163).
pub const CATALOG: &[Entry] = &[
    // Windows — Dosya ve sistem
    win("win.thispc", "files", r#"/d /c start "" explorer.exe shell:MyComputerFolder"#),
    win("win.explorer", "files", r#"/d /c start "" explorer.exe"#),
    win("win.taskmgr", "files", r#"/d /c start "" taskmgr.exe"#),
    win_admin("win.sysprop", "files", r#"/d /c start "" SystemPropertiesAdvanced.exe"#),
    win("win.programs", "files", r#"/d /c start "" appwiz.cpl"#),
    // Ağ ve sorun giderme
    win("win.netadapt", "network", r#"/d /c start "" ncpa.cpl"#),
    win("win.netset", "network", r#"/d /c start "" ms-settings:network"#),
    special("win.ipinfo", "network", Action::IpCard),
    hidden("win.flushdns", "network", WinExe::Ipconfig, "/flushdns"),
    Entry {
        id: "win.resetnic",
        cat: "network",
        admin: true,
        action: Action::Win(WinCmd {
            exe: PS,
            args: r#"-NoProfile -WindowStyle Hidden -Command "Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoP -C Get-NetAdapter -Physical|? Status -eq Up|Restart-NetAdapter'""#,
            show: false,
        }),
    },
    special("win.ping", "network", Action::Ping),
    win("win.firewall", "network", r#"/d /c start "" firewall.cpl"#),
    win("win.shares", "network", r#"/d /c start "" fsmgmt.msc"#),
    win("win.printers", "network", r#"/d /c start "" ms-settings:printers"#),
    // Yönetim araçları
    win("win.services", "admin", r#"/d /c start "" services.msc"#),
    win("win.devmgr", "admin", r#"/d /c start "" devmgmt.msc"#),
    win_admin("win.diskmgmt", "admin", r#"/d /c start "" diskmgmt.msc"#),
    win("win.eventvwr", "admin", r#"/d /c start "" eventvwr.msc"#),
    win("win.tasksch", "admin", r#"/d /c start "" taskschd.msc"#),
    win_admin("win.regedit", "admin", r#"/d /c start "" regedit.exe"#),
    // Ayarlar
    win("win.ctrlpanel", "settings", r#"/d /c start "" control.exe"#),
    win("win.winset", "settings", r#"/d /c start "" ms-settings:"#),
    win("win.dispset", "settings", r#"/d /c start "" ms-settings:display"#),
    win("win.sndset", "settings", r#"/d /c start "" ms-settings:sound"#),
    // Komut
    win("win.cmd", "command", r#"/d /c start "" cmd.exe"#),
    win("win.ps", "command", r#"/d /c start "" powershell.exe"#),
    // Sistem hareketleri
    hidden(
        "win.showdesk",
        "actions",
        PS,
        r#"-NoProfile -WindowStyle Hidden -Command "(New-Object -ComObject Shell.Application).ToggleDesktop()""#,
    ),
    special("win.cad", "actions", Action::Keys),
    hidden(
        "win.restexp",
        "actions",
        PS,
        r#"-NoProfile -WindowStyle Hidden -Command "Stop-Process -Name explorer -Force; Start-Sleep 2; if (!(Get-Process explorer -ea 0)) { Start-Process explorer.exe }""#,
    ),
    special("win.killhung", "actions", Action::WindowList),
    special("win.lock", "actions", Action::Keys),
    hidden("win.logoff", "actions", WinExe::Shutdown, "/l"),
    hidden("win.clip", "actions", WinExe::Cmd, "/d /c type nul | clip"),
    special("win.minall", "actions", Action::Keys),
    // Sistem durumu
    win("win.winupd", "health", r#"/d /c start "" ms-settings:windowsupdate"#),
    win("win.power", "health", r#"/d /c start "" powercfg.cpl"#),
    win("win.startup", "health", r#"/d /c start "" ms-settings:startupapps"#),
    win("win.temp", "health", r#"/d /c start "" "%TEMP%""#),
    win("win.resmon", "health", r#"/d /c start "" resmon.exe"#),
    win("win.perfmon", "health", r#"/d /c start "" perfmon.exe"#),
    win("win.datetime", "health", r#"/d /c start "" timedate.cpl"#),
    // Ekran ve ses
    win("win.gpu", "screen", r#"/d /c start "" ms-settings:display-advancedgraphics"#),
    win("win.mixer", "screen", r#"/d /c start "" sndvol.exe"#),
    win("win.defout", "screen", r#"/d /c start "" mmsys.cpl"#),
    win("win.night", "screen", r#"/d /c start "" ms-settings:nightlight"#),
    // macOS
    mac("mac.finder", "files", &["-a", "Finder"]),
    mac("mac.actmon", "files", &["-b", "com.apple.ActivityMonitor"]),
    mac("mac.net", "network", &["/System/Library/PreferencePanes/Network.prefPane"]),
    mac("mac.diskutil", "admin", &["-b", "com.apple.DiskUtility"]),
    mac("mac.console", "admin", &["-b", "com.apple.Console"]),
    mac("mac.sysset", "settings", &["-b", "com.apple.systempreferences"]),
    mac("mac.mdisp", "settings", &["/System/Library/PreferencePanes/Displays.prefPane"]),
    mac("mac.msnd", "settings", &["/System/Library/PreferencePanes/Sound.prefPane"]),
    mac("mac.term", "command", &["-b", "com.apple.Terminal"]),
    special("mac.forcequit", "mac", Action::WindowList),
    mac(
        "mac.privacy",
        "mac",
        &["x-apple.systempreferences:com.apple.preference.security?Privacy"],
    ),
    mac("mac.energy", "mac", &["/System/Library/PreferencePanes/EnergySaver.prefPane"]),
    special("mac.downloads", "mac", Action::MacHome("Downloads")),
    special("mac.maclock", "mac", Action::Keys),
];

/// The built-in entry `id`.
pub fn find(id: &str) -> Option<&'static Entry> {
    CATALOG.iter().find(|e| e.id == id)
}

/// The built-in entries of `os`.
pub fn of(os: Os) -> impl Iterator<Item = &'static Entry> {
    CATALOG.iter().filter(move |e| e.os() == os)
}
