//
//  ImageTableController.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <AppKit/AppKit.h>

@interface ImageTableController : NSObject <NSTableViewDataSource>

@property(unsafe_unretained) IBOutlet NSTableView *imageTable;
@property(unsafe_unretained) IBOutlet NSArrayController *imagePathArrayController;

@end
