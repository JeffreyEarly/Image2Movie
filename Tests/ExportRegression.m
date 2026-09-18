#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "ImagesToMovie.h"
#import "ImagesToMovieController.h"
#import "PrimaryWindowController.h"

static void Check(BOOL condition, NSString *message)
{
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static void WaitFor(BOOL (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(condition(), @"Timed out waiting for completion");
}

@interface DragFixture : NSObject
@property id draggingSource;
@property NSPasteboard *draggingPasteboard;
@end
@implementation DragFixture
@end

static void TableDragChecks(void)
{
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSArrayController *array = [[NSArrayController alloc] initWithContent:[@[@"a", @"b", @"c", @"d", @"e"] mutableCopy]];
    ImageTableController *controller = [[ImageTableController alloc] init];
    controller.imageTable = table;
    controller.imagePathArrayController = array;
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    DragFixture *drag = [[DragFixture alloc] init];
    drag.draggingSource = table;
    drag.draggingPasteboard = pasteboard;
    Check([pasteboard writeObjects:@[[controller tableView:table pasteboardWriterForRow:1],
                                    [controller tableView:table pasteboardWriterForRow:3]]], @"Write per-row drag items");
    Check([controller tableView:table acceptDrop:(id)drag row:5 dropOperation:NSTableViewDropAbove], @"Accept nonadjacent row move");
    Check([array.arrangedObjects isEqual:@[@"a", @"c", @"e", @"b", @"d"]], @"Move multiple rows down in order");
    [pasteboard clearContents];
    [pasteboard writeObjects:@[[controller tableView:table pasteboardWriterForRow:3],
                              [controller tableView:table pasteboardWriterForRow:4]]];
    Check([controller tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"Accept upward row move");
    Check([array.arrangedObjects isEqual:@[@"b", @"d", @"a", @"c", @"e"]], @"Move multiple rows up in order");
    Check([controller tableView:table pasteboardWriterForRow:-1] == nil &&
          [controller tableView:table pasteboardWriterForRow:5] == nil, @"Reject invalid drag rows");
    [pasteboard clearContents];
    Check(![controller tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"Reject empty local drop");
    drag.draggingSource = nil;
    [pasteboard declareTypes:@[NSFilenamesPboardType] owner:nil];
    [pasteboard setPropertyList:@[@"/tmp/input.png"] forType:NSFilenamesPboardType];
    Check([controller tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"Existing external file drop still works");
    Check([[array.arrangedObjects lastObject] isEqual:@"/tmp/input.png"], @"External file appended");
    [pasteboard releaseGlobally];
    NSLog(@"PASS: modern multi-row dragging and external file drops");
}

// Observe the same properties as the bindings, including progress-triggered Cancel.
@interface ProgressObserver : NSObject
@property BOOL offMainThread;
@property(copy) void (^onProgress)(ImagesToMovie *model);
@end
@implementation ProgressObserver
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    self.offMainThread |= !NSThread.isMainThread;
    if ([path isEqualToString:@"value"] && self.onProgress) self.onProgress(object);
}
@end

// Hold one real writer's finish callback so Cancel -> immediate retry -> late
// completion is deterministic, without adding test hooks to application code.
static dispatch_block_t finishHook;
static dispatch_block_t delayedFinishCompletion;
@interface AVAssetWriter (RegressionFinish)
- (void)regressionFinish:(dispatch_block_t)completion;
@end
@implementation AVAssetWriter (RegressionFinish)
- (void)regressionFinish:(dispatch_block_t)completion
{
    dispatch_block_t hook = finishHook;
    finishHook = nil;
    [self regressionFinish:^{
        if (hook) {
            dispatch_async(dispatch_get_main_queue(), ^{
                delayedFinishCompletion = completion;
                hook();
            });
        } else completion();
    }];
}
@end

static NSString *MakeImage(NSString *directory, NSString *name, NSUInteger width, NSUInteger height, NSUInteger color, BOOL highDPI)
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
    Check(rep != nil, @"Allocate fixture image");
    for (NSUInteger y = 0; y < height; y++) {
        unsigned char *row = rep.bitmapData + y * rep.bytesPerRow;
        for (NSUInteger x = 0; x < width; x++) {
            row[x * 4] = color % 3 == 0 ? 220 : 30;
            row[x * 4 + 1] = color % 3 == 1 ? 220 : 30;
            row[x * 4 + 2] = color % 3 == 2 ? 220 : 30;
            row[x * 4 + 3] = 255;
            if (x < width / 8 && y < height / 8)
                row[x * 4] = row[x * 4 + 1] = row[x * 4 + 2] = 255;
            if (x < width / 8 && y > height * 7 / 8)
                row[x * 4] = row[x * 4 + 1] = row[x * 4 + 2] = 0;
        }
    }
    if (highDPI) rep.size = NSMakeSize(width / 2.0, height / 2.0);
    NSString *path = [directory stringByAppendingPathComponent:name];
    Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"Write PNG fixture");
    return path;
}

static NSString *MakePDF(NSString *directory)
{
    NSMutableData *data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect bounds = CGRectMake(0, 0, 320, 180);
    CGContextRef context = CGPDFContextCreate(consumer, &bounds, NULL);
    CGPDFContextBeginPage(context, NULL);
    CGContextSetRGBFillColor(context, 0.86, 0.12, 0.12, 1);
    CGContextFillRect(context, bounds);
    CGPDFContextEndPage(context);
    CGPDFContextClose(context);
    CGContextRelease(context);
    CGDataConsumerRelease(consumer);
    NSString *path = [directory stringByAppendingPathComponent:@"vector.pdf"];
    Check([data writeToFile:path atomically:YES], @"Write PDF fixture");
    return path;
}

static ImagesToMovie *Model(NSArray *paths)
{
    ImagesToMovie *model = [[ImagesToMovie alloc] init];
    model.imagePaths = [paths mutableCopy];
    model.frameSize = NSMakeSize(320, 180);
    model.frameRate = 30;
    model.averageBitRate = 1600000;
    model.profile = AVVideoProfileLevelH264Main30;
    return model;
}

static NSError *Export(ImagesToMovie *model, NSString *path, void (^afterStart)(void), void (^progress)(ImagesToMovie *))
{
    ProgressObserver *observer = [[ProgressObserver alloc] init];
    observer.onProgress = progress;
    NSArray *keys = @[@"movieCreationInProgress", @"minValue", @"maxValue", @"value", @"progressString"];
    for (NSString *key in keys) [model addObserver:observer forKeyPath:key options:0 context:NULL];
    __block NSUInteger completions = 0;
    __block NSError *result;
    [model createMovieAtPath:path completionHandler:^(NSError *error) {
        Check(NSThread.isMainThread, @"Completion must run on main thread");
        Check(!model.movieCreationInProgress, @"Completion must restore idle state");
        completions++;
        result = error;
    }];
    if (afterStart) afterStart();
    WaitFor(^BOOL { return completions != 0; });
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    Check(completions == 1, @"Exactly one completion");
    Check(!observer.offMainThread, @"All bound property notifications must run on main thread");
    for (NSString *key in keys) [model removeObserver:observer forKeyPath:key];
    return result;
}

static void ValidateMovie(NSString *path, NSSize size, NSUInteger count, BOOL raster)
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    Check(track != nil, @"Export has a video track");
    NSError *error;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [reader addOutput:output];
    Check([reader startReading], [NSString stringWithFormat:@"Decode export: %@", reader.error]);
    NSUInteger frames = 0;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        Check(CVPixelBufferGetWidth(buffer) == size.width && CVPixelBufferGetHeight(buffer) == size.height, @"Decoded dimensions");
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        unsigned char *pixel = CVPixelBufferGetBaseAddress(buffer) +
            (NSUInteger)(size.height / 2) * CVPixelBufferGetBytesPerRow(buffer) + (NSUInteger)(size.width / 2) * 4;
        for (NSUInteger channel = 0; channel < 3; channel++)
            Check(channel == 2 - frames % 3 ? pixel[channel] > 170 : pixel[channel] < 80, @"Decoded frame color and order");
        if (raster) {
            unsigned char *top = CVPixelBufferGetBaseAddress(buffer) + (NSUInteger)(size.height / 16) * CVPixelBufferGetBytesPerRow(buffer) + (NSUInteger)(size.width / 16) * 4;
            unsigned char *bottom = CVPixelBufferGetBaseAddress(buffer) + (NSUInteger)(size.height * 15 / 16) * CVPixelBufferGetBytesPerRow(buffer) + (NSUInteger)(size.width / 16) * 4;
            Check(top[0] > 200 && top[1] > 200 && top[2] > 200 && bottom[0] < 50 && bottom[1] < 50 && bottom[2] < 50, @"Frame orientation");
        }
        Check(fabs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - frames / 30.0) < 0.001, @"Frame presentation time");
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        CFRelease(sample);
        frames++;
    }
    Check(reader.status == AVAssetReaderStatusCompleted && frames == count, @"Decoded frame count");
    Check(fabs(CMTimeGetSeconds(asset.duration) - count / 30.0) < 0.001, @"Movie duration");
}

static void PreservedFailure(ImagesToMovie *model, NSString *path, BOOL cancel)
{
    NSData *original = [@"previous movie: must survive" dataUsingEncoding:NSUTF8StringEncoding];
    Check([original writeToFile:path atomically:YES], @"Write existing destination");
    NSError *error = Export(model, path, cancel ? ^{ [model cancel]; } : nil, nil);
    Check(error != nil, @"Expected export failure");
    if (cancel) Check([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError, @"Cancellation result");
    Check([[NSData dataWithContentsOfFile:path] isEqual:original], @"Failure must preserve destination bytes");
}

static void ControllerChecks(NSArray *paths, NSString *large, NSString *dpi, NSString *pdf, NSString *bad)
{
    ImagesToMovieController *controller = [[ImagesToMovieController alloc] init];
    controller.profileDictionaryController = [[NSDictionaryController alloc] init];
    controller.bitRateNumberFormatter = [[NSNumberFormatter alloc] init];
    [controller.profileDictionaryController bind:NSContentDictionaryBinding toObject:controller withKeyPath:@"validProfiles" options:nil];
    [controller awakeFromNib];
    ImagesToMovie *model = Model(paths);
    controller.imagesToMovie = model;
    controller.selectedSizePresetsTag = 0;
    model.imagePaths = [@[dpi] mutableCopy];
    WaitFor(^BOOL { return controller.readyToCreateMovie; });
    [controller updateModelWithNewSettings];
    Check(NSEqualSizes(model.frameSize, NSMakeSize(320, 180)), @"144-DPI PNG uses pixel dimensions");

    // Repeated first paths must not permit a stale middle load to win.
    model.imagePaths = [@[large] mutableCopy];
    Check(!controller.readyToCreateMovie, @"Readiness invalidated while loading");
    model.imagePaths = [@[dpi] mutableCopy];
    model.imagePaths = [@[large] mutableCopy];
    WaitFor(^BOOL { return controller.readyToCreateMovie; });
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    Check(NSEqualSizes(controller.firstFrameSize, NSMakeSize(3840, 2160)), @"Latest first image wins");
    Check([controller.profile isEqualToString:AVVideoProfileLevelH264MainAutoLevel], @"4K selects AutoLevel");
    Check(controller.bitRate == 36, @"4K default bitrate");
    controller.selectedSizePresetsTag = 480;
    Check([controller.profile isEqualToString:AVVideoProfileLevelH264Main30], @"Downsize restores legacy profile");
    controller.selectedSizePresetsTag = 2160;
    Check(controller.width.integerValue == 3840 && controller.height.integerValue == 2160 && controller.readyToCreateMovie, @"4K preset");
    controller.selectedSizePresetsTag = 1;
    controller.width = @0;
    Check(!controller.readyToCreateMovie, @"Zero width disables Save");
    controller.width = @3840;
    controller.height = @2160;
    controller.frameRate = 31;
    Check(!controller.readyToCreateMovie, @"Unsupported rate disables Save");
    controller.frameRate = 30;
    controller.bitRate = NAN;
    Check(!controller.readyToCreateMovie, @"Invalid bitrate disables Save");

    controller.selectedSizePresetsTag = 0;
    model.imagePaths = [@[pdf] mutableCopy];
    WaitFor(^BOOL { return controller.readyToCreateMovie; });
    Check(NSEqualSizes(controller.firstFrameSize, NSMakeSize(320, 180)), @"Vector dimensions preserved");
    model.imagePaths = [@[bad] mutableCopy];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    Check(!controller.readyToCreateMovie, @"Unreadable first image disables Save");
    PrimaryWindowController *window = [[PrimaryWindowController alloc] initWithWindow:nil];
    window.imagesToMovieController = controller;
    Check(!window.saveOrCancelEnabled, @"Invalid settings disable Save/Cancel binding");
    window.imagesToMovie.movieCreationInProgress = YES;
    Check(window.saveOrCancelEnabled, @"Cancel remains enabled during export");
    window.imagesToMovie.movieCreationInProgress = NO;
    [controller.profileDictionaryController unbind:NSContentDictionaryBinding];
    NSLog(@"PASS: pixel sizing, vectors, stale loads, profiles, readiness, Cancel binding");
}

static void CancelDuringFinish(NSArray *paths, NSString *output)
{
    Method original = class_getInstanceMethod(AVAssetWriter.class, @selector(finishWritingWithCompletionHandler:));
    Method replacement = class_getInstanceMethod(AVAssetWriter.class, @selector(regressionFinish:));
    method_exchangeImplementations(original, replacement);
    ImagesToMovie *model = Model(paths);
    NSData *oldMovie = [NSData dataWithContentsOfFile:output];
    __block NSUInteger completions = 0;
    finishHook = ^{ [model cancel]; };
    [model createMovieAtPath:output completionHandler:^(NSError *error) {
        Check(NSThread.isMainThread && error.code == NSUserCancelledError, @"Cancel during finalization");
        Check([[NSData dataWithContentsOfFile:output] isEqual:oldMovie], @"Finalization cancel preserves destination");
        completions++;
        [model createMovieAtPath:output completionHandler:^(NSError *retryError) {
            Check(NSThread.isMainThread && retryError == nil, @"Immediate retry after finalization cancel");
            completions++;
        }];
        delayedFinishCompletion();
        delayedFinishCompletion = nil;
    }];
    WaitFor(^BOOL { return completions >= 2; });
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    Check(completions == 2 && !model.movieCreationInProgress, @"Late finish callback cannot disturb retry");
    method_exchangeImplementations(original, replacement);
    ValidateMovie(output, NSMakeSize(320, 180), paths.count, YES);
    NSLog(@"PASS: cancellation during finalization, immediate retry and late callback");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        Check(argc == 2, @"Supply fixture directory");
        TableDragChecks();
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSUInteger i = 0; i < 12; i++)
            [paths addObject:MakeImage(directory, [NSString stringWithFormat:@"frame-%02lu.png", i], 320, 180, i, NO)];
        NSString *large = MakeImage(directory, @"4k.png", 3840, 2160, 0, NO);
        NSString *dpi = MakeImage(directory, @"144dpi.png", 320, 180, 0, YES);
        NSString *pdf = MakePDF(directory);
        NSString *bad = [directory stringByAppendingPathComponent:@"bad.png"];
        [@"not an image" writeToFile:bad atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *truncated = [directory stringByAppendingPathComponent:@"truncated.png"];
        NSData *png = [NSData dataWithContentsOfFile:paths[0]];
        [[png subdataWithRange:NSMakeRange(0, png.length * 4 / 5)] writeToFile:truncated atomically:YES];
        NSString *output = [directory stringByAppendingPathComponent:@"movie.mp4"];

        NSArray *invalidSettings = @[
            ^(ImagesToMovie *m) { m.profile = nil; },
            ^(ImagesToMovie *m) { m.profile = @"unknown"; },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(320, 0); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(NAN, 180); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(320.5, 180); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(5000, 16); m.profile = AVVideoProfileLevelH264MainAutoLevel; },
            ^(ImagesToMovie *m) { m.frameRate = 0; },
            ^(ImagesToMovie *m) { m.frameRate = 31; },
            ^(ImagesToMovie *m) { m.averageBitRate = 0; },
            ^(ImagesToMovie *m) { m.averageBitRate = 100000000; }
        ];
        for (void (^change)(ImagesToMovie *) in invalidSettings) {
            ImagesToMovie *model = Model(paths); change(model); PreservedFailure(model, output, NO);
        }
        PreservedFailure(Model(@[]), output, NO);
        PreservedFailure(Model(@[bad]), output, NO);
        PreservedFailure(Model(@[paths[0], bad]), output, NO);
        PreservedFailure(Model(@[truncated]), output, NO);
        PreservedFailure(Model(@[paths[0], truncated]), output, NO);
        PreservedFailure(Model(@[paths[0], [directory stringByAppendingPathComponent:@"missing.png"]]), output, NO);
        PreservedFailure(Model(paths), output, YES);
        Check(Export(Model(paths), [directory stringByAppendingPathComponent:@"absent/movie.mp4"], nil, nil) != nil, @"Missing output directory returns an error");
        NSString *unwritable = [directory stringByAppendingPathComponent:@"read-only"];
        [[NSFileManager defaultManager] createDirectoryAtPath:unwritable withIntermediateDirectories:NO attributes:nil error:NULL];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0500} ofItemAtPath:unwritable error:NULL];
        Check(Export(Model(paths), [unwritable stringByAppendingPathComponent:@"movie.mp4"], nil, nil) != nil, @"Unwritable output directory returns an error");
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:unwritable error:NULL];
        // An occupied directory cannot be replaced by the completed MP4.
        NSString *marker = [unwritable stringByAppendingPathComponent:@"keep.txt"];
        [@"keep" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        Check(Export(Model(paths), unwritable, nil, nil) != nil && [[NSFileManager defaultManager] fileExistsAtPath:marker], @"Promotion failure preserves destination");
        NSLog(@"PASS: invalid settings, unreadable frames, cancellation and destination preservation");

        ImagesToMovie *model = Model(paths);
        NSError *snapshotError = Export(model, output, ^{ model.imagePaths = [@[bad] mutableCopy]; model.frameRate = 0; }, nil);
        Check(snapshotError == nil, [NSString stringWithFormat:@"Export uses frozen settings and paths: %@", snapshotError]);
        ValidateMovie(output, NSMakeSize(320, 180), paths.count, YES);
        model.imagePaths = [paths mutableCopy]; model.frameRate = 30;
        Check(Export(model, output, nil, nil) == nil, @"Retry and replace existing destination");
        ValidateMovie(output, NSMakeSize(320, 180), paths.count, YES);

        ImagesToMovie *cancelModel = Model(paths);
        for (NSUInteger i = 0; i < 100; i++) [cancelModel.imagePaths addObjectsFromArray:paths];
        NSData *beforeCancel = [NSData dataWithContentsOfFile:output];
        __block BOOL requested = NO;
        NSError *cancelError = Export(cancelModel, output, nil, ^(ImagesToMovie *m) {
            if (m.value >= 2 && !requested) { requested = YES; [m cancel]; }
        });
        Check(requested && cancelError.code == NSUserCancelledError, @"Cancel during encoding");
        Check([[NSData dataWithContentsOfFile:output] isEqual:beforeCancel], @"Mid-export cancel preserves destination");
        cancelModel.imagePaths = [paths mutableCopy];
        Check(Export(cancelModel, output, nil, nil) == nil, @"Retry after cancellation");
        CancelDuringFinish(paths, output);

        NSMutableArray *uhdPaths = [NSMutableArray arrayWithObject:large];
        for (NSUInteger i = 1; i < 3; i++) [uhdPaths addObject:MakeImage(directory, [NSString stringWithFormat:@"4k-%lu.png", i], 3840, 2160, i, NO)];
        ImagesToMovie *uhd = Model(uhdPaths);
        uhd.frameSize = NSMakeSize(3840, 2160); uhd.profile = AVVideoProfileLevelH264MainAutoLevel; uhd.averageBitRate = 36000000;
        NSString *uhdOutput = [directory stringByAppendingPathComponent:@"4k.mp4"];
        NSError *uhdError = Export(uhd, uhdOutput, nil, nil);
        Check(uhdError == nil, [NSString stringWithFormat:@"4K export: %@", uhdError]);
        ValidateMovie(uhdOutput, uhd.frameSize, 3, YES);
        NSString *vectorOutput = [directory stringByAppendingPathComponent:@"vector.mp4"];
        Check(Export(Model(@[pdf]), vectorOutput, nil, nil) == nil, @"Vector export");
        ValidateMovie(vectorOutput, NSMakeSize(320, 180), 1, NO);
        NSLog(@"PASS: decoded ordinary, UHD and vector movies; replacement, retry and main-thread notifications");
        ControllerChecks(paths, large, dpi, pdf, truncated);
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL])
            Check(![name hasPrefix:@"."], [NSString stringWithFormat:@"Temporary output leaked: %@", name]);
        NSLog(@"PASS: all regressions (%@)", directory);
    }
    return 0;
}
