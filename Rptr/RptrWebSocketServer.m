//
//  RptrWebSocketServer.m
//  Rptr
//
//  WebSocket Server Implementation
//

#import "RptrWebSocketServer.h"
#import "RptrLogger.h"

// WebSocket functionality temporarily disabled - commenting out entire implementation
#if 0

#import "CocoaHTTPServer/HTTPConnection.h"
#import "CocoaHTTPServer/HTTPDataResponse.h"
#import "CocoaHTTPServer/HTTPMessage.h"
#import "CocoaHTTPServer/GCDAsyncSocket.h"
#import <objc/runtime.h>

// Forward declarations
@interface RptrHTTPConnection : HTTPConnection
@end

@interface RptrWebSocketServer ()

@property (nonatomic, strong) HTTPServer *httpServer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RptrWebSocketConnection *> *activeConnections;
@property (nonatomic, strong) dispatch_queue_t connectionQueue;

@end

@implementation RptrWebSocketServer

- (instancetype)initWithPort:(NSUInteger)port {
    self = [super init];
    if (self) {
        _port = port;
        _httpServer = [[HTTPServer alloc] init];
        _activeConnections = [NSMutableDictionary dictionary];
        _connectionQueue = dispatch_queue_create("com.rptr.websocket.connections", DISPATCH_QUEUE_SERIAL);
        
        // Configure HTTP server
        [_httpServer setPort:port];
        [_httpServer setConnectionClass:[RptrHTTPConnection class]];
        
        // Store reference to self for the connection class
        objc_setAssociatedObject(_httpServer, @"WebSocketServer", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        RLogNetwork(@"WebSocket server initialized on port %lu", (unsigned long)port);
    }
    return self;
}

- (BOOL)startServer:(NSError **)error {
    NSError *localError = nil;
    BOOL success = [_httpServer start:&localError];
    
    if (success) {
        _isRunning = YES;
        RLogNetwork(@"WebSocket server started on port %lu", (unsigned long)_httpServer.listeningPort);
        
        if ([self.delegate respondsToSelector:@selector(webSocketServerDidStart:)]) {
            [self.delegate webSocketServerDidStart:_httpServer.listeningPort];
        }
    } else {
        RLogError(@"Failed to start WebSocket server: %@", localError.localizedDescription);
        if (error) {
            *error = localError;
        }
    }
    
    return success;
}

- (void)stopServer {
    [_httpServer stop];
    _isRunning = NO;
    
    // Close all active connections
    dispatch_sync(_connectionQueue, ^{
        for (RptrWebSocketConnection *connection in self.activeConnections.allValues) {
            [connection stop];
        }
        [self.activeConnections removeAllObjects];
    });
    
    RLogNetwork(@"WebSocket server stopped");
    
    if ([self.delegate respondsToSelector:@selector(webSocketServerDidStop)]) {
        [self.delegate webSocketServerDidStop];
    }
}

- (void)addConnection:(RptrWebSocketConnection *)connection withId:(NSString *)clientId {
    dispatch_async(_connectionQueue, ^{
        self.activeConnections[clientId] = connection;
        RLogNetwork(@"WebSocket client connected: %@", clientId);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(webSocketClientConnected:)]) {
                [self.delegate webSocketClientConnected:clientId];
            }
        });
    });
}

- (void)removeConnection:(NSString *)clientId {
    dispatch_async(_connectionQueue, ^{
        [self.activeConnections removeObjectForKey:clientId];
        RLogNetwork(@"WebSocket client disconnected: %@", clientId);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(webSocketClientDisconnected:)]) {
                [self.delegate webSocketClientDisconnected:clientId];
            }
        });
    });
}

- (NSUInteger)connectedClientsCount {
    __block NSUInteger count = 0;
    dispatch_sync(_connectionQueue, ^{
        count = self.activeConnections.count;
    });
    return count;
}

- (NSArray<NSString *> *)connectedClientIds {
    __block NSArray *clientIds = nil;
    dispatch_sync(_connectionQueue, ^{
        clientIds = [self.activeConnections.allKeys copy];
    });
    return clientIds;
}

- (void)broadcastMessage:(NSDictionary *)message {
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    
    if (error) {
        RLogError(@"Failed to serialize WebSocket message: %@", error.localizedDescription);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    dispatch_async(_connectionQueue, ^{
        for (RptrWebSocketConnection *connection in self.activeConnections.allValues) {
            [connection sendMessage:jsonString];
        }
    });
}

- (void)broadcastHLSClientCount:(NSUInteger)count {
    NSDictionary *message = @{
        @"type": @"hls_clients",
        @"count": @(count),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    [self broadcastMessage:message];
}

- (void)broadcastTitle:(NSString *)title {
    NSDictionary *message = @{
        @"type": @"title_update",
        @"title": title,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    [self broadcastMessage:message];
}

- (void)broadcastLocation:(NSDictionary *)location {
    NSDictionary *message = @{
        @"type": @"location_update",
        @"location": location,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    [self broadcastMessage:message];
}

- (void)broadcastError:(NSString *)error severity:(NSString *)severity {
    NSDictionary *message = @{
        @"type": @"error_log",
        @"error": error,
        @"severity": severity ?: @"error",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    [self broadcastMessage:message];
}

@end

// HTTP Connection subclass to handle WebSocket upgrades
@implementation RptrHTTPConnection

- (WebSocket *)webSocketForURI:(NSString *)path {
    RLogNetwork(@"WebSocket requested for path: %@", path);
    
    // Get the WebSocket server reference to check the random path
    RptrWebSocketServer *server = objc_getAssociatedObject(config.server, @"WebSocketServer");
    
    // Accept WebSocket connections on /ws/{randomPath} path
    NSString *expectedPath = server.randomPath ? [NSString stringWithFormat:@"/ws/%@", server.randomPath] : @"/ws";
    
    if ([path isEqualToString:expectedPath]) {
        RptrWebSocketConnection *ws = [[RptrWebSocketConnection alloc] initWithRequest:request socket:asyncSocket];
        ws.server = server;
        
        // Generate unique client ID
        ws.clientId = [[NSUUID UUID] UUIDString];
        
        return ws;
    }
    
    return nil;
}

@end

// WebSocket Connection Implementation
@implementation RptrWebSocketConnection

- (void)didOpen {
    [super didOpen];
    
    RLogNetwork(@"WebSocket connection opened: %@", self.clientId);
    
    // Add to active connections
    [self.server addConnection:self withId:self.clientId];
    
    // Send initial connection message
    NSDictionary *welcomeMessage = @{
        @"type": @"connection",
        @"status": @"connected",
        @"clientId": self.clientId,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:welcomeMessage options:0 error:&error];
    if (!error) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [self sendMessage:jsonString];
    }
}

- (void)didReceiveMessage:(NSString *)msg {
    RLogNetwork(@"WebSocket message from %@: %@", self.clientId, msg);
    
    // Parse incoming message
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    
    if (error) {
        RLogError(@"Failed to parse WebSocket message: %@", error.localizedDescription);
        return;
    }
    
    // Handle different message types
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"ping"]) {
        // Respond with pong
        NSDictionary *pong = @{
            @"type": @"pong",
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
        NSData *pongData = [NSJSONSerialization dataWithJSONObject:pong options:0 error:nil];
        NSString *pongString = [[NSString alloc] initWithData:pongData encoding:NSUTF8StringEncoding];
        [self sendMessage:pongString];
    } else if ([type isEqualToString:@"feedback"]) {
        // Handle feedback from viewer
        NSString *feedbackMessage = message[@"message"];
        if (feedbackMessage && feedbackMessage.length > 0) {
            RLogNetwork(@"Received feedback from %@: %@", self.clientId, feedbackMessage);
            
            // Notify delegate
            if ([self.server.delegate respondsToSelector:@selector(webSocketReceivedFeedback:fromClient:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.server.delegate webSocketReceivedFeedback:feedbackMessage fromClient:self.clientId];
                });
            }
        }
    }
    // Add more message handlers as needed
}

- (void)didClose {
    [super didClose];
    
    RLogNetwork(@"WebSocket connection closed: %@", self.clientId);
    
    // Remove from active connections
    [self.server removeConnection:self.clientId];
}

@end

#endif

// Stub implementation while WebSocket functionality is disabled
@implementation RptrWebSocketServer

- (instancetype)initWithPort:(NSUInteger)port {
    self = [super init];
    return self;
}

- (BOOL)startServer:(NSError **)error {
    RLogWarning(@"WebSocket server is disabled");
    return NO;
}

- (void)stopServer {
    // No-op
}

- (void)broadcastMessage:(NSDictionary *)message {
    // No-op
}

- (void)broadcastHLSClientCount:(NSUInteger)count {
    // No-op
}

- (void)broadcastTitle:(NSString *)title {
    // No-op
}

- (void)broadcastLocation:(NSDictionary *)location {
    // No-op
}

- (void)broadcastError:(NSString *)error severity:(NSString *)severity {
    // No-op
}

- (NSArray<NSString *> *)connectedClientIds {
    return @[];
}

@end
