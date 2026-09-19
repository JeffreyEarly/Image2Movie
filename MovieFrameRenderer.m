#import "MovieFrameRenderer.h"

#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

@interface MovieSource : NSObject {
@public
    CGImageRef raster;
    CGPDFDocumentRef pdf;
    NSImageRep *vectorRep;
    NSSize size;
    NSUInteger orientation;
    BOOL untaggedRGB;
}
@end

@implementation MovieSource
- (void)dealloc
{
    if (raster) CGImageRelease(raster);
    if (pdf) CGPDFDocumentRelease(pdf);
}
@end

static NSError *FrameError(NSString *path, NSString *reason, NSError *underlying)
{
    NSMutableDictionary *info = [@{ NSLocalizedDescriptionKey :
        [NSString stringWithFormat:@"The image “%@” %@", path.lastPathComponent, reason] } mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:@"Image2MovieErrorDomain" code:1 userInfo:info];
}

// Both readiness and rendering use this path, so a lazy raster decoder is forced
// before either reports success. No decoded image is kept between frames.
static MovieSource *LoadSource(NSString *path, NSError **error)
{
    NSURL *url = [NSURL fileURLWithPath:path ?: @""];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    MovieSource *source = [[MovieSource alloc] init];
    source->orientation = 1;

    BOOL hasImageSource = imageSource != NULL;
    CFStringRef type = imageSource ? CGImageSourceGetType(imageSource) : NULL;
    if (imageSource && CGImageSourceGetCount(imageSource) && type &&
        CFEqual(type, CFSTR("com.adobe.pdf"))) {
        source->pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
        CGPDFPageRef page = source->pdf ? CGPDFDocumentGetPage(source->pdf, 1) : NULL;
        if (page) {
            CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
            BOOL rotated = CGPDFPageGetRotationAngle(page) % 180 != 0;
            source->size = NSMakeSize(round(rotated ? box.size.height : box.size.width),
                                      round(rotated ? box.size.width : box.size.height));
        }
    } else if (imageSource && CGImageSourceGetCount(imageSource)) {
        NSDictionary *options = @{ (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
                                   (__bridge NSString *)kCGImageSourceShouldAllowFloat : @YES,
                                   (__bridge NSString *)kCGImageSourceDecodeRequest : (__bridge NSString *)kCGImageSourceDecodeToSDR };
        source->raster = CGImageSourceCreateImageAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
        if (source->raster) {
            CGDataProviderRef provider = CGImageGetDataProvider(source->raster);
            CFDataRef decoded = provider ? CGDataProviderCopyData(provider) : NULL;
            BOOL complete = decoded && CFDataGetLength(decoded) > 0 &&
                CGImageSourceGetStatusAtIndex(imageSource, 0) == kCGImageStatusComplete;
            if (decoded) CFRelease(decoded);
            if (!complete) {
                CGImageRelease(source->raster);
                source->raster = NULL;
            } else {
                CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
                NSDictionary *metadata = (__bridge NSDictionary *)properties;
                NSNumber *value = metadata[(__bridge NSString *)kCGImagePropertyOrientation];
                NSUInteger orientation = value.unsignedIntegerValue;
                if (orientation >= 1 && orientation <= 8) source->orientation = orientation;
                source->untaggedRGB = [metadata[(__bridge NSString *)kCGImagePropertyColorModel]
                    isEqual:(__bridge NSString *)kCGImagePropertyColorModelRGB] &&
                    !metadata[(__bridge NSString *)kCGImagePropertyProfileName];
                if (properties) CFRelease(properties);
                BOOL swapsAxes = source->orientation >= 5;
                source->size = NSMakeSize(swapsAxes ? CGImageGetHeight(source->raster) : CGImageGetWidth(source->raster),
                                          swapsAxes ? CGImageGetWidth(source->raster) : CGImageGetHeight(source->raster));
            }
        }
    }
    if (imageSource) CFRelease(imageSource);

    // AppKit can supply a vector representation for formats Image I/O does not
    // decode. Draw that representation into the floating-point target canvas.
    if (!source->pdf && !source->raster && !hasImageSource) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        for (NSImageRep *rep in image.representations) {
            if ([rep isKindOfClass:[NSBitmapImageRep class]] ||
                !isfinite(rep.size.width) || !isfinite(rep.size.height) ||
                rep.size.width <= 0 || rep.size.height <= 0) continue;
            source->vectorRep = rep;
            source->size = NSMakeSize(round(rep.size.width), round(rep.size.height));
            break;
        }
    }

    if ((!source->pdf && !source->raster && !source->vectorRep) ||
        !isfinite(source->size.width) || !isfinite(source->size.height) ||
        source->size.width <= 0 || source->size.height <= 0) {
        if (error) *error = FrameError(path, @"could not be completely decoded.", nil);
        return nil;
    }
    return source;
}

@interface MovieFrameRenderer () {
    CIContext *_context;
    NSSize _frameSize;
}
@property(readwrite) OSType pixelFormat;
@end

@implementation MovieFrameRenderer

+ (NSSize)imageSizeAtPath:(NSString *)path error:(NSError **)error
{
    MovieSource *source = LoadSource(path, error);
    return source ? source->size : NSZeroSize;
}

- (instancetype)initWithFrameSize:(NSSize)size codec:(AVVideoCodecType)codec
{
    if (!(self = [super init])) return nil;
    _frameSize = size;
    if ([codec isEqualToString:AVVideoCodecTypeH264]) {
        _pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    } else if ([codec isEqualToString:AVVideoCodecTypeHEVC]) {
        _pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    } else if ([codec isEqualToString:AVVideoCodecTypeAppleProRes422]) {
        _pixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    } else {
        return nil;
    }
    CGColorSpaceRef working = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!working) return nil;
    _context = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : (__bridge id)working,
                                                kCIContextWorkingFormat : @(kCIFormatRGBAh),
                                                kCIContextHighQualityDownsample : @YES,
                                                kCIContextCacheIntermediates : @NO }];
    CGColorSpaceRelease(working);
    return _context ? self : nil;
}

- (CIImage *)imageForVectorSource:(MovieSource *)source path:(NSString *)path error:(NSError **)error
{
    size_t width = (size_t)_frameSize.width;
    size_t height = (size_t)_frameSize.height;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CGContextRef bitmap = space ? CGBitmapContextCreate(NULL, width, height, 16, 0, space,
        kCGBitmapFloatComponents | kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little) : NULL;
    if (space) CGColorSpaceRelease(space);
    if (!bitmap) {
        if (error) *error = FrameError(path, @"could not allocate a vector drawing buffer.", nil);
        return nil;
    }
    CGContextSetRGBFillColor(bitmap, 0, 0, 0, 1);
    CGContextFillRect(bitmap, CGRectMake(0, 0, width, height));
    BOOL drew = NO;
    if (source->pdf) {
        CGPDFPageRef page = CGPDFDocumentGetPage(source->pdf, 1);
        CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
        CGFloat pageWidth = source->size.width, pageHeight = source->size.height;
        CGContextSaveGState(bitmap);
        CGContextScaleCTM(bitmap, width / pageWidth, height / pageHeight);
        CGContextConcatCTM(bitmap, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox,
            CGRectMake(0, 0, pageWidth, pageHeight), 0, true));
        CGContextDrawPDFPage(bitmap, page);
        CGContextRestoreGState(bitmap);
        drew = !CGRectIsEmpty(box);
    } else {
        NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:graphics];
        drew = [source->vectorRep drawInRect:NSMakeRect(0, 0, width, height)];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef snapshot = drew ? CGBitmapContextCreateImage(bitmap) : NULL;
    CGContextRelease(bitmap);
    if (!snapshot) {
        if (error) *error = FrameError(path, @"could not be drawn into a movie frame.", nil);
        return nil;
    }
    CIImage *image = [CIImage imageWithCGImage:snapshot options:@{ kCIImageToneMapHDRtoSDR : @YES }];
    CGImageRelease(snapshot);
    return image;
}

- (BOOL)renderImageAtPath:(NSString *)path intoPixelBuffer:(CVPixelBufferRef)buffer error:(NSError **)error
{
    if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != _pixelFormat ||
        CVPixelBufferGetWidth(buffer) != (size_t)_frameSize.width ||
        CVPixelBufferGetHeight(buffer) != (size_t)_frameSize.height) {
        if (error) *error = FrameError(path, @"has an incompatible movie frame buffer.", nil);
        return NO;
    }
    MovieSource *source = LoadSource(path, error);
    if (!source) return NO;

    CIImage *image;
    if (source->raster) {
        CGColorSpaceRef input = CGImageGetColorSpace(source->raster);
        CGColorSpaceRef fallback = NULL;
        CFStringRef inputName = input ? CGColorSpaceGetName(input) : NULL;
        BOOL genericUntaggedRGB = source->untaggedRGB && input &&
            CGColorSpaceGetModel(input) == kCGColorSpaceModelRGB &&
            (!inputName || CFEqual(inputName, kCGColorSpaceGenericRGB));
        if (!input || CGColorSpaceGetModel(input) == kCGColorSpaceModelUnknown || genericUntaggedRGB) {
            fallback = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        }
        NSMutableDictionary *options = [@{ kCIImageToneMapHDRtoSDR : @YES,
                                           kCIImageExpandToHDR : @NO } mutableCopy];
        if (fallback) options[kCIImageColorSpace] = (__bridge id)fallback;
        image = [CIImage imageWithCGImage:source->raster options:options];
        if (fallback) CGColorSpaceRelease(fallback);
        image = [image imageByApplyingOrientation:(int)source->orientation];
        CGRect extent = image.extent;
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        CGFloat sx = _frameSize.width / source->size.width;
        CGFloat sy = _frameSize.height / source->size.height;
        CIFilter *scale = [CIFilter filterWithName:@"CILanczosScaleTransform" withInputParameters:@{
            kCIInputImageKey : image, kCIInputScaleKey : @(sy), kCIInputAspectRatioKey : @(sx / sy) }];
        image = scale.outputImage;
    } else {
        NSError *preparationError = nil;
        image = [self imageForVectorSource:source path:path error:&preparationError];
        if (!image) {
            if (error) *error = preparationError ?: FrameError(path, @"could not be prepared for rendering.", nil);
            return NO;
        }
    }
    if (!image) {
        if (error) *error = FrameError(path, @"could not be prepared for rendering.", nil);
        return NO;
    }

    CGRect frame = CGRectMake(0, 0, _frameSize.width, _frameSize.height);
    CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:frame];
    image = [[image imageByCompositingOverImage:black] imageByCroppingToRect:frame];
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CIRenderDestination *destination = [[CIRenderDestination alloc] initWithPixelBuffer:buffer];
    // Synthesize the video Rec. 709 space from its actual buffer tags. The
    // named BT.709-5 ICC profile uses a different transfer curve from the
    // HDTV profile that Core Video reconstructs when decoding the movie.
    CGColorSpaceRef output = CVImageBufferCreateColorSpaceFromAttachments((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCVImageBufferColorPrimariesKey : (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2,
        (__bridge NSString *)kCVImageBufferTransferFunctionKey : (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2,
        (__bridge NSString *)kCVImageBufferYCbCrMatrixKey : (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2 });
    if (!destination || !output) {
        if (output) CGColorSpaceRelease(output);
        if (error) *error = FrameError(path, @"could not prepare the Rec. 709 movie frame.", nil);
        return NO;
    }
    // Keep Core Video readers on the same transfer curve used for rendering.
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, output, kCVAttachmentMode_ShouldPropagate);
    destination.colorSpace = output;
    destination.alphaMode = CIRenderDestinationAlphaNone;
    destination.dithered = _pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSError *renderError = nil;
    CIRenderTask *task = [_context startTaskToRender:image toDestination:destination error:&renderError];
    BOOL completed = task && [task waitUntilCompletedAndReturnError:&renderError];
    if (output) CGColorSpaceRelease(output);
    if (!completed && error) *error = FrameError(path, @"could not be rendered into a movie frame.", renderError);
    return completed;
}

@end
