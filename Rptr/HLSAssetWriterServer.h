//
//  HLSAssetWriterServer.h
//  Rptr
//
//  Modern HLS Server using AVAssetWriter with fragmented MP4
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol HLSAssetWriterServerDelegate <NSObject>
@optional
- (void)hlsServerDidStart:(NSString *)baseURL;
- (void)hlsServerDidStop;
- (void)hlsServer:(id)server didEncounterError:(NSError *)error;
- (void)hlsServer:(id)server clientConnected:(NSString *)clientAddress;
- (void)hlsServer:(id)server clientDisconnected:(NSString *)clientAddress;
- (NSDictionary *)hlsServerRequestsLocation:(id)server;
@end

@interface HLSAssetWriterServer : NSObject <AVAssetWriterDelegate>

@property (nonatomic, weak) id<HLSAssetWriterServerDelegate> delegate;
@property (nonatomic, readonly) BOOL isStreaming;
@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) NSUInteger connectedClients;
@property (nonatomic, readonly) NSString *streamURL;
@property (nonatomic, readonly) NSString *randomPath;
@property (atomic, strong) NSString *streamTitle;

// Thread-safe property accessors
- (NSString *)getStreamTitle;
- (void)setStreamTitleAsync:(NSString *)title;

// Initialize with port
- (instancetype)initWithPort:(NSUInteger)port;

// Start/stop the HLS server
- (BOOL)startServer:(NSError **)error;
- (void)stopServer;

// Feed video samples from capture output
- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// Feed audio samples from capture output  
- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// Stop streaming (but keep server running)
- (void)stopStreaming;

// Prepare asset writer for streaming (call after URL regeneration)
- (void)prepareForStreaming;

// Get network addresses
- (NSArray<NSString *> *)getServerURLs;

// Debug helpers
- (void)logWriterState;

// Regenerate random path and reset client count
- (void)regenerateRandomPath;

@end

NS_ASSUME_NONNULL_END