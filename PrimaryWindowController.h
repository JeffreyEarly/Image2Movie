//
//  PrimaryWindowController.h
//  Image2Movie
//
//  Created by Jeffrey Early on 11/3/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ImagesToMovie.h"
#import "ImagesToMovieController.h"
#import "ImageTableController.h"

@interface PrimaryWindowController : NSWindowController

@property (strong) IBOutlet ImagesToMovieController *imagesToMovieController;
@property (strong) IBOutlet ImageTableController *imageTableController;

/************************************************/
/*		Controller								*/
/************************************************/

#pragma mark -
#pragma mark Controller
#pragma mark

- (IBAction) openImageFilesAction: (id) sender;

// This will either build the movie, or cancel the movie that's being built.
@property(readwrite, copy, nonatomic) NSString *buttonTitle;
@property(readonly, nonatomic) BOOL saveOrCancelEnabled;
- (IBAction) buttonClicked: (id) sender;

/************************************************/
/*		Model									*/
/************************************************/

#pragma mark -
#pragma mark Model
#pragma mark

@property(readwrite, strong, nonatomic) ImagesToMovie *imagesToMovie;



@end
