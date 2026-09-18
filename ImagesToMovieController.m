//
//  ImagesToMovieController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovieController.h"
#import "ImagesToMovie.h"

static NSString * ImagePathObservationContext = @"ImagePathObservationContext";
static NSString * SelectedProfileObservationContext = @"SelectedProfileObservationContext";

@implementation ImagesToMovieController

+ (void)initialize
{
	NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
	[defaults setObject: @(1280) forKey: @"customMovieWidth"];
	[defaults setObject: @(720) forKey: @"customMovieHeight"];
	[defaults setObject: @(0) forKey: @"defaultSizePreset"];
    [defaults setObject: @(30) forKey: @"defaultFrameRate"];
	[[NSUserDefaults standardUserDefaults] registerDefaults: defaults];
}

- (id) init
{
	if ((self=[super init]))
	{
		self.width = [[NSUserDefaults standardUserDefaults] objectForKey: @"customMovieWidth"];
		self.height = [[NSUserDefaults standardUserDefaults] objectForKey: @"customMovieHeight"];
        self.frameRate = [[[NSUserDefaults standardUserDefaults] objectForKey: @"defaultFrameRate"] unsignedIntegerValue];
		self.selectedSizePresetsTag = [[[NSUserDefaults standardUserDefaults] objectForKey: @"defaultSizePreset"] unsignedIntegerValue];
		self.customFieldsAreEnabled = selectedSizePresetsTag == 1 ? YES : NO;
        self.validProfilesSelectedIndices = [NSMutableIndexSet indexSet];
		self.readyToCreateMovie = NO;
	}
	return self;
}

- (void) awakeFromNib
{
    [self.profileDictionaryController addObserver: self forKeyPath: @"selectedObjects" options: NULL context: &SelectedProfileObservationContext];
}

@synthesize imagesToMovie;

- (void) setImagesToMovie:(ImagesToMovie *) theModelObject
{
    if (imagesToMovie) {
        [imagesToMovie removeObserver: self forKeyPath: @"imagePaths"];
    }
    
	imagesToMovie = theModelObject;
    
    if (imagesToMovie) {
        [imagesToMovie addObserver:self forKeyPath:@"imagePaths" options: NULL context: &ImagePathObservationContext];
    }
	
	self.selectedSizePresetsTag = selectedSizePresetsTag;
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ( context == &ImagePathObservationContext )
	{
		if (self.imagesToMovie.imagePaths.count) {
            if ( ![self.imagesToMovie.imagePaths[0] isEqualToString: self.firstFramePath]) {
                self.firstFramePath = self.imagesToMovie.imagePaths[0];
                dispatch_async( dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                   NSSize currentSize = [[[NSImage alloc] initWithContentsOfFile: self.firstFramePath] size];
                    dispatch_async( dispatch_get_main_queue(), ^{
                        self.firstFrameSize = currentSize;
                        if (self.selectedSizePresetsTag == 0) {
                            [self willChangeValueForKey: @"width"];
                            [self willChangeValueForKey: @"height"];
                            _width=@(self.firstFrameSize.width);
                            _height=@(self.firstFrameSize.height);
                            [self didChangeValueForKey: @"height"];
                            [self didChangeValueForKey: @"width"];
                        }
                        [self frameRateOrSizeDidChange];
						self.readyToCreateMovie = YES;
                    });
                });
            }
        } else {
			self.readyToCreateMovie = NO;
            self.firstFramePath = nil;
            self.firstFrameSize = NSZeroSize;
            [self frameRateOrSizeDidChange];
        }
	}
    else if ( context == &SelectedProfileObservationContext)
    {
        if (self.profileDictionaryController.selectedObjects.count) {
            NSDictionaryControllerKeyValuePair *selectedProfile = self.profileDictionaryController.selectedObjects[0];
            self.profile = selectedProfile.key;
        } else {
            self.profile = nil;
        }
        [self profileDidChange];
    }
}

// If either the frame rate or frame size changes, this changes which profiles are available.
- (void) frameRateOrSizeDidChange
{
    NSSize sizeLimit = NSMakeSize(self.width.doubleValue, self.height.doubleValue);
    NSSize targetSize = [self.imagesToMovie resizeOriginal: self.firstFrameSize intoTargetSize: sizeLimit withTolerance: NO];
    
    NSUInteger totalPixels = ceil(targetSize.width * targetSize.height);
    NSUInteger totalPixelsPerSecond = totalPixels * ceil(self.frameRate);
    
    NSMutableDictionary *validProfiles = [NSMutableDictionary dictionary];
    for (NSString *key in self.imagesToMovie.codecProfiles) {
        NSDictionary *codec = self.imagesToMovie.codecProfiles[key];
        if ( totalPixels <= [codec[ProfileMaxPixelsKey] unsignedIntegerValue] && totalPixelsPerSecond <= [codec[ProfileMaxPixelsPerSecondKey] unsignedIntegerValue]) {
            validProfiles[key] = codec[ProfileNameKey];
        }
    }
    self.validProfiles = validProfiles;
}

- (void) profileDidChange
{
    if (self.profile) {
        self.bitRate = [[self.imagesToMovie.codecProfiles[self.profile] objectForKey: ProfileReasonableBitRateKey] floatValue]/1.0e6;
        self.bitRateNumberFormatter.maximum = @([[self.imagesToMovie.codecProfiles[self.profile] objectForKey: ProfileMaxBitRateKey] floatValue]/1.0e6);
    } else {
        self.bitRate = 1.0;
        self.bitRateNumberFormatter.maximum = @(10.0);
    }
}

- (void) updateModelWithNewSettings
{
    if (self.selectedSizePresetsTag == 0) {
        self.imagesToMovie.frameSize = self.firstFrameSize;
    } else {
        NSSize sizeLimit = NSMakeSize(self.width.doubleValue, self.height.doubleValue);
        self.imagesToMovie.frameSize = [self.imagesToMovie resizeOriginal: self.firstFrameSize intoTargetSize: sizeLimit withTolerance: NO];
    }
    
    self.imagesToMovie.frameRate = self.frameRate;
    self.imagesToMovie.averageBitRate = (NSUInteger)(self.bitRate * 1.0e6);
    self.imagesToMovie.profile = self.profile;
}

/************************************************/
/*		User Selectable                         */
/************************************************/

#pragma mark -
#pragma mark User Selectable
#pragma mark

@synthesize selectedSizePresetsTag;
- (void) setSelectedSizePresetsTag: (NSInteger) tag
{
	selectedSizePresetsTag = tag;
    NSString *preferredProfile;
    
    [self willChangeValueForKey: @"width"];
    [self willChangeValueForKey: @"height"];
	if (tag == 0) {
        _width=@(self.firstFrameSize.width); _height=@(self.firstFrameSize.height);
	} else if (tag == 480) {
        _width=@(640); _height=@(480);
        preferredProfile = AVVideoProfileLevelH264Main30;
	} else if (tag == 720) {
        _width=@(1280); _height=@(720);
        preferredProfile = AVVideoProfileLevelH264Main31;
	} else if (tag == 1080) {
        _width=@(1920); _height=@(1080);
        preferredProfile = AVVideoProfileLevelH264Main41;
	} else {
        _width=[[NSUserDefaults standardUserDefaults] objectForKey: @"customMovieWidth"];
        _height=[[NSUserDefaults standardUserDefaults] objectForKey: @"customMovieHeight"];
	}
	[self didChangeValueForKey: @"height"];
    [self didChangeValueForKey: @"width"];
    
	self.customFieldsAreEnabled = (tag == 1) ? YES : NO;

    [self frameRateOrSizeDidChange];
    if (self.validProfiles.count) {
        NSUInteger index = preferredProfile ? [self.profileDictionaryController.arrangedObjects indexOfObjectPassingTest:^BOOL (NSDictionaryControllerKeyValuePair *obj, NSUInteger idx, BOOL *stop) {
            return [obj.key isEqualToString: preferredProfile];
        }] : 0;
        index = (index == NSNotFound) ? 0 : index;
        self.profileDictionaryController.selectedObjects = @[self.profileDictionaryController.arrangedObjects[index]];
    }
    
	[[NSUserDefaults standardUserDefaults] setObject: [NSNumber numberWithUnsignedInteger: tag] forKey:@"defaultSizePreset"];
}

- (void) setWidth:(NSNumber*)aWidth
{
	if (!aWidth || aWidth.doubleValue < 0) {
		aWidth = @(0);
	}
	_width = aWidth;
	
	[[NSUserDefaults standardUserDefaults] setObject: aWidth forKey:@"customMovieWidth"];
    [self frameRateOrSizeDidChange];
}

- (void) setHeight:(NSNumber*)aHeight
{
	if (!aHeight || aHeight.doubleValue < 0) {
		aHeight = @(0);
	}
	_height = aHeight;
	
	[[NSUserDefaults standardUserDefaults] setObject: aHeight forKey:@"customMovieHeight"];
    [self frameRateOrSizeDidChange];
}

- (void) setFrameRate:(NSUInteger)frameRate {
	_frameRate = frameRate;
	[self frameRateOrSizeDidChange];
}

@end
