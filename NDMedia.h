#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSUInteger, NDMediaAction) {
    NDMediaActionPrevious,
    NDMediaActionTogglePlayPause,
    NDMediaActionNext,
};

void NDMediaBindLayers(CALayer *artwork, CALayer *titleClip, CATextLayer *title,
                       CALayer *artistClip, CATextLayer *artist,
                       CATextLayer *prev, CATextLayer *play, CATextLayer *next);
void NDMediaRefreshTextColors(void);
void NDMediaStart(void);
void NDMediaRelayout(void);
void NDMediaUpdateMarquee(CGRect titleClip, CGRect artistClip, BOOL compact);
void NDMediaSetControlHitRects(CGRect prev, CGRect play, CGRect next);
/// Re-apply horizontal control button styling after NDSetText (Tweak.m).
void NDRelayoutMediaHorizControls(void);
BOOL NDMediaHandleShellClick(CGPoint shellPoint);
BOOL NDMediaHandleScreenClick(CGPoint cocoaScreenPt);
BOOL NDMediaPerformAction(NDMediaAction action);
