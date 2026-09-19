#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ImagesToMovie.h"
#import "MovieFrameRenderer.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import "ImagesToMovieController.h"
#import "PrimaryWindowController.h"

// Keep preference tests, including a fresh process, away from the user's defaults.
static NSUserDefaults *testDefaults;
@interface NSUserDefaults (RegressionDefaults)
+ (NSUserDefaults *)regressionDefaults;
@end
@implementation NSUserDefaults (RegressionDefaults)
+ (NSUserDefaults *)regressionDefaults { return testDefaults; }
@end

static void UseTestDefaults(NSString *suite)
{
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
        class_getClassMethod(NSUserDefaults.class, @selector(regressionDefaults)));
}

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

static void TableDragChecks(NSString *imagePath)
{
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    ImagesToMovie *model = [[ImagesToMovie alloc] init];
    model.imagePaths = [@[@"a", @"b", @"c", @"d", @"e"] mutableCopy];
    NSArrayController *array = [[NSArrayController alloc] init];
    [array bind:NSContentArrayBinding toObject:model withKeyPath:@"imagePaths" options:nil];
    ImageTableController *controller = [[ImageTableController alloc] init];
    controller.imagesToMovie = model;
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
    [pasteboard writeObjects:@[[NSURL fileURLWithPath:imagePath]]];
    Check([controller tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"Existing external file drop still works");
    Check([[array.arrangedObjects lastObject] isEqual:imagePath], @"External file appended");
    model.movieCreationInProgress = YES;
    Check([controller tableView:table validateDrop:(id)drag proposedRow:0 proposedDropOperation:NSTableViewDropAbove] == NSDragOperationNone &&
        ![controller tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"External drops rejected during export");
    [pasteboard releaseGlobally];
    [array unbind:NSContentArrayBinding];
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
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 40, 22.5));
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 157.5, 40, 22.5));
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
    model.codec = AVVideoCodecTypeH264;
    model.qualityMode = MovieQualityHigh;
    return model;
}

static void PreferenceChecks(NSString *suite)
{
    ImagesToMovieController *settings = [[ImagesToMovieController alloc] init];
    Check(settings.frameRate == 30 && settings.selectedCodecTag == 1 && settings.selectedQualityTag == MovieQualityHigh, @"Fresh preferences use HEVC, High and 30 fps");
    settings.selectedCodecTag = 2;
    settings.selectedQualityTag = MovieQualityStandard;
    settings.frameRate = 24;
    settings.selectedCodecTag = -1;
    settings.frameRate = 0;
    ImagesToMovieController *restored = [[ImagesToMovieController alloc] init];
    Check(restored.frameRate == 24 && restored.selectedCodecTag == 2 && restored.selectedQualityTag == MovieQualityStandard, @"Only valid settings persist across instances");
    [testDefaults synchronize];
    NSTask *child = [[NSTask alloc] init];
    child.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    child.arguments = @[@"--preferences-child", suite];
    NSError *error;
    Check([child launchAndReturnError:&error], [NSString stringWithFormat:@"Launch preference reader: %@", error]);
    [child waitUntilExit];
    Check(child.terminationStatus == 0, @"Preferences survive a fresh process");
    for (id invalid in @[@(-1), @31, @1.5, @"30", @[], @{}]) {
        [testDefaults setObject:invalid forKey:@"defaultFrameRate"];
        [testDefaults setObject:invalid forKey:@"defaultCodecTag"];
        [testDefaults setObject:invalid forKey:@"defaultQualityTag"];
        restored = [[ImagesToMovieController alloc] init];
        Check(restored.frameRate == 30 && restored.selectedCodecTag == 1 && restored.selectedQualityTag == MovieQualityHigh, @"Invalid stored values fall back safely");
    }
    [testDefaults setObject:@0 forKey:@"defaultCodecTag"];
    settings = [[ImagesToMovieController alloc] init];
    Check(settings.selectedCodecTag == 0, @"Remembered H.264 choice survives migration");
    settings.selectedQualityTag = MovieQualityStandard;
    settings.selectedQualityTag = MovieQualityCustomBitrate;
    settings.bitRate = 12;
    restored = [[ImagesToMovieController alloc] init];
    Check(restored.selectedQualityTag == MovieQualityStandard && restored.bitRate == 20,
        @"Custom mode and rate are session-only");
    [testDefaults removePersistentDomainForName:suite];
    NSLog(@"PASS: isolated preferences, invalid values and fresh-process restoration");
}

// Intercept modal presentation in the harness; the production methods still
// construct the real panels and alerts, which are checked before callbacks run.
static NSUInteger importAlerts;
static NSString *importSummary;
@interface NSAlert (RegressionAlert)
- (void)regressionSheet:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler;
@end
@implementation NSAlert (RegressionAlert)
- (void)regressionSheet:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler
{
    importAlerts++;
    importSummary = self.informativeText;
    if (handler) handler(NSAlertFirstButtonReturn);
}
@end

static NSView *ViewBoundTo(NSView *view, NSString *binding, NSString *keyPath)
{
    if ([[view infoForBinding:binding][NSObservedKeyPathKey] isEqual:keyPath]) return view;
    for (NSView *child in view.subviews) {
        NSView *result = ViewBoundTo(child, binding, keyPath);
        if (result) return result;
    }
    return nil;
}

static NSTextField *LabelWithText(NSView *view, NSString *text)
{
    if ([view isKindOfClass:NSTextField.class] && [[(NSTextField *)view stringValue] isEqual:text]) return (id)view;
    for (NSView *child in view.subviews) {
        NSTextField *result = LabelWithText(child, text);
        if (result) return result;
    }
    return nil;
}

static NSMenuItem *MenuItemWithAction(NSMenu *menu, SEL action)
{
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return item;
        NSMenuItem *result = MenuItemWithAction(item.submenu, action);
        if (result) return result;
    }
    return nil;
}

static NSArray<NSURL *> *panelURLs;
static NSString *expectedExtension;
static NSUInteger openPanels, savePanels;
static void (^heldOpenCompletion)(NSModalResponse);
static void (^heldSaveCompletion)(NSModalResponse);
static BOOL holdOpenPanel, holdSavePanel;
@interface NSSavePanel (RegressionPanel)
- (void)regressionSheet:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler;
@end
@implementation NSSavePanel (RegressionPanel)
- (void)regressionSheet:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler
{
    Check([self.directoryURL.path isEqual:NSHomeDirectory()], @"Invalid or absent saved directory falls back to home");
    if ([self isKindOfClass:NSOpenPanel.class]) {
        openPanels++;
        Check(self.allowedContentTypes.count > 0 && [(NSOpenPanel *)self allowsMultipleSelection] &&
            ![(NSOpenPanel *)self canChooseDirectories], @"Open panel accepts supported image files");
        if (holdOpenPanel) heldOpenCompletion = [handler copy];
        else handler(NSModalResponseOK);
    } else {
        savePanels++;
        Check([self.allowedContentTypes.firstObject.preferredFilenameExtension isEqual:expectedExtension],
            @"Save panel has correct MP4/MOV content type");
        if (holdSavePanel) heldSaveCompletion = [handler copy];
        else handler(NSModalResponseCancel);
    }
}
@end
@interface NSOpenPanel (RegressionURLs)
- (NSArray<NSURL *> *)regressionURLs;
- (NSURL *)regressionURL;
@end
@implementation NSOpenPanel (RegressionURLs)
- (NSArray<NSURL *> *)regressionURLs { return panelURLs; }
- (NSURL *)regressionURL { return panelURLs.firstObject; }
@end

static void Exchange(Class cls, SEL first, SEL second)
{
    method_exchangeImplementations(class_getInstanceMethod(cls, first), class_getInstanceMethod(cls, second));
}

static void AppKitChecks(NSString *bundlePath, NSString *directory, NSArray *paths, NSString *pdf, NSString *large)
{
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSArray *menuObjects;
    Check([[[NSNib alloc] initWithNibNamed:@"MainMenu" bundle:bundle] instantiateWithOwner:NSApp topLevelObjects:&menuObjects], @"Load built main menu");
    Check([NSStringFromClass([(id)NSApp.delegate class]) isEqual:@"AppController"], @"Main menu wires the app delegate");
    NSMenuItem *add = MenuItemWithAction(NSApp.mainMenu, @selector(openImageFilesAction:));
    NSMenuItem *export = MenuItemWithAction(NSApp.mainMenu, @selector(exportMovie:));
    Check([add.keyEquivalent isEqual:@"o"] && [export.keyEquivalent isEqual:@"s"] && !add.target && !export.target,
        @"Add and export shortcuts use the responder chain");
    Check(MenuItemWithAction(NSApp.mainMenu, @selector(undo:)) && MenuItemWithAction(NSApp.mainMenu, @selector(redo:)) &&
        !MenuItemWithAction(NSApp.mainMenu, @selector(printDocument:)), @"Useful Edit menu without document template commands");
    Check(![NSFileManager.defaultManager fileExistsAtPath:[bundle.resourcePath stringByAppendingPathComponent:@"Implementation Notes"]],
        @"Historical notes are not app resources");

    PrimaryWindowController *window = [[PrimaryWindowController alloc] initWithWindow:nil];
    NSArray *objects;
    Check([[[NSNib alloc] initWithNibNamed:@"PrimaryWindow" bundle:bundle] instantiateWithOwner:window topLevelObjects:&objects], @"Load built primary window");
    [window windowDidLoad];
    [window.window makeKeyAndOrderFront:nil];
    ImageTableController *list = window.imageTableController;
    NSTableView *table = list.imageTable;
    NSArrayController *array = list.imagePathArrayController;
    ImagesToMovieController *settings = window.imagesToMovieController;
    settings.selectedSizePresetsTag = 0;
    settings.selectedCodecTag = 0;
    settings.frameRate = 30;
    NSPopUpButton *qualityPopup = (id)ViewBoundTo(window.window.contentView, NSSelectedTagBinding, @"selectedQualityTag");
    NSTextField *bitrateField = (id)ViewBoundTo(window.window.contentView, NSValueBinding, @"bitRate");
    NSTextField *automatic = LabelWithText(window.window.contentView, @"Automatic");
    NSTextField *widthField = (id)ViewBoundTo(window.window.contentView, NSValueBinding, @"width");
    Check(qualityPopup && bitrateField && automatic && widthField, @"Built window contains quality, rate and size controls");
    settings.selectedQualityTag = MovieQualityHigh;
    Check(qualityPopup.selectedTag == MovieQualityHigh && bitrateField.hidden && !automatic.hidden,
        @"High displays Automatic instead of a nominal bitrate");
    settings.selectedQualityTag = MovieQualityCustomBitrate;
    Check(!bitrateField.hidden && automatic.hidden && !widthField.enabled, @"Custom rate is independent of size editability");
    settings.selectedSizePresetsTag = 1;
    Check(widthField.enabled && bitrateField.enabled, @"Custom size and Custom rate can be edited together");
    window.imagesToMovie.movieCreationInProgress = YES;
    Check(!qualityPopup.enabled && !bitrateField.enabled && !widthField.enabled && window.saveOrCancelEnabled,
        @"Export disables new controls and dimensions while keeping Cancel available");
    window.imagesToMovie.movieCreationInProgress = NO;
    settings.selectedCodecTag = 2;
    Check(qualityPopup.hidden && bitrateField.hidden && automatic.hidden, @"ProRes hides quality and rate controls");
    settings.selectedCodecTag = 0;
    settings.selectedQualityTag = MovieQualityHigh;
    settings.selectedSizePresetsTag = 0;
    NSUndoManager *undo = window.window.undoManager;
    Check(undo && undo == list.undoManager && undo.levelsOfUndo == 20, @"One bounded window undo manager");
    Check(!window.saveOrCancelEnabled && ![window validateUserInterfaceItem:export], @"Empty list disables export");

    Exchange(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(regressionSheet:completionHandler:));
    NSString *unsupported = [directory stringByAppendingPathComponent:@"notes.txt"];
    [@"text" writeToFile:unsupported atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *unreadable = [directory stringByAppendingPathComponent:@"unreadable.png"];
    [NSFileManager.defaultManager copyItemAtPath:paths[0] toPath:unreadable error:NULL];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0} ofItemAtPath:unreadable error:NULL];
    NSArray *mixedPaths = @[paths[0], directory, unsupported, [directory stringByAppendingPathComponent:@"missing.png"], unreadable, paths[0], pdf];
    NSMutableArray *URLs = [NSMutableArray array];
    for (NSString *path in mixedPaths) [URLs addObject:[NSURL fileURLWithPath:path]];
    Check([list importImageURLs:URLs], @"Mixed import adds accepted subset");
    Check([window.imagesToMovie.imagePaths isEqual:@[paths[0], paths[0], pdf]] && importAlerts == 1 &&
        [importSummary containsString:@"notes.txt"] && [importSummary containsString:@"missing.png"] && [importSummary containsString:@"unreadable.png"],
        @"Mixed import preserves order/duplicates and reports skipped files once");
    WaitFor(^BOOL { return settings.readyToCreateMovie; });
    [undo undo];
    Check(window.imagesToMovie.imagePaths.count == 0 && !settings.readyToCreateMovie && undo.canRedo, @"Undo import restores empty readiness");
    [undo redo];
    WaitFor(^BOOL { return settings.readyToCreateMovie; });
    Check([window.imagesToMovie.imagePaths isEqual:@[paths[0], paths[0], pdf]], @"Redo restores duplicate input paths");

    [undo removeAllActions];
    Check(![list importImageURLs:@[[NSURL fileURLWithPath:unsupported]]] && !undo.canUndo && importAlerts == 2,
        @"Rejected batch leaves list and undo history unchanged");
    [table deselectAll:nil];
    [list removeSelectedImages:nil];
    Check(!undo.canUndo, @"No-selection deletion has no undo entry");
    [array setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO]]];
    [array rearrangeObjects];
    NSArray *orderedBefore = [window.imagesToMovie.imagePaths copy];
    NSArray *displayedBefore = [array.arrangedObjects copy];
    NSArray *sortBefore = [array.sortDescriptors copy];
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSetWithIndex:0];
    [selection addIndex:2];
    [table selectRowIndexes:selection byExtendingSelection:NO];
    [list removeSelectedImages:nil];
    Check(window.imagesToMovie.imagePaths.count == 1, @"Sorted nonadjacent removal");
    [undo undo];
    Check([window.imagesToMovie.imagePaths isEqual:orderedBefore] && [array.sortDescriptors isEqual:sortBefore] &&
        [table.selectedRowIndexes isEqual:selection], @"Undo restores underlying order, sorting and selected occurrences");
    [undo redo];
    Check(window.imagesToMovie.imagePaths.count == 1, @"Redo sorted removal");
    [undo undo];

    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    DragFixture *drag = [[DragFixture alloc] init]; drag.draggingSource = table; drag.draggingPasteboard = pasteboard;
    [pasteboard writeObjects:@[[list tableView:table pasteboardWriterForRow:0]]];
    Check([list tableView:table acceptDrop:(id)drag row:3 dropOperation:NSTableViewDropAbove], @"Reorder sorted display");
    Check([window.imagesToMovie.imagePaths isEqual:@[displayedBefore[1], displayedBefore[2], displayedBefore[0]]] &&
        array.sortDescriptors.count == 0, @"Reorder interprets indexes before clearing sorting");
    [undo undo];
    Check([window.imagesToMovie.imagePaths isEqual:orderedBefore] && [array.sortDescriptors isEqual:sortBefore], @"Undo sorted reorder");
    Check([list importImageURLs:@[[NSURL fileURLWithPath:paths[1]]]] && !undo.canRedo, @"New import invalidates Redo");
    WaitFor(^BOOL { return settings.readyToCreateMovie; });

    NSArray *beforeExport = [window.imagesToMovie.imagePaths copy];
    [window.window makeFirstResponder:table];
    window.imagesToMovie.movieCreationInProgress = YES;
    Check(!undo.canUndo && !undo.canRedo && window.saveOrCancelEnabled, @"Export suspends history while Cancel remains enabled");
    [undo undo]; [undo redo]; [list removeSelectedImages:nil];
    Check(![list importImageURLs:@[[NSURL fileURLWithPath:large]]] &&
        ![list tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove] &&
        [window.imagesToMovie.imagePaths isEqual:beforeExport], @"All list entry points are inert during export");
    Check(![window validateUserInterfaceItem:add] && ![window validateUserInterfaceItem:export], @"Menus disabled during export");
    window.imagesToMovie.movieCreationInProgress = NO;
    Check(undo.canUndo, @"Export preserves Undo history");
    [undo undo];
    Check([window.imagesToMovie.imagePaths isEqual:orderedBefore], @"Preserved history remains usable");
    [pasteboard releaseGlobally];

    [undo removeAllActions];
    [table selectAll:nil]; [list removeSelectedImages:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check([list importImageURLs:@[[NSURL fileURLWithPath:large]]], @"Import a different first image");
    [undo undo]; [undo undo];
    WaitFor(^BOOL { return settings.readyToCreateMovie; });
    Check(NSEqualSizes(settings.firstFrameSize, NSMakeSize(320, 180)), @"Undo rejects stale first-image loads");

    Exchange(NSSavePanel.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(regressionSheet:completionHandler:));
    Exchange(NSOpenPanel.class, @selector(URLs), @selector(regressionURLs));
    Exchange(NSOpenPanel.class, @selector(URL), @selector(regressionURL));
    [testDefaults setObject:unsupported forKey:@"defaultImagesPath"];
    [testDefaults removeObjectForKey:@"defaultMoviePath"];
    panelURLs = URLs;
    NSUInteger beforePanelCount = window.imagesToMovie.imagePaths.count;
    NSUInteger beforePanelAlerts = importAlerts;
    [window openImageFilesAction:nil];
    Check(openPanels == 1 && importAlerts == beforePanelAlerts + 1 &&
        [[window.imagesToMovie.imagePaths subarrayWithRange:NSMakeRange(beforePanelCount, 3)] isEqual:@[paths[0], paths[0], pdf]],
        @"Add Images uses the shared mixed-import validation and order");
    pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard writeObjects:URLs];
    drag.draggingSource = nil; drag.draggingPasteboard = pasteboard;
    Check([list tableView:table acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove] && importAlerts == beforePanelAlerts + 2 &&
        [[window.imagesToMovie.imagePaths subarrayWithRange:NSMakeRange(beforePanelCount + 3, 3)] isEqual:@[paths[0], paths[0], pdf]],
        @"Finder drops use the same mixed-import validation and order");
    [pasteboard releaseGlobally];
    [testDefaults removeObjectForKey:@"defaultImagesPath"];
    holdOpenPanel = YES;
    [window openImageFilesAction:nil];
    beforeExport = [window.imagesToMovie.imagePaths copy];
    window.imagesToMovie.movieCreationInProgress = YES;
    heldOpenCompletion(NSModalResponseOK); heldOpenCompletion = nil;
    [window exportMovie:nil];
    Check([window.imagesToMovie.imagePaths isEqual:beforeExport] && savePanels == 0 && window.imagesToMovie.movieCreationInProgress,
        @"Late panel import is ignored and Export command never cancels");
    window.imagesToMovie.movieCreationInProgress = NO;
    for (NSNumber *codec in @[@0, @1, @2]) {
        settings.selectedCodecTag = codec.integerValue;
        expectedExtension = codec.integerValue == 2 ? @"mov" : @"mp4";
        [window exportMovie:nil];
    }
    Check(savePanels == 3 && !window.imagesToMovie.movieCreationInProgress, @"All codec Save dialogs cancel without exporting");
    holdSavePanel = YES;
    [window exportMovie:nil];
    window.imagesToMovie.movieCreationInProgress = YES;
    heldSaveCompletion(NSModalResponseOK); heldSaveCompletion = nil;
    Check(window.imagesToMovie.movieCreationInProgress && savePanels == 4, @"Late Save completion cannot start a second export");
    window.imagesToMovie.movieCreationInProgress = NO;
    holdSavePanel = NO;

    settings.selectedSizePresetsTag = 1;
    settings.width = @320; settings.height = @180;
    NSTextField *width = (id)ViewBoundTo(window.window.contentView, NSValueBinding, @"width");
    [undo removeAllActions];
    NSArray *beforeEditing = [window.imagesToMovie.imagePaths copy];
    [list importImageURLs:@[[NSURL fileURLWithPath:paths[0]]]];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [width selectText:nil];
    NSTextView *editor = (id)window.window.firstResponder;
    Check([editor isKindOfClass:NSTextView.class] && editor.undoManager, @"Native field editor supports Undo");
    [editor insertText:@"400" replacementRange:NSMakeRange(0, editor.string.length)];
    // A command-line harness has no active key window; start at the actual
    // window's first responder, where AppKit sends the menu command in the app.
    Check([window.window.firstResponder tryToPerform:@selector(undo:) with:MenuItemWithAction(NSApp.mainMenu, @selector(undo:))] &&
        editor.string.integerValue == 320, @"Edit Undo retains native field editing behavior");
    [window.window makeFirstResponder:table];
    Check([table tryToPerform:@selector(undo:) with:MenuItemWithAction(NSApp.mainMenu, @selector(undo:))] &&
        [window.imagesToMovie.imagePaths isEqual:beforeEditing], @"Ending field editing preserves list Undo history");

    NSTextField *rate = (id)ViewBoundTo(window.window.contentView, NSValueBinding, @"frameRate");
    [rate selectText:nil];
    editor = (id)window.window.firstResponder;
    [editor insertText:@"99" replacementRange:NSMakeRange(0, editor.string.length)];
    [window exportMovie:nil];
    Check(savePanels == 4, @"Invalid active field prevents the Save dialog");
    [editor insertText:@"30" replacementRange:NSMakeRange(0, editor.string.length)];
    [window.window makeFirstResponder:table];
    Exchange(NSOpenPanel.class, @selector(URL), @selector(regressionURL));
    Exchange(NSOpenPanel.class, @selector(URLs), @selector(regressionURLs));
    Exchange(NSSavePanel.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(regressionSheet:completionHandler:));
    Exchange(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:), @selector(regressionSheet:completionHandler:));
    [undo removeAllActions];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    undo.groupsByEvent = NO;
    NSUInteger baseCount = window.imagesToMovie.imagePaths.count;
    for (NSUInteger i = 0; i < 21; i++) {
        [undo beginUndoGrouping];
        [list importImageURLs:@[[NSURL fileURLWithPath:paths[0]]]];
        [undo endUndoGrouping];
    }
    for (NSUInteger i = 0; i < 20; i++) [undo undo];
    Check(!undo.canUndo && window.imagesToMovie.imagePaths.count == baseCount + 1, @"Only the newest 20 list actions are retained");
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:unreadable error:NULL];
    NSView *content = window.window.contentView;
    NSBitmapImageRep *snapshot = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:snapshot];
    [[snapshot representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[directory stringByAppendingPathComponent:@"settings-window.png"] atomically:YES];
    [window.window orderOut:nil];
    NSApp.delegate = nil;
    NSLog(@"PASS: built menus/window, mixed imports, Undo/Redo, sorted duplicates, export guards and panel types");
}

static void TableRemovalChecks(NSArray *paths)
{
    [NSApplication sharedApplication];
    ImagesToMovie *model = Model(paths);
    NSArrayController *array = [[NSArrayController alloc] init];
    [array bind:NSContentArrayBinding toObject:model withKeyPath:@"imagePaths" options:nil];
    [array setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO]]];
    ImageTableController *controller = [[ImageTableController alloc] init];
    controller.imagesToMovie = model;
    ImageTableView *table = [[ImageTableView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
    table.allowsMultipleSelection = YES;
    controller.imageTable = table;
    controller.imagePathArrayController = array;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"image"];
    [table addTableColumn:column];
    [column bind:NSValueBinding toObject:array withKeyPath:@"arrangedObjects.lastPathComponent" options:nil];
    table.dataSource = controller;
    [table bind:NSEnabledBinding toObject:model withKeyPath:@"movieCreationInProgress"
        options:@{NSValueTransformerNameBindingOption:NSNegateBooleanTransformerName}];
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSetWithIndex:0];
    [selection addIndex:2];
    NSArray *removed = [array.arrangedObjects objectsAtIndexes:selection];
    [table selectRowIndexes:selection byExtendingSelection:NO];
    NSEvent *backspace = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:0 context:nil characters:@"\177" charactersIgnoringModifiers:@"\177" isARepeat:NO keyCode:51];
    [table keyDown:backspace];
    Check(model.imagePaths.count == paths.count - 2 && ![model.imagePaths containsObject:removed[0]] &&
        ![model.imagePaths containsObject:removed[1]], @"Backspace removes selected displayed rows, including sorted nonadjacent rows");
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    NSEvent *forwardDelete = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:0 context:nil characters:@"\uF728" charactersIgnoringModifiers:@"\uF728" isARepeat:NO keyCode:117];
    [table keyDown:forwardDelete];
    Check(model.imagePaths.count == paths.count - 3, @"Forward Delete removes a selected row");
    NSMenuItem *deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    [table deselectAll:nil];
    Check(![table validateUserInterfaceItem:deleteItem], @"Delete disabled without a selection");
    [table delete:deleteItem];
    Check(model.imagePaths.count == paths.count - 3, @"Empty-selection deletion is a no-op");
    [table selectAll:nil];
    model.movieCreationInProgress = YES;
    Check(![table validateUserInterfaceItem:deleteItem], @"Delete disabled during export");
    [table keyDown:backspace];
    [table delete:deleteItem];
    Check(model.imagePaths.count == paths.count - 3, @"Keyboard and menu cannot remove rows during export");
    model.movieCreationInProgress = NO;
    Check([table validateUserInterfaceItem:deleteItem], @"Delete enabled for selected rows");
    [table delete:deleteItem];
    Check(model.imagePaths.count == 0, @"Menu deletion removes all selected entries through the model binding");
    model.imagePaths = [@[paths[0], paths[0], paths[1]] mutableCopy];
    [array setSortDescriptors:@[]];
    [array rearrangeObjects];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [table delete:nil];
    Check([model.imagePaths isEqual:@[paths[0], paths[1]]], [NSString stringWithFormat:@"Deleting one duplicate keeps the other entry (remaining: %@)", model.imagePaths]);
    model.imagePaths = [@[paths[0], paths[1], paths[0]] mutableCopy];
    [array rearrangeObjects];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [table delete:nil];
    Check([model.imagePaths isEqual:@[paths[0], paths[1]]], @"Deleting the last nonadjacent duplicate preserves the first occurrence's position");
    model.imagePaths = [@[paths[0], paths[1], paths[0]] mutableCopy];
    [array setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES]]];
    [array rearrangeObjects];
    NSUInteger lastDuplicate = [array.arrangedObjects indexOfObject:paths[0]
        inRange:NSMakeRange([array.arrangedObjects indexOfObject:paths[0]] + 1, 1)];
    Check(lastDuplicate != NSNotFound, @"Sorted fixture has two adjacent duplicate occurrences");
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:lastDuplicate] byExtendingSelection:NO];
    [table delete:nil];
    Check([model.imagePaths isEqual:@[paths[0], paths[1]]], @"Deleting the second sorted duplicate preserves underlying occurrence order");
    for (NSString *path in paths) Check([[NSFileManager defaultManager] fileExistsAtPath:path], @"Removing table entries preserves source files");
    [table unbind:NSEnabledBinding];
    [column unbind:NSValueBinding];
    [array unbind:NSContentArrayBinding];
    NSLog(@"PASS: keyboard/menu image removal, sorting, multiple selection, duplicates and export guard");
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
    if (!cancel && [[model.imagePaths.lastObject lastPathComponent] isEqual:@"truncated.png"])
        Check([error.localizedDescription containsString:@"truncated.png"], @"Corrupt-frame errors identify the file");
    if (cancel) Check([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError, @"Cancellation result");
    Check([[NSData dataWithContentsOfFile:path] isEqual:original], @"Failure must preserve destination bytes");
}

static void ControllerChecks(NSArray *paths, NSString *large, NSString *dpi, NSString *pdf, NSString *bad)
{
    ImagesToMovieController *controller = [[ImagesToMovieController alloc] init];
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
    Check(controller.bitRate == 20, @"Custom rate starts at 20 Mb/s regardless of size");
    controller.selectedQualityTag = MovieQualityCustomBitrate;
    controller.bitRate = 18;
    controller.selectedSizePresetsTag = 480;
    controller.frameRate = 24;
    Check(controller.bitRate == 18, @"Size and frame-rate changes preserve Custom rate");
    controller.frameRate = 30;
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

    controller.selectedQualityTag = MovieQualityStandard;
    controller.selectedQualityTag = MovieQualityCustomBitrate;
    controller.selectedCodecTag = 0;
    controller.selectedCodecTag = 1;
    Check(controller.readyToCreateMovie && controller.selectedQualityTag == MovieQualityStandard,
        @"Codec change exits Custom to remembered quality");
    controller.selectedQualityTag = MovieQualityCustomBitrate;
    controller.bitRate = 18;
    [controller updateModelWithNewSettings];
    Check([model.codec isEqualToString:AVVideoCodecTypeHEVC] && model.averageBitRate == 18000000 &&
        model.qualityMode == MovieQualityCustomBitrate, @"Custom settings reach exporter");
    for (NSNumber *rate in @[@0, @0.09, @51, @(NAN)]) {
        controller.bitRate = rate.doubleValue;
        Check(!controller.readyToCreateMovie, @"Invalid Custom rate disables Save");
    }
    for (NSNumber *rate in @[@0.1, @50]) {
        controller.bitRate = rate.doubleValue;
        Check(controller.readyToCreateMovie, @"Custom endpoints accepted");
    }
    controller.selectedCodecTag = 2;
    controller.bitRate = NAN;
    Check(controller.readyToCreateMovie, @"ProRes ignores unused Custom rate");
    controller.frameRate = 31;
    Check(!controller.readyToCreateMovie, @"ProRes retains frame rate limit");
    controller.frameRate = 30;
    controller.selectedCodecTag = -1;
    Check(!controller.readyToCreateMovie, @"Unknown codec disables Save");
    controller.selectedCodecTag = 0;
    Check(controller.readyToCreateMovie, @"Automatic H.264 ignores unused Custom rate");

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
    NSLog(@"PASS: pixel sizing, vectors, stale loads, quality transitions, readiness, Cancel binding");
}

static void CancelDuringFinish(NSArray *paths, NSString *output, AVVideoCodecType codec)
{
    Method original = class_getInstanceMethod(AVAssetWriter.class, @selector(finishWritingWithCompletionHandler:));
    Method replacement = class_getInstanceMethod(AVAssetWriter.class, @selector(regressionFinish:));
    method_exchangeImplementations(original, replacement);
    ImagesToMovie *model = Model(paths);
    model.codec = codec;
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

#include "PrecisionChecks.inc"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--preferences-child") == 0) {
            UseTestDefaults([NSString stringWithUTF8String:argv[2]]);
            ImagesToMovieController *settings = [[ImagesToMovieController alloc] init];
            Check(settings.frameRate == 24 && settings.selectedCodecTag == 2 && settings.selectedQualityTag == MovieQualityStandard, @"Fresh process restores codec, quality and frame rate");
            return 0;
        }
        Check(argc == 3, @"Supply fixture directory and built app bundle");
        NSString *suite = [@"org.Image2Movie.Regression." stringByAppendingString:NSUUID.UUID.UUIDString];
        UseTestDefaults(suite);
        PreferenceChecks(suite);
        [NSApplication sharedApplication];
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSUInteger i = 0; i < 12; i++)
            [paths addObject:MakeImage(directory, [NSString stringWithFormat:@"frame-%02lu.png", i], 320, 180, i, NO)];
        TableDragChecks(paths[0]);
        TableRemovalChecks(paths);
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
            ^(ImagesToMovie *m) { m.codec = nil; },
            ^(ImagesToMovie *m) { m.codec = @"unknown"; },
            ^(ImagesToMovie *m) { m.codec = AVVideoCodecTypeHEVC; m.qualityMode = MovieQualityCustomBitrate; m.qualityMode = MovieQualityCustomBitrate; m.averageBitRate = 0; },
            ^(ImagesToMovie *m) { m.codec = AVVideoCodecTypeHEVC; m.qualityMode = MovieQualityCustomBitrate; m.averageBitRate = 50000001; },
            ^(ImagesToMovie *m) { m.qualityMode = -1; },
            ^(ImagesToMovie *m) { m.qualityMode = 3; },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(320, 0); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(NAN, 180); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(320.5, 180); },
            ^(ImagesToMovie *m) { m.frameSize = NSMakeSize(5000, 16); },
            ^(ImagesToMovie *m) { m.frameRate = 0; },
            ^(ImagesToMovie *m) { m.frameRate = 31; },
            ^(ImagesToMovie *m) { m.qualityMode = MovieQualityCustomBitrate; m.averageBitRate = 0; },
            ^(ImagesToMovie *m) { m.qualityMode = MovieQualityCustomBitrate; m.averageBitRate = 100000000; }
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
        CancelDuringFinish(paths, output, AVVideoCodecTypeH264);

        NSMutableArray *uhdPaths = [NSMutableArray arrayWithObject:large];
        for (NSUInteger i = 1; i < 3; i++) [uhdPaths addObject:MakeImage(directory, [NSString stringWithFormat:@"4k-%lu.png", i], 3840, 2160, i, NO)];
        ImagesToMovie *uhd = Model(uhdPaths);
        uhd.frameSize = NSMakeSize(3840, 2160); uhd.averageBitRate = 36000000;
        NSString *uhdOutput = [directory stringByAppendingPathComponent:@"4k.mp4"];
        NSError *uhdError = Export(uhd, uhdOutput, nil, nil);
        Check(uhdError == nil, [NSString stringWithFormat:@"4K export: %@", uhdError]);
        ValidateMovie(uhdOutput, uhd.frameSize, 3, YES);

        for (AVVideoCodecType codec in @[AVVideoCodecTypeHEVC, AVVideoCodecTypeAppleProRes422]) {
            BOOL proRes = [codec isEqualToString:AVVideoCodecTypeAppleProRes422];
            NSString *codecOutput = [directory stringByAppendingPathComponent:proRes ? @"prores.mov" : @"hevc.mp4"];
            ImagesToMovie *movie = Model(paths);
            movie.codec = codec;
            if (proRes) movie.averageBitRate = 0;
            PreservedFailure(movie, codecOutput, YES);
            movie.frameRate = 0;
            PreservedFailure(movie, codecOutput, NO);
            movie.frameRate = 30;
            Check(Export(movie, [directory stringByAppendingPathComponent:@"absent/movie.mp4"], nil, nil) != nil,
                @"Every codec reports output creation failure");
            movie.imagePaths = [@[paths[0], truncated] mutableCopy];
            PreservedFailure(movie, codecOutput, NO);
            movie.imagePaths = [paths mutableCopy];
            NSError *error = Export(movie, codecOutput, ^{ movie.codec = @"unknown"; }, nil);
            Check(error == nil, [NSString stringWithFormat:@"%@ export with frozen codec: %@", codec, error]);
            ValidateMovie(codecOutput, movie.frameSize, paths.count, YES);
            AVAssetTrack *track = [[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:codecOutput] options:nil]
                tracksWithMediaType:AVMediaTypeVideo].firstObject;
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
            Check(format && CMFormatDescriptionGetMediaSubType(format) == (proRes ? kCMVideoCodecType_AppleProRes422 : kCMVideoCodecType_HEVC),
                @"Movie contains the requested codec");
            NSData *bytes = [NSData dataWithContentsOfFile:codecOutput];
            Check(bytes.length >= 12 && memcmp((const char *)bytes.bytes + 4, "ftyp", 4) == 0 &&
                memcmp((const char *)bytes.bytes + 8, proRes ? "qt  " : "mp42", 4) == 0, @"Correct MOV/MP4 container");
            CancelDuringFinish(paths, codecOutput, codec);
            movie.codec = codec;
            movie.imagePaths = [uhdPaths mutableCopy];
            movie.frameSize = uhd.frameSize;
            if (!proRes) movie.averageBitRate = 36000000;
            error = Export(movie, codecOutput, nil, nil);
            Check(error == nil, [NSString stringWithFormat:@"%@ UHD export: %@", codec, error]);
            ValidateMovie(codecOutput, movie.frameSize, uhdPaths.count, YES);
            NSLog(@"PASS: %@ ordinary/UHD decoding, container, snapshot, cancellation, corrupt frame and retry", codec);
        }
        NSString *vectorOutput = [directory stringByAppendingPathComponent:@"vector.mp4"];
        Check(Export(Model(@[pdf]), vectorOutput, nil, nil) == nil, @"Vector export");
        ValidateMovie(vectorOutput, NSMakeSize(320, 180), 1, YES);
        NSLog(@"PASS: decoded ordinary, UHD and vector movies; replacement, retry and main-thread notifications");
        PrecisionChecks(directory);
        ColorSourceChecks(directory, paths[0]);
        QualityComparisons(directory);
        ControllerChecks(paths, large, dpi, pdf, truncated);
        AppKitChecks([NSString stringWithUTF8String:argv[2]], directory, paths, pdf, large);
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL])
            Check(![name hasPrefix:@"."], [NSString stringWithFormat:@"Temporary output leaked: %@", name]);
        NSLog(@"PASS: all regressions (%@)", directory);
        [testDefaults removePersistentDomainForName:suite];
    }
    return 0;
}
