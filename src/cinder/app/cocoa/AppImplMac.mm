/*
 Copyright (c) 2012, The Cinder Project, All rights reserved.

 This code is intended for use with the Cinder C++ library: http://libcinder.org

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and
	the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
	the following disclaimer in the documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
*/

#include "cinder/app/cocoa/AppImplMac.h"
#include "cinder/app/Renderer.h"
#include "cinder/app/Window.h"
#include "cinder/app/cocoa/PlatformCocoa.h"
#include "cinder/Log.h"
#import "cinder/cocoa/CinderCocoa.h"

#include <memory>

#import <OpenGL/OpenGL.h>

using namespace cinder;
using namespace cinder::app;

// Prototypes
void WacomAttachCallback(WacomMTCapability deviceInfo, void *userInfo);
void WacomDetachCallback(int deviceID, void *userInfo);
int WacomFingerCallback(WacomMTFingerCollection *fingerPacket, void *userData);

// This seems to be missing for unknown reasons
@interface NSApplication(MissingFunction)
- (void)setAppleMenu:(NSMenu *)menu;
@end 

// CinderWindow - necessary to enable a borderless window to receive keyboard events
@interface CinderWindow : NSWindow {
}
- (BOOL)canBecomeMainWindow;
- (BOOL)canBecomeKeyWindow;
@end
@implementation CinderWindow
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }
@end

// private properties
@interface AppImplMac()
@property(nonatomic) IOPMAssertionID idleSleepAssertionID;
@property(nonatomic) IOPMAssertionID displaySleepAssertionID;
@end

@implementation AppImplMac

@synthesize windows = mWindows;

@synthesize idleSleepAssertionID = mIdleSleepAssertionID;
@synthesize displaySleepAssertionID = mDisplaySleepAssertionID;

- (AppImplMac *)init:(AppMac *)app settings:(const AppMac::Settings &)settings
{	
	self = [super init];

	// This needs to be called before creating any windows, as it internally constructs the shared NSApplication
	[[NSApplication sharedApplication] setDelegate:self];

	NSMenu *mainMenu = [[NSMenu alloc] init];
	[NSApp setMainMenu:mainMenu];
	[mainMenu release];
	
	self.windows = [NSMutableArray array];
	
	const std::string& applicationName = settings.getTitle();
	[self setApplicationMenu:[NSString stringWithUTF8String: applicationName.c_str()]];
	
	mApp = app;
	mNeedsUpdate = YES;
	mQuitOnLastWindowClosed = settings.isQuitOnLastWindowCloseEnabled(); // TODO: consider storing this in AppBase. it is also needed by AppMsw's impl

	// build our list of requested formats; an empty list implies we should make the default window format
	std::vector<Window::Format> formats( settings.getWindowFormats() );
	if( formats.empty() )
		formats.push_back( settings.getDefaultWindowFormat() );

	// create all the requested windows
	for( const auto &format : formats ) {
		WindowImplBasicCocoa *winImpl = [WindowImplBasicCocoa instantiate:format withAppImpl:self];
		[mWindows addObject:winImpl];
		if( format.isFullScreen() )
			[winImpl setFullScreen:YES options:&format.getFullScreenOptions()];
	}
	
	mFrameRate = settings.getFrameRate();
	mFrameRateEnabled = settings.isFrameRateEnabled();

	// lastly, ensure the first window is the currently active context
	[((WindowImplBasicCocoa *)[mWindows firstObject])->mCinderView makeCurrentContext];

	return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	mApp->getRenderer()->makeCurrentContext();

	mApp->privateSetup__();
	
	// give all windows initial resizes
	for( WindowImplBasicCocoa* winIt in mWindows ) {
		[winIt->mCinderView makeCurrentContext];
		[self setActiveWindow:winIt];
		winIt->mWindowRef->emitResize();
	}	
	
	// when available, make the first window the active window
	[self setActiveWindow:[mWindows firstObject]];
	[self startAnimationTimer];
}

- (void)startAnimationTimer
{
	if( mAnimationTimer && [mAnimationTimer isValid] )
		[mAnimationTimer invalidate];
	
	float interval = ( mFrameRateEnabled ) ? 1.0f / mFrameRate : 0.001;
	mAnimationTimer = [NSTimer	 timerWithTimeInterval:interval
												target:self
											  selector:@selector(timerFired:)
											  userInfo:nil
											   repeats:YES];
	
	[[NSRunLoop currentRunLoop] addTimer:mAnimationTimer forMode:NSDefaultRunLoopMode];
	[[NSRunLoop currentRunLoop] addTimer:mAnimationTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)pauseAnimation
{
	pauseStart = [[NSDate dateWithTimeIntervalSinceNow:0] retain];
	previousFireDate = [[mAnimationTimer fireDate] retain];
	[mAnimationTimer setFireDate:[NSDate distantFuture]];
}

- (void)resumeAnimation
{
	float pauseTime = -1*[pauseStart timeIntervalSinceNow];
	[mAnimationTimer setFireDate:[previousFireDate initWithTimeInterval:pauseTime sinceDate:previousFireDate]];
	[pauseStart release];
	[previousFireDate release];
}

- (void)timerFired:(NSTimer *)t
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		// issue update() event
		mApp->privateUpdate__();

		// mark all windows as ready to draw; this really only matters the first time, to ensure the first update() fires before draw()
		for( WindowImplBasicCocoa* winIt in mWindows ) {
			[winIt->mCinderView setReadyToDraw:YES];
		}
		
		// walk all windows and draw them
		for( WindowImplBasicCocoa* winIt in mWindows ) {
			[winIt->mCinderView draw];
		}
	}
}

- (app::WindowRef)createWindow:(const Window::Format &)format
{
	WindowImplBasicCocoa *winImpl = [WindowImplBasicCocoa instantiate:format withAppImpl:self];
	[mWindows addObject:winImpl];
	if( format.isFullScreen() )
		[winImpl setFullScreen:YES options:&format.getFullScreenOptions()];

	// pass the window its first resize
	[winImpl->mCinderView makeCurrentContext];
	[self setActiveWindow:winImpl];
	winImpl->mWindowRef->emitResize();

	// mark the window as readyToDraw, now that we've resized it
	[winImpl->mCinderView setReadyToDraw:YES];
		
	return winImpl->mWindowRef;
}

// Returns a pointer to a Renderer of the same type if any existing Windows have one of the same type
- (RendererRef)findSharedRenderer:(RendererRef)match
{
	for( WindowImplBasicCocoa* winIt in mWindows ) {
		RendererRef renderer = [winIt->mCinderView getRenderer];
		if( typeid(renderer) == typeid(match) )
			return renderer;
	}
	
	return RendererRef();
}

- (app::WindowRef)getWindow
{
	if( ! mActiveWindow )
		throw ExcInvalidWindow();
	else
		return mActiveWindow->mWindowRef;
}

- (app::WindowRef)getForegroundWindow
{
	NSWindow *mainWin = [NSApp mainWindow];
	WindowImplBasicCocoa *winImpl = [self findWindowImpl:mainWin];
	if( winImpl )
		return winImpl->mWindowRef;
	else
		return app::WindowRef();
}

- (size_t)getNumWindows
{
	return [mWindows count];
}

- (app::WindowRef)getWindowIndex:(size_t)index
{
	if( index >= [mWindows count] )
		throw ExcInvalidWindow();
	
	WindowImplBasicCocoa *winImpl = [mWindows objectAtIndex:index];
	return winImpl->mWindowRef;
}

- (void)setActiveWindow:(WindowImplBasicCocoa *)win
{
	mActiveWindow = win;
}

- (WindowImplBasicCocoa *)findWindowImpl:(NSWindow *)window
{
	for( WindowImplBasicCocoa* winIt in mWindows ) {
		if( winIt->mWin == window )
			return winIt;
	}

	return nil;
}

- (void)releaseWindow:(WindowImplBasicCocoa *)windowImpl
{
	if( mActiveWindow == windowImpl ) {
		if( [mWindows count] == 1 ) // we're about to release the last window; set the active window to be NULL
			mActiveWindow = nil;
		else
			mActiveWindow = [mWindows firstObject];
	}

	windowImpl->mWindowRef->setInvalid();
	windowImpl->mWindowRef.reset();
	windowImpl->mWin = nil;
	[mWindows removeObject:windowImpl];
}

// This is all necessary because we don't use NIBs in Cinder apps
// and we have to generate our menu programmatically
- (void)setApplicationMenu:(NSString *)applicationName
{
	NSMenu *appleMenu;
	NSMenuItem *menuItem;
	NSString *title;
	appleMenu = [[NSMenu alloc] initWithTitle:@""];

	/* Add menu items */
	title = [@"About " stringByAppendingString:applicationName];
	[appleMenu addItemWithTitle:title action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];

	[appleMenu addItem:[NSMenuItem separatorItem]];

	title = [@"Hide " stringByAppendingString:applicationName];
	[appleMenu addItemWithTitle:title action:@selector(hide:) keyEquivalent:@"h"];

	menuItem = (NSMenuItem *)[appleMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	[menuItem setKeyEquivalentModifierMask:(NSAlternateKeyMask|NSCommandKeyMask)];

	[appleMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];

	[appleMenu addItem:[NSMenuItem separatorItem]];

	title = [@"Quit " stringByAppendingString:applicationName];
	[appleMenu addItemWithTitle:title action:@selector(quit) keyEquivalent:@"q"];

	/* Put menu into the menubar */
	menuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[menuItem setSubmenu:appleMenu];
	[[NSApp mainMenu] addItem:menuItem];

	/* Tell the application object that this is now the application menu */
	[NSApp setAppleMenu:appleMenu];

	/* Finally give up our references to the objects */
	[appleMenu release];
	[menuItem release];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	// we need to close all existing windows
	while( [mWindows count] > 0 ) {
		// this counts on windowWillCloseNotification: firing and in turn calling releaseWindow
		[[mWindows lastObject] close];
	}
	
	if(WacomMTQuit != NULL) // check API framework availability
	{
		WacomMTQuit();
	}

	mApp->emitCleanup();
	delete mApp;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	// Due to bug #960: https://github.com/cinder/Cinder/issues/960 We need to force the background window
	// to be actually in the background when we're fullscreen. Was true of 10.9 and 10.10
	if( app::AppBase::get() && app::getWindow() && app::getWindow()->isFullScreen() )
		[[[NSApplication sharedApplication] mainWindow] orderBack:nil];

	mApp->emitDidBecomeActive();
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
	mApp->emitWillResignActive();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application
{
	return mQuitOnLastWindowClosed;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application
{
	bool shouldQuit = mApp->privateEmitShouldQuit();
	return ( shouldQuit ) ? NSTerminateNow : NSTerminateCancel;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
	return YES;
}

- (void)rightMouseDown:(NSEvent *)event
{
//TODO
//	if( cinderView )
//		[cinderView rightMouseDown:event];
}

- (void)quit
{
	// in certain scenarios self seems to have be deallocated inside terminate:
	// so we call this here and then pass nil to terminate: instead
	if( ! mApp->privateEmitShouldQuit() )
		return;

	[NSApp stop:nil];
}

- (void)setPowerManagementEnabled:(BOOL)flag
{
	if( flag && ![self isPowerManagementEnabled] ) {
		CFStringRef reasonForActivity = CFSTR( "Cinder Application Execution" );
		IOReturn status = IOPMAssertionCreateWithName( kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn, reasonForActivity, &mIdleSleepAssertionID );
		if( status != kIOReturnSuccess ) {
			CI_LOG_E( "failed to create power management assertion to prevent idle system sleep" );
		}

		status = IOPMAssertionCreateWithName( kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertionLevelOn, reasonForActivity, &mDisplaySleepAssertionID );
		if( status != kIOReturnSuccess ) {
			CI_LOG_E( "failed to create power management assertion to prevent idle display sleep" );
		}
	} else if( !flag && [self isPowerManagementEnabled] ) {
		IOReturn status = IOPMAssertionRelease( self.idleSleepAssertionID );
		if( status != kIOReturnSuccess ) {
			CI_LOG_E( "failed to release and deactivate power management assertion that prevents idle system sleep" );
		}
		self.idleSleepAssertionID = 0;

		status = IOPMAssertionRelease( self.displaySleepAssertionID );
		if( status != kIOReturnSuccess ) {
			CI_LOG_E( "failed to release and deactivate power management assertion that prevents idle display sleep" );
		}
		self.displaySleepAssertionID = 0;
	}
}

- (BOOL)isPowerManagementEnabled
{
	return self.idleSleepAssertionID != 0 && self.displaySleepAssertionID != 0;
}

- (float)getFrameRate
{
	return mFrameRate;
}

- (void)setFrameRate:(float)frameRate
{
	mFrameRate = frameRate;
	mFrameRateEnabled = YES;
	[self startAnimationTimer];
}

- (void)disableFrameRate
{
	mFrameRateEnabled = NO;
	[self startAnimationTimer];
}

- (bool)isFrameRateEnabled
{
	return mFrameRateEnabled;
}

- (void)windowDidResignKey:(NSNotification *)notification
{
//TODO	[cinderView applicationWillResignActive:notification];
}

- (void)touchesEndedWithEvent:(NSEvent *)event
{
}

- (void)touchesCancelledWithEvent:(NSEvent *)event
{
}

#pragma mark -
#pragma mark CALLBACKS
#pragma mark -

@end

@implementation WacomTouchableWindow

-(void) FingerDataAvailable:(WacomMTFingerCollection *)packet data:(void *)userData
{
	[_baseWindow FingerDataAvailable:packet];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////////////////////////
// WindowImplBasicCocoa
@implementation WindowImplBasicCocoa

- (void)dealloc
{
	[mCinderView release];
	if( mTitle )
		[mTitle release];

	[super dealloc];
}

- (BOOL)isFullScreen
{
	return [mCinderView isFullScreen];
}

- (void)setFullScreen:(BOOL)fullScreen options:(const FullScreenOptions *)options;
{
	if( fullScreen == [mCinderView isFullScreen] )
		return;

	[mCinderView setFullScreen:fullScreen options:options];

	if( fullScreen ) {
		// ???: necessary? won't this be set in resize?
		NSRect bounds = [mCinderView bounds];
		mSize.x = static_cast<int>( bounds.size.width );
		mSize.y = static_cast<int>( bounds.size.height );	
	}
	else {
		[mWin becomeKeyWindow];
		[mWin makeFirstResponder:mCinderView];
	}
}

- (cinder::ivec2)getSize
{
	return mSize;
}

- (void)setSize:(cinder::ivec2)size
{
	// this compensates for the Mac wanting to resize from the lower-left corner
	ivec2 sizeDelta = size - mSize;
	NSRect r = [mWin frame];
	r.size.width += sizeDelta.x;
	r.size.height += sizeDelta.y;
	r.origin.y -= sizeDelta.y;
	[mWin setFrame:r display:YES];

	mSize.x = (int)mCinderView.frame.size.width;
	mSize.y = (int)mCinderView.frame.size.height;
}

- (cinder::ivec2)getPos
{
	return mPos;
}

- (float)getContentScale
{
	return [mCinderView contentScaleFactor];
}

- (void)setPos:(cinder::ivec2)pos
{
	NSPoint p;
	p.x = pos.x;
	p.y = cinder::Display::getMainDisplay()->getHeight() - pos.y;
	mPos = pos;
	NSRect currentContentRect = [mWin contentRectForFrameRect:[mWin frame]];
	NSRect targetContentRect = NSMakeRect( p.x, p.y - currentContentRect.size.height, currentContentRect.size.width, currentContentRect.size.height);
	NSRect targetFrameRect = [mWin frameRectForContentRect:targetContentRect];
	[mWin setFrameOrigin:targetFrameRect.origin];
}

- (void)close
{
	[mWin close];
}

- (NSString *)getTitle
{
	return mTitle;
}

- (void)setTitle:(NSString *)title
{
	if( mTitle )
		[mTitle release];

	mTitle = [title copy]; // title is cached because sometimes we need to restore it after changing window border styles
	[mWin setTitle:title];
}

- (BOOL)isBorderless
{
	return mBorderless;
}

- (void)setBorderless:(BOOL)borderless
{
	if( mBorderless == borderless )
		return;

	mBorderless = borderless;

	NSUInteger styleMask;
	if( mBorderless )
		styleMask = ( mResizable ) ? ( NSBorderlessWindowMask | NSResizableWindowMask ) : NSBorderlessWindowMask;
	else if( mResizable )
		styleMask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
	else
		styleMask = NSTitledWindowMask;

	[mWin setStyleMask:styleMask];
	[mWin makeFirstResponder:mCinderView];
	[mWin makeKeyWindow];
	[mWin makeMainWindow];
	[mWin setHasShadow:( ! mBorderless )];

	// kludge: the titlebar buttons don't want to re-appear after coming back from borderless mode unless we resize the window.
	if( ! mBorderless && mResizable ) {
		ivec2 currentSize = mSize;
		[self setSize:currentSize + ivec2( 0, 1 )];
		[self setSize:currentSize];

		// restore title, which also seems to disappear after coming back from borderless
		if( mTitle )
			[mWin setTitle:mTitle];
	}
}

- (bool)isAlwaysOnTop
{
	return mAlwaysOnTop;
}

- (void)setAlwaysOnTop:(bool)alwaysOnTop
{
	if( mAlwaysOnTop != alwaysOnTop ) {
		mAlwaysOnTop = alwaysOnTop;
		[mWin setLevel:(mAlwaysOnTop)?NSScreenSaverWindowLevel:NSNormalWindowLevel];
	}
}

- (void)hide
{
	if( ! mHidden ) {
		[mWin orderOut:self];
		mHidden = YES;
	}	
}

- (void)show
{
	if( mHidden ) {
		[mWin makeKeyAndOrderFront:self];
		mHidden = NO;
	}
}

- (BOOL)isHidden
{
	return mHidden;
}

- (cinder::DisplayRef)getDisplay
{
	return mDisplay;
}

- (RendererRef)getRenderer
{
	if( mCinderView )
		return [mCinderView getRenderer];
	else
		return RendererRef();
}

- (void *)getNative
{
	return mCinderView;
}

- (void)windowDidBecomeMainNotification:(NSNotification *)notification
{
	mWindowRef->getRenderer()->makeCurrentContext( true );
}

- (void)windowMovedNotification:(NSNotification *)notification
{
	NSWindow *window = [notification object];

	NSRect frame = [mWin frame];
	NSRect content = [mWin contentRectForFrameRect:frame];
	mPos = ivec2( content.origin.x, mWin.screen.frame.size.height - frame.origin.y - content.size.height );
	[mAppImpl setActiveWindow:self];

	// This appears to be NULL in some scenarios
	NSScreen *screen = [window screen];
	if( screen ) {
		NSDictionary *dict = [screen deviceDescription];
		CGDirectDisplayID displayID = (CGDirectDisplayID)[[dict objectForKey:@"NSScreenNumber"] intValue];
		if( displayID != (std::dynamic_pointer_cast<cinder::DisplayMac>( mDisplay )->getCgDirectDisplayId()) ) {
			auto newDisplay = cinder::app::PlatformCocoa::get()->findFromCgDirectDisplayId( displayID );
			if( newDisplay ) {
				mDisplay = newDisplay;
				if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
					mWindowRef->emitDisplayChange();
				}
			}
		}
	}
	
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		mWindowRef->emitMove();
	}
}

- (void)windowWillCloseNotification:(NSNotification *)notification
{
	// if this is the last window and we're set to terminate on last window, invalidate the timer
	if( [mAppImpl getNumWindows] == 1 && mAppImpl->mQuitOnLastWindowClosed ) {
		[mAppImpl->mAnimationTimer invalidate];
		mAppImpl->mAnimationTimer = nil;
	}

	[mAppImpl setActiveWindow:self];
	// emit the signal before we start destroying stuff
	mWindowRef->emitClose();
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[mAppImpl releaseWindow:self];
}

// CinderViewDelegate Methods
- (void)resize
{
	NSSize nsSize = [mCinderView frame].size;
	mSize = cinder::ivec2( nsSize.width, nsSize.height );

	NSRect frame = [mWin frame];
	NSRect content = [mWin contentRectForFrameRect:frame];
	
	ivec2 prevPos = mPos;	
	mPos = ivec2( content.origin.x, mWin.screen.frame.size.height - frame.origin.y - content.size.height );

	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		mWindowRef->emitResize();
		
		// If the resize happened from top left, also signal that the Window moved.
		if( prevPos != mPos )
			mWindowRef->emitMove();
	}
}

- (void)draw
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		mWindowRef->emitDraw();
	}
}

- (void)mouseDown:(MouseEvent *)event
{
	mIsMouseDown = true;
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitMouseDown( event );
	}
}

- (void)mouseDrag:(MouseEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitMouseDrag( event );
	}
}

- (void)mouseUp:(MouseEvent *)event
{
	mIsMouseDown = false;
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitMouseUp( event );
	}
}

- (void)mouseMove:(MouseEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitMouseMove( event );
	}
}

- (void)mouseWheel:(MouseEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitMouseWheel( event );
	}
}

- (void)keyDown:(KeyEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitKeyDown( event );
	}
}

- (void)keyUp:(KeyEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitKeyUp( event );
	}
}

- (void)touchesBegan:(TouchEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitTouchesBegan( event );
	}
}

- (void)touchesMoved:(TouchEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitTouchesMoved( event );
	}
}

- (void)touchesEnded:(TouchEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitTouchesEnded( event );
	}
}

- (const std::vector<TouchEvent::Touch> &)getActiveTouches
{
	return [mCinderView getActiveTouches];
}

- (void)fileDrop:(FileDropEvent *)event
{
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitFileDrop( event );
	}
}

- (void)tabletProximity:(cinder::app::TabletProximityEvent *)event
{
	mWacomPenInProximity = event->isEnteringProximity();
	if( ! ((PlatformCocoa*)Platform::get())->isInsideModalLoop() ) {
		[mAppImpl setActiveWindow:self];
		event->setWindow( mWindowRef );
		mWindowRef->emitTabletProximity( event );
	}
}

- (void)FingerDataAvailable:(WacomMTFingerCollection *)packet
{
	if (packet)
	{
		//std::cout << "Finger data available" << std::endl;
		//std::cout << "DeviceID: " << packet->DeviceID << " Version: " << packet->Version << " FrameNumber: " << packet->FrameNumber << " Count: " << packet->FingerCount << std::endl;
		
		WacomMTFinger* fingers = packet->Fingers;
		std::vector<TouchEvent::Touch> began;
		std::vector<TouchEvent::Touch> moved;
		std::vector<TouchEvent::Touch> ended;
		
		WacomMTCapability capabilities;
		WacomMTGetDeviceCapabilities(packet->DeviceID, &capabilities);
		
		float windowX = mWin.frame.origin.x - mWin.screen.frame.origin.x;
		float windowY = mWin.frame.origin.y - mWin.screen.frame.origin.y;
		float windowBorder = mWin.frame.size.height - mCinderView.frame.size.height;
		float borderTop = mWin.screen.frame.size.height - windowY - mWin.frame.size.height + windowBorder;
		
		
		if (fingers)
		{
			for (uint32_t i = 0; i < packet->FingerCount; ++i)
			{
				WacomMTFinger& finger = fingers[i];
				
				int fingerId = finger.FingerID;
				float rawX = finger.X;
				float rawY = finger.Y;
				float width = finger.Width;
				float height = finger.Height;
				unsigned short sensitivity = finger.Sensitivity;
				float orientation = finger.Orientation;
				bool confidence = finger.Confidence;
				WacomMTFingerState state = finger.TouchState;
				
				// Very simple logic for rejecting non confident touches.
				// Note that confidence always goes to 0 when pen and touch is used simultaneously.
				bool isEndingTouch = (state == WMTFingerStateUp || state == WMTFingerStateNone);
				if (!confidence && (mIsMouseDown || !mWacomPenInProximity) && !isEndingTouch) {
					continue;
				}
				
				float screenXFromLeft = rawX - capabilities.LogicalOriginX;
				float screenYFromTop = rawY - capabilities.LogicalOriginY;
				float x = screenXFromLeft - windowX;
				float y = screenYFromTop - borderTop;
				
				
				//std::cout << "Finger #" << i << ":" << std::endl;
				//std::cout << "Id: " << fingerId << " rawX: " << rawX << " rawY: " << rawY << " screenXFromLeft: " << screenXFromLeft << " screenYFromTop: " << screenYFromTop << " x: " << x << " y: " << y << " width: " << width << " height: " << height << " sensitivity: " << sensitivity << " orientation: " << orientation << " confidence: " << confidence << " state: " << state << std::endl;
				
				TouchEvent::Touch touch(glm::vec2(x, y), glm::vec2(x, y), static_cast<uint32_t>(fingerId), 0.0, NULL, TouchEvent::Touch::Type::Finger, 1.0f, 0.0f, 0.0f);
				
				//NSLog(@"%@", NSStringFromRect(mWin.frame));
				//NSLog(@"%@", NSStringFromRect(mCinderView.frame));
				//NSLog(@"%@", NSStringFromRect(mWin.screen.frame));
				//std::cout << "LogicalOriginX: " << capabilities.LogicalOriginX << " LogicalOriginY: " << capabilities.LogicalOriginY << " LogicalWidth: " << capabilities.LogicalWidth << " LogicalHeight: " << capabilities.LogicalHeight << std::endl;
				
				switch (state) {
					case WMTFingerStateDown:
						began.push_back(touch);
						break;
					case WMTFingerStateHold:
						moved.push_back(touch);
						break;
					case WMTFingerStateUp:
					case WMTFingerStateNone:
						ended.push_back(touch);
						break;
					default:
						break;
				}
 			}
		}
		if (!began.empty()) {
			TouchEvent touchEvent(mWindowRef, began);
			[self touchesBegan:&touchEvent];
		}
		if (!moved.empty()) {
			TouchEvent touchEvent(mWindowRef, moved);
			[self touchesMoved:&touchEvent];
		}
		if (!ended.empty()) {
			TouchEvent touchEvent(mWindowRef, ended);
			[self touchesEnded:&touchEvent];
		}
	}
}

- (app::WindowRef)getWindowRef
{
	return mWindowRef;
}

//////////////////////////////////////////////////////////////////////////////
// deviceDidAttachWithCapabilities:
//
// Purpose:		Called by the touch API callback
//
- (void) deviceDidAttachWithCapabilities:(WacomMTCapability)deviceInfo
{
	//WacomMTError err = WacomMTRegisterFingerReadID(deviceInfo.DeviceID, WMTProcessingModeNone, self->mWin, 1);
	//if (err != WMTErrorSuccess) {
	//	CI_LOG_E("Registering Wacom finger callback failed with error code " << err);
	//}
	
	WacomMTError err = WacomMTRegisterFingerReadCallback(deviceInfo.DeviceID, NULL, WMTProcessingModeNone, WacomFingerCallback, self->mWin);
	if (err != WMTErrorSuccess) {
		CI_LOG_E("Registering Wacom finger callback failed with error code " << err);
	}
}

//////////////////////////////////////////////////////////////////////////////
// deviceDidDetach:
//
// Purpose:		Called by the touch API callback.
//
- (void) deviceDidDetach:(int)deviceID
{
	//WacomMTUnRegisterFingerReadID(self->mWin);
	
	WacomMTUnRegisterFingerReadCallback(deviceID, NULL, WMTProcessingModeNone, NULL);
}

//////////////////////////////////////////////////////////////////////////////

+ (WindowImplBasicCocoa *)instantiate:(Window::Format)winFormat withAppImpl:(AppImplMac *)appImpl
{
	WindowImplBasicCocoa *winImpl = [[WindowImplBasicCocoa alloc] init];

	winImpl->mAppImpl = appImpl;
	winImpl->mWindowRef = app::Window::privateCreate__( winImpl, winImpl->mAppImpl->mApp );
	winImpl->mDisplay = winFormat.getDisplay();
	winImpl->mHidden = NO;
	winImpl->mResizable = winFormat.isResizable();
	winImpl->mBorderless = winFormat.isBorderless();
	winImpl->mAlwaysOnTop = winFormat.isAlwaysOnTop();
	winImpl->mWacomPenInProximity = false;

	if( ! winImpl->mDisplay )
		winImpl->mDisplay = Display::getMainDisplay();

	int offsetX, offsetY;
	if( ! winFormat.isPosSpecified() ) {
		offsetX = ( winImpl->mDisplay->getWidth() - winFormat.getSize().x ) / 2;
		offsetY = ( winImpl->mDisplay->getHeight() - winFormat.getSize().y ) / 2;
	}
	else {
		offsetX = winFormat.getPos().x;
		offsetY = cinder::Display::getMainDisplay()->getHeight() - winFormat.getPos().y - winFormat.getSize().y;
	}

	NSRect winRect = NSMakeRect( offsetX, offsetY, winFormat.getSize().x, winFormat.getSize().y );
	unsigned int styleMask;
	
	if( winImpl->mBorderless )
		styleMask = ( winImpl->mResizable ) ? ( NSBorderlessWindowMask | NSResizableWindowMask ) : ( NSBorderlessWindowMask );
	else if( winImpl->mResizable )
		styleMask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
	else
		styleMask = NSTitledWindowMask;

	winImpl->mWin = [[WacomTouchableWindow alloc] initWithContentRect:winRect
													styleMask:styleMask
													  backing:NSBackingStoreBuffered
														defer:NO
													   screen:std::dynamic_pointer_cast<cinder::DisplayMac>( winImpl->mDisplay )->getNsScreen()];
	winImpl->mWin.baseWindow = winImpl;

	NSRect contentRect = [winImpl->mWin contentRectForFrameRect:[winImpl->mWin frame]];
	winImpl->mSize.x = (int)contentRect.size.width;
	winImpl->mSize.y = (int)contentRect.size.height;
	winImpl->mPos = ivec2( contentRect.origin.x, Display::getMainDisplay()->getHeight() - [winImpl->mWin frame].origin.y - contentRect.size.height );

	[winImpl->mWin setLevel:( winImpl->mAlwaysOnTop ? NSScreenSaverWindowLevel : NSNormalWindowLevel )];

	if( ! winFormat.getTitle().empty() )
		[winImpl setTitle:[NSString stringWithUTF8String:winFormat.getTitle().c_str()]];

	if( winFormat.isFullScreenButtonEnabled() )
		[winImpl->mWin setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

	if( ! winFormat.getRenderer() )
		winFormat.setRenderer( appImpl->mApp->getDefaultRenderer()->clone() );

	// for some renderers, ok really just GL, we want an existing renderer so we can steal its context to share with. If this comes back with NULL that's fine - we're first
	app::RendererRef sharedRenderer = [appImpl findSharedRenderer:winFormat.getRenderer()];
	
	app::RendererRef renderer = winFormat.getRenderer();
	NSRect viewFrame = NSMakeRect( 0, 0, winImpl->mSize.x, winImpl->mSize.y );
	winImpl->mCinderView = [[CinderViewMac alloc] initWithFrame:viewFrame renderer:renderer sharedRenderer:sharedRenderer
															appReceivesEvents:YES
															highDensityDisplay:appImpl->mApp->isHighDensityDisplayEnabled()
															enableMultiTouch:appImpl->mApp->isMultiTouchEnabled()];

	[winImpl->mWin setDelegate:self];
	// add CinderView as subview of window's content view to avoid NSWindow warning: https://github.com/cinder/Cinder/issues/584
	[winImpl->mWin.contentView addSubview:winImpl->mCinderView];
	winImpl->mCinderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	[winImpl->mWin makeKeyAndOrderFront:nil];
	// after showing the window, the size may have changed (see NSWindow::constrainFrameRect) so we need to update our internal variable
	winImpl->mSize.x = (int)winImpl->mCinderView.frame.size.width;
	winImpl->mSize.y = (int)winImpl->mCinderView.frame.size.height;
	[winImpl->mWin setInitialFirstResponder:winImpl->mCinderView];
	[winImpl->mWin setAcceptsMouseMovedEvents:YES];
	[winImpl->mWin setOpaque:YES];
	[[NSNotificationCenter defaultCenter] addObserver:winImpl selector:@selector(windowDidBecomeMainNotification:) name:NSWindowDidBecomeMainNotification object:winImpl->mWin];
	[[NSNotificationCenter defaultCenter] addObserver:winImpl selector:@selector(windowMovedNotification:) name:NSWindowDidMoveNotification object:winImpl->mWin];
	[[NSNotificationCenter defaultCenter] addObserver:winImpl selector:@selector(windowWillCloseNotification:) name:NSWindowWillCloseNotification object:winImpl->mWin];
	[winImpl->mCinderView setNeedsDisplay:YES];
	[winImpl->mCinderView setDelegate:winImpl];

	// make this window the active window
	appImpl->mActiveWindow = winImpl;
	
	// The WacomMultiTouch framework is weak-linked. That means the application
	// can load if the framework is not present. However, we must take care not
	// to call framework functions if the framework wasn't loaded.
	//
	// You can set WacomMultiTouch.framework to be weak-linked in your own
	// project by opening the Info window for your target, going to the General
	// tab. In the Linked Libraries list, change the Type of
	// WacomMultiTouch.framework to "Weak".
	
	
	if(WacomMTInitialize != NULL)
	{
		WacomMTError err = WacomMTInitialize(WACOM_MULTI_TOUCH_API_VERSION);
		if(err == WMTErrorSuccess)
		{
			WacomMTRegisterAttachCallback(WacomAttachCallback, winImpl);
			WacomMTRegisterDetachCallback(WacomDetachCallback, winImpl);
			
			int   deviceIDs[30]  = {};
			int   deviceCount    = 0;
			int   counter        = 0;
			
			// Ask the Wacom API for all connected touch API-capable devices.
			// Pass a comfortably large buffer so you don't have to call this method
			// twice.
			deviceCount = WacomMTGetAttachedDeviceIDs(deviceIDs, sizeof(deviceIDs));
			
			if(deviceCount > 30)
			{
				// With a number as big as 30, this will never actually happen.
				NSLog(@"More tablets connected than would fit in the supplied buffer. Will need to reallocate buffer!");
			}
			else
			{
				// Repopulate with current devices
				for(counter = 0; counter < deviceCount; counter++)
				{
					int                  deviceID       = deviceIDs[counter];
					WacomMTCapability    capabilities   = {};
					NSMutableDictionary  *deviceRecord  = [[NSMutableDictionary alloc] init];
					
					WacomMTGetDeviceCapabilities(deviceID, &capabilities);
					
					[deviceRecord setObject:[NSNumber numberWithInt:deviceID] forKey:@"deviceID"];
					[deviceRecord setObject:[NSNumber numberWithInt:capabilities.FingerMax] forKey:@"fingerCount"];
					[deviceRecord setObject:[NSString stringWithFormat:@"%d x %d", capabilities.ReportedSizeX, capabilities.ReportedSizeY] forKey:@"scanSize"];
					
					switch(capabilities.Type)
					{
						case WMTDeviceTypeIntegrated:
							[deviceRecord setObject:@"Integrated" forKey:@"type"];
							break;
							
						case WMTDeviceTypeOpaque:
							[deviceRecord setObject:@"Opaque" forKey:@"type"];
							break;
					}
					
					[deviceRecord release];
				}
			}
		}
		else
		{
			CI_LOG_E("Failed to initialize Wacom Multi Touch API");
		}
	}

	return [winImpl autorelease];
}

@end

#pragma mark -
#pragma mark WACOM TOUCH API C-FUNCTION CALLBACKS
#pragma mark -

//////////////////////////////////////////////////////////////////////////////
// WacomAttachCallback()
//
// Purpose:		A new device was connected.
//
void WacomAttachCallback(WacomMTCapability deviceInfo, void *userInfo)
{
	WindowImplBasicCocoa *controller = (WindowImplBasicCocoa *)userInfo;
	[controller deviceDidAttachWithCapabilities:deviceInfo];
}



//////////////////////////////////////////////////////////////////////////////
// WacomDetachCallback()
//
// Purpose:		A device was unplugged.
//
void WacomDetachCallback(int deviceID, void *userInfo)
{
	WindowImplBasicCocoa *controller = (WindowImplBasicCocoa *)userInfo;
	[controller deviceDidDetach:deviceID];
}

int WacomFingerCallback(WacomMTFingerCollection *fingerPacket, void *userData)
{
	WacomTouchableWindow *window = (WacomTouchableWindow *)userData;
	[window FingerDataAvailable:fingerPacket data:NULL];
	return 0;
}
