//! Sense Remote (Sürüm 4, S5 / S12 / O11 / O12; plan 2026-11-23 §2.6 and "Ek"): files and the voice
//! call in the shared chat.
//! - D3d1: Controller → Host files over the open Remote connection (no second FileTransfer
//!   connection, S8), resume after a drop, the incoming folder (Downloads when unreachable).
//! - D3d2: Host → Controller files, a call started on the Host, microphone off, sound output
//!   choice and microphone level during a call.
//!
//! The chat and the file list live only in the connection's memory (S12); the audit log gets
//! counts only.
//!
//! Skeleton (D3-0): no transfer starts, lists are empty, setters report "not done".

/// `main_sense_incoming_dir`: folder for incoming files. Empty until D3d1 (the UI keeps its own
/// choice meanwhile).
pub fn ffi_incoming_dir() -> String {
    String::new()
}

/// `main_sense_set_incoming_dir`.
pub fn ffi_set_incoming_dir(_path: &str) {}

/// `session_sense_send_files`: IDs of the started transfers (`["id", ..]`).
pub fn ffi_send_files(_paths: &[String]) -> String {
    "[]".to_owned()
}

/// `session_sense_file_jobs`: `[{id, name, kind, dir: "out" | "in", done, total, state: "run" |
/// "ok" | "err" | "resume", path}]`.
pub fn ffi_file_jobs() -> String {
    "[]".to_owned()
}

/// `main_sense_host_file_jobs` (Host side, same shape as `ffi_file_jobs`).
pub fn ffi_host_file_jobs() -> String {
    "[]".to_owned()
}

/// `main_sense_host_offer_files`: IDs of the offered transfers.
pub fn ffi_host_offer_files(_conn_id: i32, _paths: &[String]) -> String {
    "[]".to_owned()
}

/// `main_sense_host_start_call`: voice call started on the Host.
pub fn ffi_host_start_call(_conn_id: i32) {}

/// `main_sense_sound_outputs`: `{outputs: [..], output}`; `output` empty = system default.
pub fn ffi_sound_outputs() -> String {
    r#"{"outputs":[],"output":""}"#.to_owned()
}

/// `main_sense_set_call_output`: true when the call now plays on `device`.
pub fn ffi_set_call_output(_device: &str) -> bool {
    false
}

/// `session_sense_call_set_muted`: true when the microphone is now muted / open as asked.
pub fn ffi_call_set_muted(_muted: bool) -> bool {
    false
}

/// `session_sense_call_level`: microphone level 0.0–1.0 during a call; below 0 = unknown.
pub fn ffi_call_level() -> f64 {
    -1.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn parse(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    #[test]
    fn skeleton_starts_nothing() {
        let paths = vec!["C:\\a.txt".to_owned()];
        assert_eq!(parse(&ffi_send_files(&paths)), json!([]));
        assert_eq!(parse(&ffi_file_jobs()), json!([]));
        assert_eq!(parse(&ffi_host_file_jobs()), json!([]));
        assert_eq!(parse(&ffi_host_offer_files(1, &paths)), json!([]));
        assert_eq!(ffi_incoming_dir(), "");
        ffi_set_incoming_dir("C:\\in");
        ffi_host_start_call(1);
    }

    #[test]
    fn call_controls_report_not_done() {
        assert_eq!(parse(&ffi_sound_outputs()), json!({ "outputs": [], "output": "" }));
        assert!(!ffi_set_call_output("Speakers"));
        assert!(!ffi_call_set_muted(true));
        assert!(ffi_call_level() < 0.0);
    }
}
