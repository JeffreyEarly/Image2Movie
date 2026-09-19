#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

// Private, serial-use renderer shared by readiness checks and movie export.
@interface MovieFrameRenderer : NSObject
+ (NSSize)imageSizeAtPath:(NSString *)path error:(NSError **)error;
- (instancetype)initWithFrameSize:(NSSize)size codec:(AVVideoCodecType)codec;
@property(readonly) OSType pixelFormat;
- (BOOL)renderImageAtPath:(NSString *)path intoPixelBuffer:(CVPixelBufferRef)buffer error:(NSError **)error;
@end
