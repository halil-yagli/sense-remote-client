//! Tests of the video call camera side (E1a acceptance: profile choice, error paths, wire
//! limits, encoder/decoder round trip and key frame spacing, the capture thread with a fake
//! camera). Nothing here needs a real camera.

use super::capture::{
    choose_format, classify_error, crop_rect, desc_label, scale_to_rgba, CamError, Fourcc,
    FramePacer, PixelOrder, Raw, RgbaFrame, Source, SrcFormat,
};
use super::decode::{CamDecoder, Decoded};
use super::encode::{quality_ratio, CamEncoder, KEY_INTERVAL};
use super::pace::{self, LinkGrade, Pacer, Profile};
use super::wire::{self, CamFrame, CamState, Ctl, WireError};
use super::{CamSender, SenderEvent};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

// ---- pace ------------------------------------------------------------------------------------

#[test]
fn profile_table() {
    assert_eq!(Profile::P1.size(), Some((640, 360)));
    assert_eq!(Profile::P1.fps(), 15);
    assert_eq!(Profile::P1.bitrate_kbps(), 450);
    assert_eq!(Profile::P2.size(), Some((320, 180)));
    assert_eq!(Profile::P2.fps(), 10);
    assert_eq!(Profile::P2.bitrate_kbps(), 150);
    assert_eq!(Profile::P3.size(), None);
    assert_eq!(Profile::P3.fps(), 0);
    for p in [Profile::P1, Profile::P2, Profile::P3] {
        assert_eq!(Profile::from_u8(p.to_u8()), p);
    }
}

#[test]
fn target_profile() {
    use LinkGrade::*;
    assert_eq!(pace::target(Good, false, None), Profile::P1);
    assert_eq!(pace::target(Good, true, None), Profile::P2, "relay");
    assert_eq!(pace::target(Wavy, false, None), Profile::P2);
    assert_eq!(pace::target(Bad, false, None), Profile::P3);
    assert_eq!(pace::target(Good, false, Some(0.49)), Profile::P3, "screen below half");
    assert_eq!(pace::target(Good, false, Some(0.5)), Profile::P1);
    assert_eq!(pace::target(Good, false, Some(f32::NAN)), Profile::P1, "no number, no pause");
    assert_eq!(pace::target(Wavy, true, Some(0.9)), Profile::P2);
}

#[test]
fn profile_goes_down_now_and_up_after_ten_seconds() {
    use LinkGrade::*;
    let s = Duration::from_secs;
    // Down: immediate, whatever the clock says.
    assert_eq!(pace::profile(Bad, false, None, Profile::P1, s(0)), Profile::P3);
    assert_eq!(pace::profile(Wavy, false, None, Profile::P1, s(0)), Profile::P2);
    assert_eq!(pace::profile(Good, false, Some(0.3), Profile::P2, s(0)), Profile::P3);
    // Up: only after 10 s of the better condition.
    assert_eq!(pace::profile(Good, false, None, Profile::P2, s(9)), Profile::P2);
    assert_eq!(pace::profile(Good, false, None, Profile::P2, s(10)), Profile::P1);
    assert_eq!(pace::profile(Wavy, false, None, Profile::P3, s(3)), Profile::P3);
    assert_eq!(pace::profile(Wavy, false, None, Profile::P3, s(10)), Profile::P2);
    // Same: stays.
    assert_eq!(pace::profile(Good, false, None, Profile::P1, s(0)), Profile::P1);
}

#[test]
fn pacer_keeps_the_clock() {
    use LinkGrade::*;
    let t0 = Instant::now();
    let at = |secs: u64| t0 + Duration::from_secs(secs);
    let mut p = Pacer::new(Profile::P1);
    assert_eq!(p.update(Wavy, false, None, at(0)), Profile::P2);
    for t in 1..11 {
        assert_eq!(p.update(Good, false, None, at(t)), Profile::P2, "t={}", t);
    }
    assert_eq!(p.update(Good, false, None, at(11)), Profile::P1);
    // A dip restarts the 10 s.
    assert_eq!(p.update(Bad, false, None, at(12)), Profile::P3);
    assert_eq!(p.update(Good, false, None, at(13)), Profile::P3);
    assert_eq!(p.update(Wavy, false, None, at(18)), Profile::P3);
    assert_eq!(p.update(Bad, false, None, at(19)), Profile::P3);
    assert_eq!(p.update(Good, false, None, at(20)), Profile::P3);
    assert_eq!(p.update(Good, false, None, at(29)), Profile::P3);
    assert_eq!(p.update(Good, false, None, at(30)), Profile::P1);
    assert_eq!(p.current(), Profile::P1);
}

// ---- wire ------------------------------------------------------------------------------------

#[test]
fn ctl_round_trip() {
    let all = vec![
        Ctl::hello(),
        Ctl::State {
            cam: CamState::On,
            w: 640,
            h: 360,
        },
        Ctl::State {
            cam: CamState::Blocked,
            w: 0,
            h: 0,
        },
        Ctl::Key,
        Ctl::Pause {
            why: "link".to_owned(),
        },
        Ctl::Resume,
    ];
    for c in all {
        let bytes = wire::encode_ctl(&c);
        assert!(bytes.len() <= wire::MAX_CTL_BYTES);
        assert_eq!(wire::decode_ctl(&bytes), Some(c));
    }
    let hello = String::from_utf8(wire::encode_ctl(&Ctl::hello())).unwrap();
    assert!(hello.contains("\"t\":\"hello\"") && hello.contains("\"codecs\":[\"vp8\"]"));
    for s in ["on", "off", "none", "denied", "busy", "blocked"] {
        assert_eq!(CamState::parse(s).map(|c| c.as_str()), Some(s));
    }
}

#[test]
fn ctl_ignores_what_it_does_not_know() {
    let ignored: Vec<&[u8]> = vec![
        b"",
        b"not json",
        b"{\"v\":1}",
        b"{\"t\":\"key\"}",
        b"{\"v\":0,\"t\":\"key\"}",
        b"{\"v\":1,\"t\":\"turn-on\"}",
        b"{\"v\":1,\"t\":\"state\",\"cam\":\"maybe\"}",
        b"[1,2,3]",
    ];
    for b in ignored {
        assert_eq!(wire::decode_ctl(b), None, "{:?}", String::from_utf8_lossy(b));
    }
    let long = format!("{{\"v\":1,\"t\":\"key\",\"pad\":\"{}\"}}", "x".repeat(1100));
    assert_eq!(wire::decode_ctl(long.as_bytes()), None, "over 1 KB");
    // A newer sender's extra fields are ignored, not refused.
    assert_eq!(
        wire::decode_ctl(b"{\"v\":2,\"t\":\"key\",\"extra\":true}"),
        Some(Ctl::Key)
    );
}

#[test]
fn frame_round_trip_and_limits() {
    let f = CamFrame {
        data: vec![1, 2, 3, 4, 5],
        key: true,
        pts: 1234,
    };
    let bytes = wire::encode_frame(&f).unwrap();
    assert_eq!(wire::decode_frame(&bytes), Some(f));

    let big = CamFrame {
        data: vec![7u8; wire::MAX_FRAME_BYTES],
        key: false,
        pts: 0,
    };
    assert!(matches!(wire::encode_frame(&big), Err(WireError::TooBig(n)) if n > wire::MAX_FRAME_BYTES));

    assert_eq!(wire::decode_frame(&[]), None);
    assert_eq!(wire::decode_frame(&[0xff, 0xff, 0xff]), None, "garbage");
    assert_eq!(wire::decode_frame(&vec![0u8; wire::MAX_FRAME_BYTES + 1]), None);

    use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames, VideoFrame};
    use hbb_common::protobuf::Message as _;
    let one = || EncodedVideoFrame {
        data: hbb_common::bytes::Bytes::from(vec![9u8; 4]),
        key: true,
        ..Default::default()
    };
    let mut vp9 = VideoFrame::new();
    vp9.set_vp9s(EncodedVideoFrames {
        frames: vec![one()].into(),
        ..Default::default()
    });
    assert_eq!(wire::decode_frame(&vp9.write_to_bytes().unwrap()), None, "not vp8");
    let mut two = VideoFrame::new();
    two.set_vp8s(EncodedVideoFrames {
        frames: vec![one(), one()].into(),
        ..Default::default()
    });
    assert_eq!(wire::decode_frame(&two.write_to_bytes().unwrap()), None, "two frames");
}

// ---- capture (pure parts) --------------------------------------------------------------------

#[test]
fn backend_errors_read_as_kinds() {
    let cases = [
        ("Could not open device: Access is denied. (0x80070005)", CamError::Denied),
        ("Permission denied (os error 13)", CamError::Denied),
        ("MF error 0xC00D3704", CamError::Busy),
        ("Device or resource busy (os error 16)", CamError::Busy),
        ("no camera found", CamError::None),
        ("No such device (os error 19)", CamError::None),
    ];
    for (msg, want) in cases {
        assert_eq!(classify_error(msg), want, "{}", msg);
    }
    assert!(matches!(classify_error("something else"), CamError::Open(_)));
    assert_eq!(CamError::None.kind(), "none");
    assert_eq!(CamError::Denied.kind(), "denied");
    assert_eq!(CamError::Busy.kind(), "busy");
    assert_eq!(CamError::Open("x".into()).kind(), "open");
    assert_eq!(CamError::Busy.state(), CamState::Busy);
    assert_eq!(CamError::Denied.state(), CamState::Denied);
    assert_eq!(CamError::Open("x".into()).state(), CamState::None);
}

#[test]
fn list_description() {
    assert_eq!(desc_label(Some("USB"), Some(1080)), "USB · 1080p");
    assert_eq!(desc_label(Some("Dahili"), Some(720)), "Dahili · 720p");
    assert_eq!(desc_label(None, Some(480)), "480p");
    assert_eq!(desc_label(Some(""), None), "");
}

fn fmt(width: u32, height: u32, fps: u32, fourcc: Fourcc) -> SrcFormat {
    SrcFormat {
        width,
        height,
        fps,
        fourcc,
    }
}

#[test]
fn format_choice() {
    use Fourcc::*;
    // A typical USB webcam.
    let c920 = [
        fmt(1920, 1080, 30, Mjpeg),
        fmt(1280, 720, 30, Mjpeg),
        fmt(640, 480, 30, Mjpeg),
        fmt(640, 360, 30, Mjpeg),
        fmt(640, 480, 30, Yuyv),
        fmt(640, 360, 30, Yuyv),
        fmt(1280, 720, 10, Yuyv),
    ];
    assert_eq!(choose_format(&c920, 640, 360, 15), Some(fmt(640, 360, 30, Yuyv)));
    // Lowest fps that reaches the profile.
    let rates = [fmt(640, 360, 30, Nv12), fmt(640, 360, 15, Nv12), fmt(640, 360, 5, Nv12)];
    assert_eq!(choose_format(&rates, 640, 360, 15), Some(fmt(640, 360, 15, Nv12)));
    // Nothing reaches it: the fastest.
    let slow = [fmt(640, 360, 5, Nv12), fmt(640, 360, 10, Nv12)];
    assert_eq!(choose_format(&slow, 640, 360, 15), Some(fmt(640, 360, 10, Nv12)));
    // 4:3 only: the smallest that covers (cropped later).
    let vga = [fmt(1280, 960, 30, Mjpeg), fmt(640, 480, 30, Mjpeg)];
    assert_eq!(choose_format(&vga, 640, 360, 15), Some(fmt(640, 480, 30, Mjpeg)));
    // Nothing covers: the largest.
    let small = [fmt(320, 240, 30, Yuyv), fmt(160, 120, 30, Yuyv)];
    assert_eq!(choose_format(&small, 640, 360, 15), Some(fmt(320, 240, 30, Yuyv)));
    // Grey and empty: nothing.
    assert_eq!(choose_format(&[fmt(640, 360, 30, Gray)], 640, 360, 15), None);
    assert_eq!(choose_format(&[], 640, 360, 15), None);
}

#[test]
fn crop_to_sixteen_nine() {
    assert_eq!(crop_rect(640, 480, 640, 360), (0, 60, 640, 360));
    assert_eq!(crop_rect(1280, 720, 640, 360), (0, 0, 1280, 720));
    assert_eq!(crop_rect(1000, 360, 640, 360), (180, 0, 640, 360));
    assert_eq!(crop_rect(0, 0, 640, 360), (0, 0, 0, 0));
}

#[test]
fn scaling_averages_crops_and_swaps() {
    // 2x2 RGBA -> 1x1: average.
    let src = [
        10, 20, 30, 255, 30, 40, 50, 255, //
        50, 60, 70, 255, 70, 80, 90, 255,
    ];
    let mut out = Vec::new();
    assert!(scale_to_rgba(&src, 2, 2, 8, PixelOrder::Rgba, 1, 1, &mut out));
    assert_eq!(out, vec![40, 50, 60, 255]);
    // BGRA is turned into RGBA.
    let bgra = [1, 2, 3, 0];
    assert!(scale_to_rgba(&bgra, 1, 1, 4, PixelOrder::Bgra, 1, 1, &mut out));
    assert_eq!(out, vec![3, 2, 1, 255]);
    // Row padding (stride > width * 4) is skipped.
    let padded = [5, 5, 5, 5, 0xEE, 0xEE, 6, 6, 6, 6, 0xEE, 0xEE];
    assert!(scale_to_rgba(&padded, 1, 2, 6, PixelOrder::Rgba, 1, 2, &mut out));
    assert_eq!(out, vec![5, 5, 5, 255, 6, 6, 6, 255]);
    // A taller source is cropped to the middle rows: 4x4 -> 4x2 keeps rows 1 and 2.
    let mut sq = Vec::new();
    for row in 0..4u8 {
        for _ in 0..4 {
            sq.extend_from_slice(&[row * 10, 0, 0, 255]);
        }
    }
    assert!(scale_to_rgba(&sq, 4, 4, 16, PixelOrder::Rgba, 4, 2, &mut out));
    assert_eq!(out[0], 10, "top row of the crop is source row 1");
    assert_eq!(out[4 * 4], 20, "bottom row of the crop is source row 2");
    // Too short for its stated size.
    assert!(!scale_to_rgba(&[0u8; 7], 1, 2, 4, PixelOrder::Rgba, 1, 1, &mut out));
    assert!(!scale_to_rgba(&src, 2, 2, 8, PixelOrder::Rgba, 0, 1, &mut out));
}

#[test]
fn pacer_halves_a_thirty_fps_camera() {
    let t0 = Instant::now();
    let mut p = FramePacer::new();
    let mut n = 0;
    for i in 0..60u64 {
        if p.accept(t0 + Duration::from_micros(i * 33_333), 15) {
            n += 1;
        }
    }
    assert!((29..=31).contains(&n), "accepted {}", n);
    let mut p = FramePacer::new();
    assert!(!p.accept(t0, 0), "fps 0 lets nothing through");
}

// ---- encode / decode -------------------------------------------------------------------------

/// A smooth moving picture (cheap for VP8, so rate control keeps every frame).
fn picture(w: u32, h: u32, i: u32, at: Instant) -> RgbaFrame {
    let mut data = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            data.push(((x + i * 4) % 256) as u8);
            data.push(((y + i * 2) % 256) as u8);
            data.push((((x + y) / 2 + i) % 256) as u8);
            data.push(255);
        }
    }
    RgbaFrame {
        width: w,
        height: h,
        data,
        captured_at: at,
    }
}

#[test]
fn bitrate_ratio_matches_profiles() {
    // base_bitrate(640x360) = 300, (320x180) = 75 kbit/s.
    assert!((quality_ratio(640, 360, 450) - 1.5).abs() < 0.01);
    assert!((quality_ratio(320, 180, 150) - 2.0).abs() < 0.01);
}

#[test]
fn thirty_frames_encode_and_decode() {
    let t0 = Instant::now();
    let mut enc = CamEncoder::new();
    let mut dec = CamDecoder::new();
    let mut decoded = 0;
    let mut first = true;
    let mut last_pts = -1i64;
    for i in 0..30u32 {
        let at = t0 + Duration::from_millis(i as u64 * 66);
        let out = enc.encode(&picture(640, 360, i, at), Profile::P1).unwrap();
        for e in out {
            if first {
                assert!(e.key, "first frame is a key frame");
                first = false;
            }
            assert!(e.payload.len() <= wire::MAX_FRAME_BYTES);
            assert_eq!((e.width, e.height), (640, 360));
            assert_eq!(e.captured_at, at);
            assert!(e.pts_ms > last_pts);
            last_pts = e.pts_ms;
            match dec.decode(&e.payload) {
                Decoded::Picture(p) => {
                    assert_eq!((p.width, p.height), (640, 360));
                    assert_eq!(p.data.len(), 640 * 360 * 4);
                    assert_eq!(p.pts_ms, e.pts_ms);
                    decoded += 1;
                }
                other => panic!("frame {} not decoded: {:?}", i, other),
            }
        }
    }
    assert!(decoded >= 25, "decoded {} of 30", decoded);
}

fn key_times(enc: &mut CamEncoder, t0: Instant, frames: u32, step_ms: u64) -> Vec<Duration> {
    let mut keys = Vec::new();
    for i in 0..frames {
        let at = t0 + Duration::from_millis(i as u64 * step_ms);
        for e in enc.encode(&picture(320, 180, i, at), Profile::P2).unwrap() {
            if e.key {
                keys.push(at - t0);
            }
        }
    }
    keys
}

#[test]
fn key_frame_at_least_every_five_seconds() {
    // P2 at its 10 fps for 12 s.
    let t0 = Instant::now();
    let keys = key_times(&mut CamEncoder::new(), t0, 120, 100);
    assert_eq!(keys.first(), Some(&Duration::ZERO));
    let mut prev = Duration::ZERO;
    for k in keys.iter().skip(1).chain(std::iter::once(&Duration::from_millis(11_900))) {
        assert!(*k - prev <= KEY_INTERVAL, "gap {:?} in {:?}", *k - prev, keys);
        prev = *k;
    }
    // A slow camera (1 frame/s, dark room): the 5 s rule holds in time too.
    let keys = key_times(&mut CamEncoder::new(), t0, 12, 1000);
    let mut prev = Duration::ZERO;
    for k in keys.iter().skip(1).chain(std::iter::once(&Duration::from_secs(11))) {
        assert!(*k - prev <= KEY_INTERVAL, "slow gap {:?} in {:?}", *k - prev, keys);
        prev = *k;
    }
}

#[test]
fn key_on_request_and_on_profile_change() {
    let t0 = Instant::now();
    let at = |i: u32| t0 + Duration::from_millis(i as u64 * 66);
    let mut enc = CamEncoder::new();
    let mut dec = CamDecoder::new();
    for i in 0..5 {
        for e in enc.encode(&picture(640, 360, i, at(i)), Profile::P1).unwrap() {
            assert!(matches!(dec.decode(&e.payload), Decoded::Picture(_)));
        }
    }
    enc.request_key();
    let out = enc.encode(&picture(640, 360, 5, at(5)), Profile::P1).unwrap();
    assert!(out.iter().any(|e| e.key), "requested key frame");
    // P1 -> P2: new size, key frame, decoder follows.
    let out = enc.encode(&picture(320, 180, 6, at(6)), Profile::P2).unwrap();
    assert!(out.first().map(|e| e.key).unwrap_or(false), "size change starts with a key");
    for e in out {
        match dec.decode(&e.payload) {
            Decoded::Picture(p) => assert_eq!((p.width, p.height), (320, 180)),
            other => panic!("{:?}", other),
        }
    }
    // P3 sends nothing; a bad size is refused.
    assert!(enc.encode(&picture(320, 180, 7, at(7)), Profile::P3).unwrap().is_empty());
    assert!(enc.encode(&picture(321, 180, 8, at(8)), Profile::P2).is_err());
}

#[test]
fn decoder_waits_for_a_key_frame() {
    let t0 = Instant::now();
    let mut enc = CamEncoder::new();
    let mut payloads = Vec::new();
    for i in 0..4u32 {
        for e in enc
            .encode(&picture(640, 360, i, t0 + Duration::from_millis(i as u64 * 66)), Profile::P1)
            .unwrap()
        {
            payloads.push((e.key, e.payload));
        }
    }
    assert!(payloads.len() >= 3 && payloads[0].0 && !payloads[1].0);
    let mut dec = CamDecoder::new();
    assert_eq!(dec.decode(b"garbage"), Decoded::Nothing);
    assert_eq!(dec.decode(&payloads[1].1), Decoded::NeedKey, "joined mid-stream");
    assert!(matches!(dec.decode(&payloads[0].1), Decoded::Picture(_)));
    assert!(matches!(dec.decode(&payloads[1].1), Decoded::Picture(_)));
    dec.reset();
    assert_eq!(dec.decode(&payloads[2].1), Decoded::NeedKey, "after reset");
}

// ---- capture thread with a fake camera -------------------------------------------------------

/// 640x480 BGRA with row padding at ~30 fps; fails with `fail` after `fail_after` frames.
struct FakeCam {
    n: u32,
    fail_after: Option<u32>,
    fail: CamError,
}

impl Source for FakeCam {
    fn next(&mut self, _timeout: Duration) -> Result<Option<Raw>, CamError> {
        if let Some(limit) = self.fail_after {
            if self.n >= limit {
                return Err(self.fail.clone());
            }
        }
        std::thread::sleep(Duration::from_millis(33));
        self.n += 1;
        let (w, h, stride) = (640u32, 480u32, 640usize * 4 + 64);
        let mut data = vec![0u8; stride * h as usize];
        for y in 0..h as usize {
            for x in 0..w as usize {
                let o = y * stride + x * 4;
                data[o] = (x as u32 + self.n) as u8;
                data[o + 1] = y as u8;
                data[o + 2] = 128;
                data[o + 3] = 255;
            }
        }
        Ok(Some(Raw {
            data,
            width: w,
            height: h,
            stride,
            order: PixelOrder::Bgra,
        }))
    }
}

#[derive(Default)]
struct Seen {
    previews: Vec<(u32, u32)>,
    encoded: Vec<(bool, u32, u32)>,
    lost: Vec<CamError>,
}

fn start_fake(
    fail_after: Option<u32>,
    fail: CamError,
    profile: Profile,
) -> (Result<CamSender, CamError>, Arc<Mutex<Seen>>) {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let s2 = seen.clone();
    let sender = CamSender::start_with(
        Box::new(move || {
            Ok(Box::new(FakeCam {
                n: 0,
                fail_after,
                fail,
            }) as Box<dyn Source>)
        }),
        profile,
        Box::new(move |ev| {
            let mut s = s2.lock().unwrap();
            match ev {
                SenderEvent::Preview(f) => s.previews.push((f.width, f.height)),
                SenderEvent::Encoded(e) => s.encoded.push((e.key, e.width, e.height)),
                SenderEvent::Lost(e) => s.lost.push(e),
            }
        }),
        Duration::from_secs(10),
    );
    (sender, seen)
}

#[test]
fn sender_streams_previews_and_frames() {
    let (sender, seen) = start_fake(None, CamError::None, Profile::P1);
    let sender = sender.expect("fake camera opens");
    std::thread::sleep(Duration::from_millis(1200));
    {
        let s = seen.lock().unwrap();
        assert!(s.previews.len() >= 5, "previews {}", s.previews.len());
        assert!(s.previews.iter().all(|p| *p == (640, 360)), "cropped + scaled to P1");
        assert!(s.encoded.len() >= 5, "encoded {}", s.encoded.len());
        assert!(s.encoded[0].0, "first encoded is a key frame");
        assert!(s.lost.is_empty());
    }
    // P2: smaller frames; P3: nothing.
    sender.set_profile(Profile::P2);
    std::thread::sleep(Duration::from_millis(600));
    assert!(seen
        .lock()
        .unwrap()
        .encoded
        .iter()
        .any(|e| (e.1, e.2) == (320, 180) && e.0));
    sender.set_profile(Profile::P3);
    std::thread::sleep(Duration::from_millis(300));
    let n = seen.lock().unwrap().encoded.len();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(seen.lock().unwrap().encoded.len(), n, "P3 sends nothing");
    // Key on request.
    sender.set_profile(Profile::P1);
    std::thread::sleep(Duration::from_millis(400));
    let before = seen.lock().unwrap().encoded.len();
    sender.request_key();
    std::thread::sleep(Duration::from_millis(400));
    assert!(seen.lock().unwrap().encoded[before..].iter().any(|e| e.0), "key after request");
    let t = Instant::now();
    sender.stop();
    assert!(t.elapsed() < Duration::from_secs(2), "stop is quick");
}

#[test]
fn sender_open_errors_are_returned() {
    let denied = CamSender::start_with(
        Box::new(|| Err(CamError::Denied)),
        Profile::P1,
        Box::new(|_| {}),
        Duration::from_secs(5),
    );
    assert_eq!(denied.err(), Some(CamError::Denied));
    // Windows tells a busy / blocked camera only when the stream starts: still an open error.
    let (busy, _) = start_fake(Some(0), CamError::Busy, Profile::P1);
    assert_eq!(busy.err(), Some(CamError::Busy));
}

#[test]
fn sender_reports_a_lost_camera() {
    let (sender, seen) = start_fake(Some(4), CamError::None, Profile::P1);
    let _sender = sender.expect("opens");
    std::thread::sleep(Duration::from_millis(800));
    let s = seen.lock().unwrap();
    assert_eq!(s.lost, vec![CamError::None], "unplugged");
    assert!(!s.encoded.is_empty());
}
