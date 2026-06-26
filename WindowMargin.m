#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import "NDConfig.h"

static const CGFloat kNDNearFullTol = 8.0;

static const void *kNDMarginLockKey = &kNDMarginLockKey;

typedef struct {
    BOOL active;
    CGRect insetFrame;
} NDMarginLock;

typedef void (*set_frame_fn)(id, SEL, CGRect, BOOL);
typedef void (*set_frame_anim_fn)(id, SEL, CGRect, BOOL, BOOL);
typedef void (*zoom_to_frame_fn)(id, SEL, CGRect, BOOL, BOOL, NSInteger);
typedef void (*zoom_to_screen_fn)(id, SEL, id, BOOL);
typedef void (*zoom_fill_fn)(id, SEL, id);
typedef void (*zoom_fn)(id, SEL, id);
typedef void (*gesture_fn)(id, SEL, id);
typedef CGRect (*std_frame_fn)(id, SEL);
typedef CGRect (*std_screen_fn)(id, SEL, id, BOOL);
typedef CGRect (*constrain_fn)(id, SEL, CGRect, id);

static set_frame_fn orig_setFrameDisplay = NULL;
static set_frame_anim_fn orig_setFrameDisplayAnimate = NULL;
static zoom_to_frame_fn orig_zoomToFrame = NULL;
static zoom_to_screen_fn orig_zoomToScreen = NULL;
static zoom_fill_fn orig_zoomFill = NULL;
static zoom_fn orig_zoom = NULL;
static zoom_fn orig_performZoom = NULL;
static gesture_fn orig_doubleTapGesture = NULL;
static std_frame_fn orig_standardFrame = NULL;
static std_screen_fn orig_standardFrameForScreen = NULL;
static constrain_fn orig_constrainFrame = NULL;

static IMP gSetFrameHookIMP = NULL;
static IMP gSetFrameAnimHookIMP = NULL;
static IMP gConstrainHookIMP = NULL;
static IMP gZoomHookIMP = NULL;
static IMP gPerformZoomHookIMP = NULL;

static NSMutableSet<NSString *> *gHookedSetFrameClasses = nil;
static NSMutableSet<NSString *> *gHookedSetFrameAnimClasses = nil;
static NSMutableSet<NSString *> *gHookedConstrainClasses = nil;
static NSMutableSet<NSString *> *gHookedZoomClasses = nil;
static NSMutableSet<NSString *> *gHookedPerformZoomClasses = nil;

static NSMutableDictionary<NSString *, NSValue *> *gSubclassSetFrameOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassSetFrameAnimOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassConstrainOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassZoomOrig = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSubclassPerformZoomOrig = nil;

static __thread BOOL gNDInSetFrame = NO;
static __thread BOOL gNDInConstrain = NO;
static __thread BOOL gNDInZoom = NO;

typedef const char **(*copy_class_names_fn)(const char *, unsigned int *);
static copy_class_names_fn gCopyClassNamesForImage = NULL;

static const char *kNDKnownWindowClasses[] = {
    "Window", "BrowserWindow", "BrowserWKWindow", NULL
};

static BOOL NDIsDockProcess(void) {
    const char *p = getprogname();
    return p && strcmp(p, "Dock") == 0;
}

static NSScreen *NDWindowScreen(id self) {
    NSScreen *screen = [(NSWindow *)self screen];
    return screen ?: NSScreen.mainScreen;
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

static CGRect NDInsetVisibleFrame(CGRect visible, CGFloat margin) {
    return CGRectMake(visible.origin.x + margin,
                      visible.origin.y + margin,
                      visible.size.width - 2.0 * margin,
                      visible.size.height - 2.0 * margin);
}

static NDMarginLock NDGetLock(id self) {
    NSValue *val = objc_getAssociatedObject(self, kNDMarginLockKey);
    NDMarginLock lock = {0};
    if (val) [val getValue:&lock];
    return lock;
}

static void NDSetLock(id self, CGRect insetFrame) {
    NDMarginLock lock = { .active = YES, .insetFrame = insetFrame };
    objc_setAssociatedObject(self, kNDMarginLockKey,
                             [NSValue valueWithBytes:&lock objCType:@encode(NDMarginLock)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void NDClearLock(id self) {
    NDMarginLock lock = NDGetLock(self);
    lock.active = NO;
    objc_setAssociatedObject(self, kNDMarginLockKey,
                             [NSValue valueWithBytes:&lock objCType:@encode(NDMarginLock)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL NDMarginLockActive(id self) {
    return NDGetLock(self).active;
}

static CGRect NDMarginLockedFrame(id self) {
    return NDGetLock(self).insetFrame;
}

static void NDPrepareFillLock(id self) {
    NSScreen *screen = NDWindowScreen(self);
    if (!screen || NDWindowMarginPerSide() <= 0) return;
    NDSetLock(self, NDInsetVisibleFrame(screen.visibleFrame, NDWindowMarginPerSide()));
}

static set_frame_fn NDOrigSetFrameForObject(id self) {
    if (gSubclassSetFrameOrig) {
        NSValue *v = gSubclassSetFrameOrig[NSStringFromClass(object_getClass(self))];
        if (v) return (set_frame_fn)[v pointerValue];
    }
    return orig_setFrameDisplay;
}

static set_frame_anim_fn NDOrigSetFrameAnimForObject(id self) {
    if (gSubclassSetFrameAnimOrig) {
        NSValue *v = gSubclassSetFrameAnimOrig[NSStringFromClass(object_getClass(self))];
        if (v) return (set_frame_anim_fn)[v pointerValue];
    }
    return orig_setFrameDisplayAnimate;
}

static constrain_fn NDOrigConstrainForObject(id self) {
    if (gSubclassConstrainOrig) {
        NSValue *v = gSubclassConstrainOrig[NSStringFromClass(object_getClass(self))];
        if (v) return (constrain_fn)[v pointerValue];
    }
    return orig_constrainFrame;
}

static zoom_fn NDOrigZoomForObject(id self) {
    if (gSubclassZoomOrig) {
        NSValue *v = gSubclassZoomOrig[NSStringFromClass(object_getClass(self))];
        if (v) return (zoom_fn)[v pointerValue];
    }
    return orig_zoom;
}

static zoom_fn NDOrigPerformZoomForObject(id self) {
    if (gSubclassPerformZoomOrig) {
        NSValue *v = gSubclassPerformZoomOrig[NSStringFromClass(object_getClass(self))];
        if (v) return (zoom_fn)[v pointerValue];
    }
    return orig_performZoom;
}

static CGRect NDApplyMarginIntent(id self, CGRect frame) {
    if (NDWindowMarginPerSide() <= 0) return frame;
    NSScreen *screen = NDWindowScreen(self);
    if (!screen) return frame;
    CGRect visible = screen.visibleFrame;
    if (!NDIsNearFull(frame, visible)) return frame;
    CGRect inset = NDInsetVisibleFrame(visible, NDWindowMarginPerSide());
    NDSetLock(self, inset);
    return inset;
}

static CGRect NDAdjustSetFrame(id self, CGRect frame) {
    if (NDWindowMarginPerSide() <= 0) return frame;
    NSScreen *screen = NDWindowScreen(self);
    if (!screen) return frame;

    CGRect visible = screen.visibleFrame;
    CGRect inset = NDInsetVisibleFrame(visible, NDWindowMarginPerSide());

    if (NDMarginLockActive(self)) {
        if (NDIsNearFull(frame, visible))
            return NDMarginLockedFrame(self);
        if (frame.size.width < visible.size.width - 30.0 &&
            frame.size.height < visible.size.height - 30.0)
            NDClearLock(self);
        return frame;
    }

    if (NDIsNearFull(frame, visible)) {
        NDSetLock(self, inset);
        return inset;
    }
    return frame;
}

static CGRect NDAdjustConstrainOutput(id self, CGRect frame, CGRect input, id screen) {
    if (NDWindowMarginPerSide() <= 0) return frame;
    NSScreen *scr = [(id)screen isKindOfClass:[NSScreen class]] ? (NSScreen *)screen : NDWindowScreen(self);
    if (!scr) return frame;
    CGRect visible = scr.visibleFrame;

    if (NDMarginLockActive(self)) {
        if (NDIsNearFull(input, visible) || NDIsNearFull(frame, visible))
            return NDMarginLockedFrame(self);
        return frame;
    }

    if (NDIsNearFull(frame, visible)) {
        CGRect inset = NDInsetVisibleFrame(visible, NDWindowMarginPerSide());
        NDSetLock(self, inset);
        return inset;
    }
    return frame;
}

static BOOL NDIsNSWindowSubclass(Class cls, Class windowClass) {
    if (!cls || !windowClass || cls == windowClass) return NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == windowClass) return YES;
    }
    return NO;
}

static BOOL NDShouldHookSubclass(Class cls, Class windowClass, Method m, IMP hookIMP) {
    if (!m || !hookIMP) return NO;
    if (method_getImplementation(m) == hookIMP) return NO;
    Method base = class_getInstanceMethod(windowClass, method_getName(m));
    if (!base) return YES;
    return method_getImplementation(base) != method_getImplementation(m);
}

static void NDHookSubclassMethod(Class cls, SEL sel, IMP hookIMP,
                                 NSMutableSet *hooked, NSMutableDictionary *origMap) {
    if (!cls || !hookIMP) return;
    Class windowClass = NSClassFromString(@"NSWindow");
    if (!NDIsNSWindowSubclass(cls, windowClass)) return;

    NSString *key = [NSString stringWithFormat:@"%@:%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    if ([hooked containsObject:key]) return;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m || !NDShouldHookSubclass(cls, windowClass, m, hookIMP)) return;

    if (!origMap[NSStringFromClass(cls)])
        origMap[NSStringFromClass(cls)] = [NSValue valueWithPointer:method_getImplementation(m)];

    method_setImplementation(m, hookIMP);
    [hooked addObject:key];
}

static void NDHookWindowSubclass(Class cls) {
    if (!cls) return;
    if (!gHookedSetFrameClasses) gHookedSetFrameClasses = [NSMutableSet set];
    if (!gHookedSetFrameAnimClasses) gHookedSetFrameAnimClasses = [NSMutableSet set];
    if (!gHookedConstrainClasses) gHookedConstrainClasses = [NSMutableSet set];
    if (!gHookedZoomClasses) gHookedZoomClasses = [NSMutableSet set];
    if (!gHookedPerformZoomClasses) gHookedPerformZoomClasses = [NSMutableSet set];
    if (!gSubclassSetFrameOrig) gSubclassSetFrameOrig = [NSMutableDictionary new];
    if (!gSubclassSetFrameAnimOrig) gSubclassSetFrameAnimOrig = [NSMutableDictionary new];
    if (!gSubclassConstrainOrig) gSubclassConstrainOrig = [NSMutableDictionary new];
    if (!gSubclassZoomOrig) gSubclassZoomOrig = [NSMutableDictionary new];
    if (!gSubclassPerformZoomOrig) gSubclassPerformZoomOrig = [NSMutableDictionary new];

    NDHookSubclassMethod(cls, @selector(setFrame:display:), gSetFrameHookIMP,
                         gHookedSetFrameClasses, gSubclassSetFrameOrig);
    NDHookSubclassMethod(cls, sel_getUid("setFrame:display:animate:"), gSetFrameAnimHookIMP,
                         gHookedSetFrameAnimClasses, gSubclassSetFrameAnimOrig);
    NDHookSubclassMethod(cls, @selector(constrainFrameRect:toScreen:), gConstrainHookIMP,
                         gHookedConstrainClasses, gSubclassConstrainOrig);
    NDHookSubclassMethod(cls, @selector(zoom:), gZoomHookIMP,
                         gHookedZoomClasses, gSubclassZoomOrig);
    NDHookSubclassMethod(cls, @selector(performZoom:), gPerformZoomHookIMP,
                         gHookedPerformZoomClasses, gSubclassPerformZoomOrig);
}

static void NDEnsureInstanceClassHooked(id self) {
    Class cls = object_getClass(self);
    Class windowClass = NSClassFromString(@"NSWindow");
    if (!cls || !windowClass || cls == windowClass) return;
    if (!NDIsNSWindowSubclass(cls, windowClass)) return;

    Method m = class_getInstanceMethod(cls, @selector(setFrame:display:));
    if (m && method_getImplementation(m) != gSetFrameHookIMP)
        NDHookWindowSubclass(cls);
}

static void NDEnsureZoomHooked(id self) {
    Class cls = object_getClass(self);
    Method m = class_getInstanceMethod(cls, @selector(zoom:));
    if (m && method_getImplementation(m) != gZoomHookIMP)
        NDHookWindowSubclass(cls);
}

static void nd_setFrameDisplay(id self, SEL _cmd, CGRect frame, BOOL display) {
    NDEnsureInstanceClassHooked(self);
    if (gNDInSetFrame) {
        if (orig_setFrameDisplay) orig_setFrameDisplay(self, _cmd, frame, display);
        return;
    }
    set_frame_fn orig = NDOrigSetFrameForObject(self);
    if (!orig) return;

    gNDInSetFrame = YES;
    frame = NDAdjustSetFrame(self, frame);
    orig(self, _cmd, frame, display);
    gNDInSetFrame = NO;
}

static void nd_setFrameDisplayAnimate(id self, SEL _cmd, CGRect frame, BOOL display, BOOL animate) {
    NDEnsureInstanceClassHooked(self);
    if (gNDInSetFrame) {
        if (orig_setFrameDisplayAnimate)
            orig_setFrameDisplayAnimate(self, _cmd, frame, display, animate);
        return;
    }
    set_frame_anim_fn orig = NDOrigSetFrameAnimForObject(self);
    if (!orig) return;

    if (NDMarginLockActive(self)) {
        NSScreen *screen = NDWindowScreen(self);
        if (screen && NDIsNearFull(frame, screen.visibleFrame))
            frame = NDMarginLockedFrame(self);
    } else {
        frame = NDApplyMarginIntent(self, frame);
    }

    orig(self, _cmd, frame, display, animate);
}

static CGRect nd_constrainFrameRect(id self, SEL _cmd, CGRect frame, id screen) {
    NDEnsureInstanceClassHooked(self);
    if (gNDInConstrain) {
        if (orig_constrainFrame) return orig_constrainFrame(self, _cmd, frame, screen);
        return frame;
    }
    constrain_fn orig = NDOrigConstrainForObject(self);
    if (!orig) return frame;

    gNDInConstrain = YES;
    CGRect input = frame;
    if (NDMarginLockActive(self)) {
        NSScreen *scr = [(id)screen isKindOfClass:[NSScreen class]] ? (NSScreen *)screen : NDWindowScreen(self);
        if (scr && NDIsNearFull(frame, scr.visibleFrame)) {
            gNDInConstrain = NO;
            return NDMarginLockedFrame(self);
        }
    }
    CGRect out = orig(self, _cmd, frame, screen);
    out = NDAdjustConstrainOutput(self, out, input, screen);
    gNDInConstrain = NO;
    return out;
}

static void nd_zoomToFrame(id self, SEL _cmd, CGRect frame, BOOL willChangeScreens,
                           BOOL moveToIPad, NSInteger zoomState) {
    if (!orig_zoomToFrame) return;
    frame = NDApplyMarginIntent(self, frame);
    orig_zoomToFrame(self, _cmd, frame, willChangeScreens, moveToIPad, zoomState);
}

static void nd_zoomToScreen(id self, SEL _cmd, id sender, BOOL moveToIPad) {
    if (!orig_zoomToScreen) return;
    NDPrepareFillLock(self);
    orig_zoomToScreen(self, _cmd, sender, moveToIPad);
}

static void nd_zoomFill(id self, SEL _cmd, id sender) {
    NDPrepareFillLock(self);
    if (orig_zoomToScreen) {
        orig_zoomToScreen(self, sel_getUid("_zoomToScreen:isMoveToiPad:"), sender, NO);
        return;
    }
    if (!orig_zoomFill) return;
    orig_zoomFill(self, _cmd, sender);
}

static void nd_zoom(id self, SEL _cmd, id sender) {
    NDEnsureZoomHooked(self);
    if (gNDInZoom) {
        if (orig_zoom) orig_zoom(self, _cmd, sender);
        return;
    }
    zoom_fn orig = NDOrigZoomForObject(self);
    if (!orig) return;
    gNDInZoom = YES;
    NDPrepareFillLock(self);
    orig(self, _cmd, sender);
    gNDInZoom = NO;
}

static void nd_performZoom(id self, SEL _cmd, id sender) {
    if (gNDInZoom) {
        if (orig_performZoom) orig_performZoom(self, _cmd, sender);
        return;
    }
    zoom_fn orig = NDOrigPerformZoomForObject(self);
    if (!orig) return;
    gNDInZoom = YES;
    NDPrepareFillLock(self);
    orig(self, _cmd, sender);
    gNDInZoom = NO;
}

static void nd_doubleTapGesture(id self, SEL _cmd, id gesture) {
    if (!orig_doubleTapGesture) return;
    id win = [(id)self window];
    if (win && [win isKindOfClass:[NSWindow class]])
        NDPrepareFillLock(win);
    orig_doubleTapGesture(self, _cmd, gesture);
}

static CGRect nd_standardFrame(id self, SEL _cmd) {
    if (NDMarginLockActive(self))
        return NDMarginLockedFrame(self);
    return NDApplyMarginIntent(self, orig_standardFrame(self, _cmd));
}

static CGRect nd_standardFrameForScreen(id self, SEL _cmd, id screen, BOOL moveToIPad) {
    if (NDMarginLockActive(self))
        return NDMarginLockedFrame(self);
    CGRect out = orig_standardFrameForScreen(self, _cmd, screen, moveToIPad);
    if (!screen) return out;
    return NDApplyMarginIntent(self, out);
}

static void NDHookSubclassesFromImage(const char *imagePath) {
    if (!imagePath || !gCopyClassNamesForImage || !gSetFrameHookIMP) return;
    if (!strstr(imagePath, ".app/")) return;

    unsigned int count = 0;
    const char **names = gCopyClassNamesForImage(imagePath, &count);
    if (!names) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (cls) NDHookWindowSubclass(cls);
    }
    free(names);
}

static void NDHookKnownClasses(void) {
    for (int i = 0; kNDKnownWindowClasses[i]; i++) {
        Class cls = objc_getClass(kNDKnownWindowClasses[i]);
        if (cls) NDHookWindowSubclass(cls);
    }
}

static void (*orig_finishLaunching)(id, SEL) = NULL;

static void nd_finishLaunching(id self, SEL _cmd) {
    if (orig_finishLaunching)
        orig_finishLaunching(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{ NDHookKnownClasses(); });
}

static void NDInstallFinishLaunchingHook(void) {
    if (orig_finishLaunching) return;
    Class app = NSClassFromString(@"NSApplication");
    Method m = app ? class_getInstanceMethod(app, @selector(finishLaunching)) : NULL;
    if (!m) return;
    orig_finishLaunching = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)nd_finishLaunching);
}

static void NDInstallThemeFrameHook(void) {
    if (orig_doubleTapGesture) return;
    Class tf = NSClassFromString(@"NSThemeFrame");
    Method m = tf ? class_getInstanceMethod(tf, @selector(handleDoubleTapOrClickGesture:)) : NULL;
    if (!m) return;
    orig_doubleTapGesture = (gesture_fn)method_getImplementation(m);
    method_setImplementation(m, (IMP)nd_doubleTapGesture);
}

static void NDInstallWindowHooks(void) {
    if (NDWindowMarginPerSide() <= 0 || NDIsDockProcess()) return;

    Class cls = objc_getClass("NSWindow");
    if (!cls) return;

    if (!gSetFrameHookIMP) gSetFrameHookIMP = (IMP)nd_setFrameDisplay;
    if (!gSetFrameAnimHookIMP) gSetFrameAnimHookIMP = (IMP)nd_setFrameDisplayAnimate;
    if (!gConstrainHookIMP) gConstrainHookIMP = (IMP)nd_constrainFrameRect;
    if (!gZoomHookIMP) gZoomHookIMP = (IMP)nd_zoom;
    if (!gPerformZoomHookIMP) gPerformZoomHookIMP = (IMP)nd_performZoom;

    Method m = class_getInstanceMethod(cls, @selector(setFrame:display:));
    if (m && !orig_setFrameDisplay) {
        orig_setFrameDisplay = (set_frame_fn)method_getImplementation(m);
        method_setImplementation(m, gSetFrameHookIMP);
    }

    m = class_getInstanceMethod(cls, sel_getUid("setFrame:display:animate:"));
    if (m && !orig_setFrameDisplayAnimate) {
        orig_setFrameDisplayAnimate = (set_frame_anim_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_setFrameDisplayAnimate);
    }

    m = class_getInstanceMethod(cls, sel_getUid("_zoomToFrame:willChangeScreens:toIPad:zoomState:"));
    if (m && !orig_zoomToFrame) {
        orig_zoomToFrame = (zoom_to_frame_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_zoomToFrame);
    }

    m = class_getInstanceMethod(cls, sel_getUid("_zoomToScreen:isMoveToiPad:"));
    if (m && !orig_zoomToScreen) {
        orig_zoomToScreen = (zoom_to_screen_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_zoomToScreen);
    }

    m = class_getInstanceMethod(cls, sel_getUid("_zoomFill:"));
    if (m && !orig_zoomFill) {
        orig_zoomFill = (zoom_fill_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_zoomFill);
    }

    m = class_getInstanceMethod(cls, @selector(zoom:));
    if (m && !orig_zoom) {
        orig_zoom = (zoom_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_zoom);
    }

    m = class_getInstanceMethod(cls, @selector(performZoom:));
    if (m && !orig_performZoom) {
        orig_performZoom = (zoom_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_performZoom);
    }

    m = class_getInstanceMethod(cls, sel_getUid("_standardFrame"));
    if (m && !orig_standardFrame) {
        orig_standardFrame = (std_frame_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_standardFrame);
    }

    m = class_getInstanceMethod(cls, sel_getUid("_standardFrameForScreen:isMoveToiPad:"));
    if (m && !orig_standardFrameForScreen) {
        orig_standardFrameForScreen = (std_screen_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_standardFrameForScreen);
    }

    m = class_getInstanceMethod(cls, @selector(constrainFrameRect:toScreen:));
    if (m && !orig_constrainFrame) {
        orig_constrainFrame = (constrain_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_constrainFrameRect);
    }

    NDInstallFinishLaunchingHook();
    NDInstallThemeFrameHook();
    NDHookKnownClasses();
}

static void nd_window_on_image(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    if (!objc_getClass("NSWindow")) return;

    NDInstallWindowHooks();

    const char *imagePath = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (_dyld_get_image_header(i) == mh) {
            imagePath = _dyld_get_image_name(i);
            break;
        }
    }
    if (imagePath)
        NDHookSubclassesFromImage(imagePath);
}

void NDWindowMarginInit(void) {
    if (NDWindowMarginPerSide() <= 0 || NDIsDockProcess()) return;
    if (!gCopyClassNamesForImage)
        gCopyClassNamesForImage = (copy_class_names_fn)dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImage");
    _dyld_register_func_for_add_image(nd_window_on_image);
    NDInstallWindowHooks();
}
