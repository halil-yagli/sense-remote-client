//! Sense Remote (#103): Rust panics go into the event record (`error/rust_panic`) and leave a
//! crash flag (`crash::write_panic_flag`), so the `--server` sends the record of what happened
//! before (`crash` reason), even when the panic ended the process (`panic = "abort"`). The hook
//! chains to the one installed before it (RustDesk's own output stays as it was).

use serde_json::{json, Value};
use std::{any::Any, panic::Location};

/// Installs the hook once per process.
pub fn install() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // Never panic inside the hook: everything below is best effort.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                record(info.payload(), info.location());
            }));
            previous(info);
        }));
    });
}

/// The panic message: `&str` and `String` payloads; anything else `?`.
pub fn payload_text(payload: &(dyn Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_owned()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "?".to_owned()
    }
}

/// Fields of the `rust_panic` event (cleaned later by `line::build_line`).
pub fn panic_fields(payload: &(dyn Any + Send), location: Option<&Location<'_>>, thread: Option<&str>) -> Value {
    json!({
        "panik": payload_text(payload),
        "yer": location.map(|l| format!("{}:{}", l.file(), l.line())),
        "is_parcacigi": thread.unwrap_or("?"),
    })
}

fn record(payload: &(dyn Any + Send), location: Option<&Location<'_>>) {
    let thread = std::thread::current();
    let fields = panic_fields(payload, location, thread.name());
    let t = super::now_ms();
    let process = super::process_name();
    let session = super::session_nonblocking();
    if let Some(line) = super::line::build_line(t, "error", "rust_panic", process, session.as_deref(), &fields) {
        super::writer::write_now(process, &line);
    }
    super::crash::write_panic_flag(&super::writer::events_dir(), t, process, session.as_deref());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_payloads_become_text() {
        let a: Box<dyn Any + Send> = Box::new("boom");
        let b: Box<dyn Any + Send> = Box::new(String::from("index out of range"));
        let c: Box<dyn Any + Send> = Box::new(42u8);
        assert_eq!(payload_text(&*a), "boom");
        assert_eq!(payload_text(&*b), "index out of range");
        assert_eq!(payload_text(&*c), "?");
    }

    #[test]
    fn panic_line_is_an_error_event_and_masked() {
        let payload: Box<dyn Any + Send> = Box::new(String::from("failed: password=hunter2 for ayse@example.com"));
        let location = Location::caller();
        let fields = panic_fields(&*payload, Some(location), Some("sense-log-upload"));
        let line = crate::sense::diag::line::build_line(10, "error", "rust_panic", "server", Some("h1-2"), &fields).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["c"], "error");
        assert_eq!(v["k"], "rust_panic");
        assert_eq!(v["is_parcacigi"], "sense-log-upload");
        assert!(v["yer"].as_str().unwrap().contains("panic_hook.rs:"));
        assert!(!line.contains("hunter2") && !line.contains("ayse@example.com"), "{line}");
    }

    #[test]
    fn a_caught_panic_reaches_the_payload() {
        // The hook itself is process-wide and is not installed in tests; what it reads is.
        let result = std::panic::catch_unwind(|| {
            std::panic::panic_any(String::from("deneme paniği"));
        });
        let payload = result.unwrap_err();
        assert_eq!(payload_text(&*payload), "deneme paniği");
    }
}
