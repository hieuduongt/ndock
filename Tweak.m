#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import <unistd.h>

// 0 = auto theo màn hình. >0 = ghi đè thủ công (pt).
static const CGFloat kNDCustomSpan = 0;
static const CGFloat kNDMinRealSpan = 50.0;

static BOOL NDIsDockProcess(void) {
    const char *p = getprogname();
    return p && strcmp(p, "Dock") == 0;
}

static NSScreen *NDMainScreen(void) {
    return [NSScreen mainScreen];
}

static CGFloat NDMenuBarHeight(NSScreen *screen) {
    if (!screen) return 0;
    return screen.frame.size.height - screen.visibleFrame.size.height - screen.visibleFrame.origin.y;
}

static CGFloat NDAutoHorizontalSpan(NSScreen *screen) {
    return screen ? screen.frame.size.width - 10 : 0;
}

static CGFloat NDAutoVerticalSpan(NSScreen *screen) {
    if (!screen) return 0;
    return screen.visibleFrame.size.height - 10;
}

// Dock dọc: floorFrame hẹp x cao (vd. 57x767). Dock ngang: rộng x thấp (vd. 766x57).
static BOOL NDIsVerticalFloorRect(CGRect rect) {
    return rect.size.height > rect.size.width;
}

static BOOL NDShouldResizeSpan(CGFloat current, CGFloat target) {
    if (current < kNDMinRealSpan || target <= 0) return NO;
    if (fabs(current - target) < 1.0) return NO;
    // Chi resize khi Dock đang layout thanh bar thật (~ vài trăm pt), không đụng rect phụ.
    return current <= target * 1.05;
}

static CGRect NDResizeFloorFrame(CGRect rect) {
    NSScreen *screen = NDMainScreen();
    if (!screen) return rect;

    if (NDIsVerticalFloorRect(rect)) {
        CGFloat custom = kNDCustomSpan > 0 ? kNDCustomSpan : NDAutoVerticalSpan(screen);
        if (!NDShouldResizeSpan(rect.size.height, custom)) return rect;

        CGFloat delta = custom - rect.size.height;
        rect.origin.y -= delta * 0.5;
        rect.size.height = custom;
    } else {
        CGFloat custom = kNDCustomSpan > 0 ? kNDCustomSpan : NDAutoHorizontalSpan(screen);
        if (!NDShouldResizeSpan(rect.size.width, custom)) return rect;

        CGFloat delta = custom - rect.size.width;
        rect.origin.x -= delta * 0.5;
        rect.size.width = custom;
    }
    return rect;
}

typedef void (*set_rect_fn)(id, SEL, CGRect);
static set_rect_fn orig_setFloorFrame = NULL;

static void nd_hook_setFloorFrame(id self, SEL _cmd, CGRect rect) {
    orig_setFloorFrame(self, _cmd, NDResizeFloorFrame(rect));
}

static void NDInstallHooks(void) {
    static BOOL done = NO;
    if (done) return;

    Class bar = NSClassFromString(@"DockBar");
    Method m = bar ? class_getInstanceMethod(bar, sel_getUid("setFloorFrame:")) : NULL;
    if (!m || orig_setFloorFrame) return;

    orig_setFloorFrame = (set_rect_fn)method_getImplementation(m);
    method_setImplementation(m, (IMP)nd_hook_setFloorFrame);
    done = YES;
}

static void nd_on_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    if (NDIsDockProcess()) NDInstallHooks();
}

__attribute__((constructor(0)))
static void nd_init(void) {
    if (!NDIsDockProcess()) return;
    _dyld_register_func_for_add_image(nd_on_image_added);
    NDInstallHooks();
}
