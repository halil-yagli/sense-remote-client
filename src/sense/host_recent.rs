//! Sense Remote (Sürüm 4, H2 "Son bağlantılar"; plan 2026-11-23 "Ek", #70): the Host's last
//! incoming connections — who, when, how long, how many screens — from the connection log on the
//! Rust side.
//!
//! Skeleton (D3-0): empty list (nothing made up).

/// `main_sense_host_recent_conns`: `[{name, at, seconds, screens}]` (`at` in unix seconds),
/// newest first.
pub fn ffi_host_recent_conns() -> String {
    "[]".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skeleton_list_is_empty_json() {
        let list: serde_json::Value = serde_json::from_str(&ffi_host_recent_conns()).unwrap();
        assert_eq!(list, serde_json::json!([]));
    }
}
