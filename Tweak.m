#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "NDConfig.h"
#import <math.h>

void NDWindowMarginInit(void);

static const CGFloat kNDMinRealSpan = 50.0;

static CGFloat NDAutoHorizontalSpan(NSScreen *screen) {
    if (!screen) return 0;
    return screen.frame.size.width - NDDockMarginTotal();
}

static CGFloat NDAutoVerticalSpan(NSScreen *screen) {
    if (!screen) return 0;
    return screen.visibleFrame.size.height - NDDockMarginTotal();
}

static BOOL NDIsVerticalFloorRect(CGRect rect) {
    return rect.size.height > rect.size.width;
}

static BOOL NDShouldResizeSpan(CGFloat current, CGFloat target) {
    if (current < kNDMinRealSpan || target <= 0) return NO;
    if (fabs(current - target) < 1.0) return NO;
    return current <= target * 1.05;
}

static CGRect NDResizeFloorFrame(CGRect rect) {
    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) return rect;

    if (NDIsVerticalFloorRect(rect)) {
        CGFloat target = NDAutoVerticalSpan(screen);
        if (!NDShouldResizeSpan(rect.size.height, target)) return rect;
        CGFloat delta = target - rect.size.height;
        rect.origin.y -= delta * 0.5;
        rect.size.height = target;
    } else {
        CGFloat target = NDAutoHorizontalSpan(screen);
        if (!NDShouldResizeSpan(rect.size.width, target)) return rect;
        CGFloat delta = target - rect.size.width;
        rect.origin.x -= delta * 0.5;
        rect.size.width = target;
    }
    return rect;
}

typedef void (*set_rect_fn)(id, SEL, CGRect);
static set_rect_fn orig_setFloorFrame = NULL;

static void nd_hook_setFloorFrame(id self, SEL _cmd, CGRect rect) {
    orig_setFloorFrame(self, _cmd, NDResizeFloorFrame(rect));
}

static void NDInstallDockHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class bar = NSClassFromString(@"DockBar");
        Method m = bar ? class_getInstanceMethod(bar, sel_getUid("setFloorFrame:")) : NULL;
        if (!m) return;
        orig_setFloorFrame = (set_rect_fn)method_getImplementation(m);
        method_setImplementation(m, (IMP)nd_hook_setFloorFrame);
    });
}

static void nd_on_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    NDInstallDockHooks();
}

__attribute__((constructor(0)))
static void nd_init(void) {
    NDWindowMarginInit();
    if (!NDIsDockProcess()) return;
    _dyld_register_func_for_add_image(nd_on_image_added);
    NDInstallDockHooks();
}
