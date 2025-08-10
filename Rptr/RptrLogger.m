//
//  RptrLogger.m
//  Rptr
//
//  Centralized logging system with compile-time control
//

#import "RptrLogger.h"
#import "RptrUDPLogger.h"

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
    if (area & RptrLogAreaProtocol) return @"HLS";
    if (area & RptrLogAreaStartup) return @"INIT";
    if (area & RptrLogAreaANR) return @"ANR";
    if (area & RptrLogAreaInfo) return @"INFO";
    if (area & RptrLogAreaError) return @"ERROR";
    return @"";
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
    
    // Add timestamp for better tracing
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    // Format the log message
    NSString *formattedMessage = [NSString stringWithFormat:@"[%@-%@] %@", module, levelString, message];
    
    // Send to UDP logger (non-blocking)
    [[RptrUDPLogger sharedLogger] logWithSource:@"SERVER" message:formattedMessage];
    
    // Also log to console for debugging
    NSLog(@"[%@] %@", timestamp, formattedMessage);
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
    
    // Add timestamp for better tracing
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    // Format the log message
    NSString *formattedMessage = [NSString stringWithFormat:@"[%@-%@] %@", module, levelString, message];
    
    // Send to UDP logger (non-blocking)
    [[RptrUDPLogger sharedLogger] logWithSource:@"SERVER" message:formattedMessage];
    
    // Also log to console for debugging
    NSLog(@"[%@] %@", timestamp, formattedMessage);
#endif
}

+ (void)logHLS:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaProtocol level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logVideo:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaInfo level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logNetwork:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaInfo level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logUI:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaInfo level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logPermission:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaStartup level:RptrLogLevelInfo format:format arguments:args];
    va_end(args);
}

+ (void)logDebug:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self logWithArea:RptrLogAreaInfo level:RptrLogLevelDebug format:format arguments:args];
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
    [self logWithArea:RptrLogAreaANR level:RptrLogLevelDebug format:format arguments:args];
    va_end(args);
}

@end