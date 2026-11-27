// Sense Remote (S11, M5): ScreenCaptureKit display capture, the successor of CGDisplayStream.
//
// Rust side: `sck.rs`; which backend runs: `select.rs` and `common/quartz.rs`.
//
// - ScreenCaptureKit is loaded at run time (dlopen + NSClassFromString), never linked, so the
//   binary still starts where the framework is missing and nothing changes for CGDisplayStream.
// - One SCStream per display: full-resolution BGRA (the caller passes Retina pixel sizes), the
//   cursor as asked (RustDesk draws its own), the same IOSurface frames CGDisplayStream gives
//   (`quartz::Frame`), only complete frames.
// - Windows marked NSWindowSharingNone stay out of the picture, like with CGDisplayStream: the
//   ghost-mode curtain (`src/sense/curtain_mac.mm`) and the Sense connection icon
//   (`MainFlutterWindow.swift`, #109). Apple does not promise that ScreenCaptureKit honours
//   sharingType, so the stream's filter excludes those windows itself; the list is checked every
//   second (the curtain and the icon come and go during a session) and the filter updated when it
//   changes. This only removes windows from what the Controller sees; nothing is hidden from the
//   person at the Host.
// - After `sense_sck_stop` returns, no callback reaches Rust any more.

#if !__has_feature(objc_arc)
#error "sck.m is built with -fobjc-arc (libs/scrap/build.rs)"
#endif

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <dlfcn.h>

// Every ScreenCaptureKit call below runs only after SenseSckLoad() checked macOS 12.3 and the
// classes; the framework is never linked (classes come from NSClassFromString).
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

typedef void (*SenseSckFrameFn)(void *ctx, IOSurfaceRef surface);
typedef void (*SenseSckStopFn)(void *ctx, long code);

// Error codes of sense_sck_start (logged by Rust).
enum {
    SENSE_SCK_UNAVAILABLE = 1,
    SENSE_SCK_NO_CONTENT = 2, // no answer or an error: usually the screen recording permission
    SENSE_SCK_NO_DISPLAY = 3,
    SENSE_SCK_NO_OUTPUT = 4,
    SENSE_SCK_NOT_STARTED = 5,
};

static NSString *gSenseSckStatusKey = nil; // SCStreamFrameInfoStatus

static BOOL SenseSckLoad(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        NSOperatingSystemVersion min = {12, 3, 0};
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:min]) return;
        void *lib = dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit",
                           RTLD_LAZY | RTLD_LOCAL);
        if (!lib) return;
        __unsafe_unretained NSString *const *key =
            (__unsafe_unretained NSString *const *)dlsym(lib, "SCStreamFrameInfoStatus");
        if (!key || !*key) return;
        gSenseSckStatusKey = *key;
        ok = NSClassFromString(@"SCStream") && NSClassFromString(@"SCShareableContent") &&
             NSClassFromString(@"SCContentFilter") && NSClassFromString(@"SCStreamConfiguration");
    });
    return ok;
}

int sense_sck_supported(void) { return SenseSckLoad() ? 1 : 0; }

void sense_sck_os_version(int *major, int *minor) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (major) *major = (int)v.majorVersion;
    if (minor) *minor = (int)v.minorVersion;
}

// Window numbers of the on-screen windows that ask to stay out of capture.
static NSSet<NSNumber *> *SenseSckHiddenWindowIds(void) {
    NSMutableSet<NSNumber *> *ids = [NSMutableSet set];
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return ids;
    for (NSDictionary *w in (__bridge NSArray *)list) {
        NSNumber *sharing = w[(__bridge NSString *)kCGWindowSharingState];
        NSNumber *number = w[(__bridge NSString *)kCGWindowNumber];
        if (sharing && number && sharing.intValue == kCGWindowSharingNone) [ids addObject:number];
    }
    CFRelease(list);
    return ids;
}

static void SenseSckFetchContent(void (^done)(SCShareableContent *content)) {
    [NSClassFromString(@"SCShareableContent")
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent *content, NSError *error) {
                                   done(error ? nil : content);
                                 }];
}

static SCShareableContent *SenseSckContentSync(double timeoutSecs) {
    __block SCShareableContent *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    SenseSckFetchContent(^(SCShareableContent *content) {
      result = content;
      dispatch_semaphore_signal(sem);
    });
    long timedOut = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSecs * NSEC_PER_SEC)));
    return timedOut ? nil : result;
}

static SCContentFilter *SenseSckFilter(SCShareableContent *content, uint32_t displayId,
                                       NSSet<NSNumber *> *hiddenIds) {
    SCDisplay *display = nil;
    for (SCDisplay *d in content.displays) {
        if (d.displayID == displayId) {
            display = d;
            break;
        }
    }
    if (!display) return nil;
    NSMutableArray<SCWindow *> *excluded = [NSMutableArray array];
    for (SCWindow *w in content.windows) {
        if ([hiddenIds containsObject:@(w.windowID)]) [excluded addObject:w];
    }
    return [[NSClassFromString(@"SCContentFilter") alloc] initWithDisplay:display
                                                         excludingWindows:excluded];
}

@interface SenseSckOutput : NSObject <SCStreamOutput, SCStreamDelegate> {
  @public
    void *ctx;
    SenseSckFrameFn onFrame;
    SenseSckStopFn onStop;
    BOOL detached;
}
- (void)detach;
@end

@implementation SenseSckOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) < 1) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = info[gSenseSckStatusKey];
    // Idle, blank, suspended frames carry no new picture.
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!image) return;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(image);
    if (!surface) return;
    @synchronized(self) {
        // `quartz::Frame::new` retains the surface; it outlives the sample buffer.
        if (!detached && onFrame) onFrame(ctx, surface);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    @synchronized(self) {
        if (!detached && onStop) onStop(ctx, error ? (long)error.code : -1);
    }
}

- (void)detach {
    @synchronized(self) {
        detached = YES;
    }
}

@end

@interface SenseSckCapture : NSObject {
  @public
    SCStream *stream;
    SenseSckOutput *output;
    dispatch_queue_t sampleQueue;
    dispatch_queue_t controlQueue;
    dispatch_source_t timer;
    uint32_t displayId;
    NSSet<NSNumber *> *hiddenIds; // controlQueue only
    BOOL updating;                // controlQueue only
    int stopping; // __atomic builtins
}
@end

@implementation SenseSckCapture

// controlQueue: keep NSWindowSharingNone windows out of the stream's filter.
- (void)refreshFilter {
    if (updating || __atomic_load_n(&stopping, __ATOMIC_ACQUIRE)) return;
    NSSet<NSNumber *> *ids = SenseSckHiddenWindowIds();
    if ([ids isEqualToSet:hiddenIds]) return;
    updating = YES;
    SenseSckFetchContent(^(SCShareableContent *content) {
      SCContentFilter *filter =
          content ? SenseSckFilter(content, self->displayId, ids) : nil;
      if (!filter || __atomic_load_n(&self->stopping, __ATOMIC_ACQUIRE)) {
          dispatch_async(self->controlQueue, ^{
            self->updating = NO;
          });
          return;
      }
      [self->stream updateContentFilter:filter
                      completionHandler:^(NSError *error) {
                        dispatch_async(self->controlQueue, ^{
                          if (!error) self->hiddenIds = ids;
                          self->updating = NO;
                        });
                      }];
    });
}

- (void)shutdown {
    __atomic_store_n(&stopping, 1, __ATOMIC_RELEASE);
    if (timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
    [output detach];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    // Drain: no frame callback or filter check is running after this.
    dispatch_sync(sampleQueue, ^{
                  });
    dispatch_sync(controlQueue, ^{
                  });
}

@end

void *sense_sck_start(uint32_t displayId, size_t width, size_t height, int cursor,
                      double minFrameInterval, int queueDepth, void *ctx, SenseSckFrameFn onFrame,
                      SenseSckStopFn onStop, long *err) {
    long dummy = 0;
    if (!err) err = &dummy;
    *err = 0;
    if (!SenseSckLoad()) {
        *err = SENSE_SCK_UNAVAILABLE;
        return NULL;
    }
    @autoreleasepool {
        SCShareableContent *content = SenseSckContentSync(3.0);
        if (!content) {
            *err = SENSE_SCK_NO_CONTENT;
            return NULL;
        }
        NSSet<NSNumber *> *ids = SenseSckHiddenWindowIds();
        SCContentFilter *filter = SenseSckFilter(content, displayId, ids);
        if (!filter) {
            *err = SENSE_SCK_NO_DISPLAY;
            return NULL;
        }

        SCStreamConfiguration *config = [[NSClassFromString(@"SCStreamConfiguration") alloc] init];
        config.width = width;
        config.height = height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.showsCursor = cursor ? YES : NO;
        config.queueDepth = queueDepth;
        // CGDisplayStream's "no throttle" (0) becomes at most 120 pictures a second.
        config.minimumFrameInterval =
            minFrameInterval > 0 ? CMTimeMakeWithSeconds(minFrameInterval, 600) : CMTimeMake(1, 120);

        SenseSckCapture *cap = [[SenseSckCapture alloc] init];
        cap->displayId = displayId;
        cap->hiddenIds = ids;
        cap->sampleQueue = dispatch_queue_create("sense.sck.frames", DISPATCH_QUEUE_SERIAL);
        cap->controlQueue = dispatch_queue_create("sense.sck.filter", DISPATCH_QUEUE_SERIAL);
        cap->output = [[SenseSckOutput alloc] init];
        cap->output->ctx = ctx;
        cap->output->onFrame = onFrame;
        cap->output->onStop = onStop;
        cap->stream = [[NSClassFromString(@"SCStream") alloc] initWithFilter:filter
                                                               configuration:config
                                                                    delegate:cap->output];
        NSError *addError = nil;
        if (!cap->stream || ![cap->stream addStreamOutput:cap->output
                                                     type:SCStreamOutputTypeScreen
                                       sampleHandlerQueue:cap->sampleQueue
                                                    error:&addError]) {
            [cap->output detach];
            *err = SENSE_SCK_NO_OUTPUT;
            return NULL;
        }

        __block NSError *startError = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cap->stream startCaptureWithCompletionHandler:^(NSError *error) {
          startError = error;
          dispatch_semaphore_signal(sem);
        }];
        long timedOut =
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        if (timedOut || startError) {
            [cap shutdown];
            *err = SENSE_SCK_NOT_STARTED;
            return NULL;
        }

        cap->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cap->controlQueue);
        __weak SenseSckCapture *weakCap = cap;
        dispatch_source_set_event_handler(cap->timer, ^{
          [weakCap refreshFilter];
        });
        dispatch_source_set_timer(cap->timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_resume(cap->timer);
        return (__bridge_retained void *)cap;
    }
}

void sense_sck_stop(void *handle) {
    if (!handle) return;
    @autoreleasepool {
        SenseSckCapture *cap = (__bridge_transfer SenseSckCapture *)handle;
        [cap shutdown];
    }
}
