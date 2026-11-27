//! Camera frames to VP8 (libvpx, software), independent of the screen's codec negotiation
//! (fizibilite §2.1 "Kodlama"). Every build has the encoder and both sides have the decoder.
//!
//! Key frames: at the start, after a size (profile) change, when the receiver asks
//! (`request_key`) and at the latest every 5 s. Libvpx places a key every `fps * 5` frames;
//! when the camera delivers slower than its profile (dark room), the encoder is rebuilt after
//! 5 s so the rule holds in time, not only in frames.

use super::{
    capture::RgbaFrame,
    pace::Profile,
    wire::{self, CamFrame, WireError},
};
use hbb_common::{anyhow::anyhow, ResultType};
use scrap::{
    codec::{base_bitrate, EncoderApi, EncoderCfg},
    VpxEncoder, VpxEncoderConfig, VpxVideoCodecId, STRIDE_ALIGN,
};
use std::time::{Duration, Instant};

/// Longest gap between two key frames.
pub const KEY_INTERVAL: Duration = Duration::from_secs(5);

/// One frame ready for the connection.
#[derive(Debug, Clone)]
pub struct EncodedCam {
    /// The `sense.cam` payload (`VideoFrame` bytes, at most 256 KB).
    pub payload: Vec<u8>,
    pub key: bool,
    pub width: u32,
    pub height: u32,
    /// When the camera delivered the frame. The sender drops a frame that waited too long in
    /// its queue (300 ms, §3.2) by this stamp.
    pub captured_at: Instant,
    /// Milliseconds since this stream started, also inside the payload.
    pub pts_ms: i64,
}

impl EncodedCam {
    /// Age of the frame now (capture → this moment).
    pub fn age(&self) -> Duration {
        self.captured_at.elapsed()
    }
}

/// libvpx quality ratio that gives the profile's bitrate (`bitrate = base_bitrate * ratio`).
pub fn quality_ratio(width: u32, height: u32, target_kbps: u32) -> f32 {
    let base = base_bitrate(width, height).max(1) as f32;
    (target_kbps as f32 / base).clamp(0.1, 4.0)
}

/// Bitrate step down after an over-sized frame (256 KB rule), and the floor.
const OVERSIZE_STEP: f32 = 0.5;
const MIN_BITRATE_SCALE: f32 = 0.125;

pub struct CamEncoder {
    enc: Option<VpxEncoder>,
    size: (u32, u32),
    fps: u32,
    bitrate_scale: f32,
    want_key: bool,
    last_key: Option<Instant>,
    started: Option<Instant>,
    yuv: Vec<u8>,
}

impl Default for CamEncoder {
    fn default() -> Self {
        Self::new()
    }
}

impl CamEncoder {
    pub fn new() -> Self {
        CamEncoder {
            enc: None,
            size: (0, 0),
            fps: 0,
            bitrate_scale: 1.0,
            want_key: true,
            last_key: None,
            started: None,
            yuv: Vec::new(),
        }
    }

    /// The next frame is a key frame (receiver asked, camera switched).
    pub fn request_key(&mut self) {
        self.want_key = true;
    }

    fn build(&mut self, width: u32, height: u32, profile: Profile) -> ResultType<()> {
        let kbps = (profile.bitrate_kbps() as f32 * self.bitrate_scale).max(1.0) as u32;
        let fps = profile.fps().max(1);
        let cfg = EncoderCfg::VPX(VpxEncoderConfig {
            width,
            height,
            quality: quality_ratio(width, height, kbps),
            codec: VpxVideoCodecId::VP8,
            keyframe_interval: Some((fps * KEY_INTERVAL.as_secs() as u32) as usize),
        });
        self.enc = None; // free the old context first
        self.enc = Some(VpxEncoder::new(cfg, false)?);
        self.size = (width, height);
        self.fps = fps;
        Ok(())
    }

    /// Encodes one frame for `profile`. Empty when the profile is paused (P3) or libvpx's rate
    /// control dropped the frame; an over-sized frame is not sent and the bitrate is halved.
    pub fn encode(&mut self, frame: &RgbaFrame, profile: Profile) -> ResultType<Vec<EncodedCam>> {
        if profile.size().is_none() {
            return Ok(Vec::new());
        }
        let (w, h) = (frame.width, frame.height);
        if w == 0 || h == 0 || w % 2 != 0 || h % 2 != 0 {
            return Err(anyhow!("camera frame size {}x{} not usable", w, h));
        }
        if frame.data.len() < w as usize * h as usize * 4 {
            return Err(anyhow!("camera frame too short"));
        }
        let at = frame.captured_at;
        let started = *self.started.get_or_insert(at);
        let key_overdue = self
            .last_key
            .map(|k| at.saturating_duration_since(k) >= KEY_INTERVAL)
            .unwrap_or(true);
        if self.enc.is_none()
            || self.size != (w, h)
            || self.fps != profile.fps().max(1)
            || self.want_key
            || key_overdue
        {
            self.build(w, h, profile)?;
            self.want_key = false;
        }
        let Some(enc) = self.enc.as_mut() else {
            return Ok(Vec::new());
        };
        let fmt = enc.yuvfmt();
        // RGBA bytes are libyuv's "ABGR".
        self.yuv.resize(fmt.h * fmt.stride[0] * 2, 0);
        let (y, u, v) = (0usize, fmt.u, fmt.v);
        let ret = unsafe {
            scrap::ABGRToI420(
                frame.data.as_ptr(),
                (w * 4) as _,
                self.yuv[y..].as_mut_ptr(),
                fmt.stride[0] as _,
                self.yuv[u..].as_mut_ptr(),
                fmt.stride[1] as _,
                self.yuv[v..].as_mut_ptr(),
                fmt.stride[2] as _,
                w as _,
                h as _,
            )
        };
        if ret != 0 {
            return Err(anyhow!("ABGRToI420 failed: {}", ret));
        }
        let pts = at.saturating_duration_since(started).as_millis() as i64;
        let mut frames: Vec<CamFrame> = Vec::new();
        for f in enc
            .encode(pts, &self.yuv, STRIDE_ALIGN)
            .map_err(|e| anyhow!("vp8 encode: {}", e))?
        {
            frames.push(CamFrame {
                data: f.data.to_vec(),
                key: f.key,
                pts: f.pts,
            });
        }
        for f in enc.flush().map_err(|e| anyhow!("vp8 flush: {}", e))? {
            frames.push(CamFrame {
                data: f.data.to_vec(),
                key: f.key,
                pts: f.pts,
            });
        }
        let mut out = Vec::new();
        for f in frames {
            match wire::encode_frame(&f) {
                Ok(payload) => {
                    if f.key {
                        self.last_key = Some(at);
                    }
                    out.push(EncodedCam {
                        payload,
                        key: f.key,
                        width: w,
                        height: h,
                        captured_at: at,
                        pts_ms: f.pts,
                    });
                }
                Err(WireError::TooBig(n)) => {
                    hbb_common::log::warn!("sense camera: frame of {} bytes not sent", n);
                    self.bitrate_scale = (self.bitrate_scale * OVERSIZE_STEP).max(MIN_BITRATE_SCALE);
                    self.want_key = true;
                    break;
                }
            }
        }
        Ok(out)
    }
}
