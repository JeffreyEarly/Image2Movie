//
//  ImagesToMovieController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovieController.h"
#import "ImagesToMovie.h"
#import "MovieFrameRenderer.h"
#import <math.h>

static char ImagePathObservationContext;
static BOOL ValidImageSize(NSSize size)
{
    return isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0 &&
        floor(size.width) == size.width && floor(size.height) == size.height;
}
static NSInteger ValidIntegerPreference(NSString *key, NSInteger minimum, NSInteger maximum, NSInteger fallback)
{
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number && number >= minimum && number <= maximum ?
        (NSInteger)number : fallback;
}

@interface ImagesToMovieController ()
@property NSUInteger firstFrameLoadGeneration;
@property NSInteger lastAutomaticQualityTag;
@end

@implementation ImagesToMovieController

+ (void)initialize
{
    if (self != [ImagesToMovieController class]) return;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"customMovieWidth": @1280, @"customMovieHeight": @720, @"defaultSizePreset": @0,
        @"defaultCodecTag": @1, @"defaultQualityTag": @(MovieQualityHigh), @"defaultFrameRate": @30
    }];
}

- (instancetype)init
{
    if ((self = [super init])) {
        _selectedCodecTag = ValidIntegerPreference(@"defaultCodecTag", 0, 2, 1);
        _selectedQualityTag = ValidIntegerPreference(@"defaultQualityTag", 0, 1, 1);
        _lastAutomaticQualityTag = _selectedQualityTag;
        _frameRate = ValidIntegerPreference(@"defaultFrameRate", 1, 30, 30);
        _bitRate = 20.0;
        NSInteger sizeTag = ValidIntegerPreference(@"defaultSizePreset", 0, 2160, 0);
        if (sizeTag != 0 && sizeTag != 1 && sizeTag != 480 && sizeTag != 720 && sizeTag != 1080 && sizeTag != 2160) sizeTag = 0;
        self.selectedSizePresetsTag = sizeTag;
    }
    return self;
}

- (void)awakeFromNib { [self frameRateOrSizeDidChange]; }
- (void)dealloc { [imagesToMovie removeObserver:self forKeyPath:@"imagePaths"]; }

@synthesize imagesToMovie;
@synthesize selectedSizePresetsTag;

- (void)setImagesToMovie:(ImagesToMovie *)model
{
    [imagesToMovie removeObserver:self forKeyPath:@"imagePaths"];
    imagesToMovie = model;
    [imagesToMovie addObserver:self forKeyPath:@"imagePaths" options:0 context:&ImagePathObservationContext];
    self.firstFramePath = nil;
    [self loadFirstFrame];
}

- (void)loadFirstFrame
{
    NSString *path = [self.imagesToMovie.imagePaths.firstObject copy];
    if (path && [path isEqualToString:self.firstFramePath]) { [self updateReadiness]; return; }
    NSUInteger generation = ++self.firstFrameLoadGeneration;
    self.firstFramePath = path;
    self.firstFrameSize = NSZeroSize;
    [self updateOriginalSizeFields];
    [self frameRateOrSizeDidChange];
    if (!path) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSSize size = [MovieFrameRenderer imageSizeAtPath:path error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.firstFrameLoadGeneration) return;
            self.firstFrameSize = size;
            [self updateOriginalSizeFields];
            [self frameRateOrSizeDidChange];
        });
    });
}

- (void)updateOriginalSizeFields
{
    if (self.selectedSizePresetsTag != 0) return;
    [self willChangeValueForKey:@"width"];
    [self willChangeValueForKey:@"height"];
    _width = @(self.firstFrameSize.width); _height = @(self.firstFrameSize.height);
    [self didChangeValueForKey:@"height"];
    [self didChangeValueForKey:@"width"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &ImagePathObservationContext) [self loadFirstFrame];
    else [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (NSSize)targetSize
{
    if (!ValidImageSize(self.firstFrameSize)) return NSZeroSize;
    NSSize limit = NSMakeSize(self.width.doubleValue, self.height.doubleValue);
    if (!ValidImageSize(limit)) return NSZeroSize;
    return self.selectedSizePresetsTag == 0 ? self.firstFrameSize : [self.imagesToMovie resizeOriginal:self.firstFrameSize intoTargetSize:limit withTolerance:NO];
}

- (void)updateReadiness
{
    NSSize target = [self targetSize];
    BOOL validRate = isfinite(self.bitRate) && self.bitRate >= 0.1 && self.bitRate <= 50.0;
    self.readyToCreateMovie = self.imagesToMovie.imagePaths.count > 0 &&
        [self.firstFramePath isEqualToString:self.imagesToMovie.imagePaths.firstObject] &&
        ValidImageSize(target) && target.width <= 3840 && target.height <= 2160 &&
        self.frameRate >= 1 && self.frameRate <= 30 && self.codec != nil &&
        (!self.qualityControlsVisible || self.selectedQualityTag != MovieQualityCustomBitrate || validRate);
}

+ (NSSet *)keyPathsForValuesAffectingCodec { return [NSSet setWithObject:@"selectedCodecTag"]; }
+ (NSSet *)keyPathsForValuesAffectingQualityControlsVisible { return [NSSet setWithObject:@"selectedCodecTag"]; }
+ (NSSet *)keyPathsForValuesAffectingAutomaticBitRateVisible { return [NSSet setWithObjects:@"selectedCodecTag", @"selectedQualityTag", nil]; }
+ (NSSet *)keyPathsForValuesAffectingCustomBitRateEnabled { return [NSSet setWithObjects:@"selectedCodecTag", @"selectedQualityTag", nil]; }

- (NSString *)codec
{
    switch (self.selectedCodecTag) {
        case 0: return AVVideoCodecTypeH264;
        case 1: return AVVideoCodecTypeHEVC;
        case 2: return AVVideoCodecTypeAppleProRes422;
        default: return nil;
    }
}

- (BOOL)qualityControlsVisible { return self.selectedCodecTag != 2; }
- (BOOL)automaticBitRateVisible { return self.qualityControlsVisible && self.selectedQualityTag != MovieQualityCustomBitrate; }
- (BOOL)customBitRateEnabled { return self.qualityControlsVisible && self.selectedQualityTag == MovieQualityCustomBitrate; }

- (void)setSelectedCodecTag:(NSInteger)tag
{
    if (_selectedCodecTag == tag) return;
    _selectedCodecTag = tag;
    if (tag >= 0 && tag <= 2) [[NSUserDefaults standardUserDefaults] setObject:@(tag) forKey:@"defaultCodecTag"];
    if (_selectedQualityTag == MovieQualityCustomBitrate) self.selectedQualityTag = self.lastAutomaticQualityTag;
    [self frameRateOrSizeDidChange];
}

- (void)setSelectedQualityTag:(NSInteger)tag
{
    if (tag < MovieQualityStandard || tag > MovieQualityCustomBitrate) tag = MovieQualityHigh;
    if (_selectedQualityTag == tag) { [self updateReadiness]; return; }
    _selectedQualityTag = tag;
    if (tag == MovieQualityStandard || tag == MovieQualityHigh) {
        self.lastAutomaticQualityTag = tag;
        [[NSUserDefaults standardUserDefaults] setObject:@(tag) forKey:@"defaultQualityTag"];
    }
    [self updateReadiness];
}

- (void)frameRateOrSizeDidChange { [self updateReadiness]; }

- (void)updateModelWithNewSettings
{
    self.imagesToMovie.codec = self.codec;
    self.imagesToMovie.frameSize = [self targetSize];
    self.imagesToMovie.frameRate = self.frameRate;
    self.imagesToMovie.qualityMode = (MovieQualityMode)self.selectedQualityTag;
    if (self.selectedQualityTag == MovieQualityCustomBitrate && isfinite(self.bitRate))
        self.imagesToMovie.averageBitRate = (NSUInteger)llround(self.bitRate * 1000000.0);
}

- (void)setSelectedSizePresetsTag:(NSInteger)tag
{
    if (selectedSizePresetsTag == tag && self.width && self.height) return;
    selectedSizePresetsTag = tag;
    [self willChangeValueForKey:@"width"];
    [self willChangeValueForKey:@"height"];
    if (tag == 0) { _width = @(self.firstFrameSize.width); _height = @(self.firstFrameSize.height); }
    else if (tag == 480) { _width = @640; _height = @480; }
    else if (tag == 720) { _width = @1280; _height = @720; }
    else if (tag == 1080) { _width = @1920; _height = @1080; }
    else if (tag == 2160) { _width = @3840; _height = @2160; }
    else { _width = [[NSUserDefaults standardUserDefaults] objectForKey:@"customMovieWidth"]; _height = [[NSUserDefaults standardUserDefaults] objectForKey:@"customMovieHeight"]; }
    [self didChangeValueForKey:@"height"];
    [self didChangeValueForKey:@"width"];
    self.customFieldsAreEnabled = tag == 1;
    [self frameRateOrSizeDidChange];
    [[NSUserDefaults standardUserDefaults] setObject:@(tag) forKey:@"defaultSizePreset"];
}

- (void)setWidth:(NSNumber *)value
{
    value = [value isKindOfClass:NSNumber.class] ? value : @0;
    if ([_width isEqual:value]) return;
    _width = value;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:@"customMovieWidth"];
    [self updateReadiness];
}

- (void)setHeight:(NSNumber *)value
{
    value = [value isKindOfClass:NSNumber.class] ? value : @0;
    if ([_height isEqual:value]) return;
    _height = value;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:@"customMovieHeight"];
    [self updateReadiness];
}

- (void)setFrameRate:(NSUInteger)value
{
    if (_frameRate == value) return;
    _frameRate = value;
    if (value >= 1 && value <= 30)
        [[NSUserDefaults standardUserDefaults] setObject:@(value) forKey:@"defaultFrameRate"];
    [self updateReadiness];
}

- (void)setBitRate:(CGFloat)value
{
    _bitRate = value;
    [self updateReadiness];
}

@end
