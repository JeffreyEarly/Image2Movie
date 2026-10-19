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
@class FileAccessLease;

NS_ASSUME_NONNULL_BEGIN

@interface ImageTableView : NSTableView <NSUserInterfaceValidations>
- (IBAction)delete:(id)sender;
@end

@interface ImageTableController : NSObject <NSTableViewDataSource>

@property(nullable, unsafe_unretained) IBOutlet NSTableView *imageTable;
@property(nullable, unsafe_unretained) IBOutlet NSArrayController *imagePathArrayController;
@property(nullable, nonatomic, weak) ImagesToMovie *imagesToMovie;
@property(nullable, nonatomic, strong) NSUndoManager *undoManager;

+ (NSArray<UTType *> *)supportedImageContentTypes;
- (BOOL)importImageURLs:(NSArray<NSURL *> *)URLs;
- (nullable FileAccessLease *)leaseForImagePath:(NSString *)path;
- (NSArray<FileAccessLease *> *)currentImageLeases;

- (IBAction)removeSelectedImages:(id)sender;

@end

NS_ASSUME_NONNULL_END
