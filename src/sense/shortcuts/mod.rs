//! Sense Remote (Sürüm 12, plan 2026-11-28 §2.1, §2.3): favourite shortcuts ("Sık
//! kullanılanlar"). Skeleton from ÇK-0; FAV-Ç fills it: the built-in catalogue
//! (`catalog.rs`, compiled in), the Host runner (`run.rs`) and the approved custom shortcuts
//! from the signed strategy envelope (`sense_shortcuts`).
//!
//! Rules that never change: the command of a catalogue entry is fixed; nothing comes from the
//! Controller but the id. A `custom:` id runs only when it is in the signed list. Until the
//! catalogue exists every id is `unknown_id`.

/// Why the Host did not run a shortcut (contract codes, `sense.shortcut-result.err`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunError {
    UnknownId,
    NoPermission,
    UnsupportedOs,
    NeedsAdmin,
    Failed,
}

impl RunError {
    pub fn code(self) -> &'static str {
        match self {
            RunError::UnknownId => "unknown_id",
            RunError::NoPermission => "no_permission",
            RunError::UnsupportedOs => "unsupported_os",
            RunError::NeedsAdmin => "needs_admin",
            RunError::Failed => "failed",
        }
    }
}

/// Host: runs the shortcut `id` (the caller already checked the connection may type).
pub fn run(id: &str) -> Result<(), RunError> {
    let _ = id;
    Err(RunError::UnknownId)
}

/// `main_sense_shortcut_catalog(os)`: `[{id, cat, kind, admin, available}]`; empty until the
/// catalogue exists.
pub fn ffi_catalog(os: &str) -> String {
    let _ = os;
    "[]".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_match_the_contract() {
        let all = [
            (RunError::UnknownId, "unknown_id"),
            (RunError::NoPermission, "no_permission"),
            (RunError::UnsupportedOs, "unsupported_os"),
            (RunError::NeedsAdmin, "needs_admin"),
            (RunError::Failed, "failed"),
        ];
        for (e, code) in all {
            assert_eq!(e.code(), code);
        }
    }

    #[test]
    fn skeleton_knows_no_shortcut_yet() {
        assert_eq!(run("win.taskmgr"), Err(RunError::UnknownId));
        let v: serde_json::Value = serde_json::from_str(&ffi_catalog("win")).unwrap();
        assert_eq!(v, serde_json::json!([]));
    }
}
