//
//  ImageTableController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImageTableController.h"

NSString *IndicesPasteboardType = @"IndicesPasteboardType";

@implementation ImageTableController
@synthesize imageTable;
@synthesize imagePathArrayController;

- (void) awakeFromNib
{
	[self.imageTable registerForDraggedTypes:[NSArray arrayWithObjects: NSFilenamesPboardType, IndicesPasteboardType, nil]];
}

/************************************************/
/*		NSTableDataSource						*/
/************************************************/

#pragma mark -
#pragma mark NSTableDataSource
#pragma mark

- (void) moveItemsAtIndexes: (NSIndexSet*)indexes toIndex: (NSUInteger) destinationIndex
{
    [self.imagePathArrayController setSortDescriptors: [NSArray array]];
    NSArray* temp = [[self.imagePathArrayController arrangedObjects] objectsAtIndexes: indexes];
	
    NSInteger index;
    for (index = [indexes lastIndex]; index != NSNotFound; index = [indexes indexLessThanIndex:index]) {
        if (index < destinationIndex)
			destinationIndex --;
    }
    
    [self.imagePathArrayController removeObjectsAtArrangedObjectIndexes: indexes];
    [self.imagePathArrayController insertObjects: temp atArrangedObjectIndexes: [NSIndexSet indexSetWithIndexesInRange: NSMakeRange( destinationIndex, [temp count])]];
    
    [self.imagePathArrayController setSelectionIndexes: [NSIndexSet indexSetWithIndexesInRange: NSMakeRange( destinationIndex, [temp count])]];
}

- (BOOL) tableView: (NSTableView *) aTableView writeRowsWithIndexes: (NSIndexSet *) rowIndexes toPasteboard: (NSPasteboard *) pboard
{
    [pboard declareTypes: [NSArray arrayWithObject: IndicesPasteboardType] owner:self];
    NSData *rowIndexesArchive = [NSKeyedArchiver archivedDataWithRootObject:rowIndexes];
    [pboard setData:rowIndexesArchive forType:IndicesPasteboardType];
    
    return YES;
}

- (NSDragOperation) tableView: (NSTableView*) aTableView validateDrop: (id <NSDraggingInfo>)info proposedRow: (NSInteger) row proposedDropOperation: (NSTableViewDropOperation) operation
{
    if ([info draggingSource] == self.imageTable) {
        [aTableView setDropRow: row dropOperation:NSTableViewDropAbove];
        return NSDragOperationMove;
    }
    else /* if ([[PrimaryViewAndToolbarController sharedPrimaryViewAndToolbarController] validateFilesAtPaths: [[info draggingPasteboard] propertyListForType: NSFilenamesPboardType]]) */
	{
        [aTableView setDropRow: [[self.imagePathArrayController arrangedObjects] count] dropOperation:NSTableViewDropAbove];
        return NSDragOperationCopy;
    }
	
    return NSDragOperationNone;
}

- (BOOL) tableView: (NSTableView *) aTableView acceptDrop: (id <NSDraggingInfo>)info row: (NSInteger) row dropOperation: (NSTableViewDropOperation) operation
{
    if ([info draggingSource] == self.imageTable) {
        [self moveItemsAtIndexes: [NSKeyedUnarchiver unarchiveObjectWithData: [[info draggingPasteboard] dataForType:IndicesPasteboardType]] toIndex: row];				
        return YES;
    }
    else {
        [self.imagePathArrayController addObjects: [[info draggingPasteboard] propertyListForType: NSFilenamesPboardType]];
        
        return YES;
    }
    
    return NO;
}


@end
