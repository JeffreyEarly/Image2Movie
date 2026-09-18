//
//  AppController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 4/27/10.
//  Copyright 2010 Early Innovations, LLC. All rights reserved.
//

#import "AppController.h"
#import "AddMovieFrameOperation.h"

@implementation AppController

@synthesize windowController;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	self.windowController = [[PrimaryWindowController alloc] initWithWindowNibName: @"PrimaryWindow"];
	[self.windowController showWindow: self];
}

@end
