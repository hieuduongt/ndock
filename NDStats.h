#import <QuartzCore/QuartzCore.h>

void NDStatsBindLayers(CATextLayer *disk, CATextLayer *ram, CATextLayer *chip,
                       CATextLayer *netUp, CATextLayer *netDown);
void NDStatsStart(void);
void NDStatsTick(void);
/// Dock dọc: chuỗi 2 dòng (nhãn + giá trị) vừa band hẹp.
void NDStatsSetVerticalCompact(BOOL compact);
