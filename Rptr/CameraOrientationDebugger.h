//
//  CameraOrientationDebugger.h
//  Rptr
//
//  Debug helper to find correct camera orientation
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CameraOrientationDebugger : NSObject

+ (void)debugCameraOrientation:(AVCaptureConnection *)connection 
                  previewLayer:(AVCaptureVideoPreviewLayer *)previewLayer;

+ (CGFloat)findCorrectRotationAngle;

@end

NS_ASSUME_NONNULL_END