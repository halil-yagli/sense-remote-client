//! Sense Remote (S11 E1a): camera glue for the two-way video call, Windows (Media Foundation)
//! and Linux (V4L2) through `nokhwa`. macOS has its own AVFoundation module in the app crate
//! (`src/sense/video_call/cam_mac.*`); the nokhwa AVFoundation backend is not used (see there).
//!
//! Only device access lives here: list, open with a format the caller picks, RGBA frames. The
//! choices (which format, how errors read, scaling, pacing, encoding) are pure functions in
//! `src/sense/video_call/` where the app's tests run. RustDesk's "view camera" (`Cameras`,
//! `CameraCapturer` in `camera.rs`) is untouched and keeps its own path.

use nokhwa::{
    pixel_format::RgbAFormat,
    query,
    utils::{ApiBackend, CameraFormat, CameraIndex, FrameFormat, RequestedFormat, RequestedFormatType},
    Camera,
};

/// Pixel formats a camera may offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Fourcc {
    Mjpeg,
    Yuyv,
    Nv12,
    Gray,
    Rgb,
}

impl Fourcc {
    fn from_nokhwa(f: FrameFormat) -> Self {
        match f {
            FrameFormat::MJPEG => Fourcc::Mjpeg,
            FrameFormat::YUYV => Fourcc::Yuyv,
            FrameFormat::NV12 => Fourcc::Nv12,
            FrameFormat::GRAY => Fourcc::Gray,
            FrameFormat::RAWRGB => Fourcc::Rgb,
        }
    }

    fn to_nokhwa(self) -> FrameFormat {
        match self {
            Fourcc::Mjpeg => FrameFormat::MJPEG,
            Fourcc::Yuyv => FrameFormat::YUYV,
            Fourcc::Nv12 => FrameFormat::NV12,
            Fourcc::Gray => FrameFormat::GRAY,
            Fourcc::Rgb => FrameFormat::RAWRGB,
        }
    }
}

/// One capture mode of a camera.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Format {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub fourcc: Fourcc,
}

impl Format {
    fn from_nokhwa(f: &CameraFormat) -> Self {
        Format {
            width: f.width(),
            height: f.height(),
            fps: f.frame_rate(),
            fourcc: Fourcc::from_nokhwa(f.format()),
        }
    }

    fn to_nokhwa(self) -> CameraFormat {
        CameraFormat::new_from(self.width, self.height, self.fourcc.to_nokhwa(), self.fps)
    }
}

/// A camera as the system lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Info {
    /// Stable id: the system's device path (Windows symbolic link, Linux `/dev/video*`) when
    /// there is one, else `idx:<n>`.
    pub id: String,
    pub name: String,
    /// Bus hint from the device path ("usb"), empty when unknown.
    pub bus: String,
    /// Highest frame height the camera offers; only when `list(true)` could open it.
    pub max_height: Option<u32>,
}

fn id_of(info: &nokhwa::utils::CameraInfo) -> String {
    let misc = info.misc();
    if !misc.trim().is_empty() {
        return misc;
    }
    match info.index() {
        CameraIndex::Index(i) => format!("idx:{}", i),
        CameraIndex::String(s) => format!("idx:{}", s),
    }
}

fn bus_of(info: &nokhwa::utils::CameraInfo) -> String {
    let misc = info.misc().to_ascii_lowercase();
    if misc.contains("usb#") || misc.contains("usb-") || misc.contains("\\usb") {
        "usb".to_owned()
    } else {
        String::new()
    }
}

fn open_any(index: &CameraIndex) -> Result<Camera, String> {
    Camera::new(
        index.clone(),
        RequestedFormat::new::<RgbAFormat>(RequestedFormatType::None),
    )
    .map_err(|e| e.to_string())
}

/// Cameras on this computer. `probe` opens each one (no stream) to read its highest
/// resolution for the list's short description; a camera that cannot be opened is still listed.
pub fn list(probe: bool) -> Result<Vec<Info>, String> {
    let cameras = query(ApiBackend::Auto).map_err(|e| e.to_string())?;
    let mut out: Vec<Info> = Vec::new();
    for info in &cameras {
        let id = id_of(info);
        // nokhwa may list one physical camera twice on Linux (upstream issue 171).
        if out.iter().any(|x| x.id == id) {
            continue;
        }
        let max_height = if probe {
            open_any(info.index())
                .ok()
                .and_then(|mut cam| cam.compatible_camera_formats().ok())
                .and_then(|fmts| fmts.iter().map(|f| f.height()).max())
        } else {
            None
        };
        out.push(Info {
            id,
            name: info.human_name(),
            bus: bus_of(info),
            max_height,
        });
    }
    Ok(out)
}

/// An open camera. The stream starts on the first `frame_rgba`; dropping it stops the stream.
pub struct Device {
    cam: Camera,
    format: Format,
}

impl Device {
    /// Opens the camera with this id (empty id: the first camera). `choose` picks one of the
    /// offered formats; `None` keeps the driver's default.
    pub fn open(id: &str, choose: &dyn Fn(&[Format]) -> Option<Format>) -> Result<Device, String> {
        let cameras = query(ApiBackend::Auto).map_err(|e| e.to_string())?;
        let info = if id.is_empty() {
            cameras.first()
        } else {
            cameras.iter().find(|c| id_of(c) == id)
        };
        let Some(info) = info else {
            return Err("no camera found".to_owned());
        };
        let mut cam = open_any(info.index())?;
        let offered: Vec<Format> = cam
            .compatible_camera_formats()
            .map(|v| v.iter().map(Format::from_nokhwa).collect())
            .unwrap_or_default();
        if let Some(want) = choose(&offered) {
            let req = RequestedFormat::new::<RgbAFormat>(RequestedFormatType::Exact(want.to_nokhwa()));
            if let Err(e) = cam.set_camera_requset(req) {
                // The default format still works; the app scales what it gets.
                hbb_common::log::warn!("sense camera: format {:?} refused: {}", want, e);
            }
        }
        let format = Format::from_nokhwa(&cam.camera_format());
        Ok(Device { cam, format })
    }

    pub fn format(&self) -> Format {
        self.format
    }

    /// Next frame as tightly packed RGBA into `out`; returns its size. Blocks until the camera
    /// delivers (one frame interval).
    pub fn frame_rgba(&mut self, out: &mut Vec<u8>) -> Result<(u32, u32), String> {
        if !self.cam.is_stream_open() {
            self.cam.open_stream().map_err(|e| e.to_string())?;
            self.format = Format::from_nokhwa(&self.cam.camera_format());
        }
        let buffer = self.cam.frame().map_err(|e| e.to_string())?;
        let image = buffer
            .decode_image::<RgbAFormat>()
            .map_err(|e| e.to_string())?;
        let (w, h) = (image.width(), image.height());
        *out = image.into_raw();
        Ok((w, h))
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        if self.cam.is_stream_open() {
            let _ = self.cam.stop_stream();
        }
    }
}
