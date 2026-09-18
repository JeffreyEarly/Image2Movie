//
//  PrimaryWindowController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "PrimaryWindowController.h"

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

    self.imagesToMovieController.imagesToMovie = self.imagesToMovie;
}

/************************************************/
/*		Open Images								*/
/************************************************/

#pragma mark -
#pragma mark Open Images
#pragma mark

- (IBAction) openImageFilesAction: (id) sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	openPanel.allowsMultipleSelection = YES;
	openPanel.directoryURL = [NSURL fileURLWithPath: [[NSUserDefaults standardUserDefaults] objectForKey: @"defaultImagesPath"]];
	
	[openPanel beginSheetModalForWindow: self.window completionHandler: ^(NSInteger result) {
		if (result == NSFileHandlingPanelOKButton && openPanel.URLs.count) {
			[[NSUserDefaults standardUserDefaults] setObject:[openPanel.URL.path stringByDeletingLastPathComponent] forKey:@"defaultImagesPath"];
			[self.imagesToMovie.imagePaths addObjectsFromArray: [openPanel.URLs valueForKeyPath: @"path"]];
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

- (IBAction) buttonClicked: (id) sender
{
	if ( !self.imagesToMovie.movieCreationInProgress)
	{
		NSSavePanel *savePanel = [NSSavePanel savePanel];
		savePanel.directoryURL = [NSURL fileURLWithPath: [[NSUserDefaults standardUserDefaults] objectForKey: @"defaultMoviePath"] ?: NSHomeDirectory()];
		savePanel.allowedFileTypes = @[@"mp4"];
		
		[savePanel beginSheetModalForWindow: self.window completionHandler: ^(NSInteger result) {
			if (result == NSFileHandlingPanelOKButton) {
				[[NSUserDefaults standardUserDefaults] setObject:[savePanel.URL.path stringByDeletingLastPathComponent] forKey:@"defaultMoviePath"];
                [self.imagesToMovieController updateModelWithNewSettings];
				[self.imagesToMovie createMovieAtPath: savePanel.URL.path];
			}
		}];
	}
	else
	{
		[self.imagesToMovie cancel];
	}
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
