//
//  LGSmartScanner.h
//  Vertex Watcher
//
//  Created by Louis Gerbarg on 8/6/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface LGSmartScanner : NSObject {
  NSNumber *wearCount;
  NSNumber *lifePercent;
  io_object_t drive;
}

- (void) scan;

@property (nonatomic, retain) NSNumber *wearCount;
@property (nonatomic, retain) NSNumber *lifePercent;

@property (nonatomic) io_object_t drive;


@end
