//
//  ImagesToMovieController.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <AppKit/AppKit.h>

@class ImagesToMovie;
@interface ImagesToMovieController : NSObject

/************************************************/
/*		Output Settings                         */
/************************************************/

#pragma mark -
#pragma mark Output Settings
#pragma mark

@property(readwrite, copy, nonatomic) NSString *firstFramePath;

@property(readwrite, nonatomic) NSSize firstFrameSize;

/************************************************/
/*		User Selectable                         */
/************************************************/

#pragma mark -
#pragma mark User Selectable
#pragma mark

// Default size and compression profiles, or custom
@property(readwrite, nonatomic) NSInteger selectedSizePresetsTag;
@property(nonatomic) NSInteger selectedCodecTag; // 0: H.264, 1: HEVC, 2: ProRes 422
@property(readonly, nonatomic) NSString *codec;
@property(readonly, nonatomic) BOOL usesH264Profile;
@property(readonly, nonatomic) BOOL usesBitRate;

// if 'custom' is selected, this returns NO
@property(readwrite, nonatomic) BOOL customFieldsAreEnabled;

@property(readwrite, nonatomic) BOOL readyToCreateMovie;

// users chosen settings
@property(readwrite, strong, nonatomic) NSNumber* width;
@property(readwrite, strong, nonatomic) NSNumber* height;
@property(readwrite, assign, nonatomic) NSUInteger frameRate;
@property(readwrite, copy, nonatomic) NSString *profile;
@property(readwrite, assign, nonatomic) CGFloat bitRate; // we use units of Mb/s
@property(readwrite, assign, nonatomic) CGFloat maxBitRate; // we use units of Mb/s

// This dictionary contains profiles that are valid for the given frame size and frame rate.
@property(readwrite, strong, nonatomic) NSDictionary *validProfiles;
@property(readwrite, strong, nonatomic) NSMutableIndexSet *validProfilesSelectedIndices;

@property(readwrite, strong, nonatomic) IBOutlet NSDictionaryController *profileDictionaryController;
@property(readwrite, strong, nonatomic) IBOutlet NSNumberFormatter *bitRateNumberFormatter;

/************************************************/
/*		Output                                  */
/************************************************/

#pragma mark -
#pragma mark Output
#pragma mark

- (void) updateModelWithNewSettings;

@property(readwrite, strong, nonatomic) ImagesToMovie *imagesToMovie;

@end
