//
//  CameraOrientationDebugger.m
//  Rptr
//
//  Debug helper to find correct camera orientation
//

#import "CameraOrientationDebugger.h"
#import "RptrLogger.h"
#import <UIKit/UIKit.h>

@implementation CameraOrientationDebugger

+ (void)debugCameraOrientation:(AVCaptureConnection *)connection 
                  previewLayer:(AVCaptureVideoPreviewLayer *)previewLayer {
    
    RLogVideo(@"=== CAMERA ORIENTATION DEBUG ===");
    
    // Device orientation
    UIDeviceOrientation deviceOrientation = [[UIDevice currentDevice] orientation];
    NSString *deviceOrientationStr = [self stringForDeviceOrientation:deviceOrientation];
    RLogVideo(@"Device orientation: %@ (%ld)", deviceOrientationStr, (long)deviceOrientation);
    
    // Interface orientation
    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *windowScene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
        interfaceOrientation = windowScene.interfaceOrientation;
    }
    NSString *interfaceOrientationStr = [self stringForInterfaceOrientation:interfaceOrientation];
    RLogVideo(@"Interface orientation: %@ (%ld)", interfaceOrientationStr, (long)interfaceOrientation);
    
    // Current connection settings
    if (@available(iOS 17.0, *)) {
        RLogVideo(@"Current rotation angle: %.0f degrees", connection.videoRotationAngle);
        
        // Test all possible angles
        RLogVideo(@"Testing supported rotation angles:");
        for (CGFloat angle = 0; angle <= 270; angle += 90) {
            BOOL supported = [connection isVideoRotationAngleSupported:angle];
            RLogVideo(@"  %.0f degrees: %@", angle, supported ? @"SUPPORTED" : @"NOT SUPPORTED");
        }
    }
    
    // Preview layer info
    RLogVideo(@"Preview layer frame: %@", NSStringFromCGRect(previewLayer.frame));
    RLogVideo(@"Preview layer bounds: %@", NSStringFromCGRect(previewLayer.bounds));
    RLogVideo(@"Preview layer videoGravity: %@", previewLayer.videoGravity);
    
    RLogVideo(@"=== END DEBUG ===");
}

+ (CGFloat)findCorrectRotationAngle {
    // For landscape right app (home button on left):
    // The device is rotated 90° clockwise from portrait
    // But camera sensor is always in portrait orientation
    
    // Common configurations:
    // - Portrait app + Portrait device = 0°
    // - Landscape Right app + Landscape Right device = 0° or 90°
    // - Landscape Left app + Landscape Left device = 0° or 270°
    
    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *windowScene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
        interfaceOrientation = windowScene.interfaceOrientation;
    }
    
    switch (interfaceOrientation) {
        case UIInterfaceOrientationPortrait:
            return 0.0;
        case UIInterfaceOrientationPortraitUpsideDown:
            return 180.0;
        case UIInterfaceOrientationLandscapeLeft:
            // Device rotated 90° counter-clockwise
            return 270.0;
        case UIInterfaceOrientationLandscapeRight:
            // Device rotated 90° clockwise
            // Try different values: 0, 90, 180, 270
            return 90.0; // Most common for landscape right
        default:
            return 0.0;
    }
}

+ (NSString *)stringForDeviceOrientation:(UIDeviceOrientation)orientation {
    switch (orientation) {
        case UIDeviceOrientationPortrait:
            return @"Portrait";
        case UIDeviceOrientationPortraitUpsideDown:
            return @"PortraitUpsideDown";
        case UIDeviceOrientationLandscapeLeft:
            return @"LandscapeLeft (home button right)";
        case UIDeviceOrientationLandscapeRight:
            return @"LandscapeRight (home button left)";
        case UIDeviceOrientationFaceUp:
            return @"FaceUp";
        case UIDeviceOrientationFaceDown:
            return @"FaceDown";
        default:
            return @"Unknown";
    }
}

+ (NSString *)stringForInterfaceOrientation:(UIInterfaceOrientation)orientation {
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            return @"Portrait";
        case UIInterfaceOrientationPortraitUpsideDown:
            return @"PortraitUpsideDown";
        case UIInterfaceOrientationLandscapeLeft:
            return @"LandscapeLeft";
        case UIInterfaceOrientationLandscapeRight:
            return @"LandscapeRight";
        default:
            return @"Unknown";
    }
}

@end