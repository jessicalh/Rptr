//
//  HLSAssetWriterServer.m
//  Rptr
//
//  Production-ready HLS (HTTP Live Streaming) Server Implementation
//  
//  Architecture Overview:
//  This class implements a complete HLS server using AVAssetWriter for encoding
//  and a custom HTTP server for content delivery. It uses fragmented MP4 (fMP4)
//  format which provides better compression and quality compared to traditional
//  MPEG-TS segments.
//
//  Key Components:
//  1. HTTP Server - Handles client connections and serves HLS content
//  2. AVAssetWriter - Encodes video/audio into fMP4 segments
//  3. Segment Manager - Manages segment lifecycle and playlist generation
//  4. Memory Manager - Handles segment storage and cleanup
//
//  Thread Safety:
//  - Uses multiple dispatch queues for thread isolation
//  - Concurrent queues with barriers for read/write operations
//  - Atomic properties for cross-thread access
//
//  Performance Optimizations:
//  - In-memory segment storage to avoid disk I/O
//  - Efficient buffer management
//  - Lazy segment cleanup based on memory pressure
//

#import "HLSAssetWriterServer.h"
#import "RptrLogger.h"
#import "RptrUDPLogger.h"
#import "RptrConstants.h"
#import "RptrDiagnostics.h"
#import "HLSSegmentObserver.h"
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>

#pragma mark - Configuration

// URL Generation - Always uses randomized paths for security
// URLs:
//   View: http://localhost:8080/view/{randomPath}
//   Stream: http://localhost:8080/stream/{randomPath}/playlist.m3u8

#pragma mark - Helper Classes

/**
 * HLSClient
 * Represents a connected HTTP client consuming the HLS stream
 * Tracks client address and last activity time for connection management
 */
@interface HLSClient : NSObject
@property (nonatomic, strong) NSString *address;        // Client IP address
@property (nonatomic, assign) NSTimeInterval lastActivity; // Last request timestamp
@end

@implementation HLSClient
@end

/**
 * HLSSegmentInfo
 * Metadata for an HLS segment
 * Stores all information needed to serve and manage segments
 */
@interface HLSSegmentInfo : NSObject
@property (nonatomic, strong) NSString *filename;       // Segment filename (e.g., "segment0.m4s")
@property (nonatomic, strong) NSString *path;           // Full path to segment file (deprecated - using in-memory)
@property (nonatomic, assign) CMTime duration;          // Actual duration of the segment
@property (nonatomic, assign) NSInteger sequenceNumber; // Sequence number for playlist
@property (nonatomic, strong) NSDate *createdAt;        // Creation timestamp for cleanup
@property (nonatomic, assign) NSUInteger fileSize;      // Size in bytes for memory management
@property (nonatomic, strong) NSString *segmentID;      // Unique ID for tracing segment lifecycle
@end

@implementation HLSSegmentInfo
@end

/**
 * HLSAssetWriterServer Private Interface
 * 
 * Internal properties and methods for HLS server implementation
 * Organized by functional areas for clarity
 */
@interface HLSAssetWriterServer () <NSStreamDelegate>

#pragma mark - HTTP Server Properties
// Core HTTP server infrastructure
@property (nonatomic, strong) dispatch_queue_t serverQueue;     // Serial queue for server operations
@property (nonatomic, strong) dispatch_queue_t propertyQueue;   // Concurrent queue for property access
@property (nonatomic, assign) int serverSocket;                 // BSD socket for HTTP server
@property (atomic, assign) BOOL running;                        // Server running state (atomic for thread safety)
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, HLSClient *> *clients; // Active client connections
@property (nonatomic, strong) dispatch_queue_t clientsQueue;    // Concurrent queue for client management

#pragma mark - AVAssetWriter Properties
// Video/Audio encoding infrastructure
@property (nonatomic, strong) dispatch_queue_t writerQueue;     // Serial queue for writer operations
@property (nonatomic, strong) AVAssetWriter *assetWriter;       // Core video/audio encoder
@property (nonatomic, strong) AVAssetWriterInput *videoInput;   // Video input for H.264 encoding
@property (nonatomic, strong) AVAssetWriterInput *audioInput;   // Audio input for AAC encoding
@property (nonatomic, assign) BOOL isWriting;                   // Writer active state
@property (nonatomic, assign) BOOL sessionStarted;              // Encoding session state

#pragma mark - Segment Management Properties
// HLS segment lifecycle management
@property (nonatomic, strong) NSString *baseDirectory;          // Base directory for HLS files
@property (nonatomic, strong) NSString *segmentDirectory;       // Subdirectory for segments
@property (nonatomic, strong) NSMutableArray<HLSSegmentInfo *> *segments; // Segment metadata array
@property (nonatomic, strong) NSString *initializationSegmentPath; // Path to init segment (deprecated)
@property (nonatomic, assign) NSInteger currentSegmentIndex;    // Current segment being written
@property (nonatomic, assign) NSInteger mediaSequenceNumber;    // HLS media sequence counter

#pragma mark - In-Memory Segment Storage
// Memory-based segment storage for performance
@property (nonatomic, strong) NSData *initializationSegmentData; // fMP4 initialization segment
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *segmentData; // Segment filename -> data
@property (nonatomic, strong) NSLock *segmentDataLock;          // Lock for segment data access
@property (nonatomic, strong) dispatch_queue_t segmentDataQueue; // Concurrent queue for segment data
@property (nonatomic, strong) dispatch_queue_t segmentsQueue;   // Concurrent queue for segment metadata
@property (nonatomic, assign) BOOL hasGeneratedInitSegment;     // Track if init segment has been generated
@property (nonatomic, strong) NSData *savedInitSegmentData;     // Preserved init segment for reuse
@property (nonatomic, strong) NSDictionary *savedVideoSettings; // Preserved video settings for consistency
@property (nonatomic, strong) NSDictionary *savedAudioSettings; // Preserved audio settings for consistency

#pragma mark - Timing and Synchronization
// Precise timing for segment boundaries
@property (nonatomic, assign) CMTime nextSegmentBoundary;       // Next segment start time
@property (nonatomic, assign) CMTime sessionStartTime;          // Encoding session start
@property (nonatomic, strong) NSTimer *segmentTimer;            // Timer for segment rotation
@property (nonatomic, strong) NSTimer *flushTimer;              // Timer for manual flush (Test 4)
@property (nonatomic, assign) BOOL waitingForKeyFrame;          // Waiting for IDR frame
@property (nonatomic, strong) NSDate *currentSegmentStartTime;  // Wall clock time for segment
@property (nonatomic, assign) BOOL isFinishing;                 // Currently finishing writer
@property (nonatomic, assign) CMTime lastProcessedTime;         // Last processed frame timestamp
@property (nonatomic, assign) CMTime originalSessionStartTime;  // Original session start for continuity

#pragma mark - Frame Queue System
// Queue frames during writer transitions to prevent drops
@property (nonatomic, strong) NSMutableArray *pendingVideoFrames; // Queued video frames during transition
@property (nonatomic, strong) NSMutableArray *pendingAudioFrames; // Queued audio frames during transition
@property (nonatomic, assign) BOOL isTransitioning;             // Currently transitioning between writers
@property (nonatomic, assign) BOOL hasRecentKeyframe;           // Detected keyframe recently

#pragma mark - Performance Monitoring
// Statistics and performance tracking
@property (nonatomic, assign) NSInteger framesProcessed;        // Total frames encoded
@property (nonatomic, assign) NSInteger framesDropped;          // Frames dropped due to timing
@property (nonatomic, assign) NSInteger lastKeyframeNumber;     // Frame number of last keyframe for QoE tracking

#pragma mark - Client Activity Tracking
// Monitor active clients for cleanup
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *activeClients; // Client IP -> last activity
@property (nonatomic, strong) NSTimer *clientCleanupTimer;      // Timer for inactive client cleanup

#pragma mark - Security and State
// Basic security and state management
@property (nonatomic, strong) NSString *previousRandomPath;     // Previous URL path for migration

@end

@implementation HLSAssetWriterServer

#pragma mark - Initialization and Lifecycle

/**
 * Designated initializer
 * Creates a new HLS server instance configured to run on the specified port
 * 
 * @param port The TCP port to bind the HTTP server to (0 for default 8080)
 * @return Configured HLSAssetWriterServer instance
 */
- (instancetype)initWithPort:(NSUInteger)port {
    self = [super init];
    if (self) {
        // Configure debug logging based on build configuration
        #ifdef DEBUG
        [RptrLogger setActiveAreas:RPTR_LOG_PROTOCOL_ONLY];
        [RptrLogger setLogLevel:RptrLogLevelInfo];
        #endif
        
        // Initialize server configuration
        _port = port ?: kRptrDefaultServerPort;
        
        // Create dispatch queues for thread isolation
        // Serial queues ensure operations execute in order
        _serverQueue = dispatch_queue_create([kRptrServerQueueName UTF8String], DISPATCH_QUEUE_SERIAL);
        _writerQueue = dispatch_queue_create([kRptrWriterQueueName UTF8String], DISPATCH_QUEUE_SERIAL);
        
        // Concurrent queues with barriers for efficient read/write access
        _propertyQueue = dispatch_queue_create([kRptrPropertyQueueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        _clientsQueue = dispatch_queue_create([kRptrClientsQueueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        _segmentDataQueue = dispatch_queue_create([kRptrSegmentDataQueueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        _segmentsQueue = dispatch_queue_create([kRptrSegmentsQueueName UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        // Initialize collections
        _clients = [NSMutableDictionary dictionary];
        _segments = [NSMutableArray array];
        _segmentData = [NSMutableDictionary dictionary];
        _segmentDataLock = [[NSLock alloc] init];
        _activeClients = [NSMutableDictionary dictionary];
        
        // Generate random path for basic URL obscurity
        // Not cryptographically secure - just prevents casual discovery
        _randomPath = [self generateRandomString:kRptrRandomPathLength];
        RLog(RptrLogAreaProtocol, @"Generated randomized URL path: %@", _randomPath);
        
        // Initialize default values
        _streamTitle = @"Share Stream";  // Default stream title
        _currentSegmentIndex = 0;        // Start with segment 0
        _mediaSequenceNumber = 0;        // HLS sequence starts at 0
        _waitingForKeyFrame = YES;       // Always start segments with keyframe
        _sessionStartTime = kCMTimeInvalid;
        _nextSegmentBoundary = kCMTimeZero;
        _sessionStarted = NO;
        _isFinishing = NO;
        
        // Initialize frame queue system
        _pendingVideoFrames = [NSMutableArray array];
        _pendingAudioFrames = [NSMutableArray array];
        _isTransitioning = NO;
        _hasRecentKeyframe = NO;
        _lastProcessedTime = kCMTimeInvalid;
        _originalSessionStartTime = kCMTimeInvalid;
        
        // Initialize with default quality settings
        _qualitySettings = [RptrVideoQualitySettings reliableSettings];
        
        // Setup file system directories
        [self setupDirectories];
        
        // Register for system notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

/**
 * Creates directory structure for HLS files
 * Uses temporary directory to avoid filling device storage
 * Cleans up any existing files from previous sessions
 */
- (void)setupDirectories {
    NSString *tempDir = NSTemporaryDirectory();
    self.baseDirectory = [tempDir stringByAppendingPathComponent:kRptrBaseDirectoryName];
    self.segmentDirectory = [self.baseDirectory stringByAppendingPathComponent:kRptrSegmentDirectoryName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error;
    
    // Clean up old directory if exists
    if ([fm fileExistsAtPath:self.baseDirectory]) {
        [fm removeItemAtPath:self.baseDirectory error:nil];
    }
    
    // Create fresh directories
    [fm createDirectoryAtPath:self.segmentDirectory
  withIntermediateDirectories:YES
                   attributes:nil
                        error:&error];
    
    if (error) {
        RLog(RptrLogAreaError, @"Failed to create directories: %@", error);
    }
}

#pragma mark - Server Control

/**
 * Starts the HTTP server and begins accepting connections
 * 
 * This method:
 * 1. Creates and configures a TCP socket
 * 2. Binds to all network interfaces on the specified port
 * 3. Begins listening for incoming connections
 * 4. Starts the accept loop on a background queue
 * 
 * @param error Output parameter for any errors that occur
 * @return YES if server started successfully, NO otherwise
 * 
 * @note This method is synchronous and thread-safe
 * @warning Server must be stopped before app termination
 */
- (BOOL)startServer:(NSError * __autoreleasing *)error {
    // Start new UDP logging session
    [[RptrUDPLogger sharedLogger] startNewSession];
    
    // Capture timing for ANR diagnosis (lightweight, no logging)
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
    // Ignore SIGPIPE globally (this can be done on main thread)
    signal(SIGPIPE, SIG_IGN);
    RLog(RptrLogAreaProtocol, @"SIGPIPE handler installed");
    
    // Quick check if already running
    if (self.running) {
        return YES;
    }
    
    // Add memory barrier to ensure proper ordering (fixes race condition)
    atomic_thread_fence(memory_order_seq_cst);
    
    // Create socket synchronously to check for errors immediately
    self.serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverSocket < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kRptrErrorDomainHLSServer code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        }
        return NO;
    }
    
    // Allow socket reuse
    int yes = 1;
    setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    
    // Set non-blocking mode to avoid ANR
    int flags = fcntl(self.serverSocket, F_GETFL, 0);
    fcntl(self.serverSocket, F_SETFL, flags | O_NONBLOCK);
    
    // Bind to port
    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons((uint16_t)self.port);
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(self.serverSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        close(self.serverSocket);
        if (error) {
            *error = [NSError errorWithDomain:kRptrErrorDomainHLSServer code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind socket"}];
        }
        return NO;
    }
    
    // Start listening
    if (listen(self.serverSocket, 10) < 0) {
        close(self.serverSocket);
        if (error) {
            *error = [NSError errorWithDomain:kRptrErrorDomainHLSServer code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to listen"}];
        }
        return NO;
    }
    
    self.running = YES;
    
    // Execute server setup directly on the server queue to ensure proper sequencing
    dispatch_async(self.serverQueue, ^{
        // Diagnostic: Track if we're blocking main thread
        CFAbsoluteTime acceptStartTime = CFAbsoluteTimeGetCurrent();
        
        // Setup asset writer synchronously to ensure it's ready before accepting connections
        RLog(RptrLogAreaProtocol, @"About to setup asset writer...");
        dispatch_sync(self.writerQueue, ^{
            [self setupAssetWriterSync];
        });
        RLog(RptrLogAreaProtocol, @"Asset writer setup complete");
        
        // Create initial empty playlist
        [self createInitialPlaylist];
        
        // Start accept loop on a different queue to avoid blocking
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self acceptLoop];
        });
        
        // Diagnostic: Log if this took too long
        CFAbsoluteTime setupDuration = CFAbsoluteTimeGetCurrent() - acceptStartTime;
        if (setupDuration > 0.1) {
            RLog(RptrLogAreaANR, @"Server setup took %.3f seconds", setupDuration);
        }
        
        // Start client cleanup timer on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.clientCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 
                                                                        target:self 
                                                                      selector:@selector(cleanupInactiveClients) 
                                                                      userInfo:nil 
                                                                       repeats:YES];
        });
        
        RLog(RptrLogAreaProtocol, @"Server started port:%lu path:%@", (unsigned long)self.port, self.randomPath);
        
        // Call delegate on main queue to avoid nested dispatches
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(hlsServerDidStart:)]) {
                NSString *url = [NSString stringWithFormat:@"http://localhost:%lu", (unsigned long)self.port];
                [self.delegate hlsServerDidStart:url];
            }
        });
    });
    
    // Diagnostic: Log total startup time
    CFAbsoluteTime totalStartupTime = CFAbsoluteTimeGetCurrent() - startTime;
    if (totalStartupTime > 0.5) {
        RLog(RptrLogAreaError, @"WARNING: Server startup took %.3f seconds (potential ANR)", totalStartupTime);
    }
    
    return YES;
}

- (void)stopStreaming {
    dispatch_async(self.writerQueue, ^{
        if (self.isWriting) {
            RLog(RptrLogAreaProtocol, @"Stopping streaming (keeping server running)");
            
            // Stop the manual flush timer for Test 4
            [self invalidateFlushTimer];
            
            [self stopAssetWriter];
        }
    });
}

- (void)prepareForStreaming {
    // Create initial playlist immediately so browsers don't get 404
    // Empty playlist is better than 404 - segments will come when streaming starts
    [self createInitialPlaylist];
    
    dispatch_async(self.writerQueue, ^{
        if (!self.isWriting && !self.assetWriter) {
            RLog(RptrLogAreaProtocol, @"Preparing asset writer for streaming");
            [self setupAssetWriter];
        }
    });
}

- (void)stopServer {
    // Set running to NO immediately to stop accepting new frames
    self.running = NO;
    
    dispatch_async(self.serverQueue, ^{
        
        // Stop client cleanup timer
        [self.clientCleanupTimer invalidate];
        self.clientCleanupTimer = nil;
        
        // Stop writer
        [self stopAssetWriter];
        
        // End UDP logging session
        [[RptrUDPLogger sharedLogger] endSession];
        
        // Stop segment timer
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopSegmentTimer];
        });
        
        // Close server socket
        if (self.serverSocket >= 0) {
            close(self.serverSocket);
            self.serverSocket = -1;
        }
        
        // Disconnect all clients
        NSArray *clientSockets = [self allClientSockets];
        for (NSNumber *socketNum in clientSockets) {
            close(socketNum.intValue);
        }
        [self removeAllClients];
        
        // Clean up segments
        [self cleanupAllSegments];
        
        RLog(RptrLogAreaProtocol, @"Server stopped");
        
        if ([self.delegate respondsToSelector:@selector(hlsServerDidStop)]) {
            [self.delegate hlsServerDidStop];
        }
    });
}

#pragma mark - Asset Writer Setup

- (AVMetadataItem *)metadataItemWithKey:(NSString *)key value:(NSString *)value {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.key = key;
    item.keySpace = AVMetadataKeySpaceCommon;
    item.value = value;
    return item;
}

- (void)setupAssetWriterSync {
    // Synchronous version for initial setup
    RLog(RptrLogAreaProtocol, @"setupAssetWriterSync: Starting...");
        NSError *error;
        
        // Check if we're recreating writer after forcing segment output
        BOOL isRecreation = self.hasGeneratedInitSegment;
        if (isRecreation) {
            RLog(RptrLogAreaProtocol, @"[WRITER-RECREATION] Recreating writer while preserving init segment");
        }
        
        // AVAssetWriter handles segmentation automatically via preferredOutputSegmentInterval
        // Delegate callbacks fire automatically when segments are ready
        
        // For delegate-based writing, no file needed but keep name for logging
        NSString *segmentName = [NSString stringWithFormat:@"segment_%03ld.m4s", (long)self.mediaSequenceNumber];
        RLog(RptrLogAreaProtocol, @"Starting delegate-based writing, initial segment: %@", segmentName);
        
        // Create asset writer with delegate-based fMP4 for HLS
        RLog(RptrLogAreaProtocol, @"Creating asset writer for HLS fMP4");
        
        // Use contentType for delegate-based delivery
        self.assetWriter = [[AVAssetWriter alloc] initWithContentType:UTTypeMPEG4Movie];
        if (self.assetWriter) {
            // Set Apple HLS profile for proper fMP4 output
            self.assetWriter.outputFileTypeProfile = AVFileTypeProfileMPEG4AppleHLS;
            self.assetWriter.delegate = self;
            // Set required initialSegmentStartTime for delegate-based output
            self.assetWriter.initialSegmentStartTime = kCMTimeZero;
            RLog(RptrLogAreaProtocol, @"Using delegate-based fMP4 with automatic segmentation");
            RLog(RptrLogAreaProtocol, @"Delegate set: %@", self.assetWriter.delegate ? @"YES" : @"NO");
        } else {
            RLog(RptrLogAreaError, @"Failed to create AVAssetWriter with contentType");
            return;
        }
        if (error) {
            RLog(RptrLogAreaError, @"Failed to create asset writer: %@", error);
            return;
        }
        RLog(RptrLogAreaProtocol, @"Asset writer created successfully, status: %ld", (long)self.assetWriter.status);
        
        // Configure for HLS with fragmented MP4
        self.assetWriter.shouldOptimizeForNetworkUse = YES;
        
        // CRITICAL: Set movieFragmentInterval to make segments independent
        // This ensures each segment can be decoded without depending on previous segments
        // For HLS.js compatibility, segments must be self-contained with their own moof/mdat boxes
        // Research shows this should match preferredOutputSegmentInterval
        self.assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(self.qualitySettings.segmentDuration, 600); // Use 600 timescale for precision
        
        // Set metadata for better streaming
        NSArray *metadata = @[
            [self metadataItemWithKey:AVMetadataCommonKeyTitle value:@"HLS Live Stream"],
            [self metadataItemWithKey:AVMetadataCommonKeyCreator value:@"Rptr"]
        ];
        self.assetWriter.metadata = metadata;
        
        // TEST 4: PASSTHROUGH MODE - Manual segment control
        // Set to indefinite so we can manually control with flushSegment
        self.assetWriter.preferredOutputSegmentInterval = kCMTimeIndefinite;
        RLog(RptrLogAreaProtocol, @"[TEST4] Set preferredOutputSegmentInterval to INDEFINITE");
        RLog(RptrLogAreaProtocol, @"[TEST4] Will use manual flushSegment() for segment control");
        
        // Schedule the manual flush timer for Test 4
        [self scheduleManualFlushTimer];
        
        // TEST 4: PASSTHROUGH MODE - No encoding
        // Configure video for passthrough (no compression)
        NSDictionary *videoSettings = nil; // nil = passthrough mode
        
        RLog(RptrLogAreaProtocol, @"[TEST4] PASSTHROUGH MODE - No video encoding");
        RLog(RptrLogAreaProtocol, @"[TEST4] Files will be larger but segmentation should work");
        RLog(RptrLogAreaProtocol, @"[TEST4] Can use flushSegment() for manual control");
        
        /* ORIGINAL ENCODING SETTINGS DISABLED FOR TEST 4
        // Reuse saved settings if this is a recreation to maintain codec consistency
        if (isRecreation && self.savedVideoSettings) {
            videoSettings = self.savedVideoSettings;
            RLog(RptrLogAreaProtocol, @"[WRITER-RECREATION] Reusing saved video settings for consistency");
        } else {
            videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(self.qualitySettings.videoWidth),
            AVVideoHeightKey: @(self.qualitySettings.videoHeight),
            AVVideoCompressionPropertiesKey: @{
                // Bitrate and quality settings
                AVVideoAverageBitRateKey: @(self.qualitySettings.videoBitrate),
                AVVideoQualityKey: @(self.qualitySettings.videoQuality),
                
                // Keyframe (IDR) settings for segment boundaries
                AVVideoMaxKeyFrameIntervalKey: @(self.qualitySettings.videoKeyFrameInterval),
                AVVideoMaxKeyFrameIntervalDurationKey: @(self.qualitySettings.videoKeyFrameDuration),
                
                // H.264 profile and encoding settings
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,    // Maximum compatibility
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCAVLC,             // Error resilient
                AVVideoAllowFrameReorderingKey: @(NO),                              // No B-frames
                
                // Frame rate settings
                AVVideoExpectedSourceFrameRateKey: @(self.qualitySettings.videoFrameRate),
                AVVideoAverageNonDroppableFrameRateKey: @(self.qualitySettings.videoFrameRate),
                
                // Pixel aspect ratio (square pixels)
                AVVideoPixelAspectRatioKey: @{
                    AVVideoPixelAspectRatioHorizontalSpacingKey: @(1),
                    AVVideoPixelAspectRatioVerticalSpacingKey: @(1)
                }
            }
        };
            // Save settings for future recreations
            self.savedVideoSettings = videoSettings;
            RLog(RptrLogAreaProtocol, @"[INIT-CONFIG] Saved video settings for future writer recreations");
        }
        */
        
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        if (!self.videoInput) {
            RLog(RptrLogAreaError, @"Failed to create video input!");
            return;
        }
        
        // Use identity transform - rotation is handled at capture level
        self.videoInput.transform = CGAffineTransformIdentity;
        RLog(RptrLogAreaProtocol, @"Using identity transform for segment %ld - rotation handled at capture", 
             (long)self.currentSegmentIndex);
        self.videoInput.expectsMediaDataInRealTime = YES;
        
        // CRITICAL for fMP4: Request sync samples at segment boundaries
        // This ensures each segment starts with a keyframe (IDR frame)
        self.videoInput.performsMultiPassEncodingIfSupported = YES;
        
        RLog(RptrLogAreaVideoParams, @"Created video input: %@", self.videoInput);
        
        if ([self.assetWriter canAddInput:self.videoInput]) {
            [self.assetWriter addInput:self.videoInput];
            RLog(RptrLogAreaVideoParams, @"Added video input to asset writer");
        } else {
            RLog(RptrLogAreaError, @"Cannot add video input to asset writer!");
            return;
        }
        
        // TEST 4: PASSTHROUGH MODE - No audio encoding
        NSDictionary *audioSettings = nil; // nil = passthrough mode
        
        RLog(RptrLogAreaProtocol, @"[TEST4] PASSTHROUGH MODE - No audio encoding");
        
        /* ORIGINAL AUDIO ENCODING DISABLED FOR TEST 4
        // Reuse saved settings if this is a recreation to maintain codec consistency
        if (isRecreation && self.savedAudioSettings) {
            audioSettings = self.savedAudioSettings;
            RLog(RptrLogAreaProtocol, @"[WRITER-RECREATION] Reusing saved audio settings for consistency");
        } else {
            audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),              // AAC-LC codec
            AVNumberOfChannelsKey: @(self.qualitySettings.audioChannels),
            AVSampleRateKey: @(self.qualitySettings.audioSampleRate),
            AVEncoderBitRateKey: @(self.qualitySettings.audioBitrate),
            AVEncoderAudioQualityKey: @(AVAudioQualityMedium)    // Balanced quality
        };
            // Save settings for future recreations
            self.savedAudioSettings = audioSettings;
            RLog(RptrLogAreaProtocol, @"[INIT-CONFIG] Saved audio settings for future writer recreations");
        }
        */
        
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioInput.expectsMediaDataInRealTime = YES;
        RLog(RptrLogAreaProtocol, @"[AUDIO CONFIG] Created audio input");
        RLog(RptrLogAreaVideoParams, @"[AUDIO CONFIG] Format: AAC");
        RLog(RptrLogAreaVideoParams, @"[AUDIO CONFIG] Sample Rate: 44100 Hz");
        RLog(RptrLogAreaVideoParams, @"[AUDIO CONFIG] Channels: 2");
        RLog(RptrLogAreaVideoParams, @"[AUDIO CONFIG] Bitrate: 64000 bps");
        
        // Add audio input to asset writer
        if ([self.assetWriter canAddInput:self.audioInput]) {
            [self.assetWriter addInput:self.audioInput];
            RLog(RptrLogAreaInfo, @"Added audio input to asset writer");
        } else {
            RLog(RptrLogAreaError, @"Cannot add audio input to asset writer!");
            return;  // Fail if we can't add audio input
        }
        
        // Start writing
        if ([self.assetWriter startWriting]) {
            self.waitingForKeyFrame = YES;
            self.sessionStarted = NO;  // Will start session when first frame arrives
            self.isFinishing = NO;     // Reset finishing flag for new writer
            
            RLog(RptrLogAreaProtocol, @"Asset writer started for segment %ld", (long)self.currentSegmentIndex);
            RLog(RptrLogAreaProtocol, @"Writer status after startWriting: %ld", (long)self.assetWriter.status);
            RLog(RptrLogAreaProtocol, @"Waiting for first frame to start session");
        } else {
            RLog(RptrLogAreaError, @"Failed to start writing: %@", self.assetWriter.error);
            RLog(RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
            RLog(RptrLogAreaError, @"Error domain: %@", self.assetWriter.error.domain);
            RLog(RptrLogAreaError, @"Error code: %ld", (long)self.assetWriter.error.code);
            RLog(RptrLogAreaError, @"Error userInfo: %@", self.assetWriter.error.userInfo);
            
            // Notify delegate of error
            if ([self.delegate respondsToSelector:@selector(hlsServer:didEncounterError:)]) {
                NSError *error = self.assetWriter.error ?: [NSError errorWithDomain:@"HLSServer" 
                                                                               code:100 
                                                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to start AVAssetWriter"}];
                [self.delegate hlsServer:self didEncounterError:error];
            }
        }
}

- (void)setupAssetWriter {
    // Async wrapper for segment rotation
    RLog(RptrLogAreaProtocol, @"setupAssetWriter: Starting async...");
    dispatch_async(self.writerQueue, ^{
        [self setupAssetWriterSync];
    });
}

- (void)stopAssetWriter {
    dispatch_async(self.writerQueue, ^{
        if (!self.isWriting || self.isFinishing) {
            RLog(RptrLogAreaProtocol, @"stopAssetWriter: Already stopped or finishing (isWriting=%d, isFinishing=%d)", 
                 self.isWriting, self.isFinishing);
            return;
        }
        
        self.isWriting = NO;
        self.sessionStarted = NO;
        
        // Only mark as finished if writer is in correct state
        if (self.assetWriter && self.assetWriter.status == AVAssetWriterStatusWriting) {
            self.isFinishing = YES;
            
            if (self.videoInput && self.videoInput.readyForMoreMediaData) {
                [self.videoInput markAsFinished];
            }
            if (self.audioInput && self.audioInput.readyForMoreMediaData) {
                [self.audioInput markAsFinished];
            }
            
            __weak typeof(self) weakSelf = self;
            [self.assetWriter finishWritingWithCompletionHandler:^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) {
                    RLog(RptrLogAreaProtocol, @"[WRITER] Finished writing - segments handled via delegate");
                    RLog(RptrLogAreaProtocol, @"[QoE] Writer session ended successfully");
                    // Segments are automatically handled via delegate callbacks
                    // No need to finalize manually
                    strongSelf.isFinishing = NO;
                }
            }];
        } else {
            RLog(RptrLogAreaError, @"Writer not in correct state to stop. Status: %ld", 
                  self.assetWriter ? (long)self.assetWriter.status : -1);
        }
    });
}

#pragma mark - Sample Buffer Processing

/**
 * Processes incoming video frames from the capture session
 * 
 * This method handles:
 * 1. Sample buffer validation and retention
 * 2. Segment boundary detection based on presentation time
 * 3. Keyframe detection for segment starts
 * 4. Frame dropping for performance
 * 5. Writing frames to the current segment
 * 
 * Thread Safety: Can be called from any thread, uses internal queues
 * Performance: Optimized for real-time processing with frame dropping
 * 
 * @param sampleBuffer The video sample buffer from AVCaptureVideoDataOutput
 * 
 * @note Sample buffers are retained/released automatically
 * @warning Must be called continuously to avoid segment timeouts
 */
- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    @autoreleasepool {
        if (!sampleBuffer) {
            return;
        }
        
        // Quick state check
        if (!self.running) {
            RLog(RptrLogAreaProtocol, @"Server not running, ignoring sample buffer");
            return;
        }
        
        // Validate sample buffer before processing
        if (!CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaError, @"WARNING: Invalid sample buffer received");
            return;
        }
        
        // Queue frames during transition instead of dropping
        if (self.isTransitioning) {
            CFRetain(sampleBuffer);
            [self.pendingVideoFrames addObject:(__bridge id)sampleBuffer];
            RLogDebug(@"[FRAME-QUEUE] Queued video frame during transition (total: %lu)", 
                     (unsigned long)self.pendingVideoFrames.count);
            return;
        }
        
        // Don't retain the buffer - process it immediately
        // The capture system needs these buffers back quickly for its pool
        
        // Quick check if we should process this frame
        if (!self.assetWriter || !self.videoInput || self.isFinishing) {
            return;
        }
        
        // Get timing information before async dispatch
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        BOOL isFirstFrame = !self.sessionStarted;
    
    // For the first frame, we need format information
    CMFormatDescriptionRef formatDesc = NULL;
    CMVideoDimensions dimensions = {0, 0};
    if (isFirstFrame) {
        formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
        }
    }
    
    // Check for key frame
    BOOL isKeyFrame = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync);
        isKeyFrame = (notSync == NULL) || !CFBooleanGetValue(notSync);
    }
    
    // Track keyframe for clean segment boundaries
    if (isKeyFrame) {
        self.hasRecentKeyframe = YES;
        RLogDebug(@"[KEYFRAME] Detected keyframe at time %.2f", CMTimeGetSeconds(presentationTime));
    }
    
    // Retain the buffer only for the duration of the append operation
    CFRetain(sampleBuffer);
    
    dispatch_async(self.writerQueue, ^{
        @try {
        // Validate sample buffer is still valid
        if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaError, @"ERROR: Sample buffer became invalid or nil");
            return;
        }
        
        // Check if we have a writer
        if (!self.assetWriter) {
            RLog(RptrLogAreaError, @"ERROR: No asset writer available!");
            return;
        }
        
        // Check if video input exists
        if (!self.videoInput) {
            RLog(RptrLogAreaError, @"ERROR: No video input available!");
            return;
        }
        
        // Defensive check for writer status
        NSAssert(self.assetWriter.status != AVAssetWriterStatusCancelled, @"Writer should not be cancelled");
        NSAssert(self.assetWriter.status != AVAssetWriterStatusUnknown || !self.sessionStarted, 
                 @"Writer in unknown state after session started");
        
        // Handle first frame - start the session
        if (isFirstFrame) {
            // Double-check that session hasn't been started by another thread
            if (self.sessionStarted) {
                RLog(RptrLogAreaProtocol, @"Session already started by another thread");
                return;
            } else {
                // Log buffer dimensions for first frame
                if (dimensions.width > 0 && dimensions.height > 0) {
                    RLog(RptrLogAreaProtocol, @"Stream started: %dx%d", dimensions.width, dimensions.height);
                    // Video should already be in landscape orientation from AVCaptureConnection
                }
                
                // Check writer status
                if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
                    RLog(RptrLogAreaError, @"ERROR: Writer not started yet! Call startWriting first.");
                    return;
                } else if (self.assetWriter.status == AVAssetWriterStatusWriting) {
                    // Check if session is already started (could happen due to threading)
                    if (self.sessionStarted) {
                        RLog(RptrLogAreaProtocol, @"Session already started");
                        return;
                    }
                    
                    // Start the session with the actual frame timestamp
                    RLog(RptrLogAreaProtocol, @"First frame - starting session");
                    
                    // Ensure valid time
                    if (CMTIME_IS_INVALID(presentationTime)) {
                        RLog(RptrLogAreaError, @"ERROR: Invalid presentation time!");
                        return;
                    }
                    
                    // For delegate-based fMP4, align timing to ensure segments are independent
                    // Use the actual frame time to maintain sync
                    CMTime alignedTime = presentationTime;
                    
                    // Initialize timing - preserve original for tracking but use current frame for session
                    if (CMTIME_IS_INVALID(self.originalSessionStartTime)) {
                        // First time starting - save original time for tracking
                        self.originalSessionStartTime = alignedTime;
                        self.sessionStartTime = alignedTime;
                        self.nextSegmentBoundary = alignedTime;
                        RLog(RptrLogAreaProtocol, @"[SESSION-INIT] First session start time: %.2f", 
                             CMTimeGetSeconds(alignedTime));
                    } else {
                        // Continuing from previous session after recreation
                        // Use current frame time for new session to maintain continuity
                        self.sessionStartTime = presentationTime;
                        RLog(RptrLogAreaProtocol, @"[SESSION-CONTINUITY] Using frame time %.2f for new session (original: %.2f)", 
                             CMTimeGetSeconds(presentationTime), CMTimeGetSeconds(self.originalSessionStartTime));
                    }
                    
                    // Start the session with current frame time for proper alignment
                    CMTime sessionTime = presentationTime;
                    RLog(RptrLogAreaProtocol, @"Starting session at source time: %.2f", CMTimeGetSeconds(sessionTime));
                    RLog(RptrLogAreaProtocol, @"[TEST4] PASSTHROUGH MODE - Manual segment control");
                    @try {
                        [self.assetWriter startSessionAtSourceTime:sessionTime];
                        self.sessionStarted = YES;
                        self.isWriting = YES;
                        self.currentSegmentStartTime = [NSDate date];
                        RLog(RptrLogAreaProtocol, @"Session started successfully with frame timestamp");
                        RLog(RptrLogAreaProtocol, @"[TEST4] Will manually flush segments every 1 second");
                        
                        // Start segment timer (disabled for Test 2)
                        [self startSegmentTimer];
                    } @catch (NSException *exception) {
                        RLog(RptrLogAreaError, @"EXCEPTION starting session: %@", exception);
                        RLog(RptrLogAreaError, @"Writer status was: %ld", (long)self.assetWriter.status);
                        self.sessionStarted = NO;
                        return;
                    }
                } else {
                    // Writer may be in Completed state if we just recreated it after rotation
                    // Skip this frame and let the next one start the session properly
                    RLog(RptrLogAreaProtocol, @"[WRITER-STATE] Writer in state %ld, skipping frame", (long)self.assetWriter.status);
                    if (self.assetWriter.status == AVAssetWriterStatusFailed || self.assetWriter.error) {
                        RLog(RptrLogAreaError, @"Writer error: %@", self.assetWriter.error);
                    }
                    return;
                }
            }
        }
        
        // Check writer status
        if (self.assetWriter.status == AVAssetWriterStatusFailed) {
            RLog(RptrLogAreaError, @"Writer failed with error: %@", self.assetWriter.error);
            self.isWriting = NO;
            return;
        }
        
        if (self.assetWriter.status != AVAssetWriterStatusWriting) {
            RLog(RptrLogAreaError, @"Writer not ready, status: %ld", (long)self.assetWriter.status);
            return;
        }
        
        // TEST 4: Monitor passthrough mode with manual flush
        if (self.framesProcessed % 30 == 0) {
            NSTimeInterval timeSinceSegmentStart = self.currentSegmentStartTime ? 
                [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime] : 0;
            RLog(RptrLogAreaProtocol, @"[TEST4-MONITOR] Frame %ld, Time in segment: %.2fs (manual flush every 1.0s)", 
                 (long)self.framesProcessed, timeSinceSegmentStart);
        }
        
        
        // Comprehensive null checks before appending
        if (!self.videoInput) {
            RLog(RptrLogAreaError, @"ERROR: videoInput is nil!");
            return;
        }
        
        if (!sampleBuffer) {
            RLog(RptrLogAreaError, @"ERROR: sampleBuffer is nil!");
            return;
        }
        
        // Verify sample buffer is valid
        if (!CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaError, @"ERROR: sampleBuffer is invalid!");
            return;
        }
        
        // Check if we're in the middle of finishing the writer
        if (self.isFinishing) {
            RLog(RptrLogAreaProtocol, @"Skipping frame - writer is finishing");
            return;
        }
        
        // Check if input is ready
        if (self.videoInput.isReadyForMoreMediaData) {
            RLog(RptrLogAreaVideoParams, @"About to append sample buffer - videoInput: %@, sampleBuffer: %p", 
                  self.videoInput, sampleBuffer);
            
            @try {
                // Final validation before append
                if (!CMSampleBufferIsValid(sampleBuffer)) {
                    RLog(RptrLogAreaError, @"ERROR: Sample buffer invalid before append");
                    return;
                }
                
                BOOL success = [self.videoInput appendSampleBuffer:sampleBuffer];
                if (success) {
                    self.framesProcessed++;
                    // Track the last successfully processed time
                    self.lastProcessedTime = presentationTime;
                    
                    if (self.framesProcessed == 1) {
                        RLog(RptrLogAreaProtocol, @"Successfully appended first frame!");
                    } else if (self.framesProcessed % 30 == 0) {
                        RLog(RptrLogAreaVideoParams, @"Processed %ld frames", (long)self.framesProcessed);
                    }
                } else {
                    RLog(RptrLogAreaError, @"Failed to append sample buffer");
                    RLog(RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
                    RLog(RptrLogAreaError, @"Writer error: %@", self.assetWriter.error);
                    RLog(RptrLogAreaVideoParams, @"Video input readyForMoreMediaData: %@", self.videoInput.readyForMoreMediaData ? @"YES" : @"NO");
                    self.framesDropped++;
                    
                    // Check if writer failed
                    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                        RLog(RptrLogAreaError, @"Writer failed with error: %@", self.assetWriter.error);
                        RLog(RptrLogAreaError, @"Error code: %ld", (long)self.assetWriter.error.code);
                        RLog(RptrLogAreaError, @"Error domain: %@", self.assetWriter.error.domain);
                        self.isWriting = NO;
                        
                        // Try to restart writer immediately on error
                        RLog(RptrLogAreaError, @"Attempting to restart writer...");
                        // Delegate-based: counter incremented in assetWriter:didOutputSegmentData:
                        [self setupAssetWriter];
                    }
                }
            } @catch (NSException *exception) {
                RLog(RptrLogAreaError, @"EXCEPTION appending sample buffer: %@", exception);
                RLog(RptrLogAreaError, @"Exception reason: %@", exception.reason);
                RLog(RptrLogAreaError, @"Stack trace: %@", exception.callStackSymbols);
                self.framesDropped++;
            }
        } else {
            RLog(RptrLogAreaVideoParams, @"Video input not ready for more data");
            self.framesDropped++;
        }
        } @finally {
            // Always release the sample buffer
            if (sampleBuffer) {
                CFRelease(sampleBuffer);
            }
        }
    });
    } // End of @autoreleasepool
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    @autoreleasepool {
    if (!sampleBuffer) {
        return;
    }
    
    // Quick state check
    if (!self.running) {
        return;
    }
    
    // Validate sample buffer before processing
    if (!CMSampleBufferIsValid(sampleBuffer)) {
        RLog(RptrLogAreaError, @"WARNING: Invalid audio sample buffer received");
        return;
    }
    
    // Queue frames during transition instead of dropping
    if (self.isTransitioning) {
        CFRetain(sampleBuffer);
        [self.pendingAudioFrames addObject:(__bridge id)sampleBuffer];
        RLogDebug(@"[FRAME-QUEUE] Queued audio frame during transition (total: %lu)", 
                 (unsigned long)self.pendingAudioFrames.count);
        return;
    }
    
    // Quick check if we should process this frame
    if (!self.running || !self.sessionStarted || !self.audioInput || self.isFinishing) {
        return;
    }
    
    // Process on writer queue with minimal retention
    CFRetain(sampleBuffer);
    
    dispatch_async(self.writerQueue, ^{
        @try {
            // Quick validation before append
            if (!self.audioInput || self.isFinishing || !self.sessionStarted) {
                return;
            }
            
            // Check if audio input is ready
            if (self.audioInput.isReadyForMoreMediaData) {
                BOOL success = [self.audioInput appendSampleBuffer:sampleBuffer];
                if (!success) {
                    RLog(RptrLogAreaProtocol, @"Failed to append audio sample buffer");
                    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                        RLog(RptrLogAreaError, @"Audio append failed - writer error: %@", self.assetWriter.error);
                    }
                }
            }
        } @finally {
            // Always release the sample buffer
            if (sampleBuffer) {
                CFRelease(sampleBuffer);
            }
        }
    });
    } // End of @autoreleasepool
}



#pragma mark - Frame Queue Management

- (void)processQueuedFrames {
    RLog(RptrLogAreaProtocol, @"[FRAME-QUEUE] Processing queued frames - Video: %lu, Audio: %lu", 
         (unsigned long)self.pendingVideoFrames.count, (unsigned long)self.pendingAudioFrames.count);
    
    // Process video frames
    for (id frameObj in self.pendingVideoFrames) {
        CMSampleBufferRef frame = (__bridge CMSampleBufferRef)frameObj;
        if (CMSampleBufferIsValid(frame) && self.videoInput.readyForMoreMediaData) {
            [self.videoInput appendSampleBuffer:frame];
            self.framesProcessed++;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(frame);
            self.lastProcessedTime = pts;
            RLogDebug(@"[FRAME-QUEUE] Processed queued video frame at time %.2f", CMTimeGetSeconds(pts));
        }
        CFRelease(frame);
    }
    [self.pendingVideoFrames removeAllObjects];
    
    // Process audio frames
    for (id frameObj in self.pendingAudioFrames) {
        CMSampleBufferRef frame = (__bridge CMSampleBufferRef)frameObj;
        if (CMSampleBufferIsValid(frame) && self.audioInput.readyForMoreMediaData) {
            [self.audioInput appendSampleBuffer:frame];
        }
        CFRelease(frame);
    }
    [self.pendingAudioFrames removeAllObjects];
    
    RLog(RptrLogAreaProtocol, @"[FRAME-QUEUE] Finished processing queued frames");
}

- (void)rotateSegmentWithKeyframeCheck {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime];
    
    // Only rotate at proper boundaries
    if (elapsed >= self.qualitySettings.segmentDuration) {
        
        // Only wait for keyframe if we're very close to the target duration
        if (!self.hasRecentKeyframe && elapsed < self.qualitySettings.segmentDuration + 0.2) {
            RLogDebug(@"[SEGMENT-ROTATION] Waiting for keyframe (elapsed: %.2f)", elapsed);
            return; // Wait up to 0.2s for keyframe
        }
        
        // Don't rotate if we're already transitioning
        if (self.isTransitioning) {
            RLogDebug(@"[SEGMENT-ROTATION] Already transitioning, skipping");
            return;
        }
        
        RLog(RptrLogAreaProtocol, @"[SEGMENT-ROTATION] Starting rotation after %.2fs", elapsed);
        self.isTransitioning = YES;
        
        // Mark inputs as finished
        if (self.videoInput) {
            [self.videoInput markAsFinished];
        }
        if (self.audioInput) {
            [self.audioInput markAsFinished];
        }
        
        // Save current state
        CMTime savedLastTime = self.lastProcessedTime;
        CMTime savedSessionTime = self.sessionStartTime;
        
        __weak typeof(self) weakSelf = self;
        [self.assetWriter finishWritingWithCompletionHandler:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            dispatch_async(strongSelf.writerQueue, ^{
                RLog(RptrLogAreaProtocol, @"[SEGMENT-ROTATION] Writer finished, creating new writer");
                
                // Create new writer
                [strongSelf setupAssetWriterSync];
                
                RLog(RptrLogAreaProtocol, @"[SEGMENT-ROTATION] Writer status after setup: %ld", 
                     (long)strongSelf.assetWriter.status);
                
                // Calculate next frame time for session start
                CMTime nextTime = CMTIME_IS_VALID(savedLastTime) ? 
                    CMTimeAdd(savedLastTime, CMTimeMake(1, 30)) : // For 30fps
                    savedSessionTime;
                
                // Start session at next expected frame time
                // After startWriting, status should be Writing (1)
                if (strongSelf.assetWriter && strongSelf.assetWriter.status == AVAssetWriterStatusWriting) {
                    @try {
                        [strongSelf.assetWriter startSessionAtSourceTime:nextTime];
                        strongSelf.sessionStarted = YES;
                        strongSelf.currentSegmentStartTime = [NSDate date];
                        strongSelf.hasRecentKeyframe = NO;
                        
                        RLog(RptrLogAreaProtocol, @"[SEGMENT-ROTATION] Started new session at time %.2f", 
                             CMTimeGetSeconds(nextTime));
                        
                        // Process queued frames immediately
                        strongSelf.isTransitioning = NO;
                        [strongSelf processQueuedFrames];
                        
                    } @catch (NSException *exception) {
                        RLog(RptrLogAreaError, @"[SEGMENT-ROTATION] Failed to start session: %@", exception);
                        strongSelf.isTransitioning = NO;
                    }
                } else {
                    // Writer not ready yet, let first frame start the session
                    RLog(RptrLogAreaProtocol, @"[SEGMENT-ROTATION] Writer not ready (status: %ld), will start session on first frame", 
                         (long)strongSelf.assetWriter.status);
                    strongSelf.isTransitioning = NO;
                    // Don't start session here, let the first frame do it
                }
            });
        }];
    }
}

#pragma mark - Segment Timer

- (void)startSegmentTimer {
    // TEST 4: ENABLED - Manual flushSegment control
    RLog(RptrLogAreaProtocol, @"[TEST4] Segment timer ENABLED for manual flushSegment");
    RLog(RptrLogAreaProtocol, @"[TEST4] Will call flushSegment every 1 second");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.segmentTimer invalidate];
        self.segmentTimer = [NSTimer scheduledTimerWithTimeInterval:1.0  // Flush every 1 second
                                                              target:self
                                                            selector:@selector(manualFlushSegment)
                                                            userInfo:nil
                                                             repeats:YES];
        RLog(RptrLogAreaProtocol, @"[TEST4] Started manual flush timer");
    });
}

- (void)stopSegmentTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.segmentTimer invalidate];
        self.segmentTimer = nil;
        RLog(RptrLogAreaProtocol, @"[SEGMENT-TIMER] Stopped segment rotation timer");
    });
}

- (void)checkSegmentRotation {
    if (!self.isTransitioning && self.sessionStarted) {
        dispatch_async(self.writerQueue, ^{
            [self rotateSegmentWithKeyframeCheck];
        });
    }
}

#pragma mark - Playlist Management

- (void)createPlaceholderSegment {
    RLog(RptrLogAreaProtocol, @"Creating placeholder segment...");
    
    // Check if placeholder already exists
    [self.segmentDataLock lock];
    if ([self.segmentData objectForKey:@"placeholder.m4s"]) {
        [self.segmentDataLock unlock];
        RLog(RptrLogAreaProtocol, @"Placeholder segment already exists");
        return;
    }
    [self.segmentDataLock unlock];
    
    @autoreleasepool {
        // Create a simple video with a "Starting Stream..." message
        // We'll create a single frame video segment
        CGSize videoSize = CGSizeMake(1920, 1080);
        
        // Create a bitmap context
        UIGraphicsBeginImageContextWithOptions(videoSize, YES, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        
        // Fill with dark background
        [[UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0] setFill];
        CGContextFillRect(context, CGRectMake(0, 0, videoSize.width, videoSize.height));
        
        // Draw app icon if available
        UIImage *appIcon = [UIImage imageNamed:@"AppIcon"];
        if (appIcon) {
            CGFloat iconSize = 200;
            CGRect iconRect = CGRectMake((videoSize.width - iconSize) / 2, 
                                         (videoSize.height - iconSize) / 2 - 100,
                                         iconSize, iconSize);
            [appIcon drawInRect:iconRect];
        }
        
        // Draw text
        NSString *text = @"Starting Stream...";
        UIFont *font = [UIFont boldSystemFontOfSize:60];
        NSDictionary *attributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        CGSize textSize = [text sizeWithAttributes:attributes];
        CGRect textRect = CGRectMake((videoSize.width - textSize.width) / 2,
                                     (videoSize.height - textSize.height) / 2 + 150,
                                     textSize.width, textSize.height);
        [text drawInRect:textRect withAttributes:attributes];
        
        // Get the image
        UIImage *placeholderImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        // Convert to pixel buffer
        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *options = @{
            (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
        };
        CVPixelBufferCreate(kCFAllocatorDefault, 
                            videoSize.width, videoSize.height,
                            kCVPixelFormatType_32ARGB, 
                            (__bridge CFDictionaryRef)options,
                            &pixelBuffer);
        
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
        CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmapContext = CGBitmapContextCreate(pxdata, videoSize.width, videoSize.height,
                                                           8, CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                           rgbColorSpace, kCGImageAlphaNoneSkipFirst);
        CGContextDrawImage(bitmapContext, CGRectMake(0, 0, videoSize.width, videoSize.height), 
                          placeholderImage.CGImage);
        CGColorSpaceRelease(rgbColorSpace);
        CGContextRelease(bitmapContext);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        // Create video using AVAssetWriter
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"placeholder_temp.mp4"];
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        NSURL *outputURL = [NSURL fileURLWithPath:tempPath];
        
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL 
                                                           fileType:AVFileTypeMPEG4 
                                                              error:nil];
        
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(videoSize.width),
            AVVideoHeightKey: @(videoSize.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(self.qualitySettings.videoBitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            }
        };
        
        AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                             outputSettings:videoSettings];
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
                                                         assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                         sourcePixelBufferAttributes:nil];
        
        [writer addInput:writerInput];
        [writer startWriting];
        [writer startSessionAtSourceTime:kCMTimeZero];
        
        // Write multiple frames to create a 2-second video
        for (int i = 0; i < 60; i++) { // 2 seconds at 30fps
            CMTime presentationTime = CMTimeMake(i, 30);
            while (!writerInput.readyForMoreMediaData) {
                [NSThread sleepForTimeInterval:0.01];
            }
            [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
        }
        
        CVPixelBufferRelease(pixelBuffer);
        
        [writerInput markAsFinished];
        
        // Use dispatch_semaphore to wait for completion
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            // Read the generated file
            NSData *segmentData = [NSData dataWithContentsOfFile:tempPath];
            if (segmentData) {
                // Store in memory
                [self.segmentDataLock lock];
                [self.segmentData setObject:segmentData forKey:@"placeholder.m4s"];
                [self.segmentDataLock unlock];
                
                RLog(RptrLogAreaProtocol, @"Placeholder segment created: %lu bytes", 
                     (unsigned long)segmentData.length);
            }
            
            // Clean up temp file
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            dispatch_semaphore_signal(semaphore);
        }];
        
        // Wait for completion (with timeout)
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
}

- (void)createInitialPlaylist {
    RLog(RptrLogAreaProtocol, @"Creating initial empty playlist...");
    
    // Don't include placeholder - just create empty playlist
    // The placeholder approach causes media sequence mismatches
    NSString *playlist = [NSString stringWithFormat:@"#EXTM3U\n"
                        @"#EXT-X-VERSION:6\n"  // Version 6 for better compatibility
                        @"#EXT-X-TARGETDURATION:%ld\n"
                        @"#EXT-X-PLAYLIST-TYPE:EVENT\n"
                        @"#EXT-X-MEDIA-SEQUENCE:0\n"
                        @"#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=%.1f\n"
                        @"#EXT-X-START:TIME-OFFSET=-%.1f\n"
                        @"#EXT-X-INDEPENDENT-SEGMENTS\n"
                        @"#EXT-X-ALLOW-CACHE:NO\n"
                        @"#EXT-X-DISCONTINUITY-SEQUENCE:0\n",
                        (long)self.qualitySettings.targetDuration,
                        self.qualitySettings.segmentDuration * 2,
                        self.qualitySettings.segmentDuration * 2];
    
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    NSError *error;
    [playlist writeToFile:playlistPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (error) {
        RLog(RptrLogAreaError, @"Failed to create initial playlist: %@", error);
    } else {
        RLog(RptrLogAreaProtocol, @"Initial empty playlist created at: %@", playlistPath);
    }
}

- (void)updatePlaylist {
    dispatch_async(self.writerQueue, ^{
        RLog(RptrLogAreaProtocol, @"Updating playlist...");
        
        // Track playlist update event with observer
        [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventPlaylistUpdated
                                                   segmentName:@"playlist.m3u8"
                                                sequenceNumber:self.mediaSequenceNumber
                                                          size:0
                                                     segmentID:nil];
        
        dispatch_sync(self.segmentsQueue, ^{
            NSUInteger segmentCount = self.segments.count;
        RLog(RptrLogAreaProtocol, @"Total segments available: %lu", (unsigned long)segmentCount);
        
        NSMutableString *playlist = [NSMutableString string];
        
        // Header with live HLS tags
        [playlist appendString:@"#EXTM3U\n"];
        [playlist appendString:@"#EXT-X-VERSION:6\n"]; // Version 6 for better compatibility (still supports fMP4)
        [playlist appendFormat:@"#EXT-X-TARGETDURATION:%ld\n", (long)self.qualitySettings.targetDuration];
        [playlist appendString:@"#EXT-X-PLAYLIST-TYPE:EVENT\n"]; // Live event that will eventually end
        [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"]; // CRITICAL for fMP4: segments can be decoded independently
        [playlist appendFormat:@"#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=%.1f\n", self.qualitySettings.segmentDuration * 2]; // Allow skipping old segments
        [playlist appendFormat:@"#EXT-X-START:TIME-OFFSET=-%.1f\n", self.qualitySettings.segmentDuration * 2]; // Start playback 2 segments from live edge
        
        // Add INDEPENDENT-SEGMENTS tag for better compatibility
        [playlist appendString:@"#EXT-X-INDEPENDENT-SEGMENTS\n"];
        
        // Add cache control for live streams
        [playlist appendString:@"#EXT-X-ALLOW-CACHE:NO\n"];
        
        // Add discontinuity sequence for live streams
        [playlist appendString:@"#EXT-X-DISCONTINUITY-SEQUENCE:0\n"];
        
        // Calculate starting sequence number for sliding window
        NSInteger startIndex = MAX(0, (NSInteger)segmentCount - self.qualitySettings.playlistWindow);
        NSInteger startSequence = (startIndex > 0 && segmentCount > startIndex) ? self.segments[startIndex].sequenceNumber : 0;
        
        [playlist appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%ld\n", (long)startSequence];
        
        // Add initialization segment for fMP4
        if (self.initializationSegmentData) {
            [playlist appendFormat:@"#EXT-X-MAP:URI=\"/stream/%@/init.mp4\"\n", self.randomPath];
        }
        
        // Debug: log current segment index and media sequence
        RLog(RptrLogAreaProtocol, @"Playlist generation - currentSegmentIndex: %ld, mediaSequenceNumber: %ld", 
             (long)self.currentSegmentIndex, (long)self.mediaSequenceNumber);
        
        // Add segments (sliding window)
        RLog(RptrLogAreaProtocol, @"Adding segments from index %ld to %lu", (long)startIndex, (unsigned long)segmentCount);
        
        // Add program date time for first segment in window
        if (segmentCount > startIndex && self.segments[startIndex].createdAt) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
            [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
            NSString *dateString = [formatter stringFromDate:self.segments[startIndex].createdAt];
            [playlist appendFormat:@"#EXT-X-PROGRAM-DATE-TIME:%@\n", dateString];
        }
        
        // Filter segments - skip zero-duration segments but keep accurate durations
        for (NSInteger i = startIndex; i < segmentCount; i++) {
            HLSSegmentInfo *segment = self.segments[i];
            CGFloat duration = CMTimeGetSeconds(segment.duration);
            
            // Skip zero-duration segments entirely (these are empty segments from forced rotation)
            if (duration < 0.01) {
                RLog(RptrLogAreaProtocol, @"Skipping zero-duration segment: %@ (%.3fs)", segment.filename, duration);
                continue;
            }
            
            // Add discontinuity tag if this is the first segment and not the very first in the stream
            if (i == startIndex && startIndex > 0) {
                [playlist appendString:@"#EXT-X-DISCONTINUITY\n"];
            }
            
            // RFC 8216: EXTINF duration MUST match actual segment duration
            // We can't lie about durations or merge segments in the playlist
            // Each EXTINF must point to a unique segment with matching duration
            [playlist appendFormat:@"#EXTINF:%.3f,\n", duration];
            [playlist appendFormat:@"/stream/%@/segments/%@\n", self.randomPath, segment.filename];
            
            // Log segment addition
            if (duration < 0.8) {
                RLog(RptrLogAreaProtocol, @"Added short segment: %@ (%.2fs) -> URL: segments/%@", 
                     segment.filename, duration, segment.filename);
            } else {
                RLog(RptrLogAreaProtocol, @"Added segment: %@ (%.2fs) -> URL: segments/%@", 
                     segment.filename, duration, segment.filename);
            }
        }
        
        // For live streams, don't add EXT-X-ENDLIST
        
        // Write playlist to file
        NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
        RLog(RptrLogAreaProtocol, @"Writing playlist to: %@", playlistPath);
        
        NSError *error;
        [playlist writeToFile:playlistPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        
        if (error) {
            RLog(RptrLogAreaError, @"Failed to write playlist: %@", error);
        } else {
            RLog(RptrLogAreaProtocol, @"Updated playlist with %ld segments", (long)(segmentCount - startIndex));
            RLog(RptrLogAreaProtocol, @"Playlist content:\n%@", playlist);
        }
        });
    });
}

- (void)cleanupOldSegments {
    dispatch_barrier_async(self.segmentsQueue, ^{
        NSUInteger initialCount = self.segments.count;
        while (self.segments.count > self.qualitySettings.maxSegments) {
            HLSSegmentInfo *oldSegment = self.segments.firstObject;
            NSTimeInterval segmentAge = [[NSDate date] timeIntervalSinceDate:oldSegment.createdAt];
            
            // Delete the file
            [[NSFileManager defaultManager] removeItemAtPath:oldSegment.path error:nil];
            
            // Remove from array
            [self.segments removeObjectAtIndex:0];
            
            RLog(RptrLogAreaProtocol, @"Removed old segment: %@ (#%ld, age: %.1fs) - Segments: %lu -> %lu", 
                   oldSegment.filename, (long)oldSegment.sequenceNumber, segmentAge,
                   (unsigned long)initialCount, (unsigned long)self.segments.count);
        }
    });
}

- (void)cleanupAllSegments {
    dispatch_barrier_async(self.segmentsQueue, ^{
        // Remove all segment files
        for (HLSSegmentInfo *segment in self.segments) {
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtPath:segment.path error:&error];
            if (error) {
                RLog(RptrLogAreaError, @"Failed to remove segment %@: %@", segment.filename, error.localizedDescription);
            }
        }
        [self.segments removeAllObjects];
    });
    
    // Remove initialization segment
    NSString *initSegmentPath = [self.segmentDirectory stringByAppendingPathComponent:@"init.mp4"];
    [[NSFileManager defaultManager] removeItemAtPath:initSegmentPath error:nil];
    
    // Remove all files in segments directory to ensure clean state
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.segmentDirectory error:&error];
    if (!error) {
        for (NSString *file in files) {
            NSString *filePath = [self.segmentDirectory stringByAppendingPathComponent:file];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        }
        RLog(RptrLogAreaProtocol, @"Cleaned up %lu files from segments directory", (unsigned long)files.count);
    }
}

#pragma mark - HTTP Server

/**
 * Main server accept loop - runs on background queue
 * 
 * Continuously accepts incoming connections until server stops
 * Each connection is handled on a separate queue to prevent blocking
 * 
 * Thread Model:
 * - Runs on serverQueue (serial)
 * - Spawns concurrent handlers for each client
 * - Uses BSD sockets for maximum control
 * 
 * @note This method blocks until server shutdown
 * @warning Must be called on serverQueue
 */
- (void)acceptLoop {
    while (self.running) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        
        int clientSocket = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSocket < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Non-blocking socket has no pending connections
                usleep(10000); // Sleep 10ms to avoid busy-waiting
                continue;
            }
            if (self.running) {
                RLog(RptrLogAreaError, @"Accept failed: %s (errno: %d)", strerror(errno), errno);
            }
            continue;
        }
        
        // Copy client address for async use
        struct sockaddr_in *clientAddrCopy = malloc(sizeof(struct sockaddr_in));
        if (!clientAddrCopy) {
            RLog(RptrLogAreaError, @"ERROR: Failed to allocate memory for client address");
            close(clientSocket);
            continue;
        }
        memcpy(clientAddrCopy, &clientAddr, sizeof(struct sockaddr_in));
        
        // Handle client in background with weak reference to avoid retain cycle
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                close(clientSocket);
                free(clientAddrCopy);
                return;
            }
            
            @try {
                [strongSelf handleClient:clientSocket address:clientAddrCopy];
            } @catch (NSException *exception) {
                RLog(RptrLogAreaError, @"ERROR: Exception handling client: %@", exception);
                RLog(RptrLogAreaError, @"Stack trace: %@", exception.callStackSymbols);
            } @finally {
                free(clientAddrCopy);
            }
        });
    }
}

/**
 * Handles a single HTTP client connection
 * 
 * Request Processing:
 * 1. Reads HTTP request from socket
 * 2. Parses method, path, and headers
 * 3. Routes to appropriate content handler
 * 4. Sends response with proper headers
 * 5. Tracks client activity for monitoring
 * 
 * Security:
 * - Validates random path for basic access control
 * - Prevents directory traversal attacks
 * - Limits request size to prevent DoS
 * 
 * @param clientSocket Connected client socket descriptor
 * @param clientAddr Client address structure for logging
 * 
 * @note Connection is closed after each request (HTTP/1.0)
 * @warning Large segments may cause memory spikes
 */
- (void)handleClient:(int)clientSocket address:(const struct sockaddr_in *)clientAddr {
    NSParameterAssert(clientSocket >= 0);
    NSParameterAssert(clientAddr != NULL);
    
    RLog(RptrLogAreaProtocol, @"1. handleClient started for socket: %d", clientSocket);
    
    // Use inet_ntop for thread safety
    char clientIP[INET_ADDRSTRLEN];
    NSString *clientAddress = @"unknown";
    
    if (clientAddr && inet_ntop(AF_INET, &(clientAddr->sin_addr), clientIP, INET_ADDRSTRLEN) != NULL) {
        clientAddress = [NSString stringWithUTF8String:clientIP];
        NSAssert(clientAddress != nil, @"Client address conversion should not fail");
    } else {
        RLog(RptrLogAreaError, @"WARNING: Failed to get client IP address: %s", strerror(errno));
    }
    
    // Add client
    HLSClient *client = [[HLSClient alloc] init];
    client.address = clientAddress;
    client.lastActivity = [[NSDate date] timeIntervalSince1970];
    
    [self addClient:client forSocket:clientSocket];
    
    // Track active client by IP address
    dispatch_barrier_async(self.clientsQueue, ^{
        BOOL isNewClient = (self.activeClients[clientAddress] == nil);
        self.activeClients[clientAddress] = [NSDate date];
        
        if (isNewClient && [self.delegate respondsToSelector:@selector(hlsServer:clientConnected:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate hlsServer:self clientConnected:clientAddress];
            });
        }
    });
    
    RLog(RptrLogAreaProtocol, @"Client connected: %@ (active clients: %lu)", clientAddress, (unsigned long)self.activeClients.count);
    
    // Read request
    RLog(RptrLogAreaProtocol, @"2. About to read request from socket %d", clientSocket);
    char buffer[self.qualitySettings.httpBufferSize];
    ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    RLog(RptrLogAreaProtocol, @"3. Read %zd bytes from socket %d", bytesRead, clientSocket);
    
    if (bytesRead < 0) {
        RLog(RptrLogAreaError, @"ERROR: Failed to read from client socket: %s", strerror(errno));
        // Still need to remove client and close socket
    } else if (bytesRead > 0) {
        buffer[bytesRead] = '\0';
        
        // Validate UTF8 before creating string
        if (![[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding]) {
            RLog(RptrLogAreaError, @"ERROR: Invalid UTF8 in request");
            [self sendErrorResponse:clientSocket code:400 message:@"Bad Request"];
            close(clientSocket);
            return;
        }
        
        NSString *request = [NSString stringWithUTF8String:buffer];
        RLog(RptrLogAreaProtocol, @"4. Request string created, length: %lu", (unsigned long)[request length]);
        
        // Parse request
        RLog(RptrLogAreaProtocol, @"5. Parsing request...");
        NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
        RLog(RptrLogAreaProtocol, @"6. Request has %lu lines", (unsigned long)lines.count);
        if (lines.count > 0) {
            NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
            RLog(RptrLogAreaProtocol, @"7. First line has %lu parts", (unsigned long)parts.count);
            if (parts.count >= 2) {
                NSString *method = parts[0];
                NSString *path = parts[1];
                
                // Debug: Log path details
                RLog(RptrLogAreaProtocol, @"Raw path: '%@' (length: %lu)", path, (unsigned long)path.length);
                RLog(RptrLogAreaProtocol, @"Path bytes: %@", [path dataUsingEncoding:NSUTF8StringEncoding]);
                
                RLog(RptrLogAreaProtocol, @"Request: %@ %@ (socket %d)", method, path, clientSocket);
                
                if ([method isEqualToString:@"GET"]) {
                    RLog(RptrLogAreaProtocol, @"9. Calling handleGETRequest for path: %@", path);
                    [self handleGETRequest:path socket:clientSocket];
                    RLog(RptrLogAreaProtocol, @"10. handleGETRequest completed for path: %@", path);
                } else if ([method isEqualToString:@"POST"]) {
                    // Handle POST requests (mainly for client events)
                    RLog(RptrLogAreaProtocol, @"Handling POST request for path: %@", path);
                    if ([path isEqualToString:@"/client-event"]) {
                        [self handleClientEventReport:clientSocket];
                    } else if ([path isEqualToString:@"/log"]) {
                        [self handleLogRequest:clientSocket request:request];
                    } else {
                        [self sendErrorResponse:clientSocket code:404 message:@"Not Found"];
                    }
                } else if ([method isEqualToString:@"OPTIONS"]) {
                    // Handle CORS preflight requests
                    RLog(RptrLogAreaProtocol, @"Handling OPTIONS preflight for path: %@", path);
                    [self sendOptionsResponse:clientSocket];
                } else {
                    [self sendErrorResponse:clientSocket code:405 message:@"Method Not Allowed"];
                }
            }
        }
    }
    
    // Remove client
    dispatch_barrier_async(self.clientsQueue, ^{
        [self.clients removeObjectForKey:@(clientSocket)];
    });
    
    // Safe close
    if (clientSocket >= 0) {
        shutdown(clientSocket, SHUT_RDWR);
        close(clientSocket);
    }
    
    if ([self.delegate respondsToSelector:@selector(hlsServer:clientDisconnected:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate hlsServer:self clientDisconnected:clientAddress];
        });
    }
}

- (void)handleGETRequest:(NSString *)path socket:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"GET %@ (socket: %d)", path, clientSocket);
    RLog(RptrLogAreaProtocol, @"handleGETRequest entry - path class: %@", [path class]);
    
    // Update client activity
    dispatch_barrier_async(self.clientsQueue, ^{
        HLSClient *client = self.clients[@(clientSocket)];
        if (client && client.address) {
            self.activeClients[client.address] = [NSDate date];
        }
    });
    
    // Remove query parameters
    NSRange range = [path rangeOfString:@"?"];
    if (range.location != NSNotFound) {
        path = [path substringToIndex:range.location];
    }
    
    // Security check - prevent directory traversal
    if ([path containsString:@".."] || [path containsString:@"~"]) {
        [self sendErrorResponse:clientSocket code:403 message:@"Forbidden"];
        return;
    }
    
    // Debug logging to understand path matching
    RLog(RptrLogAreaProtocol, @"Request path: '%@', Current randomPath: '%@'", path, self.randomPath);
    
    if ([path isEqualToString:@"/"]) {
        // Root path serves the playlist (legacy support)
        [self sendPlaylistResponse:clientSocket];
    } else if ([path isEqualToString:@"/debug"]) {
        [self sendDebugResponse:clientSocket];
    } else if ([path isEqualToString:@"/view"]) {
        // Redirect to the randomized URL
        NSString *redirectURL = [NSString stringWithFormat:@"/view/%@", self.randomPath];
        NSString *response = [NSString stringWithFormat:
                            @"HTTP/1.1 302 Found\r\n"
                            @"Location: %@\r\n"
                            @"Content-Length: 0\r\n"
                            @"\r\n", redirectURL];
        send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
        RLog(RptrLogAreaProtocol, @"Redirecting /view to %@", redirectURL);
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/view/%@", self.randomPath]]) {
        RLog(RptrLogAreaProtocol, @"Page requested on socket %d", clientSocket);
        [self sendViewPageResponse:clientSocket];
        RLog(RptrLogAreaProtocol, @"Page response completed for socket %d", clientSocket);
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/playlist.m3u8", self.randomPath]]) {
        RLog(RptrLogAreaProtocol, @"Secure playlist requested on socket %d", clientSocket);
        RLog(RptrLogAreaProtocol, @"DEBUG: Expected path: /stream/%@/playlist.m3u8", self.randomPath);
        RLog(RptrLogAreaProtocol, @"DEBUG: Received path: %@", path);
        [self sendPlaylistResponse:clientSocket];
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/init.mp4", self.randomPath]]) {
        RLog(RptrLogAreaProtocol, @"Secure init segment requested on socket %d", clientSocket);
        [self sendInitializationSegmentResponse:clientSocket];
    } else if ([path hasPrefix:[NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath]]) {
        NSString *segmentPrefix = [NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath];
        NSString *segmentName = [path substringFromIndex:segmentPrefix.length];
        RLog(RptrLogAreaProtocol, @"Secure segment requested: %@ on socket %d", segmentName, clientSocket);
        
        // Debug logging for segment state
        [self.segmentDataLock lock];
        NSUInteger segmentDataCount = self.segmentData.count;
        BOOL hasSegment = [self.segmentData objectForKey:segmentName] != nil;
        [self.segmentDataLock unlock];
        
        RLog(RptrLogAreaProtocol, @"Segment lookup: %@ - exists: %@, total segments in memory: %lu", 
             segmentName, hasSegment ? @"YES" : @"NO", (unsigned long)segmentDataCount);
        
        // Check if delegate-based writing is active
        if (self.assetWriter && self.assetWriter.delegate) {
            // Use delegate-based segment serving for in-memory segments
            [self sendDelegateSegmentResponse:clientSocket segmentName:segmentName];
        } else {
            // Fallback to file-based serving
            [self sendSegmentResponse:clientSocket segmentName:segmentName];
        }
    } else if ([path hasPrefix:@"/css/"] || [path hasPrefix:@"/js/"] || [path hasPrefix:@"/images/"]) {
        // Serve bundled resources
        [self sendBundledResourceResponse:clientSocket path:path];
    } else if ([path isEqualToString:@"/location"]) {
        [self sendLocationResponse:clientSocket];
    } else if ([path isEqualToString:@"/status"]) {
        [self sendStatusResponse:clientSocket];
    } else if ([path isEqualToString:@"/health"]) {
        [self sendHealthResponse:clientSocket];
    } else if ([path isEqualToString:@"/client-event"]) {
        [self handleClientEventReport:clientSocket];
    } else if (self.previousRandomPath && 
               ([path containsString:[NSString stringWithFormat:@"/stream/%@/", self.previousRandomPath]] ||
                [path containsString:[NSString stringWithFormat:@"/view/%@", self.previousRandomPath]])) {
        // Request is using the old random path after regeneration
        RLog(RptrLogAreaProtocol, @"Request using old path: %@ (current: %@)", self.previousRandomPath, self.randomPath);
        // Send 410 Gone to indicate the resource has been permanently removed
        // This should trigger clients to reload
        [self sendErrorResponse:clientSocket code:410 message:@"Gone - URL has been regenerated"];
        
        // Close the socket immediately for old URLs to prevent clients from keeping connections alive
        shutdown(clientSocket, SHUT_RDWR);
        close(clientSocket);
        return;
    } else {
        RLog(RptrLogAreaProtocol, @"DEBUG: Unmatched request path: %@", path);
        RLog(RptrLogAreaProtocol, @"DEBUG: Current randomPath: %@", self.randomPath);
        
        // Extra debugging for segment paths
        if ([path containsString:@"/segments/"]) {
            NSString *expectedPrefix = [NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath];
            RLog(RptrLogAreaProtocol, @"DEBUG: Expected segment prefix: %@", expectedPrefix);
            RLog(RptrLogAreaProtocol, @"DEBUG: Path has prefix: %@", [path hasPrefix:expectedPrefix] ? @"YES" : @"NO");
        }
        
        [self sendErrorResponse:clientSocket code:404 message:@"Not Found"];
    }
}

- (void)sendPlaylistResponse:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"=== Playlist Request Debug ===");
    BOOL isDelegateAvailable = YES; // Always available with iOS 14+ minimum
    RLog(RptrLogAreaProtocol, @"Using delegate-based approach: %@", isDelegateAvailable ? @"YES" : @"NO");
    RLog(RptrLogAreaProtocol, @"Initialization segment available: %@", self.initializationSegmentData ? @"YES" : @"NO");
    [self.segmentDataLock lock];
    NSUInteger segmentCount = self.segmentData.count;
    [self.segmentDataLock unlock];
    RLog(RptrLogAreaProtocol, @"Media segments in memory: %lu", (unsigned long)segmentCount);
    __block NSUInteger arrayCount;
    dispatch_sync(self.segmentsQueue, ^{
        arrayCount = self.segments.count;
    });
    RLog(RptrLogAreaProtocol, @"Segments array count: %lu", (unsigned long)arrayCount);
    
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    RLog(RptrLogAreaProtocol, @"Looking for playlist at: %@", playlistPath);
    
    // Check if file exists
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:playlistPath];
    RLog(RptrLogAreaProtocol, @"Playlist file exists: %@", fileExists ? @"YES" : @"NO");
    
    NSData *playlistData = [NSData dataWithContentsOfFile:playlistPath];
    
    if (!playlistData) {
        RLog(RptrLogAreaError, @"ERROR: Playlist file missing, generating on demand");
        // Generate playlist on demand
        [self updatePlaylist];
        
        // Try reading again
        playlistData = [NSData dataWithContentsOfFile:playlistPath];
        
        if (!playlistData) {
            // Still no playlist, check if we have any segments
            if (self.segments.count == 0) {
                RLog(RptrLogAreaProtocol, @"No segments generated yet, sending minimal playlist with sequence %ld", (long)self.mediaSequenceNumber);
                // Send a minimal playlist to keep client waiting
                NSString *minimalPlaylist = [NSString stringWithFormat:
                    @"#EXTM3U\n"
                    @"#EXT-X-VERSION:6\n"
                    @"#EXT-X-TARGETDURATION:6\n"
                    @"#EXT-X-MEDIA-SEQUENCE:%ld\n"
                    @"#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6.0\n",
                    (long)self.mediaSequenceNumber];
                playlistData = [minimalPlaylist dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                RLog(RptrLogAreaError, @"Failed to generate playlist despite having %lu segments", (unsigned long)self.segments.count);
                [self sendErrorResponse:clientSocket code:500 message:@"Playlist generation failed"];
                return;
            }
        }
    } else {
        RLog(RptrLogAreaProtocol, @"Playlist size: %lu bytes", (unsigned long)playlistData.length);
    }
    
    // Send headers
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: application/vnd.apple.mpegurl\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Cache-Control: no-cache\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)playlistData.length];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    send(clientSocket, playlistData.bytes, playlistData.length, MSG_NOSIGNAL);
}

- (void)sendSegmentResponse:(int)clientSocket segmentName:(NSString *)segmentName {
    RLog(RptrLogAreaProtocol, @"Segment requested: %@", segmentName);
    
    // First check if segment exists in memory (delegate-based writing)
    [self.segmentDataLock lock];
    NSData *segmentData = [self.segmentData objectForKey:segmentName];
    [self.segmentDataLock unlock];
    
    if (segmentData) {
        RLog(RptrLogAreaProtocol, @"Found segment in memory, using delegate response");
        [self sendDelegateSegmentResponse:clientSocket segmentName:segmentName];
        return;
    }
    
    // Validate segment name
    if (![segmentName hasSuffix:@".mp4"] && ![segmentName hasSuffix:@".m4s"] && ![segmentName hasSuffix:@".ts"]) {
        RLog(RptrLogAreaError, @"ERROR: Invalid segment extension for: %@", segmentName);
        [self sendErrorResponse:clientSocket code:400 message:@"Invalid segment"];
        return;
    }
    
    NSString *segmentPath = [self.segmentDirectory stringByAppendingPathComponent:segmentName];
    RLog(RptrLogAreaProtocol, @"Looking for segment at: %@", segmentPath);
    
    // Debug: List all files in segment directory
    NSError *dirError;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.segmentDirectory error:&dirError];
    if (dirError) {
        RLog(RptrLogAreaError, @"ERROR: Cannot list segment directory: %@", dirError);
    } else {
        RLog(RptrLogAreaProtocol, @"Files in segment directory (%@): %@", self.segmentDirectory, files);
    }
    
    // Check if file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:segmentPath]) {
        RLog(RptrLogAreaError, @"ERROR: Segment not found at path: %@", segmentPath);
        [self sendErrorResponse:clientSocket code:404 message:@"Segment not found"];
        return;
    }
    
    // Get file size
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:segmentPath error:nil];
    NSUInteger fileSize = [attrs fileSize];
    
    // Send headers with correct MIME type for fMP4
    NSString *contentType = @"video/mp4";
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: %@\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Cache-Control: no-cache\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: GET, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Range\r\n"
                        @"Accept-Ranges: bytes\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        contentType,
                        (unsigned long)fileSize];
    
    RLog(RptrLogAreaProtocol, @"Sending segment %@ (%lu bytes)", segmentName, (unsigned long)fileSize);
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    
    // Use dispatch_data for zero-copy file sending
    dispatch_queue_t ioQueue = dispatch_queue_create("com.rptr.file.io", DISPATCH_QUEUE_SERIAL);
    int fd = open(segmentPath.UTF8String, O_RDONLY);
    
    if (fd >= 0) {
        // Map the file into memory (zero-copy)
        dispatch_read(fd, fileSize, ioQueue, ^(dispatch_data_t data, int error) {
            close(fd);
            if (!error && data) {
                // Send the data using dispatch_data
                dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                    size_t totalSent = 0;
                    while (totalSent < size) {
                        ssize_t sent = send(clientSocket, (const char *)buffer + totalSent, 
                                          size - totalSent, MSG_NOSIGNAL);
                        if (sent <= 0) {
                            break;
                        }
                        totalSent += sent;
                    }
                    return true; // Continue iterating
                });
            }
        });
    } else {
        RLog(RptrLogAreaError, @"Failed to open segment file: %@", segmentPath);
    }
}

- (void)sendInitializationSegmentResponse:(int)clientSocket {
    if (!self.initializationSegmentData) {
        [self sendErrorResponse:clientSocket code:404 message:@"Initialization segment not available"];
        return;
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: video/mp4\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: GET, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Range\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)self.initializationSegmentData.length];
    
    RLog(RptrLogAreaProtocol, @"Sending initialization segment (%lu bytes)", (unsigned long)self.initializationSegmentData.length);
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    
    // Use dispatch_data for efficient memory management
    dispatch_data_t dispatchData = dispatch_data_create(self.initializationSegmentData.bytes, 
                                                        self.initializationSegmentData.length,
                                                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    
    dispatch_data_apply(dispatchData, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        size_t totalSent = 0;
        while (totalSent < size) {
            ssize_t sent = send(clientSocket, (const char *)buffer + totalSent, 
                              size - totalSent, MSG_NOSIGNAL);
            if (sent <= 0) {
                break;
            }
            totalSent += sent;
        }
        return true;
    });
}

- (void)sendDelegateSegmentResponse:(int)clientSocket segmentName:(NSString *)segmentName {
    [self.segmentDataLock lock];
    NSData *segmentData = [self.segmentData objectForKey:segmentName];
    
    // Debug: log all available segments
    NSArray *allSegmentKeys = [self.segmentData allKeys];
    // Log for protocol debugging
    RLog(RptrLogAreaProtocol, @"Looking for segment: %@, available segments: %@", 
         segmentName, [allSegmentKeys componentsJoinedByString:@", "]);
    
    // Track segment request with observer
    NSInteger sequenceNum = -1;
    if ([segmentName hasPrefix:@"segment_"] && [segmentName hasSuffix:@".m4s"]) {
        NSString *numberStr = [segmentName substringWithRange:NSMakeRange(8, segmentName.length - 12)];
        sequenceNum = [numberStr integerValue];
    }
    [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventRequested
                                               segmentName:segmentName
                                            sequenceNumber:sequenceNum
                                                      size:0
                                                 segmentID:nil];
    
    // If not found, try alternative naming (for transition period between numbering schemes)
    if (!segmentData && [segmentName hasPrefix:@"segment_"] && [segmentName hasSuffix:@".m4s"]) {
        // Extract the number from the segment name
        NSString *numberStr = [segmentName substringWithRange:NSMakeRange(8, segmentName.length - 12)];
        long requestedNumber = [numberStr integerValue];
        
        // Try with currentSegmentIndex-based name (old scheme)
        for (NSString *key in allSegmentKeys) {
            if ([key hasPrefix:@"segment_"] && [key hasSuffix:@".m4s"]) {
                NSString *keyNumberStr = [key substringWithRange:NSMakeRange(8, key.length - 12)];
                long keyNumber = [keyNumberStr integerValue];
                
                // Check if this might be the segment we're looking for
                // This is a heuristic - might need adjustment based on actual mapping
                if (keyNumber == requestedNumber || 
                    keyNumber == requestedNumber - (self.mediaSequenceNumber - self.currentSegmentIndex)) {
                    segmentData = [self.segmentData objectForKey:key];
                    if (segmentData) {
                        RLog(RptrLogAreaProtocol, @"Found segment with alternative key: %@ for requested: %@", key, segmentName);
                        break;
                    }
                }
            }
        }
    }
    
    [self.segmentDataLock unlock];
    
    if (!segmentData) {
        NSString *seqStr = @"???";
        if ([segmentName hasPrefix:@"segment_"] && [segmentName hasSuffix:@".m4s"]) {
            seqStr = [segmentName substringWithRange:NSMakeRange(8, segmentName.length - 12)];
        }
        RLog(RptrLogAreaError, @"[SEG-REQ-%@] NOT FOUND: %@ (404 - current_idx=%ld, media_seq=%ld)", 
             seqStr, segmentName, (long)self.currentSegmentIndex, (long)self.mediaSequenceNumber);
        
        // Track segment not found with observer
        NSInteger seqNum = [seqStr integerValue];
        [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventNotFound
                                                   segmentName:segmentName
                                                sequenceNumber:seqNum
                                                          size:0
                                                     segmentID:nil];
        
        [self sendErrorResponse:clientSocket code:404 message:@"Segment not found"];
        return;
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: video/mp4\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: GET, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Range\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)segmentData.length];
    
    NSString *seqStrFinal = @"???";
    if ([segmentName hasPrefix:@"segment_"] && [segmentName hasSuffix:@".m4s"]) {
        seqStrFinal = [segmentName substringWithRange:NSMakeRange(8, segmentName.length - 12)];
    }
    RLog(RptrLogAreaProtocol, @"[SEG-REQ-%@] SERVING: %@ (%lu bytes) to socket=%d", 
         seqStrFinal, segmentName, (unsigned long)segmentData.length, clientSocket);
    
    // Track successful segment serving with observer
    NSInteger seqNumFinal = [seqStrFinal integerValue];
    [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventServed
                                               segmentName:segmentName
                                            sequenceNumber:seqNumFinal
                                                      size:segmentData.length
                                                 segmentID:nil];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    
    // Use dispatch_data for efficient memory management
    dispatch_data_t dispatchData = dispatch_data_create(segmentData.bytes, 
                                                        segmentData.length,
                                                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    
    dispatch_data_apply(dispatchData, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        size_t totalSent = 0;
        while (totalSent < size) {
            ssize_t sent = send(clientSocket, (const char *)buffer + totalSent, 
                              size - totalSent, MSG_NOSIGNAL);
            if (sent <= 0) {
                break;
            }
            totalSent += sent;
        }
        return true;
    });
}

- (void)sendErrorResponse:(int)clientSocket code:(NSInteger)code message:(NSString *)message {
    NSString *response = [NSString stringWithFormat:
                         @"HTTP/1.1 %ld %@\r\n"
                         @"Content-Type: text/plain\r\n"
                         @"Content-Length: %lu\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                         @"Access-Control-Allow-Headers: Content-Type, Range, Accept, Origin\r\n"
                         @"Connection: close\r\n"
                         @"\r\n"
                         @"%@",
                         (long)code, message,
                         (unsigned long)message.length,
                         message];
    
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
}

- (void)sendOptionsResponse:(int)clientSocket {
    NSString *response = @"HTTP/1.1 200 OK\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Content-Type, Range, Accept, Origin\r\n"
                        @"Access-Control-Max-Age: 3600\r\n"
                        @"Content-Length: 0\r\n"
                        @"Connection: close\r\n"
                        @"\r\n";
    
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
    RLog(RptrLogAreaProtocol, @"Sent OPTIONS response for CORS preflight");
}

- (void)sendDebugResponse:(int)clientSocket {
    NSMutableString *debug = [NSMutableString string];
    [debug appendString:@"HLS Server Debug Info\n"];
    [debug appendString:@"=====================\n\n"];
    
    [debug appendFormat:@"Server Status:\n"];
    [debug appendFormat:@"- Running: %@\n", self.running ? @"YES" : @"NO"];
    [debug appendFormat:@"- Writing: %@\n", self.isWriting ? @"YES" : @"NO"];
    [debug appendFormat:@"- Session Started: %@\n", self.sessionStarted ? @"YES" : @"NO"];
    [debug appendFormat:@"- Current Segment Index: %ld\n", (long)self.currentSegmentIndex];
    [debug appendFormat:@"- Frames Processed: %ld\n", (long)self.framesProcessed];
    [debug appendFormat:@"- Frames Dropped: %ld\n\n", (long)self.framesDropped];
    
    [debug appendFormat:@"Segments:\n"];
    [debug appendFormat:@"- Total Segments: %lu\n", (unsigned long)self.segments.count];
    
    for (HLSSegmentInfo *segment in self.segments) {
        [debug appendFormat:@"  - %@ (%.2fs, %lu bytes)\n", 
               segment.filename, 
               CMTimeGetSeconds(segment.duration),
               (unsigned long)segment.fileSize];
    }
    
    [debug appendString:@"\nCurrent Playlist:\n"];
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    NSString *playlistContent = [NSString stringWithContentsOfFile:playlistPath encoding:NSUTF8StringEncoding error:nil];
    if (playlistContent) {
        [debug appendString:playlistContent];
    } else {
        [debug appendString:@"(No playlist file found)"];
    }
    
    NSData *responseData = [debug dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: text/plain\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)responseData.length];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    send(clientSocket, responseData.bytes, responseData.length, MSG_NOSIGNAL);
}

- (void)sendLocationResponse:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"Location request received");
    
    // Get location from delegate
    NSDictionary *locationData = nil;
    if ([self.delegate respondsToSelector:@selector(hlsServerRequestsLocation:)]) {
        locationData = [self.delegate hlsServerRequestsLocation:self];
    }
    
    if (!locationData) {
        locationData = @{
            @"error": @"Location not available",
            @"latitude": @(0),
            @"longitude": @(0)
        };
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:locationData options:NSJSONWritingPrettyPrinted error:&error];
    
    if (error) {
        [self sendErrorResponse:clientSocket code:500 message:@"JSON serialization error"];
        return;
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: application/json\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)jsonData.length];
    
    NSData *responseData = [headers dataUsingEncoding:NSUTF8StringEncoding];
    send(clientSocket, responseData.bytes, responseData.length, MSG_NOSIGNAL);
    send(clientSocket, jsonData.bytes, jsonData.length, MSG_NOSIGNAL);
}

- (void)sendStatusResponse:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"Status request received from socket: %d", clientSocket);
    
    // Get location from delegate
    NSDictionary *locationData = nil;
    if ([self.delegate respondsToSelector:@selector(hlsServerRequestsLocation:)]) {
        locationData = [self.delegate hlsServerRequestsLocation:self];
        RLog(RptrLogAreaProtocol, @"Location data received: %@", locationData);
    } else {
        RLog(RptrLogAreaProtocol, @"Delegate does not respond to hlsServerRequestsLocation");
    }
    
    NSMutableDictionary *statusData = [NSMutableDictionary dictionary];
    
    // Add location data
    if (locationData) {
        statusData[@"location"] = locationData;
    } else {
        statusData[@"location"] = @{
            @"error": @"Location not available",
            @"latitude": @(0),
            @"longitude": @(0)
        };
    }
    
    // Add stream title - use thread-safe getter
    NSString *currentTitle = [self getStreamTitle];
    statusData[@"title"] = currentTitle ?: @"Share Stream";
    RLog(RptrLogAreaProtocol, @"Sending status with title: %@", statusData[@"title"]);
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:statusData options:NSJSONWritingPrettyPrinted error:&error];
    
    if (error) {
        [self sendErrorResponse:clientSocket code:500 message:@"JSON serialization error"];
        return;
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: application/json\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)jsonData.length];
    
    NSData *responseData = [headers dataUsingEncoding:NSUTF8StringEncoding];
    send(clientSocket, responseData.bytes, responseData.length, MSG_NOSIGNAL);
    send(clientSocket, jsonData.bytes, jsonData.length, MSG_NOSIGNAL);
}

- (void)handleLogRequest:(int)clientSocket request:(NSString *)request {
    // Parse POST body for log message
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSString *body = [lines lastObject];
    
    if (body && body.length > 0) {
        // Forward to UDP logger
        [[RptrUDPLogger sharedLogger] logWithSource:@"CLIENT" message:body];
    }
    
    // Send simple OK response
    NSString *response = @"HTTP/1.1 200 OK\r\n"
                        @"Content-Length: 0\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Connection: close\r\n"
                        @"\r\n";
    
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
}

- (void)handleClientEventReport:(int)clientSocket {
    // For beacon API, we just acknowledge receipt
    // The actual event data would need to be read from POST body
    // For now, just log that we received a client event
    RLog(RptrLogAreaProtocol, @"[CLIENT-EVENT] Received client tracking event");
    
    // Send minimal response for beacon API
    NSString *response = @"HTTP/1.1 204 No Content\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Connection: close\r\n"
                        @"\r\n";
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
}

- (void)sendHealthResponse:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"Health report request received from socket: %d", clientSocket);
    
    // Get health report from observer
    NSString *healthReport = [[HLSSegmentObserver sharedObserver] getSegmentHealthReport];
    
    // Get protocol compliance violations
    NSArray *violations = [[HLSSegmentObserver sharedObserver] checkProtocolCompliance];
    
    // Build response
    NSMutableString *response = [NSMutableString string];
    [response appendString:@"<!DOCTYPE html>\n<html>\n<head>\n"];
    [response appendString:@"<title>HLS Server Health Report</title>\n"];
    [response appendString:@"<style>body{font-family:monospace;white-space:pre;padding:20px;background:#1a1a1a;color:#0f0;}</style>\n"];
    [response appendString:@"</head>\n<body>\n"];
    
    // Add timestamp
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    [response appendFormat:@"Report Generated: %@\n", [formatter stringFromDate:[NSDate date]]];
    
    // Add server info
    [response appendFormat:@"Server Port: %lu\n", (unsigned long)self.port];
    [response appendFormat:@"Stream Path: %@\n", self.randomPath];
    [response appendFormat:@"Streaming Active: %@\n", self.isWriting ? @"YES" : @"NO"];
    
    // Add segment info
    [self.segmentDataLock lock];
    NSUInteger segmentCount = self.segmentData.count;
    NSUInteger totalMemory = 0;
    for (NSData *data in self.segmentData.allValues) {
        totalMemory += data.length;
    }
    [self.segmentDataLock unlock];
    
    [response appendFormat:@"\n=== IN-MEMORY SEGMENTS ===\n"];
    [response appendFormat:@"Count: %lu\n", (unsigned long)segmentCount];
    [response appendFormat:@"Total Memory: %.2f MB\n", totalMemory / (1024.0 * 1024.0)];
    [response appendFormat:@"Current Index: %ld\n", (long)self.currentSegmentIndex];
    [response appendFormat:@"Media Sequence: %ld\n", (long)self.mediaSequenceNumber];
    
    // Add observer health report
    [response appendString:healthReport];
    
    // Add protocol violations
    if (violations.count > 0) {
        [response appendString:@"\n=== PROTOCOL VIOLATIONS ===\n"];
        for (NSString *violation in violations) {
            [response appendFormat:@"  ⚠️  %@\n", violation];
        }
    } else {
        [response appendString:@"\n=== PROTOCOL COMPLIANCE ===\n"];
        [response appendString:@"  ✅ No violations detected\n"];
    }
    
    // Add recent issues
    NSArray *recentIssues = [[HLSSegmentObserver sharedObserver] getRecentIssues];
    if (recentIssues.count > 0) {
        [response appendString:@"\n=== RECENT ISSUES ===\n"];
        NSInteger showCount = MIN(20, recentIssues.count);
        for (NSInteger i = recentIssues.count - showCount; i < recentIssues.count; i++) {
            [response appendFormat:@"  %@\n", recentIssues[i]];
        }
    }
    
    [response appendString:@"</body>\n</html>\n"];
    
    NSData *htmlData = [response dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: text/html; charset=utf-8\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Cache-Control: no-cache\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)htmlData.length];
    
    NSData *responseData = [headers dataUsingEncoding:NSUTF8StringEncoding];
    send(clientSocket, responseData.bytes, responseData.length, MSG_NOSIGNAL);
    send(clientSocket, htmlData.bytes, htmlData.length, MSG_NOSIGNAL);
}

- (void)sendViewPageResponse:(int)clientSocket {
    RLog(RptrLogAreaProtocol, @"Serving view page from template for socket: %d", clientSocket);
    
    @try {
        // Load template from bundle
        NSString *templatePath = [[NSBundle mainBundle] pathForResource:@"index" 
                                                                  ofType:@"html" 
                                                            inDirectory:@"WebResources"];
        
        RLog(RptrLogAreaProtocol, @"Looking for template at path: %@", templatePath);
        
        if (!templatePath) {
            RLog(RptrLogAreaError, @"HTML template not found in bundle - using embedded fallback");
            // Fall back to embedded HTML
            [self sendEmbeddedViewPageResponse:clientSocket];
            return;
        }
        
        NSError *error = nil;
        NSString *htmlTemplate = [NSString stringWithContentsOfFile:templatePath 
                                                           encoding:NSUTF8StringEncoding 
                                                              error:&error];
        
        if (error) {
            RLog(RptrLogAreaError, @"Error loading template: %@", error);
            [self sendEmbeddedViewPageResponse:clientSocket];
            return;
        }
        
        // Create placeholder dictionary
        NSString *pathComponent = self.randomPath;
        NSDictionary *placeholders = @{
            @"{{APP_TITLE}}": @"Rptr Live Stream",
            @"{{PAGE_TITLE}}": [self getStreamTitle] ?: @"Share Stream",
            @"{{STREAM_URL}}": [NSString stringWithFormat:@"/stream/%@/playlist.m3u8", pathComponent],
            @"{{SERVER_PORT}}": [NSString stringWithFormat:@"%lu", (unsigned long)self.port],
            @"{{WEBSOCKET_PATH}}": [NSString stringWithFormat:@"/ws/%@", pathComponent],
            @"{{WEBSOCKET_PORT}}": @"8081",
            @"{{LOCATION_ENDPOINT}}": @"/location",
            @"{{INITIAL_STATUS}}": @"Connecting to stream..."
        };
        
        RLog(RptrLogAreaProtocol, @"DEBUG: Template placeholders:");
        RLog(RptrLogAreaProtocol, @"  STREAM_URL: %@", placeholders[@"{{STREAM_URL}}"]);
        RLog(RptrLogAreaProtocol, @"  randomPath: %@", self.randomPath);
        
        // Replace placeholders
        NSMutableString *processedHTML = [htmlTemplate mutableCopy];
        for (NSString *placeholder in placeholders) {
            [processedHTML replaceOccurrencesOfString:placeholder 
                                           withString:placeholders[placeholder] 
                                              options:NSLiteralSearch 
                                                range:NSMakeRange(0, processedHTML.length)];
        }
        
        NSString *html = processedHTML;
    
        RLog(RptrLogAreaProtocol, @"3. HTML string created, length: %lu", (unsigned long)[html length]);
        
        RLog(RptrLogAreaProtocol, @"4. Converting HTML to NSData...");
        NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
        if (!htmlData) {
            RLog(RptrLogAreaError, @"ERROR: Failed to encode HTML data");
            [self sendErrorResponse:clientSocket code:500 message:@"Internal Server Error"];
            return;
        }
        RLog(RptrLogAreaProtocol, @"5. HTML data created, size: %lu bytes", (unsigned long)htmlData.length);
    
        RLog(RptrLogAreaProtocol, @"6. Creating HTTP headers...");
        NSString *headers = [NSString stringWithFormat:
                            @"HTTP/1.1 200 OK\r\n"
                            @"Content-Type: text/html\r\n"
                            @"Content-Length: %lu\r\n"
                            @"Connection: close\r\n"
                            @"\r\n",
                            (unsigned long)htmlData.length];
        
        RLog(RptrLogAreaProtocol, @"7. Headers created, length: %lu", (unsigned long)headers.length);
        
        // Send with error checking
        RLog(RptrLogAreaProtocol, @"8. Sending headers...");
        ssize_t headersSent = send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
        if (headersSent < 0) {
            RLog(RptrLogAreaError, @"ERROR: Failed to send headers: %s (errno: %d)", strerror(errno), errno);
            return;
        }
        RLog(RptrLogAreaProtocol, @"9. Headers sent: %zd bytes", headersSent);
    
        // Send data in chunks to avoid large buffer issues
        RLog(RptrLogAreaProtocol, @"10. Preparing to send HTML data in chunks...");
        NSUInteger totalSent = 0;
        NSUInteger dataLength = htmlData.length;
        const uint8_t *bytes = htmlData.bytes;
        
        RLog(RptrLogAreaProtocol, @"11. Total data to send: %lu bytes", (unsigned long)dataLength);
        
        while (totalSent < dataLength) {
            NSUInteger chunkSize = MIN(8192, dataLength - totalSent);
            RLog(RptrLogAreaProtocol, @"Sending chunk: offset=%lu, size=%lu", (unsigned long)totalSent, (unsigned long)chunkSize);
            ssize_t sent = send(clientSocket, bytes + totalSent, chunkSize, MSG_NOSIGNAL);
            if (sent < 0) {
                RLog(RptrLogAreaError, @"ERROR: Failed to send data: %s (errno: %d)", strerror(errno), errno);
                break;
            }
            totalSent += sent;
            RLog(RptrLogAreaProtocol, @"Chunk sent: %zd bytes, total sent: %lu/%lu", sent, (unsigned long)totalSent, (unsigned long)dataLength);
        }
        
        RLog(RptrLogAreaProtocol, @"14. All data sent successfully: %lu bytes", (unsigned long)totalSent);
        
    } @catch (NSException *exception) {
        RLog(RptrLogAreaError, @"EXCEPTION: %@", exception);
        RLog(RptrLogAreaError, @"Exception reason: %@", exception.reason);
        RLog(RptrLogAreaError, @"Stack trace: %@", exception.callStackSymbols);
        [self sendErrorResponse:clientSocket code:500 message:@"Internal Server Error"];
    } @finally {
        RLog(RptrLogAreaProtocol, @"15. Exiting sendViewPageResponse for socket: %d", clientSocket);
    }
}


#pragma mark - Utilities

- (NSArray<NSString *> *)getServerURLs {
    NSMutableArray *cellularURLs = [NSMutableArray array];
    NSMutableArray *wifiURLs = [NSMutableArray array];
    NSMutableArray *otherURLs = [NSMutableArray array];
    
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr != NULL && temp_addr->ifa_addr->sa_family == AF_INET) {
                char ip[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr, ip, INET_ADDRSTRLEN) != NULL) {
                    NSString *ipString = [NSString stringWithUTF8String:ip];
                    NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                    
                    // Skip loopback and link-local addresses
                    if ([ipString isEqualToString:@"127.0.0.1"] || [ipString hasPrefix:@"169.254."]) {
                        temp_addr = temp_addr->ifa_next;
                        continue;
                    }
                    
                    NSString *url = [NSString stringWithFormat:@"http://%@:%lu/view/%@", ipString, (unsigned long)self.port, self.randomPath];
                    
                    // Categorize by interface type
                    if ([interfaceName hasPrefix:@"pdp_ip"] || 
                        [interfaceName hasPrefix:@"rmnet"] ||
                        [interfaceName hasPrefix:@"en2"]) {
                        // Cellular interface
                        [cellularURLs addObject:url];
                        RLog(RptrLogAreaProtocol, @"Found cellular interface %@ with IP %@", interfaceName, ipString);
                    } else if ([interfaceName isEqualToString:@"en0"]) {
                        // WiFi interface
                        [wifiURLs addObject:url];
                        RLog(RptrLogAreaProtocol, @"Found WiFi interface %@ with IP %@", interfaceName, ipString);
                    } else {
                        // Other interfaces (e.g., en1, etc.)
                        [otherURLs addObject:url];
                        RLog(RptrLogAreaProtocol, @"Found other interface %@ with IP %@", interfaceName, ipString);
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    
    // Build final array with cellular first, then WiFi, then others
    NSMutableArray *urls = [NSMutableArray array];
    [urls addObjectsFromArray:cellularURLs];
    [urls addObjectsFromArray:wifiURLs];
    [urls addObjectsFromArray:otherURLs];
    
    if (urls.count == 0) {
        RLog(RptrLogAreaError, @"No network interfaces found!");
    } else {
        RLog(RptrLogAreaProtocol, @"Server URLs ordered by priority: %@", urls);
    }
    
    return urls;
}

- (NSUInteger)connectedClients {
    __block NSUInteger count;
    dispatch_sync(self.clientsQueue, ^{
        count = self.activeClients.count;
    });
    return count;
}

- (void)cleanupInactiveClients {
    dispatch_barrier_async(self.clientsQueue, ^{
        NSDate *now = [NSDate date];
        NSMutableArray *inactiveClients = [NSMutableArray array];
        
        // Find clients that haven't been active for 30 seconds
        for (NSString *clientAddress in self.activeClients.allKeys) {
            NSDate *lastActivity = self.activeClients[clientAddress];
            if ([now timeIntervalSinceDate:lastActivity] > 30.0) {
                [inactiveClients addObject:clientAddress];
            }
        }
        
        // Remove inactive clients
        for (NSString *clientAddress in inactiveClients) {
            [self.activeClients removeObjectForKey:clientAddress];
            RLog(RptrLogAreaProtocol, @"Removing inactive client: %@", clientAddress);
            
            // Notify delegate
            if ([self.delegate respondsToSelector:@selector(hlsServer:clientDisconnected:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate hlsServer:self clientDisconnected:clientAddress];
                });
            }
        }
    });
}

- (BOOL)isStreaming {
    return self.running && self.isWriting;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopServer];
}

#pragma mark - Thread-Safe Accessors

- (void)addClient:(HLSClient *)client forSocket:(int)socket {
    dispatch_barrier_async(self.clientsQueue, ^{
        self.clients[@(socket)] = client;
    });
}

- (void)removeClientForSocket:(int)socket {
    dispatch_barrier_async(self.clientsQueue, ^{
        [self.clients removeObjectForKey:@(socket)];
    });
}

- (HLSClient *)clientForSocket:(int)socket {
    __block HLSClient *client = nil;
    dispatch_sync(self.clientsQueue, ^{
        client = self.clients[@(socket)];
    });
    return client;
}

- (NSArray *)allClientSockets {
    __block NSArray *sockets = nil;
    dispatch_sync(self.clientsQueue, ^{
        sockets = [self.clients.allKeys copy];
    });
    return sockets;
}

- (void)removeAllClients {
    dispatch_barrier_async(self.clientsQueue, ^{
        [self.clients removeAllObjects];
        [self.activeClients removeAllObjects];
    });
}

#pragma mark - Memory Management

- (void)handleMemoryWarning:(NSNotification *)notification {
    RLog(RptrLogAreaProtocol, @"Received memory warning - cleaning up segments");
    
    dispatch_async(self.writerQueue, ^{
        // Clean up more aggressively during memory pressure
        [self.segmentDataLock lock];
        NSUInteger segmentDataCount = self.segmentData.count;
        
        // Keep only the most recent 3 segments in memory
        if (segmentDataCount > 3) {
            dispatch_sync(self.segmentsQueue, ^{
                // Sort segments by sequence number to find oldest
                NSArray *sortedSegments = [self.segments sortedArrayUsingComparator:^NSComparisonResult(HLSSegmentInfo *obj1, HLSSegmentInfo *obj2) {
                    return [@(obj1.sequenceNumber) compare:@(obj2.sequenceNumber)];
                }];
                
                // Remove all but the most recent 3 segments from memory
                NSInteger removeCount = sortedSegments.count - 3;
                if (removeCount > 0) {
                    for (NSInteger i = 0; i < removeCount; i++) {
                        HLSSegmentInfo *segment = sortedSegments[i];
                        [self.segmentData removeObjectForKey:segment.filename];
                        RLog(RptrLogAreaProtocol, @"Removed segment from memory: %@", segment.filename);
                    }
                }
            });
        }
        
        // Clear initialization segment if we're under severe pressure
        if (segmentDataCount > 5) {
            self.initializationSegmentData = nil;
            RLog(RptrLogAreaProtocol, @"Cleared initialization segment from memory");
        }
        
        RLog(RptrLogAreaProtocol, @"Memory cleanup complete - segments in memory: %lu -> %lu",
             (unsigned long)segmentDataCount, (unsigned long)self.segmentData.count);
        [self.segmentDataLock unlock];
    });
}

#pragma mark - Debug Helpers

#ifdef DEBUG
- (void)logWriterState {
    dispatch_async(self.writerQueue, ^{
        RLog(RptrLogAreaProtocol, @"=== Writer State ===");
        RLog(RptrLogAreaProtocol, @"Server running: %@", self.running ? @"YES" : @"NO");
        RLog(RptrLogAreaProtocol, @"Is writing: %@", self.isWriting ? @"YES" : @"NO");
        RLog(RptrLogAreaProtocol, @"Session started: %@", self.sessionStarted ? @"YES" : @"NO");
        RLog(RptrLogAreaProtocol, @"Asset writer: %@", self.assetWriter ? @"EXISTS" : @"NIL");
        if (self.assetWriter) {
            RLog(RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
            RLog(RptrLogAreaError, @"Writer error: %@", self.assetWriter.error);
        }
        RLog(RptrLogAreaVideoParams, @"Video input: %@", self.videoInput ? @"EXISTS" : @"NIL");
        RLog(RptrLogAreaVideoParams, @"Frames processed: %ld", (long)self.framesProcessed);
        RLog(RptrLogAreaProtocol, @"Frames dropped: %ld", (long)self.framesDropped);
        RLog(RptrLogAreaProtocol, @"Current segment: %ld", (long)self.currentSegmentIndex);
        RLog(RptrLogAreaProtocol, @"Segments count: %lu", (unsigned long)self.segments.count);
        RLog(RptrLogAreaProtocol, @"==================");
    });
}
#else
- (void)logWriterState {
    // No-op in release builds
}
#endif

#pragma mark - AVAssetWriterDelegate

- (void)assetWriter:(AVAssetWriter *)writer didOutputSegmentData:(NSData *)segmentData segmentType:(AVAssetSegmentType)segmentType segmentReport:(AVAssetSegmentReport *)segmentReport {
    NSString *segmentTypeStr = (segmentType == AVAssetSegmentTypeInitialization) ? @"INIT" : @"MEDIA";
    
    // Calculate time since last segment for automatic segmentation tracking
    NSTimeInterval timeSinceLastSegment = 0;
    if (self.currentSegmentStartTime) {
        timeSinceLastSegment = [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime];
    }
    
    RLog(RptrLogAreaProtocol, @"[DELEGATE] ========== AUTOMATIC SEGMENT OUTPUT ==========");
    RLog(RptrLogAreaProtocol, @"[DELEGATE] Type: %@, Size: %lu bytes", segmentTypeStr, (unsigned long)segmentData.length);
    RLog(RptrLogAreaProtocol, @"[DELEGATE] Time since last segment: %.2f seconds", timeSinceLastSegment);
    RLog(RptrLogAreaProtocol, @"[DELEGATE] Frames in segment: %ld", (long)self.framesProcessed);
    RLog(RptrLogAreaProtocol, @"[DELEGATE] Report available: %@", segmentReport ? @"YES" : @"NO");
    
    // TEST 3: Track delegate callback timing with 6-second intervals
    static NSDate *lastDelegateCall = nil;
    static int delegateCallCount = 0;
    delegateCallCount++;
    
    if (lastDelegateCall) {
        NSTimeInterval interval = [[NSDate date] timeIntervalSinceDate:lastDelegateCall];
        RLog(RptrLogAreaProtocol, @"[TEST3] Delegate callback #%d, %.2fs since last callback (target: 6.0s)", 
             delegateCallCount, interval);
        if (interval > 5.0 && interval < 7.0) {
            RLog(RptrLogAreaProtocol, @"[TEST3-SUCCESS] Segment output at expected interval!");
        }
    } else {
        RLog(RptrLogAreaProtocol, @"[TEST3] First delegate callback (#%d) - automatic segmentation is working!", delegateCallCount);
    }
    lastDelegateCall = [NSDate date];
    
    // Log segment report details if available (per Apple best practices)
    if (segmentReport && segmentType == AVAssetSegmentTypeSeparable) {
        for (AVAssetSegmentTrackReport *trackReport in segmentReport.trackReports) {
            RLog(RptrLogAreaVideoParams, @"[SEGMENT REPORT] Track ID: %d", trackReport.trackID);
            RLog(RptrLogAreaVideoParams, @"[SEGMENT REPORT] Media type: %@", trackReport.mediaType);
            RLog(RptrLogAreaVideoParams, @"[SEGMENT REPORT] Duration: %.3f", CMTimeGetSeconds(trackReport.duration));
            RLog(RptrLogAreaVideoParams, @"[SEGMENT REPORT] First frame PTS: %.3f", CMTimeGetSeconds(trackReport.earliestPresentationTimeStamp));
        }
    }
    
    dispatch_async(self.writerQueue, ^{
        if (segmentType == AVAssetSegmentTypeInitialization) {
            // Check if this is a duplicate init segment from writer recreation
            if (self.hasGeneratedInitSegment && self.savedInitSegmentData) {
                RLog(RptrLogAreaProtocol, @"[INIT SEGMENT] Ignoring duplicate init segment from writer recreation");
                RLog(RptrLogAreaProtocol, @"[INIT SEGMENT] Using preserved init segment (%lu bytes)", (unsigned long)self.savedInitSegmentData.length);
                // Use the saved init segment instead
                self.initializationSegmentData = self.savedInitSegmentData;
                return;
            }
            
            // First init segment - save it for reuse
            self.initializationSegmentData = segmentData;
            self.savedInitSegmentData = segmentData;
            self.hasGeneratedInitSegment = YES;
            RLog(RptrLogAreaProtocol, @"[INIT SEGMENT] Stored FIRST initialization segment: %lu bytes", (unsigned long)segmentData.length);
            RLog(RptrLogAreaProtocol, @"[INIT SEGMENT] Will preserve this for all future segments");
            
            // DEBUG: Analyze init segment box structure
            if (segmentData.length >= 32) {
                const uint8_t *bytes = (const uint8_t *)segmentData.bytes;
                
                // Parse first box (should be 'ftyp' for init segments)
                uint32_t box1Size = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
                NSString *box1Type = [[NSString alloc] initWithBytes:&bytes[4] length:4 encoding:NSASCIIStringEncoding];
                
                // Parse second box if there's space
                NSString *box2Type = @"";
                if (segmentData.length > box1Size + 8) {
                    uint32_t box2Offset = box1Size;
                    box2Type = [[NSString alloc] initWithBytes:&bytes[box2Offset+4] length:4 encoding:NSASCIIStringEncoding];
                }
                
                RLog(RptrLogAreaProtocol, @"[fMP4-INIT] Init segment boxes: [%@:%u bytes] [%@]", 
                     box1Type, box1Size, box2Type);
                
                // Check for proper fMP4 init structure
                if (![box1Type isEqualToString:@"ftyp"]) {
                    RLog(RptrLogAreaError, @"[fMP4-ERROR] Init segment does not start with 'ftyp' box! Found: %@", box1Type);
                }
            }
            
        } else if (segmentType == AVAssetSegmentTypeSeparable) {
            // Generate unique segment ID for tracing
            NSString *segmentID = [[NSUUID UUID] UUIDString].lowercaseString;
            NSString *shortID = [segmentID substringToIndex:8]; // First 8 chars for brevity
            
            // Store media segment using mediaSequenceNumber to ensure playlist references match
            NSString *segmentName = [NSString stringWithFormat:@"segment_%03ld.m4s", (long)self.mediaSequenceNumber];
            
            // Log segment lifecycle: CREATED
            RLog(RptrLogAreaProtocol, @"[SEG-%@] CREATED: seq=%ld, name=%@, size=%lu bytes", 
                 shortID, (long)self.mediaSequenceNumber, segmentName, (unsigned long)segmentData.length);
            RLog(RptrLogAreaProtocol, @"[QoE] Segment %ld created successfully", (long)self.mediaSequenceNumber);
            
            // DEBUG: Analyze segment box structure for fMP4 compliance
            if (segmentData.length >= 32) {
                const uint8_t *bytes = (const uint8_t *)segmentData.bytes;
                
                // Parse first box (should be 'moof' for media segments)
                uint32_t box1Size = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
                NSString *box1Type = [[NSString alloc] initWithBytes:&bytes[4] length:4 encoding:NSASCIIStringEncoding];
                
                // Parse second box if there's space
                NSString *box2Type = @"";
                if (segmentData.length > box1Size + 8) {
                    uint32_t box2Offset = box1Size;
                    // uint32_t box2Size = (bytes[box2Offset] << 24) | (bytes[box2Offset+1] << 16) | 
                    //                    (bytes[box2Offset+2] << 8) | bytes[box2Offset+3];
                    box2Type = [[NSString alloc] initWithBytes:&bytes[box2Offset+4] length:4 encoding:NSASCIIStringEncoding];
                }
                
                RLog(RptrLogAreaProtocol, @"[fMP4-STRUCTURE] Segment %@ boxes: [%@:%u bytes] [%@]", 
                     segmentName, box1Type, box1Size, box2Type);
                
                // Check for proper fMP4 structure
                if (![box1Type isEqualToString:@"moof"]) {
                    RLog(RptrLogAreaError, @"[fMP4-ERROR] Segment does not start with 'moof' box! Found: %@", box1Type);
                }
                if (![box2Type isEqualToString:@"mdat"] && box2Type.length > 0) {
                    RLog(RptrLogAreaError, @"[fMP4-ERROR] Second box is not 'mdat'! Found: %@", box2Type);
                }
            }
            
            // Log segment lifecycle: STORING
            RLog(RptrLogAreaProtocol, @"[SEG-%@] STORING: Adding to memory dictionary", shortID);
            
            [self.segmentDataLock lock];
            [self.segmentData setObject:segmentData forKey:segmentName];
            
            // Track segment memory usage for diagnostics
            NSUInteger totalSegmentMemory = 0;
            for (NSData *data in self.segmentData.allValues) {
                totalSegmentMemory += data.length;
            }
            [self.segmentDataLock unlock];
            
            // Report to diagnostics
            [[RptrDiagnostics sharedDiagnostics] updateSegmentMemoryUsage:totalSegmentMemory];
            
            // Create segment info with tracing ID
            HLSSegmentInfo *segmentInfo = [[HLSSegmentInfo alloc] init];
            segmentInfo.filename = segmentName;
            
            // Calculate segment duration properly
            CMTime segmentDuration = CMTimeMakeWithSeconds(self.qualitySettings.segmentDuration, 600);
            if (segmentReport && segmentReport.trackReports.count > 0) {
                CMTime reportedDuration = segmentReport.trackReports.firstObject.duration;
                // Only use reported duration if it's valid and non-zero
                if (CMTIME_IS_VALID(reportedDuration) && CMTimeGetSeconds(reportedDuration) > 0.1) {
                    segmentDuration = reportedDuration;
                } else {
                    // Use elapsed time for segments with no valid duration
                    NSTimeInterval elapsed = self.currentSegmentStartTime ? 
                        [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime] : 
                        self.qualitySettings.segmentDuration;
                    segmentDuration = CMTimeMakeWithSeconds(elapsed, 600);
                    RLog(RptrLogAreaProtocol, @"[SEG-%@] Using elapsed time for duration: %.2fs", shortID, elapsed);
                }
            }
            
            segmentInfo.duration = segmentDuration;
            segmentInfo.sequenceNumber = self.mediaSequenceNumber;
            segmentInfo.createdAt = [NSDate date];
            segmentInfo.fileSize = segmentData.length;
            segmentInfo.segmentID = shortID;
            
            // Track with observer for lifecycle monitoring
            [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventCreated
                                                       segmentName:segmentName
                                                    sequenceNumber:self.mediaSequenceNumber
                                                              size:segmentData.length
                                                         segmentID:shortID];
            
            dispatch_barrier_async(self.segmentsQueue, ^{
                [self.segments addObject:segmentInfo];
                
                // Log segment lifecycle: STORED
                RLog(RptrLogAreaProtocol, @"[SEG-%@] STORED: Added to segments array (total=%lu)", 
                     shortID, (unsigned long)self.segments.count);
                
                // Track storage event with observer
                [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventStored
                                                           segmentName:segmentInfo.filename
                                                        sequenceNumber:segmentInfo.sequenceNumber
                                                                  size:segmentInfo.fileSize
                                                             segmentID:segmentInfo.segmentID];
                
                // Clean up old segments to prevent memory buildup
                if (self.segments.count > self.qualitySettings.maxSegments) {
                    NSInteger removeCount = self.segments.count - self.qualitySettings.maxSegments;
                    for (NSInteger i = 0; i < removeCount; i++) {
                        HLSSegmentInfo *oldSegment = self.segments[0];
                        [self.segmentDataLock lock];
                        
                        // Try removing with the stored filename first
                        if ([self.segmentData objectForKey:oldSegment.filename]) {
                            [self.segmentData removeObjectForKey:oldSegment.filename];
                            RLog(RptrLogAreaProtocol, @"[SEG-%@] REMOVED: %@ (seq=%ld) to maintain max=%ld segments", 
                                 oldSegment.segmentID ?: @"UNKNOWN", oldSegment.filename, (long)oldSegment.sequenceNumber, (long)self.qualitySettings.maxSegments);
                            
                            // Track removal event with observer
                            [[HLSSegmentObserver sharedObserver] trackSegmentEvent:HLSSegmentEventRemoved
                                                                       segmentName:oldSegment.filename
                                                                    sequenceNumber:oldSegment.sequenceNumber
                                                                              size:oldSegment.fileSize
                                                                         segmentID:oldSegment.segmentID];
                        } else {
                            // Also try with sequence number based name (for transition period)
                            NSString *altName = [NSString stringWithFormat:@"segment_%03ld.m4s", (long)oldSegment.sequenceNumber];
                            if ([self.segmentData objectForKey:altName]) {
                                [self.segmentData removeObjectForKey:altName];
                                RLog(RptrLogAreaProtocol, @"Removed old segment with alt name: %@", altName);
                            }
                        }
                        
                        [self.segmentDataLock unlock];
                        [self.segments removeObjectAtIndex:0];
                    }
                }
            });
            
            // Log segment lifecycle: PLAYLIST UPDATE
            RLog(RptrLogAreaProtocol, @"[SEG-%@] PLAYLIST: Updating playlist with new segment", shortID);
            
            // Update playlist with current segment
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updatePlaylist];
            });
            
            // Now increment counter for the next segment
            self.mediaSequenceNumber++;
            
            // Reset segment start time for tracking automatic segmentation
            self.currentSegmentStartTime = [NSDate date];
            self.framesProcessed = 0; // Reset frame counter for next segment
            
            RLog(RptrLogAreaProtocol, @"[SEG-%@] COMPLETE: Ready for next segment (nextSeq=%ld)", 
                 shortID, (long)self.mediaSequenceNumber);
            RLog(RptrLogAreaProtocol, @"[AUTO-SEG] Automatic segmentation continuing - next segment will output in ~%.1fs", 
                 self.qualitySettings.segmentDuration);
            
            // Log QoE metrics per Apple best practices
            RLog(RptrLogAreaProtocol, @"[QoE] Total segments created: %ld", (long)self.mediaSequenceNumber);
            RLog(RptrLogAreaProtocol, @"[QoE] Segments in memory: %lu", (unsigned long)self.segmentData.count);
            
            // Clean up old segments
            [self cleanupOldSegments];
        }
    });
}

#pragma mark - Template Methods

- (void)sendEmbeddedViewPageResponse:(int)clientSocket {
    // Fallback embedded HTML when template is not available
    RLog(RptrLogAreaProtocol, @"Using embedded fallback HTML");
    
    // Use the original embedded HTML that was working
    NSString *html = @"<!DOCTYPE html>\n"
                     @"<html>\n"
                     @"<head>\n"
                     @"<title>Share Stream</title>\n"
                     @"<meta name='viewport' content='width=device-width, initial-scale=1'>\n"
                     @"<style>\n"
                     @"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; margin: 0; background: #f5f5f5; padding-top: 60px; }\n"
                     @".title-bar { position: fixed; top: 0; left: 0; right: 0; height: 60px; background: #1e3a8a; color: white; display: flex; align-items: center; padding: 0 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); z-index: 1000; }\n"
                     @".title-bar h3 { margin: 0; font-size: 20px; font-weight: 500; }\n"
                     @".main-container { display: flex; gap: 20px; max-width: 1200px; margin: 0 auto; padding: 20px; }\n"
                     @".video-container { flex: 2; }\n"
                     @".map-container { flex: 1; min-width: 300px; }\n"
                     @"video { width: 100%; background: #000; display: block; }\n"
                     @"#mapContainer { width: 100%; height: 400px; border: 2px solid #ddd; border-radius: 8px; }\n"
                     @"@media (max-width: 768px) { body { padding-top: 50px; } .title-bar { height: 50px; padding: 0 15px; } .title-bar h3 { font-size: 18px; } .main-container { flex-direction: column; padding: 10px; gap: 15px; } .map-container { min-width: unset; width: 100%; } #mapContainer { height: 300px; } button { width: 100%; max-width: 300px; margin: 5px auto; display: block; } }\n"
                     @".status { margin: 10px 0; padding: 10px; background: #e8f5e8; border-left: 4px solid #4CAF50; display: none; }\n"
                     @".status.connecting { background: #fff3cd; border-left-color: #ffc107; }\n"
                     @".status.error { background: #f8d7da; border-left-color: #dc3545; }\n"
                     @".debug-active .status { display: block; }\n"
                     @".connection-indicator { position: fixed; top: 10px; right: 10px; width: 12px; height: 12px; border-radius: 50%; background: #4CAF50; }\n"
                     @".connection-indicator.connecting { background: #ffc107; }\n"
                     @".connection-indicator.error { background: #dc3545; }\n"
                     @"</style>\n"
                     @"</head>\n"
                     @"<body>\n"
                     @"<div class='title-bar'>\n"
                     @"<h3>Share Stream</h3>\n"
                     @"</div>\n"
                     @"<div class='connection-indicator' id='connectionStatus'></div>\n"
                     @"<div class='main-container'>\n"
                     @"<div class='video-container'>\n"
                     @"<video id='video' controls autoplay playsinline></video>\n"
                     @"</div>\n"
                     @"<div class='map-container'>\n"
                     @"<div id='mapContainer'></div>\n"
                     @"</div>\n"
                     @"</div>\n"
                     @"<div class='status' id='status'>Connecting to stream...</div>\n"
                     @"<link rel='stylesheet' href='https://unpkg.com/leaflet@1.9.4/dist/leaflet.css' />\n"
                     @"<script src='https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'></script>\n"
                     @"<script src='https://cdn.jsdelivr.net/npm/hls.js@latest'></script>\n"
                     @"<script src='/js/udp_logger.js'></script>\n"
                     @"<script>\n"
                     @"console.log('Script starting - HLS.js version:', typeof Hls !== 'undefined' ? Hls.version : 'NOT LOADED');\n"
                     @"console.log('Page URL:', window.location.href);\n"
                     @"\n"
                     @"var video = document.getElementById('video');\n"
                     @"var status = document.getElementById('status');\n"
                     @"var connectionStatus = document.getElementById('connectionStatus');\n"
                     @"var videoSrc = window.location.origin + '/stream/' + window.location.pathname.split('/')[2] + '/playlist.m3u8';\n"
                     @"console.log('Stream URL:', videoSrc);\n"
                     @"\n"
                     @"var hls = null;\n"
                     @"var map = null;\n"
                     @"\n"
                     @"function initializeMap() {\n"
                     @"  if (map) return;\n"
                     @"  fetch('/location')\n"
                     @"    .then(response => response.json())\n"
                     @"    .then(data => {\n"
                     @"      if (data.latitude && data.longitude) {\n"
                     @"        map = L.map('mapContainer').setView([data.latitude, data.longitude], 15);\n"
                     @"        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {\n"
                     @"          attribution: '© OpenStreetMap contributors'\n"
                     @"        }).addTo(map);\n"
                     @"        L.marker([data.latitude, data.longitude])\n"
                     @"          .addTo(map)\n"
                     @"          .bindPopup('Device Location');\n"
                     @"      }\n"
                     @"    })\n"
                     @"    .catch(error => {\n"
                     @"      console.error('Error loading map:', error);\n"
                     @"    });\n"
                     @"}\n"
                     @"\n"
                     @"function setConnectionStatus(state) {\n"
                     @"  connectionStatus.className = 'connection-indicator ' + state;\n"
                     @"  status.className = 'status ' + state;\n"
                     @"}\n"
                     @"\n"
                     @"function initHLS() {\n"
                     @"  console.log('initHLS called');\n"
                     @"  if (hls) {\n"
                     @"    console.log('Destroying existing HLS instance');\n"
                     @"    hls.destroy();\n"
                     @"  }\n"
                     @"  \n"
                     @"  console.log('Checking HLS support...');\n"
                     @"  if (!Hls.isSupported()) {\n"
                     @"    if (video.canPlayType('application/vnd.apple.mpegurl')) {\n"
                     @"      video.src = videoSrc;\n"
                     @"      status.innerHTML = 'Using native HLS support';\n"
                     @"      setConnectionStatus('');\n"
                     @"    } else {\n"
                     @"      status.innerHTML = 'HLS not supported in this browser';\n"
                     @"      setConnectionStatus('error');\n"
                     @"    }\n"
                     @"    return;\n"
                     @"  }\n"
                     @"  \n"
                     @"  console.log('Creating HLS instance with debug enabled');\n"
                     @"  hls = new Hls({\n"
                     @"    debug: true,  // Enable full debugging to diagnose issues\n"
                     @"    enableWorker: true,\n"
                     @"    lowLatencyMode: false,\n"
                     @"    maxBufferLength: 60,\n"
                     @"    liveSyncDurationCount: 4,\n"
                     @"    fragLoadingTimeOut: 20000,\n"
                     @"    fragLoadingMaxRetry: 6,\n"
                     @"    manifestLoadingTimeOut: 10000,\n"
                     @"    manifestLoadingMaxRetry: 4\n"
                     @"  });\n"
                     @"  console.log('HLS instance created:', hls);\n"
                     @"  \n"
                     @"  setConnectionStatus('connecting');\n"
                     @"  status.innerHTML = 'Connecting to stream...';\n"
                     @"  \n"
                     @"  console.log('Loading source:', videoSrc);\n"
                     @"  hls.loadSource(videoSrc);\n"
                     @"  console.log('Attaching to video element');\n"
                     @"  hls.attachMedia(video);\n"
                     @"  \n"
                     @"  hls.on(Hls.Events ? Hls.Events.MANIFEST_PARSED : 'hlsManifestParsed', function() {\n"
                     @"    status.innerHTML = 'Stream connected';\n"
                     @"    setConnectionStatus('');\n"
                     @"    video.play().catch(function(e) {\n"
                     @"      console.log('Autoplay prevented:', e);\n"
                     @"    });\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Segment tracking for integrated traceability\n"
                     @"  var segmentTracker = {\n"
                     @"    segments: {},\n"
                     @"    currentSegment: null,\n"
                     @"    \n"
                     @"    reportEvent: function(eventType, segmentNum, details) {\n"
                     @"      var event = {\n"
                     @"        type: eventType,\n"
                     @"        segment: segmentNum,\n"
                     @"        timestamp: new Date().toISOString(),\n"
                     @"        details: details\n"
                     @"      };\n"
                     @"      \n"
                     @"      // Log locally\n"
                     @"      console.log('[CLIENT-SEG-' + segmentNum + '] ' + eventType + ':', details);\n"
                     @"      \n"
                     @"      // Could report to server via beacon API if needed\n"
                     @"      // For now, console logging is sufficient for debugging\n"
                     @"    },\n"
                     @"    \n"
                     @"    extractSegmentNumber: function(url) {\n"
                     @"      var match = url.match(/segment_(\\d+)\\.m4s/);\n"
                     @"      return match ? parseInt(match[1]) : -1;\n"
                     @"    }\n"
                     @"  };\n"
                     @"  \n"
                     @"  // Track fragment loading\n"
                     @"  hls.on(Hls.Events ? Hls.Events.FRAG_LOADING : 'hlsFragLoading', function(event, data) {\n"
                     @"    var segNum = segmentTracker.extractSegmentNumber(data.frag.url);\n"
                     @"    if (segNum >= 0) {\n"
                     @"      segmentTracker.currentSegment = segNum;\n"
                     @"      segmentTracker.segments[segNum] = {\n"
                     @"        requestStart: Date.now(),\n"
                     @"        url: data.frag.url\n"
                     @"      };\n"
                     @"      segmentTracker.reportEvent('REQUESTING', segNum, {\n"
                     @"        url: data.frag.url,\n"
                     @"        sn: data.frag.sn\n"
                     @"      });\n"
                     @"    }\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Track fragment loaded\n"
                     @"  hls.on(Hls.Events ? Hls.Events.FRAG_LOADED : 'hlsFragLoaded', function(event, data) {\n"
                     @"    var segNum = segmentTracker.extractSegmentNumber(data.frag.url);\n"
                     @"    if (segNum >= 0 && segmentTracker.segments[segNum]) {\n"
                     @"      var loadTime = Date.now() - segmentTracker.segments[segNum].requestStart;\n"
                     @"      segmentTracker.segments[segNum].loadTime = loadTime;\n"
                     @"      segmentTracker.reportEvent('RECEIVED', segNum, {\n"
                     @"        duration: data.frag.duration,\n"
                     @"        loadTime: loadTime + 'ms',\n"
                     @"        bytes: data.stats.total\n"
                     @"      });\n"
                     @"    }\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Track buffer appending\n"
                     @"  hls.on(Hls.Events ? Hls.Events.BUFFER_APPENDING : 'hlsBufferAppending', function(event, data) {\n"
                     @"    if (segmentTracker.currentSegment !== null) {\n"
                     @"      segmentTracker.reportEvent('BUFFERING', segmentTracker.currentSegment, {\n"
                     @"        type: data.type,\n"
                     @"        bytes: data.data ? data.data.length : 0\n"
                     @"      });\n"
                     @"    }\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Track buffer appended (playback ready)\n"
                     @"  hls.on(Hls.Events ? Hls.Events.BUFFER_APPENDED : 'hlsBufferAppended', function(event, data) {\n"
                     @"    if (segmentTracker.currentSegment !== null) {\n"
                     @"      segmentTracker.reportEvent('PLAYING', segmentTracker.currentSegment, {\n"
                     @"        timeRange: data.timeRanges\n"
                     @"      });\n"
                     @"    }\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Track errors\n"
                     @"  hls.on(Hls.Events ? Hls.Events.FRAG_LOAD_ERROR : 'hlsFragLoadError', function(event, data) {\n"
                     @"    var segNum = segmentTracker.extractSegmentNumber(data.frag.url);\n"
                     @"    if (segNum >= 0) {\n"
                     @"      segmentTracker.reportEvent('ERROR', segNum, {\n"
                     @"        type: 'LOAD_ERROR',\n"
                     @"        details: data.details,\n"
                     @"        response: data.response ? data.response.code : 'unknown'\n"
                     @"      });\n"
                     @"    }\n"
                     @"  });\n"
                     @"  \n"
                     @"  // Track stalls\n"
                     @"  hls.on(Hls.Events ? Hls.Events.BUFFER_STALLED_ERROR : 'hlsBufferStalledError', function(event, data) {\n"
                     @"    segmentTracker.reportEvent('STALLED', segmentTracker.currentSegment || -1, {\n"
                     @"      buffer: data.buffer\n"
                     @"    });\n"
                     @"  });\n"
                     @"  \n"
                     @"  hls.on(Hls.Events ? Hls.Events.LEVEL_UPDATED : 'hlsLevelUpdated', function(event, data) {\n"
                     @"    console.log('Level updated, fragments:', data.details.fragments.length);\n"
                     @"  });\n"
                     @"  \n"
                     @"  hls.on(Hls.Events ? Hls.Events.ERROR : 'hlsError', function (event, data) {\n"
                     @"    console.error('HLS ERROR:', data.type, data.details, data);\n"
                     @"    if (data.fatal) {\n"
                     @"      status.innerHTML = 'Connection lost - Reconnecting...';\n"
                     @"      setConnectionStatus('error');\n"
                     @"      setTimeout(function() {\n"
                     @"        initHLS();\n"
                     @"      }, 1000);\n"
                     @"    }\n"
                     @"  });\n"
                     @"}\n"
                     @"\n"
                     @"// Mobile detection\n"
                     @"var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);\n"
                     @"if (isMobile) {\n"
                     @"  document.body.classList.add('mobile-device');\n"
                     @"}\n"
                     @"\n"
                     @"// Debug mode toggle\n"
                     @"var debugMode = false;\n"
                     @"document.addEventListener('keydown', function(e) {\n"
                     @"  if (e.key === 'd' && e.ctrlKey) {\n"
                     @"    e.preventDefault();\n"
                     @"    debugMode = !debugMode;\n"
                     @"    document.body.classList.toggle('debug-active', debugMode);\n"
                     @"  }\n"
                     @"});\n"
                     @"\n"
                     @"// Touch gesture for debug mode on mobile (triple tap title bar)\n"
                     @"var touchCount = 0;\n"
                     @"var touchTimer = null;\n"
                     @"document.addEventListener('touchend', function(e) {\n"
                     @"  if (e.target.closest('.title-bar')) {\n"
                     @"    touchCount++;\n"
                     @"    if (touchCount === 3) {\n"
                     @"      debugMode = !debugMode;\n"
                     @"      document.body.classList.toggle('debug-active', debugMode);\n"
                     @"      touchCount = 0;\n"
                     @"    }\n"
                     @"    clearTimeout(touchTimer);\n"
                     @"    touchTimer = setTimeout(function() {\n"
                     @"      touchCount = 0;\n"
                     @"    }, 1000);\n"
                     @"  }\n"
                     @"});\n"
                     @"\n"
                     @"// Status polling function\n"
                     @"function updateStatus() {\n"
                     @"  var requestUrl = window.location.origin + '/status';\n"
                     @"  console.log('Status poll: Requesting', requestUrl);\n"
                     @"  \n"
                     @"  fetch(requestUrl)\n"
                     @"    .then(response => {\n"
                     @"      console.log('Status poll: Response received', response.status, response.statusText);\n"
                     @"      if (!response.ok) {\n"
                     @"        throw new Error('Response not ok: ' + response.status);\n"
                     @"      }\n"
                     @"      return response.json();\n"
                     @"    })\n"
                     @"    .then(data => {\n"
                     @"      console.log('Status poll: Data received', JSON.stringify(data));\n"
                     @"      \n"
                     @"      // Update title if changed\n"
                     @"      if (data.title) {\n"
                     @"        var titleElement = document.querySelector('.title-bar h3');\n"
                     @"        if (titleElement) {\n"
                     @"          titleElement.textContent = data.title;\n"
                     @"          console.log('Status poll: Title updated to', data.title);\n"
                     @"        }\n"
                     @"      }\n"
                     @"      \n"
                     @"      // Update map location if changed\n"
                     @"      if (data.location && data.location.latitude && data.location.longitude) {\n"
                     @"        if (map) {\n"
                     @"          var newLatLng = [data.location.latitude, data.location.longitude];\n"
                     @"          map.setView(newLatLng, 15);\n"
                     @"          console.log('Status poll: Location updated to', newLatLng);\n"
                     @"          \n"
                     @"          // Update or create marker\n"
                     @"          if (!window.deviceMarker) {\n"
                     @"            window.deviceMarker = L.marker(newLatLng).addTo(map);\n"
                     @"          } else {\n"
                     @"            window.deviceMarker.setLatLng(newLatLng);\n"
                     @"          }\n"
                     @"          window.deviceMarker.bindPopup('Device Location<br>Accuracy: ' + (data.location.accuracy || 'Unknown') + 'm');\n"
                     @"        }\n"
                     @"      }\n"
                     @"    })\n"
                     @"    .catch(error => {\n"
                     @"      console.error('Status poll: Error fetching status:', error);\n"
                     @"    });\n"
                     @"}\n"
                     @"\n"
                     @"// Initialize on load\n"
                     @"console.log('Initializing application...');\n"
                     @"console.log('Calling initializeMap()...');\n"
                     @"initializeMap();\n"
                     @"console.log('Calling initHLS()...');\n"
                     @"initHLS();\n"
                     @"\n"
                     @"// Start status polling every 10 seconds\n"
                     @"console.log('Starting status polling - will poll every 10 seconds');\n"
                     @"setInterval(updateStatus, 10000);\n"
                     @"// Do an immediate poll\n"
                     @"updateStatus();\n"
                     @"</script>\n"
                     @"</body>\n"
                     @"</html>\n";
    
    NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: text/html\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)htmlData.length];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    send(clientSocket, htmlData.bytes, htmlData.length, MSG_NOSIGNAL);
}

- (void)sendBundledResourceResponse:(int)clientSocket path:(NSString *)path {
    // Remove leading slash
    if ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }
    
    // Get resource path from bundle
    // First try the WebResources subdirectory structure
    NSString *resourcePath = [[NSBundle mainBundle] pathForResource:[path lastPathComponent]
                                                              ofType:nil
                                                        inDirectory:[@"WebResources" stringByAppendingPathComponent:[path stringByDeletingLastPathComponent]]];
    
    // If not found, try the root of the bundle (for backwards compatibility)
    if (!resourcePath) {
        resourcePath = [[NSBundle mainBundle] pathForResource:[path lastPathComponent] ofType:nil];
    }
    
    if (!resourcePath) {
        RLog(RptrLogAreaError, @"Resource not found: %@", path);
        [self sendErrorResponse:clientSocket code:404 message:@"Resource not found"];
        return;
    }
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:resourcePath options:0 error:&error];
    
    if (error || !data) {
        RLog(RptrLogAreaError, @"Error reading resource %@: %@", path, error);
        [self sendErrorResponse:clientSocket code:500 message:@"Error reading resource"];
        return;
    }
    
    // Determine MIME type
    NSString *mimeType = @"application/octet-stream";
    if ([path hasSuffix:@".css"]) {
        mimeType = @"text/css";
    } else if ([path hasSuffix:@".js"]) {
        mimeType = @"application/javascript";
    } else if ([path hasSuffix:@".png"]) {
        mimeType = @"image/png";
    } else if ([path hasSuffix:@".jpg"] || [path hasSuffix:@".jpeg"]) {
        mimeType = @"image/jpeg";
    } else if ([path hasSuffix:@".gif"]) {
        mimeType = @"image/gif";
    } else if ([path hasSuffix:@".svg"]) {
        mimeType = @"image/svg+xml";
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: %@\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Cache-Control: no-cache, no-store, must-revalidate\r\n"
                        @"Pragma: no-cache\r\n"
                        @"Expires: 0\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        mimeType,
                        (unsigned long)data.length];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    send(clientSocket, data.bytes, data.length, MSG_NOSIGNAL);
    
    RLog(RptrLogAreaProtocol, @"Served bundled resource: %@ (%@ bytes)", path, @(data.length));
}

- (NSString *)generateRandomString:(NSInteger)length {
    NSString *letters = @"abcdefghijklmnopqrstuvwxyz";
    NSMutableString *randomString = [NSMutableString stringWithCapacity:length];
    
    for (NSInteger i = 0; i < length; i++) {
        uint32_t randomIndex = arc4random_uniform((uint32_t)letters.length);
        [randomString appendFormat:@"%C", [letters characterAtIndex:randomIndex]];
    }
    
    return randomString;
}

- (void)regenerateRandomPath {
    // Store the previous path so we can return proper errors for old requests
    self.previousRandomPath = _randomPath;
    
    // Generate new random path
    _randomPath = [self generateRandomString:10];
    RLog(RptrLogAreaProtocol, @"Regenerated randomized URL path: %@ (was: %@)", _randomPath, self.previousRandomPath);
    
    // Clear all active clients
    dispatch_barrier_async(self.clientsQueue, ^{
        [self.activeClients removeAllObjects];
    });
    
    // Clear the previous path after a delay to allow final 410 responses
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.previousRandomPath = nil;
        RLog(RptrLogAreaProtocol, @"Cleared previous random path - old URLs will now get 404");
    });
    
    // Clear segment data to force fresh start with new path
    [self.segmentDataLock lock];
    [self.segmentData removeAllObjects];
    self.initializationSegmentData = nil;
    [self.segmentDataLock unlock];
    
    // Clean up all segment files before clearing the list
    [self cleanupAllSegments];
    
    // Reset segment index with offset to avoid conflicts with cached segments
    // Use current timestamp to ensure unique segment numbers
    self.currentSegmentIndex = (NSInteger)([[NSDate date] timeIntervalSince1970] / 100) % 1000;
    self.mediaSequenceNumber = self.currentSegmentIndex;
    RLog(RptrLogAreaProtocol, @"Reset segment counters to %ld", (long)self.mediaSequenceNumber);
    RLog(RptrLogAreaProtocol, @"[COUNTER RESET] currentSegmentIndex=%ld, mediaSequenceNumber=%ld", 
         (long)self.currentSegmentIndex, (long)self.mediaSequenceNumber);
    
    // Clear playlist file if it exists
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    [[NSFileManager defaultManager] removeItemAtPath:playlistPath error:nil];
    
    // Stop current writer if active
    if (self.isWriting) {
        RLog(RptrLogAreaProtocol, @"Stopping active writer before path regeneration");
        dispatch_async(self.writerQueue, ^{
            [self stopAssetWriter];
        });
    }
    
    // Create an initial empty playlist file for the new URL
    // This ensures clients get a valid (but empty) playlist instead of 404
    [self updatePlaylist];
    
    RLog(RptrLogAreaProtocol, @"Path regeneration complete - all segments cleared, empty playlist created");
    
    // Notify delegate if needed
    if ([self.delegate respondsToSelector:@selector(hlsServerDidStart:)]) {
        NSArray *urls = [self getServerURLs];
        if (urls.count > 0) {
            [self.delegate hlsServerDidStart:urls.firstObject];
        }
    }
}

#pragma mark - Thread-Safe Property Access

- (NSString *)getStreamTitle {
    // Since streamTitle is atomic, we can safely read it directly
    // No need for additional synchronization
    return self.streamTitle;
}

- (void)setStreamTitleAsync:(NSString *)title {
    // Since streamTitle is atomic, we can safely set it directly
    // The atomic property ensures thread safety for simple assignment
    self.streamTitle = title;
    RLog(RptrLogAreaProtocol, @"Stream title updated to: %@", title);
}

- (void)updateQualitySettings:(RptrVideoQualitySettings *)settings {
    if (!settings) {
        RLogError(@"Cannot update quality settings: nil settings provided");
        return;
    }
    
    // Stop current streaming if active
    BOOL wasStreaming = self.isStreaming;
    if (wasStreaming) {
        [self stopStreaming];
    }
    
    // Update quality settings
    self.qualitySettings = settings;
    
    RLogInfo(@"Updated video quality settings to %@ mode", settings.modeName);
    RLogDebug(@"New settings - Video: %ldx%ld @ %ld fps, %ld kbps", 
              (long)settings.videoWidth, (long)settings.videoHeight,
              (long)settings.videoFrameRate, (long)(settings.videoBitrate / 1000));
    RLogDebug(@"New settings - Audio: %ld kbps, %ld Hz, %ld channels",
              (long)(settings.audioBitrate / 1000), (long)settings.audioSampleRate,
              (long)settings.audioChannels);
    RLogDebug(@"New settings - Segments: %.1f seconds, max %ld segments",
              settings.segmentDuration, (long)settings.maxSegments);
    
    // Clear any existing segments
    dispatch_barrier_async(self.segmentsQueue, ^{
        [self.segments removeAllObjects];
    });
    
    dispatch_barrier_async(self.segmentDataQueue, ^{
        [self.segmentData removeAllObjects];
    });
    
    // Notify delegate if streaming was interrupted
    if (wasStreaming && self.delegate && [self.delegate respondsToSelector:@selector(hlsServer:didEncounterError:)]) {
        NSError *error = [NSError errorWithDomain:kRptrErrorDomainHLSServer
                                            code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"Streaming stopped for quality change"}];
        [self.delegate hlsServer:self didEncounterError:error];
    }
}

#pragma mark - Test 4: Manual Flush Support

- (void)scheduleManualFlushTimer {
    // TEST 4: Schedule timer to call flushSegment every 1 second
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.flushTimer) {
            [self.flushTimer invalidate];
            self.flushTimer = nil;
        }
        
        self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                           target:self
                                                         selector:@selector(manualFlushSegment)
                                                         userInfo:nil
                                                          repeats:YES];
        RLog(RptrLogAreaProtocol, @"[TEST4-TIMER] Scheduled manual flush timer (1 second interval)");
    });
}

- (void)manualFlushSegment {
    // TEST 4: Manual segment flush for passthrough mode
    dispatch_async(self.writerQueue, ^{
        if (!self.assetWriter || self.assetWriter.status != AVAssetWriterStatusWriting) {
            RLog(RptrLogAreaProtocol, @"[TEST4-FLUSH] Writer not ready for flush (status: %ld)", 
                 self.assetWriter ? (long)self.assetWriter.status : -1);
            return;
        }
        
        @try {
            // Call flushSegment to force segment output in passthrough mode
            [self.assetWriter flushSegment];
            RLog(RptrLogAreaProtocol, @"[TEST4-FLUSH] flushSegment called successfully");
            
            // Update segment timing
            self.currentSegmentStartTime = [NSDate date];
            
            // Log current state
            RLog(RptrLogAreaProtocol, @"[TEST4-FLUSH] Segment index: %ld", (long)self.currentSegmentIndex);
            RLog(RptrLogAreaProtocol, @"[TEST4-FLUSH] Writer status: %ld", (long)self.assetWriter.status);
            
        } @catch (NSException *exception) {
            RLog(RptrLogAreaError, @"[TEST4-FLUSH] Exception calling flushSegment: %@", exception);
            RLog(RptrLogAreaError, @"[TEST4-FLUSH] Exception reason: %@", exception.reason);
            RLog(RptrLogAreaError, @"[TEST4-FLUSH] This likely means flushSegment is not available in encoding mode");
        }
    });
}

- (void)invalidateFlushTimer {
    // Clean up the flush timer
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.flushTimer) {
            [self.flushTimer invalidate];
            self.flushTimer = nil;
            RLog(RptrLogAreaProtocol, @"[TEST4-TIMER] Manual flush timer invalidated");
        }
    });
}

@end