//
//  RptrDIYHLSServer.h
//  Rptr
//
//  DIY HLS Server using VideoToolbox + Custom fMP4 Muxer
//  Replaces AVAssetWriter to avoid delegate issues
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "RptrVideoToolboxEncoder.h"
#import "RptrFMP4Muxer.h"

NS_ASSUME_NONNULL_BEGIN

@class RptrDIYHLSServer;

@protocol RptrDIYHLSServerDelegate <NSObject>
@optional
- (void)diyServer:(RptrDIYHLSServer *)server didStartOnPort:(NSInteger)port;
- (void)diyServer:(RptrDIYHLSServer *)server didGenerateInitSegment:(NSData *)initSegment;
- (void)diyServer:(RptrDIYHLSServer *)server didGenerateMediaSegment:(NSData *)segment 
                                                              duration:(NSTimeInterval)duration
                                                        sequenceNumber:(uint32_t)sequenceNumber;
- (void)diyServer:(RptrDIYHLSServer *)server didEncounterError:(NSError *)error;
- (void)diyServerDidStop:(RptrDIYHLSServer *)server;
@end

@interface RptrDIYHLSServer : NSObject <RptrVideoToolboxEncoderDelegate>

@property (nonatomic, weak) id<RptrDIYHLSServerDelegate> delegate;
@property (nonatomic, readonly) BOOL isStreaming;
@property (nonatomic, readonly) NSString *playlistURL;
@property (nonatomic, readonly) NSInteger port;
@property (nonatomic, readonly) NSString *randomPath;

// Configuration
@property (nonatomic, assign) NSTimeInterval segmentDuration; // Default: 1.0 second
@property (nonatomic, assign) NSInteger playlistWindowSize;   // Default: 10 segments

// Initialize with video configuration
- (instancetype)initWithWidth:(NSInteger)width
                        height:(NSInteger)height
                     frameRate:(NSInteger)frameRate
                       bitrate:(NSInteger)bitrate;

// Server control
- (BOOL)startServerOnPort:(NSInteger)port;
- (void)stopServer;

// Streaming control
- (BOOL)startStreaming;
- (void)stopStreaming;

// Process video frames
- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)processPixelBuffer:(CVPixelBufferRef)pixelBuffer
          presentationTime:(CMTime)presentationTime;

// Get current statistics
- (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END