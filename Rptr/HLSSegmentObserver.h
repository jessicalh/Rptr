//
//  HLSSegmentObserver.h
//  Rptr
//
//  Segment health monitoring and protocol enforcement
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Segment event types for tracking
typedef NS_ENUM(NSInteger, HLSSegmentEvent) {
    HLSSegmentEventCreated,
    HLSSegmentEventStored,
    HLSSegmentEventRequested,
    HLSSegmentEventServed,
    HLSSegmentEventNotFound,
    HLSSegmentEventRemoved,
    HLSSegmentEventPlaylistUpdated
};

// Segment tracking info
@interface HLSSegmentTrace : NSObject
@property (nonatomic, strong) NSString *segmentID;      // Unique ID for tracing
@property (nonatomic, strong) NSString *filename;       // segment_XXX.m4s
@property (nonatomic, assign) NSInteger sequenceNumber; // Media sequence number
@property (nonatomic, strong) NSDate *createdAt;        // When segment was created
@property (nonatomic, strong) NSDate *lastAccessedAt;   // Last time served
@property (nonatomic, assign) NSInteger requestCount;   // How many times requested
@property (nonatomic, assign) NSInteger servedCount;    // How many times successfully served
@property (nonatomic, assign) NSInteger failedCount;    // How many 404s
@property (nonatomic, assign) NSUInteger size;          // Segment size in bytes
@property (nonatomic, strong) NSMutableArray<NSString *> *eventLog; // Event history
@end

@interface HLSSegmentObserver : NSObject

+ (instancetype)sharedObserver;

// Track segment lifecycle events
- (void)trackSegmentEvent:(HLSSegmentEvent)event 
             segmentName:(NSString *)segmentName
          sequenceNumber:(NSInteger)sequenceNumber
                    size:(NSUInteger)size
              segmentID:(nullable NSString *)segmentID;

// Get current segment health status
- (NSString *)getSegmentHealthReport;

// Check for protocol violations
- (NSArray<NSString *> *)checkProtocolCompliance;

// Get trace for specific segment
- (nullable HLSSegmentTrace *)getTraceForSegment:(NSString *)segmentName;

// Clear old traces (cleanup)
- (void)clearTracesOlderThan:(NSTimeInterval)seconds;

// Get summary of recent issues
- (NSArray<NSString *> *)getRecentIssues;

@end

NS_ASSUME_NONNULL_END