//! Sense Remote (update plan 2026-11-21, package U4): tests of `apply_mac`.

use super::*;
use crate::sense::update::UpdateSource;

fn job() -> InstallJob {
    InstallJob {
        file: PathBuf::from("/x/SenseRemote-4.dmg"),
        version: 4,
        sha256: "00".repeat(32),
        size: 1,
        source: UpdateSource::Panel,
        oid: Some("upd_0123456789abcdef".to_owned()),
    }
}

fn installing() -> Persisted {
    installing_record(&job(), None, 3, "123456789".to_owned(), "ab".to_owned(), 100)
}

fn facts() -> SelfFacts {
    SelfFacts {
        role_installed: true,
        id: "123456789".to_owned(),
        key_hash: "ab".to_owned(),
        api_server_ok: true,
        state_json_ok: true,
    }
}

#[test]
fn installing_record_keeps_identity_and_attempts() {
    let record = installing();
    assert_eq!(record.state, StoredState::Installing);
    assert_eq!((record.target, record.from), (Some(4), Some(3)));
    assert_eq!(record.from_id.as_deref(), Some("123456789"));
    assert_eq!(record.started_at, Some(100));
    assert_eq!(record.healthy_at, None);
    let mut earlier = record.clone();
    earlier.attempts = 2;
    let again = installing_record(&job(), Some(&earlier), 3, "1".into(), "ab".into(), 200);
    assert_eq!(again.attempts, 2);
}

#[test]
fn self_check_healthy() {
    let next = self_check_verdict(&installing(), 4, &facts(), 160).unwrap();
    assert_eq!(next.state, StoredState::Installed);
    assert_eq!(next.healthy_at, Some(160));
    assert_eq!(next.last_error, None);
}

#[test]
fn self_check_catches_every_change() {
    let changes: [fn(&mut SelfFacts); 6] = [
        |f| f.role_installed = false,
        |f| f.id = "987654321".to_owned(),
        |f| f.id = String::new(),
        |f| f.key_hash = "cd".to_owned(),
        |f| f.api_server_ok = false,
        |f| f.state_json_ok = false,
    ];
    for change in changes {
        let mut facts = facts();
        change(&mut facts);
        let next = self_check_verdict(&installing(), 4, &facts, 160).unwrap();
        assert_eq!(next.state, StoredState::Unhealthy, "{facts:?}");
        assert_eq!(next.last_error, Some(UpdateError::IdentityChanged));
        assert_eq!(next.healthy_at, None);
    }
}

#[test]
fn self_check_only_for_this_version() {
    // The old version (rolled back, or still running) and builds without a version.
    assert_eq!(self_check_verdict(&installing(), 3, &facts(), 160), None);
    assert_eq!(self_check_verdict(&installing(), 0, &facts(), 160), None);
    let mut done = installing();
    done.state = StoredState::Installed;
    assert_eq!(self_check_verdict(&done, 4, &facts(), 160), None);
    let mut unhealthy = installing();
    unhealthy.state = StoredState::Unhealthy;
    assert_eq!(self_check_verdict(&unhealthy, 4, &facts(), 160), None);
}

#[test]
fn rollback_records() {
    let mut unhealthy = installing();
    unhealthy.state = StoredState::Unhealthy;
    unhealthy.last_error = Some(UpdateError::IdentityChanged);
    let next = rolled_back_record(Some(&unhealthy), true);
    assert_eq!(next.state, StoredState::RolledBack);
    assert_eq!(next.last_error, Some(UpdateError::IdentityChanged));
    let timeout = rolled_back_record(Some(&installing()), true);
    assert_eq!(timeout.last_error, Some(UpdateError::HealthTimeout));
    assert_eq!(timeout.target, Some(4));
    let failed = rolled_back_record(Some(&installing()), false);
    assert_eq!(failed.state, StoredState::Failed);
    assert_eq!(failed.last_error, Some(UpdateError::RollbackFailed));
    assert_eq!(rolled_back_record(None, true).state, StoredState::RolledBack);
}

#[test]
fn guard_plist_runs_the_old_service_every_minute() {
    let service = prev_service(Path::new(UPDATE_DIR), "SenseRemote");
    assert_eq!(
        service,
        Path::new(
            "/Library/Application Support/SenseRemote/update/prev/SenseRemote.app/\
             Contents/MacOS/service"
        )
    );
    let plist = guard_plist(&service.to_string_lossy());
    assert!(plist.contains(&format!("<string>{GUARD_LABEL}</string>")));
    assert!(plist.contains(&format!("<string>{}</string>", service.display())));
    assert!(plist.contains("<string>--sense-update-guard</string>"));
    assert!(plist.contains("<key>RunAtLoad</key>\n  <true/>"));
    assert!(plist.contains("<key>StartInterval</key>\n  <integer>60</integer>"));
    assert!(plist.contains("<key>UserName</key>\n  <string>root</string>"));
    // Markup in a path can not open a new element.
    assert!(guard_plist("/a<b>&c").contains("<string>/a&lt;b&gt;&amp;c</string>"));
}

#[test]
fn folder_rule() {
    assert!(folder_ok(false, true, 0, 0o40755, 0o755));
    assert!(folder_ok(false, true, 0, 0o40700, 0o700));
    assert!(!folder_ok(false, true, 0, 0o40755, 0o700));
    assert!(!folder_ok(false, true, 0, 0o40775, 0o755));
    assert!(!folder_ok(false, true, 501, 0o40700, 0o700));
    assert!(!folder_ok(true, true, 0, 0o40700, 0o700));
    assert!(!folder_ok(false, false, 0, 0o100600, 0o700));
}

#[cfg(not(target_os = "macos"))]
#[test]
fn other_platforms_install_nothing() {
    assert_eq!(install(&job()), Err(UpdateError::Unsupported));
    assert_eq!(roll_back(), Err(UpdateError::Unsupported));
    assert_eq!(remove_guard(), Err(UpdateError::Unsupported));
    assert_eq!(self_check(), Ok(()));
    assert_eq!(download_dir_path(), None);
    assert_eq!(prepare_download_dir(), None);
}

// Plan §11.1 U4: rollback with temporary paths (macOS CI, `ditto`).
#[cfg(target_os = "macos")]
#[test]
fn swap_back_puts_the_old_bundle_back() {
    use std::fs;
    let base = std::env::temp_dir().join(format!("sense-swap-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let app = base.join("Applications/SenseRemote.app");
    let prev = base.join("update/prev/SenseRemote.app");
    fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
    fs::create_dir_all(prev.join("Contents/MacOS")).unwrap();
    fs::write(app.join("Contents/MacOS/service"), "new").unwrap();
    fs::write(prev.join("Contents/MacOS/service"), "old").unwrap();
    swap_back(&app, &prev).unwrap();
    assert_eq!(fs::read_to_string(app.join("Contents/MacOS/service")).unwrap(), "old");
    // The copy stays for a later try; the failed bundle is gone (upstream refuses updates
    // while it exists).
    assert_eq!(fs::read_to_string(prev.join("Contents/MacOS/service")).unwrap(), "old");
    let failed = base.join(format!("Applications/SenseRemote.app{FAILED_SUFFIX}"));
    assert!(!failed.exists());
    // Without a copy nothing is touched.
    fs::write(app.join("Contents/MacOS/service"), "new").unwrap();
    assert!(swap_back(&app, &base.join("missing.app")).is_err());
    assert_eq!(fs::read_to_string(app.join("Contents/MacOS/service")).unwrap(), "new");
    let _ = fs::remove_dir_all(&base);
}
