// Sense Remote (update plan 2026-11-21, §3.6): tests of the update state machine (`engine.rs`).
use super::*;
use crate::sense::update::manifest::{BuildStatement, PLATFORM_WINDOWS};

const NOW: i64 = 1_795_000_000;
const OID: &str = "upd_0123456789abcdef";
const OID2: &str = "upd_fedcba9876543210";

fn release(version: u32) -> Release {
    let sha256 = format!("{version:064x}");
    let file = format!("SenseRemote-Kurulum-{version}.exe");
    Release {
        k: "0011223344556677".to_owned(),
        version,
        platform: PLATFORM_WINDOWS.to_owned(),
        file: file.clone(),
        url: format!("https://panel.example/indir/{file}"),
        sha256: sha256.clone(),
        size: 1000,
        notes_url: Some(format!("https://panel.example/#surum-{version}")),
        published_at: NOW - 60,
        iat: NOW - 60,
        exp: NOW + 7 * 86_400,
        build: BuildStatement {
            k: "8899aabbccddeeff".to_owned(),
            version,
            platform: PLATFORM_WINDOWS.to_owned(),
            file,
            sha256,
            size: 1000,
            commit: "0".repeat(40),
            run_id: 1,
            iat: NOW - 600,
        },
    }
}

fn order(oid: &str, version: u32, window: Window) -> Order {
    Order {
        k: "0011223344556677".to_owned(),
        oid: oid.to_owned(),
        version,
        platform: PLATFORM_WINDOWS.to_owned(),
        sha256: format!("{version:064x}"),
        window,
        iat: NOW - 60,
        exp: NOW + 2 * 86_400,
    }
}

/// Idle for long, at noon, plenty of disk, no delay.
fn ctx() -> Ctx {
    Ctx {
        now_s: NOW,
        local_hour: 12,
        installed: 3,
        idle_s: 3600,
        free_bytes: Some(1 << 40),
        jitter_s: 0,
    }
}

fn run(state: State, events: Vec<Event>, ctx: &Ctx) -> (State, Vec<Action>) {
    let mut state = state;
    let mut all = Vec::new();
    for event in events {
        let (next_state, actions) = next(state, event, ctx);
        state = next_state;
        all.extend(actions);
    }
    (state, all)
}

fn available(version: u32) -> State {
    next(State::default(), Event::Release(Ok(release(version))), &ctx()).0
}

fn hint(release: Option<u32>, oid: Option<&str>) -> Event {
    Event::Hint(Hint {
        release,
        oid: oid.map(str::to_owned),
    })
}

fn drop_of(version: u32) -> Action {
    Action::DropFile {
        file: format!("SenseRemote-Kurulum-{version}.exe"),
    }
}

#[test]
fn a_newer_release_makes_available_and_an_older_one_is_ignored() {
    let (state, actions) = next(State::default(), Event::Release(Ok(release(4))), &ctx());
    assert_eq!(state.phase, UpdateState::Available);
    assert_eq!(state.target_version(), Some(4));
    assert_eq!(actions, vec![Action::Persist]);
    for version in [2, 3] {
        let (same, actions) =
            next(State::default(), Event::Release(Ok(release(version))), &ctx());
        assert_eq!(same, State::default(), "{version}");
        assert!(actions.is_empty());
    }
}

#[test]
fn the_unsigned_hint_alone_never_offers_a_version() {
    let (state, actions) = next(State::default(), hint(Some(9), Some(OID)), &ctx());
    assert_eq!(state.phase, UpdateState::Idle);
    assert_eq!(state.target_version(), None);
    assert_eq!(state.gui_status(3, None).target, None);
    assert!(actions.is_empty());
}

#[test]
fn a_refused_notice_or_order_only_sets_the_error() {
    let held = available(4);
    let (state, _) = next(held.clone(), Event::Release(Err(Reason::BadSignature)), &ctx());
    assert_eq!(state.phase, UpdateState::Available);
    assert_eq!(state.release, held.release);
    assert_eq!(state.error, Some(UpdateError::ManifestInvalid));
    assert_eq!(state.error_detail.as_deref(), Some("bad_signature"));
    let (state, _) = next(held, Event::Order(Err(Reason::ReleaseMismatch)), &ctx());
    assert_eq!(state.error, Some(UpdateError::OrderInvalid));
    assert_eq!(state.error_detail.as_deref(), Some("release_mismatch"));
    assert_eq!(state.order, None);
    let status = state.status(NOW, None);
    assert_eq!(status.error_detail.as_deref(), Some("release_mismatch"));
}

#[test]
fn local_request_downloads_at_once_when_idle() {
    let (state, actions) = next(available(4), Event::InstallRequested { version: 4 }, &ctx());
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(state.source, Some(UpdateSource::Local));
    assert_eq!(state.attempts, 1);
    assert_eq!(actions, vec![Action::Persist, Action::Download]);
}

#[test]
fn install_request_answers() {
    let c = ctx();
    assert_eq!(check_install(&State::default(), 4, &c), Err(NO_RELEASE));
    assert_eq!(check_install(&available(4), 5, &c), Err(NO_RELEASE));
    assert_eq!(check_install(&available(4), 4, &c), Ok(()));
    let newer_installed = Ctx { installed: 4, ..c };
    assert_eq!(check_install(&available(4), 4, &newer_installed), Err(NOT_NEWER));
    let (downloading, _) = next(available(4), Event::InstallRequested { version: 4 }, &c);
    assert_eq!(check_install(&downloading, 4, &c), Err(BUSY));
    // A refused request changes nothing.
    let (same, actions) = next(available(4), Event::InstallRequested { version: 5 }, &c);
    assert_eq!(same, available(4));
    assert!(actions.is_empty());
}

#[test]
fn panel_order_waits_its_random_delay() {
    let delayed = Ctx { jitter_s: 600, ..ctx() };
    let (state, actions) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &delayed);
    assert_eq!(state.phase, UpdateState::Scheduled);
    assert_eq!(state.source, Some(UpdateSource::Panel));
    assert_eq!(state.not_before_s, Some(NOW + 600));
    assert_eq!(actions, vec![Action::Persist]);
    let early = Ctx { now_s: NOW + 599, ..ctx() };
    let (state, actions) = next(state, Event::Tick, &early);
    assert_eq!(state.phase, UpdateState::Scheduled);
    assert!(actions.is_empty());
    let late = Ctx { now_s: NOW + 600, ..ctx() };
    let (state, actions) = next(state, Event::Tick, &late);
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(actions, vec![Action::Persist, Action::Download]);
    // The delay is never longer than 15 minutes.
    let huge = Ctx { jitter_s: u64::MAX, ..ctx() };
    let (state, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &huge);
    assert_eq!(state.not_before_s, Some(NOW + 900));
}

#[test]
fn an_order_for_another_file_is_not_taken() {
    let mut other = order(OID, 4, Window::Idle);
    other.sha256 = "f".repeat(64);
    let (state, actions) = next(available(4), Event::Order(Ok(other)), &ctx());
    assert_eq!(state, available(4));
    assert!(actions.is_empty());
    let (state, _) = next(State::default(), Event::Order(Ok(order(OID, 4, Window::Idle))), &ctx());
    assert_eq!(state, State::default());
}

#[test]
fn never_during_a_connection_and_only_after_120_s_idle() {
    for idle_s in [0, 119] {
        let busy = Ctx { idle_s, ..ctx() };
        let (state, actions) = next(available(4), Event::InstallRequested { version: 4 }, &busy);
        assert_eq!(state.phase, UpdateState::WaitingIdle, "{idle_s}");
        assert_eq!(state.blocked, Some(Blocked::SessionActive));
        assert_eq!(state.gui_status(3, None).blocked, Some(Blocked::SessionActive));
        assert_eq!(actions, vec![Action::Persist]);
        let (state, actions) = next(state, Event::Tick, &busy);
        assert_eq!(state.phase, UpdateState::WaitingIdle);
        assert!(actions.is_empty());
    }
    let idle = Ctx { idle_s: 120, ..ctx() };
    let busy = Ctx { idle_s: 0, ..ctx() };
    let (waiting, _) = next(available(4), Event::InstallRequested { version: 4 }, &busy);
    let (state, actions) = next(waiting, Event::Tick, &idle);
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(actions, vec![Action::Persist, Action::Download]);
}

#[test]
fn night_window_waits_for_03_to_05() {
    let (state, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Night))), &ctx());
    assert_eq!(state.phase, UpdateState::WaitingIdle);
    assert_eq!(state.blocked, Some(Blocked::NightWindow));
    for hour in [0, 2, 5, 23] {
        let c = Ctx { local_hour: hour, ..ctx() };
        assert_eq!(next(state.clone(), Event::Tick, &c).0.phase, UpdateState::WaitingIdle);
    }
    for hour in [3, 4] {
        let c = Ctx { local_hour: hour, ..ctx() };
        assert_eq!(next(state.clone(), Event::Tick, &c).0.phase, UpdateState::Downloading);
    }
    // At night but with a connection: still waiting, for the connection.
    let c = Ctx { local_hour: 3, idle_s: 10, ..ctx() };
    let (busy, _) = next(state, Event::Tick, &c);
    assert_eq!(busy.blocked, Some(Blocked::SessionActive));
}

#[test]
fn local_request_skips_the_delay_but_keeps_the_panels_night_window() {
    let delayed = Ctx { jitter_s: 900, ..ctx() };
    let (ordered, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Night))), &delayed);
    let (state, actions) = next(ordered, Event::InstallRequested { version: 4 }, &ctx());
    assert_eq!(state.phase, UpdateState::WaitingIdle);
    assert_eq!(state.blocked, Some(Blocked::NightWindow));
    assert_eq!(state.source, Some(UpdateSource::Local));
    assert!(!actions.contains(&Action::Download));
    let night = Ctx { local_hour: 3, ..ctx() };
    let (state, actions) = next(state, Event::Tick, &night);
    assert_eq!(state.phase, UpdateState::Downloading);
    assert!(actions.contains(&Action::Download));
    // An `idle` order: the local request starts at once, without the delay.
    let (ordered, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &delayed);
    let (state, _) = next(ordered, Event::InstallRequested { version: 4 }, &ctx());
    assert_eq!(state.phase, UpdateState::Downloading);
    // A night order arriving while a local request waits keeps the night window too.
    let busy = Ctx { idle_s: 0, ..ctx() };
    let (waiting, _) = next(available(4), Event::InstallRequested { version: 4 }, &busy);
    let (state, _) = next(waiting, Event::Order(Ok(order(OID, 4, Window::Night))), &ctx());
    assert_eq!(state.source, Some(UpdateSource::Local));
    let (state, _) = next(state, Event::Tick, &ctx());
    assert_eq!(state.blocked, Some(Blocked::NightWindow));
}

#[test]
fn an_older_notice_never_replaces_a_newer_one() {
    let held = available(5);
    let (state, actions) = next(held.clone(), Event::Release(Ok(release(4))), &ctx());
    assert_eq!(state, held);
    assert!(actions.is_empty());
    let (ordered, _) = next(held, Event::Order(Ok(order(OID, 5, Window::Night))), &ctx());
    let (state, _) = next(ordered.clone(), Event::Release(Ok(release(4))), &ctx());
    assert_eq!(state, ordered);
}

#[test]
fn full_path_to_installing() {
    let (state, actions) = run(
        available(4),
        vec![
            Event::InstallRequested { version: 4 },
            Event::DownloadProgress(40),
        ],
        &ctx(),
    );
    assert_eq!(state.status(NOW, None).progress_pct, Some(40));
    assert_eq!(actions, vec![Action::Persist, Action::Download]);
    let (state, actions) = next(state, Event::Downloaded, &ctx());
    assert_eq!(state.phase, UpdateState::Verifying);
    assert!(state.downloaded);
    assert_eq!(actions, vec![Action::Persist, Action::Verify]);
    let (state, actions) = next(state, Event::Verified, &ctx());
    assert_eq!(state.phase, UpdateState::Installing);
    assert_eq!(actions, vec![Action::Persist, Action::Install]);
}

#[test]
fn connection_after_the_download_goes_back_to_scheduled_and_keeps_the_file() {
    let (verifying, _) = run(
        available(4),
        vec![Event::InstallRequested { version: 4 }, Event::Downloaded],
        &ctx(),
    );
    let busy = Ctx { idle_s: 5, ..ctx() };
    let (state, actions) = next(verifying.clone(), Event::Verified, &busy);
    assert_eq!(state.phase, UpdateState::Scheduled);
    assert!(state.downloaded);
    assert!(!actions.iter().any(|a| matches!(a, Action::DropFile { .. } | Action::Install)));
    // The installer refusing because a connection just started is the same.
    let (installing, _) = next(verifying, Event::Verified, &ctx());
    let (state2, actions) = next(installing, Event::Failed(UpdateError::Busy), &ctx());
    assert_eq!(state2.phase, UpdateState::Scheduled);
    assert!(state2.downloaded);
    assert!(!actions.iter().any(|a| matches!(a, Action::DropFile { .. })));
    // Idle again: verified once more, not downloaded again, no new attempt.
    let (state, actions) = next(state, Event::Tick, &ctx());
    assert_eq!(state.phase, UpdateState::Verifying);
    assert_eq!(state.attempts, 1);
    assert_eq!(actions, vec![Action::Persist, Action::Verify]);
}

#[test]
fn not_enough_disk_fails_the_attempt() {
    for free_bytes in [None, Some(2999)] {
        let small = Ctx { free_bytes, ..ctx() };
        let (state, actions) = next(available(4), Event::InstallRequested { version: 4 }, &small);
        assert_eq!(state.phase, UpdateState::Available);
        assert_eq!(state.error, Some(UpdateError::DiskSpace));
        assert!(!actions.contains(&Action::Download));
    }
    let exact = Ctx { free_bytes: Some(3000), ..ctx() };
    let (state, _) = next(available(4), Event::InstallRequested { version: 4 }, &exact);
    assert_eq!(state.phase, UpdateState::Downloading);
}

#[test]
fn three_attempts_with_growing_waits_then_failed() {
    let (mut state, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &ctx());
    let mut now = NOW;
    for (attempt, wait) in [(1u8, 1800i64), (2, 7200)] {
        let c = Ctx { now_s: now, ..ctx() };
        assert_eq!(state.phase, UpdateState::Downloading);
        assert_eq!(state.attempts, attempt);
        let (failed, _) = next(state, Event::Failed(UpdateError::HashMismatch), &c);
        assert_eq!(failed.phase, UpdateState::Available);
        assert_eq!(failed.error, Some(UpdateError::HashMismatch));
        assert_eq!(failed.not_before_s, Some(now + wait));
        let before = Ctx { now_s: now + wait - 1, ..ctx() };
        let (waiting, actions) = next(failed, Event::Tick, &before);
        assert_eq!(waiting.phase, UpdateState::Available);
        assert!(actions.is_empty());
        now += wait;
        let after = Ctx { now_s: now, ..ctx() };
        state = next(waiting, Event::Tick, &after).0;
    }
    assert_eq!(state.attempts, 3);
    let c = Ctx { now_s: now, ..ctx() };
    let (failed, _) = next(state, Event::Failed(UpdateError::DownloadFailed), &c);
    assert_eq!(failed.phase, UpdateState::Failed);
    let later = Ctx { now_s: now + 86_400, ..ctx() };
    assert_eq!(next(failed.clone(), Event::Tick, &later).0.phase, UpdateState::Failed);
    // Within 24 h of the first attempt the user can not start a fourth.
    assert_eq!(check_install(&failed, 4, &c), Err(BUSY));
    let day_after = Ctx { now_s: NOW + ATTEMPT_PERIOD_S, ..ctx() };
    assert_eq!(check_install(&failed, 4, &day_after), Ok(()));
    // "Tekrar dene" in the panel: a new oid starts the counter again.
    let (retry, _) = next(failed, Event::Order(Ok(order(OID2, 4, Window::Idle))), &c);
    assert_eq!(retry.phase, UpdateState::Downloading);
    assert_eq!(retry.attempts, 1);
}

#[test]
fn failed_verification_drops_the_file() {
    let (verifying, _) = run(
        available(4),
        vec![Event::InstallRequested { version: 4 }, Event::Downloaded],
        &ctx(),
    );
    let (state, actions) = next(verifying, Event::Failed(UpdateError::HashMismatch), &ctx());
    assert!(!state.downloaded);
    assert!(actions.contains(&drop_of(4)));
}

#[test]
fn two_null_hints_in_a_row_drop_available() {
    let (state, _) = next(available(4), hint(None, None), &ctx());
    assert_eq!(state.phase, UpdateState::Available);
    let (state, _) = next(state, hint(Some(4), None), &ctx());
    let (state, _) = next(state, hint(None, None), &ctx());
    assert_eq!(state.phase, UpdateState::Available, "the counter restarts");
    let (state, actions) = next(state, hint(None, None), &ctx());
    assert_eq!(state.phase, UpdateState::Idle);
    assert_eq!(state.release, None);
    assert_eq!(actions, vec![Action::Persist]);
}

#[test]
fn hint_cancels_the_order_only_before_the_download() {
    let delayed = Ctx { jitter_s: 300, ..ctx() };
    let (scheduled, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &delayed);
    // The same oid keeps it.
    let (kept, _) = next(scheduled.clone(), hint(Some(4), Some(OID)), &ctx());
    assert_eq!(kept.phase, UpdateState::Scheduled);
    for other in [None, Some(OID2)] {
        let (state, _) = next(scheduled.clone(), hint(Some(4), other), &ctx());
        assert_eq!(state.phase, UpdateState::Available, "{other:?}");
        assert_eq!(state.order, None);
        assert_eq!(state.source, None);
        assert!(state.release.is_some());
    }
    // Once downloading, a cancel has no effect; neither has the release going away.
    let (downloading, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &ctx());
    assert_eq!(downloading.phase, UpdateState::Downloading);
    let (state, actions) = run(
        downloading.clone(),
        vec![hint(None, None), hint(None, None), Event::Release(Ok(release(5)))],
        &ctx(),
    );
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(state.order, downloading.order);
    assert_eq!(state.target_version(), Some(4));
    assert!(actions.is_empty());
}

#[test]
fn cancel_of_a_waiting_order_drops_the_kept_file() {
    let busy = Ctx { idle_s: 0, ..ctx() };
    let (scheduled, _) = run(
        available(4),
        vec![
            Event::Order(Ok(order(OID, 4, Window::Idle))),
            Event::Downloaded,
        ],
        &ctx(),
    );
    let (waiting, _) = next(scheduled, Event::Verified, &busy);
    assert!(waiting.downloaded);
    let (state, actions) = next(waiting, hint(Some(4), None), &ctx());
    assert_eq!(state.phase, UpdateState::Available);
    assert!(!state.downloaded);
    assert!(actions.contains(&drop_of(4)));
}

#[test]
fn a_newer_release_replaces_the_waiting_one() {
    let busy = Ctx { idle_s: 0, ..ctx() };
    let (waiting, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &busy);
    assert_eq!(waiting.phase, UpdateState::WaitingIdle);
    let (state, _) = next(waiting, Event::Release(Ok(release(5))), &busy);
    assert_eq!(state.phase, UpdateState::Available);
    assert_eq!(state.target_version(), Some(5));
    assert_eq!(state.order, None);
    // The same file signed again only refreshes it.
    let mut again = release(5);
    again.exp += 100;
    let (refreshed, actions) = next(state.clone(), Event::Release(Ok(again.clone())), &ctx());
    assert_eq!(refreshed.release, Some(again));
    assert_eq!(refreshed.phase, UpdateState::Available);
    assert!(actions.is_empty());
}

#[test]
fn expired_release_and_order_are_dropped_before_the_start() {
    let delayed = Ctx { jitter_s: 900, ..ctx() };
    let (scheduled, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &delayed);
    let order_gone = Ctx { now_s: NOW + 2 * 86_400 + 301, ..ctx() };
    let busy_order_gone = Ctx { idle_s: 0, ..order_gone };
    let (state, _) = next(scheduled, Event::Tick, &busy_order_gone);
    assert_eq!(state.order, None);
    assert_eq!(state.phase, UpdateState::Available);
    let release_gone = Ctx { now_s: NOW + 7 * 86_400 + 301, ..ctx() };
    let (state, _) = next(state, Event::Tick, &release_gone);
    assert_eq!(state.phase, UpdateState::Idle);
    assert_eq!(state.release, None);
}

#[test]
fn installed_and_rolled_back_end_after_one_report() {
    let stored = |state, error| {
        Ok(Some(Persisted {
            state,
            target: Some(4),
            from: Some(3),
            from_id: Some("123456789".to_owned()),
            from_key_hash: None,
            oid: Some(OID.to_owned()),
            source: Some(UpdateSource::Panel),
            attempts: 1,
            last_error: error,
            started_at: Some(NOW - 100),
            healthy_at: Some(NOW - 50),
        }))
    };
    let installed = State::restore(&stored(StoredState::Installed, None), NOW);
    assert_eq!(installed.phase, UpdateState::Installed);
    let status = installed.status(NOW, Some(SignKind::Unsigned));
    assert_eq!((status.target, status.from), (Some(4), Some(3)));
    assert_eq!(status.oid.as_deref(), Some(OID));
    let last = installed.gui_status(4, None).last_result.unwrap();
    assert_eq!((last.state, last.from, last.to, last.at), (UpdateState::Installed, 3, 4, NOW - 50));
    let (idle, _) = next(installed, Event::Reported, &ctx());
    assert_eq!(idle.phase, UpdateState::Idle);
    assert!(idle.last_result.is_some());

    let rolled = State::restore(
        &stored(StoredState::RolledBack, Some(UpdateError::IdentityChanged)),
        NOW,
    );
    assert_eq!(rolled.phase, UpdateState::RolledBack);
    let (failed, _) = next(rolled, Event::Reported, &ctx());
    assert_eq!(failed.phase, UpdateState::Failed);
    assert_eq!(failed.error, Some(UpdateError::IdentityChanged));

    for state in [StoredState::Installing, StoredState::Unhealthy] {
        let restored = State::restore(&stored(state, None), NOW);
        assert_eq!(restored.phase, UpdateState::Installing);
        // Nothing moves an installation the guard is watching.
        let (same, actions) = run(
            restored.clone(),
            vec![Event::Tick, Event::Release(Ok(release(5))), hint(None, None), Event::Reported],
            &ctx(),
        );
        assert_eq!(same.phase, UpdateState::Installing);
        assert!(actions.is_empty());
    }
    assert_eq!(State::restore(&Ok(None), NOW), State::default());
    assert_eq!(State::restore(&Err("bad".to_owned()), NOW), State::default());
    let downloading = State::restore(&stored(StoredState::Downloading, None), NOW);
    assert_eq!(downloading.phase, UpdateState::Idle);
    assert_eq!((downloading.attempts, downloading.counted_oid.as_deref()), (1, Some(OID)));
}

#[test]
fn the_same_order_after_a_restart_keeps_counting() {
    let mut stored = State::restore(
        &Ok(Some(Persisted {
            state: StoredState::Downloading,
            target: Some(4),
            from: None,
            from_id: None,
            from_key_hash: None,
            oid: Some(OID.to_owned()),
            source: Some(UpdateSource::Panel),
            attempts: 3,
            last_error: None,
            started_at: None,
            healthy_at: None,
        })),
        NOW,
    );
    stored = next(stored, Event::Release(Ok(release(4))), &ctx()).0;
    let (state, _) = next(stored, Event::Order(Ok(order(OID, 4, Window::Idle))), &ctx());
    assert_eq!(state.phase, UpdateState::Failed);
}

#[test]
fn persisted_keeps_what_the_platform_side_owns() {
    let (installing, _) = run(
        available(4),
        vec![
            Event::InstallRequested { version: 4 },
            Event::Downloaded,
            Event::Verified,
        ],
        &ctx(),
    );
    let fresh = installing.persisted(None).unwrap();
    assert_eq!(fresh.state, StoredState::Installing);
    assert_eq!((fresh.target, fresh.source, fresh.attempts), (Some(4), Some(UpdateSource::Local), 1));
    // Before the platform side started: the engine may write.
    let mut platform = fresh.clone();
    platform.from_id = Some("123456789".to_owned());
    let (failed, _) = next(installing.clone(), Event::Failed(UpdateError::InstallFailed), &ctx());
    let written = failed.persisted(Some(platform.clone())).unwrap();
    assert_eq!(written.state, StoredState::Available);
    assert_eq!(written.from_id.as_deref(), Some("123456789"), "same target: merged");
    // Once it started (`started_at`) or the version marked itself unhealthy: never.
    platform.started_at = Some(NOW);
    assert_eq!(failed.persisted(Some(platform.clone())), None);
    platform.state = StoredState::Unhealthy;
    assert_eq!(installing.persisted(Some(platform.clone())), None);
    // `installed` stays for the guard until new work starts.
    platform.state = StoredState::Installed;
    assert_eq!(State::default().persisted(Some(platform.clone())), None);
    let (scheduled, _) = next(available(5), Event::InstallRequested { version: 5 }, &Ctx {
        idle_s: 0,
        ..ctx()
    });
    let next_job = scheduled.persisted(Some(platform)).unwrap();
    assert_eq!((next_job.state, next_job.target), (StoredState::WaitingIdle, Some(5)));
    assert_eq!(next_job.from_id, None, "another target: not merged");
}

#[test]
fn status_reports_have_and_hides_progress_outside_downloading() {
    let (state, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Night))), &ctx());
    let status = state.status(NOW, Some(SignKind::Unsigned));
    assert_eq!(status.state, UpdateState::WaitingIdle);
    assert_eq!(
        status.have,
        Some(Have {
            release: Some(4),
            release_exp: Some(NOW + 7 * 86_400),
            oid: Some(OID.to_owned()),
        })
    );
    assert_eq!(status.progress_pct, None);
    assert_eq!(status.attempts, None);
    assert_eq!(State::default().status(NOW, None).have, None);
    let gui = state.gui_status(3, Some(NOW));
    assert_eq!(gui.notes_url.as_deref(), Some("https://panel.example/#surum-4"));
    assert_eq!(gui.blocked, Some(Blocked::NightWindow));
    assert_eq!(gui.checked_at, Some(NOW));
    // A detail that does not fit the contract is never reported.
    let mut odd = state;
    odd.error_detail = Some("Not-A-Name".to_owned());
    assert_eq!(odd.status(NOW, None).error_detail, None);
    assert_eq!(odd.gui_status(3, None).error_detail, None);
}

#[test]
fn installed_by_hand_meanwhile_drops_the_job() {
    let busy = Ctx { idle_s: 0, ..ctx() };
    let (waiting, _) = next(available(4), Event::InstallRequested { version: 4 }, &busy);
    let now_4 = Ctx { installed: 4, ..ctx() };
    let (state, _) = next(waiting, Event::Tick, &now_4);
    assert_eq!(state.phase, UpdateState::Idle);
    assert_eq!(state.release, None);
}

// Sense Remote (D3e, #68): "Vazgeç" while downloading.
#[test]
fn cancel_stops_the_users_own_download_and_does_not_count() {
    let c = ctx();
    let (downloading, _) = next(available(4), Event::InstallRequested { version: 4 }, &c);
    let (downloading, _) = next(downloading, Event::DownloadProgress(40), &c);
    assert_eq!(check_cancel(&downloading), Ok(()));
    let (state, actions) = next(downloading, Event::CancelRequested, &c);
    assert_eq!(state.phase, UpdateState::Available);
    assert_eq!(state.source, None);
    assert_eq!(state.progress_pct, None);
    assert_eq!(state.attempts, 0);
    assert_eq!(state.first_attempt_s, None);
    assert_eq!(actions, vec![Action::Persist, Action::AbortDownload]);
    // Nothing starts again by itself...
    let (state, actions) = next(state, Event::Tick, &c);
    assert_eq!(state.phase, UpdateState::Available);
    assert!(actions.is_empty());
    // ...a late progress or "downloaded" of the stopped task changes nothing...
    let (state, actions) = run(state, vec![Event::DownloadProgress(90), Event::Downloaded], &c);
    assert_eq!(state.phase, UpdateState::Available);
    assert!(actions.is_empty());
    // ...and "Güncelle" works again at once.
    assert_eq!(check_install(&state, 4, &c), Ok(()));
    let (state, actions) = next(state, Event::InstallRequested { version: 4 }, &c);
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(actions, vec![Action::Persist, Action::Download]);
}

#[test]
fn cancel_answers_and_never_stops_a_panel_order_or_an_installation() {
    let c = ctx();
    assert_eq!(check_cancel(&State::default()), Err(NOT_DOWNLOADING));
    assert_eq!(check_cancel(&available(4)), Err(NOT_DOWNLOADING));
    let (ordered, _) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Idle))), &c);
    assert_eq!(ordered.phase, UpdateState::Downloading);
    assert_eq!(check_cancel(&ordered), Err(PANEL_ORDER));
    let (same, actions) = next(ordered.clone(), Event::CancelRequested, &c);
    assert_eq!(same, ordered);
    assert!(actions.is_empty());
    let (local, _) = next(available(4), Event::InstallRequested { version: 4 }, &c);
    let (verifying, _) = next(local, Event::Downloaded, &c);
    assert_eq!(check_cancel(&verifying), Err(NOT_DOWNLOADING));
    let (same, actions) = next(verifying.clone(), Event::CancelRequested, &c);
    assert_eq!(same, verifying);
    assert!(actions.is_empty());
}

// Sense Remote: a `now` order starts at once and installs at once, with sessions open, at
// night or not, without the random delay; `idle` and `night` still wait.
#[test]
fn now_order_waits_for_nothing() {
    let busy = Ctx { idle_s: 0, local_hour: 12, jitter_s: 600, ..ctx() };
    let (state, actions) = next(available(4), Event::Order(Ok(order(OID, 4, Window::Now))), &busy);
    assert_eq!(state.phase, UpdateState::Downloading);
    assert_eq!(state.blocked, None);
    assert!(actions.contains(&Action::Download));
    let (state, _) = next(state, Event::Downloaded, &busy);
    assert_eq!(state.phase, UpdateState::Verifying);
    let (state, actions) = next(state, Event::Verified, &busy);
    assert_eq!(state.phase, UpdateState::Installing);
    assert!(actions.contains(&Action::Install));
    // The same situation with the other windows waits.
    for window in [Window::Idle, Window::Night] {
        let (state, actions) = next(available(4), Event::Order(Ok(order(OID, 4, window))), &busy);
        assert_ne!(state.phase, UpdateState::Downloading, "{window:?}");
        assert!(!actions.contains(&Action::Download), "{window:?}");
    }
}
