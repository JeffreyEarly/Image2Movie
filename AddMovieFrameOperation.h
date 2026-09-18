//
//  AddMovieFrameOperation.h
//  Image2Movie
//
//  Created by Jeffrey Early on 4/27/10.
//  Copyright 2010 Early Innovations, LLC. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <QTKit/QTKit.h>

@interface AddMovieFrameOperation : NSOperation

@property(nonatomic,strong) NSImage *image;
@property(nonatomic,strong) QTMovie *movie;
@property(nonatomic,strong) NSLock *movieLock;
@property NSUInteger frameRate;

@end
