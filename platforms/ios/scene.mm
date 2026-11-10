
// Appended to LÖVE's src/common/ios.mm by build.sh.
// The iOS 27 SDK won't launch an app without the UIScene lifecycle, and SDL 2.28 has none:
// this delegate puts SDL's windows in the app's scene and forwards scene events to SDL's app delegate.
#ifdef LOVE_IOS
#import <objc/runtime.h>
#import <objc/message.h>

static NSHashTable<UIWindow *> *bcPendingWindows;

static UIWindowScene *bcScene()
{
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		if ([scene isKindOfClass:UIWindowScene.class])
			return (UIWindowScene *)scene;
	return nil;
}

@implementation UIWindow (BCScene)

+ (void)load
{
	method_exchangeImplementations(class_getInstanceMethod(self, @selector(makeKeyAndVisible)),
	                               class_getInstanceMethod(self, @selector(bc_makeKeyAndVisible)));
}

// SDL shows its windows before the scene connects; those wait for it.
- (void)bc_makeKeyAndVisible
{
	if (!self.windowScene)
	{
		UIWindowScene *scene = bcScene();
		if (!scene)
		{
			if (!bcPendingWindows)
				bcPendingWindows = [NSHashTable weakObjectsHashTable];
			[bcPendingWindows addObject:self];
			return;
		}
		self.windowScene = scene;
	}
	[self bc_makeKeyAndVisible];
}

@end

@interface BCSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation BCSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
	for (UIWindow *window in bcPendingWindows.allObjects)
	{
		window.windowScene = (UIWindowScene *)scene;
		[window makeKeyAndVisible];
	}
	[bcPendingWindows removeAllObjects];
}

- (void)forward:(SEL)selector
{
	UIApplication *app = UIApplication.sharedApplication;
	if ([app.delegate respondsToSelector:selector])
		((void (*)(id, SEL, UIApplication *))objc_msgSend)(app.delegate, selector, app);
}

- (void)sceneDidBecomeActive:(UIScene *)scene { [self forward:@selector(applicationDidBecomeActive:)]; }
- (void)sceneWillResignActive:(UIScene *)scene { [self forward:@selector(applicationWillResignActive:)]; }
- (void)sceneWillEnterForeground:(UIScene *)scene { [self forward:@selector(applicationWillEnterForeground:)]; }
- (void)sceneDidEnterBackground:(UIScene *)scene { [self forward:@selector(applicationDidEnterBackground:)]; }

@end

#endif // LOVE_IOS
