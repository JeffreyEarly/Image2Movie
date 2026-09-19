//
//  ImageTableController.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@class ImagesToMovie;

@interface ImageTableView : NSTableView <NSUserInterfaceValidations>
- (IBAction)delete:(id)sender;
@end

@interface ImageTableController : NSObject <NSTableViewDataSource>

@property(unsafe_unretained) IBOutlet NSTableView *imageTable;
@property(unsafe_unretained) IBOutlet NSArrayController *imagePathArrayController;
@property(nonatomic, weak) ImagesToMovie *imagesToMovie;
@property(nonatomic, strong) NSUndoManager *undoManager;

+ (NSArray<UTType *> *)supportedImageContentTypes;
- (BOOL)importImageURLs:(NSArray<NSURL *> *)URLs;

- (IBAction)removeSelectedImages:(id)sender;

@end
