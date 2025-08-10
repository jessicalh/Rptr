//
//  main.m
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "RptrApplication.h"

int main(int argc, char * argv[]) {
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    // Use our custom UIApplication class to prevent menu/storyboard crashes
    return UIApplicationMain(argc, argv, NSStringFromClass([RptrApplication class]), appDelegateClassName);
}
