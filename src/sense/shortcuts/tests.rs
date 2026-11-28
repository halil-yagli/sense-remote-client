// Sense Remote (Sürüm 12, FAV-Ç): shortcut catalogue, runner checks and result bodies.
use super::catalog::{self, Action, Os, WinExe};
use super::custom::{self, Entry as CustomEntry};
use super::results::{self, Window};
use super::*;
use crate::sense::health_model::NetAdapter;
use crate::sense::network::SenseNetwork;
use serde_json::json;

const DART_CATALOG: &str =
    include_str!("../../../flutter/lib/sense/screens/session/lists/favorites/catalog.dart");

/// `SenseFavDef('win.taskmgr', _w, _files, …, keys: …)` lines of the Controller's catalogue.
fn dart_entries() -> Vec<(String, String, bool)> {
    let group = |g: &str| match g {
        "_files" => "files",
        "_net" => "network",
        "_adm" => "admin",
        "_set" => "settings",
        "_cmd" => "command",
        "_act" => "actions",
        "_hlt" => "health",
        "_scr" => "screen",
        "_mac" => "mac",
        other => panic!("unknown Dart group {other}"),
    };
    DART_CATALOG
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("SenseFavDef('"))
        .map(|l| {
            let rest = &l["SenseFavDef('".len()..];
            let id = &rest[..rest.find('\'').unwrap()];
            let fields: Vec<&str> = rest.split(',').map(str::trim).collect();
            (id.to_owned(), group(fields[2]).to_owned(), l.contains("keys: SenseFavKeys."))
        })
        .collect()
}

#[test]
fn catalogue_matches_the_controller_list_one_to_one() {
    let dart = dart_entries();
    assert_eq!(dart.len(), catalog::CATALOG.len(), "entry count");
    for (i, (id, cat, keys)) in dart.iter().enumerate() {
        let e = &catalog::CATALOG[i];
        assert_eq!(e.id, id, "order / id at {i}");
        assert_eq!(e.cat, cat, "group of {id}");
        assert_eq!(e.action == Action::Keys, *keys, "keys entry {id}");
    }
    assert_eq!(catalog::of(Os::Win).count(), 45);
    assert_eq!(catalog::of(Os::Mac).count(), 14);
}

#[test]
fn ids_fit_the_panel_and_peer_message_rules() {
    let mut seen = std::collections::HashSet::new();
    for e in catalog::CATALOG {
        assert!(seen.insert(e.id), "duplicate {}", e.id);
        // Panel `CatalogShortcutId`: ^[a-z0-9][a-z0-9_.-]{0,63}$
        assert!(e.id.len() <= 64 && e.id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b)));
        assert!(e.id.starts_with("win.") || e.id.starts_with("mac."));
    }
}

#[test]
fn the_ui_catalogue_has_no_command_or_argument_field() {
    let v: serde_json::Value = serde_json::from_str(&ffi_catalog("win")).unwrap();
    let list = v.as_array().unwrap();
    assert_eq!(list.len(), 45);
    for item in list {
        let mut keys: Vec<&str> = item.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, ["admin", "available", "cat", "id", "kind"]);
    }
    let cad = list.iter().find(|i| i["id"] == "win.cad").unwrap();
    assert_eq!(cad["kind"], "keys");
    let regedit = list.iter().find(|i| i["id"] == "win.regedit").unwrap();
    assert_eq!(regedit["admin"], true);
    let mac: serde_json::Value = serde_json::from_str(&ffi_catalog("mac")).unwrap();
    assert_eq!(mac.as_array().unwrap().len(), 14);
    for os in ["linux", "", "WIN", "any"] {
        assert_eq!(ffi_catalog(os), "[]", "{os}");
    }
}

#[test]
fn windows_command_lines_are_fixed_and_fit_the_launch_buffer() {
    for e in catalog::CATALOG {
        if let Action::Win(cmd) = e.action {
            let exe = format!(r"C:\Windows\{}", cmd.exe.rel_path());
            let line = format!("\"{exe}\" {}", cmd.args);
            // `LaunchProcessWin` copies into MAX_PATH (260 with the NUL); keep a margin for a
            // longer `SystemRoot`.
            assert!(line.encode_utf16().count() < 250, "{} is {} long", e.id, line.len());
            if cmd.exe == WinExe::Cmd && cmd.show {
                assert!(cmd.args.starts_with(r#"/d /c start "" "#), "{}", e.id);
            }
            assert!(!cmd.args.contains('\n'));
        }
    }
}

#[test]
fn only_ping_and_the_window_list_take_an_argument() {
    for e in catalog::CATALOG {
        let takes = e.action.arg() != catalog::ArgUse::None;
        assert_eq!(takes, matches!(e.action, Action::Ping | Action::WindowList), "{}", e.id);
    }
}

#[test]
fn resolve_refuses_what_may_not_run() {
    let w = Some(Os::Win);
    assert!(matches!(resolve("win.taskmgr", None, w), Ok(Resolved::Builtin(e)) if e.id == "win.taskmgr"));
    assert_eq!(resolve("win.nothing", None, w), Err(RunError::UnknownId));
    assert_eq!(resolve("cmd /c del x", None, w), Err(RunError::UnknownId));
    // Another system's entry, keys entries, no catalogue (Linux).
    assert_eq!(resolve("mac.finder", None, w), Err(RunError::UnsupportedOs));
    assert_eq!(resolve("win.taskmgr", None, Some(Os::Mac)), Err(RunError::UnsupportedOs));
    assert_eq!(resolve("win.cad", None, w), Err(RunError::UnsupportedOs));
    assert_eq!(resolve("win.taskmgr", None, None), Err(RunError::UnsupportedOs));
    // Arguments: never for a fixed command; ping needs a clean one.
    assert_eq!(resolve("win.taskmgr", Some("x"), w), Err(RunError::Failed));
    assert_eq!(resolve("win.ping", None, w), Err(RunError::Failed));
    assert_eq!(resolve("win.ping", Some("-t"), w), Err(RunError::Failed));
    assert_eq!(resolve("win.ping", Some("8.8.8.8&calc"), w), Err(RunError::Failed));
    assert!(resolve("win.ping", Some("8.8.8.8"), w).is_ok());
    assert!(resolve("win.ping", Some("router.local"), w).is_ok());
    assert!(resolve("win.killhung", None, w).is_ok());
    assert!(resolve("win.killhung", Some("4242"), w).is_ok());
    assert!(resolve("mac.forcequit", None, Some(Os::Mac)).is_ok());
}

fn custom_entry(id: &str, os: &str, kind: &str, target: &str) -> CustomEntry {
    CustomEntry {
        id: id.to_owned(),
        os: os.to_owned(),
        kind: kind.to_owned(),
        target: target.to_owned(),
    }
}

const CID: &str = "custom:0b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b";
const CID2: &str = "custom:1b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b";

#[test]
fn custom_ids_run_only_from_the_signed_list() {
    custom::set_for_test(vec![]);
    assert_eq!(resolve(CID, None, Some(Os::Win)), Err(RunError::UnknownId));
    custom::set_for_test(vec![
        custom_entry(CID, "win", "program", r"C:\Sergi\oynatici.exe"),
        custom_entry(CID2, "mac", "folder", "/Users/Shared/Sergi"),
    ]);
    assert!(matches!(resolve(CID, None, Some(Os::Win)), Ok(Resolved::Custom(e)) if e.id == CID));
    // On the other system, with an argument, or a near-miss id.
    assert_eq!(resolve(CID, None, Some(Os::Mac)), Err(RunError::UnknownId));
    assert!(matches!(resolve(CID2, None, Some(Os::Mac)), Ok(Resolved::Custom(_))));
    assert_eq!(resolve(CID, Some("x"), Some(Os::Win)), Err(RunError::Failed));
    assert_eq!(resolve("custom:0B6F0C1E-1D2A-4F3B-9A1E-2C3D4E5F6A7B", None, Some(Os::Win)), Err(RunError::UnknownId));
    assert_eq!(resolve(CID, None, None), Err(RunError::UnsupportedOs));
    custom::set_for_test(vec![]);
}

#[test]
fn custom_targets_follow_the_panel_rule() {
    for (os, kind, target) in [
        ("win", "program", r"C:\Program Files\Sergi\app.exe"),
        ("win", "program", r"D:\araclar\kisayol.lnk"),
        ("win", "folder", r"C:\Sergi\Medya"),
        ("mac", "program", "/Applications/Sergi.app"),
        ("mac", "folder", "/Users/Shared"),
        ("win", "url", "https://example.test/durum"),
    ] {
        assert_eq!(custom::target_problem(os, kind, target), None, "{target}");
    }
    for (os, kind, target, why) in [
        ("win", "program", r"C:\app.exe -x", "bad_extension"),
        ("win", "program", r#"C:\app.exe" -x"#, "bad_chars"),
        ("win", "program", r"C:\a\..\b.exe", "not_absolute"),
        ("win", "program", r"app.exe", "not_absolute"),
        ("win", "program", r"C:/a/b.exe", "not_absolute"),
        ("win", "program", r"C:\a|b.exe", "bad_chars"),
        ("win", "folder", " C:\\x", "bad_chars"),
        ("mac", "folder", "Users/x", "not_absolute"),
        ("mac", "program", "/a/../b", "not_absolute"),
        ("win", "url", "http://example.test", "not_https"),
        ("win", "url", "https://exa mple.test", "bad_chars"),
        ("win", "script", r"C:\x.ps1", "bad_kind"),
        ("win", "program", "", "too_long"),
    ] {
        assert_eq!(custom::target_problem(os, kind, target), Some(why), "{target}");
    }
    let long = format!(r"C:\{}.exe", "a".repeat(1100));
    assert_eq!(custom::target_problem("win", "program", &long), Some("too_long"));
}

#[test]
fn envelope_list_rules() {
    let ok = custom_entry(CID, "win", "url", "https://example.test");
    assert!(custom::list_is_valid(&[ok.clone()]));
    assert!(!custom::list_is_valid(&[ok.clone(), ok.clone()]), "duplicate id");
    assert!(!custom::list_is_valid(&[custom_entry("custom:x", "win", "url", "https://e.test")]));
    assert!(!custom::list_is_valid(&[custom_entry(CID, "win", "url", "http://e.test")]));
    assert!(!custom::list_is_valid(&[custom_entry(CID, "android", "url", "https://e.test")]));
    let many: Vec<CustomEntry> = (0..51)
        .map(|i| custom_entry(&format!("custom:0b6f0c1e-1d2a-4f3b-9a1e-{i:012x}"), "win", "url", "https://e.test"))
        .collect();
    assert!(!custom::list_is_valid(&many));
    assert!(custom::list_is_valid(&many[..50]));
    // Strict: an argument field is not a known key.
    let with_args = json!({"id": CID, "os": "win", "kind": "program", "target": r"C:\a.exe", "args": "-x"});
    assert!(serde_json::from_value::<CustomEntry>(with_args).is_err());
}

#[test]
fn ping_output_is_read_in_any_language() {
    let tr = "32 bayt veri ile 8.8.8.8 'e ping atılıyor:\r\n\
8.8.8.8 yanıtı: bayt=32 süre=18ms TTL=117\r\n\
8.8.8.8 yanıtı: bayt=32 süre=19ms TTL=117\r\n\
İstek zaman aşımına uğradı.\r\n\
8.8.8.8 yanıtı: bayt=32 süre=17ms TTL=117\r\n\
\r\n\
8.8.8.8 için Ping istatistiği:\r\n\
    Paket: Giden = 4, Gelen = 3, Kaybolan = 1 (%25 kayıp),\r\n\
Mili saniye türünden yaklaşık tur süreleri:\r\n\
    En Az = 17ms, En Çok = 19ms, Ortalama = 18ms\r\n";
    let p = results::parse_ping(tr, 4);
    assert_eq!((p.received, p.avg_ms, p.loss()), (3, Some(18), 25));
    assert_eq!(p.to_res(), json!({"ping": {"sent": 4, "received": 3, "avg_ms": 18, "loss": 25}}));

    let en = "Reply from 192.168.1.1: bytes=32 time<1ms TTL=64\n".repeat(4);
    let p = results::parse_ping(&en, 4);
    assert_eq!((p.received, p.avg_ms, p.loss()), (4, Some(1), 0));

    let down = "Request timed out.\nReply from 10.0.0.9: Destination host unreachable.\n\
Request timed out.\nRequest timed out.\n    Packets: Sent = 4, Received = 1, Lost = 3 (75% loss),\n";
    let p = results::parse_ping(down, 4);
    assert_eq!(p.to_res(), json!({"ping": {"sent": 4, "received": 0, "avg_ms": null, "loss": 100}}));

    let mac = "PING 8.8.8.8 (8.8.8.8): 56 data bytes\n\
64 bytes from 8.8.8.8: icmp_seq=0 ttl=117 time=18.123 ms\n\
64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=20.877 ms\n\
Request timeout for icmp_seq 2\nRequest timeout for icmp_seq 3\n\n\
--- 8.8.8.8 ping statistics ---\n4 packets transmitted, 2 packets received, 50.0% packet loss\n\
round-trip min/avg/max/stddev = 18.123/19.500/20.877/1.377 ms\n";
    let p = results::parse_ping(mac, 4);
    assert_eq!((p.received, p.avg_ms, p.loss()), (2, Some(20), 50));
    assert_eq!(results::parse_ping("", 4).loss(), 100);
}

#[test]
fn arguments_pass_only_as_a_plain_name_or_number() {
    for ok in ["8.8.8.8", "fe80::1", "router.local", "my-host", "4242"] {
        assert_eq!(results::arg_problem(ok), None, "{ok}");
    }
    for bad in ["", "-t", ".x", "a b", "a&b", "a;b", "a|b", "$(x)", "a/b", "a\\b", "ç.com", "a\"b"] {
        assert!(results::arg_problem(bad).is_some(), "{bad}");
    }
    assert!(results::arg_problem(&"a".repeat(254)).is_some());
    assert_eq!(results::pid_arg("4242"), Some(4242));
    for bad in ["0", "-1", "12a", "", "99999999999"] {
        assert_eq!(results::pid_arg(bad), None, "{bad}");
    }
}

#[test]
fn window_list_puts_hung_first_and_stays_small() {
    let w = |pid, name: &str, hung| Window { pid, name: name.to_owned(), hung };
    let res = results::windows_res(
        vec![
            w(10, "Tarayıcı", false),
            w(11, "Sergi uygulaması", true),
            w(10, "Tarayıcı — ikinci pencere", false),
            w(99, "Sense Remote", false),
            w(12, "  \u{7}  ", false),
            w(0, "Sistem", false),
            w(13, "Medya oynatıcı", false),
        ],
        99,
    );
    assert_eq!(
        res,
        json!({"windows": [
            {"pid": 11, "name": "Sergi uygulaması", "hung": true},
            {"pid": 13, "name": "Medya oynatıcı", "hung": false},
            {"pid": 10, "name": "Tarayıcı", "hung": false},
        ]})
    );
    let long: Vec<Window> = (1..200).map(|i| w(i, &"ğ".repeat(80), false)).collect();
    let res = results::windows_res(long, 0);
    assert!(res.to_string().len() <= results::MAX_RES_BYTES);
    let items = res["windows"].as_array().unwrap();
    assert!(!items.is_empty() && items.len() <= results::MAX_WINDOWS);
    assert!(items[0]["name"].as_str().unwrap().chars().count() == results::MAX_NAME_CHARS + 1);
}

#[test]
fn ip_card_takes_the_first_connected_adapter() {
    let net = |name: &str, kind: &str, ip: &[&str], up| SenseNetwork {
        name: name.to_owned(),
        kind: kind.to_owned(),
        ipv4: ip.iter().map(|s| s.to_string()).collect(),
        ipv6: None,
        up,
    };
    let inv = |name: &str, connected, gw: &[&str], dns: &[&str]| NetAdapter {
        name: name.to_owned(),
        connected: Some(connected),
        gateway: Some(gw.iter().map(|s| s.to_string()).collect()),
        dns: Some(dns.iter().map(|s| s.to_string()).collect()),
        ..Default::default()
    };
    let networks = [
        net("Ethernet", "ethernet", &["192.168.10.42/24"], Some(true)),
        net("Wi-Fi", "wifi", &["10.0.0.5"], Some(true)),
    ];
    let adapters = [
        inv("Ethernet", true, &["192.168.10.1"], &["192.168.10.1", "8.8.8.8"]),
        inv("Wi-Fi", true, &["10.0.0.1"], &[]),
    ];
    assert_eq!(
        results::ip_res(&networks, &adapters),
        json!({"ip": {"ip": "192.168.10.42", "gateway": ["192.168.10.1"], "dns": ["192.168.10.1", "8.8.8.8"]}})
    );
    // Cable out: the next adapter; nothing read: an empty card.
    let unplugged = [inv("Ethernet", false, &[], &[]), adapters[1].clone()];
    assert_eq!(results::ip_res(&networks, &unplugged)["ip"]["ip"], "10.0.0.5");
    assert_eq!(results::ip_res(&[], &[]), json!({"ip": {"ip": null, "gateway": [], "dns": []}}));
}

#[test]
fn mac_app_list_keeps_the_users_top_level_apps() {
    let ps = "  101   501 /Applications/Safari.app/Contents/MacOS/Safari\n\
  102   501 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder\n\
  103   501 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper\n\
  104     0 /Applications/Sergi.app/Contents/MacOS/Sergi\n\
  105   501 /usr/sbin/cfprefsd\n\
  106   501 /Applications/Sergi Oynatıcı.app/Contents/MacOS/Sergi Oynatıcı\n\
  bad line\n";
    let apps = mac_apps(ps, 501);
    assert_eq!(
        apps,
        vec![
            Window { pid: 101, name: "Safari".to_owned(), hung: false },
            Window { pid: 106, name: "Sergi Oynatıcı".to_owned(), hung: false },
        ]
    );
}

#[test]
fn a_run_on_a_host_without_catalogue_answers_and_is_recorded_without_content() {
    // CI runs these tests on Linux: no catalogue there.
    crate::sense::diag::sink::take();
    let job = Job { req: 7, id: "win.ping".to_owned(), arg: Some("8.8.8.8".to_owned()) };
    let msg = run_job(&job);
    let expected_err = if Os::host() == Some(Os::Win) { None } else { Some("unsupported_os".to_owned()) };
    if Os::host().is_none() {
        assert_eq!(
            msg,
            crate::sense::peer_msg::PeerMsg::ShortcutResult { req: 7, ok: false, err: expected_err, res: None }
        );
    }
    let unknown = run_job(&Job { req: 8, id: "win.nothing".to_owned(), arg: None });
    assert_eq!(
        unknown,
        crate::sense::peer_msg::PeerMsg::ShortcutResult {
            req: 8,
            ok: false,
            err: Some("unknown_id".to_owned()),
            res: None
        }
    );
    let got = crate::sense::diag::sink::take();
    assert!(got.iter().any(|(c, k)| c == "shortcut" && k == "run"));
}
