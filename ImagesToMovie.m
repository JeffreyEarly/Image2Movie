//
//  ImagesToMovie.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovie.h"
#import <errno.h>
#import <stdio.h>

@interface ImagesToMovie () {
    dispatch_queue_t _exportQueue;
    NSObject *_activeExport;
    BOOL _cancelRequested;
    dispatch_block_t _cancelExport;
}
- (BOOL) fillPixelBuffer:(CVPixelBufferRef)pixelBuffer withImageAtPath:(NSString *)imagePath error:(NSError **)error;
@end

static NSError *MovieError(NSString *description, NSError *underlyingError)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlyingError) info[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"Image2MovieErrorDomain" code:1 userInfo:info];
}

static NSError *MovieCancelledError(void)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

NSString * const ProfileNameKey = @"ProfileNameKey";
NSString * const ProfileMaxPixelsKey = @"ProfileMaxPixelsKey";
NSString * const ProfileMaxPixelsPerSecondKey = @"ProfileMaxPixelsPerSecondKey";
NSString * const ProfileReasonableBitRateKey = @"ProfileReasonableBitRateKey";
NSString * const ProfileMaxBitRateKey = @"ProfileMaxBitRateKey";

@implementation ImagesToMovie

/************************************************/
/*		Initialization							*/
/************************************************/

#pragma mark -
#pragma mark Initialization
#pragma mark

- (id) init {
	if ((self = [super init]) ) {
		self.imagePaths = [NSMutableArray array];
        _exportQueue = dispatch_queue_create("Image2Movie.export", DISPATCH_QUEUE_SERIAL);
		self.minValue = 0;
		self.maxValue = 0;
		self.value = 0;
		self.frameRate = 30;
		self.frameSize = NSMakeSize(1080, 720);
        self.codec = AVVideoCodecTypeH264;
	}
	
	return self;
}

- (NSDictionary *) codecProfiles
{
    NSDictionary *profiles = @{ AVVideoProfileLevelH264Main30 :
                                    @{ProfileNameKey:@"Main 3.0", ProfileMaxPixelsKey:@(414720), ProfileMaxPixelsPerSecondKey:@(10368000), ProfileMaxBitRateKey:@(10000000), ProfileReasonableBitRateKey:@(1600000)},
                                AVVideoProfileLevelH264Main31 :
                                    @{ProfileNameKey:@"Main 3.1", ProfileMaxPixelsKey:@(921600), ProfileMaxPixelsPerSecondKey:@(27648000), ProfileMaxBitRateKey:@(14000000), ProfileReasonableBitRateKey:@(5000000)},
                                AVVideoProfileLevelH264Main32 :
                                    @{ProfileNameKey:@"Main 3.2", ProfileMaxPixelsKey:@(1310720), ProfileMaxPixelsPerSecondKey:@(55296000), ProfileMaxBitRateKey:@(20000000), ProfileReasonableBitRateKey:@(5000000)},
                                AVVideoProfileLevelH264Main41 :
                                    @{ProfileNameKey:@"Main 4.1", ProfileMaxPixelsKey:@(2097152), ProfileMaxPixelsPerSecondKey:@(62914560), ProfileMaxBitRateKey:@(50000000), ProfileReasonableBitRateKey:@(9000000)},
                                AVVideoProfileLevelH264MainAutoLevel :
                                    @{ProfileNameKey:@"Main Auto (4K)", ProfileMaxPixelsKey:@(3840 * 2160), ProfileMaxPixelsPerSecondKey:@(3840 * 2160 * 30), ProfileMaxBitRateKey:@(50000000), ProfileReasonableBitRateKey:@(36000000)}};
    
    return profiles;
}

/************************************************/
/*		Quicktime Movie Output					*/
/************************************************/

#pragma mark -
#pragma mark Quicktime Movie Output
#pragma mark

- (void) createMovieAtPath:(NSString *)destinationPath completionHandler:(void (^)(NSError *error))completionHandler
{
    destinationPath = [destinationPath copy];
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createMovieAtPath:destinationPath completionHandler:completionHandler];
        });
        return;
    }
    if (self.movieCreationInProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler) completionHandler(MovieError(@"A movie export is already in progress.", nil));
        });
        return;
    }

    // Freeze all settings before handing work to the export queue.
    NSMutableArray *paths = [NSMutableArray array];
    NSError *validationError = nil;
    for (id path in self.imagePaths) {
        if (![path isKindOfClass:[NSString class]] || ![path length]) {
            validationError = MovieError(@"Every input image must have a valid file path.", nil);
            break;
        }
        [paths addObject:[path copy]];
    }
    NSArray *imagePaths = [paths copy];
    NSSize size = self.frameSize;
    NSUInteger frameRate = self.frameRate;
    NSUInteger bitRate = self.averageBitRate;
    AVVideoCodecType codec = [self.codec copy];
    BOOL h264 = [codec isEqualToString:AVVideoCodecTypeH264];
    BOOL hevc = [codec isEqualToString:AVVideoCodecTypeHEVC];
    BOOL proRes = [codec isEqualToString:AVVideoCodecTypeAppleProRes422];
    NSString *profile = [self.profile copy];
    NSDictionary *limits = profile ? self.codecProfiles[profile] : nil;
    double pixels = size.width * size.height;
    BOOL validCompression = proRes || (hevc && bitRate >= 1 && bitRate <= 50000000) ||
        (h264 && limits && bitRate >= 1 && bitRate <= [limits[ProfileMaxBitRateKey] unsignedIntegerValue] &&
         pixels <= [limits[ProfileMaxPixelsKey] doubleValue] &&
         pixels * frameRate <= [limits[ProfileMaxPixelsPerSecondKey] doubleValue]);
    if (!imagePaths.count || !destinationPath.isAbsolutePath ||
        !isfinite(size.width) || !isfinite(size.height) ||
        size.width < 1 || size.height < 1 || size.width > 3840 || size.height > 2160 ||
        floor(size.width) != size.width || floor(size.height) != size.height ||
        frameRate < 1 || frameRate > 30 || !validCompression) {
        validationError = MovieError(@"Choose readable images, a valid destination, and supported movie dimensions, frame rate, codec, profile, and bit rate.", nil);
    }
    if (validationError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler) completionHandler(validationError);
        });
        return;
    }

    AVFileType fileType = proRes ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;
    NSString *temporaryPath = [[destinationPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:[NSString stringWithFormat:@".Image2Movie-%@.%@", NSUUID.UUID.UUIDString, proRes ? @"mov" : @"mp4"]];
    NSObject *exportIdentity = [[NSObject alloc] init];
    __block AVAssetWriter *writer = nil;
    __block AVAssetWriterInput *writerInput = nil;
    __block AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
    __block NSUInteger frame = 0;
    __block BOOL finishing = NO;
    __block BOOL finished = NO;

    BOOL (^isCancelled)(void) = ^BOOL {
        @synchronized (self) {
            return self->_activeExport == exportIdentity && self->_cancelRequested;
        }
    };
    void (^finish)(NSError *) = ^(NSError *error) {
        // Every caller runs on the same queue, including late writer callbacks.
        if (finished) return;
        finished = YES;
        @synchronized (self) {
            if (self->_cancelRequested) error = MovieCancelledError();
            // This lock is also the cancellation boundary: once rename succeeds,
            // cancellation can no longer turn a committed export into a failure.
            if (!error && rename(temporaryPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0) {
                NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                error = MovieError(@"The completed movie could not be moved to its destination.", underlying);
            }
            self->_cancelExport = nil;
        }
        if (error) [writer cancelWriting];
        NSError *cleanupError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:&cleanupError] &&
            cleanupError.code != NSFileNoSuchFileError) {
            error = MovieError([NSString stringWithFormat:@"%@ Temporary movie cleanup also failed: %@",
                error.localizedDescription ?: @"The movie was saved.", cleanupError.localizedDescription], error ?: cleanupError);
        }
        adaptor = nil;
        writerInput = nil;
        writer = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self) {
                if (self->_activeExport != exportIdentity) return;
                self->_activeExport = nil;
            }
            self.movieWriter = nil;
            self.movieCreationInProgress = NO;
            if (completionHandler) completionHandler(error);
        });
    };

    @synchronized (self) {
        _activeExport = exportIdentity;
        _cancelRequested = NO;
        _cancelExport = ^{ finish(MovieCancelledError()); };
    }
    self.minValue = 0;
    self.maxValue = imagePaths.count;
    self.value = 0;
    self.progressString = [NSString stringWithFormat:@"0 of %lu, %@", imagePaths.count, [imagePaths[0] lastPathComponent]];
    self.movieCreationInProgress = YES;

    dispatch_async(_exportQueue, ^{
        if (finished) return;
        if (isCancelled()) { finish(MovieCancelledError()); return; }
        NSError *error = nil;
        writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:temporaryPath] fileType:fileType error:&error];
        if (!writer) { finish(MovieError(@"The movie file could not be created.", error)); return; }
        self.movieWriter = writer;
        NSMutableDictionary *videoSettings = [@{ AVVideoCodecKey : codec,
                                                AVVideoWidthKey : @(size.width),
                                                AVVideoHeightKey : @(size.height) } mutableCopy];
        // ProRes controls its own data rate and has no H.264-style profile or GOP.
        if (!proRes) {
            NSMutableDictionary *compression = [@{ AVVideoAverageBitRateKey : @(bitRate),
                AVVideoMaxKeyFrameIntervalKey : @(frameRate * 3),
                AVVideoExpectedSourceFrameRateKey : @(frameRate) } mutableCopy];
            if (h264) compression[AVVideoProfileLevelKey] = profile;
            videoSettings[AVVideoCompressionPropertiesKey] = compression;
        }
        if (![writer canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
            finish(MovieError(@"This computer cannot encode the selected movie settings.", nil)); return;
        }
        writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        NSDictionary *bufferAttributes = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB),
                                            (__bridge NSString *)kCVPixelBufferWidthKey : @(size.width),
                                            (__bridge NSString *)kCVPixelBufferHeightKey : @(size.height),
                                            (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
                                            (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES };
        adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput sourcePixelBufferAttributes:bufferAttributes];
        if (![writer canAddInput:writerInput]) {
            finish(MovieError(@"The movie writer could not accept its video input.", nil)); return;
        }
        [writer addInput:writerInput];
        if (![writer startWriting]) { finish(MovieError(@"Movie encoding could not start.", writer.error)); return; }
        [writer startSessionAtSourceTime:kCMTimeZero];
        [writerInput requestMediaDataWhenReadyOnQueue:self->_exportQueue usingBlock:^{
            if (finished || finishing) return;
            if (isCancelled()) { finish(MovieCancelledError()); return; }
            if (writer.status != AVAssetWriterStatusWriting) {
                finish(MovieError(@"Movie encoding failed.", writer.error)); return;
            }
            while (frame < imagePaths.count && writerInput.readyForMoreMediaData) {
                if (isCancelled()) { finish(MovieCancelledError()); return; }
                @autoreleasepool {
                    CVPixelBufferRef buffer = NULL;
                    CVReturn result = adaptor.pixelBufferPool ? CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) : kCVReturnInvalidPoolAttributes;
                    if (result != kCVReturnSuccess || !buffer) {
                        finish(MovieError(@"A movie frame buffer could not be allocated.", nil)); return;
                    }
                    NSError *frameError = nil;
                    BOOL drewFrame = [self fillPixelBuffer:buffer withImageAtPath:imagePaths[frame] error:&frameError];
                    BOOL appended = drewFrame && !isCancelled() && [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake((int64_t)frame, (int32_t)frameRate)];
                    CVPixelBufferRelease(buffer);
                    if (!appended) {
                        finish(frameError ?: MovieError(@"A movie frame could not be encoded.", writer.error)); return;
                    }
                    frame++;
                    NSUInteger completedFrames = frame;
                    NSString *nextName = frame < imagePaths.count ? [imagePaths[frame] lastPathComponent] : @"";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized (self) {
                            if (self->_activeExport != exportIdentity) return;
                        }
                        self.value = completedFrames;
                        self.progressString = [NSString stringWithFormat:@"%lu of %lu, %@", completedFrames, imagePaths.count, nextName];
                    });
                }
            }
            if (isCancelled()) { finish(MovieCancelledError()); return; }
            if (writer.status != AVAssetWriterStatusWriting) {
                finish(MovieError(@"Movie encoding failed.", writer.error)); return;
            }
            if (frame == imagePaths.count) {
                finishing = YES;
                [writerInput markAsFinished];
                [writer endSessionAtSourceTime:CMTimeMake((int64_t)frame, (int32_t)frameRate)];
                AVAssetWriter *finishingWriter = writer;
                [finishingWriter finishWritingWithCompletionHandler:^{
                    dispatch_async(self->_exportQueue, ^{
                        if (finished) return;
                        finish(finishingWriter.status == AVAssetWriterStatusCompleted ? nil :
                            MovieError(@"The movie could not be finished.", finishingWriter.error));
                    });
                }];
            }
        }];
    });
}

- (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize withTolerance: (BOOL) tolerateSlop;
{
    if (!isfinite(originalSize.width) || !isfinite(originalSize.height) ||
        !isfinite(targetSize.width) || !isfinite(targetSize.height) ||
        originalSize.width <= 0 || originalSize.height <= 0 || targetSize.width <= 0 || targetSize.height <= 0) return NSZeroSize;

    // Set an aspect ratio tolerance.
    CGFloat tolerance = tolerateSlop ? 0.5/100 : 0.0;
    
    CGFloat aspectRatio = originalSize.width/originalSize.height;
    if (targetSize.height * aspectRatio <= targetSize.width) {
        CGFloat width = round(targetSize.height * aspectRatio);
        targetSize.width = ((targetSize.width - width)/targetSize.width  < tolerance) ? targetSize.width : width;
    }
    else {
        CGFloat height = round(targetSize.width / aspectRatio);
        targetSize.height = ((targetSize.height - height)/targetSize.height  < tolerance) ? targetSize.height : height;
    }
    
    return targetSize;
}

- (NSImage *) imageAtPath:(NSString *)imagePath error:(NSError **)error
{
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:imagePath];
    for (NSImageRep *representation in image.representations) {
        if (![representation isKindOfClass:[NSBitmapImageRep class]]) continue;
        // NSImage and CGImage can appear valid while their lazy decoder fails.
        CGImageRef decodedImage = [(NSBitmapImageRep *)representation CGImage];
        CFDataRef pixels = decodedImage ? CGDataProviderCopyData(CGImageGetDataProvider(decodedImage)) : NULL;
        BOOL complete = pixels && CFDataGetLength(pixels) > 0;
        if (pixels) CFRelease(pixels);
        if (!complete) {
            image = nil;
            break;
        }
    }
    if (!image.isValid) {
        if (error) *error = MovieError([NSString stringWithFormat:@"The image “%@” could not be completely decoded.", imagePath.lastPathComponent], nil);
        return nil;
    }
    return image;
}

- (BOOL) fillPixelBuffer:(CVPixelBufferRef)pixelBuffer withImageAtPath:(NSString *)imagePath error:(NSError **)error
{
    NSImage *image = [self imageAtPath:imagePath error:error];
    if (!image) return NO;
    CVReturn result = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (result != kCVReturnSuccess) {
        if (error) *error = MovieError(@"A movie frame buffer could not be locked.", nil);
        return NO;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CGContextRef context = colorSpace ? CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer), width, height, 8,
        CVPixelBufferGetBytesPerRow(pixelBuffer), colorSpace, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst) : NULL;
    BOOL drewImage = NO;
    if (context) {
        NSRect bounds = NSMakeRect(0, 0, width, height);
        NSGraphicsContext *graphicsContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        CGImageRef decodedImage = [image CGImageForProposedRect:&bounds context:graphicsContext hints:nil];
        if (decodedImage) {
            CGContextSetRGBFillColor(context, 0, 0, 0, 1);
            CGContextFillRect(context, CGRectMake(0, 0, width, height));
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), decodedImage);
            drewImage = YES;
        }
        CGContextRelease(context);
    }
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    result = CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (result != kCVReturnSuccess) drewImage = NO;
    if (!drewImage && error) {
        *error = MovieError([NSString stringWithFormat:@"The image “%@” could not be decoded into a movie frame.", imagePath.lastPathComponent], nil);
    }
    return drewImage;
}

- (void) cancel
{
    @synchronized (self) {
        if (!_cancelExport) return;
        _cancelRequested = YES;
        dispatch_async(_exportQueue, _cancelExport);
    }
}

@synthesize movieCreationInProgress;
@synthesize minValue;
@synthesize maxValue;
@synthesize value;
@synthesize progressString;

@end
