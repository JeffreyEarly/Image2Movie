//
//  AddMovieFrameOperation.m
//  Image2Movie
//
//  Created by Jeffrey Early on 4/27/10.
//  Copyright 2010 Early Innovations, LLC. All rights reserved.
//

#import "AddMovieFrameOperation.h"


@implementation AddMovieFrameOperation

- (void) main
{
	if (self.movie && self.image)
	{
		[self.movieLock lock];
		
		// Inform QTKit that we want to mess with this movie on this thread.
		[QTMovie enterQTKitOnThread];
		{
			if ( ![self.movie attachToCurrentThread]) {NSLog(@"FAILED: attached time step");[self.movieLock unlock]; return;}
            
            // We want avc1 for h264. See ImageCompression.h for others.
			NSDictionary *codecDictionary = @{QTAddImageCodecType:@"avc1", QTAddImageCodecQuality:@(codecHighQuality)};
			[self.movie addImage: self.image forDuration: QTMakeTime((long long) 1, (long) self.frameRate) withAttributes:codecDictionary];
			[self.movie updateMovieFile];
			
			if ( ![self.movie detachFromCurrentThread] ) NSLog(@"FAILED: detached time step");
		}
		[QTMovie exitQTKitOnThread];
		
		[self.movieLock unlock];
	}
	
	for (NSOperation *operation in self.dependencies) {
		[self removeDependency: operation];
	}
}

@end
