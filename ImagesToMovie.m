//
//  ImagesToMovie.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovie.h"
#import "MovieFrameRenderer.h"
#import <VideoToolbox/VideoToolbox.h>
#import <errno.h>
#import <stdio.h>

@interface ImagesToMovie () {
    dispatch_queue_t _exportQueue;
    NSObject *_activeExport;
    BOOL _cancelRequested;
    dispatch_block_t _cancelExport;
}
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

static NSString *VTKey(CFStringRef key) { return (__bridge NSString *)key; }

// Query the very encoder and source format that the writer will use. Presets are
// encoder-specific, and their availability can change with profile and frame rate.
static NSDictionary *MovieCompressionSettings(AVVideoCodecType codec, MovieQualityMode quality,
    NSUInteger bitRate, NSSize size, NSUInteger frameRate, OSType pixelFormat,
    NSString **encoderID, NSError **error)
{
    CMVideoCodecType codecType = [codec isEqualToString:AVVideoCodecTypeH264] ? kCMVideoCodecType_H264 :
        [codec isEqualToString:AVVideoCodecTypeHEVC] ? kCMVideoCodecType_HEVC : kCMVideoCodecType_AppleProRes422;
    CFStringRef profile = [codec isEqualToString:AVVideoCodecTypeH264] ? kVTProfileLevel_H264_High_AutoLevel :
        [codec isEqualToString:AVVideoCodecTypeHEVC] ? kVTProfileLevel_HEVC_Main10_AutoLevel : NULL;
    NSDictionary *sourceAttributes = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
        (__bridge NSString *)kCVPixelBufferWidthKey : @(size.width),
        (__bridge NSString *)kCVPixelBufferHeightKey : @(size.height),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)size.width, (int32_t)size.height,
        codecType, NULL, (__bridge CFDictionaryRef)sourceAttributes, NULL, NULL, NULL, &session);
    if (status != noErr || !session) {
        if (error) *error = MovieError([NSString stringWithFormat:@"No %@ encoder accepts this frame size and pixel format (VideoToolbox error %d).", codec, (int)status], nil);
        return nil;
    }
    NSDictionary *result = nil;
    @try {
        if (profile) {
            status = VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profile);
            if (status != noErr) {
                if (error) *error = MovieError([NSString stringWithFormat:@"The selected %@ encoder does not support the required profile (VideoToolbox error %d).", codec, (int)status], nil);
                return nil;
            }
        }
        status = VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate,
            (__bridge CFNumberRef)@(frameRate));
        if (status != noErr) {
            if (error) *error = MovieError([NSString stringWithFormat:@"The selected encoder does not support %lu fps (VideoToolbox error %d).", (unsigned long)frameRate, (int)status], nil);
            return nil;
        }
        CFTypeRef encoderValue = NULL;
        status = VTSessionCopyProperty(session, kVTCompressionPropertyKey_EncoderID, NULL, &encoderValue);
        if (status != noErr || !encoderValue || CFGetTypeID(encoderValue) != CFStringGetTypeID()) {
            if (encoderValue) CFRelease(encoderValue);
            if (error) *error = MovieError(@"The selected video encoder could not be identified.", nil);
            return nil;
        }
        *encoderID = [(__bridge NSString *)encoderValue copy];
        CFRelease(encoderValue);
        if (!profile) { result = @{}; return result; }

        CFTypeRef presetValue = NULL;
        status = VTSessionCopyProperty(session, kVTCompressionPropertyKey_SupportedPresetDictionaries, NULL, &presetValue);
        if (status != noErr || !presetValue || CFGetTypeID(presetValue) != CFDictionaryGetTypeID()) {
            if (presetValue) CFRelease(presetValue);
            if (error) *error = MovieError(@"The selected encoder does not provide compression presets for this format.", nil);
            return nil;
        }
        NSDictionary *presets = (__bridge NSDictionary *)presetValue;
        NSString *presetKey = VTKey(quality == MovieQualityCustomBitrate ? kVTCompressionPreset_HighQuality : kVTCompressionPreset_ConsistentQuality);
        NSDictionary *preset = presets[presetKey];
        if (![preset isKindOfClass:[NSDictionary class]]) {
            CFRelease(presetValue);
            if (error) *error = MovieError([NSString stringWithFormat:@"The selected %@ encoder does not support the %@ preset.", codec,
                quality == MovieQualityCustomBitrate ? @"High Quality" : @"Consistent Quality"], nil);
            return nil;
        }
        NSMutableDictionary *settings = [preset mutableCopy];
        CFRelease(presetValue);
        // Presets may include an alternative rate controller. Keep their tuning,
        // but choose one explicit rate-control mode for this export.
        NSArray *exclusiveKeys = @[VTKey(kVTCompressionPropertyKey_AverageBitRate),
            VTKey(kVTCompressionPropertyKey_ConstantBitRate), VTKey(kVTCompressionPropertyKey_VariableBitRate),
            VTKey(kVTCompressionPropertyKey_ConstantQualityFactor)];
        [settings removeObjectsForKeys:exclusiveKeys];
        if (quality == MovieQualityCustomBitrate) {
            [settings removeObjectForKey:VTKey(kVTCompressionPropertyKey_DataRateLimits)];
            settings[VTKey(kVTCompressionPropertyKey_VariableBitRate)] = @(bitRate);
            settings[VTKey(kVTCompressionPropertyKey_VBVMaxBitRate)] = @(bitRate * 3 / 2);
        } else {
            settings[VTKey(kVTCompressionPropertyKey_ConstantQualityFactor)] = quality == MovieQualityHigh ? @0.75f : @0.50f;
        }
        settings[VTKey(kVTCompressionPropertyKey_ProfileLevel)] = (__bridge NSString *)profile;
        settings[VTKey(kVTCompressionPropertyKey_ExpectedFrameRate)] = @(frameRate);
        settings[VTKey(kVTCompressionPropertyKey_MaxKeyFrameInterval)] = @(frameRate * 3);
        CFDictionaryRef supported = NULL;
        status = VTSessionCopySupportedPropertyDictionary(session, &supported);
        NSDictionary *available = (__bridge NSDictionary *)supported;
        for (NSString *key in settings) {
            if (!available[key]) {
                if (error) *error = MovieError([NSString stringWithFormat:@"The selected encoder does not support the required %@ setting.", key], nil);
                if (supported) CFRelease(supported);
                return nil;
            }
        }
        if (supported) CFRelease(supported);
        status = VTSessionSetProperties(session, (__bridge CFDictionaryRef)settings);
        if (status != noErr) {
            if (error) *error = MovieError([NSString stringWithFormat:@"The selected encoder rejected the quality settings (VideoToolbox error %d).", (int)status], nil);
            return nil;
        }
        result = settings;
    } @finally {
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
    }
    return result;
}

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
        self.codec = AVVideoCodecTypeHEVC;
        self.qualityMode = MovieQualityHigh;
        self.averageBitRate = 20000000;
	}
	
	return self;
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
    MovieQualityMode quality = self.qualityMode;
    AVVideoCodecType codec = [self.codec copy];
    BOOL h264 = [codec isEqualToString:AVVideoCodecTypeH264];
    BOOL hevc = [codec isEqualToString:AVVideoCodecTypeHEVC];
    BOOL proRes = [codec isEqualToString:AVVideoCodecTypeAppleProRes422];
    if (!imagePaths.count || !destinationPath.isAbsolutePath ||
        !isfinite(size.width) || !isfinite(size.height) ||
        size.width < 1 || size.height < 1 || size.width > 3840 || size.height > 2160 ||
        floor(size.width) != size.width || floor(size.height) != size.height ||
        frameRate < 1 || frameRate > 30 || !(h264 || hevc || proRes) ||
        (!proRes && quality != MovieQualityStandard && quality != MovieQualityHigh && quality != MovieQualityCustomBitrate) ||
        (!proRes && quality == MovieQualityCustomBitrate && (bitRate < 100000 || bitRate > 50000000))) {
        validationError = MovieError(@"Choose input images, an absolute destination, movie dimensions up to 3840 × 2160, 1–30 fps, and a supported codec and quality. Custom bit rate must be 0.1–50 Mbps.", nil);
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
    __block MovieFrameRenderer *renderer = nil;
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
        renderer = nil;
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
        renderer = [[MovieFrameRenderer alloc] initWithFrameSize:size codec:codec];
        if (!renderer) { finish(MovieError(@"The movie frame renderer could not be created.", nil)); return; }
        if (isCancelled()) { finish(MovieCancelledError()); return; }
        NSString *encoderID = nil;
        NSDictionary *compression = MovieCompressionSettings(codec, quality, bitRate, size, frameRate,
            renderer.pixelFormat, &encoderID, &error);
        if (!compression) { finish(error); return; }
        if (isCancelled()) { finish(MovieCancelledError()); return; }
        writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:temporaryPath] fileType:fileType error:&error];
        if (!writer) { finish(MovieError(@"The movie file could not be created.", error)); return; }
        self.movieWriter = writer;
        NSMutableDictionary *videoSettings = [@{ AVVideoCodecKey : codec,
                                                AVVideoWidthKey : @(size.width),
                                                AVVideoHeightKey : @(size.height),
                                                AVVideoEncoderSpecificationKey : @{ VTKey(kVTVideoEncoderSpecification_EncoderID) : encoderID } } mutableCopy];
        if (!proRes) {
            videoSettings[AVVideoCompressionPropertiesKey] = compression;
            videoSettings[AVVideoColorPropertiesKey] = @{
                AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2 };
        }
        if (![writer canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
            finish(MovieError(@"The selected encoder cannot apply these codec, profile, and quality settings in AVAssetWriter.", nil)); return;
        }
        writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        NSDictionary *bufferAttributes = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(renderer.pixelFormat),
                                            (__bridge NSString *)kCVPixelBufferWidthKey : @(size.width),
                                            (__bridge NSString *)kCVPixelBufferHeightKey : @(size.height),
                                            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
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
                    BOOL drewFrame = [renderer renderImageAtPath:imagePaths[frame] intoPixelBuffer:buffer error:&frameError];
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
