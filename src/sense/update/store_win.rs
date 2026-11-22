//! Sense Remote (update plan 2026-11-21, §3.6): the Windows store. Package U3.
//!
//! `HKLM\SOFTWARE\SenseRemote\Update` holds `store::Persisted`, one REG_SZ value per field
//! (`State`, `Target`, `From`, `FromId`, `FromKeyHash`, `Oid`, `Source`, `Attempts`,
//! `LastError`, `StartedAt`, `HealthyAt`). The key is created under `SOFTWARE\SenseRemote` like
//! `Role` / `Setup` and inherits the same ACL (administrators and SYSTEM write, users read); no
//! own ACL is set, so it can never be weaker than the role's. `Version` sits next to `Role`: the
//! installer writes it (`sense::install_commands`, U0), the self-check writes it after an update
//! (§5.3), a rollback puts the old number back. Only SYSTEM (`--server`, the guard) and the
//! elevated installer write here.
//!
//! The value ↔ field mapping (`to_values` / `from_values`) is pure and tested on every platform;
//! only the registry access is `cfg(windows)`. Elsewhere the functions answer "unsupported".

use super::{
    order,
    store::{Persisted, StoredState},
    UpdateError, UpdateSource, MAX_VERSION,
};

/// Subkey of HKLM with the update state.
pub const REG_SUBKEY_UPDATE: &str = "SOFTWARE\\SenseRemote\\Update";

/// Value names, in write order: `State` last, so a half-written key never looks complete.
pub const VALUE_NAMES: [&str; 11] = [
    "Target",
    "From",
    "FromId",
    "FromKeyHash",
    "Oid",
    "Source",
    "Attempts",
    "LastError",
    "StartedAt",
    "HealthyAt",
    "State",
];

/// Largest `Attempts` the store accepts (contract: 0–10).
const MAX_ATTEMPTS: u8 = 10;

/// `Persisted` as registry values; `None` = the value is deleted.
pub fn to_values(state: &Persisted) -> Vec<(&'static str, Option<String>)> {
    let text = |value: Option<&str>| value.map(str::to_owned);
    let number = |value: Option<i64>| value.map(|v| v.to_string());
    vec![
        ("Target", number(state.target.map(i64::from))),
        ("From", number(state.from.map(i64::from))),
        ("FromId", text(state.from_id.as_deref())),
        ("FromKeyHash", text(state.from_key_hash.as_deref())),
        ("Oid", text(state.oid.as_deref())),
        ("Source", text(state.source.map(UpdateSource::as_str))),
        ("Attempts", Some(state.attempts.to_string())),
        ("LastError", text(state.last_error.map(UpdateError::as_str))),
        ("StartedAt", number(state.started_at)),
        ("HealthyAt", number(state.healthy_at)),
        ("State", Some(state.state.as_str().to_owned())),
    ]
}

/// Reads `Persisted` back through `get` (value name → REG_SZ). `Ok(None)` when no value is
/// there; `Err` when a value breaks its rule or values exist without `State` (the guard then
/// does nothing, §5.2).
pub fn from_values(mut get: impl FnMut(&str) -> Option<String>) -> Result<Option<Persisted>, String> {
    let values: Vec<(&str, Option<String>)> =
        VALUE_NAMES.iter().map(|name| (*name, get(name))).collect();
    let value = |name: &str| {
        values
            .iter()
            .find(|(n, _)| *n == name)
            .and_then(|(_, v)| v.clone())
    };
    let Some(state) = value("State") else {
        if values.iter().any(|(_, v)| v.is_some()) {
            return Err("values without State".to_owned());
        }
        return Ok(None);
    };
    let bad = |name: &str| format!("bad {name}");
    let version = |name: &str| -> Result<Option<u32>, String> {
        value(name)
            .map(|v| {
                v.parse::<u32>()
                    .ok()
                    .filter(|n| (1..=MAX_VERSION).contains(n))
                    .ok_or_else(|| bad(name))
            })
            .transpose()
    };
    let time = |name: &str| -> Result<Option<i64>, String> {
        value(name)
            .map(|v| v.parse::<i64>().ok().filter(|t| *t >= 0).ok_or_else(|| bad(name)))
            .transpose()
    };
    Ok(Some(Persisted {
        state: StoredState::parse(&state).ok_or_else(|| bad("State"))?,
        target: version("Target")?,
        from: version("From")?,
        from_id: value("FromId")
            .map(|v| if is_rustdesk_id(&v) { Ok(v) } else { Err(bad("FromId")) })
            .transpose()?,
        from_key_hash: value("FromKeyHash")
            .map(|v| if is_key_hash(&v) { Ok(v) } else { Err(bad("FromKeyHash")) })
            .transpose()?,
        oid: value("Oid")
            .map(|v| if order::is_order_id(&v) { Ok(v) } else { Err(bad("Oid")) })
            .transpose()?,
        source: value("Source")
            .map(|v| UpdateSource::parse(&v).ok_or_else(|| bad("Source")))
            .transpose()?,
        attempts: match value("Attempts") {
            None => 0,
            Some(v) => v
                .parse::<u8>()
                .ok()
                .filter(|n| *n <= MAX_ATTEMPTS)
                .ok_or_else(|| bad("Attempts"))?,
        },
        last_error: value("LastError")
            .map(|v| UpdateError::parse(&v).ok_or_else(|| bad("LastError")))
            .transpose()?,
        started_at: time("StartedAt")?,
        healthy_at: time("HealthyAt")?,
    }))
}

/// A RustDesk ID as the config keeps it: 1–64 of `[0-9A-Za-z_-]`.
pub fn is_rustdesk_id(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `store::key_hash`: 64 lowercase hex digits.
pub fn is_key_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(windows)]
pub fn read() -> Result<Option<Persisted>, String> {
    win::read_in(REG_SUBKEY_UPDATE)
}

#[cfg(windows)]
pub fn write(state: &Persisted) -> Result<(), String> {
    win::write_in(REG_SUBKEY_UPDATE, state)
}

#[cfg(not(windows))]
pub fn read() -> Result<Option<Persisted>, String> {
    Err(super::UNSUPPORTED.to_owned())
}

#[cfg(not(windows))]
pub fn write(state: &Persisted) -> Result<(), String> {
    let _ = state;
    Err(super::UNSUPPORTED.to_owned())
}

/// HKLM `Version`; 0 when missing or not a version number. Reads what the installer wrote.
pub fn installed_version() -> u32 {
    crate::sense::installed_version().unwrap_or(0)
}

/// Writes HKLM `Version` after an update (SYSTEM): the new number from the self-check, the old
/// one on a rollback. `0` deletes the value (a rollback to version 2, which had none).
#[cfg(windows)]
pub fn store_installed_version(version: u32) -> Result<(), String> {
    win::store_version_in(crate::sense::REG_SUBKEY, version)
}

#[cfg(not(windows))]
pub fn store_installed_version(version: u32) -> Result<(), String> {
    let _ = version;
    Err(super::UNSUPPORTED.to_owned())
}

#[cfg(windows)]
pub(super) mod win {
    use super::*;
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};

    const VALUE_VERSION: &str = "Version";

    fn is_not_found(err: &std::io::Error) -> bool {
        err.kind() == std::io::ErrorKind::NotFound
    }

    pub fn read_in(subkey: &str) -> Result<Option<Persisted>, String> {
        let key = match RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(subkey) {
            Ok(key) => key,
            Err(err) if is_not_found(&err) => return Ok(None),
            Err(err) => return Err(err.to_string()),
        };
        // A value of another type (not REG_SZ) is an error, not "missing".
        let mut broken = None;
        let result = from_values(|name| match key.get_value::<String, _>(name) {
            Ok(value) => Some(value),
            Err(err) if is_not_found(&err) => None,
            Err(err) => {
                broken = Some(format!("{name}: {err}"));
                None
            }
        });
        match broken {
            Some(err) => Err(err),
            None => result,
        }
    }

    pub fn write_in(subkey: &str, state: &Persisted) -> Result<(), String> {
        let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
            .create_subkey(subkey)
            .map_err(|err| err.to_string())?;
        for (name, value) in to_values(state) {
            match value {
                Some(value) => key.set_value(name, &value).map_err(|err| err.to_string())?,
                None => match key.delete_value(name) {
                    Ok(()) => {}
                    Err(err) if is_not_found(&err) => {}
                    Err(err) => return Err(err.to_string()),
                },
            }
        }
        Ok(())
    }

    pub fn store_version_in(subkey: &str, version: u32) -> Result<(), String> {
        let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
            .create_subkey(subkey)
            .map_err(|err| err.to_string())?;
        if version == 0 {
            return match key.delete_value(VALUE_VERSION) {
                Ok(()) => Ok(()),
                Err(err) if is_not_found(&err) => Ok(()),
                Err(err) => Err(err.to_string()),
            };
        }
        if version > MAX_VERSION {
            return Err("bad version".to_owned());
        }
        // REG_SZ like the installer's line (`sense::version_command`).
        key.set_value(VALUE_VERSION, &version.to_string())
            .map_err(|err| err.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn full() -> Persisted {
        Persisted {
            state: StoredState::Installing,
            target: Some(4),
            from: Some(3),
            from_id: Some("123456789".to_owned()),
            from_key_hash: Some("ab".repeat(32)),
            oid: Some("upd_0123456789abcdef".to_owned()),
            source: Some(UpdateSource::Panel),
            attempts: 1,
            last_error: Some(UpdateError::HealthTimeout),
            started_at: Some(1_795_000_000),
            healthy_at: None,
        }
    }

    fn read_map(map: &HashMap<&str, String>) -> Result<Option<Persisted>, String> {
        from_values(|name| map.get(name).cloned())
    }

    #[test]
    fn values_round_trip_and_state_is_written_last() {
        let state = full();
        let values = to_values(&state);
        let names: Vec<_> = values.iter().map(|(n, _)| *n).collect();
        assert_eq!(names, VALUE_NAMES);
        assert_eq!(names.last(), Some(&"State"));
        let map: HashMap<_, _> = values
            .into_iter()
            .filter_map(|(n, v)| v.map(|v| (n, v)))
            .collect();
        assert!(!map.contains_key("HealthyAt"));
        assert_eq!(map["Target"], "4");
        assert_eq!(map["Source"], "panel");
        assert_eq!(read_map(&map), Ok(Some(state)));
    }

    #[test]
    fn empty_key_is_nothing_and_values_without_state_are_an_error() {
        assert_eq!(read_map(&HashMap::new()), Ok(None));
        let map = HashMap::from([("Target", "4".to_owned())]);
        assert!(read_map(&map).is_err());
        let map = HashMap::from([("State", "installed".to_owned())]);
        let minimal = read_map(&map).unwrap().unwrap();
        assert_eq!((minimal.state, minimal.attempts), (StoredState::Installed, 0));
    }

    #[test]
    fn every_value_is_checked() {
        let good: HashMap<_, _> = to_values(&full())
            .into_iter()
            .filter_map(|(n, v)| v.map(|v| (n, v)))
            .collect();
        for (name, bad) in [
            ("State", "paused"),
            ("State", "Installing"),
            ("Target", "0"),
            ("Target", "1000000"),
            ("Target", "x"),
            ("From", "-1"),
            ("FromId", ""),
            ("FromId", "12 34"),
            ("FromKeyHash", "AB"),
            ("FromKeyHash", &"AB".repeat(32)),
            ("Oid", "upd_short"),
            ("Source", "ui"),
            ("Attempts", "11"),
            ("Attempts", "-1"),
            ("LastError", "oops"),
            ("StartedAt", "-5"),
            ("HealthyAt", "soon"),
        ] {
            let mut map = good.clone();
            map.insert(name, bad.to_owned());
            assert!(read_map(&map).is_err(), "{name}={bad}");
        }
    }

    // Windows CI (elevated): the key really round-trips in HKLM, missing values stay missing,
    // a stale value is deleted, and the key inherits the role key's ACL (users can not write).
    // A test key, never the product's own.
    #[cfg(windows)]
    #[test]
    fn registry_round_trip_and_acl() {
        use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
        if !crate::platform::is_elevated(None).unwrap_or(false) {
            assert!(std::env::var_os("GITHUB_ACTIONS").is_none(), "CI runs elevated");
            return;
        }
        let parent = format!("SOFTWARE\\SenseRemoteTest-U3-{}", std::process::id());
        let subkey = format!("{parent}\\Update");
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            assert_eq!(win::read_in(&subkey), Ok(None));
            let mut state = full();
            win::write_in(&subkey, &state).unwrap();
            assert_eq!(win::read_in(&subkey), Ok(Some(state.clone())));
            state.oid = None;
            state.state = StoredState::Installed;
            state.healthy_at = Some(1_795_000_100);
            win::write_in(&subkey, &state).unwrap();
            assert_eq!(win::read_in(&subkey), Ok(Some(state)));
            win::store_version_in(&parent, 4).unwrap();
            let key = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(&parent).unwrap();
            assert_eq!(key.get_value::<String, _>("Version").unwrap(), "4");
            win::store_version_in(&parent, 0).unwrap();
            assert!(key.get_value::<String, _>("Version").is_err());
            // Users, Authenticated Users and Everyone get no write right on the key.
            let script = format!(
                "(Get-Acl 'HKLM:\\{subkey}').Access | Where-Object {{ \
                 $_.IdentityReference -match 'Users|Everyone' -and \
                 $_.RegistryRights -match 'FullControl|SetValue|CreateSubKey|WriteKey|ChangePermissions|TakeOwnership' \
                 }} | Measure-Object | ForEach-Object {{ $_.Count }}"
            );
            let output = std::process::Command::new("powershell")
                .args(["-NoProfile", "-NonInteractive", "-Command", &script])
                .output()
                .unwrap();
            assert!(output.status.success());
            assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "0");
        }));
        let _ = RegKey::predef(HKEY_LOCAL_MACHINE).delete_subkey_all(&parent);
        result.unwrap();
    }
}
