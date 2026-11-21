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

fn offer_events_of(call: Option<Call>) -> Vec<Event> {
    match call {
        Some(Call::Offer(events)) => events,
        other => panic!("not an offer: {other:?}"),
    }
}

// Plan §11.1 U4: a broken release or order from the agent gives the engine nothing but the
// rejection; no verified release or order comes out of it.
#[test]
fn broken_offer_changes_nothing() {
    let forged = json!({ "k": "0000000000000000", "p": "e30", "s": "AAAA" }).to_string();
    for (release, order) in [
        ("not json", None),
        ("{}", Some("{")),
        (forged.as_str(), Some(forged.as_str())),
        ("", Some(forged.as_str())),
    ] {
        let events = offer_events_of(classify(&offer(release, order), true, &ctx(), None));
        for event in &events {
            match event {
                Event::Release(result) => assert!(result.is_err(), "{release}"),
                Event::Order(result) => assert!(result.is_err(), "{order:?}"),
                Event::Hint(hint) => assert_eq!(hint.release, Some(4)),
                other => panic!("unexpected {other:?}"),
            }
        }
        let expected = usize::from(!release.is_empty()) + usize::from(order.is_some()) + 1;
        assert_eq!(events.len(), expected);
    }
    let events = offer_events_of(classify(&offer("not json", None), true, &ctx(), None));
    assert_eq!(events[0], Event::Release(Err(Reason::Malformed)));
}

#[test]
fn offer_limits() {
    let big = "x".repeat(MAX_OFFER_BYTES + 1);
    assert_eq!(classify(&offer(&big, None), true, &ctx(), None), Some(Call::Offer(vec![])));
    let half = "x".repeat(MAX_OFFER_BYTES / 2 + 1);
    assert_eq!(
        classify(&offer(&half, Some(&half)), true, &ctx(), None),
        Some(Call::Offer(vec![]))
    );
    // A build the panel does not know takes nothing.
    let mut unknown = ctx();
    unknown.platform = None;
    assert_eq!(classify(&offer("{}", None), true, &unknown, None), Some(Call::Offer(vec![])));
    // A call above the limit: no answer, nothing.
    assert_eq!(classify(&offer("{}", None), false, &ctx(), None), None);
    assert_eq!(classify(&SenseUpdateIpc::StatusQuery, false, &ctx(), None), None);
    assert_eq!(classify(&SenseUpdateIpc::Install { version: 4 }, false, &ctx(), None), None);
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
        assert_eq!(classify(&message, true, &ctx(), None), Some(Call::Offer(vec![])));
    }
    let message = SenseUpdateIpc::Offer {
        release: String::new(),
        order: None,
        hint_release: None,
        hint_oid: None,
    };
    assert_eq!(
        classify(&message, true, &ctx(), None),
        Some(Call::Offer(vec![Event::Hint(Hint { release: None, oid: None })]))
    );
}

#[test]
fn only_the_three_service_messages_are_taken() {
    assert_eq!(classify(&SenseUpdateIpc::StatusQuery, true, &ctx(), None), Some(Call::Status));
    assert_eq!(
        classify(&SenseUpdateIpc::Install { version: 4 }, true, &ctx(), None),
        Some(Call::Install(4))
    );
    for other in [
        SenseUpdateIpc::Status("{}".to_owned()),
        SenseUpdateIpc::InstallRequest { version: 4 },
        SenseUpdateIpc::InstallAnswer(String::new()),
        SenseUpdateIpc::DaemonStatus("{}".to_owned()),
    ] {
        assert_eq!(classify(&other, true, &ctx(), None), None, "{other:?}");
    }
}

#[test]
fn limiter_per_process_and_per_user() {
    let mut limiter = PeerLimiter::default();
    // One call per process per interval; a new connection of the same process does not help.
    assert!(limiter.allow(Some(10), Some(501), 0));
    assert!(!limiter.allow(Some(10), Some(501), 10));
    // New processes of the same user: together at most MAX_CALLS_PER_UID.
    assert!(limiter.allow(Some(11), Some(501), 20));
    assert!(limiter.allow(Some(12), Some(501), 30));
    assert!(!limiter.allow(Some(13), Some(501), 40));
    // Another user is not starved by that.
    assert!(limiter.allow(Some(20), Some(502), 50));
    // Next interval: everything again.
    assert!(limiter.allow(Some(13), Some(501), MIN_CALL_INTERVAL_MS));
    assert!(limiter.allow(Some(10), Some(501), MIN_CALL_INTERVAL_MS + 1));
    // No readable pid / uid: one shared slot.
    let mut limiter = PeerLimiter::default();
    assert!(limiter.allow(None, None, 0));
    assert!(!limiter.allow(None, None, 1));
}

#[test]
fn limiter_tracks_a_bounded_number_of_peers() {
    let mut limiter = PeerLimiter::default();
    for pid in 0..MAX_LIMITED_PEERS as u32 {
        assert!(limiter.allow(Some(pid), Some(1000 + pid), 0));
    }
    assert!(!limiter.allow(Some(9999), Some(9999), 1));
    assert!(limiter.allow(Some(9999), Some(9999), MIN_CALL_INTERVAL_MS));
}

#[cfg(not(target_os = "macos"))]
#[test]
fn other_platforms_answer_nothing() {
    assert_eq!(on_service_ipc(offer("{}", None), Some(1), Some(501)), None);
    assert_eq!(on_service_ipc(SenseUpdateIpc::Install { version: 4 }, None, None), None);
    assert_eq!(on_service_ipc(SenseUpdateIpc::StatusQuery, None, None), None);
}

#[test]
fn permission_warning_for_mac_hosts_without_the_certificate() {
    assert!(permission_warning(Some(SenseRole::Host), SignKind::Adhoc));
    assert!(permission_warning(Some(SenseRole::Both), SignKind::Unknown));
    assert!(!permission_warning(Some(SenseRole::Host), SignKind::Cert));
    assert!(!permission_warning(Some(SenseRole::Controller), SignKind::Adhoc));
    assert!(!permission_warning(None, SignKind::Adhoc));
    let status = with_warning(GuiStatus::idle(3), true);
    assert!(status.mac_permission_warning);
}

// The agent reads back what the daemon sends for the heartbeat.
#[test]
fn heartbeat_status_survives_the_channel() {
    let status = UpdateStatus {
        state: crate::sense::update::UpdateState::Available,
        target: Some(4),
        from: None,
        source: None,
        oid: None,
        progress_pct: None,
        error: None,
        error_detail: None,
        attempts: None,
        have: Some(crate::sense::update::Have {
            release: Some(4),
            release_exp: Some(1_795_600_000),
            oid: None,
        }),
        sign: Some(SignKind::Adhoc),
        at: 1_795_000_000,
    };
    let text = serde_json::to_string(&status).unwrap();
    assert_eq!(serde_json::from_str::<UpdateStatus>(&text).unwrap(), status);
}
