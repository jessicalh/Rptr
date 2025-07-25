//
//  HLSLogger.m
//  Rptr
//
//  Centralized logging system for HLS streaming
//

#import "HLSLogger.h"
#import "RptrLogger.h"

@implementation HLSLogger

static HLSLogLevel _logLevel = HLSLogLevelDebug;

+ (HLSLogLevel)logLevel {
    return _logLevel;
}

+ (void)setLogLevel:(HLSLogLevel)logLevel {
    _logLevel = logLevel;
}

+ (void)logDebug:(NSString *)format, ... {
    if (_logLevel >= HLSLogLevelDebug) {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"%@", message);
    }
}

+ (void)logInfo:(NSString *)format, ... {
    if (_logLevel >= HLSLogLevelInfo) {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        RLog(RptrLogAreaHLS, @"%@", message);
    }
}

+ (void)logError:(NSString *)format, ... {
    // Always log errors regardless of level
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RLog(RptrLogAreaHLS | RptrLogAreaError, @"%@", message);
}

@end