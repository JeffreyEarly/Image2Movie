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
@property(readwrite, copy, nonatomic) NSString *firstFramePath;
@property(readwrite, nonatomic) NSSize firstFrameSize;
@property(readwrite, nonatomic) NSInteger selectedSizePresetsTag;
@property(readwrite, nonatomic) NSInteger selectedCodecTag;
@property(readwrite, nonatomic) NSInteger selectedQualityTag;
@property(readonly, nonatomic) NSString *codec;
@property(readonly, nonatomic) BOOL qualityControlsVisible;
@property(readonly, nonatomic) BOOL customBitRateEnabled;
@property(readonly, nonatomic) BOOL automaticBitRateVisible;
@property(readwrite, nonatomic) BOOL customFieldsAreEnabled;
@property(readwrite, nonatomic) BOOL readyToCreateMovie;
@property(readwrite, strong, nonatomic) NSNumber *width;
@property(readwrite, strong, nonatomic) NSNumber *height;
@property(readwrite, assign, nonatomic) NSUInteger frameRate;
// Display value in Mb/s; the model receives bits per second.
@property(readwrite, assign, nonatomic) CGFloat bitRate;
- (void)updateModelWithNewSettings;
@property(readwrite, strong, nonatomic) ImagesToMovie *imagesToMovie;
@end
