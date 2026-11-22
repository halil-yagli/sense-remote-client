//! Sense Remote (update plan 2026-11-21, §7): how the installed app is signed. Package U4.
//!
//! macOS keeps the privacy permissions (Screen Recording, Accessibility, Input Monitoring) of
//! an app only while a new version satisfies the designated requirement of the old one. An
//! ad-hoc signature is tied to one build, so every ad-hoc update loses them; a build signed
//! with the team's permanent self-signed certificate is expected to keep them (checked on a
//! device, §14). The panel and the app warn before updating a Mac Host unless `sign` is `cert`.
//!
//! The kind is read once from the running executable with `codesign -dv` (the same tool and
//! the same `Signature=adhoc` line the packaging script checks), not through `SecCode`: no new
//! `extern "C"` declarations (the bridge generator copies those into `bridge_generated.h`), and
//! the reading of the output is a pure function tested on every platform.
//! - `Signature=adhoc` or `adhoc` in the CodeDirectory flags → `adhoc`
//! - an `Authority=` line (a certificate chain) → `cert`
//! - "not signed at all" → `none`
//! - anything else, or `codesign` not runnable → `unknown`
//!
//! MAC-SONRA: the `cert` line is checked on a device with the certificate build (U5, M-U5).

use super::SignKind;

/// `sign` of the heartbeat's `update`. Windows: always `none`; macOS: read once and kept.
pub fn sign_kind() -> SignKind {
    if cfg!(windows) {
        return SignKind::Unsigned;
    }
    #[cfg(target_os = "macos")]
    {
        use std::sync::OnceLock;
        static KIND: OnceLock<SignKind> = OnceLock::new();
        *KIND.get_or_init(read_own_signature)
    }
    #[cfg(not(target_os = "macos"))]
    {
        SignKind::Unknown
    }
}

/// Runs `codesign -dv` on this process's executable. Only the kind is kept; the output (paths,
/// hashes) is not logged.
#[cfg(target_os = "macos")]
fn read_own_signature() -> SignKind {
    let Ok(exe) = std::env::current_exe() else {
        return SignKind::Unknown;
    };
    match std::process::Command::new("/usr/bin/codesign")
        .arg("-dv")
        .arg(&exe)
        .output()
    {
        // `codesign -d` writes its report to stderr.
        Ok(output) => classify_codesign(
            output.status.success(),
            &String::from_utf8_lossy(&output.stderr),
        ),
        Err(_) => SignKind::Unknown,
    }
}

/// Pure: the kind from `codesign -dv`'s exit status and stderr.
pub fn classify_codesign(success: bool, report: &str) -> SignKind {
    if report.contains("not signed at all") {
        return SignKind::Unsigned;
    }
    if !success {
        return SignKind::Unknown;
    }
    let adhoc_flags = report.lines().any(|line| {
        line.starts_with("CodeDirectory ")
            && line
                .split_whitespace()
                .filter_map(|part| part.strip_prefix("flags="))
                .any(|flags| flags.contains("adhoc"))
    });
    if adhoc_flags || report.lines().any(|line| line.trim() == "Signature=adhoc") {
        SignKind::Adhoc
    } else if report.lines().any(|line| line.starts_with("Authority=")) {
        SignKind::Cert
    } else {
        SignKind::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADHOC: &str = "Executable=/Applications/SenseRemote.app/Contents/MacOS/SenseRemote\n\
        Identifier=com.sensedepartment.remote\nFormat=app bundle with Mach-O thin (arm64)\n\
        CodeDirectory v=20500 size=1234 flags=0x10002(adhoc,runtime) hashes=30+7 location=embedded\n\
        Signature=adhoc\nInfo.plist entries=30\nTeamIdentifier=not set\n";
    const LINKER: &str = "Executable=/tmp/deps/librustdesk-0123\nIdentifier=librustdesk-0123\n\
        Format=Mach-O thin (arm64)\n\
        CodeDirectory v=20400 size=99 flags=0x20002(adhoc,linker-signed) hashes=3+0 location=embedded\n\
        Signature=adhoc\nTeamIdentifier=not set\n";
    const CERT: &str = "Executable=/Applications/SenseRemote.app/Contents/MacOS/SenseRemote\n\
        CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded\n\
        Signature size=1650\nAuthority=Sense Remote Code Signing\nSigned Time=21 Nov 2026\n\
        TeamIdentifier=not set\n";

    #[test]
    fn reads_the_kind_from_codesign() {
        assert_eq!(classify_codesign(true, ADHOC), SignKind::Adhoc);
        assert_eq!(classify_codesign(true, LINKER), SignKind::Adhoc);
        assert_eq!(classify_codesign(true, CERT), SignKind::Cert);
        assert_eq!(
            classify_codesign(false, "/tmp/x: code object is not signed at all\n"),
            SignKind::Unsigned
        );
        assert_eq!(classify_codesign(false, "codesign: no such file\n"), SignKind::Unknown);
        assert_eq!(classify_codesign(true, ""), SignKind::Unknown);
        // An identifier or path that merely contains the word does not count.
        assert_eq!(
            classify_codesign(true, "Identifier=adhoc-tool\nExecutable=/tmp/adhoc\n"),
            SignKind::Unknown
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_is_unsigned() {
        assert_eq!(sign_kind(), SignKind::Unsigned);
    }

    // The test binary on Apple Silicon carries the linker's ad-hoc signature, like an ad-hoc
    // build of the app (plan §11.1 U4: "`sign` adhoc derlemede `adhoc`").
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    #[test]
    fn adhoc_build_reports_adhoc() {
        assert_eq!(sign_kind(), SignKind::Adhoc);
    }
}
