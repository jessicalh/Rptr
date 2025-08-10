//
//  RptrLogger.h
//  Rptr
//
//  Centralized logging system with compile-time control
//

#import <Foundation/Foundation.h>

// Master logging switch - set to 0 to disable ALL logging
#define RPTR_LOGGING_ENABLED 1

// Simplified log areas for focused debugging
typedef NS_OPTIONS(NSUInteger, RptrLogArea) {
    RptrLogAreaNone         = 0,
    RptrLogAreaProtocol     = 1 << 0,  // HLS protocol: segments, playlists, HTTP requests/responses
    RptrLogAreaStartup      = 1 << 1,  // App startup and initialization  
    RptrLogAreaANR          = 1 << 2,  // ANR debugging: blocking operations, delays
    RptrLogAreaInfo         = 1 << 3,  // General info messages
    RptrLogAreaError        = 1 << 4,  // Errors (always enabled when logging)
    RptrLogAreaVideoParams  = 1 << 5,  // Verbose video parameter logging (compressionProperties, etc)
    RptrLogAreaDIY          = 1 << 6,  // DIY HLS implementation logging
    RptrLogAreaAll          = 0x7F      // All areas (updated to include DIY)
};

// Preset configurations for common debugging scenarios
#define RPTR_LOG_PROTOCOL_ONLY (RptrLogAreaProtocol | RptrLogAreaError)
#define RPTR_LOG_STARTUP_DEBUG (RptrLogAreaStartup | RptrLogAreaANR | RptrLogAreaError)
#define RPTR_LOG_NORMAL (RptrLogAreaInfo | RptrLogAreaError)
#define RPTR_LOG_VERBOSE RptrLogAreaAll
#define RPTR_LOG_PROTOCOL_WITH_VIDEO (RptrLogAreaProtocol | RptrLogAreaError | RptrLogAreaVideoParams)
#define RPTR_LOG_DIY_DEBUG (RptrLogAreaDIY | RptrLogAreaProtocol | RptrLogAreaError)

// Active log areas - change this to control what gets logged
#define RPTR_ACTIVE_LOG_AREAS RPTR_LOG_DIY_DEBUG

// Log levels
typedef NS_ENUM(NSInteger, RptrLogLevel) {
    RptrLogLevelError = 0,
    RptrLogLevelWarning = 1,
    RptrLogLevelInfo = 2,
    RptrLogLevelDebug = 3,
    RptrLogLevelVerbose = 4
};

// Current log level - only messages at this level or lower will be logged
#define RPTR_CURRENT_LOG_LEVEL RptrLogLevelInfo

NS_ASSUME_NONNULL_BEGIN

@interface RptrLogger : NSObject

// Runtime configuration
+ (void)setActiveAreas:(RptrLogArea)areas;
+ (RptrLogArea)activeAreas;
+ (void)setLogLevel:(RptrLogLevel)level;
+ (RptrLogLevel)logLevel;

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

// Legacy convenience macros - now map to new areas
#if RPTR_LOGGING_ENABLED
    #define RLogHLS(...) [RptrLogger log:RptrLogAreaProtocol format:__VA_ARGS__]
    #define RLogVideo(...) [RptrLogger log:RptrLogAreaInfo format:__VA_ARGS__]
    #define RLogNetwork(...) [RptrLogger log:RptrLogAreaInfo format:__VA_ARGS__]
    #define RLogUI(...) [RptrLogger log:RptrLogAreaInfo format:__VA_ARGS__]
    #define RLogPermission(...) [RptrLogger log:RptrLogAreaStartup format:__VA_ARGS__]
    #define RLogDebug(...) [RptrLogger log:RptrLogAreaInfo format:__VA_ARGS__]
    #define RLogDIY(...) [RptrLogger log:RptrLogAreaDIY format:__VA_ARGS__]
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