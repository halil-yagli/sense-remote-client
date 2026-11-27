//! The other side's camera: `sense.cam` payload to RGBA for the app (at most 640×360).
//!
//! Until a key frame arrives (start, after a decoder error) frames are not decoded and the
//! caller is told to ask for one (`sense.cam-ctl {"t":"key"}`, rate limited by the caller).

use super::wire;
use scrap::{GoogleImage, ImageFormat, ImageRgb, VpxDecoder, VpxDecoderConfig, VpxVideoCodecId};

/// Largest frame we draw; a bigger one is not decoded (the sender never makes one).
pub const MAX_W: u32 = 1280;
pub const MAX_H: u32 = 720;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    /// Tightly packed RGBA.
    pub data: Vec<u8>,
    pub pts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decoded {
    Picture(Picture),
    /// Waiting for a key frame; ask the sender for one.
    NeedKey,
    /// Not a camera frame we understand, or libvpx gave no picture; ignore.
    Nothing,
}

pub struct CamDecoder {
    dec: Option<VpxDecoder>,
    waiting_key: bool,
    rgb: ImageRgb,
}

impl Default for CamDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl CamDecoder {
    pub fn new() -> Self {
        CamDecoder {
            dec: None,
            waiting_key: true,
            // RGBA bytes are libyuv's "ABGR"; align 1 = no row padding.
            rgb: ImageRgb::new(ImageFormat::ABGR, 1),
        }
    }

    /// Forget the stream (the other side switched camera or stopped).
    pub fn reset(&mut self) {
        self.dec = None;
        self.waiting_key = true;
    }

    pub fn decode(&mut self, payload: &[u8]) -> Decoded {
        let Some(frame) = wire::decode_frame(payload) else {
            return Decoded::Nothing;
        };
        if self.waiting_key && !frame.key {
            return Decoded::NeedKey;
        }
        if self.dec.is_none() {
            match VpxDecoder::new(VpxDecoderConfig {
                codec: VpxVideoCodecId::VP8,
            }) {
                Ok(d) => self.dec = Some(d),
                Err(e) => {
                    hbb_common::log::warn!("sense camera: vp8 decoder: {}", e);
                    return Decoded::Nothing;
                }
            }
        }
        let Some(dec) = self.dec.as_mut() else {
            return Decoded::Nothing;
        };
        let mut last = None;
        let broken = match dec.decode(&frame.data) {
            Ok(frames) => {
                for img in frames {
                    last = Some(img);
                }
                false
            }
            Err(_) => true,
        };
        if broken {
            // Broken stream: start over at the next key frame.
            drop(last);
            self.dec = None;
            self.waiting_key = true;
            return Decoded::NeedKey;
        }
        let Some(dec) = self.dec.as_mut() else {
            return Decoded::Nothing;
        };
        // Same as RustDesk's screen decoder (`codec.rs`, handle_vpxs_video_frame).
        if let Ok(frames) = dec.flush() {
            for img in frames {
                last = Some(img);
            }
        }
        let Some(img) = last else {
            return Decoded::Nothing;
        };
        let (w, h) = (img.width() as u32, img.height() as u32);
        if w == 0 || h == 0 || w > MAX_W || h > MAX_H {
            return Decoded::Nothing;
        }
        self.waiting_key = false;
        img.to(&mut self.rgb);
        Decoded::Picture(Picture {
            width: w,
            height: h,
            data: self.rgb.raw.clone(),
            pts_ms: frame.pts,
        })
    }
}
