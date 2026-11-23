//! Sense Remote (B11): the log line after a cancelled download says what really happened to
//! the `.part` file. A missing file is fine (nothing was written yet); any other failure leaves
//! the file behind, which the next download may resume, and is logged as a warning.

use hbb_common::log;

/// Pure: `(warn, line)` for the result of removing the partial file.
pub fn describe(result: &std::io::Result<()>) -> (bool, String) {
    match result {
        Ok(()) => (false, "Sense Remote: update download cancelled".to_owned()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            (false, "Sense Remote: update download cancelled, no partial file".to_owned())
        }
        Err(err) => (
            true,
            format!("Sense Remote: update download cancelled, partial file not removed: {err}"),
        ),
    }
}

pub fn removed(result: std::io::Result<()>) {
    let (warn, line) = describe(&result);
    if warn {
        log::warn!("{line}");
    } else {
        log::info!("{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Error, ErrorKind};

    #[test]
    fn only_a_real_failure_warns() {
        assert!(!describe(&Ok(())).0);
        assert!(!describe(&Err(Error::from(ErrorKind::NotFound))).0);
        let (warn, line) = describe(&Err(Error::from(ErrorKind::PermissionDenied)));
        assert!(warn);
        assert!(line.contains("not removed"));
    }
}
