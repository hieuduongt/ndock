#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>
#import "NDConfig.h"

static const CGFloat kNDNearFullTol = 8.0;
static const CGFloat kNDPinTol = 0.5;
static const CGFloat kNDTileSplitTol = 3.0;
static const int kNDMaxGridDivisions = 8;
static const CFTimeInterval kNDWindowListCacheTTL = 0.08;

typedef void (*set_frame_animate_fn)(id, SEL, CGRect, BOOL, BOOL);
typedef void (*zoom_to_frame_fn)(id, SEL, CGRect, BOOL, BOOL, NSInteger);
typedef void (*set_frame_fn)(id, SEL, CGRect, BOOL);
typedef void (*set_frame_common_fn)(id, SEL, CGRect, BOOL, BOOL);
typedef CGRect (*std_frame_fn)(id, SEL);
typedef CGRect (*std_screen_fn)(id, SEL, id, BOOL);
typedef CGRect (*constrain_fn)(id, SEL, CGRect, id);

static set_frame_animate_fn orig_setFrameAnimate = NULL;
static set_frame_fn orig_setFrameDisplay = NULL;
static std_frame_fn orig_standardFrame = NULL;
static std_screen_fn orig_standardFrameForScreen = NULL;
static constrain_fn orig_constrainFrame = NULL;
static zoom_to_frame_fn orig_zoomToFrame = NULL;
static set_frame_common_fn orig_setFrameCommon = NULL;

static IMP gSetFrameAnimateHookIMP = NULL;
static IMP gSetFrameCommonHookIMP = NULL;
static IMP gConstrainHookIMP = NULL;
static IMP gSetFrameHookIMP = NULL;
static IMP gZoomToFrameHookIMP = NULL;
static IMP gStandardFrameHookIMP = NULL;
static IMP gStandardFrameForScreenHookIMP = NULL;

static Class gNSWindowClass = NULL;
static NSMutableSet<NSString *> *gHookedMethods = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassConstrainOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassSetFrameOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassZoomToFrameOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassStandardFrameOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassStandardFrameForScreenOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassSetFrameAnimateOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassSetFrameCommonOrig = nil;
static NSMutableSet<NSString *> *gFullyHookedClasses = nil;

static BOOL gNDWindowMarginActive = NO;
static BOOL gNDSwiftUIHooked = NO;

static NSArray *gNDWindowListCache = nil;
static CFAbsoluteTime gNDWindowListCacheTime = 0;

static __thread BOOL gNDInConstrain = NO;
static __thread BOOL gNDInStandardFrame = NO;
static __thread BOOL gNDInSetFrame = NO;
static __thread BOOL gNDInSetFrameAnimate = NO;
static __thread BOOL gNDInSetFrameCommon = NO;
static __thread BOOL gNDInAdjacentReflow = NO;

typedef const char **(*copy_class_names_fn)(const char *, unsigned int *);
static copy_class_names_fn gCopyClassNamesForImage = NULL;

static const char *kNDKnownWindowClasses[] = {
    "Window", "BrowserWindow", "BrowserWKWindow", NULL
};

static void NDHookWindowSubclass(Class cls);

static inline BOOL NDMarginEnabled(void) {
    return NDWindowMarginPerSide() > 0;
}

static NSScreen *NDWindowScreen(id self) {
    NSScreen *screen = [(NSWindow *)self screen];
    return screen ?: NSScreen.mainScreen;
}

static BOOL NDShouldHookWindow(id self) {
    if (!gNDWindowMarginActive) return NO;
    if (![self isKindOfClass:gNSWindowClass]) return NO;
    NSWindow *win = (NSWindow *)self;
    NSWindowStyleMask mask = win.styleMask;
    return (mask & NSWindowStyleMaskTitled) && ![win isKindOfClass:[NSPanel class]];
}

static IMP NDSubclassOrigIMP(id self, NSMutableDictionary *map, IMP fallback) {
    if (map) {
        NSValue *v = map[NSStringFromClass(object_getClass(self))];
        if (v) return [v pointerValue];
    }
    return fallback;
}

static BOOL NDFrameMatches(CGRect a, CGRect b, CGFloat tol) {
    return fabs(a.size.width - b.size.width) < tol &&
           fabs(a.size.height - b.size.height) < tol &&
           fabs(a.origin.x - b.origin.x) < tol &&
           fabs(a.origin.y - b.origin.y) < tol;
}

static BOOL NDIsNearFull(CGRect frame, CGRect visible) {
    return NDFrameMatches(frame, visible, kNDNearFullTol);
}

static BOOL NDTouchesLeftEdge(CGRect frame, CGRect visible, CGFloat margin) {
    return frame.origin.x < visible.origin.x + margin - 0.5;
}

static BOOL NDTouchesRightEdge(CGRect frame, CGRect visible, CGFloat margin) {
    return (frame.origin.x + frame.size.width) > (visible.origin.x + visible.size.width - margin + 0.5);
}

static BOOL NDTouchesBottomEdge(CGRect frame, CGRect visible, CGFloat margin) {
    return frame.origin.y < visible.origin.y + margin - 0.5;
}

static BOOL NDTouchesTopEdge(CGRect frame, CGRect visible, CGFloat margin) {
    return (frame.origin.y + frame.size.height) > (visible.origin.y + visible.size.height - margin + 0.5);
}

static BOOL NDFrameHasProperMargins(CGRect frame, CGRect visible, CGFloat margin) {
    return !NDTouchesLeftEdge(frame, visible, margin) &&
           !NDTouchesRightEdge(frame, visible, margin) &&
           !NDTouchesBottomEdge(frame, visible, margin) &&
           !NDTouchesTopEdge(frame, visible, margin);
}

static CGRect NDMaxAllowedFrame(NSScreen *screen, CGFloat margin) {
    if (!screen) return CGRectZero;
    CGRect visible = screen.visibleFrame;
    return CGRectMake(visible.origin.x + margin,
                      visible.origin.y + margin,
                      visible.size.width - 2.0 * margin,
                      visible.size.height - 2.0 * margin);
}

static CGRect NDApplyEdgeMargins(CGRect frame, CGRect visible, CGFloat margin) {
    CGRect out = frame;
    if (NDTouchesLeftEdge(frame, visible, margin)) {
        out.origin.x = visible.origin.x + margin;
        out.size.width = (frame.origin.x + frame.size.width) - out.origin.x;
    }
    if (NDTouchesRightEdge(frame, visible, margin))
        out.size.width = visible.origin.x + visible.size.width - margin - out.origin.x;
    if (NDTouchesBottomEdge(frame, visible, margin)) {
        out.origin.y = visible.origin.y + margin;
        out.size.height = (frame.origin.y + frame.size.height) - out.origin.y;
    }
    if (NDTouchesTopEdge(frame, visible, margin))
        out.size.height = visible.origin.y + visible.size.height - margin - out.origin.y;
    return out;
}

static BOOL NDPinnedToVisibleBottom(CGRect frame, CGRect visible);
static BOOL NDPinnedToVisibleTop(CGRect frame, CGRect visible);
static BOOL NDPinnedToVisibleLeft(CGRect frame, CGRect visible);
static BOOL NDPinnedToVisibleRight(CGRect frame, CGRect visible);
static CGRect NDCapPinnedEdgesForWindow(CGRect frame, NSScreen *screen, id window);

static BOOL NDCoordNearGridSplit(CGFloat coord, CGFloat origin, CGFloat span, CGFloat tol) {
    if (span <= 0) return NO;
    if (fabs(coord - origin) <= tol || fabs(coord - (origin + span)) <= tol)
        return NO;
    for (int n = 2; n <= kNDMaxGridDivisions; n++) {
        for (int i = 1; i < n; i++) {
            CGFloat split = origin + span * ((CGFloat)i / (CGFloat)n);
            if (fabs(coord - split) <= tol)
                return YES;
        }
    }
    return NO;
}

static BOOL NDLooksLikeArrangedTile(CGRect frame, CGRect visible) {
    return frame.size.width >= visible.size.width * 0.18 &&
           frame.size.height >= visible.size.height * 0.18;
}

static BOOL NDShouldApplyLayoutMargins(CGRect frame, CGRect visible) {
    if (!NDLooksLikeArrangedTile(frame, visible)) return NO;
    if (NDPinnedToVisibleLeft(frame, visible) || NDPinnedToVisibleRight(frame, visible) ||
        NDPinnedToVisibleTop(frame, visible) || NDPinnedToVisibleBottom(frame, visible))
        return YES;
    CGFloat left = frame.origin.x;
    CGFloat right = frame.origin.x + frame.size.width;
    CGFloat bottom = frame.origin.y;
    CGFloat top = frame.origin.y + frame.size.height;
    return NDCoordNearGridSplit(left, visible.origin.x, visible.size.width, kNDTileSplitTol) ||
           NDCoordNearGridSplit(right, visible.origin.x, visible.size.width, kNDTileSplitTol) ||
           NDCoordNearGridSplit(bottom, visible.origin.y, visible.size.height, kNDTileSplitTol) ||
           NDCoordNearGridSplit(top, visible.origin.y, visible.size.height, kNDTileSplitTol);
}

static CGRect NDRectFromCGWindowInfo(NSDictionary *info) {
    NSDictionary *bd = info[(__bridge NSString *)kCGWindowBounds];
    if (!bd) return CGRectZero;
    return CGRectMake([bd[@"X"] doubleValue], [bd[@"Y"] doubleValue],
                      [bd[@"Width"] doubleValue], [bd[@"Height"] doubleValue]);
}

static NSArray *NDGetOnScreenWindows(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gNDWindowListCache && (now - gNDWindowListCacheTime) < kNDWindowListCacheTTL)
        return gNDWindowListCache;
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    gNDWindowListCache = CFBridgingRelease(raw) ?: @[];
    gNDWindowListCacheTime = now;
    return gNDWindowListCache;
}

static BOOL NDAxisOverlap(CGFloat a0, CGFloat a1, CGFloat b0, CGFloat b1, CGFloat minLen) {
    return fmin(a1, b1) - fmax(a0, b0) >= minLen;
}

/// Detect edges touching another on-screen window (Fill & Arrange arbitrary grids).
static CGRect NDApplyAdjacentWindowGaps(CGRect frame, NSScreen *screen, CGFloat margin, CGWindowID selfWID) {
    if (margin <= 0 || !screen || selfWID == 0) return frame;
    if (!NDLooksLikeArrangedTile(frame, screen.visibleFrame)) return frame;

    CGFloat half = margin * 0.5;
    CGFloat tol = kNDTileSplitTol;
    CGRect visible = screen.visibleFrame;
    CGFloat minOverlap = fmin(visible.size.width, visible.size.height) * 0.2;
    CGFloat left = frame.origin.x;
    CGFloat right = frame.origin.x + frame.size.width;
    CGFloat bottom = frame.origin.y;
    CGFloat top = frame.origin.y + frame.size.height;
    CGRect out = frame;

    @autoreleasepool {
        for (NSDictionary *info in NDGetOnScreenWindows()) {
            NSNumber *widNum = info[(__bridge NSString *)kCGWindowNumber];
            if (!widNum || widNum.intValue == (int)selfWID) continue;
            NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
            if (layer && layer.intValue != 0) continue;

            CGRect other = NDRectFromCGWindowInfo(info);
            if (other.size.width < 80 || other.size.height < 60) continue;
            if (!CGRectIntersectsRect(other, visible)) continue;

            CGFloat oL = other.origin.x;
            CGFloat oR = other.origin.x + other.size.width;
            CGFloat oB = other.origin.y;
            CGFloat oT = other.origin.y + other.size.height;

            if (fabs(right - oL) <= tol && NDAxisOverlap(bottom, top, oB, oT, minOverlap) &&
                !NDPinnedToVisibleRight(frame, visible))
                out.size.width -= half;

            if (fabs(left - oR) <= tol && NDAxisOverlap(bottom, top, oB, oT, minOverlap) &&
                !NDPinnedToVisibleLeft(frame, visible)) {
                out.origin.x += half;
                out.size.width -= half;
            }

            if (fabs(top - oB) <= tol && NDAxisOverlap(left, right, oL, oR, minOverlap) &&
                !NDPinnedToVisibleTop(frame, visible))
                out.size.height -= half;

            if (fabs(bottom - oT) <= tol && NDAxisOverlap(left, right, oL, oR, minOverlap) &&
                !NDPinnedToVisibleBottom(frame, visible)) {
                out.origin.y += half;
                out.size.height -= half;
            }
        }
    }

    if (out.size.width < 1.0 || out.size.height < 1.0)
        return frame;
    return out;
}

/// Inset edges aligned with tile grid splits (half, thirds, quarters, …).
static CGRect NDApplyTileGaps(CGRect frame, CGRect visible, CGFloat margin) {
    if (margin <= 0) return frame;

    CGFloat half = margin * 0.5;
    CGFloat left = frame.origin.x;
    CGFloat right = frame.origin.x + frame.size.width;
    CGFloat bottom = frame.origin.y;
    CGFloat top = frame.origin.y + frame.size.height;
    CGRect out = frame;

    if (NDCoordNearGridSplit(left, visible.origin.x, visible.size.width, kNDTileSplitTol)) {
        out.origin.x += half;
        out.size.width -= half;
    }
    if (NDCoordNearGridSplit(right, visible.origin.x, visible.size.width, kNDTileSplitTol))
        out.size.width -= half;
    if (NDCoordNearGridSplit(bottom, visible.origin.y, visible.size.height, kNDTileSplitTol)) {
        out.origin.y += half;
        out.size.height -= half;
    }
    if (NDCoordNearGridSplit(top, visible.origin.y, visible.size.height, kNDTileSplitTol))
        out.size.height -= half;

    if (out.size.width < 1.0 || out.size.height < 1.0)
        return frame;
    return out;
}

static void NDReflowAdjacentGaps(id self, SEL _cmd, BOOL fromServer) {
    set_frame_common_fn orig = (set_frame_common_fn)NDSubclassOrigIMP(
        self, gSubclassSetFrameCommonOrig, (IMP)orig_setFrameCommon);
    if (!NDShouldHookWindow(self) || gNDInAdjacentReflow || !orig) return;

    NSScreen *scr = NDWindowScreen(self);
    CGFloat margin = NDWindowMarginPerSide();
    if (margin <= 0) return;

    CGRect visible = scr.visibleFrame;
    CGRect current = [(NSWindow *)self frame];
    if (!NDShouldApplyLayoutMargins(current, visible)) return;

    gNDWindowListCacheTime = 0;
    CGWindowID wid = (CGWindowID)[(NSWindow *)self windowNumber];
    CGRect fixed = NDApplyAdjacentWindowGaps(current, scr, margin, wid);
    if (NDFrameMatches(current, fixed, 0.5)) return;

    gNDInAdjacentReflow = YES;
    orig(self, _cmd, fixed, YES, fromServer);
    gNDInAdjacentReflow = NO;
}

static CGRect NDCapFrame(CGRect frame, NSScreen *screen, BOOL allowEdges) {
    CGFloat margin = NDWindowMarginPerSide();
    if (!screen || margin <= 0) return frame;
    CGRect visible = screen.visibleFrame;
    if (NDIsNearFull(frame, visible))
        return NDMaxAllowedFrame(screen, margin);
    if (allowEdges && !NDFrameHasProperMargins(frame, visible, margin)) {
        if (NDTouchesLeftEdge(frame, visible, margin) ||
            NDTouchesRightEdge(frame, visible, margin) ||
            NDTouchesBottomEdge(frame, visible, margin) ||
            NDTouchesTopEdge(frame, visible, margin))
            frame = NDApplyEdgeMargins(frame, visible, margin);
    }
    return NDApplyTileGaps(frame, visible, margin);
}

static Class NDHookableWindowClass(id self) {
    Class cls = object_getClass(self);
    while (cls && cls != gNSWindowClass) {
        if (strncmp(class_getName(cls), "NSKVONotifying_", 15) != 0)
            return cls;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void NDEnsureHookCollections(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHookedMethods = [NSMutableSet set];
        gSubclassSetFrameAnimateOrig = [NSMutableDictionary new];
        gSubclassConstrainOrig = [NSMutableDictionary new];
        gSubclassSetFrameOrig = [NSMutableDictionary new];
        gSubclassZoomToFrameOrig = [NSMutableDictionary new];
        gSubclassStandardFrameOrig = [NSMutableDictionary new];
        gSubclassStandardFrameForScreenOrig = [NSMutableDictionary new];
        gSubclassSetFrameCommonOrig = [NSMutableDictionary new];
        gFullyHookedClasses = [NSMutableSet set];
    });
}

static void NDEnsureSubclassHooked(id self) {
    Class cls = object_getClass(self);
    if (cls == gNSWindowClass || !gSetFrameHookIMP) return;
    cls = NDHookableWindowClass(self);
    if (!cls) return;
    NDEnsureHookCollections();
    NSString *name = NSStringFromClass(cls);
    if ([gFullyHookedClasses containsObject:name]) return;
    NDHookWindowSubclass(cls);
    [gFullyHookedClasses addObject:name];
}

static CGRect nd_standardFrame(id self, SEL _cmd) {
    std_frame_fn orig = (std_frame_fn)NDSubclassOrigIMP(self, gSubclassStandardFrameOrig,
                                                       (IMP)orig_standardFrame);
    if (!orig || !NDShouldHookWindow(self) || gNDInStandardFrame)
        return orig ? orig(self, _cmd) : CGRectZero;
    gNDInStandardFrame = YES;
    CGRect natural = orig(self, _cmd);
    gNDInStandardFrame = NO;
    return NDCapFrame(natural, NDWindowScreen(self), YES);
}

static CGRect nd_standardFrameForScreen(id self, SEL _cmd, id screen, BOOL moveToIPad) {
    std_screen_fn orig = (std_screen_fn)NDSubclassOrigIMP(self, gSubclassStandardFrameForScreenOrig,
                                                          (IMP)orig_standardFrameForScreen);
    if (!orig || !NDShouldHookWindow(self) || gNDInStandardFrame)
        return orig ? orig(self, _cmd, screen, moveToIPad) : CGRectZero;
    gNDInStandardFrame = YES;
    CGRect natural = orig(self, _cmd, screen, moveToIPad);
    gNDInStandardFrame = NO;
    NSScreen *scr = [(id)screen isKindOfClass:[NSScreen class]] ? (NSScreen *)screen : NDWindowScreen(self);
    return NDCapFrame(natural, scr, YES);
}

static void nd_zoomToFrame(id self, SEL _cmd, CGRect frame, BOOL willChangeScreens,
                           BOOL moveToIPad, NSInteger zoomState) {
    zoom_to_frame_fn orig = (zoom_to_frame_fn)NDSubclassOrigIMP(self, gSubclassZoomToFrameOrig,
                                                                (IMP)orig_zoomToFrame);
    if (!orig) return;
    if (NDShouldHookWindow(self))
        frame = NDCapPinnedEdgesForWindow(frame, NDWindowScreen(self), self);
    orig(self, _cmd, frame, willChangeScreens, moveToIPad, zoomState);
}

static BOOL NDPinnedToVisibleBottom(CGRect frame, CGRect visible) {
    return frame.origin.y <= visible.origin.y + kNDPinTol;
}

static BOOL NDPinnedToVisibleTop(CGRect frame, CGRect visible) {
    return (frame.origin.y + frame.size.height) >= (visible.origin.y + visible.size.height - kNDPinTol);
}

static BOOL NDPinnedToVisibleLeft(CGRect frame, CGRect visible) {
    return frame.origin.x <= visible.origin.x + kNDPinTol;
}

static BOOL NDPinnedToVisibleRight(CGRect frame, CGRect visible) {
    return (frame.origin.x + frame.size.width) >= (visible.origin.x + visible.size.width - kNDPinTol);
}

static CGRect NDCapNearFullOnly(CGRect frame, NSScreen *screen) {
    CGFloat margin = NDWindowMarginPerSide();
    if (!screen || margin <= 0) return frame;
    if (NDIsNearFull(frame, screen.visibleFrame))
        return NDMaxAllowedFrame(screen, margin);
    return frame;
}

static CGRect NDCapLayoutFrame(CGRect frame, NSScreen *screen, id window) {
    CGFloat margin = NDWindowMarginPerSide();
    if (!screen || margin <= 0) return frame;
    CGRect visible = screen.visibleFrame;
    if (NDIsNearFull(frame, visible))
        return NDMaxAllowedFrame(screen, margin);
    if (!NDShouldApplyLayoutMargins(frame, visible))
        return frame;
    return NDCapPinnedEdgesForWindow(frame, screen, window);
}

static CGRect NDCapPinnedEdgesForWindow(CGRect frame, NSScreen *screen, id window) {
    CGFloat margin = NDWindowMarginPerSide();
    if (!screen || margin <= 0) return frame;
    CGRect visible = screen.visibleFrame;
    if (NDIsNearFull(frame, visible))
        return NDMaxAllowedFrame(screen, margin);

    if (NDFrameHasProperMargins(frame, visible, margin))
        frame = NDApplyTileGaps(frame, visible, margin);
    else {
        BOOL pinL = NDPinnedToVisibleLeft(frame, visible);
        BOOL pinR = NDPinnedToVisibleRight(frame, visible);
        BOOL pinB = NDPinnedToVisibleBottom(frame, visible);
        BOOL pinT = NDPinnedToVisibleTop(frame, visible);
        if (!pinL && !pinR && !pinB && !pinT)
            frame = NDApplyTileGaps(frame, visible, margin);
        else {
            CGRect out = frame;
            if (pinL && NDTouchesLeftEdge(frame, visible, margin)) {
                out.origin.x = visible.origin.x + margin;
                out.size.width = (frame.origin.x + frame.size.width) - out.origin.x;
            }
            if (pinR && NDTouchesRightEdge(out, visible, margin))
                out.size.width = visible.origin.x + visible.size.width - margin - out.origin.x;
            if (pinB && NDTouchesBottomEdge(out, visible, margin)) {
                out.origin.y = visible.origin.y + margin;
                out.size.height = (frame.origin.y + frame.size.height) - out.origin.y;
            }
            if (pinT && NDTouchesTopEdge(out, visible, margin))
                out.size.height = visible.origin.y + visible.size.height - margin - out.origin.y;
            if (out.size.width < 1.0 || out.size.height < 1.0)
                return frame;
            frame = NDApplyTileGaps(out, visible, margin);
        }
    }

    if (window) {
        CGWindowID wid = (CGWindowID)[(NSWindow *)window windowNumber];
        frame = NDApplyAdjacentWindowGaps(frame, screen, margin, wid);
    }
    return frame;
}

static void nd_setFrameCommon(id self, SEL _cmd, CGRect frame, BOOL display, BOOL fromServer) {
    if (gNDInSetFrameCommon) {
        if (orig_setFrameCommon)
            orig_setFrameCommon(self, _cmd, frame, display, fromServer);
        return;
    }
    NDEnsureSubclassHooked(self);
    set_frame_common_fn orig = (set_frame_common_fn)NDSubclassOrigIMP(self, gSubclassSetFrameCommonOrig,
                                                                      (IMP)orig_setFrameCommon);
    if (!orig) return;
    if (!gNDInAdjacentReflow && NDShouldHookWindow(self))
        frame = NDCapPinnedEdgesForWindow(frame, NDWindowScreen(self), self);
    gNDInSetFrameCommon = YES;
    orig(self, _cmd, frame, display, fromServer);
    gNDInSetFrameCommon = NO;
    NDReflowAdjacentGaps(self, _cmd, fromServer);
}

static void nd_setFrameAnimate(id self, SEL _cmd, CGRect frame, BOOL display, BOOL animate) {
    if (gNDInSetFrameAnimate) {
        if (orig_setFrameAnimate)
            orig_setFrameAnimate(self, _cmd, frame, display, animate);
        return;
    }
    NDEnsureSubclassHooked(self);
    set_frame_animate_fn orig = (set_frame_animate_fn)NDSubclassOrigIMP(self, gSubclassSetFrameAnimateOrig,
                                                                        (IMP)orig_setFrameAnimate);
    if (!orig) return;
    if (NDShouldHookWindow(self)) {
        NSScreen *scr = NDWindowScreen(self);
        if (animate)
            frame = NDCapLayoutFrame(frame, scr, self);
        else
            frame = NDCapNearFullOnly(frame, scr);
    }
    gNDInSetFrameAnimate = YES;
    orig(self, _cmd, frame, display, animate);
    gNDInSetFrameAnimate = NO;
    if (animate)
        NDReflowAdjacentGaps(self, sel_getUid("_setFrameCommon:display:fromServer:"), YES);
}

static void nd_setFrameDisplay(id self, SEL _cmd, CGRect frame, BOOL display) {
    if (gNDInSetFrame) {
        if (orig_setFrameDisplay)
            orig_setFrameDisplay(self, _cmd, frame, display);
        return;
    }
    NDEnsureSubclassHooked(self);
    set_frame_fn orig = (set_frame_fn)NDSubclassOrigIMP(self, gSubclassSetFrameOrig, (IMP)orig_setFrameDisplay);
    if (!orig) return;
    BOOL reflowAfter = NO;
    if (NDShouldHookWindow(self)) {
        NSScreen *scr = NDWindowScreen(self);
        CGRect visible = scr.visibleFrame;
        if (NDIsNearFull(frame, visible))
            frame = NDCapNearFullOnly(frame, scr);
        else if (NDShouldApplyLayoutMargins(frame, visible)) {
            frame = NDCapPinnedEdgesForWindow(frame, scr, self);
            reflowAfter = YES;
        }
    }
    gNDInSetFrame = YES;
    orig(self, _cmd, frame, display);
    gNDInSetFrame = NO;
    if (reflowAfter)
        NDReflowAdjacentGaps(self, sel_getUid("_setFrameCommon:display:fromServer:"), YES);
}

static CGRect nd_constrainFrameRect(id self, SEL _cmd, CGRect frame, id screen) {
    if (gNDInConstrain) {
        if (orig_constrainFrame) return orig_constrainFrame(self, _cmd, frame, screen);
        return frame;
    }
    constrain_fn orig = (constrain_fn)NDSubclassOrigIMP(self, gSubclassConstrainOrig, (IMP)orig_constrainFrame);
    if (!orig) return frame;

    gNDInConstrain = YES;
    CGRect out = orig(self, _cmd, frame, screen);
    if (NDShouldHookWindow(self)) {
        NSScreen *scr = [(id)screen isKindOfClass:[NSScreen class]] ? (NSScreen *)screen : NDWindowScreen(self);
        if (NDIsNearFull(out, scr.visibleFrame))
            out = NDCapFrame(out, scr, YES);
        else if (NDShouldApplyLayoutMargins(out, scr.visibleFrame))
            out = NDCapPinnedEdgesForWindow(out, scr, self);
    }
    gNDInConstrain = NO;
    return out;
}

static BOOL NDIsNSWindowSubclass(Class cls) {
    if (!cls || cls == gNSWindowClass) return NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == gNSWindowClass) return YES;
    }
    return NO;
}

static BOOL NDShouldHookSubclass(Class cls, Method m, IMP hookIMP) {
    if (!m || !hookIMP) return NO;
    if (method_getImplementation(m) == hookIMP) return NO;
    Method base = class_getInstanceMethod(gNSWindowClass, method_getName(m));
    if (!base) return YES;
    return method_getImplementation(base) != method_getImplementation(m);
}

static void NDHookSubclassMethod(Class cls, SEL sel, IMP hookIMP, NSMutableDictionary *origMap) {
    if (!cls || !hookIMP) return;
    if (!NDIsNSWindowSubclass(cls)) return;

    NSString *key = [NSString stringWithFormat:@"%@:%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    if ([gHookedMethods containsObject:key]) return;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m || !NDShouldHookSubclass(cls, m, hookIMP)) return;

    if (!origMap[NSStringFromClass(cls)])
        origMap[NSStringFromClass(cls)] = [NSValue valueWithPointer:method_getImplementation(m)];

    method_setImplementation(m, hookIMP);
    [gHookedMethods addObject:key];
}

static void NDHookWindowSubclass(Class cls) {
    if (!cls) return;
    NDEnsureHookCollections();

    NDHookSubclassMethod(cls, @selector(setFrame:display:), gSetFrameHookIMP, gSubclassSetFrameOrig);
    NDHookSubclassMethod(cls, sel_getUid("setFrame:display:animate:"), gSetFrameAnimateHookIMP,
                         gSubclassSetFrameAnimateOrig);
    NDHookSubclassMethod(cls, sel_getUid("_zoomToFrame:willChangeScreens:toIPad:zoomState:"),
                         gZoomToFrameHookIMP, gSubclassZoomToFrameOrig);
    NDHookSubclassMethod(cls, @selector(constrainFrameRect:toScreen:), gConstrainHookIMP,
                         gSubclassConstrainOrig);
    NDHookSubclassMethod(cls, sel_getUid("_standardFrame"), gStandardFrameHookIMP,
                         gSubclassStandardFrameOrig);
    NDHookSubclassMethod(cls, sel_getUid("_standardFrameForScreen:isMoveToiPad:"),
                         gStandardFrameForScreenHookIMP, gSubclassStandardFrameForScreenOrig);
    NDHookSubclassMethod(cls, sel_getUid("_setFrameCommon:display:fromServer:"),
                         gSetFrameCommonHookIMP, gSubclassSetFrameCommonOrig);
}

static void NDHookSubclassesFromImage(const char *imagePath) {
    if (!imagePath || !gCopyClassNamesForImage || !gSetFrameHookIMP) return;
    if (!strstr(imagePath, ".app/")) return;

    unsigned int count = 0;
    const char **names = gCopyClassNamesForImage(imagePath, &count);
    if (!names) return;

    for (unsigned int i = 0; i < count; i++) {
        if (strncmp(names[i], "NSKVONotifying_", 15) == 0) continue;
        if (!strstr(names[i], "Window")) continue;
        Class cls = objc_getClass(names[i]);
        if (cls && NDIsNSWindowSubclass(cls))
            NDHookWindowSubclass(cls);
    }
    free(names);
}

static void NDInstallWindowHooks(void) {
    if (!gNDWindowMarginActive) return;
    if (!gNSWindowClass) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gConstrainHookIMP = (IMP)nd_constrainFrameRect;
        gSetFrameHookIMP = (IMP)nd_setFrameDisplay;
        gStandardFrameHookIMP = (IMP)nd_standardFrame;
        gStandardFrameForScreenHookIMP = (IMP)nd_standardFrameForScreen;
        gZoomToFrameHookIMP = (IMP)nd_zoomToFrame;
        gSetFrameAnimateHookIMP = (IMP)nd_setFrameAnimate;
        gSetFrameCommonHookIMP = (IMP)nd_setFrameCommon;
        NDEnsureHookCollections();

        Method m = class_getInstanceMethod(gNSWindowClass, @selector(setFrame:display:));
        if (m) {
            orig_setFrameDisplay = (set_frame_fn)method_getImplementation(m);
            method_setImplementation(m, gSetFrameHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, sel_getUid("setFrame:display:animate:"));
        if (m) {
            orig_setFrameAnimate = (set_frame_animate_fn)method_getImplementation(m);
            method_setImplementation(m, gSetFrameAnimateHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, sel_getUid("_zoomToFrame:willChangeScreens:toIPad:zoomState:"));
        if (m) {
            orig_zoomToFrame = (zoom_to_frame_fn)method_getImplementation(m);
            method_setImplementation(m, gZoomToFrameHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, sel_getUid("_standardFrame"));
        if (m) {
            orig_standardFrame = (std_frame_fn)method_getImplementation(m);
            method_setImplementation(m, gStandardFrameHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, sel_getUid("_standardFrameForScreen:isMoveToiPad:"));
        if (m) {
            orig_standardFrameForScreen = (std_screen_fn)method_getImplementation(m);
            method_setImplementation(m, gStandardFrameForScreenHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, @selector(constrainFrameRect:toScreen:));
        if (m) {
            orig_constrainFrame = (constrain_fn)method_getImplementation(m);
            method_setImplementation(m, gConstrainHookIMP);
        }
        m = class_getInstanceMethod(gNSWindowClass, sel_getUid("_setFrameCommon:display:fromServer:"));
        if (m) {
            orig_setFrameCommon = (set_frame_common_fn)method_getImplementation(m);
            method_setImplementation(m, gSetFrameCommonHookIMP);
        }
        for (int i = 0; kNDKnownWindowClasses[i]; i++) {
            Class known = objc_getClass(kNDKnownWindowClasses[i]);
            if (known) NDHookWindowSubclass(known);
        }
    });
}

static const char *NDImagePathForHeader(const struct mach_header *mh) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (_dyld_get_image_header(i) == mh)
            return _dyld_get_image_name(i);
    }
    return NULL;
}

static void nd_window_on_image(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    if (!gNDWindowMarginActive) return;

    const char *imagePath = NDImagePathForHeader(mh);
    if (!imagePath) return;

    BOOL isApp = strstr(imagePath, ".app/") != NULL;
    BOOL isSwiftUI = !gNDSwiftUIHooked && strstr(imagePath, "SwiftUI.framework") != NULL;
    if (!isApp && !isSwiftUI) return;

    if (!objc_getClass("NSWindow")) return;

    if (isApp)
        NDHookSubclassesFromImage(imagePath);
    if (isSwiftUI) {
        Class swiftWin = objc_getClass("SwiftUI.AppKitWindow");
        if (swiftWin) {
            NDHookWindowSubclass(swiftWin);
            gNDSwiftUIHooked = YES;
        }
    }
}

void NDWindowMarginInit(void) {
    if (NDIsDockProcess()) return;
    if (!NDMarginEnabled()) return;

    gNDWindowMarginActive = YES;
    gNSWindowClass = objc_getClass("NSWindow");
    if (!gNSWindowClass) return;

    if (!gCopyClassNamesForImage)
        gCopyClassNamesForImage = (copy_class_names_fn)dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImage");

    NDInstallWindowHooks();
    _dyld_register_func_for_add_image(nd_window_on_image);
}
