//
//  PermissionManager.h
//  Rptr
//
//  Centralized permission management for camera, microphone, and location
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <Photos/Photos.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PermissionType) {
    PermissionTypeCamera,
    PermissionTypeMicrophone,
    PermissionTypeLocation,
    PermissionTypePhotoLibrary
};

typedef NS_ENUM(NSInteger, PermissionStatus) {
    PermissionStatusNotDetermined,
    PermissionStatusDenied,
    PermissionStatusAuthorized,
    PermissionStatusRestricted
};

typedef void (^PermissionCompletionHandler)(BOOL granted, NSError * _Nullable error);
typedef void (^MultiplePermissionsCompletionHandler)(NSDictionary<NSNumber *, NSNumber *> *results);

@interface PermissionManager : NSObject

+ (instancetype)sharedManager;

// Check permission status
- (PermissionStatus)statusForPermission:(PermissionType)permission;

// Request single permission
- (void)requestPermission:(PermissionType)permission completion:(PermissionCompletionHandler)completion;

// Request multiple permissions
- (void)requestPermissions:(NSArray<NSNumber *> *)permissions completion:(MultiplePermissionsCompletionHandler)completion;

// Check if all required permissions are granted
- (BOOL)hasAllRequiredPermissions;

// Get human-readable description for permission
- (NSString *)descriptionForPermission:(PermissionType)permission;

// Show settings alert for denied permissions
- (void)showSettingsAlertForPermission:(PermissionType)permission fromViewController:(UIViewController *)viewController;

// Show settings alert for multiple denied permissions
- (void)showSettingsAlertForDeniedPermissionsFromViewController:(UIViewController *)viewController;

@end

NS_ASSUME_NONNULL_END