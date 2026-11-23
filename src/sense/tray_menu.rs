//! Sense Remote (Sürüm 4, C5 / H6; plan 2026-11-23 §2.6 and "Ek"; decision #69): the tray menu
//! and the operating-system notification of a new chat message.
//!
//! The menu is the operating system's own (#69; `src/tray.rs` draws it with `tray-icon`). This
//! module holds the parts that can be tested without a desktop:
//! - the items in order (YH C5): Host gets only "Sense Remote'u aç" (no "Servisi durdur": the
//!   person at the computer can not stop the service from the tray, H6); Controller (and
//!   Host + Controller) also "SON BAĞLANTILAR" (the last 3) and "Çıkış yap";
//! - the tooltip "Sense Remote · hazır" / "Sense Remote · N bağlantı" (`get_app_display_name`);
//! - which icon fits the taskbar (black on a light taskbar, white on a dark one; decision #70);
//! - the last connections (`main_sense_tray_recent`), from RustDesk's peer files (newest first).
//!
//! #62: `main_sense_notify` shows a real Windows / macOS notification instead of the in-app card.
//! A press on it (Windows) tells the session windows (`NOTIFY_ACTIVATED_EVENT`); the window
//! whose notification it was comes forward and opens the chat.

use serde_derive::Serialize;

/// Most recent connections the Controller menu shows (YH C5).
pub const RECENT_MAX: usize = 3;

pub const OPEN_LABEL: &str = "Sense Remote'u aç";
pub const RECENT_HEADER: &str = "SON BAĞLANTILAR";
pub const SIGN_OUT_LABEL: &str = "Çıkış yap";
const READY: &str = "hazır";

/// Menu item ids (`tray-icon` `MenuId`).
const ID_OPEN: &str = "sense-open";
const ID_SIGN_OUT: &str = "sense-signout";
const ID_CONNECT_PREFIX: &str = "sense-connect:";

/// Authority of the sign-out link the tray hands to the app window
/// (`flutter/lib/sense/screens/controller/data/tray_link.dart`).
pub const SIGN_OUT_AUTHORITY: &str = "sense-signout";

/// Event to the session windows when a chat notification was pressed (#62;
/// `session_chat.dart` `kSenseNotifyActivatedEvent`).
pub const NOTIFY_ACTIVATED_EVENT: &str = "sense_notify_activated";

/// Longest title / body handed to the system (the system cuts the rest anyway).
const NOTIFY_TITLE_MAX: usize = 120;
const NOTIFY_BODY_MAX: usize = 240;

/// One recent connection (`main_sense_tray_recent`: `[{peer_id, name, at}]`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Recent {
    pub peer_id: String,
    pub name: String,
    /// Unix seconds.
    pub at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Open,
    Connect(String),
    SignOut,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    Item { id: String, label: String },
    /// Grey, not clickable ("SON BAĞLANTILAR").
    Header(String),
    Separator,
}

/// Whether the role gets the Controller menu (recent connections, sign out). Without a role
/// (not installed) the app is used to connect out, like a Controller.
pub fn controller_menu(role: Option<crate::sense::SenseRole>) -> bool {
    !matches!(role, Some(crate::sense::SenseRole::Host))
}

/// Pure: the menu in order (YH C5, H6).
pub fn menu(controller: bool, recent: &[Recent], now_s: i64) -> Vec<Entry> {
    let mut items = vec![Entry::Item {
        id: ID_OPEN.to_owned(),
        label: OPEN_LABEL.to_owned(),
    }];
    if !controller {
        return items;
    }
    let recent: Vec<&Recent> = recent
        .iter()
        .filter(|r| is_peer_id(&r.peer_id))
        .take(RECENT_MAX)
        .collect();
    if !recent.is_empty() {
        items.push(Entry::Separator);
        items.push(Entry::Header(RECENT_HEADER.to_owned()));
        for r in recent {
            items.push(Entry::Item {
                id: format!("{ID_CONNECT_PREFIX}{}", r.peer_id),
                label: format!("{} · {}", r.name, ago(r.at, now_s)),
            });
        }
    }
    items.push(Entry::Separator);
    items.push(Entry::Item {
        id: ID_SIGN_OUT.to_owned(),
        label: SIGN_OUT_LABEL.to_owned(),
    });
    items
}

/// Pure: what a menu id does. Unknown ids and bad peer ids do nothing.
pub fn action_of(id: &str) -> Option<Action> {
    match id {
        ID_OPEN => Some(Action::Open),
        ID_SIGN_OUT => Some(Action::SignOut),
        _ => id
            .strip_prefix(ID_CONNECT_PREFIX)
            .filter(|peer| is_peer_id(peer))
            .map(|peer| Action::Connect(peer.to_owned())),
    }
}

/// A peer id the tray passes on (`--connect <id>`): RustDesk ids, nothing else (never
/// something that reads as another command-line flag).
pub fn is_peer_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Pure: "az önce", "5 dk önce", "2 sa önce", "dün", "3 gün" (prototype; same as `tray.dart`).
pub fn ago(at: i64, now_s: i64) -> String {
    let s = (now_s - at).max(0);
    if s < 60 {
        "az önce".to_owned()
    } else if s < 3600 {
        format!("{} dk önce", s / 60)
    } else if s < 86_400 {
        format!("{} sa önce", s / 3600)
    } else if s / 86_400 == 1 {
        "dün".to_owned()
    } else {
        format!("{} gün", s / 86_400)
    }
}

/// Local clock, Unix seconds.
pub fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Pure: the tray tooltip (H6), with the app's display name ("Sense Remote").
pub fn tooltip_for(app: &str, connections: usize) -> String {
    if connections == 0 {
        format!("{app} · {READY}")
    } else {
        format!("{app} · {connections} bağlantı")
    }
}

pub fn tooltip(connections: usize) -> String {
    tooltip_for(&crate::common::get_app_display_name(), connections)
}

/// Pure: the Windows tray icon for the taskbar (decision #70): black on a light taskbar, white
/// on a dark one. Names of the files in `res/`.
pub fn tray_icon_file(light_taskbar: bool) -> &'static str {
    if light_taskbar {
        "tray-light.ico"
    } else {
        "tray-dark.ico"
    }
}

/// Windows: whether the taskbar is light (`SystemUsesLightTheme`; the taskbar follows the
/// system theme, not the apps' one). Unreadable: dark, as Windows' default.
#[cfg(windows)]
pub fn taskbar_is_light() -> bool {
    use winreg::{enums::HKEY_CURRENT_USER, RegKey};
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        .and_then(|key| key.get_value::<u32, _>("SystemUsesLightTheme"))
        .map(|value| value != 0)
        .unwrap_or(false)
}

/// The sign-out link the tray hands to the app window.
pub fn sign_out_link() -> String {
    format!("{}{SIGN_OUT_AUTHORITY}", crate::get_uri_prefix())
}

/// The last connections of this user, newest first, from RustDesk's peer files.
pub fn recent(limit: usize) -> Vec<Recent> {
    use hbb_common::config::PeerConfig;
    let all = PeerConfig::get_vec_id_modified_time_path(&None);
    // A few more than shown, so ids the menu does not take do not leave a gap.
    let wanted = (limit * 2).min(all.len());
    if wanted == 0 {
        return vec![];
    }
    let (peers, _) = PeerConfig::batch_peers(&all, 0, Some(wanted));
    peers
        .into_iter()
        .filter(|(id, _, _)| is_peer_id(id))
        .take(limit)
        .map(|(id, modified, peer)| {
            let alias = peer.options.get("alias").map(|a| a.trim().to_owned());
            let name = alias
                .filter(|a| !a.is_empty())
                .or_else(|| Some(peer.info.hostname.trim().to_owned()).filter(|h| !h.is_empty()))
                .unwrap_or_else(|| id.clone());
            let at = modified
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            Recent {
                peer_id: id,
                name,
                at,
            }
        })
        .collect()
}

/// `main_sense_tray_recent`: `[{peer_id, name, at}]`, newest first, at most 3.
pub fn ffi_tray_recent() -> String {
    serde_json::to_string(&recent(RECENT_MAX)).unwrap_or_else(|_| "[]".to_owned())
}

/// Pure: title and body as handed to the system (trimmed, cut at a character boundary).
pub fn notify_text(title: &str, body: &str) -> (String, String) {
    let cut = |s: &str, max: usize| -> String {
        let s = s.trim();
        if s.chars().count() <= max {
            s.to_owned()
        } else {
            let mut out: String = s.chars().take(max - 1).collect();
            out.push('…');
            out
        }
    };
    (cut(title, NOTIFY_TITLE_MAX), cut(body, NOTIFY_BODY_MAX))
}

/// `main_sense_notify`: "" when the system showed the notification, otherwise a code
/// (`empty`, `failed`, `unsupported`); the UI then shows its in-app card.
pub fn ffi_notify(title: &str, body: &str) -> String {
    let (title, body) = notify_text(title, body);
    if title.is_empty() {
        return "empty".to_owned();
    }
    match show_notification(&title, &body) {
        Ok(()) => String::new(),
        Err(code) => code.to_owned(),
    }
}

#[cfg(windows)]
fn show_notification(title: &str, body: &str) -> Result<(), &'static str> {
    use tauri_winrt_notification::{Duration, Sound, Toast};
    let pressed = title.to_owned();
    // Sense Remote: no AppUserModelID of our own is registered yet (installer shortcut), so the
    // PowerShell id is used, as RustDesk does for its install toasts.
    Toast::new(Toast::POWERSHELL_APP_ID)
        .title(title)
        .text1(body)
        .sound(Some(Sound::Default))
        .duration(Duration::Short)
        .on_activated(move || {
            notify_activated(&pressed);
            Ok(())
        })
        .show()
        .map_err(|err| {
            hbb_common::log::warn!("Sense Remote: notification not shown: {err}");
            "failed"
        })
}

#[cfg(target_os = "macos")]
fn show_notification(title: &str, body: &str) -> Result<(), &'static str> {
    use cocoa::{
        base::{id, nil},
        foundation::NSString,
    };
    use objc::{msg_send, runtime::Class, sel, sel_impl};
    // NSUserNotification: no extra permission prompt for the app; a press brings the app
    // forward (the chat opens when its window gets the focus).
    if Class::get("NSUserNotificationCenter").is_none() || Class::get("NSUserNotification").is_none()
    {
        return Err("unsupported");
    }
    let (title, body) = (title.to_owned(), body.to_owned());
    dispatch::Queue::main().exec_async(move || unsafe {
        let (Some(center_class), Some(note_class)) = (
            Class::get("NSUserNotificationCenter"),
            Class::get("NSUserNotification"),
        ) else {
            return;
        };
        let center: id = msg_send![center_class, defaultUserNotificationCenter];
        if center == nil {
            return;
        }
        let note: id = msg_send![note_class, alloc];
        let note: id = msg_send![note, init];
        if note == nil {
            return;
        }
        let title = NSString::alloc(nil).init_str(&title);
        let body = NSString::alloc(nil).init_str(&body);
        let _: () = msg_send![note, setTitle: title];
        let _: () = msg_send![note, setInformativeText: body];
        let _: () = msg_send![center, deliverNotification: note];
        let _: () = msg_send![note, release];
        let _: () = msg_send![title, release];
        let _: () = msg_send![body, release];
    });
    Ok(())
}

#[cfg(not(any(windows, target_os = "macos")))]
fn show_notification(_title: &str, _body: &str) -> Result<(), &'static str> {
    Err("unsupported")
}

/// A notification was pressed: every session window hears it; the one that showed `title`
/// comes forward and opens its chat.
#[cfg_attr(not(windows), allow(dead_code))]
fn notify_activated(title: &str) {
    #[cfg(feature = "flutter")]
    {
        let event = serde_json::json!({ "name": NOTIFY_ACTIVATED_EVENT, "title": title });
        for channel in crate::flutter::get_global_event_channels() {
            if channel.starts_with("remote") {
                crate::flutter::push_global_event(&channel, event.to_string());
            }
        }
    }
    #[cfg(not(feature = "flutter"))]
    let _ = title;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sense::SenseRole;

    const NOW: i64 = 1_795_000_000;

    fn r(id: &str, name: &str, ago_s: i64) -> Recent {
        Recent {
            peer_id: id.to_owned(),
            name: name.to_owned(),
            at: NOW - ago_s,
        }
    }

    fn labels(entries: &[Entry]) -> Vec<String> {
        entries
            .iter()
            .map(|e| match e {
                Entry::Item { label, .. } => label.clone(),
                Entry::Header(h) => format!("[{h}]"),
                Entry::Separator => "--".to_owned(),
            })
            .collect()
    }

    #[test]
    fn host_menu_is_only_open() {
        assert!(!controller_menu(Some(SenseRole::Host)));
        let host = menu(false, &[r("123456789", "Lobi PC", 60)], NOW);
        assert_eq!(labels(&host), vec!["Sense Remote'u aç"]);
        // No "Servisi durdur" in any menu (H6).
        for controller in [false, true] {
            for e in labels(&menu(controller, &[r("1", "A", 0)], NOW)) {
                assert!(!e.to_lowercase().contains("durdur"), "{e}");
                assert!(!e.contains("Stop"), "{e}");
            }
        }
    }

    #[test]
    fn controller_menu_has_recent_and_sign_out() {
        assert!(controller_menu(Some(SenseRole::Controller)));
        assert!(controller_menu(Some(SenseRole::Both)));
        assert!(controller_menu(None));
        let recent = [
            r("111111111", "Giriş Salonu PC-2", 2 * 3600),
            r("222222222", "Lobi", 86_400 + 10),
            r("333333333", "Depo", 3 * 86_400),
            r("444444444", "Fazla", 4 * 86_400),
        ];
        let m = menu(true, &recent, NOW);
        assert_eq!(
            labels(&m),
            vec![
                "Sense Remote'u aç",
                "--",
                "[SON BAĞLANTILAR]",
                "Giriş Salonu PC-2 · 2 sa önce",
                "Lobi · dün",
                "Depo · 3 gün",
                "--",
                "Çıkış yap",
            ]
        );
        // Every item does what it says.
        let actions: Vec<Option<Action>> = m
            .iter()
            .filter_map(|e| match e {
                Entry::Item { id, .. } => Some(action_of(id)),
                _ => None,
            })
            .collect();
        assert_eq!(
            actions,
            vec![
                Some(Action::Open),
                Some(Action::Connect("111111111".to_owned())),
                Some(Action::Connect("222222222".to_owned())),
                Some(Action::Connect("333333333".to_owned())),
                Some(Action::SignOut),
            ]
        );
        // No recent connection: no header.
        assert_eq!(
            labels(&menu(true, &[], NOW)),
            vec!["Sense Remote'u aç", "--", "Çıkış yap"]
        );
    }

    #[test]
    fn only_plain_peer_ids_are_connected() {
        assert_eq!(action_of("sense-connect:"), None);
        assert_eq!(action_of("sense-connect:12 34"), None);
        assert_eq!(action_of("sense-connect:--password"), None);
        assert_eq!(action_of("sense-connect:a/b"), None);
        assert_eq!(action_of("sense-connect:id@evil.example"), None);
        assert_eq!(action_of("something"), None);
        assert!(is_peer_id("123456789"));
        assert!(!is_peer_id(&"9".repeat(65)));
        // A bad id from the peer files is not shown either.
        let m = menu(true, &[r("x y", "Bad", 0)], NOW);
        assert_eq!(labels(&m), vec!["Sense Remote'u aç", "--", "Çıkış yap"]);
    }

    #[test]
    fn ago_labels_match_the_prototype() {
        assert_eq!(ago(NOW, NOW), "az önce");
        assert_eq!(ago(NOW - 59, NOW), "az önce");
        assert_eq!(ago(NOW - 5 * 60, NOW), "5 dk önce");
        assert_eq!(ago(NOW - 2 * 3600, NOW), "2 sa önce");
        assert_eq!(ago(NOW - 86_400, NOW), "dün");
        assert_eq!(ago(NOW - 3 * 86_400, NOW), "3 gün");
        assert_eq!(ago(NOW + 100, NOW), "az önce");
    }

    #[test]
    fn tooltip_uses_the_display_name() {
        assert_eq!(tooltip_for("Sense Remote", 0), "Sense Remote · hazır");
        assert_eq!(tooltip_for("Sense Remote", 2), "Sense Remote · 2 bağlantı");
        assert!(!tooltip(0).contains("SenseRemote ·"));
    }

    #[test]
    fn tray_icon_follows_the_taskbar() {
        assert_eq!(tray_icon_file(true), "tray-light.ico");
        assert_eq!(tray_icon_file(false), "tray-dark.ico");
    }

    #[test]
    fn sign_out_link_is_the_bare_authority() {
        assert!(sign_out_link().ends_with("://sense-signout"));
    }

    #[test]
    fn notify_text_is_trimmed_and_cut() {
        assert_eq!(
            notify_text("  PC · yeni mesaj ", " Sahadaki kişi: merhaba "),
            ("PC · yeni mesaj".to_owned(), "Sahadaki kişi: merhaba".to_owned())
        );
        let (t, b) = notify_text(&"ş".repeat(500), &"ç".repeat(500));
        assert_eq!(t.chars().count(), NOTIFY_TITLE_MAX);
        assert_eq!(b.chars().count(), NOTIFY_BODY_MAX);
        assert!(b.ends_with('…'));
        assert_eq!(ffi_notify("  ", "x"), "empty");
    }

    #[test]
    fn recent_list_is_json() {
        let v: serde_json::Value = serde_json::from_str(&ffi_tray_recent()).unwrap();
        let list = v.as_array().unwrap();
        assert!(list.len() <= RECENT_MAX);
        for item in list {
            assert!(item["peer_id"].is_string() && item["at"].is_i64());
        }
    }
}
