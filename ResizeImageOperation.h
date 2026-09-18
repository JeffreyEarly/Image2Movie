//
//  ResizeImageOperation.h
//  Image2Movie
//
//  Created by Jeffrey J. Early on 8/6/12.
//
//

#import <Foundation/Foundation.h>

@class AddMovieFrameOperation;
@interface ResizeImageOperation : NSOperation

// Returns a size with the same aspect ratio as the originalSize, that fits within the target size.
+ (NSSize) resizeOriginal: (NSSize) originalSize intoTargetSize: (NSSize) targetSize;

@property(nonatomic,strong) NSString *imagePath;
@property BOOL shouldUseCustomSize;
@property NSSize destinationSize;
@property(nonatomic,strong) NSImage *finalImage;
@property(nonatomic, strong) AddMovieFrameOperation *addFrameOperation;



// Pulling in an image from CGImageSource doesn't appear to work for eps files.
- (NSImage *) imageFromPath: (NSString *) path usingCGImageSourceResizedTo: (NSSize) targetSize;

// But, NSImage consistently does the job.
- (NSImage *) imageFromPath: (NSString *) path usingNSImageResizedTo: (NSSize) targetSize;

@end
