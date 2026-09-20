//
//  ImageTableController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImageTableController.h"
#import "ImagesToMovie.h"
#import "Image2Movie-Swift.h"

static NSPasteboardType const ImageRowPasteboardType = @"org.image2movie.row-index";

@interface ImageTableState : NSObject
@property(nonatomic, copy) NSArray<NSString *> *paths;
@property(nonatomic, copy) NSArray<NSSortDescriptor *> *sortDescriptors;
@property(nonatomic, copy) NSIndexSet *selectionIndexes;
@property(nonatomic, copy) NSDictionary<NSString *, FileAccessLease *> *leasesByPath;
@end
@implementation ImageTableState
@end

@interface ImageTableController ()
@property(nonatomic, copy) NSDictionary<NSString *, FileAccessLease *> *leasesByPath;
- (void)restoreState:(ImageTableState *)state actionName:(NSString *)actionName;
@end

@implementation ImageTableView

- (void)keyDown:(NSEvent *)event
{
    NSString *characters = event.charactersIgnoringModifiers;
    if (!(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) &&
        characters.length == 1) {
        unichar key = [characters characterAtIndex:0];
        if (key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteFunctionKey) {
            [self delete:self];
            return;
        }
    }
    [super keyDown:event];
}

- (IBAction)delete:(id)sender
{
    [(ImageTableController *)self.dataSource removeSelectedImages:sender];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    ImageTableController *controller = (ImageTableController *)self.dataSource;
    BOOL canDelete = self.enabled && controller.imagesToMovie &&
        !controller.imagesToMovie.movieCreationInProgress && self.selectedRowIndexes.count > 0;
    return item.action != @selector(delete:) || canDelete;
}

@end

@implementation ImageTableController
@synthesize imageTable;
@synthesize imagePathArrayController;

- (void) awakeFromNib
{
	[self.imageTable registerForDraggedTypes:@[NSPasteboardTypeFileURL, ImageRowPasteboardType]];
}

- (IBAction)removeSelectedImages:(id)sender
{
    if (![self canMutate]) return;
    NSIndexSet *indexes = self.imageTable.selectedRowIndexes;
    NSArray *arranged = [self.imagePathArrayController.arrangedObjects copy];
    if (!indexes.count || indexes.lastIndex >= arranged.count) return;

    NSArray<NSString *> *modelPaths = [self.imagesToMovie.imagePaths copy];
    NSMutableIndexSet *unusedModelIndexes = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, modelPaths.count)];
    NSMutableIndexSet *modelIndexesToRemove = [NSMutableIndexSet indexSet];
    for (NSUInteger arrangedIndex = 0; arrangedIndex < arranged.count; arrangedIndex++) {
        NSString *arrangedPath = arranged[arrangedIndex];
        NSUInteger modelIndex = [unusedModelIndexes indexPassingTest:^BOOL(NSUInteger candidate, BOOL *stop) {
            return modelPaths[candidate] == arrangedPath;
        }];
        if (modelIndex == NSNotFound) {
            modelIndex = [unusedModelIndexes indexPassingTest:^BOOL(NSUInteger candidate, BOOL *stop) {
                return [modelPaths[candidate] isEqual:arrangedPath];
            }];
        }
        if (modelIndex == NSNotFound) return;
        [unusedModelIndexes removeIndex:modelIndex];
        if ([indexes containsIndex:arrangedIndex]) [modelIndexesToRemove addIndex:modelIndex];
    }
    NSMutableArray *paths = [modelPaths mutableCopy];
    [paths removeObjectsAtIndexes:modelIndexesToRemove];
    [self replacePaths:paths
       sortDescriptors:self.imagePathArrayController.sortDescriptors
      selectionIndexes:[NSIndexSet indexSet]
            actionName:@"Remove Images" additionalLeases:nil];
}

+ (NSArray<UTType *> *)supportedImageContentTypes
{
    static NSArray<UTType *> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<UTType *> *result = [NSMutableArray array];
        NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
        for (NSString *identifier in NSImage.imageTypes) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type && ![identifiers containsObject:type.identifier]) {
                [identifiers addObject:type.identifier];
                [result addObject:type];
            }
        }
        types = [result copy];
    });
    return types;
}

- (BOOL)importImageURLs:(NSArray<NSURL *> *)URLs
{
    if (![self canMutate] || !URLs.count) return NO;

    NSMutableArray<NSString *> *accepted = [NSMutableArray array];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    NSMutableArray<NSString *> *unsupported = [NSMutableArray array];
    NSMutableArray<NSString *> *unreadable = [NSMutableArray array];
    NSMutableDictionary<NSString *, FileAccessLease *> *importLeases = [NSMutableDictionary dictionary];
    [self classifyURLs:URLs acceptedPaths:accepted folders:folders unsupported:unsupported
           unreadable:unreadable leases:importLeases];

    if (accepted.count && [self canMutate]) {
        NSMutableArray *paths = [self.imagesToMovie.imagePaths mutableCopy];
        [paths addObjectsFromArray:accepted];
        [self replacePaths:paths
           sortDescriptors:self.imagePathArrayController.sortDescriptors
          selectionIndexes:self.imageTable.selectedRowIndexes
                actionName:@"Add Images" additionalLeases:importLeases];
    } else {
        [accepted removeAllObjects];
    }

    if (folders.count || unsupported.count || unreadable.count)
        [self presentSkippedImportAlertWithFolders:folders unsupported:unsupported unreadable:unreadable];
    return accepted.count > 0;
}

- (BOOL)canMutate
{
    return self.imagesToMovie && !self.imagesToMovie.movieCreationInProgress;
}

- (ImageTableState *)currentState
{
    ImageTableState *state = [[ImageTableState alloc] init];
    state.paths = [self.imagesToMovie.imagePaths copy] ?: @[];
    state.sortDescriptors = [self.imagePathArrayController.sortDescriptors copy] ?: @[];
    state.selectionIndexes = [self.imageTable.selectedRowIndexes copy] ?: [NSIndexSet indexSet];
    state.leasesByPath = [self.leasesByPath copy] ?: @{};
    return state;
}

- (void)replacePaths:(NSArray<NSString *> *)paths
     sortDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
    selectionIndexes:(NSIndexSet *)selectionIndexes
          actionName:(NSString *)actionName
    additionalLeases:(NSDictionary<NSString *, FileAccessLease *> *)additionalLeases
{
    if (![self canMutate]) return;
    ImageTableState *before = [self currentState];
    NSArray *sorts = sortDescriptors ?: @[];
    NSIndexSet *selection = selectionIndexes ?: [NSIndexSet indexSet];
    if ([before.paths isEqual:paths] && [before.sortDescriptors isEqual:sorts] &&
        [before.selectionIndexes isEqual:selection]) return;

    NSMutableDictionary<NSString *, FileAccessLease *> *nextLeases = [self.leasesByPath mutableCopy] ?: [NSMutableDictionary dictionary];
    [nextLeases addEntriesFromDictionary:additionalLeases ?: @{}];
    NSSet<NSString *> *retainedPaths = [NSSet setWithArray:paths];
    for (NSString *path in [nextLeases.allKeys copy]) {
        if (![retainedPaths containsObject:path]) [nextLeases removeObjectForKey:path];
    }
    self.leasesByPath = nextLeases;
    self.imagesToMovie.imagePaths = [paths mutableCopy];
    self.imagePathArrayController.sortDescriptors = sorts;
    [self.imagePathArrayController rearrangeObjects];
    NSMutableIndexSet *validSelection = [selection mutableCopy];
    NSUInteger arrangedCount = [self.imagePathArrayController.arrangedObjects count];
    [validSelection removeIndexesInRange:NSMakeRange(arrangedCount, NSUIntegerMax - arrangedCount)];
    self.imagePathArrayController.selectionIndexes = validSelection;
    [self.imageTable selectRowIndexes:validSelection byExtendingSelection:NO];

    if (self.undoManager) {
        [self.undoManager registerUndoWithTarget:self handler:^(ImageTableController *target) {
            [target restoreState:before actionName:actionName];
        }];
        self.undoManager.actionName = actionName;
    }
}

- (void)restoreState:(ImageTableState *)state actionName:(NSString *)actionName
{
    if (![self canMutate]) return;
    [self replacePaths:state.paths sortDescriptors:state.sortDescriptors
      selectionIndexes:state.selectionIndexes actionName:actionName additionalLeases:state.leasesByPath];
}

- (FileAccessLease *)leaseForImagePath:(NSString *)path
{
    return self.leasesByPath[path];
}

- (NSArray<FileAccessLease *> *)currentImageLeases
{
    return self.leasesByPath.allValues ?: @[];
}

- (void)classifyURLs:(NSArray<NSURL *> *)URLs
       acceptedPaths:(NSMutableArray<NSString *> *)accepted
             folders:(NSMutableArray<NSString *> *)folders
         unsupported:(NSMutableArray<NSString *> *)unsupported
          unreadable:(NSMutableArray<NSString *> *)unreadable
              leases:(NSMutableDictionary<NSString *, FileAccessLease *> *)leases
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<UTType *> *supportedTypes = self.class.supportedImageContentTypes;
    for (NSURL *URL in URLs) {
        if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) {
            [unreadable addObject:URL.lastPathComponent ?: URL.description ?: @"Unknown item"];
            continue;
        }
        NSError *leaseError = nil;
        FileAccessLease *lease = [[FileAccessManager shared] leaseForReadingURLs:@[URL] error:&leaseError];
        if (!lease) {
            [unreadable addObject:URL.lastPathComponent ?: @"Unknown item"];
            continue;
        }
        NSNumber *isDirectory;
        NSNumber *isRegularFile;
        UTType *contentType;
        NSError *error;
        BOOL readMetadata = [URL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error] &&
            [URL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:&error] &&
            [URL getResourceValue:&contentType forKey:NSURLContentTypeKey error:&error];
        if (isDirectory.boolValue) {
            [folders addObject:URL.lastPathComponent];
            continue;
        }
        if (!readMetadata || !isRegularFile.boolValue || ![fileManager isReadableFileAtPath:URL.path]) {
            [unreadable addObject:URL.lastPathComponent];
            continue;
        }
        BOOL supported = NO;
        for (UTType *type in supportedTypes) {
            if ([contentType conformsToType:type]) { supported = YES; break; }
        }
        if (supported) {
            [accepted addObject:URL.path];
            if (!self.leasesByPath[URL.path] && !leases[URL.path]) leases[URL.path] = lease;
        }
        else [unsupported addObject:URL.lastPathComponent];
    }
}

- (void)presentSkippedImportAlertWithFolders:(NSArray<NSString *> *)folders
                                 unsupported:(NSArray<NSString *> *)unsupported
                                  unreadable:(NSArray<NSString *> *)unreadable
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (folders.count) [lines addObject:[NSString stringWithFormat:@"Folders: %@", [folders componentsJoinedByString:@", "]]];
    if (unsupported.count) [lines addObject:[NSString stringWithFormat:@"Unsupported files: %@", [unsupported componentsJoinedByString:@", "]]];
    if (unreadable.count) [lines addObject:[NSString stringWithFormat:@"Missing or unreadable files: %@", [unreadable componentsJoinedByString:@", "]]];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Some items were not imported";
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:@"OK"];
    if (self.imageTable.window) [alert beginSheetModalForWindow:self.imageTable.window completionHandler:nil];
    else [alert runModal];
}

/************************************************/
/*		NSTableDataSource						*/
/************************************************/

#pragma mark -
#pragma mark NSTableDataSource
#pragma mark

- (void) moveItemsAtIndexes: (NSIndexSet*)indexes toIndex: (NSUInteger) destinationIndex
{
    if (![self canMutate]) return;
    NSArray *arranged = [self.imagePathArrayController.arrangedObjects copy];
    if (!indexes.count || indexes.lastIndex >= arranged.count || destinationIndex > arranged.count) return;
    NSArray *moved = [arranged objectsAtIndexes:indexes];
    NSMutableArray *result = [arranged mutableCopy];

    NSUInteger index;
    for (index = indexes.lastIndex; index != NSNotFound; index = [indexes indexLessThanIndex:index]) {
        if (index < destinationIndex)
			destinationIndex --;
    }
    [result removeObjectsAtIndexes:indexes];
    NSIndexSet *insertIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(destinationIndex, moved.count)];
    [result insertObjects:moved atIndexes:insertIndexes];
    if ([result isEqual:self.imagesToMovie.imagePaths] && self.imagePathArrayController.sortDescriptors.count == 0) {
        self.imagePathArrayController.selectionIndexes = insertIndexes;
        [self.imageTable selectRowIndexes:insertIndexes byExtendingSelection:NO];
        return;
    }
    [self replacePaths:result sortDescriptors:@[] selectionIndexes:insertIndexes actionName:@"Reorder Images" additionalLeases:nil];
}

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row
{
    if (![self canMutate]) return nil;
    if (row < 0 || row >= [self.imagePathArrayController.arrangedObjects count]) return nil;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setPropertyList:@(row) forType:ImageRowPasteboardType];
    return item;
}

- (NSDragOperation) tableView: (NSTableView*) aTableView validateDrop: (id <NSDraggingInfo>)info proposedRow: (NSInteger) row proposedDropOperation: (NSTableViewDropOperation) operation
{
    if (![self canMutate]) return NSDragOperationNone;
    if ([info draggingSource] == self.imageTable) {
        if (operation != NSTableViewDropAbove || row < 0 || row > (NSInteger)[self.imagePathArrayController.arrangedObjects count])
            return NSDragOperationNone;
        [aTableView setDropRow: row dropOperation:NSTableViewDropAbove];
        return NSDragOperationMove;
    }
    else if ([info.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) {
        [aTableView setDropRow: [[self.imagePathArrayController arrangedObjects] count] dropOperation:NSTableViewDropAbove];
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL) tableView: (NSTableView *) aTableView acceptDrop: (id <NSDraggingInfo>)info row: (NSInteger) row dropOperation: (NSTableViewDropOperation) operation
{
    if (![self canMutate]) return NO;
    if ([info draggingSource] == self.imageTable) {
        NSUInteger count = [self.imagePathArrayController.arrangedObjects count];
        if (row < 0 || row > count) return NO;
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        for (NSPasteboardItem *item in info.draggingPasteboard.pasteboardItems) {
            NSNumber *index = [item propertyListForType:ImageRowPasteboardType];
            if (![index isKindOfClass:[NSNumber class]] || index.integerValue < 0 || index.unsignedIntegerValue >= count) return NO;
            [indexes addIndex:index.unsignedIntegerValue];
        }
        if (!indexes.count) return NO;
        [self moveItemsAtIndexes:indexes toIndex:row];
        return YES;
    }
    else {
        NSArray<NSURL *> *URLs = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
            options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
        return [self importImageURLs:URLs];
    }
}


@end
