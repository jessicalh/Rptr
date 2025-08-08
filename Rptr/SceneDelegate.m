//
//  SceneDelegate.m
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import "SceneDelegate.h"
#import "RptrLogger.h"
#import "AppDelegate.h"
#import "ViewController.h"

@interface SceneDelegate ()

@end

@implementation SceneDelegate


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
    // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
    // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
    
    RLog(RptrLogAreaUI, @"SceneDelegate: Scene will connect to session");
    
    // Create window manually to ensure full screen
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = [UIColor blackColor];
        
        // CRITICAL: Disable window-level orientation adjustments
        if (@available(iOS 16.0, *)) {
            // Lock the window to landscape right orientation
            UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
            geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;
            [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                if (error) {
                    RLogError(@"Failed to lock window orientation: %@", error.localizedDescription);
                }
            }];
        }
        
        // Create view controller normally
        ViewController *rootViewController = [[ViewController alloc] init];
        self.window.rootViewController = rootViewController;
        
        // Log window hierarchy
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Window frame after creation: %@", NSStringFromCGRect(self.window.frame));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Window bounds: %@", NSStringFromCGRect(self.window.bounds));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"WindowScene bounds: %@", NSStringFromCGRect(windowScene.coordinateSpace.bounds));
        
        [self.window makeKeyAndVisible];
        
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Created window with frame: %@", NSStringFromCGRect(self.window.frame));
        
        // Force window to be full screen
        self.window.windowLevel = UIWindowLevelNormal;
        
        // Remove any constraints that might be affecting the window
        self.window.translatesAutoresizingMaskIntoConstraints = YES;
        rootViewController.view.translatesAutoresizingMaskIntoConstraints = YES;
        
        // Force landscape right immediately on window creation
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
            geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;
            [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                if (error) {
                    RLogError(@"Failed to set initial landscape orientation: %@", error.localizedDescription);
                }
            }];
        }
    }
    
    // Check if we need to force landscape orientation
    if (@available(iOS 16.0, *)) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            
            // Only force orientation if not already in landscape
            if (windowScene.interfaceOrientation != UIInterfaceOrientationLandscapeLeft &&
                windowScene.interfaceOrientation != UIInterfaceOrientationLandscapeRight) {
                
                UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
                geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;  // Lock to single orientation
                
                [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                    RLogError(@"SceneDelegate: Failed to set landscape orientation: %@", error.localizedDescription);
                }];
            } else {
                RLogDebug(@"SceneDelegate: Already in landscape orientation (%ld)", (long)windowScene.interfaceOrientation);
            }
        }
    }
    
    // Debug logging to verify window setup
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.window) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                RLog(RptrLogAreaUI | RptrLogAreaDebug, @"SceneDelegate: Window scene bounds: %@", NSStringFromCGRect(windowScene.coordinateSpace.bounds));
                
                // Force window to fill screen
                self.window.frame = windowScene.coordinateSpace.bounds;
                if (self.window.rootViewController) {
                    self.window.rootViewController.view.frame = self.window.bounds;
                }
                
                // Log interface orientation
                RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Interface orientation: %ld", (long)windowScene.interfaceOrientation);
            }
            
            RLog(RptrLogAreaUI | RptrLogAreaDebug, @"SceneDelegate: Window exists - Frame: %@", NSStringFromCGRect(self.window.frame));
            RLog(RptrLogAreaUI | RptrLogAreaDebug, @"SceneDelegate: Root view controller: %@", self.window.rootViewController);
            RLog(RptrLogAreaUI | RptrLogAreaDebug, @"SceneDelegate: Window is key: %@", self.window.isKeyWindow ? @"YES" : @"NO");
            RLog(RptrLogAreaUI | RptrLogAreaDebug, @"SceneDelegate: Window is visible: %@", self.window.isHidden ? @"NO" : @"YES");
        } else {
            RLog(RptrLogAreaUI | RptrLogAreaError, @"SceneDelegate: ERROR - Window is nil!");
        }
    });
}


- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.

    // Save changes in the application's managed object context when the application transitions to the background.
    // Core Data removed - no saving needed
}


@end
