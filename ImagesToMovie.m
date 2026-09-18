//
//  ImagesToMovie.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImagesToMovie.h"

@interface ImagesToMovie ()
- (void) finishMovie;
@end

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
		self.minValue = 0;
		self.maxValue = 0;
		self.value = 0;
		self.frameRate = 30;
		self.frameSize = NSMakeSize(1080, 720);
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
                                    @{ProfileNameKey:@"Main 4.1", ProfileMaxPixelsKey:@(2097152), ProfileMaxPixelsPerSecondKey:@(62914560), ProfileMaxBitRateKey:@(50000000), ProfileReasonableBitRateKey:@(9000000)}};
    
    return profiles;
}

/************************************************/
/*		Quicktime Movie Output					*/
/************************************************/

#pragma mark -
#pragma mark Quicktime Movie Output
#pragma mark

- (void) createMovieAtPath: (NSString *) destinationPath;
{
	if (self.imagePaths.count && self.frameRate > 0 && !NSEqualSizes(NSZeroSize, self.frameSize))
	{
		self.movieCreationInProgress = YES;
        
        // 0. Delete the file, if it already exists (the user had to have approved this if we've gotten this far).
        // Note that this is an important step because otherwise an error will be generated and we won't get a valid pixelBufferPool as a consequence.
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        if ([fileManager fileExistsAtPath: destinationPath]) [fileManager removeItemAtPath: destinationPath error: NULL];
        
        // 1. Create a container
        self.movieWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:destinationPath] fileType:AVFileTypeMPEG4 error:NULL];
        
        // 2. Create a writerInput, specifying the codec details.
        NSDictionary *codecSettings = @{ AVVideoAverageBitRateKey : @(self.averageBitRate),
										 AVVideoMaxKeyFrameIntervalKey : @((self.frameRate)*3.0),
                                         AVVideoProfileLevelKey : self.profile};
        
        NSDictionary *videoSettings = @{ AVVideoCodecKey : AVVideoCodecH264,
                                         AVVideoCompressionPropertiesKey : codecSettings,
                                         AVVideoWidthKey : @(self.frameSize.width),
                                         AVVideoHeightKey : @(self.frameSize.height)};
        
        AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        
        // 3. Create an adaptor (wired to the writerInput) which provides some memory buffers we should draw the images to.
        NSDictionary *bufferAttributes = @{ (__bridge NSString *) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB),
                                                                 (__bridge NSString *) kCVPixelBufferWidthKey: @(self.frameSize.width),
                                                                 (__bridge NSString *) kCVPixelBufferHeightKey: @(self.frameSize.height) };
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                                                                         sourcePixelBufferAttributes:bufferAttributes];
		// 4. Tell the assetWriter about its input source.
        [self.movieWriter addInput: writerInput];
        
        [self.movieWriter startWriting];
        [self.movieWriter startSessionAtSourceTime: kCMTimeZero];
        
        // 5. Now we just append CVPixelBuffers to the adaptor with its completion block.
        dispatch_queue_t dispatchQueue = dispatch_queue_create("mediaInputQueue", NULL);
        int __block frame = 0;
        self.minValue = 0;
		self.maxValue = self.imagePaths.count;
		
		dispatch_block_t updateProgress = ^{
			self.value = frame;
			NSString *name = self.value < self.imagePaths.count ? [[self.imagePaths objectAtIndex:self.value] lastPathComponent] : @"";
			self.progressString = [NSString stringWithFormat: @"%lu of %lu, %@", self.value, self.maxValue, name];
		};
		
		updateProgress();
		
        [writerInput requestMediaDataWhenReadyOnQueue:dispatchQueue usingBlock:^{
            while ([writerInput isReadyForMoreMediaData])
            {
                if (frame < self.imagePaths.count)
                {
                    CVPixelBufferRef pixelsBuffer = NULL;
                    CVPixelBufferPoolCreatePixelBuffer (NULL, adaptor.pixelBufferPool, &pixelsBuffer);
                    
                    // Lock pixel buffer address
                    CVPixelBufferLockBaseAddress(pixelsBuffer, 0);
                    
                    // Create your function to set your pixels data in the buffer (in your case, fill with your finalImage data)
                    //[self yourFunctionToPutDataInPixelBuffer:CVPixelBufferGetBaseAddress(pixelsBuffer)];
//                    NSLog(@"path: %@, frame: %d", [self.imagePaths[frame] lastPathComponent], frame);
                    [self fillPixelBuffer: pixelsBuffer withImageAtPath: self.imagePaths[frame] resizedTo: self.frameSize];
                    
                    // Unlock pixel buffer address
                    CVPixelBufferUnlockBaseAddress(pixelsBuffer, 0);
                    
                    // Append pixel buffer (calculate currentFrameTime with your needing, the most simplest way is to have a frame time starting at 0 and increment each time you write a frame with the time of a frame (inverse of your framerate))
					if (self.movieWriter.status == AVAssetWriterStatusWriting) {
						[adaptor appendPixelBuffer:pixelsBuffer withPresentationTime:CMTimeMake(frame, self.frameRate)];
					}
                    
                    // Release pixel buffer
                    CVPixelBufferRelease(pixelsBuffer);
                    
                    // Advance to the next frame.
                    frame++;
					
					// Update the current status for the user to see
					dispatch_async(dispatch_get_main_queue(), updateProgress);
                }
				else
				{
                    [writerInput markAsFinished];
					[self.movieWriter finishWriting];
					
					if (self.movieWriter.status == AVAssetWriterStatusFailed) {
						NSLog(@"%@",[self.movieWriter.error description]);
					}
					
                    [self finishMovie];
                }
				
				if (self.movieWriter.status == AVAssetWriterStatusCancelled) {
					[self finishMovie];
				}
            }
        }];
    }
}

- (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize withTolerance: (BOOL) tolerateSlop;
{
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

- (void) fillPixelBuffer: (CVPixelBufferRef) pixelBuffer withImageAtPath: (NSString *) imagePath resizedTo: (NSSize) size
{
    NSImage *initialImage = [[NSImage alloc] initWithContentsOfFile: imagePath];
    
    size_t bitsPerComponent = 8;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
    // context to draw in, set to pixel buffer's address
    CGContextRef cgContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer), size.width, size.height, bitsPerComponent, bytesPerRow, cs, kCGImageAlphaNoneSkipFirst);
    
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cgContext flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    // eps images need an extra 4 rows some bug somewhere.
    [initialImage drawInRect: NSMakeRect(0, 0, size.width, size.height) fromRect: NSZeroRect operation: NSCompositeCopy fraction: 1.0];
    [NSGraphicsContext restoreGraphicsState];
    
    CFRelease(cgContext);
	CFRelease(cs);
}

- (void) finishMovie
{
	self.movieCreationInProgress = NO;
}

- (void) cancel
{
	[self.movieWriter cancelWriting];
}

@synthesize movieCreationInProgress;
@synthesize minValue;
@synthesize maxValue;
@synthesize value;
@synthesize progressString;

@end
