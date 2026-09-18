//
//  ImageTableController.m
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ImageTableController.h"

static NSPasteboardType const ImageRowPasteboardType = @"org.image2movie.row-index";

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
    return item.action != @selector(delete:) || (self.enabled && self.selectedRowIndexes.count > 0);
}

@end

@implementation ImageTableController
@synthesize imageTable;
@synthesize imagePathArrayController;

- (void) awakeFromNib
{
	[self.imageTable registerForDraggedTypes:[NSArray arrayWithObjects: NSFilenamesPboardType, ImageRowPasteboardType, nil]];
}

- (IBAction)removeSelectedImages:(id)sender
{
    if (!self.imageTable.enabled) return;
    [self.imagePathArrayController removeObjectsAtArrangedObjectIndexes:self.imageTable.selectedRowIndexes];
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

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row
{
    if (row < 0 || row >= [self.imagePathArrayController.arrangedObjects count]) return nil;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setPropertyList:@(row) forType:ImageRowPasteboardType];
    return item;
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
        [self.imagePathArrayController addObjects: [[info draggingPasteboard] propertyListForType: NSFilenamesPboardType]];
        
        return YES;
    }
    
    return NO;
}


@end
