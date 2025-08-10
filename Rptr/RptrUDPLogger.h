//
//  RptrUDPLogger.h
//  Rptr
//
//  UDP logging client for sending logs to the unified logging server
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RptrUDPLogger : NSObject

// Singleton instance
+ (instancetype)sharedLogger;

// Configuration
- (void)configureWithHost:(NSString *)host port:(uint16_t)port;
- (void)configureWithHost:(NSString *)host; // Uses default port 9999

// Auto-discovery
- (void)autoDiscoverServerIP; // Finds UDP log server on local network
- (nullable NSString *)getLocalWiFiIPAddress; // Gets device's WiFi IP
- (nullable NSString *)getLogServerIP; // Gets discovered server IP or configured IP
- (uint16_t)getLogServerPort; // Gets configured port

// Session management
- (void)startNewSession;
- (void)endSession;

// Logging
- (void)log:(NSString *)message;
- (void)logWithSource:(NSString *)source message:(NSString *)message;
- (void)logFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

// Connection management
@property (nonatomic, readonly) BOOL isConnected;
- (void)connect;
- (void)disconnect;

// Performance stats
@property (nonatomic, readonly) NSUInteger messagesSent;
@property (nonatomic, readonly) NSUInteger bytesSent;
@property (nonatomic, readonly) NSUInteger messagesDropped;

@end

NS_ASSUME_NONNULL_END