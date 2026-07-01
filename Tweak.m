#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import "NDConfig.h"
#import "NDStats.h"
#import "NDMedia.h"
#import <math.h>

void NDWindowMarginInit(void);

static const CGFloat kNDMinRealSpan = 50.0;
static const CGFloat kNDMaxFloorBandPt = 120.0;
/// Lề widget so với mép trên/dưới floor (pt). Chiều cao = floorH - 2×lề.
static const CGFloat kNDWidgetInsetPt = 7.0;
static const CGFloat kNDWidgetIconGapPt = 4.0;
static const CGFloat kNDWidgetTextPadPt = 8.0;
static const CGFloat kNDWidgetLineH = 11.0;
static const CGFloat kNDWidgetFontSize = 9.5;
static const CGFloat kNDWidgetCompactLineH = 10.0;
static const CGFloat kNDWidgetCompactFontSize = 8.0;
static const CGFloat kNDWidgetCompactPadPt = 5.0;
static const int kNDStatsCompactLines = 8;
static const int kNDNetCompactLines = 2;
static const CGFloat kNDMediaHorizArtPt = 34.0;
static const CGFloat kNDMediaHorizMinWidthPt = 118.0;
static const CGFloat kNDMediaPadPt = 3.0;
static const CGFloat kNDMediaCtrlFontSize = 11.0;
static const CGFloat kNDMediaCtrlSideFontSize = 12.5;
static const CGFloat kNDMediaCompactCtrlFontSize = 10.0;
static const CGFloat kNDMediaCompactCtrlSideFontSize = 11.5;
static const CGFloat kNDMediaArtistLineH = 9.0;
static const CGFloat kNDWidgetMinHeightPt = 36.0;
static const CGFloat kNDWidgetBgAlpha = 0.58;

/// Chuỗi dự phòng đo rộng pill ngang (đơn vị scale tối đa, tránh cắt khi giá trị tăng).
static NSString * const kNDHorizDiskReserve = @"DISK 999GB/999GB 100%";
static NSString * const kNDHorizRamReserve = @"RAM  999 GB / 999 GB";
/// GHz max (%.1f) và MHz max (%u<1000) — lấy rộng hơn khi đo stats.
static NSString * const kNDHorizChipReserveGHz = @"CPU 100.0GHz | GPU 100.0GHz";
static NSString * const kNDHorizChipReserveMHz = @"CPU 999MHz | GPU 999MHz";
static NSString * const kNDHorizNetUpReserve = @"↑ 9.999 KB/s";
static NSString * const kNDHorizNetDownReserve = @"↓ 9.999 MB/s";
static NSString * const kNDHorizMediaTitleReserve = @"Blinding Lights";
static NSString * const kNDHorizMediaArtistReserve = @"The Weeknd";
static NSString * const kNDHorizMediaControlsReserve = @"⏮   ▶   ⏭";
static const CGFloat kNDHorizontalMeasureFudgePt = 10.0;

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
static CALayer *gNDMediaProbeIcon = NULL;
static CALayer *gNDMediaProbeBgLayer = NULL;
static CALayer *gNDMediaArtLayer = NULL;
static CALayer *gNDMediaTitleClip = NULL;
static CALayer *gNDMediaArtistClip = NULL;
static CATextLayer *gNDMediaTitleLayer = NULL;
static CATextLayer *gNDMediaArtistLayer = NULL;
static CATextLayer *gNDMediaPrevLayer = NULL;
static CATextLayer *gNDMediaPlayLayer = NULL;
static CATextLayer *gNDMediaNextLayer = NULL;
static CATextLayer *gNDNetUpLayer = NULL;
static CATextLayer *gNDNetDownLayer = NULL;
static BOOL gNDInWidgetLayout = NO;
static uint64_t gNDRelayoutNonce = 0;
static uint64_t gNDSettleNonce = 0;
static NSInteger gNDLastBarOrientation = -1;
static NSInteger gNDLastFloorShapeVertical = -1;
static CFAbsoluteTime gNDOrientationSettleUntil = 0;

static BOOL NDInOrientationSettle(void) {
    return CFAbsoluteTimeGetCurrent() < gNDOrientationSettleUntil;
}

static void NDBeginOrientationSettle(void) {
    gNDOrientationSettleUntil = CFAbsoluteTimeGetCurrent() + 12.0;
}

static BOOL NDIsVerticalFloorRect(CGRect rect) {
    return rect.size.height > rect.size.width;
}

static BOOL NDIsHorizontalDock(id dockBar);
static void NDFloorLayoutSize(CALayer *floor, CGFloat *outW, CGFloat *outH);
static BOOL NDFloorShapeMatchesDock(BOOL dockHorizontal, CGFloat floorW, CGFloat floorH);

/// Dock phải: barOrientation có thể vẫn là bottom trong khi floor đã dọc — tin floor khi lệch.
static BOOL NDEffectiveDockHorizontal(id dockBar, CALayer *floor) {
    BOOL barH = NDIsHorizontalDock(dockBar);
    if (!gNDFloorFrameValid) {
        if (floor) {
            CGFloat w = 0.0, h = 0.0;
            NDFloorLayoutSize(floor, &w, &h);
            if (w > 8.0 && h > 8.0)
                return !(h > w * 1.12);
        }
        return barH;
    }
    if (NDFloorShapeMatchesDock(barH, gNDFloorFrame.size.width, gNDFloorFrame.size.height))
        return barH;
    return !NDIsVerticalFloorRect(gNDFloorFrame);
}

static BOOL NDIsMainFloorLayer(CALayer *floor) {
    if (!floor || !gNDFloorFrameValid) return NO;
    CGFloat w = floor.bounds.size.width;
    CGFloat h = floor.bounds.size.height;
    if (w < kNDMinRealSpan && h < kNDMinRealSpan) return NO;

    BOOL useVertical = NDIsVerticalFloorRect(gNDFloorFrame);
    if (NDInOrientationSettle() && gNDDockBar)
        useVertical = !NDEffectiveDockHorizontal(gNDDockBar, floor);

    if (useVertical) {
        if (h < kNDMinRealSpan || w < kNDWidgetMinHeightPt) return NO;
        if (w > kNDMaxFloorBandPt || w > h * 1.2) return NO;
        if (!NDInOrientationSettle()) {
            if (fabs(h - gNDFloorFrame.size.height) > 40.0) return NO;
            if (h < gNDFloorFrame.size.height * 0.85) return NO;
        }
        return YES;
    }

    if (w < kNDMinRealSpan || h < kNDWidgetMinHeightPt) return NO;
    if (h > kNDMaxFloorBandPt || h > w * 1.2) return NO;
    if (!NDInOrientationSettle()) {
        if (fabs(w - gNDFloorFrame.size.width) > 40.0) return NO;
        if (w < gNDFloorFrame.size.width * 0.85) return NO;
    }
    return YES;
}

static BOOL NDFloorLayerUsable(CALayer *floor) {
    if (!floor || !gNDFloorFrameValid) return NO;
    if (!floor.superlayer) return NO;
    return NDIsMainFloorLayer(floor);
}

static void NDFloorLayoutSize(CALayer *floor, CGFloat *outW, CGFloat *outH);

static NSInteger NDBarOrientation(id dockBar) {
    if (dockBar && [dockBar respondsToSelector:sel_getUid("barOrientation")])
        return ((NSInteger (*)(id, SEL))objc_msgSend)(dockBar, sel_getUid("barOrientation"));
    return 2; // bottom
}

static BOOL NDIsHorizontalDock(id dockBar) {
    NSInteger o = NDBarOrientation(dockBar);
    return o == 2 || o == 0;
}

/// Dock dọc: +1 hướng mép màn hình, −1 hướng trong màn (pill icon lệch về phía cạnh).
static CGFloat NDVerticalGlassOuterSign(id dockBar, CALayer *tile) {
    NSInteger o = NDBarOrientation(dockBar);
    if (o == 1) return -1.0;
    if (o == 3) return +1.0;
    CALayer *host = tile ? tile.superlayer : NULL;
    if (!host || !gNDFloorLayerRef) return 0.0;
    CGRect floorH = [gNDFloorLayerRef convertRect:gNDFloorLayerRef.bounds toLayer:host];
    NSScreen *scr = [NSScreen mainScreen];
    if (!scr || CGRectIsEmpty(floorH)) return 0.0;
    return (CGRectGetMidX(floorH) > CGRectGetMidX(scr.frame)) ? +1.0 : -1.0;
}

/// horizontal layout nhưng floor/probe còn hình dọc → nguy cơ widget "ma".
static BOOL NDGhostRisk(BOOL layoutHorizontal, CGRect floorInHost,
                        CGRect leftProbe, CGRect rightProbe) {
    if (!layoutHorizontal) return NO;
    BOOL floorVertical = floorInHost.size.height > floorInHost.size.width * 1.12;
    if (floorVertical) return YES;
    if (leftProbe.size.width > 1.0
        && leftProbe.size.height > leftProbe.size.width * 1.4)
        return YES;
    if (rightProbe.size.width > 1.0
        && rightProbe.size.height > rightProbe.size.width * 1.4)
        return YES;
    if (gNDMediaProbeIcon && !gNDMediaProbeIcon.hidden) {
        CGRect mp = gNDMediaProbeIcon.frame;
        if (mp.size.width > 1.0 && mp.size.height > mp.size.width * 1.4)
            return YES;
    }
    return NO;
}

static void NDLayoutTextRows(CALayer *shell, CATextLayer *const *rows, int count);
static void NDLayoutStatsCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR);
static void NDLayoutNetCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR);
static void NDLayoutMediaHorizontal(CALayer *shell, CGFloat topIn, CGFloat botIn);
static void NDLayoutMediaCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR);
static CGFloat NDHorizontalMediaContentWidth(void);
static BOOL NDIsMediaShellLayer(CALayer *sub);
static CGRect NDFloorRectForWidgets(CALayer *floor, CALayer *host, BOOL dockHorizontal,
                                    const char **outSource);
static CGRect NDTileVisualRectInHost(CALayer *tile, CALayer *host);

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

/// Widget dọc: X/W = tile.frame (clone slot); H kéo dài — mirror của widget ngang (Y/H tile, W kéo).
static CGRect NDVerticalWidgetFrame(CALayer *tile, CGFloat y, CGFloat h) {
    CGRect tf = tile ? tile.frame : CGRectZero;
    return CGRectMake(tf.origin.x, y, MAX(8.0, tf.size.width), MAX(8.0, h));
}

/// Chiều cao pill compact = số dòng nội dung + padding (dock dọc net).
static CGFloat NDVerticalCompactContentHeight(int lines) {
    if (lines <= 0) return 0.0;
    return (CGFloat)lines * kNDWidgetCompactLineH + 2.0 * kNDWidgetCompactPadPt;
}

static CGFloat NDMediaVerticalContentHeight(void) {
    CGFloat lineH = kNDWidgetCompactLineH;
    CGFloat ctrlLineH = lineH + 1.0;
    return 2.0 * lineH + 3.0 * ctrlLineH + 2.0 * kNDMediaPadPt;
}

static CALayer *NDEndmostValidTile(CALayer *host, BOOL topEnd) {
    if (!host) return NULL;
    CALayer *best = NULL;
    CGFloat bestY = topEnd ? CGFLOAT_MAX : -CGFLOAT_MAX;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon || s == gNDMediaProbeIcon
            || s == gNDLeftShell || s == gNDRightShell) continue;
        if (strcmp(object_getClassName(s), "DOCKTileLayer")) continue;
        CGRect f = s.frame;
        if (f.size.width < 8.0 || f.size.height < 8.0) continue;
        if (f.size.height > 256.0 || f.size.width > 256.0) continue;
        CGFloat y = topEnd ? CGRectGetMinY(f) : CGRectGetMaxY(f);
        if (topEnd) {
            if (y < bestY) { bestY = y; best = s; }
        } else {
            if (y > bestY) { bestY = y; best = s; }
        }
    }
    return best;
}

static CALayer *NDRightmostValidTile(CALayer *host) {
    if (!host) return NULL;
    CALayer *best = NULL;
    CGFloat bestX = -CGFLOAT_MAX;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon || s == gNDMediaProbeIcon
            || s == gNDLeftShell || s == gNDRightShell) continue;
        if (strcmp(object_getClassName(s), "DOCKTileLayer")) continue;
        CGRect f = s.frame;
        if (f.size.width < 8.0 || f.size.height < 8.0) continue;
        if (f.size.height > 256.0 || f.size.width > 256.0) continue;
        if (CGRectGetMaxX(f) > bestX) {
            bestX = CGRectGetMaxX(f);
            best = s;
        }
    }
    return best;
}

static CALayer *NDLeftmostValidTile(CALayer *host) {
    if (!host) return NULL;
    CALayer *best = NULL;
    CGFloat bestX = CGFLOAT_MAX;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon || s == gNDMediaProbeIcon
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
        if (s == gNDProbeIcon || s == gNDRightProbeIcon || s == gNDMediaProbeIcon
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

/// Bề dọc cụm icon (cho overlap dock trái/phải).
static BOOL NDIconClusterY(CALayer *host, CGFloat *outMinY, CGFloat *outMaxY) {
    if (!host) return NO;
    CGFloat minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    int n = 0;
    for (CALayer *s in host.sublayers) {
        if (s == gNDProbeIcon || s == gNDRightProbeIcon || s == gNDMediaProbeIcon
            || s == gNDLeftShell || s == gNDRightShell) continue;
        if (strcmp(object_getClassName(s), "DOCKTileLayer")) continue;
        CGRect f = s.frame;
        if (f.size.width < 8.0 || f.size.height < 8.0) continue;
        if (CGRectGetMinY(f) < minY) minY = CGRectGetMinY(f);
        if (CGRectGetMaxY(f) > maxY) maxY = CGRectGetMaxY(f);
        n++;
    }
    if (n == 0) return NO;
    if (outMinY) *outMinY = minY;
    if (outMaxY) *outMaxY = maxY;
    return YES;
}

static BOOL NDRectsOverlapY(CGRect a, CGRect b, CGFloat gap) {
    if (CGRectIsEmpty(a) || CGRectIsEmpty(b)) return NO;
    return !(CGRectGetMaxY(a) + gap <= CGRectGetMinY(b)
          || CGRectGetMinY(a) >= CGRectGetMaxY(b) + gap);
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
    return sub == gNDProbeBgLayer || sub == gNDRightProbeBgLayer
        || sub == gNDMediaProbeBgLayer;
}

static BOOL NDIsMediaShellLayer(CALayer *sub) {
    return sub == gNDMediaArtLayer || sub == gNDMediaTitleClip || sub == gNDMediaArtistClip
        || sub == gNDMediaPrevLayer || sub == gNDMediaPlayLayer || sub == gNDMediaNextLayer;
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

static void NDEnsureMediaProbeIcon(CALayer *host, CALayer *floor) {
    if (!host || !floor) return;
    if (!gNDMediaProbeIcon) {
        gNDMediaProbeIcon = [CALayer layer];
        gNDMediaProbeIcon.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        gNDMediaProbeIcon.backgroundColor = [[NSColor clearColor] CGColor];
    }
    NDEnsureGlassWidgetHost(gNDMediaProbeIcon, host, floor, 552.0);
}

static void NDHideLegacyShells(void) {
    if (gNDLeftShell) {
        gNDLeftShell.hidden = YES;
        gNDLeftShell.zPosition = 0.0;
    }
    if (gNDRightShell) {
        gNDRightShell.hidden = YES;
        gNDRightShell.zPosition = 0.0;
    }
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

/// Clone tile → glass pill. Ngang: inset dọc (top/bot) theo visual icon. Dọc: inset ngang (trái/phải).
static void NDSyncGlassWidget(CALayer *shell, CALayer *bg, CALayer *src, CGRect frame,
                              CATextLayer *const *rows, int rowCount, BOOL compactVertical) {
    if (!shell || !src || !bg || rowCount <= 0) return;
    CALayer *host = src.superlayer;
    CGRect vf = NDTileVisualRectInHost(src, host);
    CGRect tf = src.frame;
    CGFloat topIn = MAX(0.0, vf.origin.y - tf.origin.y);
    CGFloat botIn = MAX(0.0, CGRectGetMaxY(tf) - CGRectGetMaxY(vf));
    CGFloat leftIn = MAX(0.0, vf.origin.x - tf.origin.x);
    CGFloat rightIn = MAX(0.0, CGRectGetMaxX(tf) - CGRectGetMaxX(vf));
    BOOL compactStats = compactVertical && rowCount == 3;
    BOOL compactNet = compactVertical && rowCount == 2;
    CGFloat glassSideL = leftIn;
    CGFloat glassSideR = rightIn;

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
    shell.hidden = NO;

    if (compactVertical) {
        CGFloat bgW = MAX(8.0, frame.size.width - leftIn - rightIn);
        CGFloat halfPad = (leftIn + rightIn) * 0.5;
        CGFloat symL = (frame.size.width - bgW) * 0.5;
        symL += NDVerticalGlassOuterSign(gNDDockBar, src) * halfPad;
        symL = MAX(0.0, MIN(frame.size.width - bgW, symL));
        glassSideL = symL;
        glassSideR = frame.size.width - bgW - symL;
        bg.frame = CGRectMake(symL, 0.0, bgW, frame.size.height);
        bg.cornerRadius = (src.cornerRadius > 0.5) ? src.cornerRadius : bgW * 0.22;
    } else {
        CGFloat bgH = MAX(8.0, frame.size.height - topIn - botIn);
        bg.frame = CGRectMake(0.0, topIn, frame.size.width, bgH);
        bg.cornerRadius = (src.cornerRadius > 0.5) ? src.cornerRadius : bgH * 0.22;
    }
    bg.masksToBounds = YES;
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
    if (compactStats)
        NDLayoutStatsCompact(shell, glassSideL, glassSideR);
    else if (compactNet)
        NDLayoutNetCompact(shell, glassSideL, glassSideR);
    else
        NDLayoutTextRows(shell, rows, rowCount);
}

static void NDSyncProbeIcon(CALayer *src, CGRect frame, BOOL compactVertical) {
    if (!gNDProbeIcon || !src) return;
    gNDProbeBgLayer = NDEnsureGlassBgLayer(gNDProbeIcon, gNDProbeBgLayer);
    CATextLayer *rows[] = { gNDDiskLayer, gNDRamLayer, gNDChipLayer };
    NDSyncGlassWidget(gNDProbeIcon, gNDProbeBgLayer, src, frame, rows, 3, compactVertical);
}

static void NDSyncRightGlassWidget(CALayer *src, CGRect frame, BOOL compactVertical) {
    if (!gNDRightProbeIcon || !src) return;
    gNDRightProbeBgLayer = NDEnsureGlassBgLayer(gNDRightProbeIcon, gNDRightProbeBgLayer);
    CATextLayer *rows[] = { gNDNetUpLayer, gNDNetDownLayer };
    NDSyncGlassWidget(gNDRightProbeIcon, gNDRightProbeBgLayer, src, frame, rows, 2, compactVertical);
}

static void NDSyncMediaWidget(CALayer *shell, CALayer *bg, CALayer *src, CGRect frame,
                              BOOL compactVertical) {
    if (!shell || !src || !bg) return;
    CALayer *host = src.superlayer;
    CGRect vf = NDTileVisualRectInHost(src, host);
    CGRect tf = src.frame;
    CGFloat topIn = MAX(0.0, vf.origin.y - tf.origin.y);
    CGFloat botIn = MAX(0.0, CGRectGetMaxY(tf) - CGRectGetMaxY(vf));
    CGFloat leftIn = MAX(0.0, vf.origin.x - tf.origin.x);
    CGFloat rightIn = MAX(0.0, CGRectGetMaxX(tf) - CGRectGetMaxX(vf));
    CGFloat glassSideL = leftIn;
    CGFloat glassSideR = rightIn;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shell.geometryFlipped = NO;
    shell.contents = nil;
    shell.backgroundColor = [[NSColor clearColor] CGColor];
    shell.borderWidth = 0.0;
    for (CALayer *sub in [shell.sublayers copy]) {
        if (NDIsGlassWidgetBg(sub) || NDIsMediaShellLayer(sub)) continue;
        [sub removeFromSuperlayer];
    }
    shell.frame = frame;
    shell.masksToBounds = NO;
    shell.cornerRadius = 0.0;
    shell.opacity = 1.0f;
    shell.hidden = NO;

    if (compactVertical) {
        CGFloat bgW = MAX(8.0, frame.size.width - leftIn - rightIn);
        CGFloat halfPad = (leftIn + rightIn) * 0.5;
        CGFloat symL = (frame.size.width - bgW) * 0.5;
        symL += NDVerticalGlassOuterSign(gNDDockBar, src) * halfPad;
        symL = MAX(0.0, MIN(frame.size.width - bgW, symL));
        glassSideL = symL;
        glassSideR = frame.size.width - bgW - symL;
        bg.frame = CGRectMake(symL, 0.0, bgW, frame.size.height);
        bg.cornerRadius = (src.cornerRadius > 0.5) ? src.cornerRadius : bgW * 0.22;
    } else {
        CGFloat bgH = MAX(8.0, frame.size.height - topIn - botIn);
        bg.frame = CGRectMake(0.0, topIn, frame.size.width, bgH);
        bg.cornerRadius = (src.cornerRadius > 0.5) ? src.cornerRadius : bgH * 0.22;
    }
    bg.masksToBounds = YES;
    if (bg.superlayer != shell)
        [shell insertSublayer:bg atIndex:0];
    NDApplyLiquidGlass(bg);
    bg.zPosition = 0.0;

    CALayer *art = gNDMediaArtLayer;
    CALayer *clips[] = { gNDMediaTitleClip, gNDMediaArtistClip };
    CATextLayer *btns[] = { gNDMediaPrevLayer, gNDMediaPlayLayer, gNDMediaNextLayer };
    if (art) {
        if (art.superlayer != shell) [shell addSublayer:art];
        art.hidden = compactVertical;
        art.opacity = 1.0f;
        art.zPosition = 2.0;
        art.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    }
    for (size_t i = 0; i < sizeof(clips) / sizeof(clips[0]); i++) {
        CALayer *clip = clips[i];
        if (!clip) continue;
        if (clip.superlayer != shell) [shell addSublayer:clip];
        clip.hidden = NO;
        clip.opacity = 1.0f;
        clip.zPosition = 2.0;
        clip.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    }
    for (size_t i = 0; i < sizeof(btns) / sizeof(btns[0]); i++) {
        CATextLayer *row = btns[i];
        if (!row) continue;
        if (row.superlayer != shell) [shell addSublayer:row];
        row.hidden = NO;
        row.opacity = 1.0f;
        row.zPosition = 2.0;
        row.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    }
    [CATransaction commit];

    if (compactVertical)
        NDLayoutMediaCompact(shell, glassSideL, glassSideR);
    else
        NDLayoutMediaHorizontal(shell, topIn, botIn);
    NDMediaRelayout();
}

static void NDSyncMediaIcon(CALayer *src, CGRect frame, BOOL compactVertical) {
    if (!gNDMediaProbeIcon || !src) return;
    gNDMediaProbeBgLayer = NDEnsureGlassBgLayer(gNDMediaProbeIcon, gNDMediaProbeBgLayer);
    NDSyncMediaWidget(gNDMediaProbeIcon, gNDMediaProbeBgLayer, src, frame, compactVertical);
}

static void NDSyncGlassWidgetsOnFloor(CALayer *host, CALayer *floor,
                                      CALayer *srcStats, CALayer *srcNet, CALayer *srcMedia,
                                      CGRect statsFrame, CGRect netFrame, CGRect mediaFrame,
                                      BOOL showStats, BOOL showNet, BOOL showMedia,
                                      BOOL compactVertical) {
    NDEnsureProbeIcon(host, floor);
    NDEnsureRightProbeIcon(host, floor);
    NDEnsureMediaProbeIcon(host, floor);
    if (showStats)
        NDSyncProbeIcon(srcStats, statsFrame, compactVertical);
    else if (gNDProbeIcon)
        gNDProbeIcon.hidden = YES;
    if (showNet)
        NDSyncRightGlassWidget(srcNet, netFrame, compactVertical);
    else if (gNDRightProbeIcon)
        gNDRightProbeIcon.hidden = YES;
    if (showMedia)
        NDSyncMediaIcon(srcMedia, mediaFrame, compactVertical);
    else if (gNDMediaProbeIcon)
        gNDMediaProbeIcon.hidden = YES;
    if (gNDProbeBgLayer) gNDProbeBgLayer.hidden = !showStats;
    if (gNDRightProbeBgLayer) gNDRightProbeBgLayer.hidden = !showNet;
    if (gNDMediaProbeBgLayer) gNDMediaProbeBgLayer.hidden = !showMedia;
    NDHideLegacyShells();
    gNDWidgetsAttached = YES;
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

static BOOL NDFloorShapeMatchesDock(BOOL dockHorizontal, CGFloat floorW, CGFloat floorH) {
    BOOL floorVertical = floorH > floorW * 1.12;
    return dockHorizontal ? !floorVertical : floorVertical;
}

/// Kích thước floor cho layout — chỉ từ gNDFloorFrame (không bypass shape khi settle).
static BOOL NDResolveFloorMetrics(id dockBar, CALayer *floor,
                                  CGFloat *outW, CGFloat *outH, BOOL *outHorizontal,
                                  const char **outPath) {
    BOOL dockHorizontal = NDEffectiveDockHorizontal(dockBar, floor);
    CGFloat useW = 0.0, useH = 0.0;
    const char *path = "frame";

    if (gNDFloorFrameValid) {
        useW = gNDFloorFrame.size.width;
        useH = gNDFloorFrame.size.height;
    } else {
        NDFloorLayoutSize(floor, &useW, &useH);
        path = "no_frame_meas";
    }

    BOOL shapeOk = NDFloorShapeMatchesDock(dockHorizontal, useW, useH);
    if (!shapeOk && gNDFloorFrameValid) {
        if (NDIsHorizontalDock(dockBar) && NDIsVerticalFloorRect(gNDFloorFrame))
            path = "bar_frame_mismatch";
        else
            path = "stale_frame";
    }

    if (outW) *outW = useW;
    if (outH) *outH = useH;
    if (outHorizontal) *outHorizontal = dockHorizontal && useW >= useH;
    if (outPath) *outPath = path;
    return shapeOk;
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
static CGRect NDFloorRectForWidgets(CALayer *floor, CALayer *host, BOOL dockHorizontal,
                                    const char **outSource) {
    CGRect measured = NDFloorRectInHost(floor, host);
    if (!gNDFloorFrameValid || CGRectIsEmpty(measured)) {
        if (outSource) *outSource = "measured_empty";
        return measured;
    }

    BOOL frameVertical = NDIsVerticalFloorRect(gNDFloorFrame);
    BOOL frameMatches = NDFloorShapeMatchesDock(dockHorizontal,
                                                gNDFloorFrame.size.width,
                                                gNDFloorFrame.size.height);
    if (frameVertical && frameMatches) {
        if (outSource) *outSource = "vert_match_origin";
        return CGRectMake(measured.origin.x, measured.origin.y,
                          gNDFloorFrame.size.width, gNDFloorFrame.size.height);
    }
    if (outSource) *outSource = "gNDFloorFrame";
    return gNDFloorFrame;
}

static BOOL NDFloorHostUsable(CGRect floorInHost, BOOL horizontal,
                              CGFloat floorW, CGFloat floorH) {
    if (CGRectIsEmpty(floorInHost)) return NO;
    CGFloat tol = NDInOrientationSettle() ? 24.0 : 3.0;
    if (horizontal) {
        if (CGRectGetHeight(floorInHost) < 18.0) return NO;
        if (fabs(CGRectGetHeight(floorInHost) - floorH) > tol) return NO;
        if (CGRectGetWidth(floorInHost) < kNDMinRealSpan * 0.5) return NO;
    } else {
        if (CGRectGetWidth(floorInHost) < 18.0) return NO;
        if (fabs(CGRectGetWidth(floorInHost) - floorW) > tol) return NO;
        if (CGRectGetHeight(floorInHost) < kNDMinRealSpan * 0.5) return NO;
    }
    return YES;
}

static CATextLayer *NDMakeText(NSString *text, NSColor *color) {
    CATextLayer *t = [CATextLayer layer];
    t.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    t.string = text;
    t.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:kNDWidgetFontSize weight:NSFontWeightSemibold];
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
        CATextLayer *row = rows[i];
        row.wrapped = NO;
        row.alignmentMode = kCAAlignmentLeft;
        row.fontSize = kNDWidgetFontSize;
        row.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:kNDWidgetFontSize
                                                           weight:NSFontWeightSemibold];
        CGFloat rowY = shell.geometryFlipped
            ? (pad + (CGFloat)i * kNDWidgetLineH)
            : (h - pad - (CGFloat)(i + 1) * kNDWidgetLineH);
        row.frame = CGRectMake(kNDWidgetTextPadPt, rowY, textW, kNDWidgetLineH);
    }
}

static NSString *NDTextLayerPlainString(CATextLayer *layer) {
    if (!layer) return @"";
    id str = layer.string;
    if ([str isKindOfClass:[NSString class]]) return (NSString *)str;
    if ([str isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)str string];
    return @"";
}

/// Dock ngang: max(rộng text hiện tại, rộng chuỗi dự phòng) + padding + fudge render.
static CGFloat NDHorizontalMeasureString(NSString *text) {
    if (!text.length) return 0.0;
    NSFont *font = [NSFont systemFontOfSize:kNDWidgetFontSize weight:NSFontWeightSemibold];
    return ceil([text sizeWithAttributes:@{ NSFontAttributeName: font }].width);
}

static CGFloat NDHorizontalContentWidth(CATextLayer *const *rows, int count,
                                        NSString *const *reserve, int reserveCount,
                                        NSString *const *extra, int extraCount) {
    CGFloat maxW = 0.0;
    for (int i = 0; i < count; i++) {
        maxW = MAX(maxW, NDHorizontalMeasureString(NDTextLayerPlainString(rows[i])));
        if (reserve && i < reserveCount)
            maxW = MAX(maxW, NDHorizontalMeasureString(reserve[i]));
    }
    for (int j = 0; extra && j < extraCount; j++)
        maxW = MAX(maxW, NDHorizontalMeasureString(extra[j]));
    return MAX(40.0, maxW + kNDHorizontalMeasureFudgePt + 2.0 * kNDWidgetTextPadPt);
}

static void NDApplyCompactTextStyle(CATextLayer *row, CGRect frame) {
    row.wrapped = YES;
    row.alignmentMode = kCAAlignmentCenter;
    row.fontSize = kNDWidgetCompactFontSize;
    row.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:kNDWidgetCompactFontSize
                                                                      weight:NSFontWeightSemibold];
    row.frame = frame;
}

/// Text compact trong vùng glass (inset ngang theo visual icon, căn giữa).
static void NDLayoutStatsCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR) {
    if (!shell || !gNDDiskLayer || !gNDRamLayer || !gNDChipLayer) return;
    CGFloat w = shell.bounds.size.width;
    CGFloat h = shell.bounds.size.height;
    if (w < 1.0 || h < 1.0) return;

    static const int kLineCounts[] = { 2, 2, 4 };
    CATextLayer *rows[] = { gNDDiskLayer, gNDRamLayer, gNDChipLayer };
    CGFloat totalH = (CGFloat)kNDStatsCompactLines * kNDWidgetCompactLineH;
    CGFloat pad = MAX(0.0, (h - totalH) * 0.5);
    CGFloat textX = sideInL + kNDWidgetCompactPadPt;
    CGFloat textW = MAX(1.0, w - sideInL - sideInR - 2.0 * kNDWidgetCompactPadPt);
    CGFloat yTop = h - pad;

    for (int i = 0; i < 3; i++) {
        CGFloat blockH = (CGFloat)kLineCounts[i] * kNDWidgetCompactLineH;
        yTop -= blockH;
        NDApplyCompactTextStyle(rows[i], CGRectMake(textX, yTop, textW, blockH));
    }
}

static void NDLayoutNetCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR) {
    if (!shell || !gNDNetUpLayer || !gNDNetDownLayer) return;
    CGFloat w = shell.bounds.size.width;
    CGFloat h = shell.bounds.size.height;
    if (w < 1.0 || h < 1.0) return;

    CATextLayer *rows[] = { gNDNetUpLayer, gNDNetDownLayer };
    CGFloat totalH = (CGFloat)kNDNetCompactLines * kNDWidgetCompactLineH;
    CGFloat pad = MAX(0.0, (h - totalH) * 0.5);
    CGFloat textX = sideInL + kNDWidgetCompactPadPt;
    CGFloat textW = MAX(1.0, w - sideInL - sideInR - 2.0 * kNDWidgetCompactPadPt);
    CGFloat yTop = h - pad;

    for (int i = 0; i < 2; i++) {
        yTop -= kNDWidgetCompactLineH;
        NDApplyCompactTextStyle(rows[i], CGRectMake(textX, yTop, textW, kNDWidgetCompactLineH));
    }
}

static void NDApplyMediaTextStyle(CATextLayer *row, CGRect frame, BOOL centered) {
    if (!row) return;
    row.wrapped = NO;
    row.truncationMode = kCATruncationEnd;
    row.alignmentMode = centered ? kCAAlignmentCenter : kCAAlignmentLeft;
    row.fontSize = kNDWidgetFontSize;
    row.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:kNDWidgetFontSize
                                                       weight:NSFontWeightSemibold];
    row.frame = frame;
}

static void NDApplyMediaCompactStyle(CATextLayer *row, CGRect frame, BOOL centered) {
    if (!row) return;
    row.wrapped = NO;
    row.truncationMode = kCATruncationEnd;
    row.alignmentMode = centered ? kCAAlignmentCenter : kCAAlignmentLeft;
    row.fontSize = kNDWidgetCompactFontSize;
    row.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:kNDWidgetCompactFontSize
                                                       weight:NSFontWeightSemibold];
    row.frame = frame;
}

static void NDApplyMediaHorizCtrlStyle(CATextLayer *row, CGRect frame, CGFloat fontSize) {
    if (!row) return;
    NSString *text = nil;
    id cur = row.string;
    if ([cur isKindOfClass:[NSString class]]) text = (NSString *)cur;
    else if ([cur isKindOfClass:[NSAttributedString class]]) text = [(NSAttributedString *)cur string];
    if (!text.length) return;

    NSFont *font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold];
    CGFloat lineH = frame.size.height;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.minimumLineHeight = lineH;
    ps.maximumLineHeight = lineH;

    CGFloat fontH = font.ascender - font.descender + font.leading;
    CGFloat baselineOffset = floor((lineH - fontH) * 0.5);
    NSMutableDictionary *attrs = [@{
        NSFontAttributeName: font,
        NSParagraphStyleAttributeName: ps,
        NSBaselineOffsetAttributeName: @(baselineOffset),
    } mutableCopy];
    if (row.foregroundColor)
        attrs[NSForegroundColorAttributeName] = [NSColor colorWithCGColor:row.foregroundColor];

    row.wrapped = NO;
    row.truncationMode = kCATruncationEnd;
    row.alignmentMode = kCAAlignmentCenter;
    row.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    row.string = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    row.frame = frame;
}

static void NDApplyMediaCtrlStyle(CATextLayer *row, CGRect frame, BOOL sideButton) {
    if (!row) return;
    row.wrapped = NO;
    row.truncationMode = kCATruncationEnd;
    row.alignmentMode = kCAAlignmentCenter;
    CGFloat size = sideButton ? kNDMediaCtrlSideFontSize : kNDMediaCtrlFontSize;
    row.fontSize = size;
    row.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    row.frame = frame;
}

static void NDApplyMediaCompactCtrlStyle(CATextLayer *row, CGRect frame, BOOL sideButton) {
    if (!row) return;
    row.wrapped = NO;
    row.truncationMode = kCATruncationEnd;
    row.alignmentMode = kCAAlignmentCenter;
    CGFloat size = sideButton ? kNDMediaCompactCtrlSideFontSize : kNDMediaCompactCtrlFontSize;
    row.fontSize = size;
    row.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    row.frame = frame;
}

static void NDLayoutMediaHorizontal(CALayer *shell, CGFloat topIn, CGFloat botIn) {
    if (!shell || !gNDMediaArtLayer || !gNDMediaTitleLayer) return;
    CGFloat w = shell.bounds.size.width;
    CGFloat h = shell.bounds.size.height;
    if (w < 1.0 || h < 1.0) return;

    CGFloat glassH = MAX(8.0, h - topIn - botIn);
    CGFloat innerW = MAX(1.0, w - 2.0 * kNDMediaPadPt);
    CGFloat innerH = MAX(8.0, glassH - 2.0 * kNDMediaPadPt);
    (void)innerW;
    CGFloat innerBot = topIn + kNDMediaPadPt;
    CGFloat innerTop = topIn + glassH - kNDMediaPadPt;

    CGFloat artSz = MIN(kNDMediaHorizArtPt, innerH);
    artSz = MAX(20.0, artSz);
    CGFloat artX = kNDMediaPadPt;
    CGFloat artY = innerBot + (innerH - artSz) * 0.5;
    gNDMediaArtLayer.frame = CGRectMake(artX, artY, artSz, artSz);
    gNDMediaArtLayer.cornerRadius = artSz * 0.12 + 2.0;

    CGFloat textX = artX + artSz + kNDMediaPadPt;
    CGFloat textW = MAX(1.0, w - textX - kNDMediaPadPt);
    CGFloat ctrlH = ceil(MAX(kNDMediaCtrlSideFontSize, kNDMediaCtrlFontSize)) + 3.0;
    CGFloat titleH = kNDWidgetLineH;
    CGFloat artistH = kNDMediaArtistLineH;
    CGFloat textBlockH = titleH + artistH;
    CGFloat freeH = innerH - textBlockH - ctrlH;
    CGFloat textAnchor = innerTop - MAX(0.0, freeH * 0.35);

    CGRect titleClip = CGRectMake(textX, textAnchor - titleH, textW, titleH);
    CGRect artistClip = CGRectMake(textX, textAnchor - titleH - artistH, textW, artistH);

    CGFloat ctrlY = innerBot;
    CGFloat btnW = textW / 3.0;
    CGFloat ctrlFont = MAX(kNDMediaCtrlFontSize, kNDMediaCtrlSideFontSize);
    NDApplyMediaHorizCtrlStyle(gNDMediaPrevLayer,
                               CGRectMake(textX, ctrlY, btnW, ctrlH), ctrlFont);
    NDApplyMediaHorizCtrlStyle(gNDMediaPlayLayer,
                               CGRectMake(textX + btnW, ctrlY, btnW, ctrlH), ctrlFont);
    NDApplyMediaHorizCtrlStyle(gNDMediaNextLayer,
                               CGRectMake(textX + 2.0 * btnW, ctrlY, btnW, ctrlH), ctrlFont);
    NDMediaUpdateMarquee(titleClip, artistClip, NO);
}

static void NDLayoutMediaCompact(CALayer *shell, CGFloat sideInL, CGFloat sideInR) {
    if (!shell || !gNDMediaTitleLayer) return;
    CGFloat w = shell.bounds.size.width;
    CGFloat h = shell.bounds.size.height;
    if (w < 1.0 || h < 1.0) return;

    CGFloat textX = sideInL + kNDMediaPadPt;
    CGFloat textW = MAX(1.0, w - sideInL - sideInR - 2.0 * kNDMediaPadPt);
    CGFloat titleLineH = kNDWidgetCompactLineH;
    CGFloat artistLineH = kNDWidgetCompactLineH - 1.0;
    CGFloat ctrlLineH = kNDWidgetCompactLineH + 1.0;
    CGFloat yTop = h - kNDMediaPadPt;

    yTop -= titleLineH;
    CGRect titleClip = CGRectMake(textX, yTop, textW, titleLineH);
    yTop -= artistLineH;
    CGRect artistClip = CGRectMake(textX, yTop, textW, artistLineH);
    yTop -= ctrlLineH;
    NDApplyMediaCompactCtrlStyle(gNDMediaPrevLayer,
                                 CGRectMake(textX, yTop, textW, ctrlLineH), YES);
    yTop -= ctrlLineH;
    NDApplyMediaCompactCtrlStyle(gNDMediaPlayLayer,
                                 CGRectMake(textX, yTop, textW, ctrlLineH), NO);
    yTop -= ctrlLineH;
    NDApplyMediaCompactCtrlStyle(gNDMediaNextLayer,
                                 CGRectMake(textX, yTop, textW, ctrlLineH), YES);
    NDMediaUpdateMarquee(titleClip, artistClip, YES);
}

static CGFloat NDHorizontalMediaContentWidth(void) {
    CGFloat titleW = NDHorizontalMeasureString(kNDHorizMediaTitleReserve);
    CGFloat artistW = NDHorizontalMeasureString(kNDHorizMediaArtistReserve);
    CGFloat ctrlW = NDHorizontalMeasureString(kNDHorizMediaControlsReserve);
    CGFloat textW = MAX(titleW, MAX(artistW, ctrlW));
    CGFloat w = kNDMediaHorizArtPt + kNDMediaPadPt + textW + 2.0 * kNDMediaPadPt
              + kNDHorizontalMeasureFudgePt;
    return MAX(kNDMediaHorizMinWidthPt, w);
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

    NSColor *hi = [[NSColor blackColor] colorWithAlphaComponent:0.94];
    NSColor *lo = [[NSColor blackColor] colorWithAlphaComponent:0.76];

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

    gNDMediaArtLayer = [CALayer layer];
    gNDMediaArtLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    gNDMediaTitleClip = [CALayer layer];
    gNDMediaArtistClip = [CALayer layer];
    gNDMediaTitleClip.masksToBounds = YES;
    gNDMediaArtistClip.masksToBounds = YES;
    gNDMediaTitleClip.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    gNDMediaArtistClip.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    gNDMediaTitleLayer = NDMakeText(@"Title …", hi);
    gNDMediaArtistLayer = NDMakeText(@"Artist …", lo);
    [gNDMediaTitleClip addSublayer:gNDMediaTitleLayer];
    [gNDMediaArtistClip addSublayer:gNDMediaArtistLayer];
    gNDMediaPrevLayer = NDMakeText(@"⏮", lo);
    gNDMediaPlayLayer = NDMakeText(@"▶", hi);
    gNDMediaNextLayer = NDMakeText(@"⏭", lo);

    NDStatsBindLayers(gNDDiskLayer, gNDRamLayer, gNDChipLayer, gNDNetUpLayer, gNDNetDownLayer);
    NDMediaBindLayers(gNDMediaArtLayer, gNDMediaTitleClip, gNDMediaTitleLayer,
                      gNDMediaArtistClip, gNDMediaArtistLayer,
                      gNDMediaPrevLayer, gNDMediaPlayLayer, gNDMediaNextLayer);
    NDMediaStart();
    NDStatsStart();
}

static void NDLayoutWidgets(id dockBar);
static void NDScheduleWidgetLayoutForce(id dockBar);
static void NDScheduleWidgetRelayoutBurst(id dockBar);
static void NDScheduleOrientationSettleRetry(id dockBar);

/// Ẩn probe khi layout bỏ qua — tránh widget kẹt frame cũ (đổi dọc↔ngang).
static void NDHideProbeWidgets(void) {
    if (gNDProbeIcon) gNDProbeIcon.hidden = YES;
    if (gNDRightProbeIcon) gNDRightProbeIcon.hidden = YES;
    if (gNDMediaProbeIcon) gNDMediaProbeIcon.hidden = YES;
    if (gNDProbeBgLayer) gNDProbeBgLayer.hidden = YES;
    if (gNDRightProbeBgLayer) gNDRightProbeBgLayer.hidden = YES;
    if (gNDMediaProbeBgLayer) gNDMediaProbeBgLayer.hidden = YES;
}

static void NDAbortWidgetLayout(id dockBar, BOOL hideProbes, const char *reason) {
    (void)dockBar;
    (void)reason;
    if (hideProbes)
        NDHideProbeWidgets();
    // Retry ngắn trong settle — KHÔNG reset gNDSettleNonce (tránh hủy retry 8–12s).
    if (NDInOrientationSettle()) {
        id bar = dockBar ?: gNDDockBar;
        if (bar) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NDScheduleWidgetLayoutForce(bar);
            });
        }
    }
}

/// Trả YES nếu barOrientation vừa đổi (dock đổi vị trí).
static BOOL NDNoteBarOrientationChange(id dockBar) {
    NSInteger o = NDBarOrientation(dockBar);
    if (gNDLastBarOrientation < 0) {
        gNDLastBarOrientation = o;
        return NO;
    }
    if (o == gNDLastBarOrientation) return NO;
    gNDLastBarOrientation = o;
    return YES;
}

/// Dock phải: barOrientation không đổi nhưng floor đổi dọc↔ngang.
static BOOL NDNoteFloorShapeChange(void) {
    if (!gNDFloorFrameValid) return NO;
    NSInteger v = NDIsVerticalFloorRect(gNDFloorFrame) ? 1 : 0;
    if (gNDLastFloorShapeVertical < 0) {
        gNDLastFloorShapeVertical = v;
        return NO;
    }
    if (v == gNDLastFloorShapeVertical) return NO;
    gNDLastFloorShapeVertical = v;
    return YES;
}

static void NDOnDockGeometryChange(id dockBar) {
    BOOL barChanged = NDNoteBarOrientationChange(dockBar);
    BOOL shapeChanged = NDNoteFloorShapeChange();
    if (!barChanged && !shapeChanged) return;
    NDBeginOrientationSettle();
    NDScheduleOrientationSettleRetry(dockBar);
    NDScheduleWidgetRelayoutBurst(dockBar);
}

static void NDScheduleOrientationSettleRetry(id dockBar) {
    id bar = dockBar ?: gNDDockBar;
    if (!bar) return;
    uint64_t nonce = ++gNDSettleNonce;
    const double delays[] = { 1.20, 2.00, 3.50, 5.00, 8.00, 10.00, 12.00, 13.50 };
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double sec = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (nonce != gNDSettleNonce) return;
            NDScheduleWidgetLayoutForce(bar);
        });
    }
}

static void NDScheduleWidgetRelayoutBurst(id dockBar) {
    id bar = dockBar ?: gNDDockBar;
    uint64_t nonce = ++gNDRelayoutNonce;
    NDScheduleWidgetLayoutForce(bar);
    const double delays[] = { 0.05, 0.16, 0.32, 0.50, 0.80, 1.20 };
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double sec = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (nonce == gNDRelayoutNonce) NDScheduleWidgetLayoutForce(bar);
        });
    }
}

/// Bỏ qua pending — dùng khi settle/recovery sau đổi orientation.
static void NDScheduleWidgetLayoutForce(id dockBar) {
    id bar = dockBar ?: gNDDockBar;
    if (!bar) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gNDWidgetLayoutPending = NO;
        if (gNDInWidgetLayout) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                gNDWidgetLayoutPending = NO;
                NDLayoutWidgets(bar);
            });
            return;
        }
        NDLayoutWidgets(bar);
    });
}

static void NDLayoutWidgets(id dockBar) {
    if (gNDInWidgetLayout) return;
    if (!dockBar) dockBar = gNDDockBar;

    CALayer *floor = gNDFloorLayerRef;
    if (!floor || !floor.superlayer) {
        gNDFloorLayerRef = NULL;
        NDAbortWidgetLayout(dockBar, NO, "no_floor");
        return;
    }
    if (!NDFloorLayerUsable(floor)) {
        NDAbortWidgetLayout(dockBar, NO, "floor_layer_unusable");
        return;
    }

    BOOL dockHorizontal = NDEffectiveDockHorizontal(dockBar, floor);
    CGFloat floorW = 0.0, floorH = 0.0;
    BOOL horizontal = NO;
    const char *metricsPath = "?";
    if (!NDResolveFloorMetrics(dockBar, floor, &floorW, &floorH, &horizontal, &metricsPath)) {
        NDAbortWidgetLayout(dockBar, YES, "shape_mismatch");
        return;
    }
    if (!NDBandSpanReasonable(horizontal, floorW, floorH)) {
        NDAbortWidgetLayout(dockBar, NO, "band_span");
        return;
    }

    gNDInWidgetLayout = YES;
    @try {
        NDEnsureWidgets();
        if (!gNDLeftShell) {
            gNDInWidgetLayout = NO;
            NDAbortWidgetLayout(dockBar, NO, "no_left_shell");
            return;
        }

        CGFloat insetTop = 0.0, insetBottom = 0.0, insetX = 0.0;
        NDWidgetInsets(&insetTop, &insetBottom, &insetX);

        CALayer *host = floor.superlayer;
        if (!host) {
            gNDInWidgetLayout = NO;
            NDAbortWidgetLayout(dockBar, NO, "no_host");
            return;
        }

        CGRect statsHost = CGRectZero, netHost = CGRectZero, mediaHost = CGRectZero;
        BOOL statsOverlap = NO, netOverlap = NO, mediaOverlap = NO;
        const char *floorRectSrc = "?";
        CGRect floorInHost = NDFloorRectForWidgets(floor, host, dockHorizontal, &floorRectSrc);
        if (!NDFloorHostUsable(floorInHost, horizontal, floorW, floorH)) {
            gNDInWidgetLayout = NO;
            NDAbortWidgetLayout(dockBar, NO, "host_usable");
            return;
        }

        if (horizontal) {
            NDStatsSetVerticalCompact(NO);
            NDStatsTick();
            CALayer *srcLeft = NDLeftmostValidTile(host);
            CALayer *srcRight = NDRightmostValidTile(host);
            if (!srcLeft) {
                gNDInWidgetLayout = NO;
                NDAbortWidgetLayout(dockBar, NO, "no_tile_h");
                return;
            }
            if (!srcRight) srcRight = srcLeft;
            CGRect sf = srcLeft.frame;

            CATextLayer *statsRows[] = { gNDDiskLayer, gNDRamLayer, gNDChipLayer };
            CATextLayer *netRows[] = { gNDNetUpLayer, gNDNetDownLayer };
            NSString *statsReserve[] = { kNDHorizDiskReserve, kNDHorizRamReserve, kNDHorizChipReserveGHz };
            NSString *statsExtra[] = { kNDHorizChipReserveMHz };
            NSString *netReserve[] = { kNDHorizNetUpReserve, kNDHorizNetDownReserve };
            CGFloat statsW = NDHorizontalContentWidth(statsRows, 3, statsReserve, 3, statsExtra, 1);
            CGFloat netW = NDHorizontalContentWidth(netRows, 2, netReserve, 2, NULL, 0);
            CGFloat mediaW = NDHorizontalMediaContentWidth();

            CGFloat statsX = CGRectGetMinX(floorInHost) + insetX;
            statsHost = NDHorizontalWidgetFrame(floor, host, floorInHost, srcLeft, statsX, statsW);
            CGFloat netX = CGRectGetMaxX(statsHost) + kNDWidgetIconGapPt;
            netHost = NDHorizontalWidgetFrame(floor, host, floorInHost, srcLeft, netX, netW);
            CGFloat mediaX = CGRectGetMaxX(floorInHost) - insetX - mediaW;
            mediaHost = NDHorizontalWidgetFrame(floor, host, floorInHost, srcRight, mediaX, mediaW);

            CGFloat clusterMinX = sf.origin.x, clusterMaxX = CGRectGetMaxX(sf);
            NDIconClusterX(host, &clusterMinX, &clusterMaxX);
            statsOverlap = CGRectGetMaxX(statsHost) + kNDWidgetIconGapPt > clusterMinX;
            netOverlap = CGRectGetMaxX(netHost) + kNDWidgetIconGapPt > clusterMinX;
            mediaOverlap = CGRectGetMinX(mediaHost) - kNDWidgetIconGapPt < clusterMaxX;
            NDSyncGlassWidgetsOnFloor(host, floor, srcLeft, srcLeft, srcRight,
                                      statsHost, netHost, mediaHost,
                                      !statsOverlap, !netOverlap, !mediaOverlap, NO);
        } else {
            NDStatsSetVerticalCompact(YES);
            CALayer *src = NDEndmostValidTile(host, NO);
            if (!src) {
                gNDInWidgetLayout = NO;
                NDAbortWidgetLayout(dockBar, NO, "no_tile_v");
                return;
            }
            CGRect sf = src.frame;

            CGFloat floorTop = CGRectGetMinY(floorInHost) + insetTop;
            CGFloat floorBot = CGRectGetMaxY(floorInHost) - insetBottom;
            CGFloat clusterMinY = sf.origin.y, clusterMaxY = CGRectGetMaxY(sf);
            if (!NDIconClusterY(host, &clusterMinY, &clusterMaxY)) {
                clusterMinY = sf.origin.y;
                clusterMaxY = CGRectGetMaxY(sf);
            }

            CGFloat wantStatsH = NDVerticalCompactContentHeight(kNDStatsCompactLines);
            CGFloat wantNetH = NDVerticalCompactContentHeight(kNDNetCompactLines);
            CGFloat wantMediaH = NDMediaVerticalContentHeight();
            CGFloat minStatsH = NDVerticalCompactContentHeight(kNDStatsCompactLines);
            CGFloat minNetH = NDVerticalCompactContentHeight(kNDNetCompactLines);
            CGFloat minMediaH = NDMediaVerticalContentHeight();

            CGFloat topBand = floorBot - clusterMaxY - kNDWidgetIconGapPt;
            CGFloat bottomBand = clusterMinY - floorTop - kNDWidgetIconGapPt;

            CGFloat statsH = MIN(wantStatsH, MAX(0.0, topBand));
            CGFloat statsY = floorBot - statsH;
            statsHost = NDVerticalWidgetFrame(src, statsY, statsH);

            CGFloat netAvail = topBand - statsH - kNDWidgetIconGapPt;
            CGFloat netH = MIN(wantNetH, MAX(0.0, netAvail));
            CGFloat netY = CGRectGetMinY(statsHost) - kNDWidgetIconGapPt - netH;
            netHost = NDVerticalWidgetFrame(src, netY, netH);

            CGFloat mediaH = MIN(wantMediaH, MAX(0.0, bottomBand));
            mediaHost = NDVerticalWidgetFrame(src, floorTop, mediaH);

            CGRect clusterBand = CGRectMake(statsHost.origin.x, clusterMinY,
                                          statsHost.size.width,
                                          clusterMaxY - clusterMinY);
            statsOverlap = statsH < minStatsH
                        || NDRectsOverlapY(statsHost, clusterBand, kNDWidgetIconGapPt);
            netOverlap = netH < minNetH
                      || NDRectsOverlapY(netHost, clusterBand, kNDWidgetIconGapPt);
            mediaOverlap = mediaH < minMediaH
                        || NDRectsOverlapY(mediaHost, clusterBand, kNDWidgetIconGapPt);
            NDSyncGlassWidgetsOnFloor(host, floor, src, src, src,
                                      statsHost, netHost, mediaHost,
                                      !statsOverlap, !netOverlap, !mediaOverlap, YES);
        }

        {
            CGFloat floorMinY = CGRectGetMinY(floorInHost);
            CGFloat floorMaxY = CGRectGetMaxY(floorInHost);
            if (CGRectGetMaxY(statsHost) > floorMaxY + 2.0
                || CGRectGetMinY(netHost) < floorMinY - 2.0
                || CGRectGetMinY(mediaHost) < floorMinY - 2.0
                || statsHost.size.height < 1.0 || netHost.size.height < 1.0
                || mediaHost.size.height < 1.0) {
                gNDInWidgetLayout = NO;
                NDAbortWidgetLayout(dockBar, NO, "bounds_overflow");
                return;
            }
        }

        gNDProbeIcon.hidden = statsOverlap;
        if (gNDRightProbeIcon) {
            gNDRightProbeIcon.hidden = netOverlap;
            if (!netOverlap) gNDRightProbeIcon.opacity = 1.0f;
        }
        if (gNDMediaProbeIcon) {
            gNDMediaProbeIcon.hidden = mediaOverlap;
            if (!mediaOverlap) gNDMediaProbeIcon.opacity = 1.0f;
        }
        if (!statsOverlap) gNDProbeIcon.opacity = 1.0f;

        CGRect lp = gNDProbeIcon ? gNDProbeIcon.frame : CGRectZero;
        CGRect rp = gNDRightProbeIcon ? gNDRightProbeIcon.frame : CGRectZero;
        BOOL ghost = NDGhostRisk(horizontal, floorInHost, lp, rp);
        if (ghost) {
            NDHideProbeWidgets();
            gNDInWidgetLayout = NO;
            NDScheduleWidgetLayoutForce(dockBar);
            return;
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
    }
    NDOnDockGeometryChange(self);
    orig_setFloorFrame(self, _cmd, rect);
    BOOL dockH = NDEffectiveDockHorizontal(self, gNDFloorLayerRef);
    if (NDFloorShapeMatchesDock(dockH, rect.size.width, rect.size.height))
        NDScheduleWidgetLayoutForce(self);
    else
        NDScheduleWidgetRelayoutBurst(self);
}

static void nd_hook_setFLastBarRect(id self, SEL _cmd, CGRect rect) {
    gNDDockBar = self;
    NDOnDockGeometryChange(self);
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
