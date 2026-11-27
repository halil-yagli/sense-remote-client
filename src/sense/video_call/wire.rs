//! Messages of the video call on the session connection (fizibilite 2026-11-27 §3.1). Both ride
//! in `Misc.plugin_request` like `sense.file-offer`; older builds ignore ids they do not know.
//!
//! - `sense.cam-ctl`: UTF-8 JSON, at most 1 KB. Unknown `t` or broken JSON is ignored.
//! - `sense.cam`: the bytes of a `VideoFrame` with exactly one VP8 frame (`vp8s`), at most
//!   256 KB. `display` is 0 and ignored.
//!
//! There is deliberately no message that turns the other side's camera on (§2.3-2): a camera
//! is turned on and off only by the person sitting at it.

use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames, VideoFrame};
use hbb_common::{bytes::Bytes, protobuf::Message as _};
use serde_json::{json, Value};

pub const ID_CAM: &str = "sense.cam";
pub const ID_CTL: &str = "sense.cam-ctl";
pub const VERSION: u64 = 1;
pub const MAX_CTL_BYTES: usize = 1024;
pub const MAX_FRAME_BYTES: usize = 256 * 1024;
pub const CODEC_VP8: &str = "vp8";

/// A side's camera, as the other side is told.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CamState {
    On,
    Off,
    /// No camera on this computer.
    None,
    /// The system refuses the camera (privacy setting / macOS permission).
    Denied,
    /// Another app holds the camera.
    Busy,
    /// Host only: the panel's camera permission (`enable-camera`) is off.
    Blocked,
}

impl CamState {
    pub fn as_str(self) -> &'static str {
        match self {
            CamState::On => "on",
            CamState::Off => "off",
            CamState::None => "none",
            CamState::Denied => "denied",
            CamState::Busy => "busy",
            CamState::Blocked => "blocked",
        }
    }

    pub fn parse(s: &str) -> Option<CamState> {
        Some(match s {
            "on" => CamState::On,
            "off" => CamState::Off,
            "none" => CamState::None,
            "denied" => CamState::Denied,
            "busy" => CamState::Busy,
            "blocked" => CamState::Blocked,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Ctl {
    /// Once at the start of the connection, both ways.
    Hello { video: bool, codecs: Vec<String> },
    State { cam: CamState, w: u32, h: u32 },
    /// The receiver asks for a key frame (first frame, decoder error).
    Key,
    /// The sender went to P3 (`why`: "link") / came back.
    Pause { why: String },
    Resume,
}

impl Ctl {
    /// This build's hello.
    pub fn hello() -> Ctl {
        Ctl::Hello {
            video: true,
            codecs: vec![CODEC_VP8.to_owned()],
        }
    }
}

pub fn encode_ctl(ctl: &Ctl) -> Vec<u8> {
    let v = match ctl {
        Ctl::Hello { video, codecs } => {
            json!({"v": VERSION, "t": "hello", "video": video, "codecs": codecs})
        }
        Ctl::State { cam, w, h } => {
            json!({"v": VERSION, "t": "state", "cam": cam.as_str(), "w": w, "h": h})
        }
        Ctl::Key => json!({"v": VERSION, "t": "key"}),
        Ctl::Pause { why } => json!({"v": VERSION, "t": "pause", "why": why}),
        Ctl::Resume => json!({"v": VERSION, "t": "resume"}),
    };
    v.to_string().into_bytes()
}

fn u32_field(v: &Value, key: &str) -> u32 {
    v.get(key)
        .and_then(Value::as_u64)
        .map(|x| x.min(u32::MAX as u64) as u32)
        .unwrap_or(0)
}

/// `None` for anything this build does not understand (too long, not JSON, no or unknown
/// `t`, missing version); callers drop it silently.
pub fn decode_ctl(bytes: &[u8]) -> Option<Ctl> {
    if bytes.len() > MAX_CTL_BYTES {
        return None;
    }
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let ver = v.get("v")?.as_u64()?;
    if ver < 1 {
        return None;
    }
    match v.get("t")?.as_str()? {
        "hello" => Some(Ctl::Hello {
            video: v.get("video").and_then(Value::as_bool).unwrap_or(false),
            codecs: v
                .get("codecs")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .take(8)
                        .map(|s| s.chars().take(16).collect())
                        .collect()
                })
                .unwrap_or_default(),
        }),
        "state" => Some(Ctl::State {
            cam: CamState::parse(v.get("cam")?.as_str()?)?,
            w: u32_field(&v, "w"),
            h: u32_field(&v, "h"),
        }),
        "key" => Some(Ctl::Key),
        "pause" => Some(Ctl::Pause {
            why: v
                .get("why")
                .and_then(Value::as_str)
                .unwrap_or("")
                .chars()
                .take(16)
                .collect(),
        }),
        "resume" => Some(Ctl::Resume),
        _ => None,
    }
}

/// One encoded camera frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CamFrame {
    /// VP8 bitstream of one frame.
    pub data: Vec<u8>,
    pub key: bool,
    /// Milliseconds since the sender's camera stream started (capture time).
    pub pts: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    /// Over `MAX_FRAME_BYTES`; the encoder lowers its bitrate and sends a key frame next.
    TooBig(usize),
}

pub fn encode_frame(f: &CamFrame) -> Result<Vec<u8>, WireError> {
    let mut vf = VideoFrame::new();
    vf.set_vp8s(EncodedVideoFrames {
        frames: vec![EncodedVideoFrame {
            data: Bytes::from(f.data.clone()),
            key: f.key,
            pts: f.pts,
            ..Default::default()
        }]
        .into(),
        ..Default::default()
    });
    let bytes = vf.write_to_bytes().unwrap_or_default();
    if bytes.is_empty() {
        return Err(WireError::TooBig(0));
    }
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(WireError::TooBig(bytes.len()));
    }
    Ok(bytes)
}

/// `None` unless it is a `VideoFrame` of at most 256 KB with exactly one non-empty VP8 frame.
pub fn decode_frame(bytes: &[u8]) -> Option<CamFrame> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
        return None;
    }
    let vf = VideoFrame::parse_from_bytes(bytes).ok()?;
    if !vf.has_vp8s() {
        return None;
    }
    let frames = &vf.vp8s().frames;
    if frames.len() != 1 || frames[0].data.is_empty() {
        return None;
    }
    let f = &frames[0];
    Some(CamFrame {
        data: f.data.to_vec(),
        key: f.key,
        pts: f.pts,
    })
}
