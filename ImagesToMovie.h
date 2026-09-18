//
//  ImagesToMovie.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NSString * const ProfileNameKey;
NSString * const ProfileMaxPixelsKey;
NSString * const ProfileMaxPixelsPerSecondKey;
NSString * const ProfileReasonableBitRateKey;
NSString * const ProfileMaxBitRateKey;

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
@property NSString *profile;

@property(readonly, nonatomic) NSDictionary *codecProfiles;

/************************************************/
/*		Quicktime Movie Output					*/
/************************************************/

#pragma mark -
#pragma mark Quicktime Movie Output
#pragma mark

@property(readwrite, strong, atomic) AVAssetWriter *movieWriter;

- (void) createMovieAtPath: (NSString *) destinationPath;

// With tolerance allows some fudge factor.
- (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize withTolerance: (BOOL) tolerateSlop;

- (void) fillPixelBuffer: (CVPixelBufferRef) pixelBuffer withImageAtPath: (NSString *) imagePath resizedTo: (NSSize) size;

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
