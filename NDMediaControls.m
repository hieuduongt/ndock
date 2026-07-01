#import "NDMediaControls.h"
#import <objc/runtime.h>

extern void NDNoteMediaControlActivated(void);
extern CALayer *gNDMediaProbeIcon;

static const CGFloat kNDMediaBtnSlop = 6.0;

static CALayer *gHostLayer = NULL;
static CGRect gShellScreenRect = {0};
static BOOL gShellScreenValid = NO;
static BOOL gEventHooksInstalled = NO;
static CFMachPortRef gEventTap = NULL;

typedef void (*nd_click_fn)(id, SEL, id, NSInteger);
static nd_click_fn gOrigHandleClick = NULL;
static nd_click_fn gOrigHandleTileClick = NULL;

#pragma mark - Screen mapping (Dock không có NSWindow — map qua gNDFloorFrame)

static CGRect NDShellScreenRectFromFloor(CGRect shellHost, CGRect floorHost, CGRect floorScreen) {
    if (CGRectIsEmpty(shellHost) || CGRectIsEmpty(floorHost) || CGRectIsEmpty(floorScreen))
        return CGRectZero;
    CGFloat sx = CGRectGetWidth(floorHost) > 1.0
        ? CGRectGetWidth(floorScreen) / CGRectGetWidth(floorHost) : 1.0;
    CGFloat sy = CGRectGetHeight(floorHost) > 1.0
        ? CGRectGetHeight(floorScreen) / CGRectGetHeight(floorHost) : 1.0;
    if (sx < 0.02 || sx > 50.0 || sy < 0.02 || sy > 50.0)
        return CGRectZero;
    CGFloat x = floorScreen.origin.x + (shellHost.origin.x - floorHost.origin.x) * sx;
    CGFloat y = floorScreen.origin.y + (shellHost.origin.y - floorHost.origin.y) * sy;
    CGRect screen = CGRectMake(x, y, shellHost.size.width * sx, shellHost.size.height * sy);
    NSScreen *main = NSScreen.mainScreen;
    if (main) {
        CGFloat maxY = CGRectGetMaxY(main.frame) + 64.0;
        if (y < -64.0 || y > maxY || x < -256.0 || x > main.frame.size.width + 256.0)
            return CGRectZero;
    }
    return screen;
}

static CGPoint NDCocoaFromCG(CGPoint cg) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return cg;
    CGRect f = screen.frame;
    return CGPointMake(cg.x, CGRectGetMaxY(f) - cg.y);
}

static CGPoint NDCocoaPointInShell(CGPoint cocoa, CGRect shellScreen) {
    return CGPointMake(cocoa.x - CGRectGetMinX(shellScreen),
                       cocoa.y - CGRectGetMinY(shellScreen));
}

static BOOL NDMediaControlsTryCocoaPoint(CGPoint cocoa, const char *via) {
    (void)via;
    if (!gShellScreenValid || !gNDMediaProbeIcon || gNDMediaProbeIcon.hidden)
        return NO;

    CGRect hit = CGRectInset(gShellScreenRect, -kNDMediaBtnSlop, -kNDMediaBtnSlop);
    if (!CGRectContainsPoint(hit, cocoa))
        return NO;

    CGPoint shellPt = NDCocoaPointInShell(cocoa, gShellScreenRect);
    NDMediaHandleShellClick(shellPt);
    NDNoteMediaControlActivated();
    return YES;
}

static BOOL NDMediaControlsTryEvent(id event, const char *via) {
    NSPoint ml = [NSEvent mouseLocation];
    return NDMediaControlsTryCocoaPoint(CGPointMake(ml.x, ml.y), via);
}

#pragma mark - DockBar click hooks

static void nd_handleClickEvent(id self, SEL _cmd, id event, NSInteger type) {
    if (NDMediaControlsTryEvent(event, "DockBar._handleClickEvent"))
        return;
    if (gOrigHandleClick) gOrigHandleClick(self, _cmd, event, type);
}

static void nd_handleTileClickEvent(id self, SEL _cmd, id event, NSInteger type) {
    if (NDMediaControlsTryEvent(event, "DockBar._handleTileClickEvent"))
        return;
    if (gOrigHandleTileClick) gOrigHandleTileClick(self, _cmd, event, type);
}

static BOOL NDInstallClickHook(Class cls, const char *sel, IMP imp, nd_click_fn *orig) {
    Method m = class_getInstanceMethod(cls, sel_getUid(sel));
    if (!m) return NO;
    *orig = (nd_click_fn)method_getImplementation(m);
    method_setImplementation(m, imp);
    return YES;
}

static void NDMediaControlsInstallEventHooks(id dockBar) {
    if (gEventHooksInstalled) return;

    Class bar = NSClassFromString(@"DockBar");
    if (!bar && dockBar) bar = object_getClass(dockBar);

    int n = 0;
    if (bar) {
        if (NDInstallClickHook(bar, "_handleClickEvent:type:", (IMP)nd_handleClickEvent, &gOrigHandleClick))
            n++;
        if (NDInstallClickHook(bar, "_handleTileClickEvent:type:", (IMP)nd_handleTileClickEvent, &gOrigHandleTileClick))
            n++;
    }

    Class handler = NSClassFromString(@"DockBarMouseEventHandler");
    if (handler) {
        if (NDInstallClickHook(handler, "_handleClickEvent:type:", (IMP)nd_handleClickEvent, &gOrigHandleClick))
            n++;
        if (NDInstallClickHook(handler, "_handleTileClickEvent:type:", (IMP)nd_handleTileClickEvent, &gOrigHandleTileClick))
            n++;
    }

    if (n > 0)
        gEventHooksInstalled = YES;
}

#pragma mark - CGEventTap backup

static CGEventRef NDMediaEventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                          CGEventRef event, void *userInfo) {
    (void)proxy;
    (void)userInfo;
    if (type != kCGEventLeftMouseDown)
        return event;
    if (gEventHooksInstalled)
        return event;
    if (!gShellScreenValid || !gNDMediaProbeIcon || gNDMediaProbeIcon.hidden)
        return event;

    CGPoint cocoa = NDCocoaFromCG(CGEventGetLocation(event));
    if (NDMediaControlsTryCocoaPoint(cocoa, "CGEventTap"))
        return NULL;
    return event;
}

static void NDInstallCGEventTap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
        gEventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault, mask,
                                     NDMediaEventTapCallback, NULL);
        if (!gEventTap)
            return;
        CFRunLoopSourceRef src =
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        CFRelease(src);
        CGEventTapEnable(gEventTap, true);
    });
}

#pragma mark - API

void NDMediaControlsInstall(id dockBar) {
    NDMediaControlsInstallEventHooks(dockBar);
    NDInstallCGEventTap();
}

void NDMediaControlsHide(void) {
    gShellScreenValid = NO;
}

void NDMediaControlsSync(id dockBar, CALayer *hostLayer, CALayer *shell,
                         CATextLayer *prev, CATextLayer *play, CATextLayer *next,
                         BOOL visible, CGRect floorScreen, CGRect floorInHost,
                         BOOL floorScreenValid) {
    (void)prev;
    (void)play;
    (void)next;
    gHostLayer = hostLayer;

    if (!visible || !shell || shell.hidden) {
        NDMediaControlsHide();
        return;
    }

    NDMediaControlsInstallEventHooks(dockBar);
    NDInstallCGEventTap();

    if (floorScreenValid && !CGRectIsEmpty(floorInHost)) {
        CGRect screen = NDShellScreenRectFromFloor(shell.frame, floorInHost, floorScreen);
        if (!CGRectIsEmpty(screen) && screen.size.width > 4 && screen.size.height > 4) {
            gShellScreenRect = screen;
            gShellScreenValid = YES;
            NDMediaSetControlHitRects(
                CGRectMake(screen.origin.x + prev.frame.origin.x,
                           screen.origin.y + prev.frame.origin.y,
                           prev.frame.size.width, prev.frame.size.height),
                CGRectMake(screen.origin.x + play.frame.origin.x,
                           screen.origin.y + play.frame.origin.y,
                           play.frame.size.width, play.frame.size.height),
                CGRectMake(screen.origin.x + next.frame.origin.x,
                           screen.origin.y + next.frame.origin.y,
                           next.frame.size.width, next.frame.size.height));
            return;
        }
    }

    gShellScreenValid = NO;
}

NSRect NDMediaShellRectInView(CALayer *shell, CALayer *hostLayer, NSView *view) {
    (void)shell;
    (void)hostLayer;
    (void)view;
    return NSZeroRect;
}

NSPoint NDMediaShellPointFromMouse(NSPoint locInView, NSRect shellRect, BOOL viewFlipped) {
    (void)viewFlipped;
    return NSMakePoint(locInView.x - shellRect.origin.x, locInView.y - shellRect.origin.y);
}
