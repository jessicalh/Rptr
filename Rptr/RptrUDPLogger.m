//
//  RptrUDPLogger.m
//  Rptr
//
//  UDP logging client implementation
//

#import "RptrUDPLogger.h"
#import "RptrUDPLoggerConfig.h"  // Auto-generated at build time
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <UIKit/UIKit.h>

#define DEFAULT_UDP_PORT 9999
#define MAX_MESSAGE_SIZE 4000  // Leave room for headers

@interface RptrUDPLogger () {
    int _socketFD;
    struct sockaddr_in _serverAddr;
    dispatch_queue_t _sendQueue;
}

@property (nonatomic, strong) NSString *serverHost;
@property (nonatomic, assign) uint16_t serverPort;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) NSUInteger messagesSent;
@property (nonatomic, assign) NSUInteger bytesSent;
@property (nonatomic, assign) NSUInteger messagesDropped;
@property (nonatomic, strong) NSString *discoveredServerIP;
@property (nonatomic, assign) BOOL autoDiscoveryEnabled;

@end

@implementation RptrUDPLogger

+ (instancetype)sharedLogger {
    static RptrUDPLogger *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _socketFD = -1;
        
        // Use build-time configured IP if available
        #ifdef RPTR_UDP_LOG_SERVER_IP
            _serverHost = RPTR_UDP_LOG_SERVER_IP;
            _serverPort = RPTR_UDP_LOG_SERVER_PORT;
            NSLog(@"[RptrUDPLogger] Using build-time configured server: %@:%d", _serverHost, _serverPort);
            NSLog(@"[RptrUDPLogger] Built on: %@ by %@", RPTR_BUILD_TIMESTAMP, RPTR_BUILD_MACHINE);
            _autoDiscoveryEnabled = NO;  // Don't need discovery when configured at build time
        #else
            _serverHost = @"127.0.0.1";  // Default to localhost
            _serverPort = DEFAULT_UDP_PORT;
            _autoDiscoveryEnabled = YES;
            // Try to auto-discover server on init
            [self autoDiscoverServerIP];
        #endif
        
        _sendQueue = dispatch_queue_create("com.rptr.udplogger", DISPATCH_QUEUE_SERIAL);
        _isConnected = NO;
        _messagesSent = 0;
        _bytesSent = 0;
        _messagesDropped = 0;
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (void)configureWithHost:(NSString *)host port:(uint16_t)port {
    self.serverHost = host;
    self.serverPort = port;
    
    // Reconnect if already connected
    if (self.isConnected) {
        [self disconnect];
        [self connect];
    }
}

- (void)configureWithHost:(NSString *)host {
    [self configureWithHost:host port:DEFAULT_UDP_PORT];
}

- (void)connect {
    if (self.isConnected) {
        return;
    }
    
    dispatch_sync(_sendQueue, ^{
        // Create UDP socket
        self->_socketFD = socket(AF_INET, SOCK_DGRAM, 0);
        if (self->_socketFD < 0) {
            NSLog(@"[RptrUDPLogger] Failed to create socket: %s", strerror(errno));
            return;
        }
        
        // Set non-blocking mode
        int flags = fcntl(self->_socketFD, F_GETFL, 0);
        fcntl(self->_socketFD, F_SETFL, flags | O_NONBLOCK);
        
        // Configure server address
        memset(&self->_serverAddr, 0, sizeof(self->_serverAddr));
        self->_serverAddr.sin_family = AF_INET;
        self->_serverAddr.sin_port = htons(self.serverPort);
        
        if (inet_pton(AF_INET, [self.serverHost UTF8String], &self->_serverAddr.sin_addr) <= 0) {
            NSLog(@"[RptrUDPLogger] Invalid address: %@", self.serverHost);
            close(self->_socketFD);
            self->_socketFD = -1;
            return;
        }
        
        self.isConnected = YES;
        
        // Send connection message
        NSString *connectMsg = [NSString stringWithFormat:@"iOS|==== iOS App Connected (%@) ====", 
                               [[UIDevice currentDevice] name]];
        [self sendMessage:connectMsg];
    });
}

- (void)disconnect {
    if (!self.isConnected) {
        return;
    }
    
    // Send disconnection message
    [self logWithSource:@"iOS" message:@"==== iOS App Disconnected ===="];
    
    dispatch_sync(_sendQueue, ^{
        if (self->_socketFD >= 0) {
            close(self->_socketFD);
            self->_socketFD = -1;
        }
        self.isConnected = NO;
    });
}

- (void)log:(NSString *)message {
    [self logWithSource:@"iOS" message:message];
}

- (void)logWithSource:(NSString *)source message:(NSString *)message {
    if (!message) return;
    
    // Auto-connect if needed
    if (!self.isConnected) {
        [self connect];
    }
    
    if (!self.isConnected) {
        self.messagesDropped++;
        return;
    }
    
    // Format: "SOURCE|MESSAGE"
    NSString *formattedMessage = [NSString stringWithFormat:@"%@|%@", source, message];
    [self sendMessage:formattedMessage];
}

- (void)logFormat:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self log:message];
}

- (void)sendMessage:(NSString *)message {
    if (!message || !self.isConnected) {
        self.messagesDropped++;
        return;
    }
    
    dispatch_async(_sendQueue, ^{
        // Truncate if too long
        NSString *finalMessage = message;
        if (message.length > MAX_MESSAGE_SIZE) {
            finalMessage = [message substringToIndex:MAX_MESSAGE_SIZE];
        }
        
        const char *utf8Message = [finalMessage UTF8String];
        size_t messageLength = strlen(utf8Message);
        
        // Send via UDP (non-blocking)
        ssize_t sent = sendto(self->_socketFD, utf8Message, messageLength, 0,
                             (struct sockaddr *)&self->_serverAddr, sizeof(self->_serverAddr));
        
        if (sent > 0) {
            self.messagesSent++;
            self.bytesSent += sent;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            // Only log real errors, not non-blocking would-block
            if (self.messagesDropped % 100 == 0) {  // Rate limit error logging
                NSLog(@"[RptrUDPLogger] Send failed: %s", strerror(errno));
            }
            self.messagesDropped++;
        }
    });
}

#pragma mark - WiFi IP Discovery

- (nullable NSString *)getLocalWiFiIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    // Retrieve the current interfaces
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check if interface is en0 which is the WiFi connection on iPhone
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([interfaceName isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    // Free memory
    freeifaddrs(interfaces);
    return address;
}

- (void)autoDiscoverServerIP {
    if (!self.autoDiscoveryEnabled) {
        return;
    }
    
    // Get local WiFi IP
    NSString *localIP = [self getLocalWiFiIPAddress];
    if (!localIP) {
        NSLog(@"[RptrUDPLogger] Could not determine local WiFi IP address");
        return;
    }
    
    NSLog(@"[RptrUDPLogger] Device WiFi IP: %@", localIP);
    
    // Extract the network prefix (e.g., 192.168.1 from 192.168.1.45)
    NSArray *components = [localIP componentsSeparatedByString:@"."];
    if (components.count != 4) {
        NSLog(@"[RptrUDPLogger] Invalid IP format: %@", localIP);
        return;
    }
    
    NSString *networkPrefix = [NSString stringWithFormat:@"%@.%@.%@", 
                               components[0], components[1], components[2]];
    
    // Try common development machine addresses
    NSArray *commonHosts = @[
        [NSString stringWithFormat:@"%@.1", networkPrefix],   // Router often at .1
        [NSString stringWithFormat:@"%@.2", networkPrefix],   // Common static IP
        [NSString stringWithFormat:@"%@.100", networkPrefix], // Common DHCP range
        @"10.0.0.1",    // Common development network
        @"10.0.0.2",
        @"172.20.10.1", // iOS Personal Hotspot default
    ];
    
    // Also check if there's a development machine IP stored in user defaults
    NSString *savedIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"RptrUDPLogServerIP"];
    if (savedIP) {
        NSMutableArray *hosts = [commonHosts mutableCopy];
        [hosts insertObject:savedIP atIndex:0];
        commonHosts = hosts;
    }
    
    // Try each potential host
    for (NSString *host in commonHosts) {
        if ([self testServerConnection:host]) {
            self.discoveredServerIP = host;
            self.serverHost = host;
            NSLog(@"[RptrUDPLogger] Discovered UDP log server at: %@", host);
            
            // Save for next time
            [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"RptrUDPLogServerIP"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            
            // Reconnect with new host
            if (self.isConnected) {
                [self disconnect];
                [self connect];
            }
            return;
        }
    }
    
    NSLog(@"[RptrUDPLogger] Could not auto-discover UDP log server on network");
    NSLog(@"[RptrUDPLogger] Falling back to default: %@", self.serverHost);
}

- (BOOL)testServerConnection:(NSString *)host {
    // Create a temporary socket for testing
    int testSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (testSocket < 0) {
        return NO;
    }
    
    // Set timeout for quick testing
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 100000; // 100ms timeout
    setsockopt(testSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    struct sockaddr_in testAddr;
    memset(&testAddr, 0, sizeof(testAddr));
    testAddr.sin_family = AF_INET;
    testAddr.sin_port = htons(self.serverPort);
    
    if (inet_pton(AF_INET, [host UTF8String], &testAddr.sin_addr) <= 0) {
        close(testSocket);
        return NO;
    }
    
    // Send a test message (could be a PING command in future)
    const char *testMsg = "PING|UDP Logger Test";
    ssize_t sent = sendto(testSocket, testMsg, strlen(testMsg), 0,
                         (struct sockaddr *)&testAddr, sizeof(testAddr));
    
    close(testSocket);
    
    // If send succeeded, assume server might be there
    // In future, could wait for PONG response
    return (sent > 0);
}

- (nullable NSString *)getLogServerIP {
    if (self.discoveredServerIP) {
        return self.discoveredServerIP;
    }
    return self.serverHost;
}

- (uint16_t)getLogServerPort {
    return self.serverPort;
}

#pragma mark - Session Management

- (void)startNewSession {
    // Send NEW_SESSION command
    [self sendMessage:@"CMD|NEW_SESSION"];
    NSLog(@"[RptrUDPLogger] Sent NEW_SESSION command to server");
}

- (void)endSession {
    // Send END_SESSION command  
    [self sendMessage:@"CMD|END_SESSION"];
    NSLog(@"[RptrUDPLogger] Sent END_SESSION command to server");
}

@end