// Included by the standalone regression harness; no application test hooks.
static NSString *WriteCGFixture(NSString *directory, NSString *name, CGImageRef image, NSDictionary *properties)
{
    NSString *path = [directory stringByAppendingPathComponent:name];
    CFStringRef type = [name.pathExtension isEqual:@"tiff"] ? CFSTR("public.tiff") : CFSTR("public.png");
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], type, 1, NULL);
    Check(destination != NULL && image != NULL, @"Create precision fixture");
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    Check(CGImageDestinationFinalize(destination), @"Write precision fixture");
    CFRelease(destination);
    return path;
}

static NSString *GradientFixture(NSString *directory)
{
    const size_t width = 1024, height = 64;
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 8];
    uint16_t *pixels = data.mutableBytes;
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        uint16_t value = (uint16_t)lrint(x * 65535.0 / (width - 1));
        size_t i = (y * width + x) * 4;
        pixels[i] = pixels[i+1] = pixels[i+2] = value; pixels[i+3] = 65535;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image = CGImageCreate(width, height, 16, 64, width * 8, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little, provider, NULL, NO, kCGRenderingIntentDefault);
    NSString *path = WriteCGFixture(directory, @"gradient16.png", image, @{});
    CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(space);
    return path;
}

static CVPixelBufferRef RenderFixture(NSString *path, NSSize size, AVVideoCodecType codec)
{
    MovieFrameRenderer *renderer = [[MovieFrameRenderer alloc] initWithFrameSize:size codec:codec];
    CVPixelBufferRef buffer = NULL;
    Check(CVPixelBufferCreate(NULL, size.width, size.height, renderer.pixelFormat,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &buffer) == kCVReturnSuccess, @"Allocate renderer destination");
    NSError *error = nil;
    Check([renderer renderImageAtPath:path intoPixelBuffer:buffer error:&error], [NSString stringWithFormat:@"Render %@: %@", path.lastPathComponent, error]);
    Check(CFEqual(CVBufferGetAttachment(buffer, kCVImageBufferColorPrimariesKey, NULL), kCVImageBufferColorPrimaries_ITU_R_709_2) &&
          CFEqual(CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL), kCVImageBufferTransferFunction_ITU_R_709_2) &&
          CFEqual(CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL), kCVImageBufferYCbCrMatrix_ITU_R_709_2), @"Rec.709 buffer attachments");
    return buffer;
}

static NSData *LumaData(CVPixelBufferRef buffer)
{
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    NSMutableData *data = [NSMutableData dataWithLength:width * height * sizeof(uint16_t)];
    uint16_t *values = data.mutableBytes;
    BOOL eight = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    for (size_t y = 0; y < height; y++) {
        uint8_t *row = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        for (size_t x = 0; x < width; x++) values[y * width + x] = eight ? row[x] * 4 : ((uint16_t *)row)[x] >> 6;
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return data;
}

static NSUInteger DistinctValues(NSData *data)
{
    NSMutableIndexSet *values = [NSMutableIndexSet indexSet];
    const uint16_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length / 2; i++) [values addIndex:p[i]];
    return values.count;
}

static NSArray<NSData *> *DecodedLuma(NSString *path, OSType pixelFormat)
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:NULL];
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(pixelFormat)}];
    [reader addOutput:output];
    Check([reader startReading], @"Start high-precision decoder");
    NSMutableArray *frames = [NSMutableArray array];
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        [frames addObject:LumaData(CMSampleBufferGetImageBuffer(sample))];
        CFRelease(sample);
    }
    Check(reader.status == AVAssetReaderStatusCompleted, @"Finish high-precision decoding");
    return frames;
}

static double LumaRMSE(NSData *reference, NSData *decoded)
{
    Check(reference.length == decoded.length, @"Comparison dimensions match");
    const uint16_t *a = reference.bytes, *b = decoded.bytes;
    double error = 0;
    for (NSUInteger i = 0; i < reference.length / 2; i++) { double d = a[i] - b[i]; error += d * d; }
    return sqrt(error / (reference.length / 2));
}

static void CheckMovieFormat(NSString *path, AVVideoCodecType codec)
{
    AVAssetTrack *track = [[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil] tracksWithMediaType:AVMediaTypeVideo].firstObject;
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    NSDictionary *extensions = (__bridge NSDictionary *)CMFormatDescriptionGetExtensions(format);
    Check([extensions[(id)kCMFormatDescriptionExtension_ColorPrimaries] isEqual:(id)kCVImageBufferColorPrimaries_ITU_R_709_2] &&
          [extensions[(id)kCMFormatDescriptionExtension_TransferFunction] isEqual:(id)kCVImageBufferTransferFunction_ITU_R_709_2] &&
          [extensions[(id)kCMFormatDescriptionExtension_YCbCrMatrix] isEqual:(id)kCVImageBufferYCbCrMatrix_ITU_R_709_2], @"Encoded Rec.709 metadata");
    NSDictionary *atoms = extensions[(id)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    if ([codec isEqual:AVVideoCodecTypeHEVC]) {
        NSData *data = atoms[@"hvcC"]; const uint8_t *p = data.bytes;
        Check(data.length > 18 && (p[1] & 31) == 2 && (p[16] & 3) == 1 && (p[17] & 7) == 2 && (p[18] & 7) == 2,
            @"HEVC Main10, 10-bit luma/chroma, 4:2:0 bitstream");
    } else if ([codec isEqual:AVVideoCodecTypeH264]) {
        NSData *data = atoms[@"avcC"]; const uint8_t *p = data.bytes;
        Check(data.length > 3 && p[1] == 100, @"H.264 High profile bitstream");
    } else {
        Check(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422 &&
            [extensions[(id)kCMFormatDescriptionExtension_BitsPerComponent] integerValue] >= 10, @"Native high-precision ProRes 422");
    }
}

// Interrupt immediately after real rendering to exercise buffer lifetime and
// accepted cancellation, without a timing-dependent GPU race.
static dispatch_block_t renderedHook;
@interface MovieFrameRenderer (RegressionRender)
- (BOOL)regressionRender:(NSString *)path intoPixelBuffer:(CVPixelBufferRef)buffer error:(NSError **)error;
@end
@implementation MovieFrameRenderer (RegressionRender)
- (BOOL)regressionRender:(NSString *)path intoPixelBuffer:(CVPixelBufferRef)buffer error:(NSError **)error
{
    BOOL result = [self regressionRender:path intoPixelBuffer:buffer error:error];
    dispatch_block_t hook = renderedHook; renderedHook = nil;
    if (hook) hook();
    return result;
}
@end

static void PrecisionChecks(NSString *directory)
{
    NSString *gradient = GradientFixture(directory);
    for (AVVideoCodecType codec in @[AVVideoCodecTypeH264, AVVideoCodecTypeHEVC, AVVideoCodecTypeAppleProRes422]) {
        BOOL h264 = [codec isEqual:AVVideoCodecTypeH264], proRes = [codec isEqual:AVVideoCodecTypeAppleProRes422];
        OSType format = h264 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : proRes ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        CVPixelBufferRef buffer = RenderFixture(gradient, NSMakeSize(1024, 64), codec);
        Check(CVPixelBufferGetPixelFormatType(buffer) == format, @"Codec uses its promised input pixel format");
        NSData *reference = LumaData(buffer);
        if (!h264) Check(DistinctValues(reference) > 600, @"16-bit source retains more than 8-bit precision before encoding");
        const uint16_t *values = reference.bytes;
        Check(values[0] >= 60 && values[0] <= 68 && values[1023] >= 936 && values[1023] <= 944, @"Video-range black and white levels");
        if (h264) {
            BOOL varies = NO;
            for (NSUInteger y = 1; y < 64; y++) for (NSUInteger x = 10; x < 1010; x++) varies |= values[y * 1024 + x] != values[x];
            Check(varies, @"H.264 destination dithering varies equal-source pixels");
        }
        CVPixelBufferRelease(buffer);
        ImagesToMovie *model = Model(@[gradient]); model.codec = codec; model.frameSize = NSMakeSize(1024, 64);
        NSString *output = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"precision-%@.%@", codec, proRes ? @"mov" : @"mp4"]];
        NSError *error = Export(model, output, nil, nil);
        Check(!error, [NSString stringWithFormat:@"Precision export %@: %@", codec, error]);
        CheckMovieFormat(output, codec);
        NSArray *decoded = DecodedLuma(output, format);
        Check(decoded.count == 1 && LumaRMSE(reference, decoded[0]) < 8, @"Decoded gradient has no range/gamma shift");
        if (!h264) Check(DistinctValues(decoded[0]) > 300, @"Encoded precision survives decoding");
        Exchange(MovieFrameRenderer.class, @selector(renderImageAtPath:intoPixelBuffer:error:), @selector(regressionRender:intoPixelBuffer:error:));
        renderedHook = ^{ [model cancel]; };
        PreservedFailure(model, output, NO);
        Check(!renderedHook, @"Cancellation reached the rendering boundary");
        Exchange(MovieFrameRenderer.class, @selector(renderImageAtPath:intoPixelBuffer:error:), @selector(regressionRender:intoPixelBuffer:error:));
        Check(Export(model, output, nil, nil) == nil, @"Retry after rendering cancellation");
        model.frameSize = NSMakeSize(511, 63);
        Check(Export(model, output, nil, nil) == nil, @"Odd output dimensions remain supported");
        NSLog(@"PASS: %@ input precision, SDR tags, bitstream profile, dither/range and rendering cancellation", codec);
    }
}

static NSString *PatchFixture(NSString *directory, NSString *name, CGColorSpaceRef space, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGContextRef context = CGBitmapContextCreate(NULL, 64, 32, 16, 0, space,
        kCGBitmapFloatComponents | kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little);
    Check(context != NULL, @"Create floating-point color fixture");
    CGFloat components[] = {red, green, blue, alpha};
    CGColorRef fill = CGColorCreate(space, components);
    CGContextSetFillColorWithColor(context, fill);
    CGContextFillRect(context, CGRectMake(0, 0, 64, 32));
    CGColorRelease(fill);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSString *path = WriteCGFixture(directory, name, image, @{});
    CGImageRelease(image); CGContextRelease(context);
    return path;
}

static NSString *UntaggedPNGFixture(NSString *directory, NSString *input)
{
    NSData *png = [NSData dataWithContentsOfFile:input];
    const uint8_t *bytes = png.bytes;
    Check(png.length >= 8 && memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0, @"Read PNG color fixture");
    NSMutableData *output = [NSMutableData dataWithBytes:bytes length:8];
    NSUInteger offset = 8;
    while (offset + 12 <= png.length) {
        uint32_t networkLength;
        memcpy(&networkLength, bytes + offset, sizeof(networkLength));
        NSUInteger chunkLength = CFSwapInt32BigToHost(networkLength);
        Check(chunkLength <= png.length - offset - 12, @"Parse PNG color fixture");
        const uint8_t *kind = bytes + offset + 4;
        if (memcmp(kind, "iCCP", 4) && memcmp(kind, "sRGB", 4) &&
            memcmp(kind, "gAMA", 4) && memcmp(kind, "cHRM", 4))
            [output appendBytes:bytes + offset length:chunkLength + 12];
        offset += chunkLength + 12;
    }
    Check(offset == png.length, @"Finish PNG color fixture");
    NSString *path = [directory stringByAppendingPathComponent:@"untagged16.png"];
    Check([output writeToFile:path atomically:YES], @"Write untagged color fixture");
    return path;
}

static NSData *RGBBytes(CVPixelBufferRef buffer)
{
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}] render:image toBitmap:data.mutableBytes
        rowBytes:width * 4 bounds:CGRectMake(0, 0, width, height) format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    return data;
}

static NSData *DecodedRGBBytes(NSString *path, OSType pixelFormat)
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:NULL];
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(pixelFormat)}];
    [reader addOutput:output];
    Check([reader startReading], @"Start SDR color decoder");
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    Check(sample != NULL, @"Decode SDR color frame");
    NSData *rgb = RGBBytes(CMSampleBufferGetImageBuffer(sample));
    CFRelease(sample);
    Check([output copyNextSampleBuffer] == NULL && reader.status == AVAssetReaderStatusCompleted,
        @"Finish SDR color decoding");
    return rgb;
}

static void ColorSourceChecks(NSString *directory, NSString *ordinary)
{
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    NSString *gray = PatchFixture(directory, @"gray16.png", srgb, 0.5, 0.5, 0.5, 1);
    NSString *untagged = UntaggedPNGFixture(directory, gray);
    NSString *alpha = PatchFixture(directory, @"alpha16.png", linear, 1, 1, 1, 0.25);
    NSString *p3path = PatchFixture(directory, @"p3.png", p3, 0.6, 0.4, 0.2, 1);
    for (NSString *path in @[gray, untagged, alpha, p3path]) {
        CVPixelBufferRef buffer = RenderFixture(path, NSMakeSize(64, 32), AVVideoCodecTypeHEVC);
        NSData *rgb = RGBBytes(buffer); const uint8_t *values = rgb.bytes;
        if ([path isEqual:gray] || [path isEqual:untagged])
            Check(abs(values[0] - 128) <= 3 && abs(values[1] - 128) <= 3 && abs(values[2] - 128) <= 3,
                @"Tagged and untagged sRGB midgray round trip has no gamma shift");
        if ([path isEqual:alpha]) Check(abs(values[0] - 137) <= 3 && abs(values[1] - 137) <= 3 && abs(values[2] - 137) <= 3, @"Transparency composites over black in linear light");
        if ([path isEqual:p3path]) {
            // Independent ColorSync conversion of the same embedded-profile color.
            CGFloat components[] = {0.6, 0.4, 0.2, 1};
            CGColorRef color = CGColorCreate(p3, components);
            CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, color, NULL);
            const CGFloat *expected = CGColorGetComponents(converted);
            for (int channel = 0; channel < 3; channel++) Check(fabs(values[channel] - expected[channel] * 255) <= 4, @"Embedded P3 converts to SDR accurately");
            CGColorRelease(converted); CGColorRelease(color);
        }
        if ([path isEqual:gray] || [path isEqual:p3path]) {
            ImagesToMovie *model = Model(@[path]); model.codec = AVVideoCodecTypeHEVC;
            model.frameSize = NSMakeSize(64, 32);
            NSString *movie = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"encoded-%@.mp4", path.lastPathComponent]];
            Check(Export(model, movie, nil, nil) == nil, @"Export color reference movie");
            NSData *decoded = DecodedRGBBytes(movie, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
            const uint8_t *roundtrip = decoded.bytes;
            for (NSUInteger channel = 0; channel < 3; channel++)
                Check(abs(roundtrip[channel] - values[channel]) <= 4,
                    @"Encoded Rec.709 movie preserves source colors through decoding");
        }
        CVPixelBufferRelease(buffer);
    }
    // A genuine grayscale image exercises non-RGB decoding.
    CGColorSpaceRef mono = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, 64, 32, 8, 0, mono, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetGrayFillColor(bitmap, 0.5, 1); CGContextFillRect(bitmap, CGRectMake(0, 0, 64, 32));
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    NSString *monoPath = WriteCGFixture(directory, @"monochrome.png", image, @{});
    CGImageRelease(image); CGContextRelease(bitmap); CGColorSpaceRelease(mono);
    CVPixelBufferRef buffer = RenderFixture(monoPath, NSMakeSize(64, 32), AVVideoCodecTypeHEVC);
    NSData *rgb = RGBBytes(buffer); const uint8_t *values = rgb.bytes;
    Check(abs(values[0] - values[1]) < 3 && abs(values[1] - values[2]) < 3 && values[0] > 100 && values[0] < 150, @"Grayscale remains neutral");
    CVPixelBufferRelease(buffer);

    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:ordinary], NULL);
    image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    NSString *rotated = WriteCGFixture(directory, @"oriented.tiff", image, @{(id)kCGImagePropertyOrientation:@6});
    Check(NSEqualSizes([MovieFrameRenderer imageSizeAtPath:rotated error:NULL], NSMakeSize(180, 320)), @"Orientation metadata changes readiness dimensions");
    buffer = RenderFixture(rotated, NSMakeSize(180, 320), AVVideoCodecTypeHEVC);
    rgb = RGBBytes(buffer); values = rgb.bytes;
    // The bitmap rows are top-down: clockwise rotation moves the original
    // white top-left marker to top-right and black bottom-left to top-left.
    size_t topRight = (10 * 180 + 170) * 4, topLeft = (10 * 180 + 10) * 4;
    Check(values[topRight] > 220 && values[topRight+1] > 220 && values[topRight+2] > 220 && values[topLeft] < 40,
        @"Orientation metadata is applied to pixels without a vertical flip");
    CVPixelBufferRelease(buffer); CGImageRelease(image); CFRelease(source);
    CGColorSpaceRelease(srgb); CGColorSpaceRelease(p3); CGColorSpaceRelease(linear);
    NSLog(@"PASS: high-precision color, grayscale, alpha, embedded P3 and orientation");
}

static NSArray<NSString *> *QualityFixtures(NSString *directory)
{
    NSMutableArray *paths = [NSMutableArray array];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for (NSUInteger frame = 0; frame < 12; frame++) {
        const size_t width = 640, height = 360;
        NSMutableData *data = [NSMutableData dataWithLength:width * height * 8];
        uint16_t *pixels = data.mutableBytes;
        for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
            double ramp = (double)((x + frame * 7) % width) / (width - 1);
            uint32_t noise = (uint32_t)(x + frame * 3) * 73856093u ^ (uint32_t)y * 19349663u;
            for (int channel = 0; channel < 3; channel++) {
                double value = y < 120 ? ramp : y < 240 ? ((noise >> (channel * 7)) & 255) / 255.0 : 0.15;
                if (y >= 240 && (x + frame * 3) % 17 == (NSUInteger)channel) value = 1;
                pixels[(y * width + x) * 4 + channel] = lrint(value * 65535);
            }
            pixels[(y * width + x) * 4 + 3] = 65535;
        }
        CGContextRef context = CGBitmapContextCreate(data.mutableBytes, width, height, 16, width * 8, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little);
        Check(context != NULL, @"Create quality fixture context");
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        [[NSString stringWithFormat:@"Moving text %02lu", frame] drawAtPoint:NSMakePoint(20 + frame * 9, 20)
            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:23], NSForegroundColorAttributeName:NSColor.whiteColor}];
        [NSGraphicsContext restoreGraphicsState];
        CGImageRef image = CGBitmapContextCreateImage(context);
        [paths addObject:WriteCGFixture(directory, [NSString stringWithFormat:@"quality-%02lu.png", frame], image, @{})];
        CGImageRelease(image); CGContextRelease(context);
    }
    CGColorSpaceRelease(space);
    return paths;
}

static NSDictionary *capturedVideoSettings;
@interface AVAssetWriterInput (RegressionSettings)
+ (instancetype)regressionInputWithMediaType:(AVMediaType)type outputSettings:(NSDictionary *)settings;
@end
@implementation AVAssetWriterInput (RegressionSettings)
+ (instancetype)regressionInputWithMediaType:(AVMediaType)type outputSettings:(NSDictionary *)settings
{
    capturedVideoSettings = [settings copy];
    return [self regressionInputWithMediaType:type outputSettings:settings];
}
@end

static void QualityComparisons(NSString *directory)
{
    NSArray *paths = QualityFixtures(directory);
    Exchange(object_getClass(AVAssetWriterInput.class), @selector(assetWriterInputWithMediaType:outputSettings:),
        @selector(regressionInputWithMediaType:outputSettings:));
    NSMutableString *report = [NSMutableString stringWithString:@"codec,quality,bytes,seconds,luma_rmse_10bit\n"];
    for (AVVideoCodecType codec in @[AVVideoCodecTypeH264, AVVideoCodecTypeHEVC]) {
        OSType format = [codec isEqual:AVVideoCodecTypeH264] ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        NSMutableArray *reference = [NSMutableArray array];
        for (NSString *path in paths) {
            CVPixelBufferRef buffer = RenderFixture(path, NSMakeSize(640, 360), codec);
            [reference addObject:LumaData(buffer)]; CVPixelBufferRelease(buffer);
        }
        for (NSUInteger quality = 0; quality < 3; quality++) {
            ImagesToMovie *model = Model(paths); model.codec = codec; model.frameSize = NSMakeSize(640, 360);
            model.qualityMode = quality; model.averageBitRate = 20000000;
            NSString *output = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"quality-%@-%lu.mp4", codec, quality]];
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSError *error = Export(model, output, ^{ model.qualityMode = -1; model.averageBitRate = 0; }, nil);
            double duration = CFAbsoluteTimeGetCurrent() - start;
            Check(!error, [NSString stringWithFormat:@"Quality comparison export: %@", error]);
            NSDictionary *compression = capturedVideoSettings[AVVideoCompressionPropertiesKey];
            Check([capturedVideoSettings[AVVideoEncoderSpecificationKey][(id)kVTVideoEncoderSpecification_EncoderID] length] > 0,
                @"Writer uses the probed encoder identifier");
            Check(!compression[(id)kVTCompressionPropertyKey_AverageBitRate] &&
                !compression[(id)kVTCompressionPropertyKey_ConstantBitRate], @"Legacy rate controls excluded");
            Check([compression[(id)kVTCompressionPropertyKey_MaxKeyFrameInterval] integerValue] == 90, @"Three-second maximum keyframe interval");
            if (quality == MovieQualityCustomBitrate) {
                Check(!compression[(id)kVTCompressionPropertyKey_ConstantQualityFactor] &&
                    [compression[(id)kVTCompressionPropertyKey_VariableBitRate] integerValue] == 20000000 &&
                    [compression[(id)kVTCompressionPropertyKey_VBVMaxBitRate] integerValue] == 30000000,
                    @"Custom uses frozen variable target and 1.5-times peak only");
            } else {
                Check(!compression[(id)kVTCompressionPropertyKey_VariableBitRate] &&
                    [compression[(id)kVTCompressionPropertyKey_ConstantQualityFactor] doubleValue] == (quality == MovieQualityHigh ? 0.75 : 0.5) &&
                    compression[(id)kVTCompressionPropertyKey_VBVMaxBitRate] != nil,
                    @"Automatic quality uses frozen factor and retains preset peak constraint");
            }
            NSArray *decoded = DecodedLuma(output, format);
            Check(decoded.count == paths.count, @"Quality comparison frame count");
            double rmse = 0;
            for (NSUInteger frame = 0; frame < decoded.count; frame++) rmse += LumaRMSE(reference[frame], decoded[frame]);
            rmse /= decoded.count;
            Check(rmse < 40, @"Quality comparison has bounded decoded error");
            [report appendFormat:@"%@,%@,%llu,%.3f,%.3f\n", codec, @[@"Standard", @"High", @"Custom20Mbps"][quality],
                [NSFileManager.defaultManager attributesOfItemAtPath:output error:NULL].fileSize, duration, rmse];
            AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:
                [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:output] options:nil]];
            CGImageRef image = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
            WriteCGFixture(directory, [NSString stringWithFormat:@"preview-%@-%lu.png", codec, quality], image, @{});
            CGImageRelease(image);
            CheckMovieFormat(output, codec);
        }
    }
    Exchange(object_getClass(AVAssetWriterInput.class), @selector(assetWriterInputWithMediaType:outputSettings:),
        @selector(regressionInputWithMediaType:outputSettings:));
    Check([report writeToFile:[directory stringByAppendingPathComponent:@"quality-comparison.csv"] atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"Write quality measurements");
    NSLog(@"PASS: quality comparisons (10-bit code-value RMSE)\n%@", report);
}
