//
//  RptrVideoQualitySettings.h
//  Rptr
//
//  Video quality settings for different streaming modes
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RptrVideoQualityMode) {
    RptrVideoQualityModeReliable = 0,  // Optimized for reliability on poor networks
    RptrVideoQualityModeRealtime = 1   // Optimized for low latency
};

@interface RptrVideoQualitySettings : NSObject

// Quality mode
@property (nonatomic, readonly) RptrVideoQualityMode mode;
@property (nonatomic, readonly) NSString *modeName;
@property (nonatomic, readonly) NSString *modeDescription;

// HLS Segment Settings
@property (nonatomic, readonly) NSTimeInterval segmentDuration;      // Target segment duration
@property (nonatomic, readonly) NSTimeInterval segmentMinDuration;    // Minimum allowed duration
@property (nonatomic, readonly) NSTimeInterval segmentMaxDuration;    // Maximum before force rotation
@property (nonatomic, readonly) NSInteger targetDuration;             // Playlist target duration
@property (nonatomic, readonly) NSInteger maxSegments;                // Max segments in playlist
@property (nonatomic, readonly) NSInteger playlistWindow;             // Sliding window size
@property (nonatomic, readonly) NSTimeInterval segmentTimerOffset;    // When to start checking
@property (nonatomic, readonly) NSTimeInterval segmentRotationDelay;  // Max wait for keyframe

// Video Settings
@property (nonatomic, readonly) NSInteger videoBitrate;
@property (nonatomic, readonly) NSInteger videoWidth;
@property (nonatomic, readonly) NSInteger videoHeight;
@property (nonatomic, readonly) NSInteger videoFrameRate;
@property (nonatomic, readonly) NSInteger videoKeyFrameInterval;
@property (nonatomic, readonly) CGFloat videoKeyFrameDuration;
@property (nonatomic, readonly) CGFloat videoQuality;
@property (nonatomic, readonly) NSString *sessionPreset;

// Audio Settings
@property (nonatomic, readonly) NSInteger audioBitrate;
@property (nonatomic, readonly) NSInteger audioSampleRate;
@property (nonatomic, readonly) NSInteger audioChannels;

// Network Settings
@property (nonatomic, readonly) NSInteger httpBufferSize;
@property (nonatomic, readonly) NSTimeInterval clientInactivityTimeout;

// Update Intervals
@property (nonatomic, readonly) NSTimeInterval locationUpdateInterval;
@property (nonatomic, readonly) NSTimeInterval audioLevelUpdateInterval;

// Class methods
+ (instancetype)settingsForMode:(RptrVideoQualityMode)mode;
+ (instancetype)reliableSettings;
+ (instancetype)realtimeSettings;

// Instance methods
- (instancetype)initWithMode:(RptrVideoQualityMode)mode;

@end

NS_ASSUME_NONNULL_END