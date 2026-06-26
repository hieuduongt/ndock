#import "NDConfig.h"
#import <Foundation/Foundation.h>

static NSString *NDConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/N-Dock/settings.plist"];
}

static NSDictionary *NDLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NDConfigPath()];
    if (d) return d;
    return @{
        @"windowMarginPerSide": @5,
        @"dockMarginPerSide": @5,
    };
}

static CGFloat NDClampMargin(NSNumber *n, CGFloat fallback) {
    if (!n) return fallback;
    CGFloat v = n.doubleValue;
    if (v < 0) return 0;
    if (v > 100) return 100;
    return v;
}

CGFloat NDWindowMarginPerSide(void) {
    return NDClampMargin(NDLoadConfig()[@"windowMarginPerSide"], 5.0);
}

CGFloat NDDockMarginPerSide(void) {
    return NDClampMargin(NDLoadConfig()[@"dockMarginPerSide"], 5.0);
}

CGFloat NDDockMarginTotal(void) {
    return NDDockMarginPerSide() * 2.0;
}
