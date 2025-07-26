//
//  HLSAssetWriterServer.m
//  Rptr
//
//  Production-ready HLS Server using AVAssetWriter with proper segment handling
//

#import "HLSAssetWriterServer.h"
#import "HLSLogger.h"
#import "RptrLogger.h"
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define SEGMENT_DURATION 1.0  // 1 second segments for stability
#define TARGET_DURATION 2     // Max segment duration for playlist
#define MAX_SEGMENTS 10       // Keep 10 segments for better buffering
#define PLAYLIST_WINDOW 5     // 5 segments in live playlist
#define BUFFER_SIZE 8192

@interface HLSClient : NSObject
@property (nonatomic, strong) NSString *address;
@property (nonatomic, assign) NSTimeInterval lastActivity;
@end

@implementation HLSClient
@end

@interface HLSSegmentInfo : NSObject
@property (nonatomic, strong) NSString *filename;
@property (nonatomic, strong) NSString *path;
@property (nonatomic, assign) CMTime duration;
@property (nonatomic, assign) NSInteger sequenceNumber;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, assign) NSUInteger fileSize;
@end

@implementation HLSSegmentInfo
@end

@interface HLSAssetWriterServer () <NSStreamDelegate>

// HTTP Server
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) dispatch_queue_t propertyQueue;
@property (nonatomic, assign) int serverSocket;
@property (atomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, HLSClient *> *clients;
@property (nonatomic, strong) dispatch_queue_t clientsQueue;  // Concurrent queue with barriers instead of lock

// Asset Writer
@property (nonatomic, strong) dispatch_queue_t writerQueue;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, assign) BOOL isWriting;
@property (nonatomic, assign) BOOL sessionStarted;
@property (nonatomic, assign) BOOL isFinishingWriter;

// Segment Management
@property (nonatomic, strong) NSString *baseDirectory;
@property (nonatomic, strong) NSString *segmentDirectory;
@property (nonatomic, strong) NSMutableArray<HLSSegmentInfo *> *segments;
@property (nonatomic, strong) NSString *initializationSegmentPath;
@property (nonatomic, assign) NSInteger currentSegmentIndex;
@property (nonatomic, assign) NSInteger mediaSequenceNumber;

// Delegate-based segment data storage
@property (nonatomic, strong) NSData *initializationSegmentData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *segmentData;
@property (nonatomic, strong) NSLock *segmentDataLock;
@property (nonatomic, strong) dispatch_queue_t segmentDataQueue;  // Concurrent queue with barriers
@property (nonatomic, strong) dispatch_queue_t segmentsQueue;      // Concurrent queue with barriers

// Timing
@property (nonatomic, assign) CMTime nextSegmentBoundary;
@property (nonatomic, assign) CMTime sessionStartTime;
@property (nonatomic, strong) NSTimer *segmentTimer;
@property (nonatomic, assign) BOOL waitingForKeyFrame;
@property (nonatomic, strong) NSDate *currentSegmentStartTime;
@property (nonatomic, assign) BOOL forceSegmentRotation;


// Performance
@property (nonatomic, assign) NSInteger framesProcessed;
@property (nonatomic, assign) NSInteger framesDropped;

// Video orientation

// Client tracking
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *activeClients;
@property (nonatomic, strong) NSTimer *clientCleanupTimer;

// Track previous path for proper error responses
@property (nonatomic, strong) NSString *previousRandomPath;

@end

@implementation HLSAssetWriterServer

- (instancetype)initWithPort:(NSUInteger)port {
    self = [super init];
    if (self) {
        // Set logging level to DEBUG by default
        [HLSLogger setLogLevel:HLSLogLevelDebug];
        
        _port = port ?: 8080;
        _serverQueue = dispatch_queue_create("com.rptr.hls.server", DISPATCH_QUEUE_SERIAL);
        _propertyQueue = dispatch_queue_create("com.rptr.hls.properties", DISPATCH_QUEUE_CONCURRENT);
        _writerQueue = dispatch_queue_create("com.rptr.hls.writer", DISPATCH_QUEUE_SERIAL);
        _clients = [NSMutableDictionary dictionary];
        _clientsQueue = dispatch_queue_create("com.rptr.hls.clients", DISPATCH_QUEUE_CONCURRENT);
        _segments = [NSMutableArray array];
        _segmentData = [NSMutableDictionary dictionary];
        _segmentDataLock = [[NSLock alloc] init];
        _segmentDataQueue = dispatch_queue_create("com.rptr.hls.segmentdata", DISPATCH_QUEUE_CONCURRENT);
        _segmentsQueue = dispatch_queue_create("com.rptr.hls.segments", DISPATCH_QUEUE_CONCURRENT);
        
        // Generate random 10-character string
        _randomPath = [self generateRandomString:10];
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Generated randomized URL path: %@", _randomPath);
        _streamTitle = @"Share Stream";  // Default title
        _currentSegmentIndex = 0;
        _mediaSequenceNumber = 0;
        _waitingForKeyFrame = YES;
        _sessionStartTime = kCMTimeInvalid;
        _nextSegmentBoundary = kCMTimeZero;
        _sessionStarted = NO;
        _isFinishingWriter = NO;
        _activeClients = [NSMutableDictionary dictionary];
        
        // Setup directories
        [self setupDirectories];
        
        // Register for memory warnings
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)setupDirectories {
    NSString *tempDir = NSTemporaryDirectory();
    self.baseDirectory = [tempDir stringByAppendingPathComponent:@"HLSStream"];
    self.segmentDirectory = [self.baseDirectory stringByAppendingPathComponent:@"segments"];
    
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
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to create directories: %@", error);
    }
}

#pragma mark - Server Control

- (BOOL)startServer:(NSError * __autoreleasing *)error {
    __block BOOL success = YES;
    __block NSError *blockError = nil;
    
    // Ignore SIGPIPE globally
    signal(SIGPIPE, SIG_IGN);
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"SIGPIPE handler installed");
    
    dispatch_sync(self.serverQueue, ^{
        if (self.running) {
            return;
        }
        
        // Create socket
        self.serverSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (self.serverSocket < 0) {
            blockError = [NSError errorWithDomain:@"HLSServer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
            success = NO;
            return;
        }
        
        // Allow socket reuse
        int yes = 1;
        setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        
        // Bind to port
        struct sockaddr_in serverAddr;
        memset(&serverAddr, 0, sizeof(serverAddr));
        serverAddr.sin_family = AF_INET;
        serverAddr.sin_port = htons((uint16_t)self.port);
        serverAddr.sin_addr.s_addr = INADDR_ANY;
        
        if (bind(self.serverSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
            close(self.serverSocket);
            blockError = [NSError errorWithDomain:@"HLSServer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind socket"}];
            success = NO;
            return;
        }
        
        // Start listening
        if (listen(self.serverSocket, 10) < 0) {
            close(self.serverSocket);
            blockError = [NSError errorWithDomain:@"HLSServer" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to listen"}];
            success = NO;
            return;
        }
        
        self.running = YES;
        
        // Start accept loop
        dispatch_async(self.serverQueue, ^{
            [self acceptLoop];
        });
        
        // Setup asset writer
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"About to call setupAssetWriter...");
        [self setupAssetWriter];
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"setupAssetWriter called");
        
        // Create initial empty playlist
        [self createInitialPlaylist];
        
        // Start client cleanup timer on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.clientCleanupTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 
                                                                        target:self 
                                                                      selector:@selector(cleanupInactiveClients) 
                                                                      userInfo:nil 
                                                                       repeats:YES];
        });
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Server started on port %lu", (unsigned long)self.port);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Randomized view URL: http://localhost:%lu/view/%@", (unsigned long)self.port, self.randomPath);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Randomized stream URL: http://localhost:%lu/stream/%@/playlist.m3u8", (unsigned long)self.port, self.randomPath);
        
        if ([self.delegate respondsToSelector:@selector(hlsServerDidStart:)]) {
            NSString *url = [NSString stringWithFormat:@"http://localhost:%lu", (unsigned long)self.port];
            [self.delegate hlsServerDidStart:url];
        }
    });
    
    if (!success && error) {
        *error = blockError;
    }
    
    return success;
}

- (void)stopStreaming {
    dispatch_async(self.writerQueue, ^{
        if (self.isWriting) {
            RLog(RptrLogAreaHLS, @"Stopping streaming (keeping server running)");
            [self stopAssetWriter];
        }
    });
}

- (void)prepareForStreaming {
    dispatch_async(self.writerQueue, ^{
        if (!self.isWriting && !self.assetWriter) {
            RLog(RptrLogAreaHLS, @"Preparing asset writer for streaming");
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
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Server stopped");
        
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

- (void)setupAssetWriter {
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"setupAssetWriter: Starting...");
    dispatch_async(self.writerQueue, ^{
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"setupAssetWriter: Inside async block");
        NSError *error;
        
        // Create a new segment file
        NSString *segmentName;
        if (@available(iOS 14.0, *)) {
            // For delegate-based writing, use .m4s extension
            segmentName = [NSString stringWithFormat:@"segment_%03ld.m4s", (long)self.currentSegmentIndex];
        } else {
            // For file-based writing, use .mp4 extension
            segmentName = [NSString stringWithFormat:@"segment_%03ld.mp4", (long)self.currentSegmentIndex];
        }
        NSString *segmentPath = [self.segmentDirectory stringByAppendingPathComponent:segmentName];
        NSURL *segmentURL = [NSURL fileURLWithPath:segmentPath];
        
        // Remove existing file
        [[NSFileManager defaultManager] removeItemAtURL:segmentURL error:nil];
        
        // Create asset writer with delegate-based fMP4 for HLS
        [HLSLogger logInfo:@"Creating delegate-based asset writer for HLS fMP4"];
        
        // Use contentType for delegate-based delivery (iOS 14+)
        if (@available(iOS 14.0, *)) {
            self.assetWriter = [[AVAssetWriter alloc] initWithContentType:UTTypeMPEG4Movie];
            if (self.assetWriter) {
                // Set Apple HLS profile for proper fMP4 output
                self.assetWriter.outputFileTypeProfile = AVFileTypeProfileMPEG4AppleHLS;
                self.assetWriter.delegate = self;
                // Set required initialSegmentStartTime for delegate-based output
                self.assetWriter.initialSegmentStartTime = kCMTimeZero;
                [HLSLogger logInfo:@"Using delegate-based fMP4 approach with Apple HLS profile"];
                [HLSLogger logDebug:@"Delegate set: %@", self.assetWriter.delegate ? @"YES" : @"NO"];
            } else {
                [HLSLogger logError:@"Failed to create AVAssetWriter with contentType"];
            }
        } else {
            // Fallback for older iOS versions
            self.assetWriter = [[AVAssetWriter alloc] initWithURL:segmentURL fileType:AVFileTypeMPEG4 error:&error];
        }
        if (error) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Failed to create asset writer: %@", error);
            return;
        }
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Asset writer created successfully, status: %ld", (long)self.assetWriter.status);
        
        // Configure for HLS with fragmented MP4
        self.assetWriter.shouldOptimizeForNetworkUse = YES;
        
        // Set metadata for better streaming
        NSArray *metadata = @[
            [self metadataItemWithKey:AVMetadataCommonKeyTitle value:@"HLS Live Stream"],
            [self metadataItemWithKey:AVMetadataCommonKeyCreator value:@"Rptr"]
        ];
        self.assetWriter.metadata = metadata;
        
        // Configure for delegate-based fMP4 HLS output
        if (@available(iOS 14.0, *)) {
            // Set segment duration for HLS with proper precision
            self.assetWriter.preferredOutputSegmentInterval = CMTimeMakeWithSeconds(SEGMENT_DURATION, 1000);
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Set preferredOutputSegmentInterval to %f seconds", SEGMENT_DURATION);
        } else {
            // Fallback: use movieFragmentInterval for older iOS
            self.assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(0.2, 1000);
        }
        
        // Video settings - optimized for mobile streaming with VBR
        // Note: Width and height should match the expected output orientation
        // For landscape video, width > height (1280x720)
        // For portrait video, width < height (720x1280)
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(1280),
            AVVideoHeightKey: @(720),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(1000000),               // 1 Mbps - balanced quality/bandwidth
                AVVideoMaxKeyFrameIntervalKey: @(24),               // 1 second at 24fps
                AVVideoMaxKeyFrameIntervalDurationKey: @(1.0),      // 1-second keyframe interval
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,  // High profile for better quality
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,       // CABAC for better compression
                AVVideoAllowFrameReorderingKey: @(NO),             // Disable B-frames for compatibility
                AVVideoExpectedSourceFrameRateKey: @(24),          // Expected frame rate
                AVVideoAverageNonDroppableFrameRateKey: @(24),     // Maintain consistent frame rate
                // Quality hint for encoder (0.0-1.0, higher is better)
                AVVideoQualityKey: @(0.85)
            }
        };
        
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        if (!self.videoInput) {
            [HLSLogger logError:@"Failed to create video input!"];
            return;
        }
        
        // Use identity transform since video is already in landscape orientation
        // The AVCaptureConnection is configured to output landscape frames
        self.videoInput.transform = CGAffineTransformIdentity;
        RLog(RptrLogAreaHLS | RptrLogAreaVideo, @"Using identity transform for segment %ld (frames pre-oriented to landscape)", 
             (long)self.currentSegmentIndex);
        self.videoInput.expectsMediaDataInRealTime = YES;
        [HLSLogger logDebug:@"Created video input: %@", self.videoInput];
        
        if ([self.assetWriter canAddInput:self.videoInput]) {
            [self.assetWriter addInput:self.videoInput];
            [HLSLogger logDebug:@"Added video input to asset writer"];
        } else {
            [HLSLogger logError:@"Cannot add video input to asset writer!"];
            return;
        }
        
        // Audio settings - high quality AAC
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: @(2),
            AVSampleRateKey: @(48000),    // 48kHz for better quality
            AVEncoderBitRateKey: @(96000) // 96 kbps - reasonable audio quality
        };
        
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioInput.expectsMediaDataInRealTime = YES;
        [HLSLogger logDebug:@"Created audio input: %@", self.audioInput];
        
        // Add audio input to asset writer
        if ([self.assetWriter canAddInput:self.audioInput]) {
            [self.assetWriter addInput:self.audioInput];
            [HLSLogger logDebug:@"Added audio input to asset writer"];
        } else {
            [HLSLogger logError:@"Cannot add audio input to asset writer!"];
            return;  // Fail if we can't add audio input
        }
        
        // Start writing
        if ([self.assetWriter startWriting]) {
            self.waitingForKeyFrame = YES;
            self.sessionStarted = NO;  // Reset session flag for new writer
            RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Asset writer started for segment %ld", (long)self.currentSegmentIndex);
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Writer status after startWriting: %ld", (long)self.assetWriter.status);
            // Don't set isWriting yet - wait for first frame to start session
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Failed to start writing: %@", self.assetWriter.error);
            RLog(RptrLogAreaHLS | RptrLogAreaDebug | RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
            
            // Notify delegate of error
            if ([self.delegate respondsToSelector:@selector(hlsServer:didEncounterError:)]) {
                NSError *error = self.assetWriter.error ?: [NSError errorWithDomain:@"HLSServer" 
                                                                               code:100 
                                                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to start AVAssetWriter"}];
                [self.delegate hlsServer:self didEncounterError:error];
            }
        }
    });
}

- (void)stopAssetWriter {
    dispatch_async(self.writerQueue, ^{
        if (!self.isWriting || self.isFinishingWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"stopAssetWriter: Already stopped or finishing (isWriting=%d, isFinishingWriter=%d)", 
                 self.isWriting, self.isFinishingWriter);
            return;
        }
        
        self.isWriting = NO;
        self.sessionStarted = NO;
        
        // Only mark as finished if writer is in correct state
        if (self.assetWriter && self.assetWriter.status == AVAssetWriterStatusWriting) {
            self.isFinishingWriter = YES;
            
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
                    RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Finished writing segment");
                    [strongSelf finalizeCurrentSegment];
                    strongSelf.isFinishingWriter = NO;
                }
            }];
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer not in correct state to stop. Status: %ld", 
                  self.assetWriter ? (long)self.assetWriter.status : -1);
        }
    });
}

#pragma mark - Sample Buffer Processing

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    @autoreleasepool {
        if (!sampleBuffer) {
            return;
        }
        
        // Quick state check
        if (!self.running) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer, @"Server not running, ignoring sample buffer");
            return;
        }
        
        // Validate sample buffer before processing
        if (!CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"WARNING: Invalid sample buffer received");
            return;
        }
        
        // Don't retain the buffer - process it immediately
        // The capture system needs these buffers back quickly for its pool
        
        // Quick check if we should process this frame
        if (!self.assetWriter || !self.videoInput || self.isFinishingWriter) {
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
    
    // Retain the buffer only for the duration of the append operation
    CFRetain(sampleBuffer);
    
    dispatch_async(self.writerQueue, ^{
        @try {
        // Validate sample buffer is still valid
        if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"ERROR: Sample buffer became invalid or nil");
            return;
        }
        
        // Check if we have a writer
        if (!self.assetWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: No asset writer available!");
            return;
        }
        
        // Check if video input exists
        if (!self.videoInput) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: No video input available!");
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
                RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Session already started by another thread");
                return;
            } else {
                // Log buffer dimensions for first frame
                if (dimensions.width > 0 && dimensions.height > 0) {
                    RLog(RptrLogAreaHLS | RptrLogAreaVideo, @"First frame buffer dimensions: %d x %d", dimensions.width, dimensions.height);
                    // Video should already be in landscape orientation from AVCaptureConnection
                }
                
                // Check writer status
                if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
                    RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: Writer not started yet! Call startWriting first.");
                    return;
                } else if (self.assetWriter.status == AVAssetWriterStatusWriting) {
                    // Double-check session hasn't been started
                    if (self.sessionStarted) {
                        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Session started by another thread during checks");
                        return;
                    }
                    
                    // Writer is ready, start the session
                    RLog(RptrLogAreaHLS | RptrLogAreaTiming, @"First frame - starting session");
                    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Asset writer status: %ld", (long)self.assetWriter.status);
                    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Video input: %@", self.videoInput);
                    
                    // Initialize timing
                    self.sessionStartTime = presentationTime;
                    self.nextSegmentBoundary = presentationTime;
                    
                    // Ensure valid time
                    if (CMTIME_IS_INVALID(presentationTime)) {
                        RLog(RptrLogAreaHLS | RptrLogAreaTiming | RptrLogAreaError, @"ERROR: Invalid presentation time!");
                        return;
                    }
                    
                    // Set sessionStarted BEFORE calling startSessionAtSourceTime to prevent race condition
                    self.sessionStarted = YES;
                    
                    // Start the session
                    RLog(RptrLogAreaHLS | RptrLogAreaTiming, @"Starting session at source time: %.2f", CMTimeGetSeconds(presentationTime));
                    @try {
                        [self.assetWriter startSessionAtSourceTime:presentationTime];
                        self.isWriting = YES;
                        self.currentSegmentStartTime = [NSDate date];
                        RLog(RptrLogAreaHLS | RptrLogAreaTiming, @"Session started successfully");
                        
                        // Start segment timer as backup
                        [self startSegmentTimer];
                    } @catch (NSException *exception) {
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"EXCEPTION starting session: %@", exception);
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer status was: %ld", (long)self.assetWriter.status);
                        // Reset sessionStarted since we failed to start
                        self.sessionStarted = NO;
                        return;
                    }
                } else {
                    RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: Writer in unexpected state: %ld", (long)self.assetWriter.status);
                    if (self.assetWriter.error) {
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer error: %@", self.assetWriter.error);
                    }
                    return;
                }
            }
        }
        
        // Check writer status
        if (self.assetWriter.status == AVAssetWriterStatusFailed) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer failed with error: %@", self.assetWriter.error);
            self.isWriting = NO;
            return;
        }
        
        if (self.assetWriter.status != AVAssetWriterStatusWriting) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer not ready, status: %ld", (long)self.assetWriter.status);
            return;
        }
        
        // Check if we need to start a new segment
        CMTime timeSinceSegmentStart = CMTimeSubtract(presentationTime, self.nextSegmentBoundary);
        double secondsSinceSegmentStart = CMTimeGetSeconds(timeSinceSegmentStart);
        
        if (secondsSinceSegmentStart >= SEGMENT_DURATION || self.forceSegmentRotation) {
            if (self.forceSegmentRotation) {
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Forced segment rotation requested");
            } else {
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Time for new segment: %.2f seconds since start", secondsSinceSegmentStart);
            }
            
            // Use the pre-extracted key frame information
            if (!isKeyFrame && self.framesProcessed % 30 == 0) {
                RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaDebug, @"Frame %ld is NOT a key frame", (long)self.framesProcessed);
            }
            
            if (isKeyFrame) {
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"[KEY FRAME] Detected at %.3f seconds (segment %ld age: %.3f)", 
                       CMTimeGetSeconds(presentationTime), 
                       (long)self.currentSegmentIndex, 
                       secondsSinceSegmentStart);
                self.forceSegmentRotation = NO;
                [self rotateSegment];
                return; // Skip this frame, it will be written to the new segment
            } else if (self.forceSegmentRotation && secondsSinceSegmentStart >= SEGMENT_DURATION + 0.5) {
                // Force rotation if we've waited a bit for key frame
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"[FORCE ROTATION] No key frame for %.3f seconds, forcing rotation of segment %ld", 
                       secondsSinceSegmentStart, (long)self.currentSegmentIndex);
                self.forceSegmentRotation = NO;
                [self rotateSegment];
                return;
            } else if (self.forceSegmentRotation) {
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming | RptrLogAreaDebug, @"[WAITING] Segment %ld: %.3f seconds elapsed, waiting for key frame (force flag set)", 
                       (long)self.currentSegmentIndex, secondsSinceSegmentStart);
            }
        }
        
        // Comprehensive null checks before appending
        if (!self.videoInput) {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: videoInput is nil!");
            return;
        }
        
        if (!sampleBuffer) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"ERROR: sampleBuffer is nil!");
            return;
        }
        
        // Verify sample buffer is valid
        if (!CMSampleBufferIsValid(sampleBuffer)) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"ERROR: sampleBuffer is invalid!");
            return;
        }
        
        // Check if we're in the middle of finishing the writer
        if (self.isFinishingWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaDebug, @"Skipping frame - writer is finishing");
            return;
        }
        
        // Check if input is ready
        if (self.videoInput.isReadyForMoreMediaData) {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaDebug, @"About to append sample buffer - videoInput: %@, sampleBuffer: %p", 
                  self.videoInput, sampleBuffer);
            
            @try {
                // Final validation before append
                if (!CMSampleBufferIsValid(sampleBuffer)) {
                    RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"ERROR: Sample buffer invalid before append");
                    return;
                }
                
                BOOL success = [self.videoInput appendSampleBuffer:sampleBuffer];
                if (success) {
                    self.framesProcessed++;
                    if (self.framesProcessed == 1) {
                        RLog(RptrLogAreaHLS | RptrLogAreaBuffer, @"Successfully appended first frame!");
                    } else if (self.framesProcessed % 30 == 0) {
                        RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaDebug, @"Processed %ld frames", (long)self.framesProcessed);
                    }
                } else {
                    RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"Failed to append sample buffer");
                    RLog(RptrLogAreaHLS | RptrLogAreaDebug | RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
                    RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer error: %@", self.assetWriter.error);
                    RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaDebug | RptrLogAreaError, @"Video input readyForMoreMediaData: %@", self.videoInput.readyForMoreMediaData ? @"YES" : @"NO");
                    self.framesDropped++;
                    
                    // Check if writer failed
                    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Writer failed with error: %@", self.assetWriter.error);
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Error code: %ld", (long)self.assetWriter.error.code);
                        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Error domain: %@", self.assetWriter.error.domain);
                        self.isWriting = NO;
                        
                        // Try to restart writer
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), self.writerQueue, ^{
                            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Attempting to restart writer...");
                            self.currentSegmentIndex++;
                            [self setupAssetWriter];
                        });
                    }
                }
            } @catch (NSException *exception) {
                RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"EXCEPTION appending sample buffer: %@", exception);
                RLog(RptrLogAreaHLS | RptrLogAreaError, @"Exception reason: %@", exception.reason);
                RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Stack trace: %@", exception.callStackSymbols);
                self.framesDropped++;
            }
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaBuffer, @"Video input not ready for more data");
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
        RLog(RptrLogAreaHLS | RptrLogAreaBuffer | RptrLogAreaError, @"WARNING: Invalid audio sample buffer received");
        return;
    }
    
    // Quick check if we should process this frame
    if (!self.running || !self.sessionStarted || !self.audioInput || self.isFinishingWriter) {
        return;
    }
    
    // Process on writer queue with minimal retention
    CFRetain(sampleBuffer);
    
    dispatch_async(self.writerQueue, ^{
        @try {
            // Quick validation before append
            if (!self.audioInput || self.isFinishingWriter || !self.sessionStarted) {
                return;
            }
            
            // Check if audio input is ready
            if (self.audioInput.isReadyForMoreMediaData) {
                BOOL success = [self.audioInput appendSampleBuffer:sampleBuffer];
                if (!success) {
                    RLog(RptrLogAreaHLS | RptrLogAreaAudio | RptrLogAreaDebug, @"Failed to append audio sample buffer");
                    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                        RLog(RptrLogAreaHLS | RptrLogAreaAudio | RptrLogAreaError, @"Audio append failed - writer error: %@", self.assetWriter.error);
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

- (void)rotateSegment {
    dispatch_async(self.writerQueue, ^{
        // Check if we're already finishing the writer or not writing
        if (!self.isWriting || self.isFinishingWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, 
                 @"rotateSegment: Skipping rotation (isWriting=%d, isFinishingWriter=%d)", 
                 self.isWriting, self.isFinishingWriter);
            return;
        }
        
        NSTimeInterval segmentAge = [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime];
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Rotating segment %ld after %.3f seconds", (long)self.currentSegmentIndex, segmentAge);
        
        // Check if we can safely finish the current writer
        if (!self.assetWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"ERROR: No writer to rotate");
            return;
        }
        
        if (self.assetWriter.status != AVAssetWriterStatusWriting) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"ERROR: Writer not in writing state, cannot rotate. Status: %ld", (long)self.assetWriter.status);
            return;
        }
        
        // Mark that we're finishing the writer to prevent concurrent finishes
        self.isFinishingWriter = YES;
        
        // Stop current writer
        if (self.videoInput && self.videoInput.readyForMoreMediaData) {
            [self.videoInput markAsFinished];
        }
        if (self.audioInput && self.audioInput.readyForMoreMediaData) {
            [self.audioInput markAsFinished];
        }
        
        __weak typeof(self) weakSelf = self;
        [self.assetWriter finishWritingWithCompletionHandler:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            dispatch_async(strongSelf.writerQueue, ^{
                // Finalize the completed segment
                [strongSelf finalizeCurrentSegment];
                
                // Update segment boundary
                strongSelf.nextSegmentBoundary = CMTimeAdd(strongSelf.nextSegmentBoundary, CMTimeMake(SEGMENT_DURATION, 1));
                
                // Clear the finishing flag
                strongSelf.isFinishingWriter = NO;
                
                // Start new segment only if we're still supposed to be writing
                if (strongSelf.isWriting) {
                    strongSelf.currentSegmentIndex++;
                    strongSelf.currentSegmentStartTime = [NSDate date];
                    [strongSelf setupAssetWriter];
                } else {
                    RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Not starting new segment - writing has been stopped");
                }
            });
        }];
    });
}

- (void)finalizeCurrentSegment {
    NSTimeInterval segmentAge = [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime];
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Finalizing segment %ld after %.3f seconds (expected: %.1f)", 
           (long)self.currentSegmentIndex, segmentAge, SEGMENT_DURATION);
    
    if (!self.assetWriter) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"ERROR: No asset writer to finalize");
        return;
    }
    
    if (self.assetWriter.status != AVAssetWriterStatusCompleted) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"ERROR: Writer not completed, status: %ld", (long)self.assetWriter.status);
        return;
    }
    
    // Get segment info
    NSURL *segmentURL = self.assetWriter.outputURL;
    NSString *segmentPath = segmentURL.path;
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile, @"Segment path: %@", segmentPath);
    
    // Get file size
    NSError *fileError;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:segmentPath error:&fileError];
    NSUInteger fileSize = [attrs fileSize];
    
    if (fileError) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaError, @"ERROR: Cannot get segment file attributes: %@", fileError);
    }
    
    // Verify file exists
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:segmentPath];
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaDebug, @"Segment file exists: %@, size: %lu bytes", fileExists ? @"YES" : @"NO", (unsigned long)fileSize);
    
    if (fileSize > 0) {
        // Calculate actual duration based on writer session
        CMTime duration = CMTimeMake(SEGMENT_DURATION * 1000, 1000); // More precise timing
        
        // Create segment info
        HLSSegmentInfo *segmentInfo = [[HLSSegmentInfo alloc] init];
        segmentInfo.filename = segmentURL.lastPathComponent;
        segmentInfo.path = segmentPath;
        segmentInfo.duration = duration;
        segmentInfo.sequenceNumber = self.mediaSequenceNumber++;
        segmentInfo.createdAt = [NSDate date];
        segmentInfo.fileSize = fileSize;
        
        // Add to segments array
        [self.segments addObject:segmentInfo];
        
        // Debug: Log current segments
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Current segments in array:");
        for (HLSSegmentInfo *seg in self.segments) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"  - %@ (path: %@)", seg.filename, seg.path);
        }
        
        // Remove old segments
        [self cleanupOldSegments];
        
        // Update playlist
        [self updatePlaylist];
        
        RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Finalized segment %@ (#%ld, %.2fs, %lu bytes) - Total segments: %lu", 
              segmentInfo.filename, 
              (long)segmentInfo.sequenceNumber,
              CMTimeGetSeconds(segmentInfo.duration),
              (unsigned long)fileSize,
              (unsigned long)self.segments.count);
        
        // Verify the file is actually accessible
        if ([[NSFileManager defaultManager] fileExistsAtPath:segmentPath]) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaDebug, @"Verified segment file exists at: %@", segmentPath);
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaError, @"ERROR: Segment file missing at: %@", segmentPath);
        }
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"Failed to finalize segment: empty file");
    }
    
    // Clear the writer reference
    self.assetWriter = nil;
}

#pragma mark - Segment Timer

- (void)startSegmentTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopSegmentTimer];
        // Fire timer slightly before segment duration to ensure timely rotation
        self.segmentTimer = [NSTimer scheduledTimerWithTimeInterval:SEGMENT_DURATION - 0.05
                                                              target:self
                                                            selector:@selector(segmentTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Started segment rotation timer (interval: %.1f)", SEGMENT_DURATION - 0.1);
    });
}

- (void)stopSegmentTimer {
    if (self.segmentTimer) {
        [self.segmentTimer invalidate];
        self.segmentTimer = nil;
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"Stopped segment rotation timer");
    }
}

- (void)segmentTimerFired:(NSTimer *)timer {
    dispatch_async(self.writerQueue, ^{
        if (!self.isWriting || !self.sessionStarted) {
            return;
        }
        
        // Check writer state
        if (!self.assetWriter || self.assetWriter.status != AVAssetWriterStatusWriting) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming | RptrLogAreaError, @"[TIMER] Writer not ready for rotation, status: %ld", 
                  self.assetWriter ? (long)self.assetWriter.status : -1);
            return;
        }
        
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.currentSegmentStartTime];
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming | RptrLogAreaDebug, @"[TIMER] Segment timer fired for segment %ld, elapsed: %.3f seconds (target: %.1f)", 
               (long)self.currentSegmentIndex, elapsed, SEGMENT_DURATION);
        
        if (elapsed >= SEGMENT_DURATION - 0.1) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaTiming, @"[TIMER] Setting force rotation flag for segment %ld (elapsed: %.3f)", 
                   (long)self.currentSegmentIndex, elapsed);
            self.forceSegmentRotation = YES;
        }
    });
}

#pragma mark - Playlist Management

- (void)createInitialPlaylist {
    RLog(RptrLogAreaHLS | RptrLogAreaFile, @"Creating initial playlist...");
    
    NSString *playlist = [NSString stringWithFormat:@"#EXTM3U\n"
                        @"#EXT-X-VERSION:7\n"  // Version 7 for fMP4
                        @"#EXT-X-TARGETDURATION:%d\n"
                        @"#EXT-X-MEDIA-SEQUENCE:0\n"
                        @"#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6.0\n", TARGET_DURATION];
    
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    NSError *error;
    [playlist writeToFile:playlistPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (error) {
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to create initial playlist: %@", error);
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaFile, @"Initial playlist created at: %@", playlistPath);
    }
}

- (void)updatePlaylist {
    dispatch_async(self.writerQueue, ^{
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Updating playlist...");
        dispatch_sync(self.segmentsQueue, ^{
            NSUInteger segmentCount = self.segments.count;
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Total segments available: %lu", (unsigned long)segmentCount);
        
        NSMutableString *playlist = [NSMutableString string];
        
        // Header with low-latency HLS tags
        [playlist appendString:@"#EXTM3U\n"];
        [playlist appendString:@"#EXT-X-VERSION:7\n"]; // Version 7 for fMP4
        [playlist appendFormat:@"#EXT-X-TARGETDURATION:%d\n", TARGET_DURATION];
        [playlist appendString:@"#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6.0\n"]; // Allow skipping old segments
        [playlist appendString:@"#EXT-X-PART-INF:PART-TARGET=0.5\n"]; // Support for partial segments
        
        // Important: Do NOT include EXT-X-PLAYLIST-TYPE for live streams
        // Including it (even as EVENT or VOD) will make players treat it as non-live
        
        // Calculate starting sequence number for sliding window
        NSInteger startIndex = MAX(0, (NSInteger)segmentCount - PLAYLIST_WINDOW);
        NSInteger startSequence = (startIndex > 0 && segmentCount > startIndex) ? self.segments[startIndex].sequenceNumber : 0;
        
        [playlist appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%ld\n", (long)startSequence];
        
        // Add initialization segment for fMP4
        if (self.initializationSegmentData) {
            [playlist appendFormat:@"#EXT-X-MAP:URI=\"/stream/%@/init.mp4\"\n", self.randomPath];
        }
        
        // Debug: log current segment index and media sequence
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Playlist generation - currentSegmentIndex: %ld, mediaSequenceNumber: %ld", 
             (long)self.currentSegmentIndex, (long)self.mediaSequenceNumber);
        
        // Add segments (sliding window)
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Adding segments from index %ld to %lu", (long)startIndex, (unsigned long)segmentCount);
        for (NSInteger i = startIndex; i < segmentCount; i++) {
            HLSSegmentInfo *segment = self.segments[i];
            CGFloat duration = CMTimeGetSeconds(segment.duration);
            [playlist appendFormat:@"#EXTINF:%.3f,\n", duration];
            [playlist appendFormat:@"/stream/%@/segments/%@\n", self.randomPath, segment.filename];
            RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Added segment: %@ (%.2fs) -> URL: segments/%@", segment.filename, duration, segment.filename);
        }
        
        // For live streams, don't add EXT-X-ENDLIST
        
        // Write playlist to file
        NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Writing playlist to: %@", playlistPath);
        
        NSError *error;
        [playlist writeToFile:playlistPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        
        if (error) {
            RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to write playlist: %@", error);
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaFile, @"Updated playlist with %ld segments", (long)(segmentCount - startIndex));
            RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Playlist content:\n%@", playlist);
        }
        });
    });
}

- (void)cleanupOldSegments {
    dispatch_barrier_async(self.segmentsQueue, ^{
        NSUInteger initialCount = self.segments.count;
        while (self.segments.count > MAX_SEGMENTS) {
            HLSSegmentInfo *oldSegment = self.segments.firstObject;
            NSTimeInterval segmentAge = [[NSDate date] timeIntervalSinceDate:oldSegment.createdAt];
            
            // Delete the file
            [[NSFileManager defaultManager] removeItemAtPath:oldSegment.path error:nil];
            
            // Remove from array
            [self.segments removeObjectAtIndex:0];
            
            RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Removed old segment: %@ (#%ld, age: %.1fs) - Segments: %lu -> %lu", 
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
                RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to remove segment %@: %@", segment.filename, error.localizedDescription);
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
        RLog(RptrLogAreaHLS | RptrLogAreaFile, @"Cleaned up %lu files from segments directory", (unsigned long)files.count);
    }
}

#pragma mark - HTTP Server

- (void)acceptLoop {
    while (self.running) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        
        int clientSocket = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSocket < 0) {
            if (self.running) {
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaError, @"Accept failed");
            }
            continue;
        }
        
        // Copy client address for async use
        struct sockaddr_in *clientAddrCopy = malloc(sizeof(struct sockaddr_in));
        if (!clientAddrCopy) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"ERROR: Failed to allocate memory for client address");
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
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"ERROR: Exception handling client: %@", exception);
                RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Stack trace: %@", exception.callStackSymbols);
            } @finally {
                free(clientAddrCopy);
            }
        });
    }
}

- (void)handleClient:(int)clientSocket address:(const struct sockaddr_in *)clientAddr {
    NSParameterAssert(clientSocket >= 0);
    NSParameterAssert(clientAddr != NULL);
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"1. handleClient started for socket: %d", clientSocket);
    
    // Use inet_ntop for thread safety
    char clientIP[INET_ADDRSTRLEN];
    NSString *clientAddress = @"unknown";
    
    if (clientAddr && inet_ntop(AF_INET, &(clientAddr->sin_addr), clientIP, INET_ADDRSTRLEN) != NULL) {
        clientAddress = [NSString stringWithUTF8String:clientIP];
        NSAssert(clientAddress != nil, @"Client address conversion should not fail");
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaError, @"WARNING: Failed to get client IP address: %s", strerror(errno));
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
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork, @"Client connected: %@ (active clients: %lu)", clientAddress, (unsigned long)self.activeClients.count);
    
    // Read request
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"2. About to read request from socket %d", clientSocket);
    char buffer[BUFFER_SIZE];
    ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"3. Read %zd bytes from socket %d", bytesRead, clientSocket);
    
    if (bytesRead < 0) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaError, @"ERROR: Failed to read from client socket: %s", strerror(errno));
        // Still need to remove client and close socket
    } else if (bytesRead > 0) {
        buffer[bytesRead] = '\0';
        
        // Validate UTF8 before creating string
        if (![[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding]) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"ERROR: Invalid UTF8 in request");
            [self sendErrorResponse:clientSocket code:400 message:@"Bad Request"];
            close(clientSocket);
            return;
        }
        
        NSString *request = [NSString stringWithUTF8String:buffer];
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"4. Request string created, length: %lu", (unsigned long)[request length]);
        
        // Parse request
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"5. Parsing request...");
        NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"6. Request has %lu lines", (unsigned long)lines.count);
        if (lines.count > 0) {
            NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"7. First line has %lu parts", (unsigned long)parts.count);
            if (parts.count >= 2) {
                NSString *method = parts[0];
                NSString *path = parts[1];
                
                // Debug: Log path details
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Raw path: '%@' (length: %lu)", path, (unsigned long)path.length);
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Path bytes: %@", [path dataUsingEncoding:NSUTF8StringEncoding]);
                
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Request: %@ %@ (socket %d)", method, path, clientSocket);
                
                if ([method isEqualToString:@"GET"]) {
                    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"9. Calling handleGETRequest for path: %@", path);
                    [self handleGETRequest:path socket:clientSocket];
                    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"10. handleGETRequest completed for path: %@", path);
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"GET %@ (socket: %d)", path, clientSocket);
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"handleGETRequest entry - path class: %@", [path class]);
    
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Request path: '%@', Current randomPath: '%@'", path, self.randomPath);
    
    if ([path isEqualToString:@"/"]) {
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
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Redirecting /view to %@", redirectURL);
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/view/%@", self.randomPath]]) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Test page requested on socket %d", clientSocket);
        [self sendTestPageResponse:clientSocket];
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Test page response completed for socket %d", clientSocket);
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/playlist.m3u8", self.randomPath]]) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Secure playlist requested on socket %d", clientSocket);
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Expected path: /stream/%@/playlist.m3u8", self.randomPath);
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Received path: %@", path);
        [self sendPlaylistResponse:clientSocket];
    } else if ([path isEqualToString:[NSString stringWithFormat:@"/stream/%@/init.mp4", self.randomPath]]) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Secure init segment requested on socket %d", clientSocket);
        [self sendInitializationSegmentResponse:clientSocket];
    } else if ([path hasPrefix:[NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath]]) {
        NSString *segmentPrefix = [NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath];
        NSString *segmentName = [path substringFromIndex:segmentPrefix.length];
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Secure segment requested: %@ on socket %d", segmentName, clientSocket);
        
        // Debug logging for segment state
        [self.segmentDataLock lock];
        NSUInteger segmentDataCount = self.segmentData.count;
        BOOL hasSegment = [self.segmentData objectForKey:segmentName] != nil;
        [self.segmentDataLock unlock];
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Segment lookup: %@ - exists: %@, total segments in memory: %lu", 
             segmentName, hasSegment ? @"YES" : @"NO", (unsigned long)segmentDataCount);
        
        // Check if we're using delegate-based writing (iOS 14+)
        if (@available(iOS 14.0, *)) {
            if (self.assetWriter && self.assetWriter.delegate) {
                // Use delegate-based segment serving for in-memory segments
                [self sendDelegateSegmentResponse:clientSocket segmentName:segmentName];
            } else {
                // Fallback to file-based serving
                [self sendSegmentResponse:clientSocket segmentName:segmentName];
            }
        } else {
            // iOS < 14, always use file-based
            [self sendSegmentResponse:clientSocket segmentName:segmentName];
        }
    } else if ([path hasPrefix:@"/css/"] || [path hasPrefix:@"/js/"] || [path hasPrefix:@"/images/"]) {
        // Serve bundled resources
        [self sendBundledResourceResponse:clientSocket path:path];
    } else if ([path isEqualToString:@"/test-external"]) {
        [self sendExternalTestPageResponse:clientSocket];
    } else if ([path isEqualToString:@"/location"]) {
        [self sendLocationResponse:clientSocket];
    } else if ([path isEqualToString:@"/status"]) {
        [self sendStatusResponse:clientSocket];
    } else if (self.previousRandomPath && 
               ([path containsString:[NSString stringWithFormat:@"/stream/%@/", self.previousRandomPath]] ||
                [path containsString:[NSString stringWithFormat:@"/view/%@", self.previousRandomPath]])) {
        // Request is using the old random path after regeneration
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Request using old path: %@ (current: %@)", self.previousRandomPath, self.randomPath);
        // Send 410 Gone to indicate the resource has been permanently removed
        // This should trigger clients to reload
        [self sendErrorResponse:clientSocket code:410 message:@"Gone - URL has been regenerated"];
        
        // Close the socket immediately for old URLs to prevent clients from keeping connections alive
        shutdown(clientSocket, SHUT_RDWR);
        close(clientSocket);
        return;
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Unmatched request path: %@", path);
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Current randomPath: %@", self.randomPath);
        
        // Extra debugging for segment paths
        if ([path containsString:@"/segments/"]) {
            NSString *expectedPrefix = [NSString stringWithFormat:@"/stream/%@/segments/", self.randomPath];
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Expected segment prefix: %@", expectedPrefix);
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Path has prefix: %@", [path hasPrefix:expectedPrefix] ? @"YES" : @"NO");
        }
        
        [self sendErrorResponse:clientSocket code:404 message:@"Not Found"];
    }
}

- (void)sendPlaylistResponse:(int)clientSocket {
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"=== Playlist Request Debug ===");
    BOOL isDelegateAvailable = NO;
    if (@available(iOS 14.0, *)) {
        isDelegateAvailable = YES;
    }
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Using delegate-based approach: %@", isDelegateAvailable ? @"YES" : @"NO");
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Initialization segment available: %@", self.initializationSegmentData ? @"YES" : @"NO");
    [self.segmentDataLock lock];
    NSUInteger segmentCount = self.segmentData.count;
    [self.segmentDataLock unlock];
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Media segments in memory: %lu", (unsigned long)segmentCount);
    __block NSUInteger arrayCount;
    dispatch_sync(self.segmentsQueue, ^{
        arrayCount = self.segments.count;
    });
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Segments array count: %lu", (unsigned long)arrayCount);
    
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Looking for playlist at: %@", playlistPath);
    
    // Check if file exists
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:playlistPath];
    RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Playlist file exists: %@", fileExists ? @"YES" : @"NO");
    
    NSData *playlistData = [NSData dataWithContentsOfFile:playlistPath];
    
    if (!playlistData) {
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"ERROR: Playlist file missing, generating on demand");
        // Generate playlist on demand
        [self updatePlaylist];
        
        // Try reading again
        playlistData = [NSData dataWithContentsOfFile:playlistPath];
        
        if (!playlistData) {
            // Still no playlist, check if we have any segments
            if (self.segments.count == 0) {
                RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"No segments generated yet, sending minimal playlist with sequence %ld", (long)self.mediaSequenceNumber);
                // Send a minimal playlist to keep client waiting
                NSString *minimalPlaylist = [NSString stringWithFormat:
                    @"#EXTM3U\n"
                    @"#EXT-X-VERSION:6\n"
                    @"#EXT-X-TARGETDURATION:6\n"
                    @"#EXT-X-MEDIA-SEQUENCE:%ld\n"
                    @"#EXT-X-PLAYLIST-TYPE:EVENT\n",
                    (long)self.mediaSequenceNumber];
                playlistData = [minimalPlaylist dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to generate playlist despite having %lu segments", (unsigned long)self.segments.count);
                [self sendErrorResponse:clientSocket code:500 message:@"Playlist generation failed"];
                return;
            }
        }
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaDebug, @"Playlist size: %lu bytes", (unsigned long)playlistData.length);
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaSegment, @"Segment requested: %@", segmentName);
    
    // First check if segment exists in memory (for delegate-based writing)
    if (@available(iOS 14.0, *)) {
        [self.segmentDataLock lock];
        NSData *segmentData = [self.segmentData objectForKey:segmentName];
        [self.segmentDataLock unlock];
        
        if (segmentData) {
            RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Found segment in memory, using delegate response");
            [self sendDelegateSegmentResponse:clientSocket segmentName:segmentName];
            return;
        }
    }
    
    // Validate segment name
    if (![segmentName hasSuffix:@".mp4"] && ![segmentName hasSuffix:@".m4s"] && ![segmentName hasSuffix:@".ts"]) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"ERROR: Invalid segment extension for: %@", segmentName);
        [self sendErrorResponse:clientSocket code:400 message:@"Invalid segment"];
        return;
    }
    
    NSString *segmentPath = [self.segmentDirectory stringByAppendingPathComponent:segmentName];
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaDebug, @"Looking for segment at: %@", segmentPath);
    
    // Debug: List all files in segment directory
    NSError *dirError;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.segmentDirectory error:&dirError];
    if (dirError) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaError, @"ERROR: Cannot list segment directory: %@", dirError);
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaDebug, @"Files in segment directory (%@): %@", self.segmentDirectory, files);
    }
    
    // Check if file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:segmentPath]) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaFile | RptrLogAreaError, @"ERROR: Segment not found at path: %@", segmentPath);
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
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaSegment | RptrLogAreaNetwork, @"Sending segment %@ (%lu bytes)", segmentName, (unsigned long)fileSize);
    
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
        RLog(RptrLogAreaHLS | RptrLogAreaFile | RptrLogAreaError, @"Failed to open segment file: %@", segmentPath);
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
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaSegment | RptrLogAreaNetwork, @"Sending initialization segment (%lu bytes)", (unsigned long)self.initializationSegmentData.length);
    
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
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Looking for segment: %@, available segments: %@", 
         segmentName, [allSegmentKeys componentsJoinedByString:@", "]);
    
    [self.segmentDataLock unlock];
    
    if (!segmentData) {
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaError, @"Segment not found: %@ (current index: %ld)", segmentName, (long)self.currentSegmentIndex);
        [self sendErrorResponse:clientSocket code:404 message:@"Segment not found"];
        return;
    }
    
    NSString *headers = [NSString stringWithFormat:
                        @"HTTP/1.1 200 OK\r\n"
                        @"Content-Type: video/iso.segment\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Access-Control-Allow-Origin: *\r\n"
                        @"Access-Control-Allow-Methods: GET, OPTIONS\r\n"
                        @"Access-Control-Allow-Headers: Range\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (unsigned long)segmentData.length];
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaSegment | RptrLogAreaNetwork, @"Sending delegate segment %@ (%lu bytes)", segmentName, (unsigned long)segmentData.length);
    
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
                         @"Connection: close\r\n"
                         @"\r\n"
                         @"%@",
                         (long)code, message,
                         (unsigned long)message.length,
                         message];
    
    send(clientSocket, response.UTF8String, response.length, MSG_NOSIGNAL);
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Location request received");
    
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Status request received from socket: %d", clientSocket);
    
    // Get location from delegate
    NSDictionary *locationData = nil;
    if ([self.delegate respondsToSelector:@selector(hlsServerRequestsLocation:)]) {
        locationData = [self.delegate hlsServerRequestsLocation:self];
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Location data received: %@", locationData);
    } else {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Delegate does not respond to hlsServerRequestsLocation");
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
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Sending status with title: %@", statusData[@"title"]);
    
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

- (void)sendTestPageResponse:(int)clientSocket {
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"Serving view page from template for socket: %d", clientSocket);
    
    @try {
        // Load template from bundle
        NSString *templatePath = [[NSBundle mainBundle] pathForResource:@"index" 
                                                                  ofType:@"html" 
                                                            inDirectory:@"WebResources"];
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Looking for template at path: %@", templatePath);
        
        if (!templatePath) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"HTML template not found in bundle - using embedded fallback");
            // Fall back to embedded HTML
            [self sendEmbeddedTestPageResponse:clientSocket];
            return;
        }
        
        NSError *error = nil;
        NSString *htmlTemplate = [NSString stringWithContentsOfFile:templatePath 
                                                           encoding:NSUTF8StringEncoding 
                                                              error:&error];
        
        if (error) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"Error loading template: %@", error);
            [self sendEmbeddedTestPageResponse:clientSocket];
            return;
        }
        
        // Create placeholder dictionary
        NSDictionary *placeholders = @{
            @"{{APP_TITLE}}": @"Rptr Live Stream",
            @"{{PAGE_TITLE}}": [self getStreamTitle] ?: @"Share Stream",
            @"{{STREAM_URL}}": [NSString stringWithFormat:@"/stream/%@/playlist.m3u8", self.randomPath],
            @"{{SERVER_PORT}}": [NSString stringWithFormat:@"%lu", (unsigned long)self.port],
            @"{{LOCATION_ENDPOINT}}": @"/location",
            @"{{INITIAL_STATUS}}": @"Connecting to stream..."
        };
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"DEBUG: Template placeholders:");
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"  STREAM_URL: %@", placeholders[@"{{STREAM_URL}}"]);
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"  randomPath: %@", self.randomPath);
        
        // Replace placeholders
        NSMutableString *processedHTML = [htmlTemplate mutableCopy];
        for (NSString *placeholder in placeholders) {
            [processedHTML replaceOccurrencesOfString:placeholder 
                                           withString:placeholders[placeholder] 
                                              options:NSLiteralSearch 
                                                range:NSMakeRange(0, processedHTML.length)];
        }
        
        NSString *html = processedHTML;
    
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"3. HTML string created, length: %lu", (unsigned long)[html length]);
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"4. Converting HTML to NSData...");
        NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
        if (!htmlData) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"ERROR: Failed to encode HTML data");
            [self sendErrorResponse:clientSocket code:500 message:@"Internal Server Error"];
            return;
        }
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"5. HTML data created, size: %lu bytes", (unsigned long)htmlData.length);
    
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"6. Creating HTTP headers...");
        NSString *headers = [NSString stringWithFormat:
                            @"HTTP/1.1 200 OK\r\n"
                            @"Content-Type: text/html\r\n"
                            @"Content-Length: %lu\r\n"
                            @"Connection: close\r\n"
                            @"\r\n",
                            (unsigned long)htmlData.length];
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"7. Headers created, length: %lu", (unsigned long)headers.length);
        
        // Send with error checking
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"8. Sending headers...");
        ssize_t headersSent = send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
        if (headersSent < 0) {
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaError, @"ERROR: Failed to send headers: %s (errno: %d)", strerror(errno), errno);
            return;
        }
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"9. Headers sent: %zd bytes", headersSent);
    
        // Send data in chunks to avoid large buffer issues
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"10. Preparing to send HTML data in chunks...");
        NSUInteger totalSent = 0;
        NSUInteger dataLength = htmlData.length;
        const uint8_t *bytes = htmlData.bytes;
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"11. Total data to send: %lu bytes", (unsigned long)dataLength);
        
        while (totalSent < dataLength) {
            NSUInteger chunkSize = MIN(8192, dataLength - totalSent);
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"Sending chunk: offset=%lu, size=%lu", (unsigned long)totalSent, (unsigned long)chunkSize);
            ssize_t sent = send(clientSocket, bytes + totalSent, chunkSize, MSG_NOSIGNAL);
            if (sent < 0) {
                RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaError, @"ERROR: Failed to send data: %s (errno: %d)", strerror(errno), errno);
                break;
            }
            totalSent += sent;
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"Chunk sent: %zd bytes, total sent: %lu/%lu", sent, (unsigned long)totalSent, (unsigned long)dataLength);
        }
        
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork | RptrLogAreaDebug, @"14. All data sent successfully: %lu bytes", (unsigned long)totalSent);
        
    } @catch (NSException *exception) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"EXCEPTION: %@", exception);
        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Exception reason: %@", exception.reason);
        RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Stack trace: %@", exception.callStackSymbols);
        [self sendErrorResponse:clientSocket code:500 message:@"Internal Server Error"];
    } @finally {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaDebug, @"15. Exiting sendTestPageResponse for socket: %d", clientSocket);
    }
}

- (void)sendExternalTestPageResponse:(int)clientSocket {
    NSString *html = @"<!DOCTYPE html>\n"
                     @"<html>\n"
                     @"<head>\n"
                     @"<title>HLS External Test</title>\n"
                     @"<meta name='viewport' content='width=device-width, initial-scale=1'>\n"
                     @"</head>\n"
                     @"<body>\n"
                     @"<h1>Testing with External HLS Stream</h1>\n"
                     @"<p>This tests HLS.js with a known-good stream to verify the player works.</p>\n"
                     @"<video id='video' controls autoplay style='width:100%;max-width:800px;'></video>\n"
                     @"<div id='info'>Loading external test stream...</div>\n"
                     @"<script src='https://cdn.jsdelivr.net/npm/hls.js@latest'></script>\n"
                     @"<script>\n"
                     @"var video = document.getElementById('video');\n"
                     @"var testUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';\n"
                     @"if (Hls.isSupported()) {\n"
                     @"  var hls = new Hls();\n"
                     @"  hls.loadSource(testUrl);\n"
                     @"  hls.attachMedia(video);\n"
                     @"  hls.on(Hls.Events.MANIFEST_PARSED, function() {\n"
                     @"    document.getElementById('info').innerHTML = 'External stream loaded successfully! HLS.js is working.';\n"
                     @"  });\n"
                     @"}\n"
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

#pragma mark - Utilities

- (NSArray<NSString *> *)getServerURLs {
    NSMutableArray *urls = [NSMutableArray array];
    
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr != NULL && temp_addr->ifa_addr->sa_family == AF_INET) {
                char ip[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr, ip, INET_ADDRSTRLEN) != NULL) {
                    NSString *ipString = [NSString stringWithUTF8String:ip];
                    if (![ipString isEqualToString:@"127.0.0.1"]) {
                        NSString *url = [NSString stringWithFormat:@"http://%@:%lu/view/%@", ipString, (unsigned long)self.port, self.randomPath];
                        [urls addObject:url];
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
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
            RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaNetwork, @"Removing inactive client: %@", clientAddress);
            
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
    RLog(RptrLogAreaHLS | RptrLogAreaMemory, @"Received memory warning - cleaning up segments");
    
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
                        RLog(RptrLogAreaHLS | RptrLogAreaMemory, @"Removed segment from memory: %@", segment.filename);
                    }
                }
            });
        }
        
        // Clear initialization segment if we're under severe pressure
        if (segmentDataCount > 5) {
            self.initializationSegmentData = nil;
            RLog(RptrLogAreaHLS | RptrLogAreaMemory, @"Cleared initialization segment from memory");
        }
        
        RLog(RptrLogAreaHLS | RptrLogAreaMemory, @"Memory cleanup complete - segments in memory: %lu -> %lu",
             (unsigned long)segmentDataCount, (unsigned long)self.segmentData.count);
        [self.segmentDataLock unlock];
    });
}

#pragma mark - Debug Helpers

#ifdef DEBUG
- (void)logWriterState {
    dispatch_async(self.writerQueue, ^{
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"=== Writer State ===");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Server running: %@", self.running ? @"YES" : @"NO");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Is writing: %@", self.isWriting ? @"YES" : @"NO");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Session started: %@", self.sessionStarted ? @"YES" : @"NO");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Asset writer: %@", self.assetWriter ? @"EXISTS" : @"NIL");
        if (self.assetWriter) {
            RLog(RptrLogAreaHLS | RptrLogAreaDebug | RptrLogAreaError, @"Writer status: %ld", (long)self.assetWriter.status);
            RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Writer error: %@", self.assetWriter.error);
        }
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Video input: %@", self.videoInput ? @"EXISTS" : @"NIL");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Frames processed: %ld", (long)self.framesProcessed);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Frames dropped: %ld", (long)self.framesDropped);
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Current segment: %ld", (long)self.currentSegmentIndex);
        RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"Segments count: %lu", (unsigned long)self.segments.count);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"==================");
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
    RLog(RptrLogAreaHLS | RptrLogAreaSegment | RptrLogAreaDebug, @"[DELEGATE] Received %@ segment: %lu bytes", segmentTypeStr, (unsigned long)segmentData.length);
    
    dispatch_async(self.writerQueue, ^{
        if (segmentType == AVAssetSegmentTypeInitialization) {
            // Store initialization segment
            self.initializationSegmentData = segmentData;
            RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Stored initialization segment: %lu bytes", (unsigned long)segmentData.length);
            
        } else if (segmentType == AVAssetSegmentTypeSeparable) {
            // Store media segment
            NSString *segmentName = [NSString stringWithFormat:@"segment_%03ld.m4s", (long)self.currentSegmentIndex];
            [self.segmentDataLock lock];
            [self.segmentData setObject:segmentData forKey:segmentName];
            [self.segmentDataLock unlock];
            
            // Create segment info
            HLSSegmentInfo *segmentInfo = [[HLSSegmentInfo alloc] init];
            segmentInfo.filename = segmentName;
            segmentInfo.duration = segmentReport ? segmentReport.trackReports.firstObject.duration : CMTimeMakeWithSeconds(SEGMENT_DURATION, 1);
            segmentInfo.sequenceNumber = self.mediaSequenceNumber;
            segmentInfo.createdAt = [NSDate date];
            segmentInfo.fileSize = segmentData.length;
            
            dispatch_barrier_async(self.segmentsQueue, ^{
                [self.segments addObject:segmentInfo];
                
                RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Stored media segment: %@ (%lu bytes, %.2fs)", 
                      segmentName, (unsigned long)segmentData.length, CMTimeGetSeconds(segmentInfo.duration));
                
                // Clean up old segments to prevent memory buildup
                if (self.segments.count > MAX_SEGMENTS) {
                    NSInteger removeCount = self.segments.count - MAX_SEGMENTS;
                    for (NSInteger i = 0; i < removeCount; i++) {
                        HLSSegmentInfo *oldSegment = self.segments[0];
                        [self.segmentDataLock lock];
                        [self.segmentData removeObjectForKey:oldSegment.filename];
                        [self.segmentDataLock unlock];
                        [self.segments removeObjectAtIndex:0];
                        RLog(RptrLogAreaHLS | RptrLogAreaSegment, @"Removed old segment: %@", oldSegment.filename);
                    }
                }
            });
            
            self.currentSegmentIndex++;
            self.mediaSequenceNumber++;
            
            // Update playlist
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updatePlaylist];
            });
            
            // Clean up old segments
            [self cleanupOldSegments];
        }
    });
}

#pragma mark - Template Methods

- (void)sendEmbeddedTestPageResponse:(int)clientSocket {
    // Fallback embedded HTML when template is not available
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Using embedded fallback HTML");
    
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
                     @"<script>\n"
                     @"var video = document.getElementById('video');\n"
                     @"var status = document.getElementById('status');\n"
                     @"var connectionStatus = document.getElementById('connectionStatus');\n"
                     @"var videoSrc = window.location.origin + '/stream/' + window.location.pathname.split('/')[2] + '/playlist.m3u8';\n"
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
                     @"  if (hls) {\n"
                     @"    hls.destroy();\n"
                     @"  }\n"
                     @"  \n"
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
                     @"  hls = new Hls({\n"
                     @"    debug: false,\n"
                     @"    enableWorker: true,\n"
                     @"    lowLatencyMode: true\n"
                     @"  });\n"
                     @"  \n"
                     @"  setConnectionStatus('connecting');\n"
                     @"  status.innerHTML = 'Connecting to stream...';\n"
                     @"  \n"
                     @"  hls.loadSource(videoSrc);\n"
                     @"  hls.attachMedia(video);\n"
                     @"  \n"
                     @"  hls.on(Hls.Events.MANIFEST_PARSED, function() {\n"
                     @"    status.innerHTML = 'Stream connected';\n"
                     @"    setConnectionStatus('');\n"
                     @"    video.play().catch(function(e) {\n"
                     @"      console.log('Autoplay prevented:', e);\n"
                     @"    });\n"
                     @"  });\n"
                     @"  \n"
                     @"  hls.on(Hls.Events.ERROR, function (event, data) {\n"
                     @"    console.log('HLS error:', data.type, data.details);\n"
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
                     @"initializeMap();\n"
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
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"Resource not found: %@", path);
        [self sendErrorResponse:clientSocket code:404 message:@"Resource not found"];
        return;
    }
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:resourcePath options:0 error:&error];
    
    if (error || !data) {
        RLog(RptrLogAreaHLS | RptrLogAreaHTTP | RptrLogAreaError, @"Error reading resource %@: %@", path, error);
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
                        @"Cache-Control: max-age=86400\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        mimeType,
                        (unsigned long)data.length];
    
    send(clientSocket, headers.UTF8String, headers.length, MSG_NOSIGNAL);
    send(clientSocket, data.bytes, data.length, MSG_NOSIGNAL);
    
    RLog(RptrLogAreaHLS | RptrLogAreaHTTP, @"Served bundled resource: %@ (%@ bytes)", path, @(data.length));
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
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Regenerated randomized URL path: %@ (was: %@)", _randomPath, self.previousRandomPath);
    
    // Clear all active clients
    dispatch_barrier_async(self.clientsQueue, ^{
        [self.activeClients removeAllObjects];
    });
    
    // Clear the previous path after a delay to allow final 410 responses
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.previousRandomPath = nil;
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Cleared previous random path - old URLs will now get 404");
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
    RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Reset segment index to %ld to avoid conflicts", (long)self.currentSegmentIndex);
    
    // Clear playlist file if it exists
    NSString *playlistPath = [self.baseDirectory stringByAppendingPathComponent:@"playlist.m3u8"];
    [[NSFileManager defaultManager] removeItemAtPath:playlistPath error:nil];
    
    // Stop current writer if active
    if (self.isWriting) {
        RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Stopping active writer before path regeneration");
        dispatch_async(self.writerQueue, ^{
            [self stopAssetWriter];
        });
    }
    
    // Create an initial empty playlist file for the new URL
    // This ensures clients get a valid (but empty) playlist instead of 404
    [self updatePlaylist];
    
    RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Path regeneration complete - all segments cleared, empty playlist created");
    
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
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Stream title updated to: %@", title);
}

@end