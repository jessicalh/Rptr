//
//  RptrConstants.h
//  Rptr
//
//  Application-wide constants and configuration values
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Network Configuration

// Server Ports
static const NSUInteger kRptrHLSServerPort = 8080;
static const NSUInteger kRptrDefaultServerPort = 8080;

// Network Timeouts (seconds)
static const NSTimeInterval kRptrNetworkTimeout = 30.0;
static const NSTimeInterval kRptrManifestTimeout = 15.0;

// Buffer Sizes
static const NSUInteger kRptrSocketBufferSize = 4096;
static const NSUInteger kRptrMaxBufferSize = 30 * 1024 * 1024; // 30 MB

#pragma mark - HLS Configuration

// Segment Configuration
static const NSTimeInterval kRptrSegmentDuration = 4.0;
static const NSInteger kRptrSegmentCount = 6;
static const NSInteger kRptrMaxSegmentCount = 10;

// HLS Timing
static const NSTimeInterval kRptrLiveLatency = 3.0;
static const NSTimeInterval kRptrMaxLatency = 10.0;

#pragma mark - Video Configuration

// Video Dimensions
static const CGFloat kRptrVideoWidth = 960.0;
static const CGFloat kRptrVideoHeight = 540.0;

// Frame Rates
static const NSInteger kRptrReliableFrameRate = 15;
static const NSInteger kRptrRealtimeFrameRate = 30;

// Bitrates (bits per second)
static const NSInteger kRptrReliableVideoBitrate = 600000;  // 600 kbps
static const NSInteger kRptrRealtimeVideoBitrate = 1500000; // 1.5 Mbps
static const NSInteger kRptrAudioBitrate = 64000;           // 64 kbps

#pragma mark - UI Configuration

// Button Sizes
static const CGFloat kRptrStreamButtonSize = 60.0;
static const CGFloat kRptrSmallButtonSize = 40.0;

// Animation Durations
static const NSTimeInterval kRptrFadeAnimationDuration = 0.3;
static const NSTimeInterval kRptrPulseAnimationDuration = 1.5;

// Feedback Display
static const NSTimeInterval kRptrFeedbackDisplayDuration = 10.0;
static const NSUInteger kRptrMaxFeedbackQueueSize = 100;

// Layout Constants
static const CGFloat kRptrDefaultPadding = 20.0;
static const CGFloat kRptrSmallPadding = 10.0;
static const CGFloat kRptrCornerRadius = 8.0;

#pragma mark - Timer Intervals

static const NSTimeInterval kRptrUTCUpdateInterval = 1.0;
static const NSTimeInterval kRptrLocationUpdateInterval = 10.0;
static const NSTimeInterval kRptrStatsUpdateInterval = 0.2;
static const NSTimeInterval kRptrStatusPollInterval = 10.0;

#pragma mark - Limits

// Connection Limits
static const NSUInteger kRptrMaxConnections = 100;

// String Length Limits
static const NSUInteger kRptrMaxTitleLength = 100;
static const NSUInteger kRptrMaxFeedbackLength = 100;
static const NSUInteger kRptrRandomPathLength = 8;

#pragma mark - Queue Names

static NSString * const kRptrServerQueueName = @"com.rptr.server.queue";
static NSString * const kRptrWriterQueueName = @"com.rptr.writer.queue";
static NSString * const kRptrPropertyQueueName = @"com.rptr.property.queue";
static NSString * const kRptrClientsQueueName = @"com.rptr.clients.queue";
static NSString * const kRptrSegmentDataQueueName = @"com.rptr.segmentData.queue";
static NSString * const kRptrSegmentsQueueName = @"com.rptr.segments.queue";

#pragma mark - File System Names

static NSString * const kRptrBaseDirectoryName = @"HLSAssets";
static NSString * const kRptrSegmentDirectoryName = @"segments";

#pragma mark - Camera Configuration

// Brightness Detection
static const CGFloat kRptrMinBrightness = 0.1;
static const CGFloat kRptrMaxBrightness = 0.9;
static const NSUInteger kRptrBrightnessHistorySize = 30;

// Activity Detection
static const NSTimeInterval kRptrCameraEvaluationInterval = 5.0;
static const NSInteger kRptrNoActivityThreshold = 5;
static const NSInteger kRptrBurstCountThreshold = 3;

#pragma mark - File System

// Cache Durations (seconds)
static const NSTimeInterval kRptrWebResourceCacheDuration = 0; // No cache for development
static const NSTimeInterval kRptrSegmentCacheDuration = 30.0;

#pragma mark - Error Codes

static NSString * const kRptrErrorDomainHLSServer = @"com.rptr.hls.error";

typedef NS_ENUM(NSInteger, RptrErrorCode) {
    RptrErrorCodeUnknown = -1,
    RptrErrorCodeNetworkUnavailable = 1000,
    RptrErrorCodeServerStartFailed = 1001,
    RptrErrorCodeStreamingFailed = 1002,
    RptrErrorCodePermissionDenied = 1003,
    RptrErrorCodeCameraUnavailable = 1004,
    RptrErrorCodeAssetWriterFailed = 1005,
    RptrErrorCodeInvalidConfiguration = 1006
};

#pragma mark - Notification Names

extern NSString * const RptrStreamDidStartNotification;
extern NSString * const RptrStreamDidStopNotification;
extern NSString * const RptrClientDidConnectNotification;
extern NSString * const RptrClientDidDisconnectNotification;
extern NSString * const RptrErrorOccurredNotification;

#pragma mark - User Defaults Keys

extern NSString * const RptrUserDefaultsStreamTitle;
extern NSString * const RptrUserDefaultsQualityMode;
extern NSString * const RptrUserDefaultsLocationEnabled;
extern NSString * const RptrUserDefaultsAudioEnabled;

NS_ASSUME_NONNULL_END