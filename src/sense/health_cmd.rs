//! Sense Remote (S6): runs a system tool (PowerShell, nvidia-smi, netsh on Windows;
//! system_profiler, ioreg, pmset on macOS) and returns its standard output, or `None` when it
//! is missing, fails or does not finish within the time limit (then it is killed). Output over
//! `MAX_OUTPUT` bytes is cut. Only absolute paths of tools that ship with the OS / driver are
//! passed in, so the search path plays no part.

// Sense Remote: used by the Windows / macOS readers and the tests.
#![allow(dead_code)]

use hbb_common::log;
use std::{
    io::Read,
    process::{Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

const MAX_OUTPUT: u64 = 4 * 1024 * 1024;
const POLL: Duration = Duration::from_millis(50);
/// Error output kept for the log (the rest is read and dropped).
const MAX_ERROR_OUTPUT: u64 = 4096;
/// Characters of error output written to the log.
pub const ERROR_EXCERPT_CHARS: usize = 300;

/// First `ERROR_EXCERPT_CHARS` characters of a tool's error text on one line; empty -> None.
pub fn error_excerpt(raw: &str) -> Option<String> {
    let one_line = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    (!one_line.is_empty()).then(|| one_line.chars().take(ERROR_EXCERPT_CHARS).collect())
}

pub fn run(program: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        // Sense Remote (Sürüm 11, #119): the error output is kept (start of it in the log), so a
        // failing query is no longer invisible.
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW: no console flashes up in the user's session.
        command.creation_flags(0x0800_0000);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            log::debug!("Sense Remote: {program} not started: {err}");
            return None;
        }
    };
    // Read on another thread so a full pipe never blocks the child.
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = (&mut stdout).take(MAX_OUTPUT).read_to_end(&mut bytes);
        let _ = tx.send(bytes);
    });
    let (err_tx, err_rx) = mpsc::channel();
    if let Some(mut stderr) = child.stderr.take() {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = (&mut stderr).take(MAX_ERROR_OUTPUT).read_to_end(&mut bytes);
            // The rest is read and dropped so the child never blocks on a full pipe.
            let _ = std::io::copy(&mut stderr, &mut std::io::sink());
            let _ = err_tx.send(bytes);
        });
    }
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(POLL),
            Ok(None) => {
                log::warn!("Sense Remote: {program} did not finish in {timeout:?}, stopped");
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            Err(err) => {
                log::debug!("Sense Remote: {program} wait failed: {err}");
                let _ = child.kill();
                break None;
            }
        }
    };
    let status = status?;
    let bytes = rx.recv_timeout(Duration::from_secs(2)).ok()?;
    let errors = err_rx
        .recv_timeout(Duration::from_millis(200))
        .ok()
        .and_then(|e| error_excerpt(&String::from_utf8_lossy(&e)));
    if !status.success() {
        match errors {
            Some(errors) => log::info!("Sense Remote: {program} exited with {status}: {errors}"),
            None => log::debug!("Sense Remote: {program} exited with {status}"),
        }
        return None;
    }
    if let Some(errors) = errors {
        log::debug!("Sense Remote: {program} error output: {errors}");
    }
    let text = String::from_utf8_lossy(&bytes);
    Some(text.trim_start_matches('\u{feff}').to_owned())
}

#[cfg(test)]
mod excerpt_tests {
    use super::*;

    #[test]
    fn error_text_is_one_short_line() {
        assert_eq!(error_excerpt("  \r\n "), None);
        assert_eq!(
            error_excerpt("Cannot convert value \"NVMe\" to type\r\n  \"System.Int32\".").as_deref(),
            Some("Cannot convert value \"NVMe\" to type \"System.Int32\".")
        );
        assert_eq!(error_excerpt(&"x".repeat(1000)).unwrap().chars().count(), ERROR_EXCERPT_CHARS);
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn output_is_returned() {
        let out = run("/bin/echo", &["hello"], Duration::from_secs(5)).unwrap();
        assert_eq!(out.trim(), "hello");
    }

    #[test]
    fn slow_tool_is_stopped_at_the_limit() {
        let start = Instant::now();
        assert_eq!(run("/bin/sleep", &["5"], Duration::from_millis(300)), None);
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn missing_or_failing_tool_gives_none() {
        assert_eq!(run("/nonexistent/tool", &[], Duration::from_secs(1)), None);
        assert_eq!(run("/bin/sh", &["-c", "exit 3"], Duration::from_secs(5)), None);
    }
}
