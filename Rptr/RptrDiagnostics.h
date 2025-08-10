//
//  RptrDiagnostics.h
//  Rptr
//
//  Diagnostic monitoring for ANR detection and memory tracking
//

#import <Foundation/Foundation.h>
#import <MetricKit/MetricKit.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations
@protocol RptrDiagnosticsDelegate;

/**
 * Memory pressure levels based on available memory
 */
typedef NS_ENUM(NSInteger, RptrMemoryPressureLevel) {
    RptrMemoryPressureNormal = 0,     // > 100MB available
    RptrMemoryPressureWarning = 1,    // 50-100MB available
    RptrMemoryPressureCritical = 2,   // < 50MB available
    RptrMemoryPressureTerminal = 3    // < 20MB available (danger of termination)
};

/**
 * ANR (Application Not Responding) severity levels
 */
typedef NS_ENUM(NSInteger, RptrANRSeverity) {
    RptrANRSeverityLight = 0,     // 1-2 seconds
    RptrANRSeverityModerate = 1,  // 2-4 seconds
    RptrANRSeveritySevere = 2,    // 4-8 seconds
    RptrANRSeverityCritical = 3   // > 8 seconds
};

/**
 * Memory statistics snapshot
 */
@interface RptrMemoryStats : NSObject
@property (nonatomic, readonly) NSUInteger footprintBytes;      // Current memory footprint
@property (nonatomic, readonly) NSUInteger availableBytes;      // Available memory
@property (nonatomic, readonly) NSUInteger peakFootprintBytes;  // Peak memory usage
@property (nonatomic, readonly) NSUInteger segmentBufferBytes;  // Memory used by HLS segments
@property (nonatomic, readonly) RptrMemoryPressureLevel pressureLevel;
@property (nonatomic, readonly) NSDate *timestamp;
@end

/**
 * ANR event information
 */
@interface RptrANREvent : NSObject
@property (nonatomic, readonly) NSTimeInterval duration;        // How long main thread was blocked
@property (nonatomic, readonly) RptrANRSeverity severity;
@property (nonatomic, readonly) NSString *stackTrace;          // Stack trace of main thread
@property (nonatomic, readonly) NSDate *timestamp;
@property (nonatomic, readonly) BOOL recovered;                // Whether app recovered or was terminated
@end

/**
 * RptrDiagnostics
 * 
 * Provides runtime diagnostics for monitoring app health, specifically:
 * - ANR (Application Not Responding) detection
 * - Memory pressure monitoring
 * - MetricKit integration for production metrics
 * 
 * This class helps identify performance issues before they cause app termination
 */
@interface RptrDiagnostics : NSObject <MXMetricManagerSubscriber>

// Singleton instance
+ (instancetype)sharedDiagnostics;

// Configuration
@property (nonatomic, weak, nullable) id<RptrDiagnosticsDelegate> delegate;
@property (nonatomic, assign) BOOL enableANRDetection;         // Default: YES
@property (nonatomic, assign) BOOL enableMemoryMonitoring;     // Default: YES
@property (nonatomic, assign) BOOL enableMetricKit;            // Default: YES
@property (nonatomic, assign) NSTimeInterval anrThreshold;     // Default: 2.0 seconds
@property (nonatomic, assign) NSTimeInterval memoryCheckInterval; // Default: 5.0 seconds

// Control methods
- (void)startMonitoring;
- (void)stopMonitoring;

// Memory monitoring
- (RptrMemoryStats *)currentMemoryStats;
- (void)logMemoryWarning:(NSString *)context;
- (NSUInteger)availableMemory;
- (NSUInteger)memoryFootprint;

// ANR detection
- (void)pauseANRDetection;  // Pause during known blocking operations
- (void)resumeANRDetection;

// HLS segment memory tracking
- (void)updateSegmentMemoryUsage:(NSUInteger)bytes;

// Manual event logging
- (void)logDiagnosticEvent:(NSString *)event details:(nullable NSDictionary *)details;

// Export diagnostic report
- (NSString *)generateDiagnosticReport;

@end

/**
 * Delegate protocol for receiving diagnostic events
 */
@protocol RptrDiagnosticsDelegate <NSObject>
@optional

// Memory events
- (void)diagnostics:(RptrDiagnostics *)diagnostics 
    didDetectMemoryPressure:(RptrMemoryPressureLevel)level 
                      stats:(RptrMemoryStats *)stats;

- (void)diagnostics:(RptrDiagnostics *)diagnostics 
    memoryUsageExceededThreshold:(NSUInteger)thresholdBytes 
                           stats:(RptrMemoryStats *)stats;

// ANR events
- (void)diagnostics:(RptrDiagnostics *)diagnostics 
       didDetectANR:(RptrANREvent *)event;

- (void)diagnostics:(RptrDiagnostics *)diagnostics 
       didRecoverFromANR:(RptrANREvent *)event;

// MetricKit events (production metrics)
- (void)diagnostics:(RptrDiagnostics *)diagnostics 
    didReceiveMetricPayload:(MXMetricPayload *)payload API_AVAILABLE(ios(13.0));

- (void)diagnostics:(RptrDiagnostics *)diagnostics 
    didReceiveDiagnosticPayload:(MXDiagnosticPayload *)payload API_AVAILABLE(ios(14.0));

@end

NS_ASSUME_NONNULL_END