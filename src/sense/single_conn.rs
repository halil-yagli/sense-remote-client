//! Sense Remote (S8, TK6): one Controller at a time on a Host.
//!
//! The Host turns a second Controller away with the login error [`BUSY`] (the app shows
//! "Meşgul"). Two things are not a second Controller and stay allowed:
//! - the same session coming back (a reconnect keeps its session key);
//! - another connection from the same Controller computer (its file transfer or terminal
//!   window, or a fresh remote window after its app restarted while the old link lingers).
//!
//! The check runs twice in `server/connection.rs`: once when the login request arrives (after
//! the whitelist, before the password, so a busy Host does not spend a password try), and again
//! at authorization while [`ADMISSION`] is held, so two logins racing past the first check
//! cannot both get in. This is an operational rule, not an access control: every connection
//! still has to pass the password; the peer id it is keyed on is the one the peer reports.

/// Login error sent to a second Controller. The app maps it to its "Meşgul" text.
pub const BUSY: &str = "sense_busy";

/// Sense Remote (Sürüm 12, "Meşgul" ayrıntısı): the login error with since when the Host is in
/// use: `sense_busy {"since":<unix s>}`. It still starts with [`BUSY`], so an older Controller
/// shows its plain "Meşgul" card. The answer goes out before the password check, so it carries
/// no name, id, address or computer name (karar #173); "who" comes from the panel (`busy_by`).
pub fn busy_text(since: Option<i64>) -> String {
    match since.filter(|s| *s > 0) {
        Some(since) => format!("{BUSY} {}", serde_json::json!({ "since": since })),
        None => BUSY.to_owned(),
    }
}

/// [`busy_text`] for the connection open on this Host now (`host_recent`).
pub fn busy_message() -> String {
    busy_text(super::host_recent::open_since())
}

/// Held from the second check until the connection is in `AUTHED_CONNS`. A tokio mutex: the
/// login path awaits while holding it, and the guard must be `Send`.
pub static ADMISSION: hbb_common::tokio::sync::Mutex<()> =
    hbb_common::tokio::sync::Mutex::const_new(());

/// An authorized connection already on this Host.
#[derive(Debug, Clone, Copy)]
pub struct Existing<'a> {
    /// The Controller's id (`LoginRequest.my_id`).
    pub peer_id: &'a str,
    /// Same session key (peer id, name, session id) as the newcomer.
    pub same_session: bool,
}

/// Whether a newcomer from `peer_id` may join the connections already on this Host.
pub fn admits(existing: &[Existing], peer_id: &str) -> bool {
    existing
        .iter()
        .all(|c| c.same_session || (!peer_id.is_empty() && c.peer_id == peer_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(peer_id: &str, same_session: bool) -> Existing<'_> {
        Existing {
            peer_id,
            same_session,
        }
    }

    #[test]
    fn a_free_host_admits_anyone() {
        assert!(admits(&[], "111"));
        assert!(admits(&[], ""));
    }

    #[test]
    fn a_second_controller_is_turned_away() {
        assert!(!admits(&[conn("111", false)], "222"));
        assert!(!admits(&[conn("111", false), conn("111", false)], "222"));
    }

    #[test]
    fn the_same_session_may_reconnect() {
        assert!(admits(&[conn("111", true)], "111"));
    }

    #[test]
    fn the_same_controller_may_open_file_and_terminal_windows() {
        assert!(admits(&[conn("111", false)], "111"));
        assert!(admits(&[conn("111", true), conn("111", false)], "111"));
    }

    #[test]
    fn one_foreign_connection_is_enough_to_refuse() {
        assert!(!admits(&[conn("111", true), conn("222", false)], "111"));
    }

    #[test]
    fn an_empty_peer_id_never_matches_another_connection() {
        assert!(!admits(&[conn("", false)], ""));
        assert!(admits(&[conn("", true)], ""));
    }

    #[test]
    fn busy_text_says_since_when_and_nothing_else() {
        let text = busy_text(Some(1_732_790_000));
        assert_eq!(text, r#"sense_busy {"since":1732790000}"#);
        // Karar #173: one key only (no name before the password check).
        let json: serde_json::Value = serde_json::from_str(&text[BUSY.len() + 1..]).unwrap();
        assert_eq!(json.as_object().unwrap().len(), 1);
    }

    #[test]
    fn busy_text_without_a_time_is_the_old_code() {
        assert_eq!(busy_text(None), "sense_busy");
        assert_eq!(busy_text(Some(0)), "sense_busy");
        assert_eq!(busy_text(Some(-5)), "sense_busy");
    }

    #[test]
    fn busy_code_is_stable() {
        // The app matches this exact text.
        assert_eq!(BUSY, "sense_busy");
    }
}
