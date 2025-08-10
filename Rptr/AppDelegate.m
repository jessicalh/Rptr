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
    // Diagnostic: Track app launch time
    CFAbsoluteTime launchStartTime = CFAbsoluteTimeGetCurrent();
    
    // Override point for customization after application launch.
    RLog(RptrLogAreaInfo, @"AppDelegate: Application did finish launching");
    RLog(RptrLogAreaInfo, @"AppDelegate: Launch options: %@", launchOptions);
    
    // Keyboard preloading moved to ViewController to avoid startup flash
    
    // CRITICAL: Force landscape orientation at app launch
    // This ensures the app starts in landscape mode regardless of device orientation
    if (@available(iOS 16.0, *)) {
        // Use completion handler instead of arbitrary delay
        NSArray *connectedScenes = [[[UIApplication sharedApplication] connectedScenes] allObjects];
        for (UIScene *scene in connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
                geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;
                [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error) {
                            RLogError(@"Failed to set initial orientation: %@", error.localizedDescription);
                        } else {
                            RLog(RptrLogAreaInfo, @"Successfully set landscape orientation");
                        }
                    });
                }];
            }
        }
    
    } else {
        // For iOS < 16, try to force orientation
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeRight) forKey:@"orientation"];
    }
    
    // Check launch duration at the end of setup
    CFAbsoluteTime launchDuration = CFAbsoluteTimeGetCurrent() - launchStartTime;
    if (launchDuration > 0.5) {
        RLog(RptrLogAreaANR, @"App launch took %.3f seconds", launchDuration);
        if (launchDuration > 3.0) {
            RLog(RptrLogAreaError, @"WARNING: Potential ANR - launch exceeded 3 seconds");
        }
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
