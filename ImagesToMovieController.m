//
//  ImagesToMovieController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovieController.h"
#import "ImagesToMovie.h"
#import <math.h>

static NSString * ImagePathObservationContext = @"ImagePathObservationContext";
static NSString * SelectedProfileObservationContext = @"SelectedProfileObservationContext";

static BOOL ValidImageSize(NSSize size)
{
    return isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0 &&
        floor(size.width) == size.width && floor(size.height) == size.height;
}

static NSSize ImagePixelSize(NSImage *image)
{
    if (!image.isValid) return NSZeroSize;

    NSSize pixelSize = NSZeroSize;
    BOOL hasBitmap = NO;
    for (NSImageRep *representation in image.representations) {
        if ([representation isKindOfClass:[NSBitmapImageRep class]]) {
            hasBitmap = YES;
            NSBitmapImageRep *bitmap = (NSBitmapImageRep *)representation;
            NSSize size = NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh);
            if (ValidImageSize(size) && bitmap.CGImage &&
                size.width * size.height > pixelSize.width * pixelSize.height) {
                pixelSize = size;
            }
        }
    }
    // Vector images have no fixed raster size; use their natural size in pixels.
    return hasBitmap ? pixelSize : NSMakeSize(round(image.size.width), round(image.size.height));
}

@interface ImagesToMovieController ()
@property NSUInteger firstFrameLoadGeneration;
@property BOOL updatingProfiles;
@property BOOL observingProfileSelection;
@end

@implementation ImagesToMovieController

+ (void)initialize
{
    if (self != [ImagesToMovieController class]) return;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"customMovieWidth": @1280, @"customMovieHeight": @720,
        @"defaultSizePreset": @0, @"defaultFrameRate": @30
    }];
}

- (id)init
{
    if ((self = [super init])) {
        _frameRate = [[[NSUserDefaults standardUserDefaults] objectForKey:@"defaultFrameRate"] unsignedIntegerValue];
        self.validProfilesSelectedIndices = [NSMutableIndexSet indexSet];
        self.selectedSizePresetsTag = [[[NSUserDefaults standardUserDefaults] objectForKey:@"defaultSizePreset"] integerValue];
    }
    return self;
}

- (void)awakeFromNib
{
    [self.profileDictionaryController addObserver:self forKeyPath:@"selectedObjects" options:0 context:&SelectedProfileObservationContext];
    self.observingProfileSelection = YES;
    [self frameRateOrSizeDidChange];
}

- (void)dealloc
{
    [imagesToMovie removeObserver:self forKeyPath:@"imagePaths"];
    if (self.observingProfileSelection) {
        [self.profileDictionaryController removeObserver:self forKeyPath:@"selectedObjects"];
    }
}

@synthesize imagesToMovie;

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
    if (path && [path isEqualToString:self.firstFramePath]) {
        [self updateReadiness];
        return;
    }

    NSUInteger generation = ++self.firstFrameLoadGeneration;
    self.firstFramePath = path;
    self.firstFrameSize = NSZeroSize;
    [self updateOriginalSizeFields];
    [self frameRateOrSizeDidChange];
    if (!path) return;

    ImagesToMovie *model = self.imagesToMovie;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSSize size = ImagePixelSize([model imageAtPath:path error:NULL]);
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
    _width = @(self.firstFrameSize.width);
    _height = @(self.firstFrameSize.height);
    [self didChangeValueForKey:@"height"];
    [self didChangeValueForKey:@"width"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &ImagePathObservationContext) {
        [self loadFirstFrame];
    } else if (context == &SelectedProfileObservationContext) {
        if (!self.updatingProfiles) {
            NSDictionaryControllerKeyValuePair *selectedProfile = self.profileDictionaryController.selectedObjects.firstObject;
            self.profile = selectedProfile.key;
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (NSSize)targetSize
{
    if (!ValidImageSize(self.firstFrameSize)) return NSZeroSize;
    NSSize limit = NSMakeSize(self.width.doubleValue, self.height.doubleValue);
    if (!ValidImageSize(limit)) return NSZeroSize;
    return self.selectedSizePresetsTag == 0 ? self.firstFrameSize :
        [self.imagesToMovie resizeOriginal:self.firstFrameSize intoTargetSize:limit withTolerance:NO];
}

- (void)updateReadiness
{
    NSSize targetSize = [self targetSize];
    self.readyToCreateMovie = self.imagesToMovie.imagePaths.count > 0 &&
        [self.firstFramePath isEqualToString:self.imagesToMovie.imagePaths.firstObject] &&
        ValidImageSize(targetSize) && targetSize.width <= 3840 && targetSize.height <= 2160 &&
        self.frameRate >= 1 && self.frameRate <= 30 && self.profile != nil && self.validProfiles[self.profile] != nil &&
        isfinite(self.bitRate) && self.bitRate >= 0.000001 && self.bitRate <= self.maxBitRate;
}

// Reconsider the profile only when dimensions or frame rate change.
- (void)frameRateOrSizeDidChange
{
    NSSize targetSize = [self targetSize];
    NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
    NSArray *profileOrder = @[AVVideoProfileLevelH264Main30, AVVideoProfileLevelH264Main31,
        AVVideoProfileLevelH264Main32, AVVideoProfileLevelH264Main41, AVVideoProfileLevelH264MainAutoLevel];
    if (ValidImageSize(targetSize) && targetSize.width <= 3840 && targetSize.height <= 2160 &&
        self.frameRate >= 1 && self.frameRate <= 30) {
        double pixels = targetSize.width * targetSize.height;
        for (NSString *key in profileOrder) {
            NSDictionary *codec = self.imagesToMovie.codecProfiles[key];
            if (pixels <= [codec[ProfileMaxPixelsKey] doubleValue] &&
                pixels * self.frameRate <= [codec[ProfileMaxPixelsPerSecondKey] doubleValue]) {
                profiles[key] = codec[ProfileNameKey];
            }
        }
    }

    NSString *preferredProfile = nil;
    switch (self.selectedSizePresetsTag) {
        case 480: preferredProfile = AVVideoProfileLevelH264Main30; break;
        case 720: preferredProfile = AVVideoProfileLevelH264Main31; break;
        case 1080: preferredProfile = AVVideoProfileLevelH264Main41; break;
        case 2160: preferredProfile = AVVideoProfileLevelH264MainAutoLevel; break;
    }
    if (!preferredProfile || !profiles[preferredProfile]) {
        preferredProfile = nil;
        for (NSString *key in profileOrder) {
            if (profiles[key]) { preferredProfile = key; break; }
        }
    }

    self.updatingProfiles = YES;
    self.validProfiles = profiles;
    [self.profileDictionaryController rearrangeObjects];
    NSArray *selection = @[];
    for (NSDictionaryControllerKeyValuePair *pair in self.profileDictionaryController.arrangedObjects) {
        if ([pair.key isEqualToString:preferredProfile]) { selection = @[pair]; break; }
    }
    self.profileDictionaryController.selectedObjects = selection;
    self.profile = preferredProfile;
    self.updatingProfiles = NO;
    [self updateReadiness];
}

- (void)setProfile:(NSString *)profile
{
    if ((_profile == profile) || [_profile isEqualToString:profile]) return;
    _profile = [profile copy];
    NSDictionary *codec = profile ? self.imagesToMovie.codecProfiles[profile] : nil;
    self.maxBitRate = [codec[ProfileMaxBitRateKey] doubleValue] / 1.0e6;
    self.bitRateNumberFormatter.maximum = @(self.maxBitRate);
    self.bitRate = [codec[ProfileReasonableBitRateKey] doubleValue] / 1.0e6;
}

- (void)setBitRate:(CGFloat)bitRate
{
    _bitRate = bitRate;
    [self updateReadiness];
}

- (void)updateModelWithNewSettings
{
    self.imagesToMovie.frameSize = [self targetSize];
    self.imagesToMovie.frameRate = self.frameRate;
    self.imagesToMovie.averageBitRate = isfinite(self.bitRate) && self.bitRate > 0 && self.bitRate <= 50 ?
        (NSUInteger)(self.bitRate * 1.0e6) : 0;
    self.imagesToMovie.profile = self.profile;
}

@synthesize selectedSizePresetsTag;

- (void)setSelectedSizePresetsTag:(NSInteger)tag
{
    if (selectedSizePresetsTag == tag && self.width && self.height) return;
    selectedSizePresetsTag = tag;
    [self willChangeValueForKey:@"width"];
    [self willChangeValueForKey:@"height"];
    if (tag == 0) {
        _width = @(self.firstFrameSize.width); _height = @(self.firstFrameSize.height);
    } else if (tag == 480) {
        _width = @640; _height = @480;
    } else if (tag == 720) {
        _width = @1280; _height = @720;
    } else if (tag == 1080) {
        _width = @1920; _height = @1080;
    } else if (tag == 2160) {
        _width = @3840; _height = @2160;
    } else {
        _width = [[NSUserDefaults standardUserDefaults] objectForKey:@"customMovieWidth"];
        _height = [[NSUserDefaults standardUserDefaults] objectForKey:@"customMovieHeight"];
    }
    [self didChangeValueForKey:@"height"];
    [self didChangeValueForKey:@"width"];
    self.customFieldsAreEnabled = tag == 1;
    [self frameRateOrSizeDidChange];
    [[NSUserDefaults standardUserDefaults] setObject:@(tag) forKey:@"defaultSizePreset"];
}

- (void)setWidth:(NSNumber *)width
{
    width = width ?: @0;
    if ([_width isEqualToNumber:width]) return;
    _width = width;
    [[NSUserDefaults standardUserDefaults] setObject:_width forKey:@"customMovieWidth"];
    [self frameRateOrSizeDidChange];
}

- (void)setHeight:(NSNumber *)height
{
    height = height ?: @0;
    if ([_height isEqualToNumber:height]) return;
    _height = height;
    [[NSUserDefaults standardUserDefaults] setObject:_height forKey:@"customMovieHeight"];
    [self frameRateOrSizeDidChange];
}

- (void)setFrameRate:(NSUInteger)frameRate
{
    if (_frameRate == frameRate) return;
    _frameRate = frameRate;
    [self frameRateOrSizeDidChange];
}

@end
