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

/// Lowercase ASCII byte.
const fn lower(c: u8) -> u8 {
    if c >= b'A' && c <= b'Z' {
        c + 32
    } else {
        c
    }
}

/// Case-insensitive (ASCII) substring check, usable in `const`.
const fn contains_ignore_case(value: &str, needle: &str) -> bool {
    let (value, needle) = (value.as_bytes(), needle.as_bytes());
    if needle.len() > value.len() {
        return false;
    }
    let mut i = 0;
    while i + needle.len() <= value.len() {
        let mut j = 0;
        while j < needle.len() && lower(value[i + j]) == lower(needle[j]) {
            j += 1;
        }
        if j == needle.len() {
            return true;
        }
        i += 1;
    }
    false
}

/// Case-insensitive (ASCII) equality of `a` and `b[from..to]`.
const fn eq_ignore_case_range(a: &str, b: &[u8], from: usize, to: usize) -> bool {
    let a = a.as_bytes();
    if a.len() != to - from {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if lower(a[i]) != lower(b[from + i]) {
            return false;
        }
        i += 1;
    }
    true
}

/// `host` or `host:port`: not empty, no scheme / path / whitespace, not RustDesk's (any case),
/// not this computer or the wildcard address, port 1-65535 when given.
pub const fn is_valid_server(server: &str) -> bool {
    let bytes = server.as_bytes();
    if bytes.is_empty() || contains_ignore_case(server, "rustdesk") {
        return false;
    }
    let mut host_end = bytes.len();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'/' || c == b'@' || c == b'?' || c == b'#' || c == b'\\' || c <= b' ' {
            return false;
        }
        if c == b':' {
            if host_end != bytes.len() {
                return false; // a second ':' (no IPv6 literal for our server)
            }
            host_end = i;
        }
        i += 1;
    }
    if host_end == 0
        || eq_ignore_case_range("localhost", bytes, 0, host_end)
        || eq_ignore_case_range("0.0.0.0", bytes, 0, host_end)
        || (host_end >= 4 && eq_ignore_case_range("127.", bytes, 0, 4))
    {
        return false;
    }
    if host_end < bytes.len() {
        // Port: 1-5 digits, 1..=65535.
        let digits = bytes.len() - host_end - 1;
        if digits == 0 || digits > 5 {
            return false;
        }
        let mut port: u32 = 0;
        let mut k = host_end + 1;
        while k < bytes.len() {
            let c = bytes[k];
            if c < b'0' || c > b'9' {
                return false;
            }
            port = port * 10 + (c - b'0') as u32;
            k += 1;
        }
        if port == 0 || port > 65535 {
            return false;
        }
    }
    true
}

/// RustDesk's public key, written out so the check below does not depend on `hbb_common`.
const RUSTDESK_PUBLIC_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";

/// Base64 of 32 bytes (44 characters, one `=`) and not RustDesk's key.
pub const fn is_valid_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    if bytes.len() != 44 || bytes[43] != b'=' || contains_ignore_case(key, RUSTDESK_PUBLIC_KEY) {
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

/// A build that moves the server must bring that server's key too: our default key would not
/// verify any peer registered on another hbbs.
pub const fn server_comes_with_key(server: Option<&str>, key: Option<&str>) -> bool {
    let server_set = match server {
        Some(s) => !s.is_empty(),
        None => false,
    };
    let key_set = match key {
        Some(k) => !k.is_empty(),
        None => false,
    };
    !server_set || key_set
}

// A wrong repository variable stops the build instead of producing a client that talks to
// another server.
const _: () = assert!(
    is_valid_server(RENDEZVOUS_SERVER) && is_valid_server(RELAY_SERVER),
    "SENSE_RENDEZVOUS_SERVER / SENSE_RELAY_SERVER must be host[:port], not RustDesk's or local"
);
const _: () = assert!(
    is_valid_key(RS_PUB_KEY),
    "SENSE_RS_PUB_KEY must be the base64 Ed25519 key of our hbbs"
);
const _: () = assert!(
    server_comes_with_key(
        option_env!("SENSE_RENDEZVOUS_SERVER"),
        option_env!("SENSE_RS_PUB_KEY")
    ),
    "SENSE_RENDEZVOUS_SERVER is set but SENSE_RS_PUB_KEY is empty"
);

/// Lowercase `host:port` (default port added), as upstream's `check_port` builds it.
fn normalize(server: &str) -> String {
    let server = server.trim().to_ascii_lowercase();
    if server.contains(':') {
        server
    } else {
        format!("{server}:{}", hbb_common::config::RENDEZVOUS_PORT)
    }
}

/// Our ID server as lowercase `host:port`.
pub fn rendezvous_server_with_port() -> String {
    normalize(RENDEZVOUS_SERVER)
}

/// Allow list for `<id>@<server>`: only our own ID server (any case, port 21116 implied).
pub fn is_our_server(server: &str) -> bool {
    is_valid_server(server.trim()) && normalize(server) == rendezvous_server_with_port()
}

/// Where `<id>@<server>` connects: `<id>@public` means our own ID server, `<id>@<ours>` too;
/// every other server is refused.
pub fn other_server_target(other: &str, public_alias: &str) -> hbb_common::ResultType<String> {
    if other == public_alias || is_our_server(other) {
        return Ok(rendezvous_server_with_port());
    }
    hbb_common::log::error!("Sense Remote: ID server {other:?} refused (only our own is allowed)");
    hbb_common::bail!("Sense Remote connects only through its own server ({other:?} refused)")
}

/// Whether a session may continue unencrypted (peer key missing or not verified). Never in our
/// build: upstream asks the user ("Insecure Connection"), we refuse.
pub const PLAINTEXT_ALLOWED: bool = false;

fn unsecured_decision(allowed: bool, reason: &str) -> hbb_common::ResultType<()> {
    if allowed {
        return Ok(());
    }
    hbb_common::log::error!("Sense Remote: unencrypted connection refused ({reason})");
    hbb_common::bail!(
        "The connection could not be encrypted ({reason}). Sense Remote does not open \
         unencrypted connections; both computers must use the Sense Remote server."
    )
}

/// `Err` (connection refused) unless `PLAINTEXT_ALLOWED`.
pub fn refuse_unsecured(reason: &str) -> hbb_common::ResultType<()> {
    unsecured_decision(PLAINTEXT_ALLOWED, reason)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::config;

    fn var_unset(value: Option<&str>) -> bool {
        value.unwrap_or_default().is_empty()
    }

    #[test]
    fn defaults_are_our_server_and_key() {
        // The CI builds and tests run without the variables: the defaults are what ships.
        if var_unset(option_env!("SENSE_RENDEZVOUS_SERVER")) {
            assert_eq!(RENDEZVOUS_SERVER, "130.210.66.22");
        }
        if var_unset(option_env!("SENSE_RELAY_SERVER")) {
            assert_eq!(RELAY_SERVER, RENDEZVOUS_SERVER);
        }
        if var_unset(option_env!("SENSE_RS_PUB_KEY")) {
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
            assert!(!server.to_lowercase().contains("rustdesk"), "{server}");
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
        for ok in [
            "130.210.66.22",
            "130.210.66.22:21116",
            "id.example.net",
            "ID.Example.NET:1",
            "10.0.0.1:65535",
        ] {
            assert!(is_valid_server(ok), "{ok}");
        }
        for bad in [
            "",
            "rs-ny.rustdesk.com",
            "RS-NY.RUSTDESK.COM",
            "rs-sg.RustDesk.com:21116",
            "http://130.210.66.22",
            "130.210.66.22/x",
            "a b",
            "user@host",
            "localhost",
            "LOCALHOST:21116",
            "0.0.0.0",
            "0.0.0.0:21116",
            "127.0.0.1",
            "130.210.66.22:",
            "130.210.66.22:0",
            "130.210.66.22:65536",
            "130.210.66.22:2111a",
            "130.210.66.22:211160",
            "130.210.66.22:21116:1",
            ":21116",
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

    #[test]
    fn moved_server_needs_its_key() {
        assert!(server_comes_with_key(None, None));
        assert!(server_comes_with_key(Some(""), None));
        assert!(server_comes_with_key(Some(""), Some("")));
        assert!(server_comes_with_key(None, Some("k")));
        assert!(server_comes_with_key(Some("10.0.0.1"), Some("k")));
        assert!(!server_comes_with_key(Some("10.0.0.1"), None));
        assert!(!server_comes_with_key(Some("10.0.0.1"), Some("")));
    }

    #[test]
    fn only_our_server_is_allowed_after_at() {
        let ours = RENDEZVOUS_SERVER;
        assert!(is_our_server(ours));
        assert!(is_our_server(&ours.to_uppercase()));
        assert!(is_our_server(&rendezvous_server_with_port()));
        assert!(is_our_server(&format!(" {} ", rendezvous_server_with_port())));
        for other in [
            "rs-ny.rustdesk.com",
            "RS-NY.RUSTDESK.COM",
            "10.0.0.1",
            "evil.example.net",
            "localhost",
            "",
        ] {
            assert!(!is_our_server(other), "{other}");
        }
        // Same host, another port: refused.
        let host = ours.split(':').next().unwrap();
        assert!(!is_our_server(&format!("{host}:21117")));
    }

    #[test]
    fn default_ip_server_allow_list() {
        if var_unset(option_env!("SENSE_RENDEZVOUS_SERVER")) {
            assert_eq!(rendezvous_server_with_port(), "130.210.66.22:21116");
            assert!(is_our_server("130.210.66.22"));
            assert!(is_our_server("130.210.66.22:21116"));
            assert!(!is_our_server("130.210.66.23"));
            assert!(!is_our_server("130.210.66.22:21115"));
        }
    }

    #[test]
    fn at_public_and_at_ours_go_to_our_server() {
        let ours = rendezvous_server_with_port();
        assert_eq!(other_server_target("public", "public").unwrap(), ours);
        assert_eq!(other_server_target(RENDEZVOUS_SERVER, "public").unwrap(), ours);
        assert_eq!(other_server_target(&ours.to_uppercase(), "public").unwrap(), ours);
        for other in ["rs-ny.rustdesk.com", "Public.example", "10.0.0.1", ""] {
            assert!(other_server_target(other, "public").is_err(), "{other}");
        }
    }

    #[test]
    fn unencrypted_sessions_are_refused() {
        assert!(!PLAINTEXT_ALLOWED);
        let err = refuse_unsecured("test").unwrap_err().to_string();
        assert!(err.contains("could not be encrypted"), "{err}");
        assert!(unsecured_decision(true, "test").is_ok());
        assert!(unsecured_decision(false, "test").is_err());
    }

    #[tokio::test]
    async fn pinned_settings_read_back_as_ours() {
        // Every process calls `apply_security_settings` at start; after it the upstream readers
        // return our values whatever the stored settings say.
        crate::sense::apply_security_settings();
        assert_eq!(
            config::Config::get_rendezvous_server().to_ascii_lowercase(),
            rendezvous_server_with_port()
        );
        assert_eq!(
            config::Config::get_rendezvous_servers(),
            vec![RENDEZVOUS_SERVER.to_owned()]
        );
        assert_eq!(config::Config::get_option("key"), RS_PUB_KEY);
        assert_eq!(config::Config::get_option("relay-server"), RELAY_SERVER);
        assert_eq!(
            config::Config::get_option("custom-rendezvous-server"),
            RENDEZVOUS_SERVER
        );
        // UI-side readers take the constants directly (no IPC to the service).
        assert_eq!(crate::common::get_key(false).await, RS_PUB_KEY);
        let (server, others, _) = crate::common::get_rendezvous_server(10).await;
        assert_eq!(server, rendezvous_server_with_port());
        assert!(others.is_empty());
    }
}
