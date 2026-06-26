#import "NDConfig.h"
#import <Foundation/Foundation.h>
#import <string.h>
#import <unistd.h>

static NSString *NDConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/N-Dock/settings.plist"];
}

static CGFloat gNDWindowMargin = NDDefaultMarginPerSide;
static CGFloat gNDDockMargin = NDDefaultMarginPerSide;

static CGFloat NDClampMargin(NSNumber *n, CGFloat fallback) {
    if (!n) return fallback;
    CGFloat v = n.doubleValue;
    if (v < 0) return 0;
    if (v > 100) return 100;
    return v;
}

static void NDEnsureMarginsCached(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NDConfigPath()];
        if (!d) return;
        gNDWindowMargin = NDClampMargin(d[@"windowMarginPerSide"], NDDefaultMarginPerSide);
        gNDDockMargin = NDClampMargin(d[@"dockMarginPerSide"], NDDefaultMarginPerSide);
    });
}

BOOL NDIsDockProcess(void) {
    const char *p = getprogname();
    return p && strcmp(p, "Dock") == 0;
}

CGFloat NDWindowMarginPerSide(void) {
    NDEnsureMarginsCached();
    return gNDWindowMargin;
}

CGFloat NDDockMarginPerSide(void) {
    NDEnsureMarginsCached();
    return gNDDockMargin;
}

CGFloat NDDockMarginTotal(void) {
    return NDDockMarginPerSide() * 2.0;
}
