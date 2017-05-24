//
//  CustomNSApplication.m
//  cinder
//
//  Created by Poerner, Mario on 5/23/17.
//
//

#import <AppKit/NSApplication.h>

@interface CustomNSApplication : NSApplication {
}
- (void)run;
- (void)sendEvent:(NSEvent *)event;
@end
