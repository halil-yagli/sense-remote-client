//! Sense Remote (#103, contract `Calisma/plan/2026-11-26_kayit-sozlesmesi.md`): the detailed
//! event record. Every process writes one JSON line per event into its own file
//! (`sense-events/<process>.jsonl` in the log directory, [`writer`]); the `--server` merges the
//! lines of a connection into the record it already sends to the panel (`log_upload`), in
//! five-minute chunks during long connections and once more after a crash ([`crash`]).
//!
//! API (contract §4): [`event`] for Rust callers, [`event_json`] for the Dart bridge
//! (`main_sense_diag_event`), named events in [`kinds`]. Neither blocks, neither panics, every
//! failure is swallowed. What goes into a line and what never does: [`line`].
//!
//! Started lazily by the first event of a process, and by the `--server` on its first heartbeat
//! answer; the panic hook ([`panic_hook`]) is installed at the same moment.

pub mod crash;
pub mod kinds;
pub mod line;
mod panic_hook;
pub mod read;
pub mod sys;
pub mod writer;

use serde_json::Value;
use std::sync::{Mutex, OnceLock};

/// Events a process may record per second (a runaway loop must not fill the disk).
const EVENTS_PER_S: u32 = 400;
static RATE: Mutex<(i64, u32)> = Mutex::new((0, 0));
static SESSION: Mutex<Option<String>> = Mutex::new(None);
static PROCESS: OnceLock<String> = OnceLock::new();

pub fn now_ms() -> i64 {
    read::unix_ms(std::time::SystemTime::now())
}

/// This process's `p` from its command line (pure part: [`process_name_from`]).
pub fn process_name() -> &'static str {
    PROCESS.get_or_init(|| {
        let args: Vec<String> = std::env::args().skip(1).take(4).collect();
        process_name_from(&args)
    })
}

/// `--server` -> `server`, `--cm` -> `cm`, any `--name` -> `name`; a Flutter sub-window
/// (`multi_window`) -> `client`; no switch -> `main`. Always a valid `p`.
pub fn process_name_from(args: &[String]) -> String {
    let Some(first) = args.first() else {
        return "main".to_owned();
    };
    if first == "multi_window" {
        return "client".to_owned();
    }
    let Some(name) = first.strip_prefix("--") else {
        return "main".to_owned();
    };
    let name: String = name
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
        .take(16)
        .collect();
    if line::is_process(&name) {
        name
    } else {
        "bilinmiyor".to_owned()
    }
}

/// Starts this process's record (writer thread, panic hook). Idempotent; cheap after the first.
pub fn init() {
    #[cfg(not(test))]
    {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            writer::start(process_name());
            panic_hook::install();
        });
    }
}

/// The session the events of this process belong to now (`s`); `None` = none.
pub fn set_session(session: Option<&str>) {
    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) =
        session.filter(|s| line::is_session(s)).map(str::to_owned);
}

/// Clears the session only when it is still `session` (another one may have started since).
pub fn end_session(session: &str) {
    let mut guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    if guard.as_deref() == Some(session) {
        *guard = None;
    }
}

pub fn session() -> Option<String> {
    SESSION.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// For the panic hook: never waits for the lock.
fn session_nonblocking() -> Option<String> {
    SESSION.try_lock().ok().and_then(|g| g.clone())
}

fn allowed(now_s: i64) -> bool {
    allowed_in(&mut RATE.lock().unwrap_or_else(|e| e.into_inner()), now_s)
}

/// One more event in the second `now_s` of `window` (`(second, count)`); false over the limit.
fn allowed_in(window: &mut (i64, u32), now_s: i64) -> bool {
    if window.0 != now_s {
        *window = (now_s, 0);
    }
    window.1 += 1;
    window.1 <= EVENTS_PER_S
}

/// Records one event: category `c`, event `k`, `fields` (an object). Invalid names are dropped.
pub fn event(c: &str, k: &str, fields: Value) {
    let t = now_ms();
    if !allowed(t / 1000) {
        return;
    }
    let Some(line) = line::build_line(t, c, k, process_name(), session().as_deref(), &fields) else {
        return;
    };
    init();
    #[cfg(not(test))]
    writer::push(line);
    #[cfg(test)]
    {
        drop(line);
        sink::record(c, k);
    }
}

/// Tests only: the events this thread has written (category, event), to prove a call site fires.
#[cfg(test)]
pub mod sink {
    use std::cell::RefCell;

    thread_local! {
        static EVENTS: RefCell<Vec<(String, String)>> = const { RefCell::new(Vec::new()) };
    }

    pub fn record(c: &str, k: &str) {
        EVENTS.with(|e| e.borrow_mut().push((c.to_owned(), k.to_owned())));
    }

    /// Takes (and clears) what this thread recorded.
    pub fn take() -> Vec<(String, String)> {
        EVENTS.with(|e| std::mem::take(&mut *e.borrow_mut()))
    }
}

/// [`event`] with the fields as JSON text (Dart bridge). Text that is not JSON goes in as
/// `{"gecersiz_json": true}`; its content is never written.
pub fn event_json(c: &str, k: &str, fields_json: &str) {
    event(c, k, parse_fields(fields_json));
}

/// Fields from the bridge: a JSON object, at most 16 KB of text.
pub fn parse_fields(fields_json: &str) -> Value {
    let trimmed = fields_json.trim();
    if trimmed.is_empty() {
        return Value::Object(Default::default());
    }
    if trimmed.len() > 16 * 1024 {
        return serde_json::json!({ "gecersiz_json": true, "neden": "buyuk" });
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(value @ Value::Object(_)) => value,
        _ => serde_json::json!({ "gecersiz_json": true }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn process_names() {
        assert_eq!(process_name_from(&args(&[])), "main");
        assert_eq!(process_name_from(&args(&["--server"])), "server");
        assert_eq!(process_name_from(&args(&["--cm"])), "cm");
        assert_eq!(process_name_from(&args(&["--sense-update-guard"])), "sense-update-gua");
        assert_eq!(process_name_from(&args(&["multi_window", "1", "{}"])), "client");
        assert_eq!(process_name_from(&args(&["rustdesk://connection/new/1"])), "main");
        assert_eq!(process_name_from(&args(&["--Weird Name!"])), "weird_name_");
        assert_eq!(process_name_from(&args(&["--"])), "bilinmiyor");
    }

    #[test]
    fn bridge_fields_are_objects_only() {
        assert_eq!(parse_fields(r#"{"ad":"kaydet"}"#)["ad"], "kaydet");
        assert_eq!(parse_fields(""), serde_json::json!({}));
        assert_eq!(parse_fields("[1,2]")["gecersiz_json"], true);
        assert_eq!(parse_fields("password=hunter2")["gecersiz_json"], true);
        assert!(!parse_fields("password=hunter2").to_string().contains("hunter2"));
        assert_eq!(parse_fields(&format!("{{\"a\":\"{}\"}}", "x".repeat(20_000)))["gecersiz_json"], true);
    }

    #[test]
    fn sessions_end_only_themselves() {
        set_session(Some("c1-0"));
        end_session("c2-0");
        assert_eq!(session().as_deref(), Some("c1-0"));
        end_session("c1-0");
        assert_eq!(session(), None);
        set_session(Some("bad id"));
        assert_eq!(session(), None);
    }

    #[test]
    fn the_rate_limit_counts_per_second() {
        let mut window = (0, 0);
        let mut passed = 0;
        for _ in 0..(EVENTS_PER_S + 50) {
            if allowed_in(&mut window, 42) {
                passed += 1;
            }
        }
        assert_eq!(passed, EVENTS_PER_S);
        assert!(allowed_in(&mut window, 43));
    }
}
