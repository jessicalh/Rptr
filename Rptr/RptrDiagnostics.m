//
//  RptrDiagnostics.m
//  Rptr
//
//  Diagnostic monitoring for ANR detection and memory tracking
//

#import "RptrDiagnostics.h"
#import "RptrLogger.h"
#import "RptrConstants.h"
#import <os/proc.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <execinfo.h>

#pragma mark - Memory Stats Implementation

@implementation RptrMemoryStats

- (instancetype)initWithFootprint:(NSUInteger)footprint 
                        available:(NSUInteger)available 
                             peak:(NSUInteger)peak 
                    segmentBuffer:(NSUInteger)segmentBuffer {
    self = [super init];
    if (self) {
        _footprintBytes = footprint;
        _availableBytes = available;
        _peakFootprintBytes = peak;
        _segmentBufferBytes = segmentBuffer;
        _timestamp = [NSDate date];
        
        // Calculate pressure level based on available memory
        if (available < 20 * 1024 * 1024) {  // < 20MB
            _pressureLevel = RptrMemoryPressureTerminal;
        } else if (available < 50 * 1024 * 1024) {  // < 50MB
            _pressureLevel = RptrMemoryPressureCritical;
        } else if (available < 100 * 1024 * 1024) {  // < 100MB
            _pressureLevel = RptrMemoryPressureWarning;
        } else {
            _pressureLevel = RptrMemoryPressureNormal;
        }
    }
    return self;
}

@end

#pragma mark - ANR Event Implementation

@implementation RptrANREvent

- (instancetype)initWithDuration:(NSTimeInterval)duration 
                       stackTrace:(NSString *)stackTrace 
                        recovered:(BOOL)recovered {
    self = [super init];
    if (self) {
        _duration = duration;
        _stackTrace = stackTrace;
        _recovered = recovered;
        _timestamp = [NSDate date];
        
        // Calculate severity based on duration
        if (duration >= 8.0) {
            _severity = RptrANRSeverityCritical;
        } else if (duration >= 4.0) {
            _severity = RptrANRSeveritySevere;
        } else if (duration >= 2.0) {
            _severity = RptrANRSeverityModerate;
        } else {
            _severity = RptrANRSeverityLight;
        }
    }
    return self;
}

@end

#pragma mark - RptrDiagnostics Implementation

@interface RptrDiagnostics ()

// Monitoring state
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, assign) NSUInteger peakMemoryFootprint;
@property (nonatomic, assign) NSUInteger currentSegmentMemory;

// ANR detection
@property (nonatomic, strong) dispatch_queue_t watchdogQueue;
@property (nonatomic, strong) dispatch_source_t anrTimer;
@property (nonatomic, assign) NSTimeInterval lastMainThreadCheck;
@property (nonatomic, assign) BOOL anrDetectionPaused;
@property (nonatomic, assign) NSInteger anrCheckCounter;

// Memory monitoring
@property (nonatomic, strong) dispatch_source_t memoryTimer;
@property (nonatomic, strong) dispatch_source_t memoryPressureSource;
@property (nonatomic, strong) NSMutableArray<RptrMemoryStats *> *memoryHistory;

// Event logging
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *diagnosticEvents;
@property (nonatomic, strong) NSDateFormatter *timestampFormatter;

@end

@implementation RptrDiagnostics

#pragma mark - Singleton

+ (instancetype)sharedDiagnostics {
    static RptrDiagnostics *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        // Default configuration
        _enableANRDetection = YES;
        _enableMemoryMonitoring = YES;
        _enableMetricKit = YES;
        _anrThreshold = 2.0;  // 2 seconds
        _memoryCheckInterval = 5.0;  // Check every 5 seconds
        
        // Initialize queues
        _watchdogQueue = dispatch_queue_create("com.rptr.diagnostics.watchdog", DISPATCH_QUEUE_SERIAL);
        
        // Initialize storage
        _memoryHistory = [NSMutableArray array];
        _diagnosticEvents = [NSMutableArray array];
        
        // Setup timestamp formatter
        _timestampFormatter = [[NSDateFormatter alloc] init];
        _timestampFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        _timestampFormatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        
        // Register for MetricKit if available
        if (@available(iOS 13.0, *)) {
            if (_enableMetricKit) {
                [[MXMetricManager sharedManager] addSubscriber:self];
                RLogInfo(@"RptrDiagnostics: Registered for MetricKit");
            }
        }
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
    if (@available(iOS 13.0, *)) {
        [[MXMetricManager sharedManager] removeSubscriber:self];
    }
}

#pragma mark - Monitoring Control

- (void)startMonitoring {
    if (self.isMonitoring) {
        return;
    }
    
    self.isMonitoring = YES;
    RLogInfo(@"RptrDiagnostics: Starting monitoring");
    
    if (self.enableANRDetection) {
        [self startANRDetection];
    }
    
    if (self.enableMemoryMonitoring) {
        [self startMemoryMonitoring];
    }
}

- (void)stopMonitoring {
    if (!self.isMonitoring) {
        return;
    }
    
    self.isMonitoring = NO;
    RLogInfo(@"RptrDiagnostics: Stopping monitoring");
    
    [self stopANRDetection];
    [self stopMemoryMonitoring];
}

#pragma mark - ANR Detection

- (void)startANRDetection {
    if (self.anrTimer) {
        return;
    }
    
    RLogDebug(@"RptrDiagnostics: Starting ANR detection with threshold: %.1fs", self.anrThreshold);
    
    // Create a timer that fires every 0.5 seconds to check main thread
    self.anrTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.watchdogQueue);
    dispatch_source_set_timer(self.anrTimer, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.anrTimer, ^{
        [weakSelf checkMainThreadResponsiveness];
    });
    
    dispatch_resume(self.anrTimer);
}

- (void)stopANRDetection {
    if (self.anrTimer) {
        dispatch_source_cancel(self.anrTimer);
        self.anrTimer = nil;
    }
}

- (void)checkMainThreadResponsiveness {
    if (self.anrDetectionPaused) {
        return;
    }
    
    NSTimeInterval startTime = CACurrentMediaTime();
    __block BOOL responded = NO;
    __block NSTimeInterval responseTime = 0;
    
    // Increment check counter
    self.anrCheckCounter++;
    NSInteger currentCheck = self.anrCheckCounter;
    
    // Dispatch work to main thread with a specific identifier
    dispatch_async(dispatch_get_main_queue(), ^{
        responded = YES;
        responseTime = CACurrentMediaTime() - startTime;
        
        // Only process if this is still the current check
        if (currentCheck == self.anrCheckCounter) {
            if (responseTime > self.anrThreshold) {
                // Main thread was blocked
                [self handleANRDetected:responseTime];
            }
        }
    });
    
    // Check after threshold time
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.anrThreshold * NSEC_PER_SEC)), self.watchdogQueue, ^{
        if (!responded && currentCheck == self.anrCheckCounter) {
            // Still checking - main thread is severely blocked
            NSTimeInterval blockDuration = CACurrentMediaTime() - startTime;
            [self handleANRDetected:blockDuration];
        }
    });
}

- (void)handleANRDetected:(NSTimeInterval)duration {
    // Get main thread stack trace
    NSString *stackTrace = [self getCurrentStackTrace];
    
    // Create ANR event
    RptrANREvent *event = [[RptrANREvent alloc] initWithDuration:duration 
                                                       stackTrace:stackTrace 
                                                        recovered:YES];
    
    // Log the event
    RLogError(@"RptrDiagnostics: ANR detected! Duration: %.2fs, Severity: %ld", 
              duration, (long)event.severity);
    
    // Log diagnostic event
    [self logDiagnosticEvent:@"ANR" details:@{
        @"duration": @(duration),
        @"severity": @(event.severity),
        @"stackTrace": stackTrace ?: @"unavailable"
    }];
    
    // Notify delegate on main thread
    if ([self.delegate respondsToSelector:@selector(diagnostics:didDetectANR:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate diagnostics:self didDetectANR:event];
        });
    }
}

- (void)pauseANRDetection {
    self.anrDetectionPaused = YES;
    RLogDebug(@"RptrDiagnostics: ANR detection paused");
}

- (void)resumeANRDetection {
    self.anrDetectionPaused = NO;
    self.anrCheckCounter++;  // Invalidate any pending checks
    RLogDebug(@"RptrDiagnostics: ANR detection resumed");
}

#pragma mark - Memory Monitoring

- (void)startMemoryMonitoring {
    if (self.memoryTimer) {
        return;
    }
    
    RLogDebug(@"RptrDiagnostics: Starting memory monitoring");
    
    // Setup periodic memory checking
    self.memoryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(self.memoryTimer, DISPATCH_TIME_NOW, self.memoryCheckInterval * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.memoryTimer, ^{
        [weakSelf checkMemoryStatus];
    });
    
    dispatch_resume(self.memoryTimer);
    
    // Setup memory pressure monitoring
    [self setupMemoryPressureMonitoring];
}

- (void)stopMemoryMonitoring {
    if (self.memoryTimer) {
        dispatch_source_cancel(self.memoryTimer);
        self.memoryTimer = nil;
    }
    
    if (self.memoryPressureSource) {
        dispatch_source_cancel(self.memoryPressureSource);
        self.memoryPressureSource = nil;
    }
}

- (void)setupMemoryPressureMonitoring {
    // Monitor system memory pressure
    self.memoryPressureSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                                       DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.memoryPressureSource, ^{
        unsigned long pressureLevel = dispatch_source_get_data(weakSelf.memoryPressureSource);
        [weakSelf handleMemoryPressure:pressureLevel];
    });
    
    dispatch_resume(self.memoryPressureSource);
}

- (void)checkMemoryStatus {
    RptrMemoryStats *stats = [self currentMemoryStats];
    
    // Update peak memory
    if (stats.footprintBytes > self.peakMemoryFootprint) {
        self.peakMemoryFootprint = stats.footprintBytes;
    }
    
    // Add to history (keep last 12 samples = 1 minute at 5 second intervals)
    @synchronized(self.memoryHistory) {
        [self.memoryHistory addObject:stats];
        if (self.memoryHistory.count > 12) {
            [self.memoryHistory removeObjectAtIndex:0];
        }
    }
    
    // Check for memory pressure
    if (stats.pressureLevel >= RptrMemoryPressureWarning) {
        RLogWarning(@"RptrDiagnostics: Memory pressure detected - Level: %ld, Available: %.1fMB, Footprint: %.1fMB",
                    (long)stats.pressureLevel,
                    stats.availableBytes / (1024.0 * 1024.0),
                    stats.footprintBytes / (1024.0 * 1024.0));
        
        // Notify delegate
        if ([self.delegate respondsToSelector:@selector(diagnostics:didDetectMemoryPressure:stats:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate diagnostics:self didDetectMemoryPressure:stats.pressureLevel stats:stats];
            });
        }
    }
}

- (void)handleMemoryPressure:(unsigned long)pressureLevel {
    NSString *pressureString = @"Unknown";
    RptrMemoryPressureLevel level = RptrMemoryPressureNormal;
    
    if (pressureLevel & DISPATCH_MEMORYPRESSURE_CRITICAL) {
        pressureString = @"CRITICAL";
        level = RptrMemoryPressureCritical;
    } else if (pressureLevel & DISPATCH_MEMORYPRESSURE_WARN) {
        pressureString = @"WARNING";
        level = RptrMemoryPressureWarning;
    }
    
    RLogError(@"RptrDiagnostics: System memory pressure: %@", pressureString);
    
    // Log diagnostic event
    [self logDiagnosticEvent:@"SystemMemoryPressure" details:@{
        @"level": pressureString,
        @"availableMemory": @([self availableMemory]),
        @"footprint": @([self memoryFootprint])
    }];
    
    // Get current stats and notify delegate
    RptrMemoryStats *stats = [self currentMemoryStats];
    if ([self.delegate respondsToSelector:@selector(diagnostics:didDetectMemoryPressure:stats:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate diagnostics:self didDetectMemoryPressure:level stats:stats];
        });
    }
}

#pragma mark - Memory Information

- (RptrMemoryStats *)currentMemoryStats {
    NSUInteger footprint = [self memoryFootprint];
    NSUInteger available = [self availableMemory];
    
    return [[RptrMemoryStats alloc] initWithFootprint:footprint
                                             available:available
                                                  peak:self.peakMemoryFootprint
                                         segmentBuffer:self.currentSegmentMemory];
}

- (NSUInteger)availableMemory {
    // Use os_proc_available_memory if available (iOS 13+)
    if (@available(iOS 13.0, *)) {
        return os_proc_available_memory();
    }
    
    // Fallback: estimate based on system memory and current usage
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t infoCount = HOST_VM_INFO_COUNT;
    kern_return_t kernReturn = host_statistics64(mach_host_self(), HOST_VM_INFO, (host_info64_t)&vmStats, &infoCount);
    
    if (kernReturn != KERN_SUCCESS) {
        return 0;
    }
    
    return (vm_page_size * vmStats.free_count);
}

- (NSUInteger)memoryFootprint {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(),
                                   MACH_TASK_BASIC_INFO,
                                   (task_info_t)&info,
                                   &size);
    if (kerr == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

- (void)updateSegmentMemoryUsage:(NSUInteger)bytes {
    self.currentSegmentMemory = bytes;
    
    // Check if segment memory is too high
    if (bytes > 100 * 1024 * 1024) {  // > 100MB in segments
        RLogWarning(@"RptrDiagnostics: High segment memory usage: %.1fMB", bytes / (1024.0 * 1024.0));
        [self logDiagnosticEvent:@"HighSegmentMemory" details:@{
            @"bytes": @(bytes),
            @"segmentCount": @(bytes / (4 * 1024 * 1024))  // Estimate based on 4MB segments
        }];
    }
}

- (void)logMemoryWarning:(NSString *)context {
    RptrMemoryStats *stats = [self currentMemoryStats];
    RLogWarning(@"RptrDiagnostics: Memory warning - %@: Footprint: %.1fMB, Available: %.1fMB",
                context,
                stats.footprintBytes / (1024.0 * 1024.0),
                stats.availableBytes / (1024.0 * 1024.0));
    
    [self logDiagnosticEvent:@"MemoryWarning" details:@{
        @"context": context,
        @"footprint": @(stats.footprintBytes),
        @"available": @(stats.availableBytes),
        @"pressure": @(stats.pressureLevel)
    }];
}

#pragma mark - MetricKit Support

- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads API_AVAILABLE(ios(13.0)) {
    for (MXMetricPayload *payload in payloads) {
        // Log key metrics
        if (payload.memoryMetrics) {
            RLogInfo(@"RptrDiagnostics: MetricKit Memory - Peak: %.1fMB, Avg Suspended: %.1fMB",
                     payload.memoryMetrics.peakMemoryUsage.doubleValue / (1024.0 * 1024.0),
                     payload.memoryMetrics.averageSuspendedMemory.averageMeasurement.doubleValue / (1024.0 * 1024.0));
        }
        
        if (payload.applicationExitMetrics) {
            if (@available(iOS 14.0, *)) {
                RLogWarning(@"RptrDiagnostics: MetricKit Exits - Foreground Normal: %ld, Background: %ld",
                            (long)payload.applicationExitMetrics.foregroundExitData.cumulativeNormalAppExitCount,
                            (long)payload.applicationExitMetrics.backgroundExitData.cumulativeNormalAppExitCount);
            }
        }
        
        // Notify delegate
        if ([self.delegate respondsToSelector:@selector(diagnostics:didReceiveMetricPayload:)]) {
            [self.delegate diagnostics:self didReceiveMetricPayload:payload];
        }
    }
}

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads API_AVAILABLE(ios(14.0)) {
    for (MXDiagnosticPayload *payload in payloads) {
        // Log diagnostic information
        if (payload.hangDiagnostics) {
            for (MXHangDiagnostic *hang in payload.hangDiagnostics) {
                RLogError(@"RptrDiagnostics: MetricKit Hang - Duration: %.1fs",
                          hang.hangDuration.doubleValue);
            }
        }
        
        // Notify delegate
        if ([self.delegate respondsToSelector:@selector(diagnostics:didReceiveDiagnosticPayload:)]) {
            [self.delegate diagnostics:self didReceiveDiagnosticPayload:payload];
        }
    }
}

#pragma mark - Diagnostic Logging

- (void)logDiagnosticEvent:(NSString *)event details:(nullable NSDictionary *)details {
    NSDictionary *eventData = @{
        @"event": event,
        @"timestamp": [self.timestampFormatter stringFromDate:[NSDate date]],
        @"details": details ?: @{}
    };
    
    @synchronized(self.diagnosticEvents) {
        [self.diagnosticEvents addObject:eventData];
        
        // Keep last 100 events
        if (self.diagnosticEvents.count > 100) {
            [self.diagnosticEvents removeObjectAtIndex:0];
        }
    }
}

- (NSString *)generateDiagnosticReport {
    NSMutableString *report = [NSMutableString string];
    
    [report appendString:@"=== Rptr Diagnostic Report ===\n"];
    [report appendFormat:@"Generated: %@\n\n", [self.timestampFormatter stringFromDate:[NSDate date]]];
    
    // Memory section
    RptrMemoryStats *currentStats = [self currentMemoryStats];
    [report appendString:@"== Memory Status ==\n"];
    [report appendFormat:@"Current Footprint: %.1f MB\n", currentStats.footprintBytes / (1024.0 * 1024.0)];
    [report appendFormat:@"Available Memory: %.1f MB\n", currentStats.availableBytes / (1024.0 * 1024.0)];
    [report appendFormat:@"Peak Footprint: %.1f MB\n", currentStats.peakFootprintBytes / (1024.0 * 1024.0)];
    [report appendFormat:@"Segment Buffer: %.1f MB\n", currentStats.segmentBufferBytes / (1024.0 * 1024.0)];
    [report appendFormat:@"Pressure Level: %ld\n\n", (long)currentStats.pressureLevel];
    
    // Recent events
    [report appendString:@"== Recent Diagnostic Events ==\n"];
    @synchronized(self.diagnosticEvents) {
        NSArray *recentEvents = [self.diagnosticEvents subarrayWithRange:NSMakeRange(MAX(0, (NSInteger)self.diagnosticEvents.count - 20), MIN(20, self.diagnosticEvents.count))];
        for (NSDictionary *event in recentEvents) {
            [report appendFormat:@"%@ - %@: %@\n", event[@"timestamp"], event[@"event"], event[@"details"]];
        }
    }
    
    return report;
}

#pragma mark - Helper Methods

- (NSString *)getCurrentStackTrace {
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    
    NSMutableString *stackTrace = [NSMutableString string];
    for (int i = 0; i < frames; i++) {
        [stackTrace appendFormat:@"%s\n", symbols[i]];
    }
    
    free(symbols);
    return stackTrace;
}

@end