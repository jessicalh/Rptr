//
//  RptrVideoToolboxEncoder.h
//  Rptr
//
//  VideoToolbox-based H.264 encoder for HLS streaming
//  Replaces AVAssetWriter to avoid delegate issues
//

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RptrVideoToolboxEncoder;

// Encoded frame data structure
@interface RptrEncodedFrame : NSObject
@property (nonatomic, strong) NSData *data;           // H.264 NALU data
@property (nonatomic, assign) CMTime presentationTime;
@property (nonatomic, assign) CMTime decodeTime;
@property (nonatomic, assign) CMTime duration;
@property (nonatomic, assign) BOOL isKeyframe;        // IDR frame
@property (nonatomic, assign) BOOL isParameterSet;    // SPS/PPS
@end

// Delegate for receiving encoded frames
@protocol RptrVideoToolboxEncoderDelegate <NSObject>
- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncodeFrame:(RptrEncodedFrame *)frame;
- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncodeParameterSets:(NSData *)sps pps:(NSData *)pps;
- (void)encoder:(RptrVideoToolboxEncoder *)encoder didEncounterError:(NSError *)error;
@optional
- (void)encoderDidStartSession:(RptrVideoToolboxEncoder *)encoder;
- (void)encoderDidEndSession:(RptrVideoToolboxEncoder *)encoder;
@end

@interface RptrVideoToolboxEncoder : NSObject

@property (nonatomic, weak) id<RptrVideoToolboxEncoderDelegate> delegate;
@property (nonatomic, readonly) BOOL isEncoding;
@property (nonatomic, readonly) VTCompressionSessionRef compressionSession;

// Configuration
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger frameRate;
@property (nonatomic, assign) NSInteger bitrate;
@property (nonatomic, assign) NSInteger keyframeInterval; // In frames

// Initialize with configuration
- (instancetype)initWithWidth:(NSInteger)width 
                        height:(NSInteger)height
                     frameRate:(NSInteger)frameRate
                       bitrate:(NSInteger)bitrate;

// Start/stop encoding session
- (BOOL)startEncoding;
- (void)stopEncoding;

// Encode a sample buffer
- (void)encodeVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer 
         presentationTime:(CMTime)presentationTime 
                 duration:(CMTime)duration;

// Force keyframe on next encode
- (void)forceKeyframe;

// Flush any pending frames
- (void)flush;

@end

NS_ASSUME_NONNULL_END