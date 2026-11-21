//! Sense Remote (update plan 2026-11-21, package U4): tests of `daemon_mac`.

use super::*;
use crate::sense::{update::SignKind, SenseRole};
use serde_json::json;

fn ctx() -> DaemonCtx<'static> {
    DaemonCtx {
        panel_keys: &[],
        build_keys: &[],
        iss: "panel.example",
        api_server: "https://panel.example",
        platform: Some(manifest::PLATFORM_MACOS),
        did: "123456789",
        duuid: "dXVpZA",
        now_s: 1_795_000_000,
        installed: 3,
    }
}

const OID: &str = "upd_0123456789abcdef";

fn offer(release: &str, order: Option<&str>) -> SenseUpdateIpc {
    SenseUpdateIpc::Offer {
        release: release.to_owned(),
        order: order.map(str::to_owned),
        hint_release: Some(4),
        hint_oid: Some(OID.to_owned()),
    }
}

// Plan §11.1 U4: a broken release or order from the agent changes nothing.
#[test]
fn broken_offer_changes_nothing() {
    let forged = json!({ "k": "0000000000000000", "p": "e30", "s": "AAAA" }).to_string();
    for (release, order) in [
        ("not json", None),
        ("{}", Some("{")),
        (forged.as_str(), Some(forged.as_str())),
        ("", Some(forged.as_str())),
    ] {
        let mut held = Held::default();
        let events = handle(&offer(release, order), true, &ctx(), &mut held).unwrap();
        assert_eq!(held, Held::default(), "{release} {order:?}");
        for event in &events {
            match event {
                Event::Release(result) => assert!(result.is_err()),
                Event::Order(result) => assert!(result.is_err()),
                Event::Hint(hint) => assert_eq!(hint.release, Some(4)),
                other => panic!("unexpected {other:?}"),
            }
        }
        let expected = usize::from(!release.is_empty()) + usize::from(order.is_some()) + 1;
        assert_eq!(events.len(), expected);
    }
    let mut held = Held::default();
    let events = handle(&offer("not json", None), true, &ctx(), &mut held).unwrap();
    assert_eq!(events[0], Event::Release(Err(Reason::Malformed)));
}

#[test]
fn offer_limits() {
    let mut held = Held::default();
    let big = "x".repeat(MAX_OFFER_BYTES + 1);
    assert_eq!(handle(&offer(&big, None), true, &ctx(), &mut held), Some(vec![]));
    let half = "x".repeat(MAX_OFFER_BYTES / 2 + 1);
    assert_eq!(
        handle(&offer(&half, Some(&half)), true, &ctx(), &mut held),
        Some(vec![])
    );
    // A build the panel does not know takes nothing.
    let mut unknown = ctx();
    unknown.platform = None;
    assert_eq!(handle(&offer("{}", None), true, &unknown, &mut held), Some(vec![]));
    // A call that came too soon: no answer, nothing.
    assert_eq!(handle(&offer("{}", None), false, &ctx(), &mut held), None);
    assert_eq!(handle(&SenseUpdateIpc::StatusQuery, false, &ctx(), &mut held), None);
}

#[test]
fn bad_hints_are_dropped() {
    for (release, oid) in [(Some(0), None), (Some(1_000_000), None), (None, Some("upd_x"))] {
        let message = SenseUpdateIpc::Offer {
            release: String::new(),
            order: None,
            hint_release: release,
            hint_oid: oid.map(str::to_owned),
        };
        let mut held = Held::default();
        assert_eq!(handle(&message, true, &ctx(), &mut held), Some(vec![]));
    }
    let message = SenseUpdateIpc::Offer {
        release: String::new(),
        order: None,
        hint_release: None,
        hint_oid: None,
    };
    assert_eq!(
        handle(&message, true, &ctx(), &mut Held::default()),
        Some(vec![Event::Hint(Hint { release: None, oid: None })])
    );
}

#[test]
fn install_only_for_the_held_newer_release() {
    let mut held = Held::default();
    let install = |version| SenseUpdateIpc::Install { version };
    // Nothing held: a local process can not start anything.
    assert_eq!(handle(&install(4), true, &ctx(), &mut held), Some(vec![]));
    held.release = Some(release(4));
    assert_eq!(
        handle(&install(4), true, &ctx(), &mut held),
        Some(vec![Event::InstallRequested { version: 4 }])
    );
    assert_eq!(handle(&install(5), true, &ctx(), &mut held), Some(vec![]));
    let mut current = ctx();
    current.installed = 4;
    assert_eq!(handle(&install(4), true, &current, &mut held), Some(vec![]));
    assert_eq!(handle(&install(4), false, &ctx(), &mut held), None);
}

#[test]
fn only_the_three_service_messages_are_taken() {
    let mut held = Held::default();
    assert_eq!(handle(&SenseUpdateIpc::StatusQuery, true, &ctx(), &mut held), Some(vec![]));
    for other in [
        SenseUpdateIpc::Status("{}".to_owned()),
        SenseUpdateIpc::InstallRequest { version: 4 },
        SenseUpdateIpc::DaemonStatus("{}".to_owned()),
    ] {
        assert_eq!(handle(&other, true, &ctx(), &mut held), None, "{other:?}");
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
fn other_platforms_answer_nothing() {
    assert_eq!(on_service_ipc(offer("{}", None), Some(1)), None);
    assert_eq!(on_service_ipc(SenseUpdateIpc::Install { version: 4 }, None), None);
    assert_eq!(on_service_ipc(SenseUpdateIpc::StatusQuery, None), None);
}

#[test]
fn status_from_state_and_record() {
    let mut state = engine::State::default();
    state.phase = crate::sense::update::UpdateState::Downloading;
    state.release = Some(release(4));
    state.progress_pct = Some(40);
    state.error_detail = Some("Not-A-Detail".to_owned());
    let stored: Persisted = serde_json::from_value(json!({
        "state": "rolled_back", "target": 4, "from": 3, "started_at": 1_795_000_000_i64,
        "last_error": "health_timeout",
    }))
    .unwrap();
    let status = gui_status(&state, 3, Some(1_795_000_100), true, Some(&stored));
    assert_eq!(status.target, Some(4));
    assert_eq!(status.progress_pct, Some(40));
    assert_eq!(status.error_detail, None);
    assert!(status.mac_permission_warning);
    assert_eq!(
        status.notes_url.as_deref(),
        Some("https://panel.example/#surum-4")
    );
    let last = status.last_result.unwrap();
    assert_eq!((last.from, last.to, last.at), (3, 4, 1_795_000_000));
    assert_eq!(last.state, crate::sense::update::UpdateState::RolledBack);
    let installing: Persisted = serde_json::from_value(json!({
        "state": "installing", "target": 4, "from": 3, "started_at": 1,
    }))
    .unwrap();
    assert_eq!(last_result(&installing), None);
}

#[test]
fn permission_warning_for_mac_hosts_without_the_certificate() {
    assert!(permission_warning(Some(SenseRole::Host), SignKind::Adhoc));
    assert!(permission_warning(Some(SenseRole::Both), SignKind::Unknown));
    assert!(!permission_warning(Some(SenseRole::Host), SignKind::Cert));
    assert!(!permission_warning(Some(SenseRole::Controller), SignKind::Adhoc));
    assert!(!permission_warning(None, SignKind::Adhoc));
}

fn release(version: u32) -> Release {
    Release {
        k: "0000000000000000".to_owned(),
        version,
        platform: manifest::PLATFORM_MACOS.to_owned(),
        file: format!("SenseRemote-{version}.dmg"),
        url: format!("https://panel.example/indir/SenseRemote-{version}.dmg"),
        sha256: "00".repeat(32),
        size: 1,
        notes_url: Some(format!("https://panel.example/#surum-{version}")),
        published_at: 1,
        iat: 1,
        exp: 2,
        build: manifest::BuildStatement {
            k: "0000000000000000".to_owned(),
            version,
            platform: manifest::PLATFORM_MACOS.to_owned(),
            file: format!("SenseRemote-{version}.dmg"),
            sha256: "00".repeat(32),
            size: 1,
            commit: "0".repeat(40),
            run_id: 1,
            iat: 1,
        },
    }
}
