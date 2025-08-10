//
//  HLSSegmentObserver.m
//  Rptr
//
//  Segment health monitoring and protocol enforcement
//

#import "HLSSegmentObserver.h"
#import "RptrLogger.h"

@implementation HLSSegmentTrace

- (instancetype)init {
    if (self = [super init]) {
        _eventLog = [NSMutableArray array];
        _createdAt = [NSDate date];
        _lastAccessedAt = [NSDate date];
        _requestCount = 0;
        _servedCount = 0;
        _failedCount = 0;
    }
    return self;
}

@end

@interface HLSSegmentObserver ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, HLSSegmentTrace *> *traces;
@property (nonatomic, strong) NSMutableArray<NSString *> *recentIssues;
@property (nonatomic, strong) dispatch_queue_t observerQueue;
@property (nonatomic, assign) NSInteger lastSeenSequence;
@property (nonatomic, assign) NSInteger expectedNextSequence;
@end

@implementation HLSSegmentObserver

+ (instancetype)sharedObserver {
    static HLSSegmentObserver *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[HLSSegmentObserver alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _traces = [NSMutableDictionary dictionary];
        _recentIssues = [NSMutableArray array];
        _observerQueue = dispatch_queue_create("com.rptr.segment.observer", DISPATCH_QUEUE_SERIAL);
        _lastSeenSequence = -1;
        _expectedNextSequence = 0;
    }
    return self;
}

- (void)trackSegmentEvent:(HLSSegmentEvent)event 
             segmentName:(NSString *)segmentName
          sequenceNumber:(NSInteger)sequenceNumber
                    size:(NSUInteger)size
              segmentID:(NSString *)segmentID {
    
    dispatch_async(self.observerQueue, ^{
        // Get or create trace
        HLSSegmentTrace *trace = self.traces[segmentName];
        if (!trace) {
            trace = [[HLSSegmentTrace alloc] init];
            trace.filename = segmentName;
            trace.sequenceNumber = sequenceNumber;
            trace.size = size;
            trace.segmentID = segmentID ?: [[NSUUID UUID] UUIDString];
            self.traces[segmentName] = trace;
        }
        
        // Create timestamp
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"HH:mm:ss.SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        // Track event
        NSString *eventString = nil;
        switch (event) {
            case HLSSegmentEventCreated: {
                eventString = [NSString stringWithFormat:@"[%@] CREATED (seq=%ld, size=%lu)", 
                              timestamp, (long)sequenceNumber, (unsigned long)size];
                trace.createdAt = [NSDate date];
                
                // Check for sequence gaps
                if (self.lastSeenSequence >= 0 && sequenceNumber != self.expectedNextSequence) {
                    NSString *issue = [NSString stringWithFormat:@"[%@] SEQUENCE GAP: Expected seq=%ld, got seq=%ld", 
                                      timestamp, (long)self.expectedNextSequence, (long)sequenceNumber];
                    [self.recentIssues addObject:issue];
                    RLog(RptrLogAreaError, @"[OBSERVER] %@", issue);
                }
                self.lastSeenSequence = sequenceNumber;
                self.expectedNextSequence = sequenceNumber + 1;
                break;
            }
                
            case HLSSegmentEventStored:
                eventString = [NSString stringWithFormat:@"[%@] STORED in memory", timestamp];
                break;
                
            case HLSSegmentEventRequested:
                eventString = [NSString stringWithFormat:@"[%@] REQUESTED by client", timestamp];
                trace.requestCount++;
                trace.lastAccessedAt = [NSDate date];
                break;
                
            case HLSSegmentEventServed:
                eventString = [NSString stringWithFormat:@"[%@] SERVED successfully", timestamp];
                trace.servedCount++;
                break;
                
            case HLSSegmentEventNotFound: {
                eventString = [NSString stringWithFormat:@"[%@] NOT FOUND (404)", timestamp];
                trace.failedCount++;
                
                // Track 404 issues
                NSString *issue = [NSString stringWithFormat:@"[%@] 404: %@ (seq=%ld)", 
                                  timestamp, segmentName, (long)sequenceNumber];
                [self.recentIssues addObject:issue];
                RLog(RptrLogAreaError, @"[OBSERVER] %@", issue);
                break;
            }
                
            case HLSSegmentEventRemoved:
                eventString = [NSString stringWithFormat:@"[%@] REMOVED from memory", timestamp];
                break;
                
            case HLSSegmentEventPlaylistUpdated:
                eventString = [NSString stringWithFormat:@"[%@] PLAYLIST updated", timestamp];
                break;
        }
        
        if (eventString) {
            [trace.eventLog addObject:eventString];
            
            // Keep event log reasonable size
            if (trace.eventLog.count > 20) {
                [trace.eventLog removeObjectAtIndex:0];
            }
        }
        
        // Keep recent issues list reasonable
        if (self.recentIssues.count > 50) {
            [self.recentIssues removeObjectsInRange:NSMakeRange(0, 10)];
        }
    });
}

- (NSString *)getSegmentHealthReport {
    __block NSMutableString *report = [NSMutableString string];
    
    dispatch_sync(self.observerQueue, ^{
        [report appendString:@"\n========== SEGMENT HEALTH REPORT ==========\n"];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"HH:mm:ss"];
        
        // Overall stats
        NSInteger totalSegments = self.traces.count;
        NSInteger totalRequests = 0;
        NSInteger totalServed = 0;
        NSInteger totalFailed = 0;
        NSInteger activeSegments = 0;
        
        NSDate *now = [NSDate date];
        
        for (HLSSegmentTrace *trace in self.traces.allValues) {
            totalRequests += trace.requestCount;
            totalServed += trace.servedCount;
            totalFailed += trace.failedCount;
            
            // Consider segment active if accessed in last 30 seconds
            if ([now timeIntervalSinceDate:trace.lastAccessedAt] < 30) {
                activeSegments++;
            }
        }
        
        [report appendFormat:@"Total Segments: %ld\n", (long)totalSegments];
        [report appendFormat:@"Active Segments: %ld\n", (long)activeSegments];
        [report appendFormat:@"Total Requests: %ld\n", (long)totalRequests];
        [report appendFormat:@"Successful: %ld (%.1f%%)\n", 
         (long)totalServed, totalRequests > 0 ? (totalServed * 100.0 / totalRequests) : 0];
        [report appendFormat:@"Failed (404): %ld (%.1f%%)\n", 
         (long)totalFailed, totalRequests > 0 ? (totalFailed * 100.0 / totalRequests) : 0];
        [report appendFormat:@"Last Sequence: %ld\n", (long)self.lastSeenSequence];
        [report appendFormat:@"Expected Next: %ld\n", (long)self.expectedNextSequence];
        
        // Recent problem segments
        [report appendString:@"\n--- Problem Segments ---\n"];
        NSArray *sortedTraces = [self.traces.allValues sortedArrayUsingComparator:^NSComparisonResult(HLSSegmentTrace *t1, HLSSegmentTrace *t2) {
            return [@(t2.failedCount) compare:@(t1.failedCount)];
        }];
        
        NSInteger problemCount = 0;
        for (HLSSegmentTrace *trace in sortedTraces) {
            if (trace.failedCount > 0) {
                [report appendFormat:@"  %@ (seq=%ld): %ld requests, %ld served, %ld failed\n",
                 trace.filename, (long)trace.sequenceNumber, 
                 (long)trace.requestCount, (long)trace.servedCount, (long)trace.failedCount];
                problemCount++;
                if (problemCount >= 5) break; // Show top 5 problem segments
            }
        }
        
        if (problemCount == 0) {
            [report appendString:@"  No problem segments\n"];
        }
        
        [report appendString:@"==========================================\n"];
    });
    
    return report;
}

- (NSArray<NSString *> *)checkProtocolCompliance {
    __block NSMutableArray<NSString *> *violations = [NSMutableArray array];
    
    dispatch_sync(self.observerQueue, ^{
        // Check for sequence gaps
        NSMutableSet *sequences = [NSMutableSet set];
        NSInteger minSeq = NSIntegerMax;
        NSInteger maxSeq = NSIntegerMin;
        
        for (HLSSegmentTrace *trace in self.traces.allValues) {
            [sequences addObject:@(trace.sequenceNumber)];
            if (trace.sequenceNumber < minSeq) minSeq = trace.sequenceNumber;
            if (trace.sequenceNumber > maxSeq) maxSeq = trace.sequenceNumber;
        }
        
        // Check for missing sequences
        if (minSeq != NSIntegerMax && maxSeq != NSIntegerMin) {
            for (NSInteger seq = minSeq; seq <= maxSeq; seq++) {
                if (![sequences containsObject:@(seq)]) {
                    [violations addObject:[NSString stringWithFormat:@"Missing segment with sequence %ld", (long)seq]];
                }
            }
        }
        
        // Check for segments never served
        for (HLSSegmentTrace *trace in self.traces.allValues) {
            if (trace.requestCount > 0 && trace.servedCount == 0) {
                [violations addObject:[NSString stringWithFormat:@"Segment %@ requested but never served", trace.filename]];
            }
        }
        
        // Check for high failure rate
        for (HLSSegmentTrace *trace in self.traces.allValues) {
            if (trace.requestCount > 0) {
                double failureRate = (double)trace.failedCount / trace.requestCount;
                if (failureRate > 0.5) {
                    [violations addObject:[NSString stringWithFormat:@"Segment %@ has %.0f%% failure rate", 
                                         trace.filename, failureRate * 100]];
                }
            }
        }
    });
    
    return violations;
}

- (HLSSegmentTrace *)getTraceForSegment:(NSString *)segmentName {
    __block HLSSegmentTrace *trace = nil;
    dispatch_sync(self.observerQueue, ^{
        trace = self.traces[segmentName];
    });
    return trace;
}

- (void)clearTracesOlderThan:(NSTimeInterval)seconds {
    dispatch_async(self.observerQueue, ^{
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-seconds];
        NSMutableArray *toRemove = [NSMutableArray array];
        
        for (NSString *key in self.traces) {
            HLSSegmentTrace *trace = self.traces[key];
            if ([trace.lastAccessedAt compare:cutoff] == NSOrderedAscending) {
                [toRemove addObject:key];
            }
        }
        
        for (NSString *key in toRemove) {
            [self.traces removeObjectForKey:key];
        }
        
        if (toRemove.count > 0) {
            RLog(RptrLogAreaProtocol, @"[OBSERVER] Cleared %lu old segment traces", (unsigned long)toRemove.count);
        }
    });
}

- (NSArray<NSString *> *)getRecentIssues {
    __block NSArray *issues = nil;
    dispatch_sync(self.observerQueue, ^{
        issues = [self.recentIssues copy];
    });
    return issues;
}

@end