#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import "NDMedia.h"

void NDMediaControlsInstall(id dockBar);
void NDMediaControlsSync(id dockBar, CALayer *hostLayer, CALayer *shell,
                         CATextLayer *prev, CATextLayer *play, CATextLayer *next,
                         BOOL visible, CGRect floorScreen, CGRect floorInHost,
                         BOOL floorScreenValid);
void NDMediaControlsHide(void);

NSRect NDMediaShellRectInView(CALayer *shell, CALayer *hostLayer, NSView *view);
NSPoint NDMediaShellPointFromMouse(NSPoint locInView, NSRect shellRect, BOOL viewFlipped);
