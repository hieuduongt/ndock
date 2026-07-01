#import <QuartzCore/QuartzCore.h>

void NDMediaBindLayers(CALayer *artwork, CALayer *titleClip, CATextLayer *title,
                       CALayer *artistClip, CATextLayer *artist,
                       CATextLayer *prev, CATextLayer *play, CATextLayer *next);
void NDMediaStart(void);
void NDMediaRelayout(void);
void NDMediaUpdateMarquee(CGRect titleClip, CGRect artistClip, BOOL compact);
