//
//  AppDelegate.m
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import "AppDelegate.h"
#import "RptrLogger.h"

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    RLog(RptrLogAreaUI, @"AppDelegate: Application did finish launching");
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"AppDelegate: Launch options: %@", launchOptions);
    
    // Keyboard preloading moved to ViewController to avoid startup flash
    
    // CRITICAL: Force landscape orientation at app launch
    // This ensures the app starts in landscape mode regardless of device orientation
    if (@available(iOS 16.0, *)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSArray *connectedScenes = [[[UIApplication sharedApplication] connectedScenes] allObjects];
            for (UIScene *scene in connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
                    geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;
                    [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                        if (error) {
                            RLogError(@"Failed to set initial orientation: %@", error.localizedDescription);
                        }
                    }];
                }
            }
        });
    } else {
        // For iOS < 16, try to force orientation
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeRight) forKey:@"orientation"];
    }
    
    return YES;
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    // Lock to landscape right only - no rotation between landscape orientations
    return UIInterfaceOrientationMaskLandscapeRight;
}


@end
