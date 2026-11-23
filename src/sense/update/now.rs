//! Sense Remote: the update order window `now` ("güncelle, kimseye sorma"). The panel signed
//! the order for this computer (`order::verify`), so nobody has to agree: the installer runs as
//! soon as the file is verified, also with sessions open.
//!
//! Open sessions are not cut off silently. Right before the installer:
//! 1. every incoming connection gets the close reason [`NOTICE`] (the Controller shows it as its
//!    "Connection Error" message and ends the session): Windows closes them in the same
//!    process, macOS asks the `--server` of every logged-in user over the main IPC
//!    (`SenseUpdateIpc::CloseSessions`);
//! 2. it waits a few seconds for them to end;
//! 3. it lifts the "no connection" check of the installation for [`FORCE_FOR`], so the checks
//!    in `apply` (which still ask) do not refuse. The lift expires by itself.
//!
//! Outgoing sessions (this computer as Controller, in the Flutter UI) are not closed from here:
//! the UI cannot be reached from the privileged process; the installer restarts the app.

use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

/// What the other side reads (Turkish, like the rest of the app).
pub const NOTICE: &str = "Güncelleme kuruluyor, bağlantı kapanıyor";
/// How long the installation check is lifted after the sessions were told.
pub const FORCE_FOR: Duration = Duration::from_secs(180);
/// How long to wait for the sessions to end.
const CLOSE_WAIT: Duration = Duration::from_secs(8);

static FORCE_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);

fn until() -> std::sync::MutexGuard<'static, Option<Instant>> {
    FORCE_UNTIL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Pure: is a lift that ends at `until` still in force at `now`?
pub fn in_force(until: Option<Instant>, now: Instant) -> bool {
    until.is_some_and(|until| now < until)
}

/// True while a `now` installation is under way: `updater::has_no_active_conns*` then say
/// "idle". Never set by anything but [`prepare`].
pub fn forcing() -> bool {
    in_force(*until(), Instant::now())
}

/// Pure: polls `done` every `step` until it is true or `limit` is over; the last answer.
pub fn wait_until(limit: Duration, step: Duration, mut done: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + limit;
    loop {
        if done() {
            return true;
        }
        if Instant::now() >= end {
            return false;
        }
        std::thread::sleep(step);
    }
}

/// Runs on the installation thread of a `now` order, before its "idle?" check.
pub fn prepare() {
    close_sessions();
    *until() = Some(Instant::now() + FORCE_FOR);
}

#[cfg(not(target_os = "macos"))]
fn close_sessions() {
    let told = crate::server::sense_close_incoming(NOTICE);
    log::info!("Sense Remote: update now, {told} connection(s) told to close");
    let ended = wait_until(CLOSE_WAIT, Duration::from_millis(200), || {
        crate::Connection::alive_conns().is_empty()
    });
    if !ended {
        log::warn!("Sense Remote: update now, connections still open after the notice");
    }
}

#[cfg(target_os = "macos")]
fn close_sessions() {
    let uids = crate::platform::get_logged_in_uids();
    if let Ok(runtime) = hbb_common::tokio::runtime::Runtime::new() {
        for uid in uids {
            runtime.block_on(async move {
                if let Ok(mut conn) = crate::ipc::connect_for_uid(1_000, uid, "").await {
                    let _ = conn
                        .send(&crate::ipc::Data::SenseUpdate(
                            super::SenseUpdateIpc::CloseSessions,
                        ))
                        .await;
                }
            });
        }
    }
    log::info!("Sense Remote: update now, sessions told to close");
    let ended = wait_until(CLOSE_WAIT, Duration::from_millis(500), || {
        crate::updater::has_no_active_conns_ipc()
    });
    if !ended {
        log::warn!("Sense Remote: update now, connections still open after the notice");
    }
}

use hbb_common::log;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lift_lasts_only_until_its_end() {
        let now = Instant::now();
        assert!(!in_force(None, now));
        assert!(in_force(Some(now + Duration::from_secs(1)), now));
        assert!(!in_force(Some(now), now));
        assert!(!in_force(Some(now), now + Duration::from_secs(1)));
    }

    #[test]
    fn nothing_is_lifted_until_prepared() {
        assert!(!forcing());
    }

    #[test]
    fn wait_until_stops_early_and_gives_up() {
        let mut calls = 0;
        assert!(wait_until(Duration::from_secs(5), Duration::from_millis(1), || {
            calls += 1;
            calls == 3
        }));
        assert_eq!(calls, 3);
        let started = Instant::now();
        assert!(!wait_until(Duration::from_millis(30), Duration::from_millis(5), || false));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn the_notice_is_what_the_plan_says() {
        assert_eq!(NOTICE, "Güncelleme kuruluyor, bağlantı kapanıyor");
    }
}
