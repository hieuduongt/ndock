#import <QuartzCore/QuartzCore.h>

void NDStatsBindLayers(CATextLayer *disk, CATextLayer *ram, CATextLayer *chip,
                       CATextLayer *netUp, CATextLayer *netDown);
void NDStatsStart(void);
void NDStatsTick(void);
