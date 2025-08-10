//
//  RptrWebSocketServer.h
//  Rptr
//
//  WebSocket Server for real-time communication
//  Handles client connections, status updates, and error logging
//

#import <Foundation/Foundation.h>
// WebSocket functionality removed - files kept for potential future use
// #import "CocoaHTTPServer/HTTPServer.h"  
// #import "CocoaHTTPServer/WebSocket.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RptrWebSocketServerDelegate <NSObject>
@optional
- (void)webSocketServerDidStart:(NSUInteger)port;
- (void)webSocketServerDidStop;
- (void)webSocketClientConnected:(NSString *)clientId;
- (void)webSocketClientDisconnected:(NSString *)clientId;
- (void)webSocketReceivedFeedback:(NSString *)message fromClient:(NSString *)clientId;
@end

@interface RptrWebSocketServer : NSObject

@property (nonatomic, weak) id<RptrWebSocketServerDelegate> delegate;
@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) NSUInteger connectedClientsCount;
@property (nonatomic, strong) NSString *randomPath;

// Initialization
- (instancetype)initWithPort:(NSUInteger)port;

// Server Control
- (BOOL)startServer:(NSError **)error;
- (void)stopServer;

// Broadcasting Methods
- (void)broadcastMessage:(NSDictionary *)message;
- (void)broadcastHLSClientCount:(NSUInteger)count;
- (void)broadcastTitle:(NSString *)title;
- (void)broadcastLocation:(NSDictionary *)location;
- (void)broadcastError:(NSString *)error severity:(NSString *)severity;

// Client Management
- (NSArray<NSString *> *)connectedClientIds;

@end

// WebSocket Connection Handler - disabled (no longer inherits from WebSocket)
// @interface RptrWebSocketConnection : WebSocket
// @property (nonatomic, weak) RptrWebSocketServer *server;
// @property (nonatomic, strong) NSString *clientId;
// @end

NS_ASSUME_NONNULL_END