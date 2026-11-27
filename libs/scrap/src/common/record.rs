use crate::CodecFormat;
use base::message_proto::{message, video_frame, EncodedVideoFrame, Message};
#[cfg(feature = "hwcodec")]
use hbb_common::anyhow::anyhow;
use hbb_common::{bail, chrono, log, ResultType};
#[cfg(feature = "hwcodec")]
use hwcodec::mux::{MuxContext, Muxer};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io,
    ops::{Deref, DerefMut},
    path::PathBuf,
    sync::{mpsc::Sender, Mutex},
    time::Instant,
};
use webm::mux::{self, Segment, Track, VideoTrack, Writer};

// Sense Remote (#136): one file per display across Host encoder restarts, real start/finish.
use crate::record_sense::{self, SenseRecordEvent};

const MIN_SECS: u64 = 1;

// Replace characters that are invalid in Windows filename components so recordings remain portable.
// Control characters are also replaced because they can make filenames invalid
// on Windows or invisible and difficult to handle on Linux and macOS.
fn sanitize_filename_component(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') {
                '_'
            } else {
                c
            }
        })
        .collect()
}

// Sense Remote (#114): one recording = one folder (`<computer name>_<date>_<time>`) holding the
// per-display files. The folder name is made once when recording starts and shared by every
// display's recorder of that session (key = `sense_record_key`: peer id + session, so two
// windows of the same peer — #97, one per display — never share or drop each other's folder;
// denetim K48), then dropped when recording stops.
static SENSE_SESSIONS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

const SENSE_NAME_MAX: usize = 48;

/// A computer name made safe for a file name: Turkish letters stay, characters Windows /
/// macOS refuse become `_`, trailing dots and spaces (Windows) go, length is capped.
pub fn sense_readable_component(value: &str) -> String {
    let cleaned: String = sanitize_filename_component(value.trim())
        .chars()
        .take(SENSE_NAME_MAX)
        .collect();
    let cleaned = cleaned.trim_matches(|c: char| c == '.' || c == ' ').to_string();
    let upper = cleaned.to_uppercase();
    let reserved = matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((upper.starts_with("COM") || upper.starts_with("LPT"))
            && upper.len() == 4
            && upper.ends_with(|c: char| c.is_ascii_digit()));
    if cleaned.is_empty() || reserved {
        "Bilgisayar".to_string()
    } else {
        cleaned
    }
}

/// `<computer>_<yyyy-mm-dd>_<hh-mm-ss>`.
pub fn sense_session_folder_name(peer_name: &str, stamp: &str) -> String {
    format!("{}_{}", sense_readable_component(peer_name), stamp)
}

/// `<folder>_Ekran1.mp4` (`Kamera1` for a camera); `n >= 2` adds `_2`, `_3`, ... for the rare
/// second file of the same display (the picture size or codec changed mid-recording).
pub fn sense_file_name(folder: &str, camera: bool, display_idx: usize, n: usize, ext: &str) -> String {
    let kind = if camera { "Kamera" } else { "Ekran" };
    let suffix = if n >= 2 { format!("_{n}") } else { String::new() };
    format!("{folder}_{kind}{}{suffix}.{ext}", display_idx + 1)
}

/// Key of one session's recording: the peer id plus the session instance (any number unique
/// among the open sessions of this process, e.g. the address of the session's shared state).
pub fn sense_record_key(peer_id: &str, instance: usize) -> String {
    format!("{peer_id}#{instance:x}")
}

/// The folder of the recording that is running for `key`; made on first ask.
pub fn sense_session_folder(key: &str, peer_name: &str) -> String {
    let mut g = SENSE_SESSIONS.lock().unwrap();
    g.get_or_insert_with(HashMap::new)
        .entry(key.to_owned())
        .or_insert_with(|| {
            let stamp = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
            sense_session_folder_name(peer_name, &stamp)
        })
        .clone()
}

/// A new recording starts: forget the old folder name so the next ask makes a fresh one.
pub fn sense_begin_session(key: &str, peer_name: &str) -> String {
    sense_end_session(key);
    sense_session_folder(key, peer_name)
}

/// Recording stopped: returns the folder name it used, if any.
pub fn sense_end_session(key: &str) -> Option<String> {
    SENSE_SESSIONS
        .lock()
        .unwrap()
        .as_mut()
        .and_then(|m| m.remove(key))
}

#[derive(Debug, Clone)]
pub struct RecorderContext {
    pub server: bool,
    pub id: String,
    pub dir: String,
    pub display_idx: usize,
    pub camera: bool,
    pub tx: Option<Sender<RecordState>>,
    /// Sense Remote (#114): sub folder of `dir` for this recording (Controller side); None keeps
    /// the stock flat naming (Host side).
    pub sense_folder: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RecorderContext2 {
    pub filename: String,
    pub width: usize,
    pub height: usize,
    pub format: CodecFormat,
}

impl RecorderContext2 {
    pub fn set_filename(&mut self, ctx: &RecorderContext) -> ResultType<()> {
        // Sense Remote (#114): readable names in one folder per recording.
        if let Some(folder) = &ctx.sense_folder {
            let dir = PathBuf::from(&ctx.dir).join(folder);
            std::fs::create_dir_all(&dir)?;
            let ext = if self.format == CodecFormat::VP9
                || self.format == CodecFormat::VP8
                || self.format == CodecFormat::AV1
            {
                "webm"
            } else {
                "mp4"
            };
            let mut n = 1;
            let path = loop {
                let p = dir.join(sense_file_name(folder, ctx.camera, ctx.display_idx, n, ext));
                if !p.exists() {
                    break p;
                }
                n += 1;
            };
            self.filename = path.to_string_lossy().to_string();
            return Ok(());
        }
        if !PathBuf::from(&ctx.dir).exists() {
            std::fs::create_dir_all(&ctx.dir)?;
        }
        let file = if ctx.server { "incoming" } else { "outgoing" }.to_string()
            + "_"
            + &sanitize_filename_component(&ctx.id)
            + &chrono::Local::now().format("_%Y%m%d%H%M%S%3f_").to_string()
            + &format!(
                "{}{}_",
                if ctx.camera { "camera" } else { "display" },
                ctx.display_idx
            )
            + &self.format.to_string().to_lowercase()
            + if self.format == CodecFormat::VP9
                || self.format == CodecFormat::VP8
                || self.format == CodecFormat::AV1
            {
                ".webm"
            } else {
                ".mp4"
            };
        self.filename = PathBuf::from(&ctx.dir)
            .join(file)
            .to_string_lossy()
            .to_string();
        Ok(())
    }
}

unsafe impl Send for Recorder {}
unsafe impl Sync for Recorder {}

pub trait RecorderApi {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self>
    where
        Self: Sized;
    // Sense Remote (#136): `pts` is the timestamp to write (the frame's own one, or continued
    // after a Host encoder restart, `Recorder::check_pts`).
    fn write_video(&mut self, frame: &EncodedVideoFrame, pts: i64) -> bool;
}

#[derive(Debug)]
pub enum RecordState {
    NewFile(String),
    NewFrame,
    WriteTail,
    RemoveFile,
}

pub struct Recorder {
    pub inner: Option<Box<dyn RecorderApi>>,
    ctx: RecorderContext,
    ctx2: Option<RecorderContext2>,
    pts: Option<i64>,
    check_failed: bool,
    // Sense Remote (#136): Controller-side recording (`ctx.sense_folder` set) only.
    sense_offset: i64,
    sense_last_out: Option<(i64, Instant)>,
    sense_need_key: bool,
    sense_part: usize,
    sense_fail_at: &'static str,
    sense_event: Option<SenseRecordEvent>,
}

impl Deref for Recorder {
    type Target = Option<Box<dyn RecorderApi>>;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl DerefMut for Recorder {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

impl Recorder {
    pub fn new(ctx: RecorderContext) -> ResultType<Self> {
        if let Some(folder) = &ctx.sense_folder {
            record_sense::opened(folder); // Sense Remote (#136): closed in Drop
        }
        Ok(Self {
            inner: None,
            ctx,
            ctx2: None,
            pts: None,
            check_failed: false,
            sense_offset: 0,
            sense_last_out: None,
            sense_need_key: false,
            sense_part: 0,
            sense_fail_at: "dosya",
            sense_event: None,
        })
    }

    /// Sense Remote (#136): what happened since the last ask: the recording's file opened
    /// (`Started`) or it cannot go on (`Failed`). Controller-side recording only.
    pub fn sense_take_event(&mut self) -> Option<SenseRecordEvent> {
        self.sense_event.take()
    }

    fn check(&mut self, w: usize, h: usize, format: CodecFormat) -> ResultType<()> {
        match self.ctx2 {
            Some(ref ctx2) => {
                if ctx2.width != w || ctx2.height != h || ctx2.format != format {
                    let mut ctx2 = RecorderContext2 {
                        width: w,
                        height: h,
                        format,
                        filename: Default::default(),
                    };
                    self.sense_fail_at = "klasor"; // Sense Remote (#136)
                    ctx2.set_filename(&self.ctx)?;
                    self.ctx2 = Some(ctx2);
                    self.inner = None;
                }
            }
            None => {
                let mut ctx2 = RecorderContext2 {
                    width: w,
                    height: h,
                    format,
                    filename: Default::default(),
                };
                self.sense_fail_at = "klasor"; // Sense Remote (#136)
                ctx2.set_filename(&self.ctx)?;
                self.ctx2 = Some(ctx2);
                self.inner = None;
            }
        }
        let Some(ctx2) = &self.ctx2 else {
            bail!("ctx2 is None");
        };
        if self.inner.is_none() {
            // Sense Remote (#136): a codec this build cannot put in a file vs. a file that
            // would not open.
            self.sense_fail_at = if cfg!(feature = "hwcodec")
                || matches!(format, CodecFormat::VP8 | CodecFormat::VP9 | CodecFormat::AV1)
            {
                "dosya"
            } else {
                "kodek"
            };
            self.inner = match format {
                CodecFormat::VP8 | CodecFormat::VP9 | CodecFormat::AV1 => Some(Box::new(
                    WebmRecorder::new(self.ctx.clone(), (*ctx2).clone())?,
                )),
                #[cfg(feature = "hwcodec")]
                _ => Some(Box::new(HwRecorder::new(
                    self.ctx.clone(),
                    (*ctx2).clone(),
                )?)),
                #[cfg(not(feature = "hwcodec"))]
                _ => bail!("unsupported codec type"),
            };
            // pts is None when new inner is created
            self.pts = None;
            self.send_state(RecordState::NewFile(ctx2.filename.clone()));
            if self.ctx.sense_folder.is_some() {
                // Sense Remote (#136): the new file starts its own clock; the UI hears that the
                // recording really started (or that a new part began).
                self.sense_offset = 0;
                self.sense_last_out = None;
                self.sense_need_key = false;
                self.sense_part += 1;
                self.sense_event = Some(SenseRecordEvent::Started {
                    file: ctx2.filename.clone(),
                    part: self.sense_part,
                    codec: format.to_string(),
                    width: w,
                    height: h,
                });
            }
        }
        Ok(())
    }

    pub fn write_message(&mut self, msg: &Message, w: usize, h: usize) {
        if let Some(message::Union::VideoFrame(vf)) = &msg.union {
            if let Some(frame) = &vf.union {
                self.write_frame(frame, w, h).ok();
            }
        }
    }

    pub fn write_frame(
        &mut self,
        frame: &video_frame::Union,
        w: usize,
        h: usize,
    ) -> ResultType<()> {
        if self.check_failed {
            bail!("check failed");
        }
        let format = CodecFormat::from(frame);
        if format == CodecFormat::Unknown {
            bail!("unsupported frame type");
        }
        let res = self.check(w, h, format);
        if res.is_err() {
            self.check_failed = true;
            log::error!("check failed: {:?}", res);
            if self.ctx.sense_folder.is_some() {
                // Sense Remote (#136): the UI stops the recording and says it could not record.
                self.sense_event = Some(SenseRecordEvent::Failed {
                    reason: self.sense_fail_at,
                });
            }
            res?;
        }
        match frame {
            video_frame::Union::Vp8s(vp8s) => {
                for f in vp8s.frames.iter() {
                    if let Some(pts) = self.check_pts(f.pts, f.key, w, h, format)? {
                        self.as_mut().map(|x| x.write_video(f, pts));
                    }
                }
            }
            video_frame::Union::Vp9s(vp9s) => {
                for f in vp9s.frames.iter() {
                    if let Some(pts) = self.check_pts(f.pts, f.key, w, h, format)? {
                        self.as_mut().map(|x| x.write_video(f, pts));
                    }
                }
            }
            video_frame::Union::Av1s(av1s) => {
                for f in av1s.frames.iter() {
                    if let Some(pts) = self.check_pts(f.pts, f.key, w, h, format)? {
                        self.as_mut().map(|x| x.write_video(f, pts));
                    }
                }
            }
            #[cfg(feature = "hwcodec")]
            video_frame::Union::H264s(h264s) => {
                for f in h264s.frames.iter() {
                    if let Some(pts) = self.check_pts(f.pts, f.key, w, h, format)? {
                        self.as_mut().map(|x| x.write_video(f, pts));
                    }
                }
            }
            #[cfg(feature = "hwcodec")]
            video_frame::Union::H265s(h265s) => {
                for f in h265s.frames.iter() {
                    if let Some(pts) = self.check_pts(f.pts, f.key, w, h, format)? {
                        self.as_mut().map(|x| x.write_video(f, pts));
                    }
                }
            }
            _ => bail!("unsupported frame type"),
        }
        self.send_state(RecordState::NewFrame);
        Ok(())
    }

    /// The timestamp to write the frame with, or None to leave the frame out.
    fn check_pts(
        &mut self,
        pts: i64,
        key: bool,
        w: usize,
        h: usize,
        format: CodecFormat,
    ) -> ResultType<Option<i64>> {
        // https://stackoverflow.com/questions/76379101/how-to-create-one-playable-webm-file-from-two-different-video-tracks-with-same-c
        if self.pts.is_none() && !key {
            bail!("first frame is not key frame");
        }
        if self.ctx.sense_folder.is_some() {
            return Ok(self.sense_check_pts(pts, key));
        }
        let old_pts = self.pts;
        self.pts = Some(pts);
        if old_pts.clone().unwrap_or_default() > pts {
            log::info!("pts {:?} -> {}, change record filename", old_pts, pts);
            self.inner = None;
            self.ctx2 = None;
            let res = self.check(w, h, format);
            if res.is_err() {
                self.check_failed = true;
                log::error!("check failed: {:?}", res);
                res?;
            }
            self.pts = Some(pts);
        }
        Ok(Some(pts))
    }

    /// Sense Remote (#136): a backwards timestamp means the Host rebuilt its encoder (ghost
    /// mode, display switch, quality). The same file goes on: same size and codec (a change of
    /// those is a new part, `check`), timestamps continued by the real time that passed, and
    /// nothing written until the new encoder's key frame.
    fn sense_check_pts(&mut self, pts: i64, key: bool) -> Option<i64> {
        let now = Instant::now();
        if let Some(old) = self.pts {
            if pts < old {
                let (last_out, at) = self.sense_last_out.unwrap_or((old + self.sense_offset, now));
                let gap = now.saturating_duration_since(at).as_millis() as i64;
                self.sense_offset = record_sense::continue_offset(last_out, pts, gap);
                self.sense_need_key = true;
                log::info!(
                    "record display #{}: encoder restarted (pts {old} -> {pts}), same file goes on",
                    self.ctx.display_idx
                );
            }
        }
        self.pts = Some(pts);
        if self.sense_need_key {
            if !key {
                return None;
            }
            self.sense_need_key = false;
        }
        let out = pts + self.sense_offset;
        self.sense_last_out = Some((out, now));
        Some(out)
    }

    fn send_state(&self, state: RecordState) {
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

// Sense Remote (#136): the file's tail is written first (the inner recorder's Drop), then the
// recording's open count goes down, so "Kaydedildi" never comes before a file is complete.
impl Drop for Recorder {
    fn drop(&mut self) {
        self.inner = None;
        if let Some(folder) = &self.ctx.sense_folder {
            record_sense::closed(folder);
        }
    }
}

struct WebmRecorder {
    vt: VideoTrack,
    webm: Option<Segment<Writer<File>>>,
    ctx: RecorderContext,
    ctx2: RecorderContext2,
    key: bool,
    written: bool,
    start: Instant,
}

impl RecorderApi for WebmRecorder {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self> {
        let out = match {
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&ctx2.filename)
        } {
            Ok(file) => file,
            Err(ref e) if e.kind() == io::ErrorKind::AlreadyExists => File::create(&ctx2.filename)?,
            Err(e) => return Err(e.into()),
        };
        let mut webm = match mux::Segment::new(mux::Writer::new(out)) {
            Some(v) => v,
            None => bail!("Failed to create webm mux"),
        };
        let vt = webm.add_video_track(
            ctx2.width as _,
            ctx2.height as _,
            None,
            if ctx2.format == CodecFormat::VP9 {
                mux::VideoCodecId::VP9
            } else if ctx2.format == CodecFormat::VP8 {
                mux::VideoCodecId::VP8
            } else {
                mux::VideoCodecId::AV1
            },
        );
        if ctx2.format == CodecFormat::AV1 {
            // [129, 8, 12, 0] in 3.6.0, but zero works
            let codec_private = vec![0, 0, 0, 0];
            if !webm.set_codec_private(vt.track_number(), &codec_private) {
                bail!("Failed to set codec private");
            }
        }
        Ok(WebmRecorder {
            vt,
            webm: Some(webm),
            ctx,
            ctx2,
            key: false,
            written: false,
            start: Instant::now(),
        })
    }

    fn write_video(&mut self, frame: &EncodedVideoFrame, pts: i64) -> bool {
        if frame.key {
            self.key = true;
        }
        if self.key {
            let ok = self
                .vt
                .add_frame(&frame.data, pts.max(0) as u64 * 1_000_000, frame.key);
            if ok {
                self.written = true;
            }
            ok
        } else {
            false
        }
    }
}

impl Drop for WebmRecorder {
    fn drop(&mut self) {
        let _ = std::mem::replace(&mut self.webm, None).map_or(false, |webm| webm.finalize(None));
        let mut state = RecordState::WriteTail;
        if !self.written || self.start.elapsed().as_secs() < MIN_SECS {
            std::fs::remove_file(&self.ctx2.filename).ok();
            state = RecordState::RemoveFile;
        }
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

#[cfg(feature = "hwcodec")]
struct HwRecorder {
    muxer: Option<Muxer>,
    ctx: RecorderContext,
    ctx2: RecorderContext2,
    written: bool,
    key: bool,
    start: Instant,
}

#[cfg(feature = "hwcodec")]
impl RecorderApi for HwRecorder {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self> {
        let muxer = Muxer::new(MuxContext {
            filename: ctx2.filename.clone(),
            width: ctx2.width,
            height: ctx2.height,
            is265: ctx2.format == CodecFormat::H265,
            framerate: crate::hwcodec::DEFAULT_FPS as _,
        })
        .map_err(|_| anyhow!("Failed to create hardware muxer"))?;
        Ok(HwRecorder {
            muxer: Some(muxer),
            ctx,
            ctx2,
            written: false,
            key: false,
            start: Instant::now(),
        })
    }

    // The muxer times frames itself (fixed frame rate); `pts` is not needed.
    fn write_video(&mut self, frame: &EncodedVideoFrame, _pts: i64) -> bool {
        if frame.key {
            self.key = true;
        }
        if self.key {
            let ok = self
                .muxer
                .as_mut()
                .map(|m| m.write_video(&frame.data, frame.key).is_ok())
                .unwrap_or_default();
            if ok {
                self.written = true;
            }
            ok
        } else {
            false
        }
    }
}

#[cfg(feature = "hwcodec")]
impl Drop for HwRecorder {
    fn drop(&mut self) {
        self.muxer.as_mut().map(|m| m.write_tail().ok());
        let mut state = RecordState::WriteTail;
        if !self.written || self.start.elapsed().as_secs() < MIN_SECS {
            // The process cannot access the file because it is being used by another process
            self.muxer = None;
            std::fs::remove_file(&self.ctx2.filename).ok();
            state = RecordState::RemoveFile;
        }
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

#[cfg(test)]
mod tests {
    use super::{
        sanitize_filename_component, sense_file_name, sense_readable_component,
        sense_session_folder_name,
    };

    #[test]
    fn sense_names_are_readable_and_safe() {
        assert_eq!(sense_readable_component("Müze-Şef PC"), "Müze-Şef PC");
        assert_eq!(sense_readable_component("a/b:c*"), "a_b_c_");
        assert_eq!(sense_readable_component("  PC. "), "PC");
        assert_eq!(sense_readable_component("con"), "Bilgisayar");
        assert_eq!(sense_readable_component(""), "Bilgisayar");
        assert_eq!(sense_readable_component(&"x".repeat(200)).chars().count(), 48);
        let f = sense_session_folder_name("Slayer", "2026-11-27_03-52-04");
        assert_eq!(f, "Slayer_2026-11-27_03-52-04");
        assert_eq!(sense_file_name(&f, false, 0, 1, "mp4"), "Slayer_2026-11-27_03-52-04_Ekran1.mp4");
        assert_eq!(sense_file_name(&f, false, 1, 2, "webm"), "Slayer_2026-11-27_03-52-04_Ekran2_2.webm");
        assert_eq!(sense_file_name(&f, true, 0, 1, "mp4"), "Slayer_2026-11-27_03-52-04_Kamera1.mp4");
    }

    #[test]
    fn sense_session_folder_is_shared_until_ended() {
        use super::{sense_begin_session, sense_end_session, sense_session_folder};
        let a = sense_begin_session("test-key-114", "PC");
        assert_eq!(sense_session_folder("test-key-114", "PC"), a);
        assert_eq!(sense_end_session("test-key-114"), Some(a));
        assert_eq!(sense_end_session("test-key-114"), None);
    }

    // K48: two windows of the same peer (#97) record into their own folders; one stopping does
    // not take the other's folder away.
    #[test]
    fn sense_two_sessions_of_one_peer_keep_their_folders() {
        use super::{sense_begin_session, sense_end_session, sense_record_key, sense_session_folder};
        let a = sense_record_key("test-peer-k48", 0x10);
        let b = sense_record_key("test-peer-k48", 0x20);
        assert_ne!(a, b);
        let fa = sense_begin_session(&a, "PC");
        let fb = sense_begin_session(&b, "PC");
        // The second start does not reset the first one's folder.
        assert_eq!(sense_session_folder(&a, "PC"), fa);
        assert_eq!(sense_end_session(&b), Some(fb));
        // The first recording keeps its folder after the second one stopped.
        assert_eq!(sense_session_folder(&a, "PC"), fa);
        assert_eq!(sense_end_session(&a), Some(fa));
    }

    #[test]
    fn sanitize_recording_filename_component() {
        assert_eq!(
            sanitize_filename_component("192.168.1.2:21118"),
            "192.168.1.2_21118"
        );
        assert_eq!(
            sanitize_filename_component("[2001:db8::1]:21118"),
            "[2001_db8__1]_21118"
        );
        assert_eq!(
            sanitize_filename_component("peer/name\\with?bad\nchars"),
            "peer_name_with_bad_chars"
        );
    }
}
