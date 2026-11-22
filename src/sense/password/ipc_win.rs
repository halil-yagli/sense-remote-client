//! Sense Remote (permanent password plan §3.7, U11): Windows, SYSTEM `--server` side of the main
//! IPC. `Begin` (role + rate limit → signed request), `Set` (§3.3 steps 7–12), `Cancel`,
//! `StatusQuery`. U9: the safe default answers (`unsupported`).
//!
//! The main channel's handler also runs in other processes that listen on it; this must only
//! act in the `--server` process and answer `None` everywhere else (U11).

use super::SensePasswordIpc;

pub async fn on_ipc(message: SensePasswordIpc) -> Option<SensePasswordIpc> {
    super::unsupported_answer(&message)
}
