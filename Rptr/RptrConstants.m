//
//  RptrConstants.m
//  Rptr
//
//  Implementation of string constants
//

#import "RptrConstants.h"

#pragma mark - Notification Names

NSString * const RptrStreamDidStartNotification = @"RptrStreamDidStartNotification";
NSString * const RptrStreamDidStopNotification = @"RptrStreamDidStopNotification";
NSString * const RptrClientDidConnectNotification = @"RptrClientDidConnectNotification";
NSString * const RptrClientDidDisconnectNotification = @"RptrClientDidDisconnectNotification";
NSString * const RptrErrorOccurredNotification = @"RptrErrorOccurredNotification";

#pragma mark - User Defaults Keys

NSString * const RptrUserDefaultsStreamTitle = @"RptrStreamTitle";
NSString * const RptrUserDefaultsQualityMode = @"RptrQualityMode";
NSString * const RptrUserDefaultsLocationEnabled = @"RptrLocationEnabled";
NSString * const RptrUserDefaultsAudioEnabled = @"RptrAudioEnabled";