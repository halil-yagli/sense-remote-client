// Sense Remote (H5, MAC-SONRA-15): maintenance curtain of ghost mode (hayalet mod) on macOS.
//
// AppKit side of `src/sense/curtain_mac.rs`. One borderless window per screen, above full-screen
// apps, Dock and menu bar, on every Space, kept out of capture (NSWindowSharingNone), letting
// input through and never taking focus. Layout, glow, texts and colours come from Rust (the
// numbers of the Windows curtain, `curtain.rs`). Everything AppKit runs on the main thread of
// the `--server` process (its main thread runs the tray's event loop); callers on other threads
// wait with a timeout and cancel what they asked for when the main thread does not answer.
//
// The connection stays visible (workshop CLAUDE.md, Security): while the curtain is up, it asks
// the Sense icon (connection manager, `--cm`) to stay above it with a distributed notification
// (`SenseRemoteCurtain`, "on" every second, "off" at the end; `AppDelegate.swift`).
//
// Local input: the same event tap rule as RustDesk's macOS privacy mode (`macos.mm`): physical
// keyboard and mouse events are dropped, remote input (enigo, user data 100) passes.
//
// Manual reference counting, like `src/platform/macos.mm` (built in the same `cc::Build`).

#if __has_feature(objc_arc)
#error "curtain_mac.mm is written for manual reference counting"
#endif

#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>

extern "C" {
// Must match `LayoutC`, `ScreenC` and `ConfigC` in curtain_mac.rs.
typedef struct {
    int32_t width, height, mark_x, mark_y, mark_size, border, title_px, title_top, title_line,
        sub_px, sub_top, sub_line, glow;
} SenseCurtainLayout;

typedef struct {
    uint32_t display_id;
    int32_t x;
    int32_t y;
} SenseCurtainScreen;

typedef struct {
    const char *title_bold;
    const char *title_light;
    const char *subtitle;
    const float *mark_ops;
    size_t mark_ops_len;
    uint8_t muted[3];
    uint8_t border[3];
    uint8_t green[3];
    uint8_t white[3];
    uint32_t transition_ms;
    void (*layout)(int32_t, int32_t, SenseCurtainLayout *);
    void (*glow_size)(int32_t, int32_t, int32_t *, int32_t *);
    void (*glow_pixels)(int32_t, int32_t, float, uint32_t *);
    void (*watched)(const SenseCurtainScreen *, size_t, bool *);
} SenseCurtainConfig;
}

// Path operations (`OP_*` in curtain_mac.rs).
static const float kOpMove = 0, kOpLine = 1, kOpCubic = 2, kOpClose = 3;
// Remote input from enigo (libs/enigo/src/macos/macos_impl.rs, ENIGO_INPUT_EXTRA_VALUE).
static const int64_t kSenseEnigoInput = 100;
static NSString *const kSenseIconNote = @"SenseRemoteCurtain";

// ---- main-thread state ----
static SenseCurtainConfig g_cfg;
static NSMutableArray *g_windows = nil;
static NSBezierPath *g_mark = nil;  // unit square, y down
static NSString *g_title_bold = nil, *g_title_light = nil, *g_subtitle = nil;
static id g_ticker = nil;
static NSTimer *g_refresh_timer = nil, *g_anim_timer = nil;
static CFAbsoluteTime g_anim_last = 0;
static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_tap_source = NULL;
// ---- any thread ----
static std::atomic<uint64_t> g_curtain_gen{0};
static std::atomic<uint64_t> g_input_gen{0};

static NSColor *SenseRGB(const uint8_t c[3], CGFloat alpha) {
    return [NSColor colorWithSRGBRed:c[0] / 255.0 green:c[1] / 255.0 blue:c[2] / 255.0 alpha:alpha];
}

static NSFont *SenseFont(NSArray<NSString *> *names, CGFloat px, CGFloat weight) {
    for (NSString *name in names) {
        NSFont *f = [NSFont fontWithName:name size:px];
        if (f) return f;  // Poppins when the computer has it (BRAND_CORE)
    }
    return [NSFont systemFontOfSize:px weight:weight];
}

// ---------------------------------------------------------------------------------------------

@interface SenseCurtainView : NSView {
  @public
    uint32_t displayId;
    float level;   // 0 white logo … 1 green logo (the screen the Controller watches)
    float target;
    CGImageRef glow;
    NSSize glowFor;
}
@end

@implementation SenseCurtainView
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)isOpaque {
    return YES;
}
- (NSView *)hitTest:(NSPoint)point {
    return nil;  // input goes through
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return NO;
}
- (void)dealloc {
    if (glow) CGImageRelease(glow);
    [super dealloc];
}

- (void)rebuildGlow:(NSSize)size {
    if (glow) {
        CGImageRelease(glow);
        glow = NULL;
    }
    glowFor = size;
    int32_t w = (int32_t)lround(size.width), h = (int32_t)lround(size.height);
    if (w <= 0 || h <= 0 || !g_cfg.glow_size || !g_cfg.glow_pixels) return;
    int32_t gw = 0, gh = 0;
    g_cfg.glow_size(w, h, &gw, &gh);
    if (gw <= 0 || gh <= 0) return;
    std::vector<uint32_t> px((size_t)gw * (size_t)gh, 0);
    g_cfg.glow_pixels(gw, gh, (float)w / (float)h, px.data());
    // 0x00RRGGBB words, little endian in memory: B, G, R, X.
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)px.data(), (CFIndex)(px.size() * 4));
    if (!data) return;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    if (!provider) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    glow = CGImageCreate(gw, gh, 8, 32, (size_t)gw * 4, space,
                         kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL,
                         true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [[NSColor blackColor] setFill];
    NSRectFill(dirty);
    int32_t w = (int32_t)lround(b.size.width), h = (int32_t)lround(b.size.height);
    if (w <= 0 || h <= 0 || !g_cfg.layout) return;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    // Background glow (navy middle, purple lower right), stretched like on Windows.
    if (!glow || !NSEqualSizes(glowFor, b.size)) [self rebuildGlow:b.size];
    if (glow && ctx) {
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, b.size.height);  // the view is flipped, the image is not
        CGContextScaleCTM(ctx, 1, -1);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake(0, 0, b.size.width, b.size.height), glow);
        CGContextRestoreGState(ctx);
    }

    SenseCurtainLayout L;
    memset(&L, 0, sizeof(L));
    g_cfg.layout(w, h, &L);
    float t = level < 0 ? 0 : (level > 1 ? 1 : level);
    CGFloat border = L.border > 0 ? L.border : 1;
    NSRect circle = NSMakeRect(L.mark_x, L.mark_y, L.mark_size, L.mark_size);

    // Green glow around a watched screen's logo (H5: #00FFB6, 14 px).
    if (t > 0) {
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowOffset = NSZeroSize;
        shadow.shadowBlurRadius = L.glow;
        shadow.shadowColor = SenseRGB(g_cfg.green, 0.6 * t);
        [shadow set];
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
        [shadow release];
        [NSGraphicsContext restoreGraphicsState];
    }

    // The mark in a thin round box (as on Windows).
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, border / 2, border / 2)];
    [[NSColor blackColor] setFill];
    [ring fill];
    ring.lineWidth = border;
    [SenseRGB(g_cfg.border, 1) setStroke];
    [ring stroke];

    CGFloat inset = border + L.mark_size / 16.0;
    CGFloat icon = L.mark_size - 2 * inset;
    if (icon > 0 && g_mark) {
        // The program icon has a margin around the mark; the bare mark gets the same room.
        CGFloat m = icon * 0.86;
        NSAffineTransform *tr = [NSAffineTransform transform];
        [tr translateXBy:L.mark_x + inset + (icon - m) / 2 yBy:L.mark_y + inset + (icon - m) / 2];
        [tr scaleBy:m];
        NSBezierPath *mark = [[g_mark copy] autorelease];
        [mark transformUsingAffineTransform:tr];
        CGFloat r = (g_cfg.white[0] + (g_cfg.green[0] - g_cfg.white[0]) * t) / 255.0;
        CGFloat g = (g_cfg.white[1] + (g_cfg.green[1] - g_cfg.white[1]) * t) / 255.0;
        CGFloat bl = (g_cfg.white[2] + (g_cfg.green[2] - g_cfg.white[2]) * t) / 255.0;
        [[NSColor colorWithSRGBRed:r green:g blue:bl alpha:1] setFill];
        [mark fill];
    }

    // "**Bakım** yapılıyor" and the subtitle.
    NSFont *bold = SenseFont(@[ @"Poppins-Bold" ], L.title_px, NSFontWeightBold);
    NSFont *light = SenseFont(@[ @"Poppins-ExtraLight", @"Poppins-Light" ], L.title_px,
                              NSFontWeightUltraLight);
    NSFont *sub = SenseFont(@[ @"Poppins-Light" ], L.sub_px, NSFontWeightLight);
    NSColor *white = [NSColor whiteColor];
    NSMutableAttributedString *title = [[[NSMutableAttributedString alloc] init] autorelease];
    if (g_title_bold) {
        [title appendAttributedString:[[[NSAttributedString alloc]
                                          initWithString:g_title_bold
                                              attributes:@{NSFontAttributeName : bold,
                                                           NSForegroundColorAttributeName : white}]
                                          autorelease]];
    }
    if (g_title_light) {
        [title appendAttributedString:[[[NSAttributedString alloc]
                                          initWithString:g_title_light
                                              attributes:@{NSFontAttributeName : light,
                                                           NSForegroundColorAttributeName : white}]
                                          autorelease]];
    }
    NSSize ts = [title size];
    [title drawAtPoint:NSMakePoint((w - ts.width) / 2, L.title_top)];
    if (g_subtitle) {
        NSAttributedString *s = [[[NSAttributedString alloc]
            initWithString:g_subtitle
                attributes:@{NSFontAttributeName : sub,
                             NSForegroundColorAttributeName : SenseRGB(g_cfg.muted, 1)}]
            autorelease];
        NSSize ss = [s size];
        [s drawAtPoint:NSMakePoint((w - ss.width) / 2, L.sub_top)];
    }
}
@end

@interface SenseCurtainWindow : NSWindow
@end

@implementation SenseCurtainWindow
- (BOOL)canBecomeKeyWindow {
    return NO;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end

// ---------------------------------------------------------------------------------------------

static void SensePostIcon(bool on) {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kSenseIconNote
                                                                   object:(on ? @"on" : @"off")
                                                                 userInfo:nil
                                                       deliverImmediately:YES];
}

static NSArray *SenseCreateWindows(NSArray<NSScreen *> *screens) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSScreen *screen in screens) {
        NSRect f = screen.frame;
        SenseCurtainWindow *win =
            [[SenseCurtainWindow alloc] initWithContentRect:f
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        win.releasedWhenClosed = NO;
        win.opaque = YES;
        win.backgroundColor = [NSColor blackColor];
        win.hasShadow = NO;
        win.ignoresMouseEvents = YES;
        win.hidesOnDeactivate = NO;
        win.animationBehavior = NSWindowAnimationBehaviorNone;
        // Above Dock, menu bar and full-screen apps; the Sense icon goes one level higher.
        win.level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
        win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorStationary |
                                 NSWindowCollectionBehaviorIgnoresCycle |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
        // Kept out of capture: the Controller sees the real screen.
        win.sharingType = NSWindowSharingNone;
        [win setFrame:f display:NO];
        SenseCurtainView *view =
            [[SenseCurtainView alloc] initWithFrame:NSMakeRect(0, 0, f.size.width, f.size.height)];
        view->displayId = [[screen.deviceDescription objectForKey:@"NSScreenNumber"] unsignedIntValue];
        win.contentView = view;
        [view release];
        [out addObject:win];
        [win release];
    }
    return out;
}

static void SenseOrderFront(NSArray *windows) {
    for (NSWindow *w in windows) [w orderFrontRegardless];
}

static void SenseCloseWindows(NSArray *windows) {
    for (NSWindow *w in windows) {
        [w orderOut:nil];
        [w close];
    }
}

static void SenseStopAnimation() {
    [g_anim_timer invalidate];
    [g_anim_timer release];
    g_anim_timer = nil;
}

// Reads the watched screens; `animate` = move the logos over the transition time.
static void SenseUpdateWatched(bool animate);

@interface SenseCurtainTicker : NSObject
@end

@implementation SenseCurtainTicker
- (void)refresh:(NSTimer *)timer {
    SensePostIcon(true);
    // Screens the windows do not match any more (missed notification): rebuild.
    NSArray<NSScreen *> *screens = [NSScreen screens];
    bool same = screens.count == g_windows.count;
    for (NSUInteger i = 0; same && i < screens.count; i++) {
        same = NSEqualRects(screens[i].frame, [g_windows[i] frame]);
    }
    if (!same) [self screensChanged:nil];
}
- (void)screensChanged:(NSNotification *)note {
    if (!g_windows) return;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) return;
    // New windows first, so the screens are never uncovered in between.
    NSArray *fresh = SenseCreateWindows(screens);
    NSArray *old = [g_windows copy];
    [g_windows removeAllObjects];
    [g_windows addObjectsFromArray:fresh];
    SenseUpdateWatched(false);
    SenseOrderFront(g_windows);
    SenseCloseWindows(old);
    [old release];
    NSLog(@"Sense curtain: screens changed (%lu)", (unsigned long)g_windows.count);
}
- (void)animate:(NSTimer *)timer {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double dt = (now - g_anim_last) * 1000.0;
    g_anim_last = now;
    if (dt > 1000) dt = 1000;
    float step = (float)(dt / (g_cfg.transition_ms > 0 ? g_cfg.transition_ms : 1));
    bool moving = false;
    for (NSWindow *w in g_windows) {
        SenseCurtainView *v = (SenseCurtainView *)w.contentView;
        if (v->level < v->target) {
            v->level = MIN(v->level + step, v->target);
        } else if (v->level > v->target) {
            v->level = MAX(v->level - step, v->target);
        }
        moving |= v->level != v->target;
        [v setNeedsDisplay:YES];
    }
    if (!moving) SenseStopAnimation();
}
@end

static void SenseUpdateWatched(bool animate) {
    NSUInteger n = g_windows.count;
    if (n == 0 || !g_cfg.watched) return;
    std::vector<SenseCurtainScreen> screens(n);
    std::unique_ptr<bool[]> flags(new bool[n]());
    for (NSUInteger i = 0; i < n; i++) {
        SenseCurtainView *v = (SenseCurtainView *)[g_windows[i] contentView];
        CGRect r = CGDisplayBounds(v->displayId);  // the video service's display origin
        screens[i] = {v->displayId, (int32_t)r.origin.x, (int32_t)r.origin.y};
    }
    g_cfg.watched(screens.data(), n, flags.get());
    bool moving = false;
    for (NSUInteger i = 0; i < n; i++) {
        SenseCurtainView *v = (SenseCurtainView *)[g_windows[i] contentView];
        v->target = flags[i] ? 1.0f : 0.0f;
        if (!animate) {
            v->level = v->target;
            [v setNeedsDisplay:YES];
        }
        moving |= v->level != v->target;
    }
    if (animate && moving && !g_anim_timer) {
        g_anim_last = CFAbsoluteTimeGetCurrent();
        g_anim_timer = [[NSTimer timerWithTimeInterval:1.0 / 60.0
                                                target:g_ticker
                                              selector:@selector(animate:)
                                              userInfo:nil
                                               repeats:YES] retain];
        [[NSRunLoop mainRunLoop] addTimer:g_anim_timer forMode:NSRunLoopCommonModes];
    }
}

static NSBezierPath *SenseMarkPath(const float *ops, size_t n) {
    if (!ops || n == 0) return nil;
    NSBezierPath *p = [NSBezierPath bezierPath];
    size_t i = 0;
    while (i < n) {
        float op = ops[i];
        if (op == kOpMove && i + 2 < n) {
            [p moveToPoint:NSMakePoint(ops[i + 1], ops[i + 2])];
            i += 3;
        } else if (op == kOpLine && i + 2 < n) {
            [p lineToPoint:NSMakePoint(ops[i + 1], ops[i + 2])];
            i += 3;
        } else if (op == kOpCubic && i + 6 < n) {
            [p curveToPoint:NSMakePoint(ops[i + 5], ops[i + 6])
              controlPoint1:NSMakePoint(ops[i + 1], ops[i + 2])
              controlPoint2:NSMakePoint(ops[i + 3], ops[i + 4])];
            i += 7;
        } else if (op == kOpClose) {
            [p closePath];
            i += 1;
        } else {
            return nil;  // malformed: no mark rather than a wrong one
        }
    }
    p.windingRule = NSWindingRuleNonZero;
    return [p copy];  // owned (+1)
}

static void SenseClose() {
    if (!g_windows) return;
    SenseStopAnimation();
    [g_refresh_timer invalidate];
    [g_refresh_timer release];
    g_refresh_timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:g_ticker];
    SenseCloseWindows(g_windows);
    [g_windows release];
    g_windows = nil;
    [g_ticker release];
    g_ticker = nil;
    [g_mark release];
    g_mark = nil;
    [g_title_bold release];
    [g_title_light release];
    [g_subtitle release];
    g_title_bold = g_title_light = g_subtitle = nil;
    SensePostIcon(false);
    NSLog(@"Sense curtain off");
}

static bool SenseOpen() {
    if (g_windows) return true;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) {
        NSLog(@"Sense curtain: no screen found");
        return false;
    }
    g_mark = SenseMarkPath(g_cfg.mark_ops, g_cfg.mark_ops_len);
    g_title_bold = g_cfg.title_bold ? [[NSString alloc] initWithUTF8String:g_cfg.title_bold] : nil;
    g_title_light = g_cfg.title_light ? [[NSString alloc] initWithUTF8String:g_cfg.title_light] : nil;
    g_subtitle = g_cfg.subtitle ? [[NSString alloc] initWithUTF8String:g_cfg.subtitle] : nil;
    g_ticker = [[SenseCurtainTicker alloc] init];
    g_windows = [[NSMutableArray alloc] initWithArray:SenseCreateWindows(screens)];
    SenseUpdateWatched(false);
    // The icon first, so it is never under the curtain longer than one notification trip.
    SensePostIcon(true);
    SenseOrderFront(g_windows);
    [[NSNotificationCenter defaultCenter] addObserver:g_ticker
                                             selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    g_refresh_timer = [[NSTimer timerWithTimeInterval:1.0
                                               target:g_ticker
                                             selector:@selector(refresh:)
                                             userInfo:nil
                                              repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:g_refresh_timer forMode:NSRunLoopCommonModes];
    NSLog(@"Sense curtain on (%lu screens)", (unsigned long)g_windows.count);
    return true;
}

// ---- local input (same rule as RustDesk's macOS privacy mode) ----

static CGEventRef SenseTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event,
                                   void *refcon) {
    (void)proxy;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kSenseEnigoInput) {
        return event;  // remote input
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState) {
        return NULL;  // physical keyboard / mouse of this computer
    }
    return event;
}

static bool SenseTapOn() {
    if (g_tap) return true;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                       CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventScrollWheel);
    g_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask,
                             SenseTapCallback, NULL);
    if (!g_tap) {
        NSLog(@"Sense curtain: event tap could not be created (Accessibility)");
        return false;
    }
    g_tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    return true;
}

static void SenseTapOff() {
    if (!g_tap) return;
    CGEventTapEnable(g_tap, false);
    if (g_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
        CFRelease(g_tap_source);
        g_tap_source = NULL;
    }
    CFRelease(g_tap);
    g_tap = NULL;
}

// ---- thread hop ----

namespace {
struct SenseWait {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    bool ok = false;
};
}  // namespace

// Runs `work` on the main thread and waits up to `timeout_ms`. False on timeout.
static bool SenseRunOnMain(uint32_t timeout_ms, bool *timed_out, bool (^work)(void)) {
    if (timed_out) *timed_out = false;
    if ([NSThread isMainThread]) return work();
    std::shared_ptr<SenseWait> wait = std::make_shared<SenseWait>();
    dispatch_async(dispatch_get_main_queue(), ^{
      bool ok = work();
      {
          std::lock_guard<std::mutex> lock(wait->m);
          wait->ok = ok;
          wait->done = true;
      }
      wait->cv.notify_all();
    });
    std::unique_lock<std::mutex> lock(wait->m);
    if (!wait->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return wait->done; })) {
        if (timed_out) *timed_out = true;
        return false;
    }
    return wait->ok;
}

extern "C" bool SenseCurtainMacShow(const SenseCurtainConfig *cfg, uint32_t timeout_ms) {
    if (!cfg) return false;
    SenseCurtainConfig c = *cfg;
    uint64_t gen = ++g_curtain_gen;
    bool timed_out = false;
    bool ok = SenseRunOnMain(timeout_ms, &timed_out, ^bool {
      if (g_curtain_gen.load() != gen) return false;  // hidden or asked again meanwhile
      g_cfg = c;
      return SenseOpen();
    });
    if (timed_out) {
        // Nobody waits any more: what was asked must not appear later on its own.
        uint64_t cancel = ++g_curtain_gen;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (g_curtain_gen.load() == cancel) SenseClose();
        });
        NSLog(@"Sense curtain: main thread did not answer in time");
    }
    return ok;
}

extern "C" void SenseCurtainMacHide(uint32_t timeout_ms) {
    uint64_t gen = ++g_curtain_gen;
    SenseRunOnMain(timeout_ms, NULL, ^bool {
      if (g_curtain_gen.load() == gen) SenseClose();
      return true;
    });
}

extern "C" void SenseCurtainMacWatchedChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_windows) SenseUpdateWatched(true);
    });
}

extern "C" bool SenseCurtainMacBlockInput(bool on, uint32_t timeout_ms) {
    uint64_t gen = ++g_input_gen;
    bool timed_out = false;
    bool ok = SenseRunOnMain(timeout_ms, &timed_out, ^bool {
      if (g_input_gen.load() != gen) return !on;  // superseded
      if (on) return SenseTapOn();
      SenseTapOff();
      return true;
    });
    if (timed_out && on) {
        // Reported as failed: the tap must not come later on its own.
        uint64_t cancel = ++g_input_gen;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (g_input_gen.load() == cancel) SenseTapOff();
        });
    }
    return ok;
}
