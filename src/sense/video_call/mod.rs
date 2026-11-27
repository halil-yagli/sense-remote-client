//! Sense Remote (S11 Faz E, E1a): camera side of the two-way video call (YH O11, S5;
//! fizibilite `Calisma/fizibilite/2026-11-27_goruntulu-arama.md` §2–§3).
//!
//! Interface for E1b (connection, IPC, FFI), which only calls what is `pub` here:
//! - `list_cameras()` / `permission()`: the camera list `{"id","name","desc"}` and the error
//!   word (`CamError::kind()`: none / denied / busy / open).
//! - `CamSender::start(device_id, profile, sink)`: opens the camera and, on its own thread,
//!   crops/scales to the profile, encodes VP8 and hands the sink a `Preview` (RGBA, for the
//!   "you" box) and an `Encoded` (`sense.cam` payload + capture time) per frame; `Lost` when
//!   the camera goes away. `set_profile`, `request_key`, `stop`.
//! - `CamDecoder::decode(payload)`: the other side's frames to RGBA, or "ask for a key frame".
//! - `wire`: `sense.cam` / `sense.cam-ctl` encode/decode with the 256 KB / 1 KB limits.
//! - `pace`: profiles P1/P2/P3 and the down-now / up-after-10-s rule.
//!
//! The camera is opened only by the person at that computer (there is no remote "turn on"
//! message, §2.3-2). Frames never go to the session recording, disk, the log, the panel or a
//! diagnostics bundle (§2.3-4): this module has no path to any of them.

pub mod capture;
pub mod decode;
pub mod encode;
pub mod pace;
pub mod wire;

#[cfg(target_os = "macos")]
mod cam_mac;

#[cfg(test)]
mod tests;

pub use capture::{list_cameras, permission, CamError, CameraInfo, Permission, RgbaFrame};
pub use decode::{CamDecoder, Decoded, Picture};
pub use encode::{CamEncoder, EncodedCam};
pub use pace::{LinkGrade, Pacer, Profile};

use capture::{Capture, CaptureEvent, Opener};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

/// What a running camera hands its owner, on the camera thread. Keep the sink short: send the
/// payload to the connection queue, the preview to the app, and return.
pub enum SenderEvent {
    /// This side's own picture for the "you" box (always shown while the camera is on, §2.3-6).
    Preview(Arc<RgbaFrame>),
    Encoded(EncodedCam),
    /// The camera stopped delivering; the sender has ended. Tell the other side `state`.
    Lost(CamError),
}

pub type SenderSink = Box<dyn FnMut(SenderEvent) + Send>;

/// This side's camera, open and sending. Stops (and closes the camera) when dropped.
pub struct CamSender {
    capture: Capture,
    want_key: Arc<AtomicBool>,
}

impl CamSender {
    /// Opens `device_id` (`""` = the first/default camera). Blocks until the camera delivered
    /// its first frame or failed (macOS may first ask the person for the permission); call it
    /// off the UI thread.
    pub fn start(device_id: &str, profile: Profile, sink: SenderSink) -> Result<CamSender, CamError> {
        let want_key = Arc::new(AtomicBool::new(false));
        let capture = Capture::start(device_id, profile, Self::pipeline(want_key.clone(), sink))?;
        Ok(CamSender { capture, want_key })
    }

    pub(crate) fn start_with(
        opener: Opener,
        profile: Profile,
        sink: SenderSink,
        open_timeout: std::time::Duration,
    ) -> Result<CamSender, CamError> {
        let want_key = Arc::new(AtomicBool::new(false));
        let capture = Capture::start_with(
            opener,
            profile,
            Self::pipeline(want_key.clone(), sink),
            open_timeout,
        )?;
        Ok(CamSender { capture, want_key })
    }

    fn pipeline(want_key: Arc<AtomicBool>, mut sink: SenderSink) -> capture::CaptureSink {
        let mut encoder = CamEncoder::new();
        Box::new(move |ev| match ev {
            CaptureEvent::Frame(frame) => {
                let profile = profile_of(&frame);
                if want_key.swap(false, Ordering::Relaxed) {
                    encoder.request_key();
                }
                let frame = Arc::new(frame);
                sink(SenderEvent::Preview(frame.clone()));
                match encoder.encode(&frame, profile) {
                    Ok(list) => {
                        for e in list {
                            sink(SenderEvent::Encoded(e));
                        }
                    }
                    Err(e) => hbb_common::log::warn!("sense camera: encode: {}", e),
                }
            }
            CaptureEvent::Lost(e) => sink(SenderEvent::Lost(e)),
        })
    }

    /// Profile for the next frames (P3 pauses: the camera stays open, nothing is sent).
    pub fn set_profile(&self, p: Profile) {
        self.capture.set_profile(p);
    }

    pub fn profile(&self) -> Profile {
        self.capture.profile()
    }

    /// The other side asked for a key frame (`sense.cam-ctl {"t":"key"}`).
    pub fn request_key(&self) {
        self.want_key.store(true, Ordering::Relaxed);
    }

    /// Closes the camera.
    pub fn stop(self) {
        self.capture.stop();
    }
}

/// The capture thread scales to the profile's size, so the size tells the profile.
fn profile_of(frame: &RgbaFrame) -> Profile {
    match Profile::P2.size() {
        Some(s) if s == (frame.width, frame.height) => Profile::P2,
        _ => Profile::P1,
    }
}
