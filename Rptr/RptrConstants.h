//
//  RptrConstants.h
//  Rptr
//
//  Centralized constants for the Rptr application
//  Following Apple's Objective-C naming conventions:
//  - Use 'k' prefix for constants (e.g., kRptrConstantName)
//  - Use descriptive names that indicate purpose
//  - Group related constants together
//

#ifndef RptrConstants_h
#define RptrConstants_h

#import <Foundation/Foundation.h>

// MARK: - HLS Streaming Constants

// Segment Configuration
// These values are optimized for reliability on poor network conditions
// Research: Apple recommends 6-10 second segments for live streaming
// We use 4 seconds to balance latency and reliability
static const NSTimeInterval kRptrSegmentDuration = 4.0;  // Duration of each HLS segment in seconds
static const NSInteger kRptrTargetDuration = 5;          // Maximum segment duration for playlist (must be >= actual segment duration)
static const NSInteger kRptrMaxSegments = 20;            // Maximum segments to keep in memory (20 * 4s = 80s buffer)
static const NSInteger kRptrPlaylistWindow = 6;          // Number of segments in sliding window playlist (6 * 4s = 24s)

// Network Buffer Sizes
static const NSInteger kRptrHTTPBufferSize = 16384;      // 16KB buffer for HTTP operations

// Video Encoding Constants
// Optimized for reliability: lower bitrate, resolution, and framerate
static const NSInteger kRptrVideoBitrate = 600000;       // 600 kbps - works on most 3G/4G networks
static const NSInteger kRptrVideoWidth = 960;            // qHD width (quarter HD)
static const NSInteger kRptrVideoHeight = 540;           // qHD height
static const NSInteger kRptrVideoFrameRate = 15;         // 15 fps - smooth enough for most content
static const NSInteger kRptrVideoKeyFrameInterval = 30;  // Keyframe every 2 seconds (30 frames at 15fps)
static const CGFloat kRptrVideoKeyFrameDuration = 2.0;   // Keyframe interval in seconds
static const CGFloat kRptrVideoQuality = 0.75;           // Video quality (0.0-1.0)

// Audio Encoding Constants
static const NSInteger kRptrAudioBitrate = 64000;        // 64 kbps for mono audio
static const NSInteger kRptrAudioSampleRate = 44100;     // Standard CD quality
static const NSInteger kRptrAudioChannels = 1;           // Mono to save bandwidth

// Server Configuration
static const NSInteger kRptrDefaultServerPort = 8080;    // Default HTTP server port
static const NSInteger kRptrRandomPathLength = 10;       // Length of random URL path for basic security

// Timing Constants
static const NSTimeInterval kRptrSegmentTimerOffset = 0.5;     // Fire timer 0.5s before segment end
static const NSTimeInterval kRptrSegmentRotationDelay = 0.5;   // Additional delay before forcing rotation
static const NSTimeInterval kRptrClientInactivityTimeout = 30.0; // Remove inactive clients after 30s
static const NSTimeInterval kRptrMemoryWarningDelay = 0.5;     // Delay before handling memory warnings

// UI Update Intervals
static const NSTimeInterval kRptrLocationUpdateInterval = 2.0;  // Update location every 2 seconds
static const NSTimeInterval kRptrAudioLevelUpdateInterval = 0.1; // Update audio meter 10 times per second

// MARK: - Network Interface Names

// Cellular Interface Prefixes
static NSString * const kRptrCellularInterfacePDP = @"pdp_ip";
static NSString * const kRptrCellularInterfaceRMNET = @"rmnet";
static NSString * const kRptrCellularInterfaceEN2 = @"en2";

// WiFi Interface
static NSString * const kRptrWiFiInterface = @"en0";

// MARK: - HLS Playlist Tags

// HLS Version and Compatibility
static NSString * const kRptrHLSVersion = @"6";  // Version 6 supports fMP4 with good compatibility

// MARK: - File Names and Paths

static NSString * const kRptrPlaylistFileName = @"playlist.m3u8";
static NSString * const kRptrInitSegmentFileName = @"init.mp4";
static NSString * const kRptrSegmentFilePrefix = @"segment";
static NSString * const kRptrSegmentFileExtension = @"m4s";
static NSString * const kRptrBaseDirectoryName = @"HLSStream";
static NSString * const kRptrSegmentDirectoryName = @"segments";

// MARK: - HTTP Response Headers

static NSString * const kRptrHTTPHeaderContentType = @"Content-Type";
static NSString * const kRptrHTTPHeaderContentLength = @"Content-Length";
static NSString * const kRptrHTTPHeaderConnection = @"Connection";
static NSString * const kRptrHTTPHeaderCacheControl = @"Cache-Control";
static NSString * const kRptrHTTPHeaderAccessControl = @"Access-Control-Allow-Origin";

// MARK: - Content Types

static NSString * const kRptrContentTypeM3U8 = @"application/vnd.apple.mpegurl";
static NSString * const kRptrContentTypeMP4 = @"video/mp4";
static NSString * const kRptrContentTypeHTML = @"text/html";
static NSString * const kRptrContentTypeCSS = @"text/css";
static NSString * const kRptrContentTypeJS = @"application/javascript";
static NSString * const kRptrContentTypePNG = @"image/png";
static NSString * const kRptrContentTypeJSON = @"application/json";

// MARK: - Queue Names

static NSString * const kRptrServerQueueName = @"com.rptr.hls.server";
static NSString * const kRptrWriterQueueName = @"com.rptr.hls.writer";
static NSString * const kRptrPropertyQueueName = @"com.rptr.hls.properties";
static NSString * const kRptrClientsQueueName = @"com.rptr.hls.clients";
static NSString * const kRptrSegmentDataQueueName = @"com.rptr.hls.segmentdata";
static NSString * const kRptrSegmentsQueueName = @"com.rptr.hls.segments";
static NSString * const kRptrVideoQueueName = @"com.rptr.videoQueue";
static NSString * const kRptrAudioQueueName = @"com.rptr.audioQueue";
static NSString * const kRptrOverlayQueueName = @"com.rptr.overlay.queue";
static NSString * const kRptrLocationQueueName = @"com.rptr.permission.location";

// MARK: - Error Domains

static NSString * const kRptrErrorDomainHLSServer = @"HLSServer";
static NSString * const kRptrErrorDomainPermission = @"PermissionManager";

// MARK: - Notification Names

static NSString * const kRptrNotificationStreamingStarted = @"RptrStreamingStarted";
static NSString * const kRptrNotificationStreamingStopped = @"RptrStreamingStopped";
static NSString * const kRptrNotificationClientConnected = @"RptrClientConnected";
static NSString * const kRptrNotificationClientDisconnected = @"RptrClientDisconnected";

#endif /* RptrConstants_h */