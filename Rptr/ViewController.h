//
//  ViewController.h
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import "HLSAssetWriterServer.h"
#import "RptrDIYHLSServer.h"
#import "RptrVideoQualitySettings.h"
#import "RptrDiagnostics.h"

@interface ViewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, CLLocationManagerDelegate, HLSAssetWriterServerDelegate, RptrDIYHLSServerDelegate, RptrDiagnosticsDelegate>

@property (nonatomic, strong) NSMutableDictionary<NSString *, AVCaptureSession *> *captureSessions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVCaptureMovieFileOutput *> *movieFileOutputs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVCaptureVideoDataOutput *> *videoDataOutputs;
@property (nonatomic, strong) AVCaptureSession *captureSession; // Current active session
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieFileOutput; // Current active output
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput; // Current active data output
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioDataOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInput *audioWriterInput;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) AVCaptureDevice *currentCameraDevice;
@property (nonatomic, strong) NSMutableArray<UILabel *> *endpointLabels;
@property (nonatomic, strong) NSMutableArray<UIButton *> *endpointCopyButtons;
@property (nonatomic, strong) UILabel *locationLabel;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UILabel *utcTimeLabel;
@property (nonatomic, strong) UILabel *streamInfoLabel;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) CLLocation *currentLocation;
@property (nonatomic, strong) NSTimer *utcTimer;
@property (nonatomic, strong) NSTimer *locationUpdateTimer;
@property (nonatomic, strong) NSTimer *burstTimer;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t overlayQueue;
@property (nonatomic, strong) NSMutableArray *recentFrameBrightness;
@property (nonatomic, strong) NSMutableDictionary *cameraActivityScores;
@property (nonatomic, strong) NSMutableDictionary *cameraSwitchTimestamps;
@property (nonatomic, strong) NSTimer *cameraEvaluationTimer;
@property (nonatomic, assign) CGFloat lastFrameBrightness;
@property (nonatomic, assign) NSInteger burstCount;
@property (nonatomic, assign) NSInteger noActivityCount;
@property (nonatomic, assign) BOOL shouldContinueRecording;
@property (nonatomic, assign) BOOL isMonitoringActivity;

// HLS Streaming
@property (nonatomic, strong) HLSAssetWriterServer *hlsServer;
@property (nonatomic, strong) RptrDIYHLSServer *diyHLSServer; // DIY implementation
@property (nonatomic, assign) BOOL useDIYServer; // Toggle for testing
@property (nonatomic, strong) UIButton *streamButton;
@property (nonatomic, strong) UILabel *streamStatusLabel;
@property (nonatomic, assign) BOOL isStreaming;

// Quality Settings
@property (nonatomic, strong) UIButton *qualityButton;
@property (nonatomic, assign) RptrVideoQualityMode currentQualityMode;

// Title button
@property (nonatomic, strong) UIButton *titleButton;

// Share button
@property (nonatomic, strong) UIButton *shareButton;


// Streaming indicators
@property (nonatomic, strong) UIView *streamingLED;
@property (nonatomic, strong) UIView *audioLevelMeter;
@property (nonatomic, strong) NSMutableArray<UIView *> *audioLevelBars;
@property (nonatomic, assign) float currentAudioLevel;

// Feedback display
@property (nonatomic, strong) UILabel *feedbackLabel;
@property (nonatomic, strong) NSTimer *feedbackDismissTimer;
@property (nonatomic, strong) NSMutableArray<NSString *> *feedbackQueue;
@property (nonatomic, strong) dispatch_queue_t feedbackQueueLock;
@property (nonatomic, assign) BOOL isDisplayingFeedback;

// Cached icons
@property (nonatomic, strong) UIImage *cachedCopyIcon;

@end

