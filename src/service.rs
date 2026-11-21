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
    hbb_common::init_log(false, "service");
    crate::start_os_service();
}
