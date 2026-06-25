#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import <unistd.h>

// 0 = full chiều rộng màn hình. >0 = ghi đè thủ công (pt).
static const CGFloat kNDCustomBarWidth = 0;
static const CGFloat kNDMinRealBarWidth = 100.0;

static BOOL NDIsDockProcess(void) {
    const char *p = getprogname();
    return p && strcmp(p, "Dock") == 0;
}

static CGFloat NDEffectiveCustomWidth(void) {
    if (kNDCustomBarWidth > 0) return kNDCustomBarWidth;
    NSScreen *s = [NSScreen mainScreen];
    return s ? s.frame.size.width - 10 : 0;
}

static BOOL NDIsBarWidth(CGFloat w) {
    if (w < kNDMinRealBarWidth) return NO;
    CGFloat maxW = NDEffectiveCustomWidth();
    return maxW <= 0 || w <= maxW * 1.05;
}

static CGRect NDResizeWidth(CGRect rect) {
    CGFloat custom = NDEffectiveCustomWidth();
    if (custom <= 0 || !NDIsBarWidth(rect.size.width)) return rect;
    if (fabs(rect.size.width - custom) < 1.0) return rect;

    CGFloat delta = custom - rect.size.width;
    rect.origin.x -= delta * 0.5;
    rect.size.width = custom;
    return rect;
}

typedef void (*set_rect_fn)(id, SEL, CGRect);
static set_rect_fn orig_setFloorFrame = NULL;

static void nd_hook_setFloorFrame(id self, SEL _cmd, CGRect rect) {
    orig_setFloorFrame(self, _cmd, NDResizeWidth(rect));
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
