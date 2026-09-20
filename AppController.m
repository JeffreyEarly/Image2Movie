//
//  AppController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 4/27/10.
//  Copyright 2010 Early Innovations, LLC. All rights reserved.
//

#import "AppController.h"
#import "Image2Movie-Swift.h"

@implementation AppController

@synthesize windowController;

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	self.windowController = [[PrimaryWindowController alloc] initWithWindowNibName: @"PrimaryWindow"];
	[self.windowController showWindow: self];
    [AutomationBootstrap finishLaunching];
}

- (IBAction)showAutomationSettings:(id)sender
{
    [[AutomationSettingsController shared] showWindow:sender];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    ExportCoordinator *coordinator = [ExportCoordinator shared];
    if (!coordinator.hasActiveExport) return NSTerminateNow;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Cancel the export and quit?";
    alert.informativeText = @"The current export will be cancelled before Image2Movie quits. Any previous movie will be preserved.";
    [alert addButtonWithTitle:@"Keep Exporting"];
    [alert addButtonWithTitle:@"Cancel Export and Quit"];
    if ([alert runModal] != NSAlertSecondButtonReturn) return NSTerminateCancel;
    [coordinator prepareForTerminationWithCompletion:^{ [sender replyToApplicationShouldTerminate:YES]; }];
    return NSTerminateLater;
}

@end
