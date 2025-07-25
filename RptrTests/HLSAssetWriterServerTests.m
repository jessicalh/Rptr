//
//  HLSAssetWriterServerTests.m
//  RptrTests
//
//  Unit tests for HLSAssetWriterServer
//

#import <XCTest/XCTest.h>
#import "HLSAssetWriterServer.h"
#import <AVFoundation/AVFoundation.h>

@interface HLSAssetWriterServerTests : XCTestCase <HLSAssetWriterServerDelegate>

@property (nonatomic, strong) HLSAssetWriterServer *server;
@property (nonatomic, strong) XCTestExpectation *delegateExpectation;
@property (nonatomic, strong) NSError *lastError;

@end

@implementation HLSAssetWriterServerTests

- (void)setUp {
    [super setUp];
    self.server = [[HLSAssetWriterServer alloc] init];
    self.server.delegate = self;
    self.delegateExpectation = nil;
    self.lastError = nil;
}

- (void)tearDown {
    [self.server stopServer];
    self.server = nil;
    self.delegateExpectation = nil;
    self.lastError = nil;
    [super tearDown];
}

#pragma mark - Server Lifecycle Tests

- (void)testServerInitialization {
    XCTAssertNotNil(self.server, @"Server should be initialized");
    XCTAssertFalse(self.server.isRunning, @"Server should not be running initially");
    XCTAssertNil(self.server.serverURL, @"Server URL should be nil when not running");
}

- (void)testServerStartStop {
    // Start server
    NSError *error = nil;
    BOOL started = [self.server startServerWithError:&error];
    
    XCTAssertTrue(started, @"Server should start successfully");
    XCTAssertNil(error, @"No error should occur when starting server");
    XCTAssertTrue(self.server.isRunning, @"Server should be running");
    XCTAssertNotNil(self.server.serverURL, @"Server URL should be available");
    XCTAssertTrue([self.server.serverURL.absoluteString containsString:@"http://"], @"Server URL should be HTTP");
    XCTAssertTrue([self.server.serverURL.absoluteString containsString:@":8080"], @"Server URL should use port 8080");
    
    // Stop server
    [self.server stopServer];
    XCTAssertFalse(self.server.isRunning, @"Server should not be running after stop");
}

- (void)testServerMultipleStartAttempts {
    NSError *error1 = nil;
    BOOL started1 = [self.server startServerWithError:&error1];
    XCTAssertTrue(started1, @"First start should succeed");
    
    NSError *error2 = nil;
    BOOL started2 = [self.server startServerWithError:&error2];
    XCTAssertFalse(started2, @"Second start should fail");
    XCTAssertNotNil(error2, @"Error should be provided for second start attempt");
}

#pragma mark - Streaming Tests

- (void)testStartStopStreaming {
    // Start server first
    [self.server startServerWithError:nil];
    
    // Configure video settings
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(1920),
        AVVideoHeightKey: @(1080)
    };
    
    // Start streaming
    self.delegateExpectation = [self expectationWithDescription:@"Streaming should start"];
    [self.server startStreamingWithVideoSettings:videoSettings audioSettings:nil];
    
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    
    XCTAssertTrue(self.server.isStreaming, @"Server should be streaming");
    XCTAssertNotNil(self.server.playlistURL, @"Playlist URL should be available");
    XCTAssertTrue([self.server.playlistURL.absoluteString containsString:@"playlist.m3u8"], @"Playlist URL should contain playlist.m3u8");
    
    // Stop streaming
    [self.server stopStreaming];
    XCTAssertFalse(self.server.isStreaming, @"Server should not be streaming after stop");
}

- (void)testProcessSampleBuffer {
    // Start server and streaming
    [self.server startServerWithError:nil];
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(1920),
        AVVideoHeightKey: @(1080)
    };
    
    [self.server startStreamingWithVideoSettings:videoSettings audioSettings:nil];
    
    // Create mock sample buffer
    CMSampleBufferRef mockBuffer = [self createMockVideoSampleBuffer];
    
    // Process sample buffer
    if (mockBuffer) {
        [self.server processSampleBuffer:mockBuffer];
        CFRelease(mockBuffer);
    }
    
    // Note: In a real test, we'd verify the buffer was processed correctly
    // This would require mocking AVAssetWriter or checking internal state
}

#pragma mark - Playlist Tests

- (void)testPlaylistGeneration {
    // Start server and streaming
    [self.server startServerWithError:nil];
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(1920),
        AVVideoHeightKey: @(1080)
    };
    
    [self.server startStreamingWithVideoSettings:videoSettings audioSettings:nil];
    
    // Get playlist content
    NSString *playlist = [self.server currentPlaylistContent];
    
    XCTAssertNotNil(playlist, @"Playlist should be generated");
    XCTAssertTrue([playlist containsString:@"#EXTM3U"], @"Playlist should start with #EXTM3U");
    XCTAssertTrue([playlist containsString:@"#EXT-X-VERSION:6"], @"Playlist should specify version 6 for fMP4");
    XCTAssertTrue([playlist containsString:@"#EXT-X-TARGETDURATION:"], @"Playlist should specify target duration");
}

#pragma mark - Error Handling Tests

- (void)testStreamingWithoutServer {
    // Try to start streaming without starting server
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(1920),
        AVVideoHeightKey: @(1080)
    };
    
    self.delegateExpectation = [self expectationWithDescription:@"Should receive error"];
    [self.server startStreamingWithVideoSettings:videoSettings audioSettings:nil];
    
    [self waitForExpectationsWithTimeout:1.0 handler:nil];
    
    XCTAssertNotNil(self.lastError, @"Should receive error when streaming without server");
    XCTAssertFalse(self.server.isStreaming, @"Should not be streaming");
}

#pragma mark - HLSAssetWriterServerDelegate

- (void)hlsServerDidStartStreaming:(HLSAssetWriterServer *)server {
    [self.delegateExpectation fulfill];
}

- (void)hlsServerDidStopStreaming:(HLSAssetWriterServer *)server {
    // Used for stop streaming tests if needed
}

- (void)hlsServer:(HLSAssetWriterServer *)server didEncounterError:(NSError *)error {
    self.lastError = error;
    if (self.delegateExpectation) {
        [self.delegateExpectation fulfill];
    }
}

- (void)hlsServer:(HLSAssetWriterServer *)server didGenerateSegment:(NSString *)segmentName {
    // Used for segment generation tests
}

#pragma mark - Helper Methods

- (CMSampleBufferRef)createMockVideoSampleBuffer {
    // Create a simple mock video sample buffer for testing
    // In a real implementation, this would create a proper sample buffer
    // For now, return NULL as creating a real sample buffer requires significant setup
    return NULL;
}

@end