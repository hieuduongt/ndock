#import <CoreGraphics/CoreGraphics.h>

/// Margin mặc định mỗi cạnh (pt) — window zoom và Dock.
static const CGFloat NDDefaultMarginPerSide = 5.0;

BOOL NDIsDockProcess(void);

CGFloat NDWindowMarginPerSide(void);
CGFloat NDDockMarginPerSide(void);
CGFloat NDDockMarginTotal(void);
