//
//  RptrVideoQualitySettings.m
//  Rptr
//
//  Video quality settings implementation
//

#import "RptrVideoQualitySettings.h"

@implementation RptrVideoQualitySettings

- (instancetype)initWithMode:(RptrVideoQualityMode)mode {
    self = [super init];
    if (self) {
        _mode = mode;
        [self configureSettingsForMode:mode];
    }
    return self;
}

+ (instancetype)settingsForMode:(RptrVideoQualityMode)mode {
    return [[self alloc] initWithMode:mode];
}

+ (instancetype)reliableSettings {
    return [[self alloc] initWithMode:RptrVideoQualityModeReliable];
}

+ (instancetype)realtimeSettings {
    return [[self alloc] initWithMode:RptrVideoQualityModeRealtime];
}

- (void)configureSettingsForMode:(RptrVideoQualityMode)mode {
    switch (mode) {
        case RptrVideoQualityModeReliable:
            [self configureReliableMode];
            break;
            
        case RptrVideoQualityModeRealtime:
            [self configureRealtimeMode];
            break;
    }
}

- (void)configureReliableMode {
    // Mode identification
    _modeName = @"Reliable";
    _modeDescription = @"Optimized for poor network conditions";
    
    // HLS Segment Settings - 1 second for browser compatibility
    _segmentDuration = 1.0;          // Target: 1 second segments (optimal for browsers)
    _segmentMinDuration = 0.5;       // Min: Half of target (prevents micro-segments)
    _segmentMaxDuration = 1.5;       // Max: 1.5x target (force rotation)
    _targetDuration = 6;             // Playlist target duration (Apple recommendation)
    _maxSegments = 20;               // 80 seconds of buffer
    _playlistWindow = 6;             // 24 seconds window
    _segmentTimerOffset = 0.2;       // Start checking at 0.8s (target - offset)
    _segmentRotationDelay = 0.5;     // Max 0.5s wait for keyframe after target
    
    // Video Settings - Lower quality for reliability
    _videoBitrate = 600000;          // 600 kbps
    _videoWidth = 960;               // qHD width
    _videoHeight = 540;              // qHD height
    _videoFrameRate = 15;            // 15 fps (keep low for reliability)
    _videoKeyFrameInterval = 15;     // Every 1 second at 15fps (aligned with segments)
    _videoKeyFrameDuration = 1.0;    // 1 second keyframe interval (critical for segments)
    _videoQuality = 0.75;            // 75% quality
    _sessionPreset = AVCaptureSessionPresetHigh;
    
    // Audio Settings - Mono to save bandwidth
    _audioBitrate = 64000;           // 64 kbps
    _audioSampleRate = 44100;        // 44.1 kHz
    _audioChannels = 1;              // Mono
    
    // Network Settings
    _httpBufferSize = 16384;         // 16KB buffer
    _clientInactivityTimeout = 30.0; // 30 second timeout
    
    // Update Intervals
    _locationUpdateInterval = 2.0;   // Every 2 seconds
    _audioLevelUpdateInterval = 0.1; // 10 times per second
}

- (void)configureRealtimeMode {
    // Mode identification
    _modeName = @"Real-time";
    _modeDescription = @"Low latency for good networks";
    
    // HLS Segment Settings - 1 second for browser compatibility
    _segmentDuration = 1.0;          // Target: 1 second segments (optimal for browsers)
    _segmentMinDuration = 0.5;       // Min: Half of target (prevents micro-segments)
    _segmentMaxDuration = 1.5;       // Max: 1.5x target (force rotation)
    _targetDuration = 3;             // Playlist target duration
    _maxSegments = 6;                // 12 seconds of buffer
    _playlistWindow = 3;             // 6 seconds window (3 segments)
    _segmentTimerOffset = 0.2;       // Start checking at 0.8s (target - offset)
    _segmentRotationDelay = 0.5;     // Max 0.5s wait for keyframe after target
    
    // Video Settings - Balanced for real-time streaming
    _videoBitrate = 1200000;         // 1.2 Mbps (reduced bitrate with 24fps)
    _videoWidth = 1280;              // HD width
    _videoHeight = 720;              // HD height
    _videoFrameRate = 24;            // 24 fps (cinema standard, saves bandwidth)
    _videoKeyFrameInterval = 24;     // Every 1 second at 24fps (aligned with segments)
    _videoKeyFrameDuration = 1.0;    // 1 second keyframe interval (critical for segments)
    _videoQuality = 0.85;            // 85% quality (slightly reduced)
    _sessionPreset = AVCaptureSessionPreset1280x720;
    
    // Audio Settings - Stereo for better quality
    _audioBitrate = 128000;          // 128 kbps
    _audioSampleRate = 48000;        // 48 kHz
    _audioChannels = 2;              // Stereo
    
    // Network Settings
    _httpBufferSize = 32768;         // 32KB buffer
    _clientInactivityTimeout = 10.0; // 10 second timeout
    
    // Update Intervals
    _locationUpdateInterval = 1.0;   // Every second
    _audioLevelUpdateInterval = 0.05; // 20 times per second
}

@end