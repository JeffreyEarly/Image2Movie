//
//  AppController.h
//  Image2Movie
//
//  Created by Jeffrey Early on 4/27/10.
//  Copyright 2010 Early Innovations, LLC. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PrimaryWindowController.h"

@interface AppController : NSObject

@property(readwrite, strong, nonatomic) PrimaryWindowController *windowController;

@end
