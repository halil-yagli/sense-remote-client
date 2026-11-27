// Sense Remote (S11 E1a): camera capture for the two-way video call on macOS (AVFoundation).
//
// AVFoundation side of `src/sense/video_call/cam_mac.rs`. One AVCaptureSession per open camera,
// frames as packed 32BGRA handed to Rust with their real row stride on a private serial queue.
// Rust crops, scales, paces and encodes; nothing here keeps or writes a frame.
//
// Errors (shared with cam_mac.rs): 1 no camera, 2 permission denied, 3 busy, 4 other,
// 5 Info.plist has no NSCameraUsageDescription (macOS would kill the process on access).
//
// Manual reference counting, like `src/platform/macos.mm` (built in the same `cc::Build`).

#if __has_feature(objc_arc)
#error "cam_mac.mm is written for manual reference counting"
#endif

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <stdint.h>

typedef void (*SenseCamMacDeviceCb)(void *ctx, const char *uid, const char *name, int32_t kind,
                                    int32_t max_h);
typedef void (*SenseCamMacFrameCb)(void *ctx, const uint8_t *bgra, int32_t w, int32_t h,
                                   int32_t stride);

enum {
  kSenseCamErrNone = 1,
  kSenseCamErrDenied = 2,
  kSenseCamErrBusy = 3,
  kSenseCamErrOpen = 4,
  kSenseCamErrPlist = 5,
};

static bool SenseCamHasUsageText(void) {
  return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSCameraUsageDescription"] != nil;
}

// -1 no usage text, 0 not determined, 1 restricted, 2 denied, 3 authorized.
extern "C" int32_t SenseCamMacAuth(void) {
  @autoreleasepool {
    if (!SenseCamHasUsageText()) return -1;
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
      case AVAuthorizationStatusNotDetermined: return 0;
      case AVAuthorizationStatusRestricted: return 1;
      case AVAuthorizationStatusDenied: return 2;
      case AVAuthorizationStatusAuthorized: return 3;
    }
    return 2;
  }
}

// Asks the person once (system dialog) and waits for the answer. Never call on the main thread.
extern "C" bool SenseCamMacRequestAccess(uint32_t timeout_ms) {
  if (!SenseCamHasUsageText()) return false;
  if ([NSThread isMainThread]) return false;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block BOOL granted = NO;
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL ok) {
                             granted = ok;
                             dispatch_semaphore_signal(done);
                           }];
  long timed_out = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC));
  // The block keeps its own reference to the semaphore.
  dispatch_release(done);
  // `granted` is read only after the handler signalled (the semaphore orders the two).
  return timed_out == 0 && granted;
}

// Device type names as strings: the macOS 14 constants are weak symbols on macOS 12.3/13 (the
// app's minimum) and `@available` needs compiler-rt in the Rust link, so neither is used.
static NSString *const kSenseCamTypeExternal = @"AVCaptureDeviceTypeExternal";            // 14.0+
static NSString *const kSenseCamTypeContinuity = @"AVCaptureDeviceTypeContinuityCamera";  // 14.0+
static NSString *const kSenseCamTypeExternalOld = @"AVCaptureDeviceTypeExternalUnknown";  // < 14

static bool SenseCamIsMacOS14(void) {
  NSOperatingSystemVersion v = {14, 0, 0};
  return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:v];
}

static NSArray *SenseCamDevices(void) {
  NSMutableArray *types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  if (SenseCamIsMacOS14()) {
    [types addObject:kSenseCamTypeExternal];
    [types addObject:kSenseCamTypeContinuity];
  } else {
    [types addObject:kSenseCamTypeExternalOld];
  }
  AVCaptureDeviceDiscoverySession *s =
      [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                             mediaType:AVMediaTypeVideo
                                                              position:AVCaptureDevicePositionUnspecified];
  return s.devices;
}

static int32_t SenseCamKind(AVCaptureDevice *d) {
  NSString *t = d.deviceType;
  if ([t isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) return 1;
  if ([t isEqualToString:kSenseCamTypeContinuity]) return 3;
  if ([t isEqualToString:kSenseCamTypeExternal] || [t isEqualToString:kSenseCamTypeExternalOld]) return 2;
  return 0;
}

static int32_t SenseCamMaxHeight(AVCaptureDevice *d) {
  int32_t best = 0;
  for (AVCaptureDeviceFormat *f in d.formats) {
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
    if (dim.height > best) best = dim.height;
  }
  return best;
}

// Device list; needs no camera permission.
extern "C" int32_t SenseCamMacList(SenseCamMacDeviceCb cb, void *ctx) {
  @autoreleasepool {
    int32_t n = 0;
    for (AVCaptureDevice *d in SenseCamDevices()) {
      const char *uid = d.uniqueID.UTF8String;
      const char *name = d.localizedName.UTF8String;
      if (!uid || !name) continue;
      cb(ctx, uid, name, SenseCamKind(d), SenseCamMaxHeight(d));
      n++;
    }
    return n;
  }
}

@interface SenseCamMacDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
 @public
  SenseCamMacFrameCb cb;
  void *ctx;
  std::atomic<bool> live;
}
@end

@implementation SenseCamMacDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (!live.load()) return;
  CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!img) return;
  if (CVPixelBufferGetPixelFormatType(img) != kCVPixelFormatType_32BGRA || CVPixelBufferIsPlanar(img))
    return;
  if (CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
  const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(img);
  if (base) {
    cb(ctx, base, (int32_t)CVPixelBufferGetWidth(img), (int32_t)CVPixelBufferGetHeight(img),
       (int32_t)CVPixelBufferGetBytesPerRow(img));
  }
  CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}
@end

struct SenseCamMacHandle {
  AVCaptureSession *session;
  AVCaptureVideoDataOutput *output;
  SenseCamMacDelegate *delegate;
  dispatch_queue_t queue;
};

static int32_t SenseCamErrorOf(NSError *e) {
  if (!e) return kSenseCamErrOpen;
  if ([e.domain isEqualToString:AVFoundationErrorDomain]) {
    switch (e.code) {
      case AVErrorApplicationIsNotAuthorizedToUseDevice: return kSenseCamErrDenied;
      case AVErrorDeviceInUseByAnotherApplication: return kSenseCamErrBusy;
      case AVErrorDeviceNotConnected: return kSenseCamErrNone;
      default: break;
    }
  }
  return kSenseCamErrOpen;
}

// Opens `uid` ("" = default camera) near want_w x want_h. Frames go to `cb(ctx, ...)` on a private
// queue until SenseCamMacStop returns. Returns NULL and sets *err on failure.
extern "C" void *SenseCamMacStart(const char *uid, int32_t want_w, int32_t want_h, int32_t fps,
                                  SenseCamMacFrameCb cb, void *ctx, int32_t *err) {
  (void)fps;  // Rust paces; the session runs at the camera's own rate.
  @autoreleasepool {
    *err = 0;
    if (!SenseCamHasUsageText()) {
      *err = kSenseCamErrPlist;
      return NULL;
    }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] !=
        AVAuthorizationStatusAuthorized) {
      *err = kSenseCamErrDenied;
      return NULL;
    }
    AVCaptureDevice *device = nil;
    if (uid && uid[0]) {
      device = [AVCaptureDevice deviceWithUniqueID:[NSString stringWithUTF8String:uid]];
    } else {
      device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    if (!device) {
      *err = kSenseCamErrNone;
      return NULL;
    }
    NSError *e = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&e];
    if (!input) {
      *err = SenseCamErrorOf(e);
      return NULL;
    }
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    if (![session canAddInput:input]) {
      [session commitConfiguration];
      [session release];
      *err = device.isInUseByAnotherApplication ? kSenseCamErrBusy : kSenseCamErrOpen;
      return NULL;
    }
    [session addInput:input];
    // 16:9 720p when the camera has it (scaled 2:1 to 640x360 without cropping), else VGA
    // (cropped to 16:9), else whatever the camera calls medium.
    NSString *preset = AVCaptureSessionPresetMedium;
    if (want_w <= 1280 && want_h <= 720 && [session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
      preset = AVCaptureSessionPreset1280x720;
    } else if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
      preset = AVCaptureSessionPreset640x480;
    }
    if ([session canSetSessionPreset:preset]) session.sessionPreset = preset;

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    output.alwaysDiscardsLateVideoFrames = YES;
    SenseCamMacDelegate *delegate = [[SenseCamMacDelegate alloc] init];
    delegate->cb = cb;
    delegate->ctx = ctx;
    delegate->live = true;
    dispatch_queue_t queue = dispatch_queue_create("com.sensedepartment.remote.camera", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:delegate queue:queue];
    if (![session canAddOutput:output]) {
      [session commitConfiguration];
      delegate->live = false;
      [output setSampleBufferDelegate:nil queue:NULL];
      [output release];
      [delegate release];
      dispatch_release(queue);
      [session release];
      *err = kSenseCamErrOpen;
      return NULL;
    }
    [session addOutput:output];
    [session commitConfiguration];
    [session startRunning];  // blocking; we are on the capture thread
    if (!session.isRunning) {
      delegate->live = false;
      [output setSampleBufferDelegate:nil queue:NULL];
      dispatch_sync(queue, ^{});
      [output release];
      [delegate release];
      dispatch_release(queue);
      [session release];
      *err = device.isInUseByAnotherApplication ? kSenseCamErrBusy : kSenseCamErrOpen;
      return NULL;
    }
    SenseCamMacHandle *h = new SenseCamMacHandle;
    h->session = session;
    h->output = output;
    h->delegate = delegate;
    h->queue = queue;
    return h;
  }
}

// Stops and frees. After this returns no frame callback runs any more (Rust frees ctx then).
extern "C" void SenseCamMacStop(void *handle) {
  if (!handle) return;
  SenseCamMacHandle *h = (SenseCamMacHandle *)handle;
  @autoreleasepool {
    h->delegate->live = false;
    [h->session stopRunning];
    [h->output setSampleBufferDelegate:nil queue:NULL];
    // Wait for a callback already running on the queue.
    dispatch_sync(h->queue, ^{});
    [h->session release];
    [h->output release];
    [h->delegate release];
    dispatch_release(h->queue);
  }
  delete h;
}
