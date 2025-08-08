//
//  HLSAssetWriterServer.h
//  Rptr
//
//  Modern HLS (HTTP Live Streaming) Server with AVAssetWriter
//  
//  This class provides a complete HLS streaming solution that:
//  - Accepts video/audio samples from capture devices
//  - Encodes to H.264/AAC using hardware acceleration
//  - Generates HLS-compliant segmented streams
//  - Serves content via embedded HTTP server
//  - Manages memory efficiently with in-memory segments
//
//  Thread Safety: All public methods are thread-safe
//  Memory Model: Automatic segment cleanup based on limits
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "RptrVideoQualitySettings.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * HLSAssetWriterServerDelegate Protocol
 * 
 * Optional callbacks for monitoring server state and client activity
 * All delegate methods are called on the main queue
 */
@protocol HLSAssetWriterServerDelegate <NSObject>
@optional

/**
 * Called when the server successfully starts
 * @param baseURL The base URL for accessing the stream
 */
- (void)hlsServerDidStart:(NSString *)baseURL;

/**
 * Called when the server stops
 */
- (void)hlsServerDidStop;

/**
 * Called when an error occurs during streaming
 * @param server The server instance
 * @param error The error that occurred
 */
- (void)hlsServer:(id)server didEncounterError:(NSError *)error;

/**
 * Called when a client connects to the stream
 * @param server The server instance
 * @param clientAddress IP address of the connected client
 */
- (void)hlsServer:(id)server clientConnected:(NSString *)clientAddress;

/**
 * Called when a client disconnects
 * @param server The server instance
 * @param clientAddress IP address of the disconnected client
 */
- (void)hlsServer:(id)server clientDisconnected:(NSString *)clientAddress;

/**
 * Called when location information is requested
 * @param server The server instance
 * @return Dictionary with latitude, longitude, accuracy keys (or nil)
 */
- (NSDictionary *)hlsServerRequestsLocation:(id)server;

@end

/**
 * HLSAssetWriterServer
 * 
 * Complete HLS streaming server implementation
 * Handles encoding, segmentation, and HTTP delivery
 */
@interface HLSAssetWriterServer : NSObject <AVAssetWriterDelegate>

#pragma mark - Properties

/** Delegate for server events and callbacks */
@property (nonatomic, weak) id<HLSAssetWriterServerDelegate> delegate;

/** YES if actively streaming, NO otherwise */
@property (nonatomic, readonly) BOOL isStreaming;

/** TCP port the server is running on */
@property (nonatomic, readonly) NSUInteger port;

/** Number of currently connected clients */
@property (nonatomic, readonly) NSUInteger connectedClients;

/** Full URL for accessing the stream */
@property (nonatomic, readonly) NSString *streamURL;

/** Random path component for basic security */
@property (nonatomic, readonly) NSString *randomPath;

/** Title displayed in the web interface */
@property (atomic, strong) NSString *streamTitle;

/** Current video quality settings */
@property (nonatomic, strong) RptrVideoQualitySettings *qualitySettings;

#pragma mark - Thread-Safe Accessors

/**
 * Gets the current stream title (thread-safe)
 * @return Current stream title
 */
- (NSString *)getStreamTitle;

/**
 * Sets the stream title asynchronously (thread-safe)
 * @param title New title for the stream
 */
- (void)setStreamTitleAsync:(NSString *)title;

#pragma mark - Initialization

/**
 * Creates a new HLS server instance
 * @param port TCP port to bind to (use 0 for default 8080)
 * @return Initialized server instance
 */
- (instancetype)initWithPort:(NSUInteger)port;

#pragma mark - Server Control

/**
 * Starts the HTTP server
 * @param error Error output parameter
 * @return YES if successful, NO on error
 */
- (BOOL)startServer:(NSError **)error;

/**
 * Stops the server and releases all resources
 */
- (void)stopServer;

#pragma mark - Streaming

/**
 * Processes a video frame for encoding
 * @param sampleBuffer Video sample buffer from capture session
 * @note Thread-safe, can be called from any queue
 */
- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/**
 * Processes audio samples for encoding
 * @param sampleBuffer Audio sample buffer from capture session
 * @note Thread-safe, can be called from any queue
 */
- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/**
 * Stops streaming but keeps the server running
 * Clients will receive an empty playlist
 */
- (void)stopStreaming;

/**
 * Prepares the asset writer for a new streaming session
 * Call this after regenerating the random path
 */
- (void)prepareForStreaming;

#pragma mark - Network Information

/**
 * Gets all available server URLs (cellular first, then WiFi)
 * @return Array of full URLs for accessing the stream
 */
- (NSArray<NSString *> *)getServerURLs;

#pragma mark - Utilities

/**
 * Logs current asset writer state for debugging
 */
- (void)logWriterState;

/**
 * Generates a new random path and resets client tracking
 * Use when starting a new streaming session
 */
- (void)regenerateRandomPath;

/**
 * Updates video quality settings
 * @param settings New quality settings to apply
 * @note This will stop current streaming and require restart
 */
- (void)updateQualitySettings:(RptrVideoQualitySettings *)settings;

@end

NS_ASSUME_NONNULL_END