use std::{ops, ptr, slice};

use super::ffi::*;

pub struct Frame {
    surface: IOSurfaceRef,
    inner: &'static [u8],
    bgra: Vec<u8>,
    bgra_stride: usize,
}

impl Frame {
    pub unsafe fn new(surface: IOSurfaceRef) -> Frame {
        CFRetain(surface);
        IOSurfaceIncrementUseCount(surface);

        IOSurfaceLock(surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());

        let inner = slice::from_raw_parts(
            IOSurfaceGetBaseAddress(surface) as *const u8,
            IOSurfaceGetAllocSize(surface),
        );

        Frame {
            surface,
            inner,
            bgra: Vec::new(),
            bgra_stride: 0,
        }
    }

    #[inline]
    pub fn inner(&self) -> &[u8] {
        self.inner
    }

    pub fn stride(&self) -> usize {
        self.bgra_stride
    }

    pub fn surface_to_bgra<'a>(&'a mut self, h: usize) {
        unsafe {
            let mut plane0 = IOSurfaceGetBaseAddressOfPlane(self.surface, 0);
            self.bgra_stride = IOSurfaceGetBytesPerRowOfPlane(self.surface, 0);
            // Sense Remote (S11, M5): a non-planar surface (ScreenCaptureKit's pixel buffers)
            // may report no plane 0; read the whole surface then. CGDisplayStream frames keep
            // the plane values as before.
            if plane0.is_null() || self.bgra_stride == 0 {
                plane0 = IOSurfaceGetBaseAddress(self.surface);
                self.bgra_stride = IOSurfaceGetBytesPerRow(self.surface);
            }
            // Never read past the surface.
            let len = (self.bgra_stride * h).min(IOSurfaceGetAllocSize(self.surface));
            self.bgra.resize(self.bgra_stride * h, 0);
            if !plane0.is_null() {
                std::ptr::copy_nonoverlapping(plane0 as *const u8, self.bgra.as_mut_ptr(), len);
            }
        }
    }
}

impl ops::Deref for Frame {
    type Target = [u8];
    fn deref<'a>(&'a self) -> &'a [u8] {
        &self.bgra
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        unsafe {
            IOSurfaceUnlock(self.surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());

            IOSurfaceDecrementUseCount(self.surface);
            CFRelease(self.surface);
        }
    }
}
