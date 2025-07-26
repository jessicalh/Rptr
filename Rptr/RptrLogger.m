//
//  RptrLogger.m
//  Rptr
//
//  Centralized logging system with compile-time control
//

#import "RptrLogger.h"

@implementation RptrLogger

// Static variables for runtime configuration
static RptrLogArea _activeAreas = RPTR_ACTIVE_LOG_AREAS;
static RptrLogLevel _currentLogLevel = RPTR_CURRENT_LOG_LEVEL;

// Runtime configuration methods
+ (void)setActiveAreas:(RptrLogArea)areas {
    _activeAreas = areas;
}

+ (RptrLogArea)activeAreas {
    return _activeAreas;
}

+ (void)setLogLevel:(RptrLogLevel)level {
    _currentLogLevel = level;
}

+ (RptrLogLevel)logLevel {
    return _currentLogLevel;
}

// Helper to get module name from area
+ (NSString *)moduleNameForArea:(RptrLogArea)area {
    // Return first matching area for simplicity
    if (area & RptrLogAreaHLS) return @"HLS";
    if (area & RptrLogAreaVideo) return @"VIDEO";
    if (area & RptrLogAreaAudio) return @"AUDIO";
    if (area & RptrLogAreaNetwork) return @"NET";
    if (area & RptrLogAreaUI) return @"UI";
    if (area & RptrLogAreaPermission) return @"PERM";
    if (area & RptrLogAreaCamera) return @"CAM";
    if (area & RptrLogAreaSegment) return @"SEG";
    if (area & RptrLogAreaBuffer) return @"BUF";
    if (area & RptrLogAreaPlayback) return @"PLAY";
    if (area & RptrLogAreaTiming) return @"TIME";
    if (area & RptrLogAreaMemory) return @"MEM";
    if (area & RptrLogAreaFile) return @"FILE";
    if (area & RptrLogAreaHTTP) return @"HTTP";
    if (area & RptrLogAreaError) return @"ERROR";
    if (area & RptrLogAreaDebug) return @"DEBUG";
    if (area & RptrLogAreaAssetWriter) return @"WRITER";
    if (area & RptrLogAreaLocation) return @"LOC";
    if (area & RptrLogAreaSession) return @"SESSION";
    if (area & RptrLogAreaDelegate) return @"DELEGATE";
    if (area & RptrLogAreaLifecycle) return @"LIFECYCLE";
    if (area & RptrLogAreaPerformance) return @"PERF";
    return @"UNKNOWN";
}

+ (BOOL)isAreaActive:(RptrLogArea)area {
#if RPTR_LOGGING_ENABLED
    // Always log errors
    if (area & RptrLogAreaError) return YES;
    return (area & _activeAreas) != 0;
#else
    return NO;
#endif
}

+ (void)log:(RptrLogArea)area format:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    if (![self isAreaActive:area]) {
        return;
    }
    
    va_list args;
    va_start(args, format);
    [self logWithArea:area level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
#endif
}

+ (void)log:(RptrLogArea)area level:(RptrLogLevel)level format:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    if (![self isAreaActive:area]) {
        return;
    }
    
    va_list args;
    va_start(args, format);
    [self logWithArea:area level:level format:format arguments:args];
    va_end(args);
#endif
}

+ (void)logWithArea:(RptrLogArea)area level:(RptrLogLevel)level format:(NSString *)format arguments:(va_list)args {
#if RPTR_LOGGING_ENABLED
    if (level > _currentLogLevel) {
        return;
    }
    
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    NSString *levelString = @"";
    
    switch (level) {
        case RptrLogLevelError:
            levelString = @"ERROR";
            break;
        case RptrLogLevelWarning:
            levelString = @"WARN";
            break;
        case RptrLogLevelInfo:
            levelString = @"INFO";
            break;
        case RptrLogLevelDebug:
            levelString = @"DEBUG";
            break;
        case RptrLogLevelVerbose:
            levelString = @"VERBOSE";
            break;
    }
    
    NSString *module = [self moduleNameForArea:area];
    
    // Use NSLog for output - this could be replaced with a more sophisticated system later
    NSLog(@"[%@-%@] %@", module, levelString, message);
#endif
}

// Legacy method kept for compatibility
+ (void)logWithLevel:(RptrLogLevel)level module:(NSString *)module format:(NSString *)format arguments:(va_list)args {
#if RPTR_LOGGING_ENABLED
    if (level > RPTR_CURRENT_LOG_LEVEL) {
        return;
    }
    
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    NSString *levelString = @"";
    
    switch (level) {
        case RptrLogLevelError:
            levelString = @"ERROR";
            break;
        case RptrLogLevelWarning:
            levelString = @"WARN";
            break;
        case RptrLogLevelInfo:
            levelString = @"INFO";
            break;
        case RptrLogLevelDebug:
            levelString = @"DEBUG";
            break;
        case RptrLogLevelVerbose:
            levelString = @"VERBOSE";
            break;
    }
    
    // Use NSLog for output - this could be replaced with a more sophisticated system later
    NSLog(@"[%@-%@] %@", module, levelString, message);
#endif
}

+ (void)logHLS:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaHLS level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logVideo:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaVideo level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logNetwork:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaNetwork level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logUI:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaUI level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logPermission:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaPermission level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logDebug:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaDebug level:RptrLogLevelDebug format:format arguments:args];
    va_end(args);
}

+ (void)logError:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    va_list args;
    va_start(args, format);
    [self logWithLevel:RptrLogLevelError module:@"ERROR" format:format arguments:args];
    va_end(args);
#endif
}

+ (void)logWarning:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    va_list args;
    va_start(args, format);
    [self logWithLevel:RptrLogLevelWarning module:@"WARN" format:format arguments:args];
    va_end(args);
#endif
}

+ (void)logInfo:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    va_list args;
    va_start(args, format);
    [self logWithLevel:RptrLogLevelInfo module:@"INFO" format:format arguments:args];
    va_end(args);
#endif
}

+ (void)logVerbose:(NSString *)format, ... {
#if RPTR_LOGGING_ENABLED
    va_list args;
    va_start(args, format);
    [self logWithLevel:RptrLogLevelVerbose module:@"VERBOSE" format:format arguments:args];
    va_end(args);
#endif
}

+ (void)logPerformance:(NSString *)format, ... {
    // Performance logging uses timing area
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaTiming level:RptrLogLevelDebug format:format arguments:args];
    va_end(args);
}

@end