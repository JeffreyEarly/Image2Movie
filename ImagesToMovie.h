//
//  ImagesToMovie.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, MovieQualityMode) {
    MovieQualityStandard = 0,
    MovieQualityHigh = 1,
    MovieQualityCustomBitrate = 2
};

@interface ImagesToMovie : NSObject

/************************************************/
/*		Initialization							*/
/************************************************/

#pragma mark -
#pragma mark Initialization
#pragma mark

@property(readwrite, strong, nonatomic) NSMutableArray *imagePaths;
@property(readwrite, assign, nonatomic) NSUInteger frameRate;
@property NSSize frameSize;
@property NSUInteger averageBitRate;
@property MovieQualityMode qualityMode;
@property(copy) AVVideoCodecType codec; // HEVC by default

/************************************************/
/*		Quicktime Movie Output					*/
/************************************************/

#pragma mark -
#pragma mark Quicktime Movie Output
#pragma mark

@property(readwrite, strong, atomic) AVAssetWriter *movieWriter;

// Completion runs once on the main thread. A nil error means success.
- (void) createMovieAtPath: (NSString *) destinationPath completionHandler: (void (^)(NSError *error)) completionHandler;

// With tolerance allows some fudge factor.
- (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize withTolerance: (BOOL) tolerateSlop;

- (void) cancel;

/************************************************/
/*		Progress								*/
/************************************************/

#pragma mark -
#pragma mark Progress
#pragma mark

@property BOOL movieCreationInProgress;
@property NSUInteger minValue;
@property NSUInteger maxValue;
@property NSUInteger value;
@property(copy) NSString *progressString;

@end
