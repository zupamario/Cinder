//
//  CustomNSApplication.m
//  cinder
//
//  Created by Poerner, Mario on 5/23/17.
//
//

#import "CustomNSApplication.h"

@implementation CustomNSApplication

- (void)run {
	[super run];
}

- (void)sendEvent:(NSEvent *)event {
	if ([event type] == NSKeyUp && ([event modifierFlags] & NSCommandKeyMask))
		[[self keyWindow] sendEvent:event];
	else
		[super sendEvent:event];
}

@end
