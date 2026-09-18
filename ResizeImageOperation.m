//
//  ResizeImageOperation.m
//  Image2Movie
//
//  Created by Jeffrey J. Early on 8/6/12.
//
//

#import "ResizeImageOperation.h"
#import "AddMovieFrameOperation.h"

@implementation ResizeImageOperation

+ (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize
{
    // Set an aspect ratio tolerance.
    CGFloat tolerance = 0.5/100;
    
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

CGImageRef CGImageCreateFromImageWithResize( CGImageRef image, CGSize size)
{
    NSUInteger bitmapBytesPerRow   = (size.width * 4);
	NSUInteger bitmapByteCount     = (bitmapBytesPerRow * size.height);
	
	void *bitmapData = malloc( bitmapByteCount );
	if (bitmapData == NULL)	return nil;
	
	CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
	CGContextRef context = CGBitmapContextCreate(bitmapData, size.width, size.height,8,bitmapBytesPerRow, colorspace,kCGImageAlphaNoneSkipFirst);
	CGColorSpaceRelease(colorspace);
	if(context == NULL) {
		free(bitmapData);
		return nil;
	}
	
	CGContextSetShouldAntialias( context, YES);
	CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
	
	CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), image);
	CGImageRef imgRef = CGBitmapContextCreateImage(context);
	CGContextRelease(context);
	free(bitmapData);
	
	return imgRef;
}

- (NSImage *) imageFromPath: (NSString *) path usingCGImageSourceResizedTo: (NSSize) targetSize
{
	CGImageRef imageRef = NULL;
	CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
	if(source) {
		// This will return NULL for vector images, use CGImageSourceCreateThumbnailAtIndex instead.
		imageRef = CGImageSourceCreateImageAtIndex(source, 0, NULL);
		CFRelease(source);
	} else {
		return nil;
	}
	
	// OK, we've got a valid image ref
	if (imageRef)
	{
		if ( NSEqualSizes( targetSize, NSZeroSize) )
		{
			NSImage *image = [[NSImage alloc] initWithCGImage: imageRef size: NSZeroSize];
			CFRelease(imageRef);
			
			return image;
		}
		else
		{
			// Take the requested target size and make sure it obeys the proper aspect ratio.
			NSSize originalSize = NSMakeSize( CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
            targetSize = [ResizeImageOperation resizeOriginal: originalSize intoTargetSize: targetSize];
			
			CGImageRef resizedImageRef = CGImageCreateFromImageWithResize( imageRef, targetSize );
			CFRelease(imageRef);
			
			if (resizedImageRef) {
				NSImage *image = [[NSImage alloc] initWithCGImage: resizedImageRef size: NSZeroSize];
				CFRelease(resizedImageRef);
				
				return image;
			} else {
				return nil;
			}
		}
	}
	else
	{
		return nil;
	}
}

- (CVPixelBufferRef)fastImageFromNSImage:(NSImage *)image
{
    CVPixelBufferRef buffer = NULL;
    
    
    // config
    size_t width = [image size].width;
    size_t height = [image size].height;
    size_t bitsPerComponent = 8; // *not* CGImageGetBitsPerComponent(image);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGBitmapInfo bi = kCGImageAlphaNoneSkipFirst; // *not* CGImageGetBitmapInfo(image);
    //NSDictionary *d = @{kCVPixelBufferCGImageCompatibilityKey : @(YES), kCVPixelBufferCGBitmapContextCompatibilityKey : @(YES)};
    NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey, [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey, nil];
    
    // create pixel buffer
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, k32ARGBPixelFormat, (__bridge CFDictionaryRef)d, &buffer);
    CVPixelBufferLockBaseAddress(buffer, 0);
    void *rasterData = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    
    // context to draw in, set to pixel buffer's address
    CGContextRef ctxt = CGBitmapContextCreate(rasterData, width, height, bitsPerComponent, bytesPerRow, cs, bi);
    if(ctxt == NULL){
        NSLog(@"could not create context");
        return NULL;
    }
    
    // draw
    NSGraphicsContext *nsctxt = [NSGraphicsContext graphicsContextWithGraphicsPort:ctxt flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsctxt];
    [image compositeToPoint:NSMakePoint(0.0, 0.0) operation:NSCompositeCopy];
    [NSGraphicsContext restoreGraphicsState];
    
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CFRelease(ctxt);
    
    return buffer;
}

- (NSImage *) imageFromPath: (NSString *) path usingNSImageResizedTo: (NSSize) targetSize
{
    NSImage *initialImage = [[NSImage alloc] initWithContentsOfFile: path];
    
    NSSize pinnedSize = [ResizeImageOperation resizeOriginal: initialImage.size intoTargetSize: targetSize];
    
    NSImage *finalImage = [[NSImage alloc] initWithSize: targetSize];
    [finalImage lockFocus];
    [[NSGraphicsContext currentContext] setShouldAntialias: YES];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [initialImage drawInRect: NSMakeRect(0, 0, pinnedSize.width, pinnedSize.height) fromRect: NSMakeRect(0, 0, initialImage.size.width, initialImage.size.height) operation: NSCompositeCopy fraction: 1.0];
    [finalImage unlockFocus];
    
    return finalImage;
}

- (void) main
{
	if (self.imagePath)
	{
		if (self.shouldUseCustomSize) {
			NSSize targetSize = self.shouldUseCustomSize ? self.destinationSize : NSZeroSize;
			
			//self.finalImage = [self imageFromPath: self.imagePath usingCGImageSourceResizedTo: targetSize];
            self.finalImage = [self imageFromPath: self.imagePath usingNSImageResizedTo: targetSize];
			
			self.addFrameOperation.image = self.finalImage;
		} else {
			self.addFrameOperation.image = [[NSImage alloc] initWithContentsOfFile: self.imagePath];
		}
	}
	
	for (NSOperation *operation in self.dependencies) {
		[self removeDependency: operation];
	}
	self.addFrameOperation = nil;
}

@end
