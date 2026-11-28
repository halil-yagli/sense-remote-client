//! Sense Remote (Sürüm 12, #161, K3; plan 2026-11-28 §2.3): approved custom shortcuts. They
//! come only in the signed strategy envelope (`StrategyBody.sense_shortcuts`, the panel's
//! `SenseShortcutEntry`); the Host runs a `custom:<uuid>` id only when it is in the list of the
//! last applied envelope. No list = every `custom:` id is `unknown_id`.
//!
//! The target rule is the panel's `customShortcutTargetProblem` (K3): program / folder = an
//! absolute path without arguments, url = `https://` only. The Host checks it again before
//! running (defence in depth) and opens the target the way a double click does, never through a
//! shell that would expand it.
//!
//! The list is kept in this process (the sync loop and the Host connections are in the same
//! `--server` process) and in `sense_shortcuts.json` next to the config, so it survives a restart
//! until the next envelope.

use hbb_common::{config::Config, log};
use serde_derive::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};

/// The panel's `SENSE_SHORTCUTS_MAX`.
pub const MAX_ENTRIES: usize = 50;
/// The panel's `CUSTOM_SHORTCUT_TARGET_MAX`.
pub const MAX_TARGET: usize = 1024;
const STORE_FILE: &str = "sense_shortcuts.json";
pub const PREFIX: &str = "custom:";

/// One entry of `sense_shortcuts` (strict: an unknown key such as `args` is refused).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub id: String,
    pub os: String,
    pub kind: String,
    pub target: String,
}

fn is_uuid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == 5
        && parts
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(p, n)| p.len() == n && p.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
}

/// `custom:<lowercase uuid>`.
pub fn is_custom_id(id: &str) -> bool {
    id.strip_prefix(PREFIX).is_some_and(is_uuid)
}

/// The panel's target rule; `None` = valid.
pub fn target_problem(os: &str, kind: &str, target: &str) -> Option<&'static str> {
    if target.is_empty() || target.chars().count() > MAX_TARGET {
        return Some("too_long");
    }
    if kind == "url" {
        if !target.starts_with("https://") {
            return Some("not_https");
        }
        let ok = url::Url::parse(target).is_ok_and(|u| u.scheme() == "https" && u.has_host());
        if !ok || target.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Some("bad_chars");
        }
        return None;
    }
    if !matches!(kind, "program" | "folder") {
        return Some("bad_kind");
    }
    if target
        .chars()
        .any(|c| c.is_control() || matches!(c, '"' | '<' | '>' | '|' | '*' | '?'))
        || target != target.trim()
    {
        return Some("bad_chars");
    }
    match os {
        "win" => {
            let b = target.as_bytes();
            let abs = b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\';
            if !abs || target.contains('/') || target.split('\\').any(|p| p == "..") {
                return Some("not_absolute");
            }
            let lower = target.to_ascii_lowercase();
            if kind == "program"
                && ![".exe", ".msc", ".lnk"].iter().any(|ext| lower.ends_with(ext))
            {
                return Some("bad_extension");
            }
            None
        }
        "mac" | "linux" => {
            if !target.starts_with('/') || target.split('/').any(|p| p == "..") {
                return Some("not_absolute");
            }
            None
        }
        _ => Some("bad_os"),
    }
}

pub fn entry_is_valid(e: &Entry) -> bool {
    is_custom_id(&e.id)
        && matches!(e.os.as_str(), "win" | "mac" | "linux")
        && target_problem(&e.os, &e.kind, &e.target).is_none()
}

/// The envelope's list as a whole: at most 50, every entry valid, ids unique.
pub fn list_is_valid(list: &[Entry]) -> bool {
    let mut ids = std::collections::HashSet::new();
    list.len() <= MAX_ENTRIES && list.iter().all(|e| entry_is_valid(e) && ids.insert(&e.id))
}

fn state() -> &'static Mutex<Option<Vec<Entry>>> {
    static STATE: OnceLock<Mutex<Option<Vec<Entry>>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

fn load_file() -> Vec<Entry> {
    std::fs::read_to_string(Config::path(STORE_FILE))
        .ok()
        .and_then(|text| serde_json::from_str::<Vec<Entry>>(&text).ok())
        .filter(|list| list_is_valid(list))
        .unwrap_or_default()
}

/// The list of the last applied envelope (loaded from the file once).
pub fn current() -> Vec<Entry> {
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    state.get_or_insert_with(load_file).clone()
}

/// An envelope was applied: its list replaces the old one (a missing key = no custom shortcut;
/// every envelope carries the whole set).
pub fn set_from_envelope(list: Option<&[Entry]>) {
    let list: Vec<Entry> = list.unwrap_or(&[]).to_vec();
    let changed = {
        let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
        let changed = state.as_ref() != Some(&list);
        *state = Some(list.clone());
        changed
    };
    if !changed {
        return;
    }
    let path = Config::path(STORE_FILE);
    let result = serde_json::to_vec(&list)
        .map_err(|e| e.to_string())
        .and_then(|bytes| std::fs::write(&path, bytes).map_err(|e| e.to_string()));
    match result {
        Ok(()) => log::info!("Sense Remote: custom shortcuts from the envelope: {}", list.len()),
        Err(err) => log::warn!("Sense Remote: custom shortcuts not stored: {err}"),
    }
}

/// The approved entry `id` for this computer's system.
pub fn find(id: &str, host_os: &str) -> Option<Entry> {
    if !is_custom_id(id) {
        return None;
    }
    current()
        .into_iter()
        .find(|e| e.id == id && e.os == host_os && entry_is_valid(e))
}

#[cfg(test)]
pub fn set_for_test(list: Vec<Entry>) {
    *state().lock().unwrap_or_else(|e| e.into_inner()) = Some(list);
}
