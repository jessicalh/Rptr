//
//  RptrFMP4Muxer.h
//  Rptr
//
//  Fragmented MP4 muxer for HLS streaming
//  Creates fMP4 segments with precise control
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Track configuration
@interface RptrFMP4TrackConfig : NSObject
@property (nonatomic, assign) uint32_t trackID;
@property (nonatomic, strong) NSString *mediaType; // "video" or "audio"

// Video properties
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, strong, nullable) NSData *sps;
@property (nonatomic, strong, nullable) NSData *pps;

// Audio properties
@property (nonatomic, assign) NSInteger sampleRate;
@property (nonatomic, assign) NSInteger channelCount;
@property (nonatomic, strong, nullable) NSData *audioSpecificConfig;

// Common properties
@property (nonatomic, assign) uint32_t timescale;
@end

// Sample data for muxing
@interface RptrFMP4Sample : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) CMTime presentationTime;
@property (nonatomic, assign) CMTime decodeTime;
@property (nonatomic, assign) CMTime duration;
@property (nonatomic, assign) BOOL isSync; // Keyframe for video
@property (nonatomic, assign) uint32_t trackID;
@end

// Segment info
@interface RptrFMP4Segment : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) CMTime duration;
@property (nonatomic, assign) uint32_t sequenceNumber;
@property (nonatomic, assign) BOOL isInitSegment;
@end

@interface RptrFMP4Muxer : NSObject

// Track management
- (void)addTrack:(RptrFMP4TrackConfig *)trackConfig;
- (void)removeTrackWithID:(uint32_t)trackID;
- (void)removeAllTracks;

// Stream management
- (void)resetStreamStartTime;

// Init segment generation
- (nullable NSData *)createInitializationSegment;

// Media segment generation
- (nullable NSData *)createMediaSegmentWithSamples:(NSArray<RptrFMP4Sample *> *)samples
                                     sequenceNumber:(uint32_t)sequenceNumber
                                      baseMediaTime:(CMTime)baseMediaTime;

// Convenience methods for single-track segments
- (nullable NSData *)createVideoSegmentWithNALUs:(NSArray<NSData *> *)nalus
                                         keyframes:(NSArray<NSNumber *> *)keyframes
                                    sequenceNumber:(uint32_t)sequenceNumber
                                     baseMediaTime:(CMTime)baseMediaTime;

// Box creation helpers (exposed for testing/debugging)
- (NSData *)createFtypBox;
- (NSData *)createMoovBoxWithTracks:(NSArray<RptrFMP4TrackConfig *> *)tracks;
- (NSData *)createMoofBoxWithSamples:(NSArray<RptrFMP4Sample *> *)samples
                       sequenceNumber:(uint32_t)sequenceNumber;
- (NSData *)createMdatBoxWithSamples:(NSArray<RptrFMP4Sample *> *)samples;

@end

NS_ASSUME_NONNULL_END