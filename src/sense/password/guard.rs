//! Sense Remote (permanent password plan §3.7, §6.3): the locks. With a Sense role installed the
//! permanent password, its salt and the identity change only through the app's signed grant
//! (`ipc_win` / `ipc_mac`), never through RustDesk's older ways in:
//! - `Config("permanent-password" | "salt" | "id", Some)` on the main IPC (the command line and
//!   any UI process use it) is refused;
//! - on Windows a `SyncConfig(Some)` from a UI process keeps SYSTEM's identity, key pair,
//!   password and salt (`mac_apply::PROTECTED_CONFIG_FIELDS`, the list the macOS daemon uses);
//! - on Windows, with a role that takes incoming connections, `Options(Some)` and the options of
//!   `SyncConfig(Some)` keep SYSTEM's access settings and the envelope's permission settings
//!   (`mac_apply::keep_root_options`, the macOS daemon's list);
//! - the `--password` command line prints `CLI_PASSWORD_REFUSED`.
//!
//! `RoleState` is `sense::installed_role_state()`: `Ok(None)` = not installed, RustDesk behaves
//! as before. A role that can not be read (`Err`) is never less strict than an installed one.

use crate::sense::{mac_apply, SenseRole};
use std::collections::HashMap;

/// `sense::installed_role_state()`.
pub type RoleState = Result<Option<SenseRole>, String>;

/// Main IPC `Config` names that write the permanent password or the identity.
pub const GUARDED_CONFIG_NAMES: [&str; 3] = ["permanent-password", "salt", "id"];

/// A role is installed, or one is there that can not be read.
pub fn locked(state: &RoleState) -> bool {
    !matches!(state, Ok(None))
}

/// Whether a main IPC `Config(name, Some(_))` write is refused. Pure.
pub fn refuses_config_write(name: &str, state: &RoleState) -> bool {
    locked(state) && GUARDED_CONFIG_NAMES.contains(&name)
}

/// Whether `SyncConfig(Some)` from a client keeps the privileged process's protected `Config`
/// fields. Every installed role: on Windows no Sense flow sends `SyncConfig(Some)` at all.
pub fn protects_sync_config(state: &RoleState) -> bool {
    locked(state)
}

/// Whether protected options are kept: as `mac_apply::sync_protected` on macOS, a role that
/// takes incoming connections (Host, Host + Controller) or an unreadable one. A Controller only
/// connects out; its own settings stay its own.
pub fn protects_options(state: &RoleState) -> bool {
    match state {
        Ok(None) | Ok(Some(SenseRole::Controller)) => false,
        Ok(Some(_)) | Err(_) => true,
    }
}

/// Whether `--password` is refused with `CLI_PASSWORD_REFUSED`.
pub fn refuses_cli_password(state: &RoleState) -> bool {
    locked(state)
}

/// What the privileged process takes from a synced config: when locked, `incoming` with the
/// protected fields of `own` (read only then); a merge that fails keeps `own` whole
/// (`mac_apply::keep_root_config`, which logs it).
pub fn sync_config_for<T>(state: &RoleState, incoming: T, own: impl FnOnce() -> T) -> T
where
    T: serde::Serialize + serde::de::DeserializeOwned,
{
    if !protects_sync_config(state) {
        return incoming;
    }
    mac_apply::keep_root_config(&incoming, own(), &mac_apply::PROTECTED_CONFIG_FIELDS)
}

/// The full option map a client sends (`Options(Some)`, `SyncConfig(Some)`): when protected,
/// its protected options are replaced by `own`'s (`own` read only then).
pub fn keep_options(
    state: &RoleState,
    incoming: &mut HashMap<String, String>,
    own: impl FnOnce() -> HashMap<String, String>,
) {
    if protects_options(state) {
        mac_apply::keep_root_options(incoming, &own());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn states() -> [RoleState; 5] {
        [
            Ok(None),
            Ok(Some(SenseRole::Host)),
            Ok(Some(SenseRole::Both)),
            Ok(Some(SenseRole::Controller)),
            Err("unreadable".to_owned()),
        ]
    }

    #[test]
    fn config_write_decision_table() {
        for state in states() {
            let installed = !matches!(state, Ok(None));
            for name in GUARDED_CONFIG_NAMES {
                assert_eq!(
                    refuses_config_write(name, &state),
                    installed,
                    "{state:?} {name}"
                );
            }
            for name in [
                "temporary-password",
                "unlock-pin",
                "voice-call-input",
                "permanent-password-set",
                "permanent-password-storage-and-salt",
                "Permanent-Password",
                "ID",
                "",
            ] {
                assert!(!refuses_config_write(name, &state), "{state:?} {name}");
            }
        }
    }

    #[test]
    fn locks_follow_the_role_state() {
        for state in states() {
            let installed = !matches!(state, Ok(None));
            assert_eq!(locked(&state), installed, "{state:?}");
            assert_eq!(protects_sync_config(&state), installed, "{state:?}");
            assert_eq!(refuses_cli_password(&state), installed, "{state:?}");
        }
        // Options: as on macOS, the incoming roles and an unreadable role.
        let options: Vec<bool> = states().iter().map(protects_options).collect();
        assert_eq!(options, [false, true, true, false, true]);
    }

    fn own() -> Value {
        json!({"id": "111111111", "enc_id": "own-enc", "password": "own-pw", "salt": "own-salt",
               "key_pair": [[1], [2]], "nat_type": 1})
    }

    fn incoming() -> Value {
        json!({"id": "999999999", "enc_id": "ui-enc", "password": "ui-pw", "salt": "ui-salt",
               "key_pair": [[9], [9]], "nat_type": 2})
    }

    #[test]
    fn sync_config_keeps_protected_fields_when_locked() {
        for state in states().into_iter().filter(locked) {
            let merged = sync_config_for(&state, incoming(), own);
            for field in mac_apply::PROTECTED_CONFIG_FIELDS {
                assert_eq!(merged[field], own()[field], "{state:?} {field}");
            }
            // Everything else comes from the client, as before.
            assert_eq!(merged["nat_type"], 2);
        }
    }

    #[test]
    fn sync_config_without_a_role_is_untouched() {
        let merged = sync_config_for(&Ok(None), incoming(), || panic!("own config read"));
        assert_eq!(merged, incoming());
    }

    #[test]
    fn sync_config_with_the_real_config_keeps_password_and_id() {
        use hbb_common::config::Config;
        let from = |value: Value| -> Config { serde_json::from_value(value).unwrap() };
        let own_config =
            from(json!({"id": "111111111", "password": "own-pw", "salt": "own-salt"}));
        let ui_config = from(json!({"id": "999999999", "password": "ui-pw", "salt": "ui-salt"}));
        let merged = sync_config_for(&Ok(Some(SenseRole::Host)), ui_config, move || own_config);
        let merged = serde_json::to_value(&merged).unwrap();
        assert_eq!(merged["id"], "111111111");
        assert_eq!(merged["password"], "own-pw");
        assert_eq!(merged["salt"], "own-salt");
    }

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn options_keep_access_and_envelope_settings_when_protected() {
        use base::config::keys;
        let own = || {
            map(&[
                ("verification-method", "use-permanent-password"),
                ("approve-mode", "password"),
                (keys::OPTION_ENABLE_FILE_TRANSFER, "N"),
                ("theme", "dark"),
            ])
        };
        let ui = || {
            map(&[
                ("verification-method", "use-both-passwords"),
                ("whitelist", "0.0.0.0/0"),
                (keys::OPTION_ENABLE_FILE_TRANSFER, "Y"),
                ("theme", "light"),
            ])
        };
        for state in [
            Ok(Some(SenseRole::Host)),
            Ok(Some(SenseRole::Both)),
            Err("unreadable".to_owned()),
        ] {
            let mut incoming = ui();
            keep_options(&state, &mut incoming, own);
            assert_eq!(
                incoming,
                map(&[
                    ("verification-method", "use-permanent-password"),
                    ("approve-mode", "password"),
                    (keys::OPTION_ENABLE_FILE_TRANSFER, "N"),
                    // Not protected: the client's value, as before.
                    ("theme", "light"),
                ]),
                "{state:?}"
            );
        }
        for state in [Ok(None), Ok(Some(SenseRole::Controller))] {
            let mut incoming = ui();
            keep_options(&state, &mut incoming, || panic!("own options read"));
            assert_eq!(incoming, ui(), "{state:?}");
        }
    }
}
