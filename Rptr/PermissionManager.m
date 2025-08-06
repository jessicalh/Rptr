//
//  PermissionManager.m
//  Rptr
//
//  Centralized permission management for camera, microphone, and location
//

#import "PermissionManager.h"
#import <UIKit/UIKit.h>

@interface PermissionManager () <CLLocationManagerDelegate>

@property (nonatomic, strong) CLLocationManager *locationManager;
@property (atomic, copy) PermissionCompletionHandler locationCompletionHandler;
@property (nonatomic, strong) dispatch_queue_t locationCallbackQueue;

@end

@implementation PermissionManager

+ (instancetype)sharedManager {
    static PermissionManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationCallbackQueue = dispatch_queue_create("com.rptr.permission.location", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Permission Status

- (PermissionStatus)statusForPermission:(PermissionType)permission {
    switch (permission) {
        case PermissionTypeCamera:
            return [self cameraPermissionStatus];
            
        case PermissionTypeMicrophone:
            return [self microphonePermissionStatus];
            
        case PermissionTypeLocation:
            return [self locationPermissionStatus];
            
        case PermissionTypePhotoLibrary:
            return [self photoLibraryPermissionStatus];
    }
}

- (PermissionStatus)cameraPermissionStatus {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return [self permissionStatusFromAVAuthorizationStatus:status];
}

- (PermissionStatus)microphonePermissionStatus {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    return [self permissionStatusFromAVAuthorizationStatus:status];
}

- (PermissionStatus)locationPermissionStatus {
    // Create a location manager instance to get the authorization status (iOS 14+)
    CLLocationManager *locationManager = [[CLLocationManager alloc] init];
    CLAuthorizationStatus status = locationManager.authorizationStatus;
    
    switch (status) {
        case kCLAuthorizationStatusNotDetermined:
            return PermissionStatusNotDetermined;
            
        case kCLAuthorizationStatusRestricted:
            return PermissionStatusRestricted;
            
        case kCLAuthorizationStatusDenied:
            return PermissionStatusDenied;
            
        case kCLAuthorizationStatusAuthorizedAlways:
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            return PermissionStatusAuthorized;
            
        default:
            return PermissionStatusNotDetermined;
    }
}

- (PermissionStatus)photoLibraryPermissionStatus {
    PHAuthorizationStatus status;
    
    if (@available(iOS 14, *)) {
        status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    } else {
        status = [PHPhotoLibrary authorizationStatus];
    }
    
    switch (status) {
        case PHAuthorizationStatusNotDetermined:
            return PermissionStatusNotDetermined;
            
        case PHAuthorizationStatusRestricted:
            return PermissionStatusRestricted;
            
        case PHAuthorizationStatusDenied:
            return PermissionStatusDenied;
            
        case PHAuthorizationStatusAuthorized:
        case PHAuthorizationStatusLimited:
            return PermissionStatusAuthorized;
            
        default:
            return PermissionStatusNotDetermined;
    }
}

- (PermissionStatus)permissionStatusFromAVAuthorizationStatus:(AVAuthorizationStatus)status {
    switch (status) {
        case AVAuthorizationStatusNotDetermined:
            return PermissionStatusNotDetermined;
            
        case AVAuthorizationStatusRestricted:
            return PermissionStatusRestricted;
            
        case AVAuthorizationStatusDenied:
            return PermissionStatusDenied;
            
        case AVAuthorizationStatusAuthorized:
            return PermissionStatusAuthorized;
            
        default:
            return PermissionStatusNotDetermined;
    }
}

#pragma mark - Request Permissions

- (void)requestPermission:(PermissionType)permission completion:(PermissionCompletionHandler)completion {
    PermissionStatus currentStatus = [self statusForPermission:permission];
    
    if (currentStatus == PermissionStatusAuthorized) {
        if (completion) {
            completion(YES, nil);
        }
        return;
    }
    
    if (currentStatus == PermissionStatusDenied || currentStatus == PermissionStatusRestricted) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"PermissionManager" 
                                                 code:1001 
                                             userInfo:@{NSLocalizedDescriptionKey: @"Permission denied by user"}];
            completion(NO, error);
        }
        return;
    }
    
    switch (permission) {
        case PermissionTypeCamera:
            [self requestCameraPermissionWithCompletion:completion];
            break;
            
        case PermissionTypeMicrophone:
            [self requestMicrophonePermissionWithCompletion:completion];
            break;
            
        case PermissionTypeLocation:
            [self requestLocationPermissionWithCompletion:completion];
            break;
            
        case PermissionTypePhotoLibrary:
            [self requestPhotoLibraryPermissionWithCompletion:completion];
            break;
    }
}

- (void)requestCameraPermissionWithCompletion:(PermissionCompletionHandler)completion {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(granted, nil);
            }
        });
    }];
}

- (void)requestMicrophonePermissionWithCompletion:(PermissionCompletionHandler)completion {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(granted, nil);
            }
        });
    }];
}

- (void)requestLocationPermissionWithCompletion:(PermissionCompletionHandler)completion {
    self.locationCompletionHandler = completion;
    [self.locationManager requestWhenInUseAuthorization];
}

- (void)requestPhotoLibraryPermissionWithCompletion:(PermissionCompletionHandler)completion {
    if (@available(iOS 14, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL granted = (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited);
                if (completion) {
                    completion(granted, nil);
                }
            });
        }];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL granted = (status == PHAuthorizationStatusAuthorized);
                if (completion) {
                    completion(granted, nil);
                }
            });
        }];
    }
}

- (void)requestPermissions:(NSArray<NSNumber *> *)permissions completion:(MultiplePermissionsCompletionHandler)completion {
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();
    
    for (NSNumber *permissionNumber in permissions) {
        PermissionType permission = [permissionNumber integerValue];
        
        dispatch_group_enter(group);
        [self requestPermission:permission completion:^(BOOL granted, NSError *error) {
            results[permissionNumber] = @(granted);
            dispatch_group_leave(group);
        }];
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (completion) {
            completion(results);
        }
    });
}

#pragma mark - Helper Methods

- (BOOL)hasAllRequiredPermissions {
    NSArray *requiredPermissions = @[
        @(PermissionTypeCamera),
        @(PermissionTypeMicrophone),
        @(PermissionTypeLocation)
    ];
    
    for (NSNumber *permissionNumber in requiredPermissions) {
        PermissionType permission = [permissionNumber integerValue];
        if ([self statusForPermission:permission] != PermissionStatusAuthorized) {
            return NO;
        }
    }
    
    return YES;
}

- (NSString *)descriptionForPermission:(PermissionType)permission {
    switch (permission) {
        case PermissionTypeCamera:
            return @"Camera";
            
        case PermissionTypeMicrophone:
            return @"Microphone";
            
        case PermissionTypeLocation:
            return @"Location";
            
        case PermissionTypePhotoLibrary:
            return @"Photo Library";
    }
}

- (void)showSettingsAlertForPermission:(PermissionType)permission fromViewController:(UIViewController *)viewController {
    NSString *permissionName = [self descriptionForPermission:permission];
    NSString *message = [NSString stringWithFormat:@"%@ access is required to use this feature. Please enable it in Settings.", permissionName];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Permission Required"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] 
                                           options:@{} 
                                 completionHandler:nil];
    }]];
    
    [viewController presentViewController:alert animated:YES completion:nil];
}

- (void)showSettingsAlertForDeniedPermissionsFromViewController:(UIViewController *)viewController {
    NSMutableArray *deniedPermissions = [NSMutableArray array];
    
    NSArray *allPermissions = @[
        @(PermissionTypeCamera),
        @(PermissionTypeMicrophone),
        @(PermissionTypeLocation)
    ];
    
    for (NSNumber *permissionNumber in allPermissions) {
        PermissionType permission = [permissionNumber integerValue];
        PermissionStatus status = [self statusForPermission:permission];
        
        if (status == PermissionStatusDenied || status == PermissionStatusRestricted) {
            [deniedPermissions addObject:[self descriptionForPermission:permission]];
        }
    }
    
    if (deniedPermissions.count == 0) {
        return;
    }
    
    NSString *permissionList = [deniedPermissions componentsJoinedByString:@", "];
    NSString *message = [NSString stringWithFormat:@"The following permissions are required: %@. Please enable them in Settings.", permissionList];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Permissions Required"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] 
                                           options:@{} 
                                 completionHandler:nil];
    }]];
    
    [viewController presentViewController:alert animated:YES completion:nil];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    dispatch_async(self.locationCallbackQueue, ^{
        PermissionCompletionHandler handler = self.locationCompletionHandler;
        if (handler) {
            self.locationCompletionHandler = nil;
            PermissionStatus status = [self locationPermissionStatus];
            BOOL granted = (status == PermissionStatusAuthorized);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(granted, nil);
            });
        }
    });
}

// iOS 13 and earlier - kept for backwards compatibility
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if (status != kCLAuthorizationStatusNotDetermined) {
        dispatch_async(self.locationCallbackQueue, ^{
            PermissionCompletionHandler handler = self.locationCompletionHandler;
            if (handler) {
                self.locationCompletionHandler = nil;
                BOOL granted = (status == kCLAuthorizationStatusAuthorizedAlways || 
                               status == kCLAuthorizationStatusAuthorizedWhenInUse);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(granted, nil);
                });
            }
        });
    }
}
#pragma clang diagnostic pop

@end