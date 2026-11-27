use librustdesk::*;

#[cfg(not(target_os = "macos"))]
fn main() {}

#[cfg(target_os = "macos")]
fn main() {
    let args: Vec<String> = std::env::args().collect();
    crate::common::load_custom_client();
    if args.len() > 1 && args[1] == "--write-plists" {
        if let Err(e) = librustdesk::platform::write_plists() {
            eprintln!("Failed to write plists: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }
    // Sense Remote (Mac M2, plan §3.2): the privileged install script stores the role chosen
    // in the setup wizard (and the setup info) in the root-owned state file. Not root or a
    // value that is not allowed: nothing is written, exit 1.
    if let Some(code) = librustdesk::platform::sense_install_state_exit_code(&args) {
        std::process::exit(code);
    }
    // Sense Remote (S11 M4): a fresh process's Screen Recording answer for the setup wizard.
    if let Some(code) = librustdesk::platform::sense_screen_capture_exit_code(&args) {
        std::process::exit(code);
    }
    hbb_common::init_log(false, "service");
    // Sense Remote (update plan 2026-11-21, §5.2): `service --sense-update-guard` is the old
    // version's copy watching a new installation; it never becomes the daemon.
    if let Some(code) = librustdesk::platform::sense_update_cli_exit_code(&args) {
        std::process::exit(code);
    }
    // Sense Remote (security review G4-1): report when this daemon's own bundle is not root's.
    librustdesk::platform::sense_log_bundle_ownership();
    // Sense Remote (S11 M17): launchd's stdout / stderr files of this daemon do not grow forever.
    librustdesk::platform::sense_trim_service_logs();
    // Sense Remote (update plan 2026-11-21, §2.1-5): on macOS the root daemon is the updater
    // (U0: nothing starts yet).
    librustdesk::platform::sense_update_daemon_start();
    crate::start_os_service();
}
