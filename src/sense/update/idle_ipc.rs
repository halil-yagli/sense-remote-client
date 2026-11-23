//! Sense Remote (#77): when may the macOS updater count a session as idle although its
//! `--server` could not be asked?
//!
//! The root daemon asks every logged-in session's `--server` over the main IPC (`""`) whether
//! it has a connection (`updater::has_no_active_conns_ipc`). Upstream defers on *any* IPC error.
//! On a computer where a session has no IPC listener at all (no `--server` running for that uid,
//! e.g. a Controller-only Mac), that defers the update for ever: "bağlantı bitince
//! güncellenecek" with no connection.
//!
//! Connections are served only by a process that holds the main IPC listener: `start_server`
//! binds `ipc::start("")` and the process exits when it cannot. So when connecting to that
//! listener fails because nothing listens there (no socket file, or a socket file nobody
//! accepts on), there is no incoming connection in that session. Every other failure (time-out,
//! permission, a peer that is not our `--server`, a broken answer) still defers: the safe side.

use hbb_common::anyhow;
use std::io::ErrorKind;

/// Pure: the I/O error kinds that mean "no process listens on this socket path".
pub fn kind_means_no_listener(kind: ErrorKind) -> bool {
    matches!(kind, ErrorKind::NotFound | ErrorKind::ConnectionRefused)
}

/// True when a failed `ipc::connect_for_uid` says nothing listens for that session. Looks
/// through the error's causes for the I/O error of the connect; anything else is `false`.
pub fn no_listener(err: &anyhow::Error) -> bool {
    err.chain()
        .filter_map(|cause| cause.downcast_ref::<std::io::Error>())
        .any(|io| kind_means_no_listener(io.kind()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_missing_or_refusing_socket_means_no_listener() {
        assert!(kind_means_no_listener(ErrorKind::NotFound));
        assert!(kind_means_no_listener(ErrorKind::ConnectionRefused));
        for kind in [
            ErrorKind::PermissionDenied,
            ErrorKind::TimedOut,
            ErrorKind::ConnectionReset,
            ErrorKind::BrokenPipe,
            ErrorKind::UnexpectedEof,
            ErrorKind::InvalidData,
            ErrorKind::Other,
        ] {
            assert!(!kind_means_no_listener(kind), "{kind:?}");
        }
    }

    #[test]
    fn io_errors_are_found_through_context() {
        let err = anyhow::Error::from(std::io::Error::from(ErrorKind::NotFound));
        assert!(no_listener(&err));
        let err = anyhow::Error::from(std::io::Error::from(ErrorKind::ConnectionRefused))
            .context("IPC connection failed for uid 501");
        assert!(no_listener(&err));
        let err = anyhow::Error::from(std::io::Error::from(ErrorKind::PermissionDenied));
        assert!(!no_listener(&err));
    }

    #[test]
    fn other_failures_still_defer() {
        // `connect_for_uid` refusing a peer that is not our `--server`.
        assert!(!no_listener(&anyhow::anyhow!("Rejected user IPC peer for uid 501")));
        // A listener that does not answer in time.
        let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let elapsed = rt.block_on(hbb_common::tokio::time::timeout(
            std::time::Duration::from_millis(1),
            std::future::pending::<()>(),
        ));
        let err = anyhow::Error::from(elapsed.unwrap_err());
        assert!(!no_listener(&err));
    }

    // The kinds the operating system really gives for a socket path: none, a stale file
    // (listener gone), and a live listener (connects).
    #[cfg(unix)]
    #[test]
    fn real_socket_paths() {
        use std::os::unix::net::{UnixListener, UnixStream};
        let dir = std::env::temp_dir().join(format!("sense-idle-ipc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ipc");

        let err = UnixStream::connect(&path).unwrap_err();
        assert!(no_listener(&anyhow::Error::from(err)));

        let listener = UnixListener::bind(&path).unwrap();
        assert!(UnixStream::connect(&path).is_ok());
        drop(listener); // the socket file stays, nobody accepts
        assert!(path.exists());
        let err = UnixStream::connect(&path).unwrap_err();
        assert!(no_listener(&anyhow::Error::from(err)), "stale socket");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // The real connect path: a session with no socket at all.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn connect_for_uid_without_listener() {
        let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        // No session has this uid, so no socket exists for it.
        let err = match rt.block_on(crate::ipc::connect_for_uid(500, 3_999_999_001, "")) {
            Ok(_) => panic!("connected to a uid nobody has"),
            Err(err) => err,
        };
        assert!(no_listener(&err), "{err:?}");
    }

    // The call site in upstream's updater counts such a session as idle and keeps deferring on
    // every other error.
    #[test]
    fn updater_uses_it_only_on_connect() {
        let source = include_str!("../../updater.rs").replace("\r\n", "\n");
        let start = source.find("async fn query_no_active_conns_ipc()").unwrap();
        let body = &source[start..];
        let body = &body[..body.find("\n}\n").unwrap()];
        let call = body
            .find("Err(err) if crate::sense::update::idle_ipc::no_listener(&err) => {")
            .unwrap();
        assert!(call < body.find("conn.send(&crate::ipc::Data::HasNoActiveConns(None))").unwrap());
        assert!(body[call..].contains("continue;"));
        assert_eq!(body.matches("no_listener(").count(), 1);
    }
}
