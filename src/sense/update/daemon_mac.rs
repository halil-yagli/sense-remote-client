//! Sense Remote (update plan 2026-11-21, §2.1-5, §3.7): the macOS root daemon's side of an
//! update. Package U4.
//!
//! On macOS the heartbeat answer arrives in the agent (`--server`, session user), which can
//! not install anything. It forwards the raw signed release and order plus the unsigned hint
//! to the daemon over the protected `_service` channel (`SenseUpdateIpc::Offer`); the user's
//! "Güncelle" goes the same way (`Install`). As for envelopes (M5) the daemon does NOT trust
//! the agent: it verifies everything again with the keys built into its own binary, the id of
//! the root config, the machine uuid and its own clock, and runs the engine itself.
//!
//! `_service` takes exactly `Offer`, `Install` and `StatusQuery` (`ipc.rs`,
//! `sense_service_accepts`); everything else closes the connection as before.
//! - `Offer`: at most `MAX_OFFER_BYTES` in total; a bad release or order changes nothing.
//! - `Install { version }`: only against the valid release the daemon holds; a local process
//!   can at most make a signed newer version install earlier.
//! - `StatusQuery` → `DaemonStatus(json)`.
//! - At most one call per `MIN_CALL_INTERVAL_MS` per peer process (`peer_pid`, like G4-4).
//!
//! Nothing of a release or order is logged, only reasons and version numbers.
//!
//! Compiled on every platform; elsewhere and in U0 nothing is answered.
//! MAC-SONRA: checked on a device with the rest of the Mac update (plan §14).

use super::SenseUpdateIpc;

/// Limit of one `Offer` (release + order text).
pub const MAX_OFFER_BYTES: usize = 24 * 1024;
/// At most one call per peer process per this many milliseconds.
pub const MIN_CALL_INTERVAL_MS: u64 = 1000;
/// How long the agent waits for the daemon's answer.
pub const DAEMON_TIMEOUT_MS: u64 = 5000;

/// Called by the `service` binary (root) before it enters its loop; must return at once (the
/// engine's timer and the self-check, §5.3, run on their own thread). U0: nothing starts.
pub fn start() {}

/// Daemon side of the `_service` channel; blocking (file and config work), called off the async
/// loop. `None` = no answer. U0: nothing is taken.
pub fn on_service_ipc(message: SenseUpdateIpc, peer_pid: Option<u32>) -> Option<SenseUpdateIpc> {
    let _ = (message, peer_pid);
    None
}

/// Agent side: sends one message to the daemon and waits `DAEMON_TIMEOUT_MS` for its answer.
/// `None` = the daemon did not answer. U0: nothing is sent.
pub async fn request_daemon(message: SenseUpdateIpc) -> Option<SenseUpdateIpc> {
    let _ = message;
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // U0: the daemon takes nothing from the agent.
    #[test]
    fn skeleton_answers_nothing() {
        let offer = SenseUpdateIpc::Offer {
            release: "{}".to_owned(),
            order: None,
            hint_release: None,
            hint_oid: None,
        };
        assert_eq!(on_service_ipc(offer, Some(1)), None);
        assert_eq!(on_service_ipc(SenseUpdateIpc::Install { version: 4 }, None), None);
        assert_eq!(on_service_ipc(SenseUpdateIpc::StatusQuery, None), None);
    }
}
