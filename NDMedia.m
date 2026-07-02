#import "NDMedia.h"
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <dlfcn.h>

typedef void (^NDMRNowPlayingCompletion)(CFDictionaryRef information);
typedef void (^NDMRIsPlayingCompletion)(Boolean isPlaying);
typedef void (*NDMRGetNowPlayingInfoFn)(dispatch_queue_t queue, NDMRNowPlayingCompletion completion);
typedef void (*NDMRGetIsPlayingFn)(dispatch_queue_t queue, NDMRIsPlayingCompletion completion);
typedef void (*NDMRRegisterFn)(dispatch_queue_t queue);
typedef Boolean (*NDMRSendCommandFn)(int command, CFDictionaryRef userInfo);

static CALayer *gArtwork = NULL;
static CALayer *gTitleClip = NULL;
static CATextLayer *gTitle = NULL;
static CALayer *gTitleScroll = NULL;
static CALayer *gArtistScroll = NULL;
static CALayer *gArtistClip = NULL;
static CATextLayer *gArtist = NULL;
static CATextLayer *gPrev = NULL;
static CATextLayer *gPlay = NULL;
static CATextLayer *gNext = NULL;

static void *gMRHandle = NULL;
static struct {
    NDMRGetNowPlayingInfoFn getInfo;
    NDMRGetIsPlayingFn getIsPlaying;
    NDMRRegisterFn registerNotifications;
    NDMRSendCommandFn sendCommand;
    CFStringRef keyTitle;
    CFStringRef keyArtist;
    CFStringRef keyArtwork;
    CFStringRef keyTrackID;
    CFStringRef noteInfoChanged;
    CFStringRef notePlayingChanged;
    CFStringRef noteAppChanged;
} gMR;

static BOOL gMRReady = NO;
static BOOL gMediaStarted = NO;
static BOOL gFetchInFlight = NO;
static BOOL gCachedPlaying = NO;
static BOOL gHasCache = NO;
static NSString *gCachedTitle = nil;
static NSString *gCachedArtist = nil;
static NSData *gCachedArtwork = nil;
static NSString *gCachedTrackID = nil;
static NSData *gLastArtwork = nil;
static NSString *gLastTrackID = nil;
static dispatch_source_t gPollTimer = NULL;
static BOOL gMarqueeFramesValid = NO;
static BOOL gMarqueeCompact = NO;
static CGRect gMarqueeTitleClip = {0};
static CGRect gMarqueeArtistClip = {0};

static const CGFloat kNDMediaTitleFontHoriz = 9.5;
static const CGFloat kNDMediaArtistFontHoriz = 7.5;
static const CGFloat kNDMediaTitleFontCompact = 8.0;
static const CGFloat kNDMediaArtistFontCompact = 6.5;
static const CGFloat kNDMediaMarqueeSpeedPt = 22.0;
static const CGFloat kNDMediaMarqueeEdgePadPt = 5.0;

typedef struct {
    CGFloat spanW;
    CGFloat textX;
    CGFloat travel;
} NDMarqueeMetrics;

static CGFloat gTitleMarqueeTravel = 0.0;
static CGFloat gArtistMarqueeTravel = 0.0;
static BOOL gTitleMarqueeActive = NO;
static BOOL gArtistMarqueeActive = NO;
static CFTimeInterval gTitleMarqueeEpoch = 0.0;
static CFTimeInterval gArtistMarqueeEpoch = 0.0;
static dispatch_source_t gMarqueeTimer = NULL;
static NSString *gTitleMarqueeKey = nil;
static NSString *gArtistMarqueeKey = nil;

static const int kNDMRCommandTogglePlayPause = 2;
static const int kNDMRCommandNextTrack = 4;
static const int kNDMRCommandPreviousTrack = 5;

static CGRect gHitPrev = {0};
static CGRect gHitPlay = {0};
static CGRect gHitNext = {0};
static const CGFloat kNDMediaHitSlopPt = 3.0;

static void NDFetchNowPlaying(void);
static NSColor *NDMediaTextColor(BOOL primary);

static void NDSetTextWithColor(CATextLayer *layer, NSString *text, NSColor *color) {
    if (!layer || !text || !color) return;

    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: [NSFont systemFontOfSize:layer.fontSize > 0 ? layer.fontSize : 12.0 weight:NSFontWeightSemibold],
    };
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.foregroundColor = color.CGColor;
    layer.string = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    [CATransaction commit];
}

static void NDSetText(CATextLayer *layer, NSString *text) {
    if (!layer || !text) return;

    BOOL isPrimary = (layer == gTitle || layer == gPlay);
    NSColor *color = NDMediaTextColor(isPrimary);
    NDSetTextWithColor(layer, text, color);
}

static NSString *NDMRString(CFDictionaryRef dict, CFStringRef key) {
    if (!dict || !key) return nil;
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return nil;
    return (__bridge NSString *)(CFStringRef)value;
}

static NSData *NDMRData(CFDictionaryRef dict, CFStringRef key) {
    if (!dict || !key) return nil;
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return nil;
    return (__bridge NSData *)(CFDataRef)value;
}

static CFStringRef NDLoadMRKey(const char *sym) {
    void *ptr = dlsym(gMRHandle, sym);
    if (!ptr) return NULL;
    return *(CFStringRef *)ptr;
}

static BOOL NDLoadMediaRemote(void) {
    if (gMRReady) return YES;
    gMRHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                       RTLD_LAZY | RTLD_LOCAL);
    if (!gMRHandle) return NO;

    gMR.getInfo = (NDMRGetNowPlayingInfoFn)dlsym(gMRHandle, "MRMediaRemoteGetNowPlayingInfo");
    gMR.getIsPlaying = (NDMRGetIsPlayingFn)dlsym(gMRHandle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gMR.registerNotifications =
        (NDMRRegisterFn)dlsym(gMRHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gMR.sendCommand = (NDMRSendCommandFn)dlsym(gMRHandle, "MRMediaRemoteSendCommand");
    gMR.keyTitle = NDLoadMRKey("kMRMediaRemoteNowPlayingInfoTitle");
    gMR.keyArtist = NDLoadMRKey("kMRMediaRemoteNowPlayingInfoArtist");
    gMR.keyArtwork = NDLoadMRKey("kMRMediaRemoteNowPlayingInfoArtworkData");
    gMR.keyTrackID = NDLoadMRKey("kMRMediaRemoteNowPlayingInfoUniqueIdentifier");
    gMR.noteInfoChanged = NDLoadMRKey("kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    gMR.notePlayingChanged =
        NDLoadMRKey("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    gMR.noteAppChanged = NDLoadMRKey("kMRMediaRemoteNowPlayingApplicationDidChangeNotification");

    gMRReady = gMR.getInfo && gMR.keyTitle && gMR.keyArtist;
    return gMRReady;
}

static void NDSetArtwork(NSData *data) {
    if (!gArtwork) return;
    gArtwork.masksToBounds = YES;
    gArtwork.cornerRadius = 6.5;
    if (!data.length) {
        gArtwork.contents = nil;
        gArtwork.backgroundColor = [[NSColor colorWithWhite:0.25 alpha:0.55] CGColor];
        return;
    }
    NSImage *img = [[NSImage alloc] initWithData:data];
    CGImageRef cg = img ? [img CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
    if (!cg) {
        gArtwork.contents = nil;
        gArtwork.backgroundColor = [[NSColor colorWithWhite:0.25 alpha:0.55] CGColor];
        return;
    }
    gArtwork.contents = (__bridge id)cg;
    gArtwork.contentsGravity = kCAGravityResizeAspectFill;
    gArtwork.backgroundColor = [[NSColor clearColor] CGColor];
}

static void NDApplyIdleState(void) {
    gCachedTitle = @"Not Playing";
    gCachedArtist = @"";
    gCachedArtwork = nil;
    gCachedTrackID = nil;
    gCachedPlaying = NO;
    gHasCache = YES;
}

static void NDStoreCache(NSString *title, NSString *artist, NSData *artwork,
                         NSString *trackID, BOOL playing) {
    gCachedTitle = title.length ? [title copy] : @"Not Playing";
    gCachedArtist = [artist copy] ?: @"";
    gCachedArtwork = artwork.length ? [artwork copy] : nil;
    gCachedTrackID = [trackID copy];
    gCachedPlaying = playing;
    gHasCache = YES;
}

static NDMarqueeMetrics NDMeasureMarqueeMetrics(NSAttributedString *attr, CGFloat clipW) {
    NDMarqueeMetrics m = {0};
    if (!attr.length) return m;

    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attr);
    if (!line) {
        m.spanW = ceil([attr size].width);
        m.textX = kNDMediaMarqueeEdgePadPt;
        m.travel = MAX(0.0, m.spanW + 2.0 * kNDMediaMarqueeEdgePadPt - clipW);
        return m;
    }

    CGRect optical = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseOpticalBounds);
    CFRelease(line);
    m.spanW = ceil(CGRectGetMaxX(optical) - CGRectGetMinX(optical));
    m.textX = kNDMediaMarqueeEdgePadPt - CGRectGetMinX(optical);
    m.travel = MAX(0.0, m.textX + CGRectGetMaxX(optical) - clipW + kNDMediaMarqueeEdgePadPt);
    return m;
}

static void NDPruneMarqueeScrollSublayers(CALayer *scroll, CATextLayer *textLayer) {
    if (!scroll || !textLayer) return;
    for (CALayer *sub in [scroll.sublayers copy]) {
        if (sub != (CALayer *)textLayer)
            [sub removeFromSuperlayer];
    }
}

static CGFloat NDMarqueePingPongOffset(CFTimeInterval epoch, CGFloat travel) {
    if (travel < 0.5) return 0.0;
    CGFloat elapsed = (CACurrentMediaTime() - epoch) * kNDMediaMarqueeSpeedPt;
    CGFloat cycle = travel * 2.0;
    CGFloat phase = elapsed - floor(elapsed / cycle) * cycle;
    return (phase <= travel) ? phase : (cycle - phase);
}

static void NDMarqueeTimerTick(void) {
    if (gTitleMarqueeActive && gTitleScroll && gTitleMarqueeTravel > 0.5) {
        CGFloat off = NDMarqueePingPongOffset(gTitleMarqueeEpoch, gTitleMarqueeTravel);
        gTitleScroll.transform = CATransform3DMakeTranslation(-off, 0, 0);
    }
    if (gArtistMarqueeActive && gArtistScroll && gArtistMarqueeTravel > 0.5) {
        CGFloat off = NDMarqueePingPongOffset(gArtistMarqueeEpoch, gArtistMarqueeTravel);
        gArtistScroll.transform = CATransform3DMakeTranslation(-off, 0, 0);
    }
}

static void NDEnsureMarqueeTimer(void) {
    if (gMarqueeTimer) return;
    dispatch_queue_t q = dispatch_get_main_queue();
    gMarqueeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gMarqueeTimer) return;
    dispatch_source_set_timer(gMarqueeTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 60), (uint64_t)(NSEC_PER_SEC / 300));
    dispatch_source_set_event_handler(gMarqueeTimer, ^{
        NDMarqueeTimerTick();
    });
    dispatch_resume(gMarqueeTimer);
}

static BOOL NDSystemIsDarkAppearance(void) {
    NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    return [style.lowercaseString isEqualToString:@"dark"];
}

static NSColor *NDMediaTextColor(BOOL primary) {
    NSColor *base = NDSystemIsDarkAppearance() ? [NSColor whiteColor] : [NSColor blackColor];
    return [base colorWithAlphaComponent:primary ? 0.94 : 0.76];
}

static void NDApplyMarqueePresentation(void);

void NDMediaRefreshTextColors(void) {
    NSColor *primary = NDMediaTextColor(YES);
    NSColor *secondary = NDMediaTextColor(NO);
    if (gTitle) gTitle.foregroundColor = primary.CGColor;
    if (gArtist) gArtist.foregroundColor = secondary.CGColor;
    if (gPrev) gPrev.foregroundColor = secondary.CGColor;
    if (gPlay) gPlay.foregroundColor = primary.CGColor;
    if (gNext) gNext.foregroundColor = secondary.CGColor;

    if (gTitle || gArtist) {
        if (gMarqueeFramesValid) {
            NDApplyMarqueePresentation();
        } else {
            NDSetText(gTitle, gHasCache ? (gCachedTitle ?: @"Not Playing") : @"…");
            NDSetText(gArtist, gHasCache ? (gCachedArtist ?: @"") : @"");
        }
    }

    if (gPrev || gPlay || gNext) {
        NDRelayoutMediaHorizControls();
    }
}

static void NDStyleMarqueeText(CATextLayer *layer, NSAttributedString *attr, CGFloat layerW,
                               CGFloat clipH, CGFloat textX, CGFloat fontH) {
    layer.string = attr;
    layer.wrapped = NO;
    layer.truncationMode = kCATruncationNone;
    layer.alignmentMode = kCAAlignmentLeft;
    layer.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    layer.anchorPoint = CGPointMake(0.0, 0.5);
    layer.bounds = CGRectMake(0.0, 0.0, layerW, MAX(clipH, fontH + 1.0));
    layer.position = CGPointMake(textX, clipH * 0.5);
    layer.transform = CATransform3DIdentity;
    layer.hidden = NO;
}

static void NDEnsureMarqueeScroll(CALayer *clipLayer, CATextLayer *textLayer, BOOL forTitle) {
    if (!clipLayer || !textLayer) return;
    CALayer *existingScroll = forTitle ? gTitleScroll : gArtistScroll;
    if (existingScroll) return;

    CALayer *scroll = [CALayer layer];
    scroll.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    scroll.anchorPoint = CGPointMake(0.0, 0.5);
    if (textLayer.superlayer == clipLayer)
        [textLayer removeFromSuperlayer];
    [scroll addSublayer:textLayer];
    [clipLayer addSublayer:scroll];
    if (forTitle)
        gTitleScroll = scroll;
    else
        gArtistScroll = scroll;
}

static void NDApplyMarqueeLine(CATextLayer *textLayer, CALayer *clipLayer, BOOL forTitle,
                               NSString *text, CGRect clipFrame, CGFloat fontSize, BOOL primary) {
    if (!textLayer || !clipLayer) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    clipLayer.frame = clipFrame;
    clipLayer.masksToBounds = YES;
    clipLayer.hidden = NO;
    clipLayer.opacity = 1.0f;
    clipLayer.zPosition = 2.0;

    NSString *show = text ?: @"";
    NSFont *font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold];
    NSColor *color = NDMediaTextColor(primary);
    CGFloat clipW = MAX(1.0, clipFrame.size.width);
    CGFloat clipH = MAX(1.0, clipFrame.size.height);

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentLeft;
    ps.lineBreakMode = NSLineBreakByClipping;
    CGFloat fontH = font.ascender - font.descender + font.leading;
    CGFloat baselineOffset = floor((clipH - fontH) * 0.5);
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: ps,
        NSBaselineOffsetAttributeName: @(baselineOffset),
    };
    NSAttributedString *singleAttr = [[NSAttributedString alloc] initWithString:show attributes:attrs];
    NDMarqueeMetrics metrics = NDMeasureMarqueeMetrics(singleAttr, clipW);

    NDEnsureMarqueeScroll(clipLayer, textLayer, forTitle);
    CALayer *scroll = forTitle ? gTitleScroll : gArtistScroll;
    if (!scroll) {
        [CATransaction commit];
        return;
    }
    NDPruneMarqueeScrollSublayers(scroll, textLayer);

    scroll.bounds = CGRectMake(0.0, 0.0, clipW, clipH);
    scroll.anchorPoint = CGPointMake(0.0, 0.5);
    scroll.position = CGPointMake(0.0, clipH * 0.5);

    CGFloat layerW = metrics.spanW + 2.0 * kNDMediaMarqueeEdgePadPt;

    if (!show.length || metrics.spanW <= clipW - 2.0 * kNDMediaMarqueeEdgePadPt + 0.5) {
        if (forTitle) gTitleMarqueeActive = NO;
        else gArtistMarqueeActive = NO;
        scroll.transform = CATransform3DIdentity;
        NDStyleMarqueeText(textLayer, singleAttr, MAX(clipW, layerW), clipH, metrics.textX, fontH);
        [CATransaction commit];
        return;
    }

    CGFloat travel = metrics.travel;
    NDStyleMarqueeText(textLayer, singleAttr, layerW, clipH, metrics.textX, fontH);

    NSString *marqueeKey = [NSString stringWithFormat:@"%@|%.2f|%.1f", show, travel, clipW];
    if (forTitle) {
        if (![marqueeKey isEqualToString:gTitleMarqueeKey]) {
            gTitleMarqueeKey = [marqueeKey copy];
            gTitleMarqueeTravel = travel;
            gTitleMarqueeEpoch = CACurrentMediaTime();
            scroll.transform = CATransform3DIdentity;
        }
        gTitleMarqueeActive = YES;
    } else {
        if (![marqueeKey isEqualToString:gArtistMarqueeKey]) {
            gArtistMarqueeKey = [marqueeKey copy];
            gArtistMarqueeTravel = travel;
            gArtistMarqueeEpoch = CACurrentMediaTime();
            scroll.transform = CATransform3DIdentity;
        }
        gArtistMarqueeActive = YES;
    }
    [CATransaction commit];
    NDEnsureMarqueeTimer();
    NDMarqueeTimerTick();
}

static void NDApplyMarqueePresentation(void) {
    if (!gTitle || !gTitleClip || !gArtistClip) return;
    NSString *title = gHasCache ? (gCachedTitle ?: @"Not Playing") : @"…";
    NSString *artist = gHasCache ? (gCachedArtist ?: @"") : @"";
    CGFloat titleFont = gMarqueeCompact ? kNDMediaTitleFontCompact : kNDMediaTitleFontHoriz;
    CGFloat artistFont = gMarqueeCompact ? kNDMediaArtistFontCompact : kNDMediaArtistFontHoriz;
    NDApplyMarqueeLine(gTitle, gTitleClip, YES, title, gMarqueeTitleClip, titleFont, YES);
    NDApplyMarqueeLine(gArtist, gArtistClip, NO, artist, gMarqueeArtistClip, artistFont, NO);
}

static void NDApplyCachedToLayers(void) {
    if (!gTitle) return;
    if (gMarqueeFramesValid)
        NDApplyMarqueePresentation();
    else {
        NDSetText(gTitle, gHasCache ? (gCachedTitle ?: @"Not Playing") : @"…");
        NDSetText(gArtist, gHasCache ? (gCachedArtist ?: @"") : @"");
    }
    if (!gHasCache) {
        NDSetText(gPrev, @"⏮");
        NDSetText(gPlay, @"▶");
        NDSetText(gNext, @"⏭");
        NDSetArtwork(nil);
        NDRelayoutMediaHorizControls();
        return;
    }
    NDSetText(gPrev, @"⏮");
    NDSetText(gPlay, gCachedPlaying ? @"⏸" : @"▶");
    NDSetText(gNext, @"⏭");
    NDSetArtwork(gCachedArtwork);
    NDRelayoutMediaHorizControls();
}

static void NDApplyNowPlaying(CFDictionaryRef info, Boolean isPlaying) {
    if (!info) {
        NDApplyIdleState();
        NDApplyCachedToLayers();
        return;
    }

    NSString *title = NDMRString(info, gMR.keyTitle);
    NSString *artist = NDMRString(info, gMR.keyArtist);
    NSString *trackID = gMR.keyTrackID ? NDMRString(info, gMR.keyTrackID) : nil;
    NSData *artwork = gMR.keyArtwork ? NDMRData(info, gMR.keyArtwork) : nil;

    if (!artwork.length && trackID.length && gLastArtwork.length
        && [trackID isEqualToString:gLastTrackID]) {
        artwork = gLastArtwork;
    }
    if (artwork.length) {
        gLastArtwork = artwork;
        gLastTrackID = [trackID copy];
    }

    if (!title.length && !artist.length) {
        NDApplyIdleState();
        NDApplyCachedToLayers();
        return;
    }

    NDStoreCache(title, artist, artwork, trackID, isPlaying);
    NDApplyCachedToLayers();

    if (!artwork.length && (title.length || artist.length)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NDFetchNowPlaying();
        });
    }
}

static void NDFetchNowPlaying(void) {
    if (!gMRReady || gFetchInFlight) return;
    gFetchInFlight = YES;

    void (^finish)(CFDictionaryRef, Boolean) = ^(CFDictionaryRef info, Boolean playing) {
        gFetchInFlight = NO;
        NDApplyNowPlaying(info, playing);
    };

    if (gMR.getIsPlaying) {
        gMR.getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            gMR.getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
                finish(info, playing);
            });
        });
    } else {
        gMR.getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            finish(info, NO);
        });
    }
}

static void NDNowPlayingNotify(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        NDFetchNowPlaying();
    });
}

static void NDInstallNowPlayingObservers(void) {
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    if (gMR.noteInfoChanged) {
        CFNotificationCenterAddObserver(darwin, NULL, NDNowPlayingNotify, gMR.noteInfoChanged,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    if (gMR.notePlayingChanged) {
        CFNotificationCenterAddObserver(darwin, NULL, NDNowPlayingNotify, gMR.notePlayingChanged,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    if (gMR.noteAppChanged) {
        CFNotificationCenterAddObserver(darwin, NULL, NDNowPlayingNotify, gMR.noteAppChanged,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

static BOOL NDMRSend(int command) {
    if (!gMR.sendCommand)
        return NO;
    Boolean ok = gMR.sendCommand(command, NULL);
    return ok ? YES : NO;
}

static BOOL NDSendMediaKeyFallback(NDMediaAction action) {
    (void)action;
    return NO;
}

BOOL NDMediaPerformAction(NDMediaAction action) {
    static CFAbsoluteTime sLastActionTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastActionTime < 0.35)
        return YES;
    sLastActionTime = now;

    if (!NDLoadMediaRemote())
        return NO;

    int command = 0;
    switch (action) {
        case NDMediaActionPrevious:
            command = kNDMRCommandPreviousTrack;
            break;
        case NDMediaActionTogglePlayPause:
            command = kNDMRCommandTogglePlayPause;
            break;
        case NDMediaActionNext:
            command = kNDMRCommandNextTrack;
            break;
    }

    BOOL sent = NDMRSend(command);
    if (!sent)
        sent = NDSendMediaKeyFallback(action);
    if (!sent)
        return NO;

    if (action == NDMediaActionTogglePlayPause && gHasCache) {
        gCachedPlaying = !gCachedPlaying;
        NDApplyCachedToLayers();
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NDFetchNowPlaying();
    });
    return YES;
}

void NDMediaSetControlHitRects(CGRect prev, CGRect play, CGRect next) {
    gHitPrev = prev;
    gHitPlay = play;
    gHitNext = next;
}

static BOOL NDPointInHitRect(CGPoint p, CGRect r) {
    if (CGRectIsEmpty(r)) return NO;
    return CGRectContainsPoint(CGRectInset(r, -kNDMediaHitSlopPt, -kNDMediaHitSlopPt), p);
}

BOOL NDMediaHandleScreenClick(CGPoint cocoaScreenPt) {
    if (NDPointInHitRect(cocoaScreenPt, gHitPrev))
        return NDMediaPerformAction(NDMediaActionPrevious);
    if (NDPointInHitRect(cocoaScreenPt, gHitPlay))
        return NDMediaPerformAction(NDMediaActionTogglePlayPause);
    if (NDPointInHitRect(cocoaScreenPt, gHitNext))
        return NDMediaPerformAction(NDMediaActionNext);
    return NO;
}

static BOOL NDShellPointHits(CATextLayer *btn, CGPoint shellPoint) {
    if (!btn || btn.hidden) return NO;
    return CGRectContainsPoint(CGRectInset(btn.frame, -kNDMediaHitSlopPt, -kNDMediaHitSlopPt), shellPoint);
}

BOOL NDMediaHandleShellClick(CGPoint shellPoint) {
    if (NDShellPointHits(gPrev, shellPoint))
        return NDMediaPerformAction(NDMediaActionPrevious);
    if (NDShellPointHits(gPlay, shellPoint))
        return NDMediaPerformAction(NDMediaActionTogglePlayPause);
    if (NDShellPointHits(gNext, shellPoint))
        return NDMediaPerformAction(NDMediaActionNext);
    return NO;
}

void NDMediaBindLayers(CALayer *artwork, CALayer *titleClip, CATextLayer *title,
                       CALayer *artistClip, CATextLayer *artist,
                       CATextLayer *prev, CATextLayer *play, CATextLayer *next) {
    gArtwork = artwork;
    gTitleClip = titleClip;
    gTitle = title;
    gArtistClip = artistClip;
    gArtist = artist;
    gPrev = prev;
    gPlay = play;
    gNext = next;
    NDApplyCachedToLayers();
}

void NDMediaStart(void) {
    if (gMediaStarted) return;
    gMediaStarted = YES;
    if (!NDLoadMediaRemote()) {
        NDApplyIdleState();
        NDApplyCachedToLayers();
        return;
    }
    if (gMR.registerNotifications)
        gMR.registerNotifications(dispatch_get_main_queue());
    NDInstallNowPlayingObservers();
    NDFetchNowPlaying();

    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gPollTimer) {
        dispatch_source_set_timer(gPollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                  (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gPollTimer, ^{
            NDFetchNowPlaying();
        });
        dispatch_resume(gPollTimer);
    }
}

void NDMediaRelayout(void) {
    NDApplyCachedToLayers();
}

void NDMediaUpdateMarquee(CGRect titleClip, CGRect artistClip, BOOL compact) {
    gMarqueeTitleClip = titleClip;
    gMarqueeArtistClip = artistClip;
    gMarqueeCompact = compact;
    gMarqueeFramesValid = YES;
    NDApplyCachedToLayers();
}
