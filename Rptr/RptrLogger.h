//
//  RptrLogger.h
//  Rptr
//
//  Centralized logging system with compile-time control
//

#import <Foundation/Foundation.h>

// Master logging switch - set to 0 to disable ALL logging
#define RPTR_LOGGING_ENABLED 1

// Log Area Bitmasks - can be combined for fine-grained control
typedef NS_OPTIONS(NSUInteger, RptrLogArea) {
    RptrLogAreaNone         = 0,
    RptrLogAreaHLS          = 1 << 0,  // 0x0001 - HLS streaming
    RptrLogAreaVideo        = 1 << 1,  // 0x0002 - Video capture/processing
    RptrLogAreaAudio        = 1 << 2,  // 0x0004 - Audio capture/processing
    RptrLogAreaNetwork      = 1 << 3,  // 0x0008 - Network operations
    RptrLogAreaUI           = 1 << 4,  // 0x0010 - UI interactions
    RptrLogAreaPermission   = 1 << 5,  // 0x0020 - Permission handling
    RptrLogAreaCamera       = 1 << 6,  // 0x0040 - Camera operations
    RptrLogAreaSegment      = 1 << 7,  // 0x0080 - Segment management
    RptrLogAreaBuffer       = 1 << 8,  // 0x0100 - Buffer operations
    RptrLogAreaPlayback     = 1 << 9,  // 0x0200 - Playback issues
    RptrLogAreaTiming       = 1 << 10, // 0x0400 - Timing/sync issues
    RptrLogAreaMemory       = 1 << 11, // 0x0800 - Memory management
    RptrLogAreaFile         = 1 << 12, // 0x1000 - File operations
    RptrLogAreaHTTP         = 1 << 13, // 0x2000 - HTTP server
    RptrLogAreaError        = 1 << 14, // 0x4000 - Errors (always enabled)
    RptrLogAreaDebug        = 1 << 15, // 0x8000 - Debug info
    RptrLogAreaAll          = 0xFFFF   // All areas
};

// Active log areas - modify this to control what gets logged
#define RPTR_ACTIVE_LOG_AREAS (RptrLogAreaError)

// Log levels
typedef NS_ENUM(NSInteger, RptrLogLevel) {
    RptrLogLevelError = 0,
    RptrLogLevelWarning = 1,
    RptrLogLevelInfo = 2,
    RptrLogLevelDebug = 3,
    RptrLogLevelVerbose = 4
};

// Current log level - only messages at this level or lower will be logged
#define RPTR_CURRENT_LOG_LEVEL RptrLogLevelError

NS_ASSUME_NONNULL_BEGIN

@interface RptrLogger : NSObject

// Bitmask-based logging method
+ (void)log:(RptrLogArea)area format:(NSString *)format, ... NS_FORMAT_FUNCTION(2,3);
+ (void)log:(RptrLogArea)area level:(RptrLogLevel)level format:(NSString *)format, ... NS_FORMAT_FUNCTION(3,4);

// Check if an area is active
+ (BOOL)isAreaActive:(RptrLogArea)area;

// Legacy module-specific logging methods (now use bitmask internally)
+ (void)logHLS:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logVideo:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logNetwork:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logUI:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logPermission:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logDebug:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

// Level-specific logging methods
+ (void)logError:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logWarning:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logInfo:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logVerbose:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

// Performance-critical logging (minimal overhead when disabled)
+ (void)logPerformance:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

@end

// Convenience macros for bitmask-based logging
#if RPTR_LOGGING_ENABLED
    #define RLog(area, ...) [RptrLogger log:area format:__VA_ARGS__]
    #define RLogLevel(area, level, ...) [RptrLogger log:area level:level format:__VA_ARGS__]
#else
    #define RLog(area, ...) ((void)0)
    #define RLogLevel(area, level, ...) ((void)0)
#endif

// Legacy convenience macros (now use bitmask internally)
#if RPTR_LOGGING_ENABLED
    #define RLogHLS(...) [RptrLogger log:RptrLogAreaHLS format:__VA_ARGS__]
    #define RLogVideo(...) [RptrLogger log:RptrLogAreaVideo format:__VA_ARGS__]
    #define RLogNetwork(...) [RptrLogger log:RptrLogAreaNetwork format:__VA_ARGS__]
    #define RLogUI(...) [RptrLogger log:RptrLogAreaUI format:__VA_ARGS__]
    #define RLogPermission(...) [RptrLogger log:RptrLogAreaPermission format:__VA_ARGS__]
    #define RLogDebug(...) [RptrLogger log:RptrLogAreaDebug format:__VA_ARGS__]
#else
    #define RLogHLS(...) ((void)0)
    #define RLogVideo(...) ((void)0)
    #define RLogNetwork(...) ((void)0)
    #define RLogUI(...) ((void)0)
    #define RLogPermission(...) ((void)0)
    #define RLogDebug(...) ((void)0)
#endif

// Level-based macros
#if RPTR_LOGGING_ENABLED
    #define RLogError(...) [RptrLogger logError:__VA_ARGS__]
    #define RLogWarning(...) [RptrLogger logWarning:__VA_ARGS__]
    #define RLogInfo(...) [RptrLogger logInfo:__VA_ARGS__]
    #define RLogVerbose(...) [RptrLogger logVerbose:__VA_ARGS__]
    #define RLogPerformance(...) [RptrLogger logPerformance:__VA_ARGS__]
#else
    #define RLogError(...) ((void)0)
    #define RLogWarning(...) ((void)0)
    #define RLogInfo(...) ((void)0)
    #define RLogVerbose(...) ((void)0)
    #define RLogPerformance(...) ((void)0)
#endif

NS_ASSUME_NONNULL_END