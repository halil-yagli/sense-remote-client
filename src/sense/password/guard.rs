//! Sense Remote (permanent password plan §3.7, §6.3): the locks. With a Sense role installed the
//! permanent password, its salt and the identity change only through the app's signed grant
//! (`ipc_win` / `ipc_mac`), never through RustDesk's older ways in:
//! - `Config("permanent-password" | "salt", Some)` on the main IPC (the `--password` command
//!   line and any UI process use it) is refused;
//! - on Windows a `SyncConfig(Some)` from a UI process keeps SYSTEM's identity, key pair,
//!   password and salt (`mac_apply::PROTECTED_CONFIG_FIELDS`, as the macOS daemon does, G4-3);
//! - the `--password` command line prints `CLI_PASSWORD_REFUSED`.
//!
//! Without a role (not installed) RustDesk behaves as before.

use crate::sense::{mac_apply, SenseRole};

/// Main IPC `Config` names that write the permanent password.
pub const GUARDED_CONFIG_NAMES: [&str; 2] = ["permanent-password", "salt"];

/// Whether a main IPC `Config(name, Some(_))` write is refused. Pure.
pub fn refuses_config_write(name: &str, role: Option<SenseRole>) -> bool {
    role.is_some() && GUARDED_CONFIG_NAMES.contains(&name)
}

/// Whether `SyncConfig(Some)` from a client keeps the privileged process's protected fields.
/// Every installed role: on Windows no Sense flow sends `SyncConfig(Some)` at all.
pub fn protects_sync_config(role: Option<SenseRole>) -> bool {
    role.is_some()
}

/// Whether `--password` is refused with `CLI_PASSWORD_REFUSED`.
pub fn refuses_cli_password(role: Option<SenseRole>) -> bool {
    role.is_some()
}

/// What the privileged process takes from a synced config: with a role, `incoming` with the
/// protected fields of `own` (read only then); a merge that fails keeps `own` whole
/// (`mac_apply::keep_root_config`, which logs it).
pub fn sync_config_for<T>(role: Option<SenseRole>, incoming: T, own: impl FnOnce() -> T) -> T
where
    T: serde::Serialize + serde::de::DeserializeOwned,
{
    if !protects_sync_config(role) {
        return incoming;
    }
    mac_apply::keep_root_config(&incoming, own(), &mac_apply::PROTECTED_CONFIG_FIELDS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    const ROLES: [Option<SenseRole>; 4] = [
        None,
        Some(SenseRole::Host),
        Some(SenseRole::Both),
        Some(SenseRole::Controller),
    ];

    #[test]
    fn config_write_decision_table() {
        for role in ROLES {
            for name in GUARDED_CONFIG_NAMES {
                assert_eq!(
                    refuses_config_write(name, role),
                    role.is_some(),
                    "{role:?} {name}"
                );
            }
            for name in [
                "id",
                "temporary-password",
                "unlock-pin",
                "voice-call-input",
                "permanent-password-set",
                "permanent-password-storage-and-salt",
                "Permanent-Password",
                "",
            ] {
                assert!(!refuses_config_write(name, role), "{role:?} {name}");
            }
        }
    }

    #[test]
    fn sync_and_cli_locks_follow_the_installed_role() {
        for role in ROLES {
            assert_eq!(protects_sync_config(role), role.is_some(), "{role:?}");
            assert_eq!(refuses_cli_password(role), role.is_some(), "{role:?}");
        }
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
    fn sync_config_keeps_protected_fields_with_a_role() {
        for role in ROLES.into_iter().flatten() {
            let merged = sync_config_for(Some(role), incoming(), own);
            for field in mac_apply::PROTECTED_CONFIG_FIELDS {
                assert_eq!(merged[field], own()[field], "{role:?} {field}");
            }
            // Everything else comes from the client, as before.
            assert_eq!(merged["nat_type"], 2);
        }
    }

    #[test]
    fn sync_config_without_a_role_is_untouched() {
        let merged = sync_config_for(None, incoming(), || panic!("own config read"));
        assert_eq!(merged, incoming());
    }

    #[test]
    fn sync_config_with_the_real_config_keeps_password_and_id() {
        use hbb_common::config::Config;
        let from = |value: Value| -> Config { serde_json::from_value(value).unwrap() };
        let own_config =
            from(json!({"id": "111111111", "password": "own-pw", "salt": "own-salt"}));
        let ui_config = from(json!({"id": "999999999", "password": "ui-pw", "salt": "ui-salt"}));
        let merged = sync_config_for(Some(SenseRole::Host), ui_config, move || own_config);
        let merged = serde_json::to_value(&merged).unwrap();
        assert_eq!(merged["id"], "111111111");
        assert_eq!(merged["password"], "own-pw");
        assert_eq!(merged["salt"], "own-salt");
    }
}
