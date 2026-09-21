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
	BOOL automationLaunch = [AutomationBootstrap isAutomationLaunch];
	self.windowController = [[PrimaryWindowController alloc] initWithWindowNibName: @"PrimaryWindow"];
	if (automationLaunch) {
		// Force the existing controller and bindings to load, but do not order the
		// window or activate the app. Clearing the first responder also prevents a
		// hidden field editor from making automation report a busy draft.
		NSWindow *window = self.windowController.window;
		window.restorable = NO;
		[window makeFirstResponder:nil];
	} else {
		[self.windowController showWindow: self];
	}
    [AutomationBootstrap finishLaunching];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
	if (!self.windowController) return NO;
	if ([AutomationBootstrap isAutomationReopen]) {
		return NO;
	}
	self.windowController.window.restorable = YES;
	[self.windowController showWindow: self];
	[sender activateIgnoringOtherApps:YES];
	return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return NO;
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
