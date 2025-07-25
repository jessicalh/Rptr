//
//  HLSLogger.h
//  Rptr
//
//  Centralized logging system for HLS streaming
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, HLSLogLevel) {
    HLSLogLevelRelease = 0,  // No logging
    HLSLogLevelInfo = 1,     // Important events only
    HLSLogLevelDebug = 2     // All debugging information
};

@interface HLSLogger : NSObject

@property (class, nonatomic, assign) HLSLogLevel logLevel;

+ (void)logDebug:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logInfo:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logError:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

@end

NS_ASSUME_NONNULL_END