#import "LiveNanjingView.h"

#import "LiveStreamService.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const LNModuleName = @"com.jomic.LiveNanjing";
static NSString *const LNWebsiteURL = @"https://m2.nbs.cn/eventlive/280714.html";
static NSString *const LNModeKey = @"PlaybackMode";
static NSString *const LNIntervalKey = @"SwitchIntervalMinutes";
static NSString *const LNNameDisplayModeKey = @"NameDisplayMode";
static NSString *const LNLegacyShowNameKey = @"ShowStreamName";
static NSString *const LNShowMapKey = @"ShowLocationMap";
static NSString *const LNForceBlackAndWhiteKey = @"ForceBlackAndWhite";

@interface LiveNanjingView ()
@property(nonatomic, strong) LiveStreamService *streamService;
@property(nonatomic, strong, nullable) AVPlayer *activePlayer;
@property(nonatomic, strong, nullable) AVPlayerLayer *activeLayer;
@property(nonatomic, strong, nullable) LNLiveStream *activeStream;
@property(nonatomic, strong, nullable) AVPlayer *pendingPlayer;
@property(nonatomic, strong, nullable) AVPlayerLayer *pendingLayer;
@property(nonatomic, strong, nullable) LNLiveStream *pendingStream;
@property(nonatomic, strong) CATextLayer *nameLayer;
@property(nonatomic, strong) CATextLayer *statusLayer;
@property(nonatomic, strong) CALayer *mapLayer;
@property(nonatomic, strong) CAShapeLayer *mapBoundaryLayer;
@property(nonatomic, strong) CAShapeLayer *mapMarkerLayer;
@property(nonatomic, strong) CAShapeLayer *mapMarkerPulseLayer;
@property(nonatomic, copy) NSArray<NSArray<NSArray<NSNumber *> *> *> *mapRings;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL fetching;
@property(nonatomic) CFTimeInterval pendingStartTime;
@property(nonatomic) CFTimeInterval nextSwitchTime;
@property(nonatomic) CFTimeInterval lastProgressTime;
@property(nonatomic) Float64 lastPlaybackSeconds;
@property(nonatomic) NSUInteger nameDisplayGeneration;
@property(nonatomic) NSUInteger mapDisplayGeneration;
@property(nonatomic, strong, nullable) NSPanel *configurationPanel;
@property(nonatomic, strong, nullable) NSButton *keepButton;
@property(nonatomic, strong, nullable) NSButton *rotateButton;
@property(nonatomic, strong, nullable) NSPopUpButton *intervalPopup;
@property(nonatomic, strong, nullable) NSPopUpButton *nameDisplayPopup;
@property(nonatomic, strong, nullable) NSButton *showMapButton;
@property(nonatomic, strong, nullable) NSButton *blackAndWhiteButton;
@end

@implementation LiveNanjingView

+ (void)initialize
{
    if (self != LiveNanjingView.class) return;
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:LNModuleName];
    if (![defaults objectForKey:LNNameDisplayModeKey]) {
        NSNumber *legacyValue = [defaults objectForKey:LNLegacyShowNameKey];
        NSString *initialMode = legacyValue ? (legacyValue.boolValue ? @"always" : @"hidden") : @"fade";
        [defaults setObject:initialMode forKey:LNNameDisplayModeKey];
    }
    [defaults registerDefaults:@{
        LNModeKey: @"rotate",
        LNIntervalKey: @10,
        LNNameDisplayModeKey: @"fade",
        LNShowMapKey: @YES,
        LNForceBlackAndWhiteKey: @NO,
    }];
    [defaults synchronize];
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0 / 30.0;
        self.wantsLayer = YES;
        self.layerUsesCoreImageFilters = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.streamService = [[LiveStreamService alloc] init];

        _nameLayer = [CATextLayer layer];
        _nameLayer.alignmentMode = kCAAlignmentLeft;
        _nameLayer.truncationMode = kCATruncationEnd;
        _nameLayer.wrapped = YES;
        _nameLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
        _nameLayer.foregroundColor = NSColor.whiteColor.CGColor;
        _nameLayer.backgroundColor = NSColor.clearColor.CGColor;
        _nameLayer.shadowOpacity = 0.0;
        _nameLayer.zPosition = 100.0;
        [self.layer addSublayer:_nameLayer];

        _statusLayer = [CATextLayer layer];
        _statusLayer.alignmentMode = kCAAlignmentRight;
        _statusLayer.truncationMode = kCATruncationStart;
        _statusLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
        _statusLayer.foregroundColor = [NSColor colorWithWhite:1.0 alpha:0.82].CGColor;
        _statusLayer.backgroundColor = NSColor.clearColor.CGColor;
        _statusLayer.shadowOpacity = 0.0;
        _statusLayer.zPosition = 101.0;
        _statusLayer.hidden = YES;
        [self.layer addSublayer:_statusLayer];

        [self setupMapOverlay];
        [self layoutLayers];
    }
    return self;
}

- (ScreenSaverDefaults *)defaults
{
    return [ScreenSaverDefaults defaultsForModuleWithName:LNModuleName];
}

- (BOOL)rotatesStreams
{
    return ![[[self defaults] stringForKey:LNModeKey] isEqualToString:@"keep"];
}

- (NSTimeInterval)switchInterval
{
    NSInteger minutes = [[self defaults] integerForKey:LNIntervalKey];
    return MAX(1, minutes) * 60.0;
}

- (NSString *)nameDisplayMode
{
    NSString *mode = [[self defaults] stringForKey:LNNameDisplayModeKey];
    return [@[@"hidden", @"always", @"fade"] containsObject:mode] ? mode : @"fade";
}

- (BOOL)showsLocationMap
{
    return [[self defaults] boolForKey:LNShowMapKey];
}

- (BOOL)usesBlackAndWhiteVideo
{
    return [[self defaults] boolForKey:LNForceBlackAndWhiteKey];
}

- (NSArray<CIFilter *> *)videoFilters
{
    if (![self usesBlackAndWhiteVideo]) return @[];
    CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
    [filter setValue:@0.0 forKey:kCIInputSaturationKey];
    return filter ? @[filter] : @[];
}

- (void)applyVideoColorMode
{
    self.activeLayer.filters = [self videoFilters];
    self.pendingLayer.filters = [self videoFilters];
}

- (void)setupMapOverlay
{
    _mapLayer = [CALayer layer];
    _mapLayer.zPosition = 90.0;
    _mapLayer.opacity = 0.0;

    _mapBoundaryLayer = [CAShapeLayer layer];
    _mapBoundaryLayer.fillColor = [NSColor colorWithWhite:0.0 alpha:0.16].CGColor;
    _mapBoundaryLayer.strokeColor = [NSColor colorWithWhite:1.0 alpha:0.72].CGColor;
    _mapBoundaryLayer.lineWidth = 1.0;
    _mapBoundaryLayer.lineJoin = kCALineJoinRound;
    _mapBoundaryLayer.fillRule = kCAFillRuleEvenOdd;
    [_mapLayer addSublayer:_mapBoundaryLayer];

    _mapMarkerPulseLayer = [CAShapeLayer layer];
    _mapMarkerPulseLayer.fillColor = NSColor.clearColor.CGColor;
    _mapMarkerPulseLayer.strokeColor = [NSColor colorWithRed:1.0 green:0.27 blue:0.18 alpha:0.95].CGColor;
    _mapMarkerPulseLayer.lineWidth = 1.5;
    [_mapLayer addSublayer:_mapMarkerPulseLayer];

    _mapMarkerLayer = [CAShapeLayer layer];
    _mapMarkerLayer.fillColor = [NSColor colorWithRed:1.0 green:0.27 blue:0.18 alpha:1.0].CGColor;
    _mapMarkerLayer.strokeColor = NSColor.whiteColor.CGColor;
    _mapMarkerLayer.lineWidth = 1.2;
    [_mapLayer addSublayer:_mapMarkerLayer];
    [self.layer addSublayer:_mapLayer];

    NSURL *URL = [[NSBundle bundleForClass:self.class] URLForResource:@"nanjing-boundaries" withExtension:@"json"];
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL] : nil;
    NSDictionary *map = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *rings = [map[@"rings"] isKindOfClass:NSArray.class] ? map[@"rings"] : nil;
    _mapRings = rings ?: @[];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self layoutLayers];
}

- (void)layoutLayers
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.activeLayer.frame = self.bounds;
    self.pendingLayer.frame = self.bounds;
    BOOL compact = NSWidth(self.bounds) < 500.0;
    CGFloat inset = compact ? 12.0 : 32.0;
    CGFloat height = compact ? 40.0 : 64.0;
    CGFloat mapHeight = compact ? MIN(105.0, NSHeight(self.bounds) * 0.42)
                                : MIN(300.0, MAX(180.0, NSHeight(self.bounds) * 0.28));
    CGFloat mapAspect = ((119.241663 - 118.363373) * cos(32.0 * M_PI / 180.0)) /
                        (32.614363 - 31.228097);
    CGFloat mapWidth = mapHeight * mapAspect;
    self.mapLayer.frame = NSMakeRect(NSWidth(self.bounds) - inset - mapWidth, inset, mapWidth, mapHeight);
    self.mapBoundaryLayer.frame = self.mapLayer.bounds;
    self.mapMarkerLayer.frame = self.mapLayer.bounds;
    self.mapMarkerPulseLayer.frame = self.mapLayer.bounds;
    [self updateMapBoundaryPath];
    BOOL showMap = [self showsLocationMap] && self.mapRings.count > 0;
    self.mapLayer.hidden = !showMap;
    self.nameLayer.frame = NSMakeRect(inset, inset, MAX(80.0, NSWidth(self.bounds) - inset * 2.0), height);
    CGFloat statusHeight = compact ? 20.0 : 28.0;
    self.statusLayer.frame = NSMakeRect(MAX(inset, NSWidth(self.bounds) - inset - (compact ? 280.0 : 520.0)),
                                        inset,
                                        MIN(compact ? 280.0 : 520.0, NSWidth(self.bounds) - inset * 2.0),
                                        statusHeight);
    [CATransaction commit];
    [self updateNameOverlay];
    [self updateMapMarker];
}

- (void)setStatusText:(nullable NSString *)text
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!text.length) {
        self.statusLayer.string = nil;
        self.statusLayer.hidden = YES;
    } else {
        BOOL compact = NSWidth(self.bounds) < 500.0;
        CGFloat size = compact ? 10.0 : 15.0;
        NSFont *font = [NSFont fontWithName:@"PingFangSC-Regular" size:size]
                       ?: [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
        self.statusLayer.string = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.82],
        }];
        self.statusLayer.hidden = NO;
    }
    [CATransaction commit];
}

- (NSString *)shortStreamName:(NSString *)name
{
    NSRange separator = [name rangeOfString:@"-"];
    NSString *shortName = separator.location == NSNotFound ? name : [name substringToIndex:separator.location];
    return [shortName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)updateMapBoundaryPath
{
    if (!self.mapRings.count || NSWidth(self.mapLayer.bounds) <= 0.0) return;
    CGFloat padding = NSWidth(self.bounds) < 500.0 ? 2.0 : 4.0;
    CGFloat width = MAX(1.0, NSWidth(self.mapLayer.bounds) - padding * 2.0);
    CGFloat height = MAX(1.0, NSHeight(self.mapLayer.bounds) - padding * 2.0);
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSArray<NSArray<NSNumber *> *> *ring in self.mapRings) {
        BOOL first = YES;
        for (NSArray<NSNumber *> *coordinate in ring) {
            if (coordinate.count < 2) continue;
            CGPoint point = CGPointMake(padding + coordinate[0].doubleValue / 10000.0 * width,
                                        padding + coordinate[1].doubleValue / 10000.0 * height);
            if (first) {
                CGPathMoveToPoint(path, NULL, point.x, point.y);
                first = NO;
            } else {
                CGPathAddLineToPoint(path, NULL, point.x, point.y);
            }
        }
        if (!first) CGPathCloseSubpath(path);
    }
    self.mapBoundaryLayer.path = path;
    CGPathRelease(path);
}

- (void)updateMapMarker
{
    double latitude = self.activeStream.latitude;
    double longitude = self.activeStream.longitude;
    BOOL valid = isfinite(latitude) && isfinite(longitude) &&
                 latitude >= 31.228097 && latitude <= 32.614363 &&
                 longitude >= 118.363373 && longitude <= 119.241663;
    self.mapMarkerLayer.hidden = !valid;
    self.mapMarkerPulseLayer.hidden = !valid;
    if (!valid) return;

    CGFloat padding = NSWidth(self.bounds) < 500.0 ? 2.0 : 4.0;
    CGFloat width = MAX(1.0, NSWidth(self.mapLayer.bounds) - padding * 2.0);
    CGFloat height = MAX(1.0, NSHeight(self.mapLayer.bounds) - padding * 2.0);
    CGPoint point = CGPointMake(padding + (longitude - 118.363373) / (119.241663 - 118.363373) * width,
                                padding + (latitude - 31.228097) / (32.614363 - 31.228097) * height);
    CGFloat radius = NSWidth(self.bounds) < 500.0 ? 2.6 : 4.0;
    CGPathRef markerPath = CGPathCreateWithEllipseInRect(CGRectMake(point.x - radius, point.y - radius,
                                                                    radius * 2.0, radius * 2.0), NULL);
    self.mapMarkerLayer.path = markerPath;
    CGPathRelease(markerPath);
    CGPathRef pulsePath = CGPathCreateWithEllipseInRect(CGRectMake(point.x - radius * 2.0,
                                                                   point.y - radius * 2.0,
                                                                   radius * 4.0, radius * 4.0), NULL);
    self.mapMarkerPulseLayer.path = pulsePath;
    CGPathRelease(pulsePath);
    [self.mapMarkerPulseLayer removeAnimationForKey:@"pulse"];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.15;
    pulse.duration = 1.25;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.mapMarkerPulseLayer addAnimation:pulse forKey:@"pulse"];
}

- (void)showMapOverlayAndScheduleFade
{
    self.mapDisplayGeneration++;
    NSUInteger generation = self.mapDisplayGeneration;
    if (![self showsLocationMap] || !self.activeStream || !self.mapRings.count) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.mapLayer.opacity = 0.0;
        [CATransaction commit];
        return;
    }

    [self.mapLayer removeAnimationForKey:@"opacity"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.mapLayer.opacity = 1.0;
    [CATransaction commit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.running || generation != self.mapDisplayGeneration || ![self showsLocationMap]) return;
        [CATransaction begin];
        [CATransaction setAnimationDuration:1.2];
        self.mapLayer.opacity = 0.0;
        [CATransaction commit];
    });
}

- (void)startAnimation
{
    [super startAnimation];
    if (self.running) return;
    self.running = YES;
    [self setStatusText:[self localized:@"StatusFetching"]];
    [self requestStreamChange];
}

- (void)stopAnimation
{
    self.running = NO;
    self.fetching = NO;
    [self.streamService cancel];
    [self.activePlayer pause];
    [self.pendingPlayer pause];
    [self.activeLayer removeFromSuperlayer];
    [self.pendingLayer removeFromSuperlayer];
    self.activePlayer = nil;
    self.pendingPlayer = nil;
    self.activeLayer = nil;
    self.pendingLayer = nil;
    self.activeStream = nil;
    self.pendingStream = nil;
    self.nameDisplayGeneration++;
    self.mapDisplayGeneration++;
    self.nameLayer.string = nil;
    [self setStatusText:nil];
    [self.mapMarkerPulseLayer removeAllAnimations];
    [self updateMapMarker];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.mapLayer.opacity = 0.0;
    [CATransaction commit];
    [super stopAnimation];
}

- (void)requestStreamChange
{
    if (!self.running || self.fetching || self.pendingPlayer) return;
    self.fetching = YES;
    [self setStatusText:[self localized:(self.activePlayer ? @"StatusFindingNext" : @"StatusFetching")]];
    __weak typeof(self) weakSelf = self;
    [self.streamService fetchRandomStreamExcludingName:self.activeStream.name URL:self.activeStream.URL completion:^(LNLiveStream *stream, NSError *error) {
        (void)error;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.running) return;
        self.fetching = NO;
        if (!stream) {
            [self setStatusText:[self localized:@"StatusRetrying"]];
            NSTimeInterval delay = self.activePlayer ? 30.0 : 5.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.running) [self requestStreamChange];
            });
            return;
        }
        [self prepareStream:stream];
    }];
}

- (void)prepareStream:(LNLiveStream *)stream
{
    NSString *place = [self shortStreamName:stream.name];
    [self setStatusText:[NSString stringWithFormat:[self localized:@"StatusConnectingFormat"], place]];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:stream.URL];
    item.preferredForwardBufferDuration = 3.0;
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.muted = YES;
    player.automaticallyWaitsToMinimizeStalling = YES;

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.frame = self.bounds;
    layer.opacity = 0.01;
    layer.zPosition = 1.0;
    layer.filters = [self videoFilters];
    [self.layer addSublayer:layer];

    self.pendingStream = stream;
    self.pendingPlayer = player;
    self.pendingLayer = layer;
    self.pendingStartTime = CACurrentMediaTime();
    [player play];
}

- (void)discardPendingStreamAndRetry
{
    [self setStatusText:[self localized:@"StatusConnectionFailed"]];
    [self.pendingPlayer pause];
    [self.pendingLayer removeFromSuperlayer];
    self.pendingPlayer = nil;
    self.pendingLayer = nil;
    self.pendingStream = nil;
    if (self.running) [self requestStreamChange];
}

- (void)promotePendingStream
{
    AVPlayer *oldPlayer = self.activePlayer;
    AVPlayerLayer *oldLayer = self.activeLayer;
    AVPlayerLayer *newLayer = self.pendingLayer;

    self.activePlayer = self.pendingPlayer;
    self.activeLayer = newLayer;
    self.activeStream = self.pendingStream;
    self.pendingPlayer = nil;
    self.pendingLayer = nil;
    self.pendingStream = nil;
    self.lastPlaybackSeconds = 0;
    self.lastProgressTime = CACurrentMediaTime();
    self.nextSwitchTime = self.lastProgressTime + [self switchInterval];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.6];
    newLayer.opacity = 1.0;
    oldLayer.opacity = 0.0;
    [CATransaction commit];

    [self updateNameOverlay];
    [self updateMapMarker];
    [self setStatusText:nil];
    [self showMapOverlayAndScheduleFade];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [oldPlayer pause];
        [oldLayer removeFromSuperlayer];
    });
}

- (void)updateNameOverlay
{
    self.nameDisplayGeneration++;
    NSUInteger generation = self.nameDisplayGeneration;
    NSString *mode = [self nameDisplayMode];
    NSString *name = self.activeStream.name;
    if (!name.length || [mode isEqualToString:@"hidden"]) {
        self.nameLayer.hidden = YES;
        self.nameLayer.string = nil;
        return;
    }

    BOOL compact = NSWidth(self.bounds) < 500.0;
    CGFloat titleSize = compact ? 13.0 : 22.0;
    CGFloat detailSize = compact ? 10.0 : 15.0;
    NSFont *titleFont = [NSFont fontWithName:@"PingFangSC-Semibold" size:titleSize]
                        ?: [NSFont systemFontOfSize:titleSize weight:NSFontWeightSemibold];
    NSFont *detailFont = [NSFont fontWithName:@"PingFangSC-Regular" size:detailSize]
                         ?: [NSFont systemFontOfSize:detailSize weight:NSFontWeightRegular];
    NSRange separator = [name rangeOfString:@"-"];
    NSString *title = name;
    NSString *detail = @"";
    if (separator.location != NSNotFound) {
        NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        title = [[name substringToIndex:separator.location] stringByTrimmingCharactersInSet:whitespace];
        detail = [[name substringFromIndex:NSMaxRange(separator)] stringByTrimmingCharactersInSet:whitespace];
    }
    NSString *displayName = detail.length ? [NSString stringWithFormat:@"%@\n%@", title, detail] : title;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineSpacing = compact ? 0.0 : 2.0;
    NSMutableAttributedString *attributedName = [[NSMutableAttributedString alloc] initWithString:displayName attributes:@{
        NSFontAttributeName: titleFont,
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSParagraphStyleAttributeName: paragraph,
    }];
    if (detail.length) {
        NSRange detailRange = NSMakeRange(title.length + 1, detail.length);
        [attributedName addAttributes:@{
            NSFontAttributeName: detailFont,
            NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.82],
        } range:detailRange];
    }
    self.nameLayer.string = attributedName;
    self.nameLayer.hidden = NO;
    [self.nameLayer removeAnimationForKey:@"opacity"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.nameLayer.opacity = 1.0;
    [CATransaction commit];

    if ([mode isEqualToString:@"fade"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.running || generation != self.nameDisplayGeneration || ![[self nameDisplayMode] isEqualToString:@"fade"]) return;
            [CATransaction begin];
            [CATransaction setAnimationDuration:1.2];
            self.nameLayer.opacity = 0.0;
            [CATransaction commit];
        });
    }
}

- (void)animateOneFrame
{
    if (!self.running) return;
    CFTimeInterval now = CACurrentMediaTime();

    if (self.pendingPlayer) {
        AVPlayerItem *item = self.pendingPlayer.currentItem;
        if (item.status == AVPlayerItemStatusFailed || now - self.pendingStartTime > 15.0) {
            [self discardPendingStreamAndRetry];
        } else if (item.status == AVPlayerItemStatusReadyToPlay && self.pendingLayer.readyForDisplay) {
            [self promotePendingStream];
        }
    }

    if (self.activePlayer && !self.pendingPlayer && !self.fetching) {
        Float64 seconds = CMTimeGetSeconds(self.activePlayer.currentTime);
        if (isfinite(seconds) && seconds > self.lastPlaybackSeconds + 0.05) {
            self.lastPlaybackSeconds = seconds;
            self.lastProgressTime = now;
        }
        if (self.activePlayer.currentItem.status == AVPlayerItemStatusFailed || now - self.lastProgressTime > 20.0) {
            [self requestStreamChange];
        } else if ([self rotatesStreams] && now >= self.nextSwitchTime) {
            [self requestStreamChange];
        }
    }
}

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (NSString *)localized:(NSString *)key
{
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    return [bundle localizedStringForKey:key value:key table:nil];
}

- (NSTextField *)labelWithTitle:(NSString *)title frame:(NSRect)frame
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = title;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

- (NSWindow *)configureSheet
{
    if (self.configurationPanel) return self.configurationPanel;

    NSRect frame = NSMakeRect(0, 0, 430, 320);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = [self localized:@"SettingsTitle"];
    NSView *content = panel.contentView;

    [content addSubview:[self labelWithTitle:[self localized:@"PlaybackLabel"] frame:NSMakeRect(24, 274, 380, 22)]];

    self.keepButton = [[NSButton alloc] initWithFrame:NSMakeRect(38, 241, 350, 24)];
    self.keepButton.buttonType = NSButtonTypeRadio;
    self.keepButton.title = [self localized:@"KeepStream"];
    self.keepButton.target = self;
    self.keepButton.action = @selector(playbackModeChanged:);
    self.keepButton.tag = 0;
    [content addSubview:self.keepButton];

    self.rotateButton = [[NSButton alloc] initWithFrame:NSMakeRect(38, 209, 210, 24)];
    self.rotateButton.buttonType = NSButtonTypeRadio;
    self.rotateButton.title = [self localized:@"RotateStream"];
    self.rotateButton.target = self;
    self.rotateButton.action = @selector(playbackModeChanged:);
    self.rotateButton.tag = 1;
    [content addSubview:self.rotateButton];

    self.intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(255, 206, 120, 28) pullsDown:NO];
    for (NSNumber *minutes in @[@1, @5, @10, @15, @30]) {
        NSString *title = [NSString stringWithFormat:[self localized:@"MinutesFormat"], minutes.integerValue];
        [self.intervalPopup addItemWithTitle:title];
        self.intervalPopup.lastItem.representedObject = minutes;
    }
    [content addSubview:self.intervalPopup];

    [content addSubview:[self labelWithTitle:[self localized:@"NameDisplayLabel"] frame:NSMakeRect(24, 170, 219, 22)]];
    self.nameDisplayPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(255, 166, 120, 28) pullsDown:NO];
    NSArray<NSArray<NSString *> *> *nameModes = @[
        @[@"NameDisplayHidden", @"hidden"],
        @[@"NameDisplayAlways", @"always"],
        @[@"NameDisplayFade", @"fade"],
    ];
    for (NSArray<NSString *> *entry in nameModes) {
        [self.nameDisplayPopup addItemWithTitle:[self localized:entry[0]]];
        self.nameDisplayPopup.lastItem.representedObject = entry[1];
    }
    [content addSubview:self.nameDisplayPopup];

    [content addSubview:[self labelWithTitle:[self localized:@"MapDisplayLabel"] frame:NSMakeRect(24, 129, 219, 22)]];
    self.showMapButton = [[NSButton alloc] initWithFrame:NSMakeRect(255, 127, 120, 24)];
    self.showMapButton.buttonType = NSButtonTypeSwitch;
    self.showMapButton.title = [self localized:@"Show"];
    [content addSubview:self.showMapButton];

    self.blackAndWhiteButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 86, 351, 24)];
    self.blackAndWhiteButton.buttonType = NSButtonTypeSwitch;
    self.blackAndWhiteButton.title = [self localized:@"ForceBlackAndWhite"];
    [content addSubview:self.blackAndWhiteButton];

    NSButton *websiteButton = [[NSButton alloc] initWithFrame:NSMakeRect(268, 60, 140, 22)];
    websiteButton.bordered = NO;
    websiteButton.alignment = NSTextAlignmentRight;
    websiteButton.focusRingType = NSFocusRingTypeNone;
    websiteButton.attributedTitle = [[NSAttributedString alloc] initWithString:[self localized:@"WebsiteLink"] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12.0],
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    }];
    websiteButton.target = self;
    websiteButton.action = @selector(openWebsite:);
    [content addSubview:websiteButton];

    NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(224, 20, 90, 32)];
    cancel.title = [self localized:@"Cancel"];
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.target = self;
    cancel.action = @selector(cancelConfiguration:);
    [content addSubview:cancel];

    NSButton *OK = [[NSButton alloc] initWithFrame:NSMakeRect(318, 20, 90, 32)];
    OK.title = [self localized:@"OK"];
    OK.bezelStyle = NSBezelStyleRounded;
    OK.keyEquivalent = @"\r";
    OK.target = self;
    OK.action = @selector(saveConfiguration:);
    [content addSubview:OK];

    self.configurationPanel = panel;
    [self loadConfigurationControls];
    return panel;
}

- (void)openWebsite:(id)sender
{
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:LNWebsiteURL]];
}

- (void)loadConfigurationControls
{
    BOOL rotates = [self rotatesStreams];
    self.keepButton.state = rotates ? NSControlStateValueOff : NSControlStateValueOn;
    self.rotateButton.state = rotates ? NSControlStateValueOn : NSControlStateValueOff;
    self.intervalPopup.enabled = rotates;
    NSInteger configuredMinutes = [[self defaults] integerForKey:LNIntervalKey];
    for (NSMenuItem *item in self.intervalPopup.itemArray) {
        if ([item.representedObject integerValue] == configuredMinutes) {
            [self.intervalPopup selectItem:item];
            break;
        }
    }
    NSString *nameMode = [self nameDisplayMode];
    for (NSMenuItem *item in self.nameDisplayPopup.itemArray) {
        if ([item.representedObject isEqualToString:nameMode]) {
            [self.nameDisplayPopup selectItem:item];
            break;
        }
    }
    self.showMapButton.state = [self showsLocationMap] ? NSControlStateValueOn : NSControlStateValueOff;
    self.blackAndWhiteButton.state = [self usesBlackAndWhiteVideo] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)playbackModeChanged:(NSButton *)sender
{
    BOOL rotates = sender.tag == 1;
    self.keepButton.state = rotates ? NSControlStateValueOff : NSControlStateValueOn;
    self.rotateButton.state = rotates ? NSControlStateValueOn : NSControlStateValueOff;
    self.intervalPopup.enabled = rotates;
}

- (void)cancelConfiguration:(id)sender
{
    [self loadConfigurationControls];
    [NSApp endSheet:self.configurationPanel returnCode:NSModalResponseCancel];
}

- (void)saveConfiguration:(id)sender
{
    ScreenSaverDefaults *defaults = [self defaults];
    [defaults setObject:(self.rotateButton.state == NSControlStateValueOn ? @"rotate" : @"keep") forKey:LNModeKey];
    [defaults setInteger:[self.intervalPopup.selectedItem.representedObject integerValue] forKey:LNIntervalKey];
    [defaults setObject:self.nameDisplayPopup.selectedItem.representedObject forKey:LNNameDisplayModeKey];
    [defaults setBool:(self.showMapButton.state == NSControlStateValueOn) forKey:LNShowMapKey];
    [defaults setBool:(self.blackAndWhiteButton.state == NSControlStateValueOn) forKey:LNForceBlackAndWhiteKey];
    [defaults synchronize];
    self.nextSwitchTime = CACurrentMediaTime() + [self switchInterval];
    [self updateNameOverlay];
    [self layoutLayers];
    [self showMapOverlayAndScheduleFade];
    [self applyVideoColorMode];
    [NSApp endSheet:self.configurationPanel returnCode:NSModalResponseOK];
}

@end
