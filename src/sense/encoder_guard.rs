// Sense Remote (Sürüm 4 #82): hardware encoder safety net.
// On machines with two GPUs the hardware (VRAM / RAM) encoder can start without ever producing a
// frame, which leaves the Controller with a black screen. If the first encoded frame does not
// come within FIRST_FRAME_TIMEOUT, hardware encoding is switched off for that monitor and the
// software (VP9) encoder takes over. Pure decision functions here, wiring in video_service.rs.

use std::{
    collections::HashSet,
    sync::Mutex,
    time::Duration,
};

/// Time a hardware encoder gets to emit its first encoded frame.
pub const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(3);

lazy_static::lazy_static! {
    static ref HW_DENIED: Mutex<HashSet<String>> = Default::default();
}

/// True when a hardware encoder has been running for longer than the timeout without a frame.
pub fn first_frame_overdue(
    since_start: Duration,
    warmed_up: bool,
    is_hardware: bool,
    timeout: Duration,
) -> bool {
    is_hardware && !warmed_up && since_start >= timeout
}

/// Turns hardware encoding off for one video service (monitor) until the process restarts.
pub fn deny_hardware(service_name: &str) {
    HW_DENIED.lock().unwrap().insert(service_name.to_owned());
}

pub fn hardware_denied(service_name: &str) -> bool {
    HW_DENIED.lock().unwrap().contains(service_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: Duration = Duration::from_secs(3);

    #[test]
    fn overdue_only_for_silent_hardware_encoder() {
        assert!(!first_frame_overdue(Duration::from_millis(2999), false, true, T));
        assert!(first_frame_overdue(Duration::from_secs(3), false, true, T));
        assert!(first_frame_overdue(Duration::from_secs(30), false, true, T));
        // already produced a frame
        assert!(!first_frame_overdue(Duration::from_secs(30), true, true, T));
        // software encoder is never switched away from
        assert!(!first_frame_overdue(Duration::from_secs(30), false, false, T));
    }

    #[test]
    fn deny_is_per_monitor() {
        deny_hardware("test-display-a");
        assert!(hardware_denied("test-display-a"));
        assert!(!hardware_denied("test-display-b"));
    }
}
