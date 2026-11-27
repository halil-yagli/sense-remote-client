use crate::{quartz, Frame, Pixfmt};
use hbb_common::log;
use quartz::select::{self, Backend};
use std::marker::PhantomData;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::{io, mem};

// Sense Remote (S11, M5): the capture backend, CGDisplayStream (RustDesk's) or ScreenCaptureKit.
enum Inner {
    DisplayStream(quartz::Capturer),
    Sck(quartz::sck::Capturer),
}

/// Failed ScreenCaptureKit streams in this process (`select::MAX_SCK_FAILURES`).
static SCK_FAILURES: AtomicU32 = AtomicU32::new(0);

pub struct Capturer {
    inner: Inner,
    frame: Arc<Mutex<Option<quartz::Frame>>>,
    saved_raw_data: Vec<u8>, // for faster compare and copy
    sck_failure_counted: bool,
}

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        let frame = Arc::new(Mutex::new(None));

        // Sense Remote (S11, M5): ScreenCaptureKit when chosen (`select.rs`); any failure to
        // start falls back to CGDisplayStream below.
        let backend = select::choose(
            quartz::sck::os_version(),
            quartz::sck::supported(),
            &hbb_common::config::Config::get_option(select::OPTION),
            SCK_FAILURES.load(Ordering::Relaxed),
        );
        if backend == Backend::ScreenCaptureKit {
            let f = frame.clone();
            match quartz::sck::Capturer::new(
                display.0,
                display.width(),
                display.height(),
                &Default::default(),
                move |inner| {
                    if let Ok(mut f) = f.lock() {
                        *f = Some(inner);
                    }
                },
            ) {
                Ok(inner) => {
                    log::info!(
                        "screen capture: ScreenCaptureKit, display {} {}x{}",
                        display.0.id(),
                        inner.width(),
                        inner.height()
                    );
                    return Ok(Capturer {
                        inner: Inner::Sck(inner),
                        frame,
                        saved_raw_data: Vec::new(),
                        sck_failure_counted: false,
                    });
                }
                Err(code) => {
                    SCK_FAILURES.fetch_add(1, Ordering::Relaxed);
                    log::warn!(
                        "ScreenCaptureKit did not start (code {}), using CGDisplayStream",
                        code
                    );
                }
            }
        }

        let f = frame.clone();
        let inner = quartz::Capturer::new(
            display.0,
            display.width(),
            display.height(),
            quartz::PixelFormat::Argb8888,
            Default::default(),
            move |inner| {
                if let Ok(mut f) = f.lock() {
                    *f = Some(inner);
                }
            },
        )
        .map_err(|_| io::Error::from(io::ErrorKind::Other))?;

        Ok(Capturer {
            inner: Inner::DisplayStream(inner),
            frame,
            saved_raw_data: Vec::new(),
            sck_failure_counted: false,
        })
    }

    pub fn width(&self) -> usize {
        match &self.inner {
            Inner::DisplayStream(c) => c.width(),
            Inner::Sck(c) => c.width(),
        }
    }

    pub fn height(&self) -> usize {
        match &self.inner {
            Inner::DisplayStream(c) => c.height(),
            Inner::Sck(c) => c.height(),
        }
    }
}

impl crate::TraitCapturer for Capturer {
    fn frame<'a>(&'a mut self, _timeout_ms: std::time::Duration) -> io::Result<Frame<'a>> {
        // Sense Remote (S11, M5): a failed ScreenCaptureKit stream ends this capturer; the video
        // service starts a new one (CGDisplayStream after `select::MAX_SCK_FAILURES`).
        if let Inner::Sck(c) = &self.inner {
            if c.failed() {
                if !self.sck_failure_counted {
                    self.sck_failure_counted = true;
                    SCK_FAILURES.fetch_add(1, Ordering::Relaxed);
                    log::warn!("ScreenCaptureKit stream failed, restarting capture");
                }
                return Err(io::ErrorKind::Other.into());
            }
        }
        match self.frame.try_lock() {
            Ok(mut handle) => {
                let mut frame = None;
                mem::swap(&mut frame, &mut handle);

                match frame {
                    Some(mut frame) => {
                        crate::would_block_if_equal(&mut self.saved_raw_data, frame.inner())?;
                        frame.surface_to_bgra(self.height());
                        Ok(Frame::PixelBuffer(PixelBuffer {
                            frame,
                            data: PhantomData,
                            width: self.width(),
                            height: self.height(),
                        }))
                    }

                    None => Err(io::ErrorKind::WouldBlock.into()),
                }
            }

            Err(TryLockError::WouldBlock) => Err(io::ErrorKind::WouldBlock.into()),

            Err(TryLockError::Poisoned(..)) => Err(io::ErrorKind::Other.into()),
        }
    }
}

pub struct PixelBuffer<'a> {
    frame: quartz::Frame,
    data: PhantomData<&'a [u8]>,
    width: usize,
    height: usize,
}

impl<'a> crate::TraitPixelBuffer for PixelBuffer<'a> {
    fn data(&self) -> &[u8] {
        &*self.frame
    }

    fn width(&self) -> usize {
        self.width
    }

    fn height(&self) -> usize {
        self.height
    }

    fn stride(&self) -> Vec<usize> {
        let mut v = Vec::new();
        v.push(self.frame.stride());
        v
    }

    fn pixfmt(&self) -> Pixfmt {
        Pixfmt::BGRA
    }
}

pub struct Display(quartz::Display);

impl Display {
    pub fn primary() -> io::Result<Display> {
        Ok(Display(quartz::Display::primary()))
    }

    pub fn all() -> io::Result<Vec<Display>> {
        Ok(quartz::Display::online()
            .map_err(|_| io::Error::from(io::ErrorKind::Other))?
            .into_iter()
            .map(Display)
            .collect())
    }

    pub fn width(&self) -> usize {
        self.0.width()
    }

    pub fn height(&self) -> usize {
        self.0.height()
    }

    pub fn scale(&self) -> f64 {
        self.0.scale()
    }

    pub fn name(&self) -> String {
        self.0.id().to_string()
    }

    pub fn is_online(&self) -> bool {
        self.0.is_online()
    }

    pub fn origin(&self) -> (i32, i32) {
        let o = self.0.bounds().origin;
        (o.x as _, o.y as _)
    }

    pub fn is_primary(&self) -> bool {
        self.0.is_primary()
    }
}
