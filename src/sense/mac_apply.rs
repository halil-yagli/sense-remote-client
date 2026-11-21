//! Sense Remote (Mac M0, plan §3.3): applying signed panel envelopes on macOS through the root
//! daemon.
//!
//! On macOS the `--server` process (which receives the heartbeat answer) runs as the session
//! user and can not write the root-owned state file; only the daemon (`service`, root) can. The
//! user process is NOT trusted: it forwards the raw envelopes over the `_service` IPC channel,
//! the daemon verifies each one again with its own data (embedded panel keys, `id` / `uuid`
//! of the root config, `mac_state.envelope_seq`, full-set rule G2-7) and applies it in the
//! Windows order (writable check → role → settings → seq, undo on error).
//!
//! M0 is the skeleton only: the IPC types and limits below are the contract; nothing is sent,
//! nothing is applied (`envelope_apply::APPLIES` stays Windows-only). M5 fills this file in,
//! adds `Data::SenseEnvelope(SenseEnvelopeIpc)` to `ipc.rs` (+ the `_service` allow list) and
//! routes `hbbs_http/sync.rs` here on macOS.
//!
//! The types compile on every platform (the IPC `Data` enum is shared); only the daemon entry
//! is macOS-only.

use serde_derive::{Deserialize, Serialize};

/// Limits of one `Apply` call; anything above is ignored and logged.
pub const MAX_ENVELOPES: usize = 8;
pub const MAX_TOTAL_BYTES: usize = 64 * 1024;
/// At most one `Apply` call per this many milliseconds.
pub const MIN_CALL_INTERVAL_MS: u64 = 1000;

/// Payload of `ipc::Data::SenseEnvelope`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseEnvelopeIpc {
    /// User process → daemon: raw envelope JSON as received from the panel (≤ `MAX_ENVELOPES`)
    /// and the server time of the heartbeat answer.
    Apply {
        envelopes: Vec<String>,
        server_time: Option<i64>,
    },
    /// Daemon → user process: one outcome per envelope, in order.
    Result(Vec<SenseApplyOutcome>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "c")]
pub enum SenseApplyOutcome {
    /// Applied and stored by the daemon. `role` = the new role when it changed
    /// (`host|controller|both`); `disconnect` = connection ids the user process must close.
    Applied {
        seq: u64,
        role: Option<String>,
        disconnect: Vec<i32>,
    },
    /// Nothing was changed. `reason` uses the names of `envelope::Reason::as_str`.
    Rejected { reason: String },
}

/// Pure part of the limits: count and total size of one `Apply` call.
pub fn within_limits(envelopes: &[String]) -> bool {
    envelopes.len() <= MAX_ENVELOPES
        && envelopes.iter().map(String::len).sum::<usize>() <= MAX_TOTAL_BYTES
}

/// Daemon side: verifies and applies each envelope with the daemon's own data. Skeleton: every
/// envelope is rejected with `unsupported_platform` and nothing changes.
pub fn apply_in_daemon(
    envelopes: &[String],
    _server_time: Option<i64>,
) -> Vec<SenseApplyOutcome> {
    let reason = super::envelope::Reason::UnsupportedPlatform.as_str();
    envelopes
        .iter()
        .map(|_| SenseApplyOutcome::Rejected {
            reason: reason.to_owned(),
        })
        .collect()
}

/// Called once from `platform::macos::start_os_service` (root daemon), after the `_service`
/// IPC server was started. Skeleton: nothing to start.
#[cfg(target_os = "macos")]
pub fn start_daemon_side() {}

#[cfg(test)]
mod tests {
    use super::*;

    // The wire format between the user process and the daemon (an agent can outlive a daemon
    // update): keep the tags stable.
    #[test]
    fn ipc_wire_format() {
        let apply = SenseEnvelopeIpc::Apply {
            envelopes: vec!["{}".to_owned()],
            server_time: Some(7),
        };
        let json = serde_json::to_string(&apply).unwrap();
        assert_eq!(
            json,
            r#"{"t":"Apply","c":{"envelopes":["{}"],"server_time":7}}"#
        );
        assert_eq!(serde_json::from_str::<SenseEnvelopeIpc>(&json).unwrap(), apply);

        let result = SenseEnvelopeIpc::Result(vec![
            SenseApplyOutcome::Applied {
                seq: 42,
                role: Some("both".to_owned()),
                disconnect: vec![3],
            },
            SenseApplyOutcome::Rejected {
                reason: "replayed".to_owned(),
            },
        ]);
        let json = serde_json::to_string(&result).unwrap();
        assert_eq!(
            json,
            r#"{"t":"Result","c":[{"t":"Applied","c":{"seq":42,"role":"both","disconnect":[3]}},{"t":"Rejected","c":{"reason":"replayed"}}]}"#
        );
        assert_eq!(serde_json::from_str::<SenseEnvelopeIpc>(&json).unwrap(), result);
    }

    #[test]
    fn limits_count_and_size() {
        assert!(within_limits(&[]));
        assert!(within_limits(&vec!["x".repeat(10); MAX_ENVELOPES]));
        assert!(!within_limits(&vec!["x".to_owned(); MAX_ENVELOPES + 1]));
        assert!(within_limits(&["x".repeat(MAX_TOTAL_BYTES)]));
        assert!(!within_limits(&["x".repeat(MAX_TOTAL_BYTES), "x".to_owned()]));
    }

    #[test]
    fn skeleton_daemon_rejects_everything() {
        let out = apply_in_daemon(&["{}".to_owned(), "{}".to_owned()], None);
        let rejected = SenseApplyOutcome::Rejected {
            reason: "unsupported_platform".to_owned(),
        };
        assert_eq!(out, vec![rejected.clone(), rejected]);
    }
}
