//! Sense Remote (permanent password plan §3.7, U12): macOS. The user `--server` forwards `Begin`,
//! `Set`, `Cancel` and `StatusQuery` to the root daemon over `_service`; the daemon trusts
//! nothing from it (own nonce, own keys, own identity, M5). U9: the safe default answers
//! (`unsupported`) on both sides.

use super::SensePasswordIpc;

/// User `--server`, main IPC: forwards to the daemon and passes its answer back.
pub async fn forward(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
    super::unsupported_answer(&message)
}

/// Daemon (root), `_service` channel; blocking, called off the async loop. `None` = no
/// answer. Limits per peer process (G4-4): one call a second, `Begin` 6 an hour, `Set` 10 per
/// pending nonce (U12).
pub fn on_service_ipc(message: SensePasswordIpc, peer_pid: Option<u32>) -> Option<SensePasswordIpc> {
    let _ = peer_pid;
    super::unsupported_answer(&message)
}
