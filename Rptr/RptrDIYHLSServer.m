//
//  RptrDIYHLSServer.m
//  Rptr
//
//  DIY HLS Server implementation
//

#import "RptrDIYHLSServer.h"
#import "RptrLogger.h"
#import "RptrUDPLogger.h"
#import "RptrSegmentValidator.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

// Segment info for playlist generation
@interface DIYSegmentInfo : NSObject
@property (nonatomic, strong) NSString *filename;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) uint32_t sequenceNumber;
@property (nonatomic, strong) NSDate *createdAt;
@end

@implementation DIYSegmentInfo
@end

@interface RptrDIYHLSServer ()

// Encoding components
@property (nonatomic, strong) RptrVideoToolboxEncoder *encoder;
@property (nonatomic, strong) RptrFMP4Muxer *muxer;

// Server properties
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, assign) BOOL isStreaming;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, strong) NSString *playlistURL;
@property (nonatomic, strong) NSString *randomPath;

// Segment management
@property (nonatomic, strong) NSMutableArray<DIYSegmentInfo *> *segments;
@property (nonatomic, strong) NSData *initializationSegmentData;
@property (nonatomic, assign) uint32_t currentSequenceNumber;
@property (nonatomic, assign) uint32_t mediaSequenceNumber;

// Frame buffering for segments
@property (nonatomic, strong) NSMutableArray<RptrEncodedFrame *> *currentSegmentFrames;
@property (nonatomic, assign) CMTime segmentStartTime;
@property (nonatomic, assign) CMTime nextKeyframeTime;
@property (nonatomic, strong) NSTimer *segmentTimer;

// Thread safety
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) dispatch_queue_t segmentQueue;
@property (nonatomic, strong) NSLock *segmentLock;

// Statistics
@property (nonatomic, assign) NSInteger totalSegments;
@property (nonatomic, assign) NSInteger droppedFrames;
@property (nonatomic, strong) NSDate *streamStartTime;

// Configuration
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger frameRate;
@property (nonatomic, assign) NSInteger bitrate;

// Parameter sets
@property (nonatomic, strong) NSData *sps;
@property (nonatomic, strong) NSData *pps;

@end

@implementation RptrDIYHLSServer

- (instancetype)initWithWidth:(NSInteger)width
                        height:(NSInteger)height
                     frameRate:(NSInteger)frameRate
                       bitrate:(NSInteger)bitrate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _frameRate = frameRate;
        _bitrate = bitrate;
        
        _segmentDuration = 1.0;
        _playlistWindowSize = 10;
        
        _segments = [NSMutableArray array];
        _currentSegmentFrames = [NSMutableArray array];
        _segmentLock = [[NSLock alloc] init];
        
        _serverQueue = dispatch_queue_create("com.rptr.diy.server", DISPATCH_QUEUE_SERIAL);
        _segmentQueue = dispatch_queue_create("com.rptr.diy.segment", DISPATCH_QUEUE_SERIAL);
        
        _currentSequenceNumber = 0;
        _mediaSequenceNumber = 0;
        
        // Generate random path for security (8 chars like original)
        _randomPath = [self generateRandomString:8];
        
        [self setupEncoder];
        [self setupMuxer];
        
        RLogDIY(@"[DIY-HLS] Initialized: %ldx%ld @ %ldfps, %ld bps",
                (long)width, (long)height, (long)frameRate, (long)bitrate);
    }
    return self;
}

- (void)dealloc {
    [self stopServer];
    [self stopStreaming];
}

#pragma mark - Utility Methods

- (NSString *)generateRandomString:(NSInteger)length {
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *randomString = [NSMutableString stringWithCapacity:length];
    
    for (NSInteger i = 0; i < length; i++) {
        uint32_t index = arc4random_uniform((uint32_t)letters.length);
        [randomString appendFormat:@"%C", [letters characterAtIndex:index]];
    }
    
    return randomString;
}

#pragma mark - Setup

- (void)setupEncoder {
    self.encoder = [[RptrVideoToolboxEncoder alloc] initWithWidth:self.width
                                                            height:self.height
                                                         frameRate:self.frameRate
                                                           bitrate:self.bitrate];
    self.encoder.delegate = self;
    self.encoder.keyframeInterval = self.frameRate; // Keyframe every second
    
    RLogDIY(@"[DIY-HLS] VideoToolbox encoder configured");
}

- (void)setupMuxer {
    self.muxer = [[RptrFMP4Muxer alloc] init];
    
    // Configure video track only
    RptrFMP4TrackConfig *videoTrack = [[RptrFMP4TrackConfig alloc] init];
    videoTrack.trackID = 1;
    videoTrack.mediaType = @"video";
    videoTrack.width = self.width;
    videoTrack.height = self.height;
    videoTrack.timescale = 90000; // 90kHz standard for video (matches PTS/DTS)
    
    [self.muxer addTrack:videoTrack];
    
    RLogDIY(@"[DIY-HLS] fMP4 muxer configured for video-only streaming");
}

#pragma mark - Server Control

- (BOOL)startServerOnPort:(NSInteger)port {
    if (self.serverSocket > 0) {
        RLogWarning(@"[DIY-HLS] Server already running");
        return YES;
    }
    
    // Create socket
    self.serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverSocket < 0) {
        RLogError(@"[DIY-HLS] Failed to create socket");
        return NO;
    }
    
    // Allow reuse
    int yes = 1;
    setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    
    // Bind to port
    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(port);
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(self.serverSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        RLogError(@"[DIY-HLS] Failed to bind to port %ld", (long)port);
        close(self.serverSocket);
        self.serverSocket = 0;
        return NO;
    }
    
    // Listen for connections
    if (listen(self.serverSocket, 10) < 0) {
        RLogError(@"[DIY-HLS] Failed to listen on socket");
        close(self.serverSocket);
        self.serverSocket = 0;
        return NO;
    }
    
    self.port = port;
    self.playlistURL = [NSString stringWithFormat:@"http://localhost:%ld/stream/%@/playlist.m3u8", (long)port, self.randomPath];
    
    // Start accept loop
    dispatch_async(self.serverQueue, ^{
        [self acceptConnections];
    });
    
    RLogDIY(@"[DIY-HLS] Server started on port %ld", (long)port);
    RLogDIY(@"[DIY-HLS] Random path: %@", self.randomPath);
    RLogDIY(@"[DIY-HLS] Playlist URL: %@", self.playlistURL);
    
    if ([self.delegate respondsToSelector:@selector(diyServer:didStartOnPort:)]) {
        [self.delegate diyServer:self didStartOnPort:port];
    }
    
    return YES;
}

- (void)stopServer {
    if (self.serverSocket > 0) {
        close(self.serverSocket);
        self.serverSocket = 0;
        RLogDIY(@"[DIY-HLS] Server stopped");
    }
}

- (void)acceptConnections {
    while (self.serverSocket > 0) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        
        int clientSocket = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSocket < 0) {
            if (self.serverSocket > 0) {
                RLogError(@"[DIY-HLS] Accept failed");
            }
            break;
        }
        
        // Handle request in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self handleClientSocket:clientSocket];
        });
    }
}

- (void)handleClientSocket:(int)clientSocket {
    // Read HTTP request
    char buffer[1024];
    ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    
    if (bytesRead <= 0) {
        close(clientSocket);
        return;
    }
    
    buffer[bytesRead] = '\0';
    NSString *request = [NSString stringWithUTF8String:buffer];
    
    // Parse request path
    NSArray *lines = [request componentsSeparatedByString:@"\n"];
    if (lines.count == 0) {
        close(clientSocket);
        return;
    }
    
    NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        close(clientSocket);
        return;
    }
    
    NSString *path = parts[1];
    RLogDIY(@"[DIY-HLS] Request: %@", path);
    
    // Route request with random path
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/view"]) {
        // Redirect to secure view path
        NSString *redirectURL = [NSString stringWithFormat:@"/view/%@", self.randomPath];
        NSString *response = [NSString stringWithFormat:
            @"HTTP/1.1 302 Found\r\n"
            @"Location: %@\r\n"
            @"Content-Length: 0\r\n"
            @"\r\n", redirectURL];
        send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
        RLogDIY(@"[DIY-HLS] Redirecting to %@", redirectURL);
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/view/%@", self.randomPath]]) {
        [self sendPlayerPage:clientSocket];
    } else if ([path hasPrefix:@"/css/"] || [path hasPrefix:@"/js/"] || [path hasPrefix:@"/images/"]) {
        // Serve static assets from WebResources
        [self serveStaticAsset:path socket:clientSocket];
    } else if ([path hasPrefix:@"/debug/validate/"]) {
        // Debug validation endpoints
        [self handleValidationRequest:path socket:clientSocket];
    } else if ([path isEqualToString:@"/forward-log"]) {
        if ([parts[0] isEqualToString:@"POST"]) {
            // Forward JavaScript logs through centralized logging
            [self forwardLogToCentralized:request socket:clientSocket];
        } else if ([parts[0] isEqualToString:@"OPTIONS"]) {
            // Handle CORS preflight
            [self sendCORSResponse:clientSocket];
        }
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/master.m3u8", self.randomPath]]) {
        [self sendMasterPlaylist:clientSocket];
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/playlist.m3u8", self.randomPath]]) {
        [self sendPlaylist:clientSocket];
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/init.mp4", self.randomPath]]) {
        [self sendInitSegment:clientSocket];
    } else if ([path hasPrefix:[NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath]]) {
        NSString *segmentPrefix = [NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath];
        NSString *filename = [path substringFromIndex:segmentPrefix.length];
        [self sendMediaSegment:filename socket:clientSocket];
    } else {
        [self send404:clientSocket];
    }
    
    close(clientSocket);
}

#pragma mark - HTTP Responses

- (void)sendMasterPlaylist:(int)clientSocket {
    // Master playlist with explicit CODECS for Safari native HLS
    // avc1.42001f = H.264 Baseline Profile Level 3.1 (for Safari compatibility)
    NSMutableString *playlist = [NSMutableString string];
    [playlist appendString:@"#EXTM3U\n"];
    [playlist appendString:@"#EXT-X-VERSION:6\n"];
    [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];
    
    // Explicitly declare the codec for Safari
    // Use actual resolution from our encoder (960x540)
    // Using Apple's codec format: avc1.640020 (Main Profile, Level 3.2)
    // This matches Apple's bipbop sample for 960x540
    // Video-only HLS stream
    [playlist appendFormat:@"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=600000,BANDWIDTH=2000000,CODECS=\"avc1.640020\",RESOLUTION=960x540,FRAME-RATE=15.000\n"];
    [playlist appendFormat:@"/stream/%@/playlist.m3u8\n", self.randomPath];
    
    NSData *playlistData = [playlist dataUsingEncoding:NSUTF8StringEncoding];
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/vnd.apple.mpegurl\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: no-cache\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (unsigned long)playlistData.length];
    
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
    send(clientSocket, playlistData.bytes, playlistData.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent master playlist with CODECS=\"avc1.640020,mp4a.40.2\"");
}

- (void)sendPlaylist:(int)clientSocket {
    RLogDIY(@"[DIY-HLS] Sending playlist - segments count: %lu, has init: %@", 
            (unsigned long)self.segments.count, 
            self.initializationSegmentData ? @"YES" : @"NO");
    
    [self.segmentLock lock];
    
    NSMutableString *playlist = [NSMutableString string];
    [playlist appendString:@"#EXTM3U\n"];
    [playlist appendString:@"#EXT-X-VERSION:6\n"];
    [playlist appendFormat:@"#EXT-X-TARGETDURATION:%d\n", (int)ceil(self.segmentDuration)];
    [playlist appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%u\n", self.mediaSequenceNumber];
    // Add explicit codec for Safari native HLS - Baseline Profile 3.1 (0x42001f)
    // Safari requires explicit CODECS attribute for native HLS playback
    [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];
    [playlist appendFormat:@"#EXT-X-MAP:URI=\"/stream/%@/init.mp4\"\n", self.randomPath];
    
    for (DIYSegmentInfo *segment in self.segments) {
        [playlist appendFormat:@"#EXTINF:%.3f,\n", segment.duration];
        [playlist appendFormat:@"/stream/%@/segments/%@\n", self.randomPath, segment.filename];
    }
    
    if (!self.isStreaming) {
        [playlist appendString:@"#EXT-X-ENDLIST\n"];
    }
    
    [self.segmentLock unlock];
    
    NSData *playlistData = [playlist dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/vnd.apple.mpegurl\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: no-cache\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (unsigned long)playlistData.length];
    
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
    send(clientSocket, playlistData.bytes, playlistData.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent playlist: %lu segments", (unsigned long)self.segments.count);
}

- (void)sendInitSegment:(int)clientSocket {
    if (!self.initializationSegmentData) {
        [self send404:clientSocket];
        return;
    }
    
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: video/mp4\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: max-age=3600\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (unsigned long)self.initializationSegmentData.length];
    
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
    send(clientSocket, self.initializationSegmentData.bytes, self.initializationSegmentData.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent init segment: %lu bytes", (unsigned long)self.initializationSegmentData.length);
}

- (void)sendMediaSegment:(NSString *)filename socket:(int)clientSocket {
    [self.segmentLock lock];
    
    DIYSegmentInfo *segment = nil;
    for (DIYSegmentInfo *seg in self.segments) {
        if ([seg.filename isEqualToString:filename]) {
            segment = seg;
            break;
        }
    }
    
    [self.segmentLock unlock];
    
    if (!segment || !segment.data) {
        [self send404:clientSocket];
        return;
    }
    
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: video/mp4\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: max-age=3600\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (unsigned long)segment.data.length];
    
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
    send(clientSocket, segment.data.bytes, segment.data.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent segment %@: %lu bytes", filename, (unsigned long)segment.data.length);
}

- (void)send404:(int)clientSocket {
    NSString *response = @"HTTP/1.1 404 Not Found\r\n"
                        @"Content-Length: 0\r\n"
                        @"\r\n";
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
}

- (void)serveStaticAsset:(NSString *)path socket:(int)clientSocket {
    // Strip query parameters if present
    NSString *cleanPath = path;
    NSRange queryRange = [path rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        cleanPath = [path substringToIndex:queryRange.location];
    }
    
    // Remove leading slash for resource lookup
    NSString *resourcePath = [cleanPath substringFromIndex:1];
    
    // Try to find the resource in WebResources directory
    NSString *filePath = [[NSBundle mainBundle] pathForResource:[resourcePath lastPathComponent]
                                                          ofType:nil
                                                    inDirectory:[@"WebResources" stringByAppendingPathComponent:[resourcePath stringByDeletingLastPathComponent]]];
    
    if (!filePath) {
        // Try without WebResources prefix (for backwards compatibility)
        filePath = [[NSBundle mainBundle] pathForResource:[resourcePath lastPathComponent] 
                                                    ofType:nil];
    }
    
    if (filePath) {
        NSData *fileData = [NSData dataWithContentsOfFile:filePath];
        if (fileData) {
            // Determine content type (check cleanPath for extension)
            NSString *contentType = @"application/octet-stream";
            if ([cleanPath hasSuffix:@".html"]) {
                contentType = @"text/html; charset=utf-8";
            } else if ([cleanPath hasSuffix:@".css"]) {
                contentType = @"text/css; charset=utf-8";
            } else if ([cleanPath hasSuffix:@".js"]) {
                contentType = @"application/javascript; charset=utf-8";
            } else if ([cleanPath hasSuffix:@".png"]) {
                contentType = @"image/png";
            } else if ([cleanPath hasSuffix:@".jpg"] || [cleanPath hasSuffix:@".jpeg"]) {
                contentType = @"image/jpeg";
            }
            
            NSString *response = [NSString stringWithFormat:
                @"HTTP/1.1 200 OK\r\n"
                @"Content-Type: %@\r\n"
                @"Content-Length: %lu\r\n"
                @"Cache-Control: max-age=3600\r\n"
                @"Access-Control-Allow-Origin: *\r\n"
                @"\r\n",
                contentType,
                (unsigned long)fileData.length];
            
            send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
            send(clientSocket, fileData.bytes, fileData.length, MSG_NOSIGNAL);
            
            RLogDIY(@"[DIY-HLS] Served asset: %@ (%lu bytes)", cleanPath, (unsigned long)fileData.length);
            return;
        }
    }
    
    RLogDIY(@"[DIY-HLS] Asset not found: %@ (cleaned: %@)", path, cleanPath);
    [self send404:clientSocket];
}

- (NSString *)getWiFiIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([interfaceName isEqualToString:@"en0"]) {  // WiFi interface
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    freeifaddrs(interfaces);
    return address;
}

- (void)forwardLogToCentralized:(NSString *)request socket:(int)clientSocket {
    // Extract the log message from the POST body
    NSArray *parts = [request componentsSeparatedByString:@"\r\n\r\n"];
    if (parts.count >= 2) {
        NSString *body = parts[1];
        
        // Forward through centralized logging system
        // The body is already formatted as "JS|[LEVEL] [MODULE] message"
        if (body.length > 0) {
            // Use RLogDIY to go through centralized logging → UDP
            RLogDIY(@"%@", body);
        }
    }
    
    // Send HTTP 200 OK response with CORS headers
    NSString *response = @"HTTP/1.1 200 OK\r\n"
                        @"Content-Length: 0\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Content-Type\r\n"
                        @"\r\n";
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
}

- (void)sendCORSResponse:(int)clientSocket {
    NSString *response = @"HTTP/1.1 200 OK\r\n"
                        @"Content-Length: 0\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Content-Type\r\n"
                        @"Access-Control-Max-Age: 86400\r\n"
                        @"\r\n";
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
}

- (void)sendPlayerPage:(int)clientSocket {
    // Try to load template from WebResources directory first, then from root
    NSString *templatePath = [[NSBundle mainBundle] pathForResource:@"index" 
                                                              ofType:@"html" 
                                                        inDirectory:@"WebResources"];
    
    // If not found in WebResources, try root of bundle
    if (!templatePath) {
        templatePath = [[NSBundle mainBundle] pathForResource:@"index" 
                                                        ofType:@"html"];
    }
    
    NSString *htmlContent = nil;
    
    if (templatePath) {
        NSError *error = nil;
        NSString *templateHTML = [NSString stringWithContentsOfFile:templatePath 
                                                           encoding:NSUTF8StringEncoding 
                                                              error:&error];
        if (!error && templateHTML) {
            // Replace template placeholders with actual values
            htmlContent = templateHTML;
            
            // Get WiFi IP address
            NSString *wifiIP = [self getWiFiIPAddress] ?: @"localhost";
            
            // Replace all template variables
            htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"{{APP_TITLE}}" 
                                                                  withString:@"Rptr Live Stream"];
            htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"{{PAGE_TITLE}}" 
                                                                  withString:@"Live Stream"];
            htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"{{STREAM_URL}}" 
                                                                  withString:[NSString stringWithFormat:@"/stream/%@/playlist.m3u8", 
                                                                             self.randomPath]];
            htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"{{SERVER_PORT}}" 
                                                                  withString:@"8080"];
            htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"{{INITIAL_STATUS}}" 
                                                                  withString:@"Connecting..."];
            
            RLogDIY(@"[DIY-HLS] Using WebResources template with WiFi IP: %@", wifiIP);
        } else {
            RLogError(@"[DIY-HLS] Failed to load template: %@", error);
        }
    } else {
        RLogError(@"[DIY-HLS] CRITICAL: Template not found - no fallback available");
    }
    
    // Fail if template not found
    if (!htmlContent) {
        RLogError(@"[DIY-HLS] Cannot serve player page - template missing");
        [self send404:clientSocket];
        return;
    }
    
    // Send the HTML content (either instrumented or fallback)
    NSData *htmlData = [htmlContent dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: text/html; charset=utf-8\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: no-cache\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (unsigned long)htmlData.length];
    
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
    send(clientSocket, htmlData.bytes, htmlData.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent player page: %lu bytes", (unsigned long)htmlData.length);
}

- (void)handleValidationRequest:(NSString *)path socket:(int)clientSocket {
    @try {
        RLogDIY(@"[VALIDATION-HANDLER] START: Processing validation request for path: %@", path);
        
        // Extract what to validate from path
        // Format: /debug/validate/init or /debug/validate/segment_N.m4s
        
        NSString *target = [path stringByReplacingOccurrencesOfString:@"/debug/validate/" withString:@""];
        RLogDIY(@"[VALIDATION-HANDLER] Target extracted: %@", target);
        
        NSData *dataToValidate = nil;
        NSString *segmentName = nil;
        BOOL isInit = NO;
        
        if ([target isEqualToString:@"init"]) {
            RLogDIY(@"[VALIDATION-HANDLER] Validating init segment");
            // Validate init segment
            dataToValidate = self.initializationSegmentData;
            segmentName = @"init.mp4";
            isInit = YES;
            RLogDIY(@"[VALIDATION-HANDLER] Init segment data size: %lu bytes", 
                    dataToValidate ? (unsigned long)dataToValidate.length : 0);
        } else if ([target isEqualToString:@"all"]) {
            RLogDIY(@"[VALIDATION-HANDLER] Sending validation dashboard");
            // Validate all segments
            [self sendValidationDashboard:clientSocket];
            return;
        } else if ([target hasPrefix:@"segment_"]) {
            RLogDIY(@"[VALIDATION-HANDLER] Looking for media segment: %@", target);
            // Validate specific segment
            [self.segmentLock lock];
            @try {
                RLogDIY(@"[VALIDATION-HANDLER] Total segments available: %lu", 
                        (unsigned long)self.segments.count);
                
                NSString *targetFilename = [target stringByAppendingString:@".m4s"];
                for (DIYSegmentInfo *segment in self.segments) {
                    RLogDIY(@"[VALIDATION-HANDLER] Checking segment: %@ (size: %lu)", 
                            segment.filename, (unsigned long)segment.data.length);
                    if ([segment.filename isEqualToString:targetFilename]) {
                        dataToValidate = segment.data;
                        segmentName = segment.filename;
                        RLogDIY(@"[VALIDATION-HANDLER] Found matching segment: %@ (%lu bytes)", 
                                segmentName, (unsigned long)dataToValidate.length);
                        break;
                    }
                }
            }
            @finally {
                [self.segmentLock unlock];
            }
            
            if (!dataToValidate) {
                RLogWarning(@"[VALIDATION-HANDLER] Segment not found: %@", target);
            }
        }
        
        if (!dataToValidate) {
            RLogError(@"[VALIDATION-HANDLER] No data to validate for target: %@", target);
            [self send404:clientSocket];
            return;
        }
        
        RLogDIY(@"[VALIDATION-HANDLER] Starting validation of %@ (%lu bytes)", 
                segmentName, (unsigned long)dataToValidate.length);
        
        // Log first 32 bytes as hex for debugging
        if (dataToValidate.length >= 32) {
            const uint8_t *bytes = dataToValidate.bytes;
            NSMutableString *hexStr = [NSMutableString string];
            for (int i = 0; i < 32; i++) {
                [hexStr appendFormat:@"%02X ", bytes[i]];
                if ((i + 1) % 16 == 0) [hexStr appendString:@"\n"];
            }
            RLogDIY(@"[VALIDATION-HANDLER] First 32 bytes of %@:\n%@", segmentName, hexStr);
        }
        
        // Perform validation with exception handling
        RptrSegmentValidationResult *result = nil;
        @try {
            RLogDIY(@"[VALIDATION-HANDLER] Calling validator for %@ segment", isInit ? @"init" : @"media");
            // Use quick validation for debug endpoint
            result = [RptrSegmentValidator quickValidateSegment:dataToValidate];
            RLogDIY(@"[VALIDATION-HANDLER] Validation completed successfully");
        }
        @catch (NSException *validationException) {
            RLogError(@"[VALIDATION-HANDLER] EXCEPTION during validation: %@", validationException);
            RLogError(@"[VALIDATION-HANDLER] Exception reason: %@", validationException.reason);
            RLogError(@"[VALIDATION-HANDLER] Exception userInfo: %@", validationException.userInfo);
            
            // Create a failed result
            result = [[RptrSegmentValidationResult alloc] init];
            result.isValid = NO;
            [result.errors addObject:[NSString stringWithFormat:@"Validation crashed: %@", validationException.reason]];
        }
        
        if (!result) {
            RLogError(@"[VALIDATION-HANDLER] Validation returned nil result");
            result = [[RptrSegmentValidationResult alloc] init];
            result.isValid = NO;
            [result.errors addObject:@"Validation failed to produce result"];
        }
        
        // Log validation results
    RLogDIY(@"[VALIDATION] ========== %@ ==========", segmentName);
    RLogDIY(@"[VALIDATION] Status: %@", result.isValid ? @"VALID" : @"INVALID");
    RLogDIY(@"[VALIDATION] Size: %lu bytes", (unsigned long)dataToValidate.length);
    
    // Log errors
    if (result.errors.count > 0) {
        RLogError(@"[VALIDATION] ERRORS:");
        for (NSString *error in result.errors) {
            RLogError(@"[VALIDATION]   - %@", error);
        }
    }
    
    // Log warnings - commented out for new validator
    // if (result.warnings.count > 0) {
    //     RLogWarning(@"[VALIDATION] WARNINGS:");
    //     for (NSString *warning in result.warnings) {
    //         RLogWarning(@"[VALIDATION]   - %@", warning);
    //     }
    // }
    
    // Log info
    RLogDIY(@"[VALIDATION] INFO:");
    for (NSString *key in result.info) {
        RLogDIY(@"[VALIDATION]   %@: %@", key, result.info[key]);
    }
    
    // Log box structure summary - commented out for new validator
    // if (result.boxTree) {
    //     RLogDIY(@"[VALIDATION] BOX STRUCTURE:");
    //     for (RptrBoxInfo *box in result.boxTree.children) {
    //         [self logBoxStructure:box indent:1];
    //     }
    // }
    
    RLogDIY(@"[VALIDATION] ========== END %@ ==========", segmentName);
    
    // Generate HTML report with exception handling
    @try {
        RLogDIY(@"[VALIDATION-HANDLER] Generating HTML report");
        // Simple HTML report for now
        NSString *html = [NSString stringWithFormat:@"<html><body><h1>%@</h1><p>Valid: %@</p><p>Errors: %@</p></body></html>",
                          segmentName, result.isValid ? @"YES" : @"NO", 
                          [result.errors componentsJoinedByString:@", "]];
        NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
        
        NSString *response = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\n"
            @"Content-Type: text/html; charset=utf-8\r\n"
            @"Content-Length: %lu\r\n"
            @"Cache-Control: no-cache\r\n"
            @"\r\n",
            (unsigned long)htmlData.length];
        
        send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
        send(clientSocket, htmlData.bytes, htmlData.length, MSG_NOSIGNAL);
        
        RLogDIY(@"[VALIDATION-HANDLER] Sent validation report for %@: %@ (%lu bytes)", 
                segmentName, result.isValid ? @"VALID" : @"INVALID", (unsigned long)htmlData.length);
    }
    @catch (NSException *reportException) {
        RLogError(@"[VALIDATION-HANDLER] EXCEPTION generating report: %@", reportException);
        
        // Send simple error response
        NSString *errorHTML = [NSString stringWithFormat:
            @"<html><body><h1>Validation Error</h1>"
            @"<p>Failed to generate report for %@</p>"
            @"<p>Exception: %@</p></body></html>",
            segmentName, reportException.reason];
        NSData *errorData = [errorHTML dataUsingEncoding:NSUTF8StringEncoding];
        
        NSString *response = [NSString stringWithFormat:
            @"HTTP/1.1 500 Internal Server Error\r\n"
            @"Content-Type: text/html; charset=utf-8\r\n"
            @"Content-Length: %lu\r\n"
            @"\r\n",
            (unsigned long)errorData.length];
        
        send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
        send(clientSocket, errorData.bytes, errorData.length, MSG_NOSIGNAL);
    }
    }
    @catch (NSException *exception) {
        RLogError(@"[VALIDATION-HANDLER] FATAL EXCEPTION in handleValidationRequest: %@", exception);
        RLogError(@"[VALIDATION-HANDLER] Stack trace: %@", [exception callStackSymbols]);
        
        // Send error response
        NSString *errorResponse = @"HTTP/1.1 500 Internal Server Error\r\n"
                                 @"Content-Type: text/plain\r\n"
                                 @"Content-Length: 25\r\n"
                                 @"\r\n"
                                 @"Validation system error\r\n";
        send(clientSocket, [errorResponse UTF8String], errorResponse.length, MSG_NOSIGNAL);
    }
}

// Commented out - old validation code
/*
- (void)logBoxStructure:(RptrBoxInfo *)box indent:(NSInteger)indent {
    NSString *padding = [@"" stringByPaddingToLength:indent * 2 withString:@" " startingAtIndex:0];
    RLogDIY(@"[VALIDATION] %@%@ (size: %u, offset: %u)", padding, box.type, box.size, box.offset);
    
    for (RptrBoxInfo *child in box.children) {
        [self logBoxStructure:child indent:indent + 1];
    }
}
*/

- (void)sendValidationDashboard:(int)clientSocket {
    NSMutableString *html = [NSMutableString string];
    
    [html appendString:@"<!DOCTYPE html><html><head>"];
    [html appendString:@"<title>Segment Validation Dashboard</title>"];
    [html appendString:@"<style>"];
    [html appendString:@"body { font-family: Arial, sans-serif; background: #1e1e1e; color: #d4d4d4; padding: 20px; }"];
    [html appendString:@"h1 { color: #4ec9b0; }"];
    [html appendString:@".segment-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px; }"];
    [html appendString:@".segment-card { background: #2d2d30; padding: 15px; border-radius: 5px; }"];
    [html appendString:@".segment-card:hover { background: #3e3e42; }"];
    [html appendString:@"a { color: #569cd6; text-decoration: none; }"];
    [html appendString:@"a:hover { text-decoration: underline; }"];
    [html appendString:@".init { border-left: 3px solid #dcdcaa; }"];
    [html appendString:@".media { border-left: 3px solid #4ec9b0; }"];
    [html appendString:@".size { color: #808080; font-size: 0.9em; }"];
    [html appendString:@".status { margin-top: 20px; padding: 10px; background: #252526; border-radius: 5px; }"];
    [html appendString:@"</style></head><body>"];
    
    [html appendString:@"<h1>Segment Validation Dashboard</h1>"];
    
    // Status info
    [html appendString:@"<div class='status'>"];
    [html appendFormat:@"<p>Streaming: %@</p>", self.isStreaming ? @"YES" : @"NO"];
    [html appendFormat:@"<p>Random Path: %@</p>", self.randomPath ?: @"None"];
    [html appendFormat:@"<p>Init Segment: %@ bytes</p>", 
           self.initializationSegmentData ? @(self.initializationSegmentData.length) : @"None"];
    
    [self.segmentLock lock];
    [html appendFormat:@"<p>Active Segments: %lu</p>", (unsigned long)self.segments.count];
    [self.segmentLock unlock];
    [html appendString:@"</div>"];
    
    [html appendString:@"<h2>Segments</h2>"];
    [html appendString:@"<div class='segment-list'>"];
    
    // Init segment
    if (self.initializationSegmentData) {
        [html appendString:@"<div class='segment-card init'>"];
        [html appendString:@"<a href='/debug/validate/init'>init.mp4</a>"];
        [html appendFormat:@"<div class='size'>%lu bytes</div>", 
               (unsigned long)self.initializationSegmentData.length];
        [html appendString:@"</div>"];
    }
    
    // Media segments
    [self.segmentLock lock];
    for (DIYSegmentInfo *segment in self.segments) {
        NSString *name = [segment.filename stringByReplacingOccurrencesOfString:@".m4s" withString:@""];
        [html appendString:@"<div class='segment-card media'>"];
        [html appendFormat:@"<a href='/debug/validate/%@'>%@</a>", name, segment.filename];
        [html appendFormat:@"<div class='size'>%lu bytes | %.2fs</div>", 
               (unsigned long)segment.data.length, segment.duration];
        [html appendString:@"</div>"];
    }
    [self.segmentLock unlock];
    
    [html appendString:@"</div>"];
    [html appendString:@"</body></html>"];
    
    NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: text/html; charset=utf-8\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: no-cache\r\n"
        @"\r\n",
        (unsigned long)htmlData.length];
    
    send(clientSocket, [response UTF8String], response.length, MSG_NOSIGNAL);
    send(clientSocket, htmlData.bytes, htmlData.length, MSG_NOSIGNAL);
    
    RLogDIY(@"[DIY-HLS] Sent validation dashboard");
}

#pragma mark - Streaming Control

- (BOOL)startStreaming {
    if (self.isStreaming) {
        return YES;
    }
    
    if (![self.encoder startEncoding]) {
        RLogError(@"[DIY-HLS] Failed to start video encoder");
        return NO;
    }
    
    // Start UDP logging session
    [[RptrUDPLogger sharedLogger] startNewSession];
    RLogDIY(@"[DIY-HLS] Started UDP logging session");
    
    // Reset muxer stream start time for new stream
    [self.muxer resetStreamStartTime];
    
    self.isStreaming = YES;
    self.streamStartTime = [NSDate date];
    self.totalSegments = 0;
    self.droppedFrames = 0;
    
    // Clear old segments
    [self.segmentLock lock];
    [self.segments removeAllObjects];
    self.mediaSequenceNumber = 0;
    [self.segmentLock unlock];
    
    // Schedule segment timer
    self.segmentTimer = [NSTimer scheduledTimerWithTimeInterval:self.segmentDuration
                                                         target:self
                                                       selector:@selector(segmentTimerFired)
                                                       userInfo:nil
                                                        repeats:YES];
    
    RLogDIY(@"[DIY-HLS] Streaming started");
    
    return YES;
}

- (void)stopStreaming {
    if (!self.isStreaming) {
        return;
    }
    
    self.isStreaming = NO;
    
    [self.segmentTimer invalidate];
    self.segmentTimer = nil;
    
    [self.encoder stopEncoding];
    
    // Finalize any pending segment
    [self finalizeCurrentSegment];
    
    // End UDP logging session
    [[RptrUDPLogger sharedLogger] endSession];
    RLogDIY(@"[DIY-HLS] Ended UDP logging session");
    
    RLogDIY(@"[DIY-HLS] Streaming stopped");
    
    if ([self.delegate respondsToSelector:@selector(diyServerDidStop:)]) {
        [self.delegate diyServerDidStop:self];
    }
}

#pragma mark - Frame Processing

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isStreaming) {
        return;
    }
    
    [self.encoder encodeVideoSampleBuffer:sampleBuffer];
}

- (void)processPixelBuffer:(CVPixelBufferRef)pixelBuffer
          presentationTime:(CMTime)presentationTime {
    if (!self.isStreaming) {
        return;
    }
    
    CMTime duration = CMTimeMake(1, (int32_t)self.frameRate);
    [self.encoder encodePixelBuffer:pixelBuffer 
                   presentationTime:presentationTime 
                           duration:duration];
}


#pragma mark - VideoToolbox Encoder Delegate

- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncodeParameterSets:(NSData *)sps pps:(NSData *)pps {
    dispatch_async(self.segmentQueue, ^{
        // Save parameter sets
        self.sps = sps;
        self.pps = pps;
        
        // Update muxer with parameter sets
        RptrFMP4TrackConfig *videoTrack = [[RptrFMP4TrackConfig alloc] init];
        videoTrack.trackID = 1;
        videoTrack.mediaType = @"video";
        videoTrack.width = self.width;
        videoTrack.height = self.height;
        videoTrack.sps = sps;
        videoTrack.pps = pps;
        videoTrack.timescale = 90000; // 90kHz standard for video (matches PTS/DTS)
        
        [self.muxer removeAllTracks];
        [self.muxer addTrack:videoTrack];
        
        // Generate init segment
        self.initializationSegmentData = [self.muxer createInitializationSegment];
        
        RLogDIY(@"[DIY-HLS] Generated init segment: %lu bytes", 
                (unsigned long)self.initializationSegmentData.length);
        
        // Log detailed structure of init segment
        NSString *initBoxStructure = [RptrSegmentValidator detailedBoxStructure:self.initializationSegmentData];
        RLogDIY(@"[DIY-HLS] Init segment structure:\n%@", initBoxStructure);
        
        // Save init segment to file for analysis with timestamp
        NSString *initPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"init_segment_%u.mp4", 
                               (unsigned int)[[NSDate date] timeIntervalSince1970]]];
        [self.initializationSegmentData writeToFile:initPath atomically:YES];
        RLogDIY(@"[DIY-HLS] Init segment saved to: %@", initPath);
        
        if ([self.delegate respondsToSelector:@selector(diyServer:didGenerateInitSegment:)]) {
            [self.delegate diyServer:self didGenerateInitSegment:self.initializationSegmentData];
        }
    });
}

- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncodeFrame:(RptrEncodedFrame *)frame {
    dispatch_async(self.segmentQueue, ^{
        // Check if we need to start a new segment (on keyframe)
        // Only split on keyframe if we have accumulated enough frames for a valid segment
        if (frame.isKeyframe && self.currentSegmentFrames.count > 0) {
            RptrEncodedFrame *firstFrame = self.currentSegmentFrames.firstObject;
            CMTime elapsed = CMTimeSubtract(frame.presentationTime, firstFrame.presentationTime);
            double elapsedSeconds = CMTimeGetSeconds(elapsed);
            
            // Only create new segment if current one is at least 0.5 seconds
            // This prevents tiny 1-frame segments
            if (elapsedSeconds >= 0.5) {
                [self finalizeCurrentSegment];
            }
        }
        
        // Add frame to current segment
        [self.currentSegmentFrames addObject:frame];
        
        // Update segment start time
        if (self.currentSegmentFrames.count == 1) {
            self.segmentStartTime = frame.presentationTime;
            RLogDIY(@"[DIY-HLS] Started segment %u at %.3f", 
                    self.currentSequenceNumber,
                    CMTimeGetSeconds(self.segmentStartTime));
        }
    });
}

- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncounterError:(NSError *)error {
    RLogError(@"[DIY-HLS] Video encoder error: %@", error);
    
    if ([self.delegate respondsToSelector:@selector(diyServer:didEncounterError:)]) {
        [self.delegate diyServer:self didEncounterError:error];
    }
}

#pragma mark - Segment Management

- (void)segmentTimerFired {
    // Force keyframe for next segment boundary
    [self.encoder forceKeyframe];
    RLogDIY(@"[DIY-HLS] Segment timer fired - forcing keyframe");
}

- (void)finalizeCurrentSegment {
    if (self.currentSegmentFrames.count == 0) {
        return;
    }
    
    // Convert frames to samples for muxer
    NSMutableArray<RptrFMP4Sample *> *samples = [NSMutableArray array];
    
    // Convert video frames to samples
    for (RptrEncodedFrame *frame in self.currentSegmentFrames) {
        RptrFMP4Sample *sample = [[RptrFMP4Sample alloc] init];
        sample.data = frame.data;
        sample.presentationTime = frame.presentationTime;
        sample.decodeTime = frame.decodeTime;
        sample.duration = frame.duration;
        sample.isSync = frame.isKeyframe;
        sample.trackID = 1; // Video track ID
        
        [samples addObject:sample];
    }
    
    // Calculate segment duration
    RptrEncodedFrame *firstFrame = self.currentSegmentFrames.firstObject;
    RptrEncodedFrame *lastFrame = self.currentSegmentFrames.lastObject;
    CMTime duration = CMTimeSubtract(lastFrame.presentationTime, firstFrame.presentationTime);
    NSTimeInterval segmentDuration = 0;
    
    if (CMTIME_IS_VALID(duration) && CMTIME_IS_VALID(lastFrame.duration)) {
        segmentDuration = CMTimeGetSeconds(duration) + CMTimeGetSeconds(lastFrame.duration);
    } else {
        // Fallback: estimate based on frame count and frame rate
        segmentDuration = (double)self.currentSegmentFrames.count / (double)self.frameRate;
        RLogDIY(@"[DIY-HLS] Invalid duration, using estimate: %.3fs", segmentDuration);
    }
    
    // Create media segment
    NSData *segmentData = [self.muxer createMediaSegmentWithSamples:samples
                                                      sequenceNumber:self.currentSequenceNumber
                                                       baseMediaTime:self.segmentStartTime];
    
    if (segmentData) {
        // Create segment info
        DIYSegmentInfo *segment = [[DIYSegmentInfo alloc] init];
        segment.filename = [NSString stringWithFormat:@"segment_%u.m4s", self.currentSequenceNumber];
        segment.data = segmentData;
        segment.duration = segmentDuration;
        segment.sequenceNumber = self.currentSequenceNumber;
        segment.createdAt = [NSDate date];
        
        // Add to playlist
        [self.segmentLock lock];
        [self.segments addObject:segment];
        
        // Maintain window size
        while (self.segments.count > self.playlistWindowSize) {
            self.mediaSequenceNumber++;
            [self.segments removeObjectAtIndex:0];
        }
        [self.segmentLock unlock];
        
        RLogDIY(@"[DIY-HLS] Finalized segment %u: %.3fs, %lu frames, %lu bytes",
                self.currentSequenceNumber,
                segmentDuration,
                (unsigned long)self.currentSegmentFrames.count,
                (unsigned long)segmentData.length);
        
        // Auto-validate segment with comprehensive iOS native validation
        // Do full validation on first 10 segments and every 10th segment after that
        BOOL doFullValidation = (self.currentSequenceNumber <= 10) || (self.currentSequenceNumber % 10 == 0);
        
        if (doFullValidation) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                // Save combined init+media segment for segment 1 for debugging
                if (self.currentSequenceNumber == 1) {
                    NSMutableData *combined = [NSMutableData dataWithData:self.initializationSegmentData];
                    [combined appendData:segmentData];
                    NSString *combinedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                             [NSString stringWithFormat:@"combined_segment_%u.mp4", 
                                              (unsigned int)[[NSDate date] timeIntervalSince1970]]];
                    [combined writeToFile:combinedPath atomically:YES];
                    RLogDIY(@"[DEBUG] Saved combined init+media segment to: %@", combinedPath);
                }
                
                RptrSegmentValidationResult *validationResult = [RptrSegmentValidator validateSegment:segmentData 
                                                                                          initSegment:self.initializationSegmentData
                                                                                       sequenceNumber:self.currentSequenceNumber];
                if (validationResult.isValid) {
                    RLogDIY(@"[AUTO-VALIDATE] Segment %u: VALID", self.currentSequenceNumber);
                    RLogDIY(@"[AUTO-VALIDATE] tfdt: %@, NALUs: %@, first_nalu: %@", 
                            validationResult.info[@"tfdt_seconds"],
                            validationResult.info[@"nalu_count"],
                            validationResult.info[@"first_nalu_type_name"]);
                } else {
                    RLogError(@"[AUTO-VALIDATE] Segment %u: INVALID - %@", 
                             self.currentSequenceNumber, 
                             [validationResult.errors componentsJoinedByString:@", "]);
                    RLogError(@"[AUTO-VALIDATE] iOS native parsers cannot read our segments!");
                    
                    // Log more details for debugging
                    RLogError(@"[AUTO-VALIDATE] tfdt_seconds: %@", validationResult.info[@"tfdt_seconds"]);
                    RLogError(@"[AUTO-VALIDATE] moof_found: %@", validationResult.info[@"moof_found"]);
                    RLogError(@"[AUTO-VALIDATE] mdat_found: %@", validationResult.info[@"mdat_found"]);
                    RLogError(@"[AUTO-VALIDATE] nalu_count: %@", validationResult.info[@"nalu_count"]);
                    RLogError(@"[AUTO-VALIDATE] first_nalu_type_name: %@", validationResult.info[@"first_nalu_type_name"]);
                }
            });
        } else {
            // Quick validation for other segments
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                RptrSegmentValidationResult *validationResult = [RptrSegmentValidator quickValidateSegment:segmentData];
                if (!validationResult.isValid) {
                    RLogError(@"[AUTO-VALIDATE] Segment %u: Quick validation failed - %@", 
                             self.currentSequenceNumber, 
                             [validationResult.errors componentsJoinedByString:@", "]);
                } else {
                    // Log success with key info even for quick validation
                    RLogDIY(@"[AUTO-VALIDATE] Segment %u: Quick validation PASSED - tfdt: %@s", 
                            self.currentSequenceNumber,
                            validationResult.info[@"tfdt_seconds"]);
                }
            });
        }
        
        // Notify delegate
        if ([self.delegate respondsToSelector:@selector(diyServer:didGenerateMediaSegment:duration:sequenceNumber:)]) {
            [self.delegate diyServer:self 
               didGenerateMediaSegment:segmentData
                              duration:segmentDuration
                        sequenceNumber:self.currentSequenceNumber];
        }
        
        self.currentSequenceNumber++;
        self.totalSegments++;
    }
    
    // Clear current segment
    [self.currentSegmentFrames removeAllObjects];
}

#pragma mark - Statistics

- (NSDictionary *)statistics {
    NSTimeInterval uptime = self.streamStartTime ? 
        [[NSDate date] timeIntervalSinceDate:self.streamStartTime] : 0;
    
    return @{
        @"isStreaming": @(self.isStreaming),
        @"uptime": @(uptime),
        @"totalSegments": @(self.totalSegments),
        @"currentSegments": @(self.segments.count),
        @"droppedFrames": @(self.droppedFrames),
        @"encoderActive": @(self.encoder.isEncoding)
    };
}

@end