//! Sense Remote: our own ID (hbbs) and relay (hbbr) server, fixed at build time (2026-11-21).
//!
//! RustDesk's public server (`rs-ny.rustdesk.com`) now refuses connections from clients that
//! are not signed in to a RustDesk account. Our clients sign in to our panel instead, so every
//! remote connection over the public server was refused. Sense builds use only the server
//! below; there is no fallback to RustDesk's servers or key (`RENDEZVOUS_SERVERS` /
//! `RS_PUB_KEY` in `hbb_common` stay unused, see the call sites in `client.rs` / `common.rs`).
//!
//! The values are pinned in `OVERWRITE_SETTINGS` (`security_overwrite_settings`), so neither
//! the user, a panel strategy nor a custom.txt can change them, and the settings page shows
//! them locked.
//!
//! "Connect with ID" therefore finds computers registered on our server. A computer running
//! the official RustDesk client is reachable only after its user enters our address as ID
//! server and our public key as key in RustDesk's network settings.
//!
//! Moving the server needs no code change: set the repository variables
//! `SENSE_RENDEZVOUS_SERVER` (and `SENSE_RELAY_SERVER` if hbbr runs elsewhere) and
//! `SENSE_RS_PUB_KEY`; an empty or unset variable keeps the defaults below. The IP address and
//! the public key are not secret.

/// `value` unless it is missing or empty (an unset repository variable arrives as "").
const fn env_or(value: Option<&'static str>, default: &'static str) -> &'static str {
    match value {
        Some(v) if !v.is_empty() => v,
        _ => default,
    }
}

/// ID server (hbbs), `host` or `host:port` (port 21116 when missing).
pub const RENDEZVOUS_SERVER: &str =
    env_or(option_env!("SENSE_RENDEZVOUS_SERVER"), "130.210.66.22");

/// Relay server (hbbr), `host` or `host:port` (port 21117 when missing). Same host by default.
pub const RELAY_SERVER: &str = env_or(option_env!("SENSE_RELAY_SERVER"), RENDEZVOUS_SERVER);

/// Public key of our hbbs (base64 of the 32-byte Ed25519 key). Not secret.
pub const RS_PUB_KEY: &str = env_or(
    option_env!("SENSE_RS_PUB_KEY"),
    "4NFLedghh3cvGMgdCyIS5uKWRZVl3WHK7NZEHjxbNrw=",
);

const fn contains(value: &str, needle: &str) -> bool {
    let (value, needle) = (value.as_bytes(), needle.as_bytes());
    if needle.len() > value.len() {
        return false;
    }
    let mut i = 0;
    while i + needle.len() <= value.len() {
        let mut j = 0;
        while j < needle.len() && value[i + j] == needle[j] {
            j += 1;
        }
        if j == needle.len() {
            return true;
        }
        i += 1;
    }
    false
}

/// `host` or `host:port`: not empty, no scheme / path / whitespace, and never RustDesk's.
pub const fn is_valid_server(server: &str) -> bool {
    let bytes = server.as_bytes();
    if bytes.is_empty() || contains(server, "rustdesk") {
        return false;
    }
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'/' || c == b'@' || c == b'?' || c == b'#' || c == b'\\' || c <= b' ' {
            return false;
        }
        i += 1;
    }
    true
}

/// RustDesk's public key, written out so the check below does not depend on `hbb_common`.
const RUSTDESK_PUBLIC_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";

/// Base64 of 32 bytes (44 characters, one `=`) and not RustDesk's key.
pub const fn is_valid_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    if bytes.len() != 44 || bytes[43] != b'=' || contains(key, RUSTDESK_PUBLIC_KEY) {
        return false;
    }
    let mut i = 0;
    while i < 43 {
        let c = bytes[i];
        if !(c.is_ascii_alphanumeric() || c == b'+' || c == b'/') {
            return false;
        }
        i += 1;
    }
    true
}

// A wrong repository variable stops the build instead of producing a client that talks to
// another server.
const _: () = assert!(
    is_valid_server(RENDEZVOUS_SERVER) && is_valid_server(RELAY_SERVER),
    "SENSE_RENDEZVOUS_SERVER / SENSE_RELAY_SERVER must be host[:port] and not RustDesk's"
);
const _: () = assert!(
    is_valid_key(RS_PUB_KEY),
    "SENSE_RS_PUB_KEY must be the base64 Ed25519 key of our hbbs"
);

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::config;

    #[test]
    fn defaults_are_our_server_and_key() {
        // The CI builds and tests run without the variables: the defaults are what ships.
        if option_env!("SENSE_RENDEZVOUS_SERVER").unwrap_or_default().is_empty() {
            assert_eq!(RENDEZVOUS_SERVER, "130.210.66.22");
        }
        if option_env!("SENSE_RELAY_SERVER").unwrap_or_default().is_empty() {
            assert_eq!(RELAY_SERVER, RENDEZVOUS_SERVER);
        }
        if option_env!("SENSE_RS_PUB_KEY").unwrap_or_default().is_empty() {
            assert_eq!(RS_PUB_KEY, "4NFLedghh3cvGMgdCyIS5uKWRZVl3WHK7NZEHjxbNrw=");
        }
    }

    #[test]
    fn key_is_a_32_byte_ed25519_key() {
        let bytes = crate::common::decode64(RS_PUB_KEY).unwrap();
        assert_eq!(bytes.len(), 32);
    }

    #[test]
    fn nothing_points_at_rustdesk() {
        for server in [RENDEZVOUS_SERVER, RELAY_SERVER] {
            assert!(!server.contains("rustdesk"), "{server}");
            assert!(!config::RENDEZVOUS_SERVERS.contains(&server), "{server}");
        }
        assert_ne!(RS_PUB_KEY, config::RS_PUB_KEY);
        assert_eq!(RUSTDESK_PUBLIC_KEY, config::RS_PUB_KEY);
    }

    #[test]
    fn env_or_ignores_missing_and_empty() {
        assert_eq!(env_or(None, "d"), "d");
        assert_eq!(env_or(Some(""), "d"), "d");
        assert_eq!(env_or(Some("x"), "d"), "x");
    }

    #[test]
    fn server_validation() {
        for ok in ["130.210.66.22", "130.210.66.22:21116", "id.example.net"] {
            assert!(is_valid_server(ok), "{ok}");
        }
        for bad in [
            "",
            "rs-ny.rustdesk.com",
            "rs-sg.rustdesk.com:21116",
            "http://130.210.66.22",
            "130.210.66.22/x",
            "a b",
            "user@host",
        ] {
            assert!(!is_valid_server(bad), "{bad}");
        }
    }

    #[test]
    fn key_validation() {
        assert!(is_valid_key("4NFLedghh3cvGMgdCyIS5uKWRZVl3WHK7NZEHjxbNrw="));
        for bad in [
            "",
            "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=",
            "4NFLedghh3cvGMgdCyIS5uKWRZVl3WHK7NZEHjxbNrw",
            "4NFLedghh3cvGMgdCyIS5uKWRZVl3WHK7NZEHjxbNr w=",
        ] {
            assert!(!is_valid_key(bad), "{bad}");
        }
    }
}
