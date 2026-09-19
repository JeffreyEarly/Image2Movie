//
//  PrimaryWindowController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "PrimaryWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MovieUndoManager : NSUndoManager
@property(weak) ImagesToMovie *imagesToMovie;
@end

@implementation MovieUndoManager

- (BOOL)canUndo
{
    return !self.imagesToMovie.movieCreationInProgress && super.canUndo;
}

- (BOOL)canRedo
{
    return !self.imagesToMovie.movieCreationInProgress && super.canRedo;
}

- (void)undo
{
    if (!self.imagesToMovie.movieCreationInProgress) [super undo];
}

- (void)redo
{
    if (!self.imagesToMovie.movieCreationInProgress) [super redo];
}

@end

static NSURL *PanelDirectoryURL(NSString *defaultsKey)
{
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    BOOL isDirectory = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (path.length == 0 || ![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory ||
        ![fileManager isReadableFileAtPath:path] || ![fileManager isExecutableFileAtPath:path]) {
        path = NSHomeDirectory();
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@interface PrimaryWindowController ()
@property(strong) MovieUndoManager *movieUndoManager;
@end

@implementation PrimaryWindowController
@synthesize imagesToMovieController;
@synthesize imageTableController;

- (id)initWithWindow:(NSWindow *)window
{
    self = [super initWithWindow:window];
    if (self) {
		self.buttonTitle = @"Save Movie";
        self.imagesToMovie = [[ImagesToMovie alloc] init];
		[self.imagesToMovie addObserver: self forKeyPath: @"movieCreationInProgress" options: 0 context:NULL];
    }
    
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];

    self.window.delegate = self;
    self.movieUndoManager = [[MovieUndoManager alloc] init];
    self.movieUndoManager.levelsOfUndo = 20;
    self.movieUndoManager.imagesToMovie = self.imagesToMovie;
    self.imagesToMovieController.imagesToMovie = self.imagesToMovie;
    self.imageTableController.imagesToMovie = self.imagesToMovie;
    self.imageTableController.undoManager = self.movieUndoManager;
}

- (void)dealloc
{
    [self.imagesToMovie removeObserver:self forKeyPath:@"movieCreationInProgress"];
}

/************************************************/
/*		Open Images								*/
/************************************************/

#pragma mark -
#pragma mark Open Images
#pragma mark

- (IBAction)openImageFilesAction:(id)sender
{
	if (self.imagesToMovie.movieCreationInProgress || self.window.attachedSheet) return;
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	openPanel.allowsMultipleSelection = YES;
	openPanel.canChooseFiles = YES;
	openPanel.canChooseDirectories = NO;
	openPanel.allowedContentTypes = [ImageTableController supportedImageContentTypes];
	openPanel.directoryURL = PanelDirectoryURL(@"defaultImagesPath");
	
	__weak typeof(self) weakSelf = self;
	[openPanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		PrimaryWindowController *strongSelf = weakSelf;
		if (strongSelf && result == NSModalResponseOK && openPanel.URLs.count && !strongSelf.imagesToMovie.movieCreationInProgress) {
			[[NSUserDefaults standardUserDefaults] setObject:[openPanel.URL.path stringByDeletingLastPathComponent] forKey:@"defaultImagesPath"];
			[strongSelf.imageTableController importImageURLs:openPanel.URLs];
		}
	}];
}

/************************************************/
/*		Controller								*/
/************************************************/

#pragma mark -
#pragma mark Controller
#pragma mark

@synthesize buttonTitle;

+ (NSSet *)keyPathsForValuesAffectingSaveOrCancelEnabled
{
    return [NSSet setWithObjects:@"imagesToMovie.movieCreationInProgress", @"imagesToMovieController.readyToCreateMovie", nil];
}

- (BOOL)saveOrCancelEnabled
{
    return self.imagesToMovie.movieCreationInProgress || self.imagesToMovieController.readyToCreateMovie;
}

- (IBAction)buttonClicked:(id)sender
{
	if (self.imagesToMovie.movieCreationInProgress) {
		[self.imagesToMovie cancel];
	} else {
        [self exportMovie:sender];
    }
}

- (IBAction)exportMovie:(id)sender
{
    if (self.imagesToMovie.movieCreationInProgress || self.window.attachedSheet) return;
    // Ending field editing asks formatters to validate and commit their current values.
    if (![self.window makeFirstResponder:nil] || !self.imagesToMovieController.readyToCreateMovie) return;

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.directoryURL = PanelDirectoryURL(@"defaultMoviePath");
    BOOL proRes = [self.imagesToMovieController.codec isEqualToString:AVVideoCodecTypeAppleProRes422];
    savePanel.allowedContentTypes = @[proRes ? UTTypeQuickTimeMovie : UTTypeMPEG4Movie];

    __weak typeof(self) weakSelf = self;
    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        PrimaryWindowController *strongSelf = weakSelf;
        if (result != NSModalResponseOK || !strongSelf || strongSelf.imagesToMovie.movieCreationInProgress ||
            !strongSelf.imagesToMovieController.readyToCreateMovie) return;
        [[NSUserDefaults standardUserDefaults] setObject:savePanel.URL.path.stringByDeletingLastPathComponent
                                                  forKey:@"defaultMoviePath"];
        [strongSelf.imagesToMovieController updateModelWithNewSettings];
        [strongSelf.imagesToMovie createMovieAtPath:savePanel.URL.path completionHandler:^(NSError *error) {
            if (error && !([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError)) {
                [strongSelf.window presentError:error];
            }
        }];
    }];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL action = item.action;
    if (action == @selector(openImageFilesAction:)) {
        return !self.imagesToMovie.movieCreationInProgress && self.window.attachedSheet == nil;
    }
    if (action == @selector(exportMovie:)) {
        return !self.imagesToMovie.movieCreationInProgress && self.imagesToMovieController.readyToCreateMovie &&
            self.window.attachedSheet == nil;
    }
    return YES;
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window
{
    return self.movieUndoManager;
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ( [keyPath isEqualToString: @"movieCreationInProgress"] )
	{
		if ( self.imagesToMovie.movieCreationInProgress ) {
			self.buttonTitle = @"Cancel";
		} else {
			self.buttonTitle = @"Save Movie";
		}
	}
}


/************************************************/
/*		Model									*/
/************************************************/

#pragma mark -
#pragma mark Model
#pragma mark


@synthesize imagesToMovie;

@end
