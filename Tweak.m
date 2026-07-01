#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import "NDConfig.h"
#import "NDStats.h"
#import <math.h>
#import <stdio.h>
#import <stdarg.h>

void NDWindowMarginInit(void);

static const CGFloat kNDMinRealSpan = 50.0;
static const CGFloat kNDMaxFloorBandPt = 120.0;
/// Lề widget so với mép trên/dưới floor (pt). Chiều cao = floorH - 2×lề.
static const CGFloat kNDWidgetInsetPt = 7.0;
static const CGFloat kNDWidgetIconGapPt = 4.0;
static const CGFloat kNDWidgetTextPadPt = 8.0;
static const CGFloat kNDWidgetLineH = 11.0;
static const CGFloat kNDWidgetFontSize = 9.5;
static const CGFloat kNDWidgetMinHeightPt = 36.0;
static const CGFloat kNDWidgetBgAlpha = 0.58;
static const CGFloat kNDLeftWidgetWidthPt = 198.0;
static const CGFloat kNDRightWidgetWidthPt = 132.0;
/// Probe trái: rộng tối thiểu ~3× tile thiết kế (198pt @ icon ~43pt), scale theo icon khi resize.
static const CGFloat kNDLeftProbeWidthMul = 3.0;
static const CGFloat kNDRefIconSizePt = 43.0;

typedef void (*set_rect_fn)(id, SEL, CGRect);
typedef void (*void_fn)(id, SEL);

static set_rect_fn orig_setFloorFrame = NULL;
static set_rect_fn orig_setFLastBarRect = NULL;
static void_fn orig_floorLayout = NULL;

static CGRect gNDFloorFrame = {0};
static BOOL gNDFloorFrameValid = NO;
static id gNDDockBar = nil;
static CALayer *gNDFloorLayerRef = NULL;
static CALayer *gNDLeftShell = NULL;
static CALayer *gNDRightShell = NULL;
static CALayer *gNDProbeIcon = NULL;
static CALayer *gNDRightProbeIcon = NULL;
static CALayer *gNDProbeBgLayer = NULL;
static CALayer *gNDRightProbeBgLayer = NULL;
static BOOL gNDWidgetsAttached = NO;
static BOOL gNDWidgetLayoutPending = NO;
static CATextLayer *gNDDiskLayer = NULL;
static CATextLayer *gNDRamLayer = NULL;
static CATextLayer *gNDChipLayer = NULL;
static CATextLayer *gNDNetUpLayer = NULL;
static CATextLayer *gNDNetDownLayer = NULL;
static BOOL gNDInWidgetLayout = NO;
static BOOL gNDVerifyLogged = NO;
static uint64_t gNDRelayoutNonce = 0;

static BOOL NDIsVerticalFloorRect(CGRect rect) {
    return rect.size.height > rect.size.width;
}

static BOOL NDIsMainFloorLayer(CALayer *floor) {
    if (!floor || !gNDFloorFrameValid) return NO;
    CGFloat w = floor.bounds.size.width;
    CGFloat h = floor.bounds.size.height;
    if (w < kNDMinRealSpan && h < kNDMinRealSpan) return NO;

    if (NDIsVerticalFloorRect(gNDFloorFrame)) {
        if (h < kNDMinRealSpan || w < kNDWidgetMinHeightPt) return NO;
        if (w > kNDMaxFloorBandPt || w > h * 1.2) return NO;
        if (fabs(h - gNDFloorFrame.size.height) > 40.0) return NO;
        if (h < gNDFloorFrame.size.height * 0.85) return NO;
        return YES;
    }

    if (w < kNDMinRealSpan || h < kNDWidgetMinHeightPt) return NO;
    if (h > kNDMaxFloorBandPt || h > w * 1.2) return NO;
    if (fabs(w - gNDFloorFrame.size.width) > 40.0) return NO;
    if (w < gNDFloorFrame.size.width * 0.85) return NO;
    return YES;
}

static BOOL NDFloorLayerUsable(CALayer *floor) {
    if (!floor || !gNDFloorFrameValid) return NO;
    if (!floor.superlayer) return NO;
    return NDIsMainFloorLayer(floor);
}

static NSInteger NDBarOrientation(id dockBar) {
    if (dockBar && [dockBar respondsToSelector:sel_getUid("barOrientation")])
        return ((NSInteger (*)(id, SEL))objc_msgSend)(dockBar, sel_getUid("barOrientation"));
    return 2; // bottom
}

static BOOL NDIsHorizontalDock(id dockBar) {
    NSInteger o = NDBarOrientation(dockBar);
    return o == 2 || o == 0;
}

static BOOL NDDebugEnabled(void) {
    const char *e = getenv("NDOCK_DEBUG");
    return e && e[0] != '\0' && e[0] != '0';
}

static void NDLogAlways(const char *fmt, ...) {
    if (!NDDebugEnabled()) return;
    FILE *f = fopen("/tmp/ndock_debug.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static CGFloat NDWidgetCornerRadius(CGFloat widgetH);
static void NDLayoutTextRows(CALayer *shell, CATextLayer *const *rows, int count);
static CGRect NDFloorRectForWidgets(CALayer *floor, CALayer *host);

static CGFloat NDLeftProbeWidth(CGFloat iconW, CGFloat iconH) {
    CGFloat scale = (iconH > 1.0) ? (iconH / kNDRefIconSizePt) : 1.0;
    if (scale < 0.55) scale = 0.55;
    if (scale > 2.5) scale = 2.5;
    CGFloat designW = kNDLeftWidgetWidthPt * scale;
    CGFloat mulW = iconW * kNDLeftProbeWidthMul;
    return MAX(designW, mulW);
}

/// Visual icon (Bezel item) trong host; fallback = tile.frame.
static CGRect NDTileVisualRectInHost(CALayer *tile, CALayer *host) {
    if (!tile || !host) return CGRectZero;
    CGRect visual = CGRectZero;
    BOOL have = NO;
    for (CALayer *sub in tile.sublayers) {
        const char *cn = object_getClassName(sub);
        if (strstr(cn, "Label") || strstr(cn, "Selection") || strstr(cn, "Badge"))
            continue;
        CGRect r = [tile convertRect:sub.bounds toLayer:host];
        if (r.size.width < 4.0 || r.size.height < 4.0) continue;
        if (!have) { visual = r; have = YES; }
        else visual = CGRectUnion(visual, r);
    }
    return have ? visual : tile.frame;
}

/// Widget ngang: X từ floor+inset; Y/H = tile.frame (cùng slot layout với icon gốc).
static CGRect NDHorizontalWidgetFrame(CALayer *floor, CALayer *host, CGRect floorInHost,
                                      CALayer *tile, CGFloat x, CGFloat w) {
    (void)floor;
    (void)host;
    (void)floorInHost;
    CGRect tf = tile ? tile.frame : CGRectZero;
    CGFloat h = MAX(8.0, tf.size.height);
    return CGRectMake(x, tf.origin.y, w, h);
}

static CALayer *NDLeftmostValidTile(CALayer *host) {
    if (!host) return NULL;
    CALayer *best = NULL;
    CGFloat bestX = CGFLOAT_MAX;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon
            || s == gNDLeftShell || s == gNDRightShell) continue;
        if (strcmp(object_getClassName(s), "DOCKTileLayer")) continue;
        CGRect f = s.frame;
        if (f.size.width < 8.0 || f.size.height < 8.0) continue;
        if (f.size.height > 256.0 || f.size.width > 256.0) continue;
        if (CGRectGetMinX(f) < bestX) {
            bestX = CGRectGetMinX(f);
            best = s;
        }
    }
    return best;
}

/// Bề ngang cụm icon (cho overlap), không dùng cho Y/H.
static BOOL NDIconClusterX(CALayer *host, CGFloat *outMinX, CGFloat *outMaxX) {
    if (!host) return NO;
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX;
    int n = 0;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon
            || s == gNDLeftShell || s == gNDRightShell) continue;
        if (strcmp(object_getClassName(s), "DOCKTileLayer")) continue;
        CGRect f = s.frame;
        if (f.size.width < 8.0 || f.size.height < 8.0) continue;
        if (CGRectGetMinX(f) < minX) minX = CGRectGetMinX(f);
        if (CGRectGetMaxX(f) > maxX) maxX = CGRectGetMaxX(f);
        n++;
    }
    if (n == 0) return NO;
    if (outMinX) *outMinX = minX;
    if (outMaxX) *outMaxX = maxX;
    return YES;
}

/// Liquid glass: nền trong + viền sáng + blur phía sau (CALayer, không private API).
static void NDApplyLiquidGlass(CALayer *layer) {
    if (!layer) return;
    layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.16] CGColor];
    layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.42] CGColor];
    layer.borderWidth = 0.5;
    layer.shadowOpacity = 0.0;
    if (layer.backgroundFilters.count > 0) return;
    @try {
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        if (blur) {
            [blur setValue:@(14.0) forKey:kCIInputRadiusKey];
            layer.backgroundFilters = @[blur];
        }
    } @catch (__unused NSException *e) {}
}

static BOOL NDIsGlassWidgetBg(CALayer *sub) {
    return sub == gNDProbeBgLayer || sub == gNDRightProbeBgLayer;
}

static void NDEnsureGlassWidgetHost(CALayer *shell, CALayer *host, CALayer *floor, CGFloat zBump) {
    if (!shell || !host || !floor) return;
    CGFloat maxZ = floor.zPosition;
    for (CALayer *sub in host.sublayers) {
        if (sub == shell) continue;
        if (sub.zPosition > maxZ) maxZ = sub.zPosition;
    }
    if (shell.superlayer != host) {
        [shell removeFromSuperlayer];
        [host insertSublayer:shell above:floor];
    }
    shell.zPosition = maxZ + zBump;
    shell.geometryFlipped = NO;
}

static void NDEnsureProbeIcon(CALayer *host, CALayer *floor) {
    if (!host || !floor) return;
    if (!gNDProbeIcon) {
        gNDProbeIcon = [CALayer layer];
        gNDProbeIcon.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        gNDProbeIcon.backgroundColor = [[NSColor clearColor] CGColor];
    }
    NDEnsureGlassWidgetHost(gNDProbeIcon, host, floor, 550.0);
}

static void NDEnsureRightProbeIcon(CALayer *host, CALayer *floor) {
    if (!host || !floor) return;
    if (!gNDRightProbeIcon) {
        gNDRightProbeIcon = [CALayer layer];
        gNDRightProbeIcon.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        gNDRightProbeIcon.backgroundColor = [[NSColor clearColor] CGColor];
    }
    NDEnsureGlassWidgetHost(gNDRightProbeIcon, host, floor, 551.0);
}

static CALayer *NDEnsureGlassBgLayer(CALayer *shell, CALayer *bg) {
    if (!shell) return bg;
    if (!bg) {
        bg = [CALayer layer];
        bg.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        NDApplyLiquidGlass(bg);
        [shell insertSublayer:bg atIndex:0];
        return bg;
    }
    if (bg.superlayer != shell) {
        [bg removeFromSuperlayer];
        [shell insertSublayer:bg atIndex:0];
    }
    return bg;
}

/// Bám frame tile → nền glass inset theo icon visual + text stats.
static void NDSyncGlassWidget(CALayer *shell, CALayer *bg, CALayer *src, CGRect frame,
                              CATextLayer *const *rows, int rowCount) {
    if (!shell || !src || !bg || rowCount <= 0) return;
    CALayer *host = src.superlayer;
    CGRect vf = NDTileVisualRectInHost(src, host);
    CGRect tf = src.frame;
    CGFloat topIn = MAX(0.0, vf.origin.y - tf.origin.y);
    CGFloat botIn = MAX(0.0, CGRectGetMaxY(tf) - CGRectGetMaxY(vf));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shell.geometryFlipped = NO;
    shell.contents = nil;
    shell.backgroundColor = [[NSColor clearColor] CGColor];
    shell.borderWidth = 0.0;
    for (CALayer *sub in [shell.sublayers copy]) {
        if (NDIsGlassWidgetBg(sub)) continue;
        BOOL keep = NO;
        for (int i = 0; i < rowCount; i++) {
            if (sub == rows[i]) { keep = YES; break; }
        }
        if (!keep) [sub removeFromSuperlayer];
    }
    shell.frame = frame;
    shell.masksToBounds = NO;
    shell.cornerRadius = 0.0;
    shell.opacity = 1.0f;

    CGFloat bgH = MAX(8.0, frame.size.height - topIn - botIn);
    bg.frame = CGRectMake(0.0, topIn, frame.size.width, bgH);
    bg.masksToBounds = YES;
    bg.cornerRadius = (src.cornerRadius > 0.5) ? src.cornerRadius : bgH * 0.22;
    if (bg.superlayer != shell)
        [shell insertSublayer:bg atIndex:0];
    NDApplyLiquidGlass(bg);

    for (int i = 0; i < rowCount; i++) {
        CATextLayer *row = rows[i];
        if (!row) continue;
        if (row.superlayer != shell) [shell addSublayer:row];
        row.hidden = NO;
        row.opacity = 1.0f;
        row.zPosition = 2.0;
        row.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    }
    bg.zPosition = 0.0;
    [CATransaction commit];
    NDLayoutTextRows(shell, rows, rowCount);
}

static void NDSyncProbeIcon(CALayer *src, CGRect frame) {
    if (!gNDProbeIcon || !src) return;
    gNDProbeBgLayer = NDEnsureGlassBgLayer(gNDProbeIcon, gNDProbeBgLayer);
    CATextLayer *rows[] = { gNDDiskLayer, gNDRamLayer, gNDChipLayer };
    NDSyncGlassWidget(gNDProbeIcon, gNDProbeBgLayer, src, frame, rows, 3);
}

static void NDSyncRightGlassWidget(CALayer *src, CGRect frame) {
    if (!gNDRightProbeIcon || !src) return;
    gNDRightProbeBgLayer = NDEnsureGlassBgLayer(gNDRightProbeIcon, gNDRightProbeBgLayer);
    CATextLayer *rows[] = { gNDNetUpLayer, gNDNetDownLayer };
    NDSyncGlassWidget(gNDRightProbeIcon, gNDRightProbeBgLayer, src, frame, rows, 2);
}

/// Gắn lại nền widget + text stats (dock dọc).
static void NDRestoreWidgetContent(CALayer *shell, BOOL isLeft) {
    if (!shell) return;
    shell.backgroundColor = [[NSColor colorWithWhite:0.10 alpha:kNDWidgetBgAlpha] CGColor];
    shell.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.28] CGColor];
    shell.borderWidth = 1.0;
    shell.masksToBounds = YES;
    shell.opacity = 1.0f;
    shell.contents = nil;
    if (isLeft) {
        if (gNDDiskLayer.superlayer != shell) [shell addSublayer:gNDDiskLayer];
        if (gNDRamLayer.superlayer != shell) [shell addSublayer:gNDRamLayer];
        if (gNDChipLayer.superlayer != shell) [shell addSublayer:gNDChipLayer];
    } else {
        if (gNDNetUpLayer.superlayer != shell) [shell addSublayer:gNDNetUpLayer];
        if (gNDNetDownLayer.superlayer != shell) [shell addSublayer:gNDNetDownLayer];
    }
}

static CGFloat NDAutoHorizontalSpan(NSScreen *screen) {
    if (!screen) return 0;
    return screen.frame.size.width - NDDockMarginTotal();
}

static CGFloat NDAutoVerticalSpan(NSScreen *screen) {
    if (!screen) return 0;
    return screen.visibleFrame.size.height - NDDockMarginTotal();
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

static CGFloat NDDoubleFromDockBar(id dockBar, const char *key) {
    SEL sel = sel_getUid(key);
    if ([dockBar respondsToSelector:sel])
        return ((CGFloat(*)(id, SEL))objc_msgSend)(dockBar, sel);
    @try {
        id v = [dockBar valueForKey:[NSString stringWithUTF8String:key]];
        if (v) return [v doubleValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static CGRect NDRectFromDockBar(id dockBar, const char *key) {
    SEL sel = sel_getUid(key);
    if ([dockBar respondsToSelector:sel])
        return ((CGRect(*)(id, SEL))objc_msgSend)(dockBar, sel);
    @try {
        NSValue *v = [dockBar valueForKey:[NSString stringWithUTF8String:key]];
        if ([v isKindOfClass:[NSValue class]]) return [v rectValue];
    } @catch (__unused NSException *e) {}
    return CGRectZero;
}

static BOOL NDRectsOverlapY(CGRect a, CGRect b, CGFloat gap) {
    if (CGRectIsEmpty(a) || CGRectIsEmpty(b)) return NO;
    return !(CGRectGetMaxY(a) + gap <= CGRectGetMinY(b)
          || CGRectGetMaxY(b) + gap <= CGRectGetMinY(a));
}

static CGRect NDIconBarLocalRect(id dockBar, CGFloat floorW, CGFloat floorH, BOOL horizontal) {
    if (!gNDFloorFrameValid) return CGRectZero;

    if (horizontal) {
        CGFloat barL = NDDoubleFromDockBar(dockBar, "barLeft");
        CGFloat barR = NDDoubleFromDockBar(dockBar, "barRight");
        if (barR > barL + 8.0) {
            return CGRectMake(barL - gNDFloorFrame.origin.x, 0,
                              barR - barL, floorH);
        }
        CGRect cluster = NDRectFromDockBar(dockBar, "fLastBarRect");
        if (cluster.size.width > 8.0) {
            return CGRectMake(cluster.origin.x - gNDFloorFrame.origin.x, 0,
                              cluster.size.width, floorH);
        }
        return CGRectZero;
    }

    CGFloat barB = NDDoubleFromDockBar(dockBar, "barBottom");
    CGFloat barT = NDDoubleFromDockBar(dockBar, "barTop");
    if (barT > barB + 8.0) {
        return CGRectMake(0, barB - gNDFloorFrame.origin.y,
                          floorW, barT - barB);
    }
    CGRect cluster = NDRectFromDockBar(dockBar, "fLastBarRect");
    if (cluster.size.height > 8.0) {
        return CGRectMake(0, cluster.origin.y - gNDFloorFrame.origin.y,
                        floorW, cluster.size.height);
    }
    return CGRectZero;
}

static void NDFloorLayoutSize(CALayer *floor, CGFloat *outW, CGFloat *outH) {
    if (!floor) return;
    if (outW) *outW = floor.bounds.size.width;
    if (outH) *outH = floor.bounds.size.height;
}

/// Lề đều 5pt mọi cạnh của floor (trong host coords).
static void NDWidgetInsets(CGFloat *outTop, CGFloat *outBottom, CGFloat *outX) {
    if (outTop) *outTop = kNDWidgetInsetPt;
    if (outBottom) *outBottom = kNDWidgetInsetPt;
    if (outX) *outX = kNDWidgetInsetPt;
}

/// Widget lấp đầy band trừ lề trên/dưới 5pt → lề trên = lề dưới. Text tự căn giữa.
static CGFloat NDWidgetShellHeight(CGFloat bandSpan) {
    CGFloat insetTop = 0.0, insetBottom = 0.0;
    NDWidgetInsets(&insetTop, &insetBottom, NULL);
    return MAX(8.0, bandSpan - insetTop - insetBottom);
}

static CGFloat NDWidgetLocalY(CALayer *floor, CGFloat bandSpan, CGFloat widgetH) {
    CGFloat insetTop = 0.0, insetBottom = 0.0;
    NDWidgetInsets(&insetTop, &insetBottom, NULL);
    if (floor.geometryFlipped)
        return insetTop;
    return bandSpan - insetBottom - widgetH;
}

static BOOL NDFloorShapeMatchesDock(BOOL dockHorizontal, CGFloat floorW, CGFloat floorH) {
    BOOL floorVertical = floorH > floorW * 1.12;
    return dockHorizontal ? !floorVertical : floorVertical;
}

static BOOL NDBandSpanReasonable(BOOL horizontal, CGFloat floorW, CGFloat floorH) {
    CGFloat band = horizontal ? floorH : floorW;
    CGFloat narrow = horizontal ? floorW : floorH;
    if (band < 8.0 || band > kNDMaxFloorBandPt) return NO;
    if (narrow < kNDMinRealSpan) return NO;
    return YES;
}

/// Chỉ dùng model layer. KHÔNG dùng presentationLayer — crash SIGTRAP trong Dock.
static CGRect NDFloorRectInHost(CALayer *floor, CALayer *host) {
    if (!floor || !host || !floor.superlayer) return CGRectZero;
    return [floor convertRect:floor.bounds toLayer:host];
}

/// floor.bounds animate lúc resize (log: floor=1502x83,88,82... hostL nhảy theo).
/// gNDFloorFrame là frame đã settle từ setFloorFrame: (đúng host coords) → dùng trọn vẹn
/// để widget đứng yên tại vị trí đích, không dao động theo animation.
static CGRect NDFloorRectForWidgets(CALayer *floor, CALayer *host) {
    if (gNDFloorFrameValid) return gNDFloorFrame;
    return NDFloorRectInHost(floor, host);
}

static BOOL NDFloorHostUsable(CGRect floorInHost, BOOL horizontal, CGFloat floorW, CGFloat floorH) {
    if (CGRectIsEmpty(floorInHost)) return NO;
    if (horizontal) {
        if (CGRectGetHeight(floorInHost) < 18.0) return NO;
        if (fabs(CGRectGetHeight(floorInHost) - floorH) > 3.0) return NO;
        if (CGRectGetWidth(floorInHost) < kNDMinRealSpan * 0.5) return NO;
    } else {
        if (CGRectGetWidth(floorInHost) < 18.0) return NO;
        if (fabs(CGRectGetWidth(floorInHost) - floorW) > 3.0) return NO;
        if (CGRectGetHeight(floorInHost) < kNDMinRealSpan * 0.5) return NO;
    }
    return YES;
}

/// Đặt widget trong host từ floorInHost; căn đáy cách maxY đúng insetBottom.
static CGRect NDWidgetHostFrame(CGRect floorInHost, BOOL horizontal, BOOL isRight,
                                CGFloat insetX, CGFloat insetTop, CGFloat insetBottom,
                                CGFloat w, CGFloat h) {
    if (horizontal) {
        CGFloat x = isRight
            ? CGRectGetMaxX(floorInHost) - insetX - w
            : CGRectGetMinX(floorInHost) + insetX;
        CGFloat y = CGRectGetMaxY(floorInHost) - insetBottom - h;
        return CGRectMake(x, y, w, h);
    }
    CGFloat x = CGRectGetMinX(floorInHost) + insetX;
    CGFloat y = isRight
        ? CGRectGetMinY(floorInHost) + insetTop
        : CGRectGetMaxY(floorInHost) - insetBottom - h;
    return CGRectMake(x, y, w, h);
}

static CALayer *NDTopHostLayerBelowWidgets(CALayer *host, CALayer *floor) {
    CALayer *top = floor;
    CGFloat topZ = floor ? floor.zPosition : 0.0;
    for (CALayer *sub in host.sublayers) {
        if (sub == gNDLeftShell || sub == gNDRightShell) continue;
        if (sub.zPosition >= topZ) {
            topZ = sub.zPosition;
            top = sub;
        }
    }
    return top ?: floor;
}

/// Con của host, trên floor/glass; frame host từ floor-local.
static void NDEnsureWidgetsAboveGlass(CALayer *floor) {
    CALayer *host = floor ? floor.superlayer : NULL;
    if (!host || !gNDLeftShell || !gNDRightShell) return;

    CALayer *anchor = NDTopHostLayerBelowWidgets(host, floor);
    CGFloat maxZ = anchor.zPosition;
    for (CALayer *sub in host.sublayers) {
        if (sub == gNDLeftShell || sub == gNDRightShell) continue;
        if (sub.zPosition > maxZ) maxZ = sub.zPosition;
    }
    BOOL needReparent = gNDLeftShell.superlayer != host
        || gNDRightShell.superlayer != host
        || gNDLeftShell.zPosition <= maxZ;
    if (needReparent) {
        [gNDLeftShell removeFromSuperlayer];
        [host insertSublayer:gNDLeftShell above:anchor];
        [gNDRightShell removeFromSuperlayer];
        [host insertSublayer:gNDRightShell above:anchor];
        maxZ = anchor.zPosition;
        for (CALayer *sub in host.sublayers) {
            if (sub == gNDLeftShell || sub == gNDRightShell) continue;
            if (sub.zPosition > maxZ) maxZ = sub.zPosition;
        }
    }
    gNDLeftShell.zPosition = maxZ + 500.0;
    gNDRightShell.zPosition = maxZ + 501.0;
    gNDLeftShell.geometryFlipped = NO;
    gNDRightShell.geometryFlipped = NO;
    gNDWidgetsAttached = YES;
}

static CATextLayer *NDMakeText(NSString *text, NSColor *color) {
    CATextLayer *t = [CATextLayer layer];
    t.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    t.string = text;
    t.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:kNDWidgetFontSize weight:NSFontWeightMedium];
    t.fontSize = kNDWidgetFontSize;
    t.foregroundColor = color.CGColor;
    t.alignmentMode = kCAAlignmentLeft;
    t.truncationMode = kCATruncationEnd;
    t.wrapped = NO;
    return t;
}

static void NDLayoutTextRows(CALayer *shell, CATextLayer *const *rows, int count) {
    if (!shell || count <= 0) return;
    CGFloat w = shell.bounds.size.width;
    CGFloat h = shell.bounds.size.height;
    if (w < 1.0 || h < 1.0) return;
    CGFloat totalH = count * kNDWidgetLineH;
    CGFloat pad = MAX(0.0, (h - totalH) * 0.5);
    CGFloat textW = MAX(1.0, w - 2.0 * kNDWidgetTextPadPt);
    for (int i = 0; i < count; i++) {
        CGFloat rowY = shell.geometryFlipped
            ? (pad + (CGFloat)i * kNDWidgetLineH)
            : (h - pad - (CGFloat)(i + 1) * kNDWidgetLineH);
        rows[i].frame = CGRectMake(kNDWidgetTextPadPt, rowY, textW, kNDWidgetLineH);
    }
}

static CGFloat NDWidgetCornerRadius(CGFloat widgetH) {
    return MIN(12.0, MAX(6.0, widgetH * 0.24));
}

static CALayer *NDMakeLayerShell(void) {
    CALayer *shell = [CALayer layer];
    shell.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    shell.masksToBounds = YES;
    shell.cornerRadius = 10.0;
    shell.backgroundColor = [[NSColor colorWithWhite:0.10 alpha:kNDWidgetBgAlpha] CGColor];
    shell.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.28] CGColor];
    shell.borderWidth = 1.0;
    shell.hidden = YES;
    shell.zPosition = 8000.0;
    return shell;
}

static void NDEnsureWidgets(void) {
    if (gNDLeftShell) return;

    NSColor *hi = [[NSColor whiteColor] colorWithAlphaComponent:0.94];
    NSColor *lo = [[NSColor whiteColor] colorWithAlphaComponent:0.76];

    gNDLeftShell = NDMakeLayerShell();
    gNDRightShell = NDMakeLayerShell();
    gNDDiskLayer = NDMakeText(@"DISK …", lo);
    gNDRamLayer = NDMakeText(@"RAM  …", lo);
    gNDChipLayer = NDMakeText(@"CPU … | GPU …", hi);
    [gNDLeftShell addSublayer:gNDDiskLayer];
    [gNDLeftShell addSublayer:gNDRamLayer];
    [gNDLeftShell addSublayer:gNDChipLayer];
    gNDNetUpLayer = NDMakeText(@"↑ …", lo);
    gNDNetDownLayer = NDMakeText(@"↓ …", lo);
    [gNDRightShell addSublayer:gNDNetUpLayer];
    [gNDRightShell addSublayer:gNDNetDownLayer];

    NDStatsBindLayers(gNDDiskLayer, gNDRamLayer, gNDChipLayer, gNDNetUpLayer, gNDNetDownLayer);
    NDStatsStart();
}

static void NDLayoutWidgets(id dockBar);
static void NDScheduleWidgetLayout(id dockBar);

static void NDScheduleWidgetRelayoutBurst(id dockBar) {
    id bar = dockBar ?: gNDDockBar;
    uint64_t nonce = ++gNDRelayoutNonce;
    NDScheduleWidgetLayout(bar);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayout(bar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayout(bar);
    });
    // Dock may animate floor/band updates asynchronously; finalize after a few hundred ms.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayout(bar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayout(bar);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayout(bar);
    });
}

static void NDScheduleWidgetLayout(id dockBar) {
    if (gNDInWidgetLayout || gNDWidgetLayoutPending) return;
    gNDWidgetLayoutPending = YES;
    id bar = dockBar ?: gNDDockBar;
    dispatch_async(dispatch_get_main_queue(), ^{
        gNDWidgetLayoutPending = NO;
        NDLayoutWidgets(bar);
    });
}

static void NDLayoutWidgets(id dockBar) {
    if (gNDInWidgetLayout) return;
    if (!dockBar) dockBar = gNDDockBar;

    CALayer *floor = gNDFloorLayerRef;
    if (!floor || !floor.superlayer) {
        gNDFloorLayerRef = NULL;
        return;
    }
    if (!NDFloorLayerUsable(floor))
        return;

    // Kích thước settle từ gNDFloorFrame (không dùng floor.bounds đang animate).
    CGFloat floorW = 0.0, floorH = 0.0;
    if (gNDFloorFrameValid) {
        floorW = gNDFloorFrame.size.width;
        floorH = gNDFloorFrame.size.height;
    } else {
        NDFloorLayoutSize(floor, &floorW, &floorH);
    }

    BOOL dockHorizontal = NDIsHorizontalDock(dockBar);
    BOOL horizontal = dockHorizontal && floorW >= floorH;
    if (!NDFloorShapeMatchesDock(dockHorizontal, floorW, floorH))
        return;
    if (!NDBandSpanReasonable(horizontal, floorW, floorH))
        return;

    gNDInWidgetLayout = YES;
    @try {
        NDEnsureWidgets();
        if (!gNDLeftShell) {
            gNDInWidgetLayout = NO;
            return;
        }

        CGFloat insetTop = 0.0, insetBottom = 0.0, insetX = 0.0;
        NDWidgetInsets(&insetTop, &insetBottom, &insetX);

        NDEnsureWidgetsAboveGlass(floor);
        CALayer *host = floor.superlayer;
        if (!host) {
            gNDInWidgetLayout = NO;
            return;
        }

        CGRect leftHost = CGRectZero, rightHost = CGRectZero;
        CGRect refTile = CGRectZero;
        CGFloat widgetH = 0.0;
        BOOL leftOverlap = NO, rightOverlap = NO;

        if (horizontal) {
            // Bám Y/H từ tile (căn giữa giống icon); X từ floor + inset trái/phải.
            CALayer *src = NDLeftmostValidTile(host);
            if (!src) {
                gNDInWidgetLayout = NO;
                return;
            }
            CGRect sf = src.frame;
            refTile = sf;
            widgetH = sf.size.height;

            CGRect floorInHost = NDFloorRectForWidgets(floor, host);
            if (!NDFloorHostUsable(floorInHost, horizontal, floorW, floorH)) {
                gNDInWidgetLayout = NO;
                return;
            }

            CGFloat probeW = NDLeftProbeWidth(sf.size.width, sf.size.height);
            CGFloat leftX = CGRectGetMinX(floorInHost) + insetX;
            CGRect iconClone = NDHorizontalWidgetFrame(floor, host, floorInHost, src,
                                                         leftX, probeW);
            leftHost = iconClone;
            CGFloat rightX = CGRectGetMaxX(floorInHost) - insetX - kNDRightWidgetWidthPt;
            rightHost = NDHorizontalWidgetFrame(floor, host, floorInHost, src,
                                                rightX, kNDRightWidgetWidthPt);
            CGFloat clusterMinX = sf.origin.x, clusterMaxX = CGRectGetMaxX(sf);
            NDIconClusterX(host, &clusterMinX, &clusterMaxX);
            leftOverlap = CGRectGetMaxX(iconClone) + kNDWidgetIconGapPt > clusterMinX;
            rightOverlap = CGRectGetMinX(rightHost) - kNDWidgetIconGapPt < clusterMaxX;
            NDEnsureProbeIcon(host, floor);
            NDEnsureRightProbeIcon(host, floor);
            NDSyncProbeIcon(src, iconClone);
            NDSyncRightGlassWidget(src, rightHost);
            if (gNDProbeBgLayer) gNDProbeBgLayer.hidden = NO;
            if (gNDRightProbeBgLayer) gNDRightProbeBgLayer.hidden = NO;
            gNDLeftShell.hidden = YES;
            gNDRightShell.hidden = YES;
            gNDProbeIcon.hidden = leftOverlap;
            if (gNDRightProbeIcon) {
                gNDRightProbeIcon.hidden = rightOverlap;
                if (!rightOverlap) gNDRightProbeIcon.opacity = 1.0f;
            }
        } else {
            // Dock dọc: giữ logic cũ theo floor/glass (đường ít dùng, tránh hồi quy).
            CGFloat bandSpan = floorW;
            widgetH = NDWidgetShellHeight(bandSpan);
            CGFloat widgetY = NDWidgetLocalY(floor, bandSpan, widgetH);
            CGRect floorInHost = NDFloorRectForWidgets(floor, host);
            if (!NDFloorHostUsable(floorInHost, horizontal, floorW, floorH)) {
                gNDInWidgetLayout = NO;
                return;
            }
            CGFloat slotW = MAX(8.0, floorW - 2.0 * insetX);
            CGRect leftLocal = CGRectMake(insetX, widgetY, slotW, widgetH);
            CGRect rightLocal = CGRectMake(insetX, floorH - widgetY - widgetH, slotW, widgetH);
            CGRect icons = dockBar ? NDIconBarLocalRect(dockBar, floorW, floorH, horizontal)
                                   : CGRectZero;
            leftOverlap = NDRectsOverlapY(leftLocal, icons, kNDWidgetIconGapPt);
            rightOverlap = NDRectsOverlapY(rightLocal, icons, kNDWidgetIconGapPt);
            leftHost = NDWidgetHostFrame(floorInHost, horizontal, NO,
                                         insetX, insetTop, insetBottom, slotW, widgetH);
            rightHost = NDWidgetHostFrame(floorInHost, horizontal, YES,
                                          insetX, insetTop, insetBottom, slotW, widgetH);
            refTile = floorInHost;
        }

        if (leftHost.origin.y < 0.0 || rightHost.origin.y < 0.0) {
            gNDInWidgetLayout = NO;
            return;
        }

        if (!horizontal) {
            if (gNDRightProbeBgLayer) gNDRightProbeBgLayer.hidden = YES;
            if (gNDProbeBgLayer) gNDProbeBgLayer.hidden = YES;
            if (gNDRightProbeIcon) gNDRightProbeIcon.hidden = YES;
            NDRestoreWidgetContent(gNDLeftShell, YES);
            NDRestoreWidgetContent(gNDRightShell, NO);
            CGFloat radius = NDWidgetCornerRadius(widgetH);
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gNDLeftShell.cornerRadius = radius;
            gNDRightShell.cornerRadius = radius;
            gNDLeftShell.frame = leftHost;
            gNDRightShell.frame = rightHost;
            [CATransaction commit];
            CATextLayer *leftRows[] = { gNDDiskLayer, gNDRamLayer, gNDChipLayer };
            CATextLayer *rightRows[] = { gNDNetUpLayer, gNDNetDownLayer };
            NDLayoutTextRows(gNDLeftShell, leftRows, 3);
            NDLayoutTextRows(gNDRightShell, rightRows, 2);
        }
        if (!horizontal) {
            gNDLeftShell.hidden = leftOverlap;
            if (!leftOverlap) gNDLeftShell.opacity = 1.0f;
            gNDRightShell.hidden = rightOverlap;
            if (!rightOverlap) gNDRightShell.opacity = 1.0f;
        }

        if (!horizontal && gNDProbeIcon)
            gNDProbeIcon.hidden = YES;

        if (NDDebugEnabled() && !gNDVerifyLogged && gNDWidgetsAttached) {
            BOOL onHost = gNDRightShell.superlayer == host;
            BOOL dimOk = gNDRightShell.frame.size.width > 10;
            BOOL visOk = !gNDRightShell.hidden;
            BOOL zOk = gNDRightShell.zPosition > floor.zPosition;
            if (horizontal) {
                onHost = gNDProbeIcon.superlayer == host
                      && gNDRightProbeIcon.superlayer == host;
                dimOk = gNDProbeIcon.frame.size.width > 10
                      && gNDRightProbeIcon.frame.size.width > 10;
                visOk = !gNDProbeIcon.hidden && !gNDRightProbeIcon.hidden;
                zOk = gNDProbeIcon.zPosition > floor.zPosition
                    && gNDRightProbeIcon.zPosition > floor.zPosition;
            } else {
                onHost = onHost && gNDLeftShell.superlayer == host;
                dimOk = dimOk && gNDLeftShell.frame.size.width > 10;
                visOk = visOk || !gNDLeftShell.hidden;
                zOk = zOk && gNDLeftShell.zPosition > floor.zPosition;
            }
            BOOL tileOk;
            if (horizontal) {
                CGRect fh = NDFloorRectForWidgets(floor, host);
                CGFloat leftM = leftHost.origin.x - CGRectGetMinX(fh);
                tileOk = fabs(widgetH - refTile.size.height) < 0.5
                      && fabs(leftM - insetX) < 1.0
                      && fabs(leftHost.origin.y - refTile.origin.y) < 0.5;
            } else {
                tileOk = widgetH > 8.0;
            }
            BOOL ok = onHost && dimOk && visOk && tileOk && zOk;
            NDLogAlways("VERIFY widgets=%s dock=ok", ok ? "PASS" : "FAIL");
            gNDVerifyLogged = YES;
        }
        NDStatsTick();
    } @catch (__unused NSException *e) {}
    gNDInWidgetLayout = NO;
}

static void nd_hook_setFloorFrame(id self, SEL _cmd, CGRect rect) {
    gNDDockBar = self;
    rect = NDResizeFloorFrame(rect);
    if (rect.size.width > kNDMinRealSpan || rect.size.height > kNDMinRealSpan) {
        gNDFloorFrame = rect;
        gNDFloorFrameValid = YES;
        gNDVerifyLogged = NO;
    }
    orig_setFloorFrame(self, _cmd, rect);
    NDScheduleWidgetRelayoutBurst(self);
}

static void nd_hook_setFLastBarRect(id self, SEL _cmd, CGRect rect) {
    gNDDockBar = self;
    orig_setFLastBarRect(self, _cmd, rect);
    if (gNDFloorLayerRef)
        NDScheduleWidgetRelayoutBurst(self);
}

static void nd_floor_layoutSublayers(id self, SEL _cmd) {
    orig_floorLayout(self, _cmd);
    CALayer *floor = (CALayer *)self;
    if (!NDIsMainFloorLayer(floor)) return;

    if (gNDFloorLayerRef != floor) {
        gNDFloorLayerRef = floor;
        NDScheduleWidgetRelayoutBurst(gNDDockBar);
    } else if (!gNDInWidgetLayout) {
        gNDFloorLayerRef = floor;
        NDLayoutWidgets(gNDDockBar);
    }
}

static void NDInstallFloorHook(void) {
    if (orig_floorLayout) return;
    Class floorCls = objc_getClass("DockCore.ModernFloorLayer");
    if (!floorCls) return;
    Method m = class_getInstanceMethod(floorCls, sel_getUid("layoutSublayers"));
    if (!m) return;
    orig_floorLayout = (void_fn)method_getImplementation(m);
    method_setImplementation(m, (IMP)nd_floor_layoutSublayers);
}

static void NDInstallDockHooks(void) {
    Class bar = NSClassFromString(@"DockBar");
    if (!bar) return;

    if (!orig_setFloorFrame) {
        Method m = class_getInstanceMethod(bar, sel_getUid("setFloorFrame:"));
        if (m) {
            orig_setFloorFrame = (set_rect_fn)method_getImplementation(m);
            method_setImplementation(m, (IMP)nd_hook_setFloorFrame);
        }
    }
    if (!orig_setFLastBarRect) {
        Method clusterM = class_getInstanceMethod(bar, sel_getUid("setFLastBarRect:"));
        if (clusterM) {
            orig_setFLastBarRect = (set_rect_fn)method_getImplementation(clusterM);
            method_setImplementation(clusterM, (IMP)nd_hook_setFLastBarRect);
        }
    }
    NDInstallFloorHook();
}

static void nd_on_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    NDInstallDockHooks();
}

__attribute__((constructor(0)))
static void nd_init(void) {
    if (NDIsDockProcess()) {
        _dyld_register_func_for_add_image(nd_on_image_added);
        NDInstallDockHooks();
        return;
    }
    NDWindowMarginInit();
}
