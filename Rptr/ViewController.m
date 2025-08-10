//
//  ViewController.m
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import "ViewController.h"
#import "PermissionManager.h"
#import "RptrLogger.h"
#import "RptrDiagnostics.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <CoreMotion/CoreMotion.h>

@interface ViewController () {
    BOOL _isLockingOrientation;
    UIDeviceOrientation _lastDeviceOrientation;
    CMMotionManager *_motionManager;
}

@end

@implementation ViewController

- (void)loadView {
    // Use default view creation
    [super loadView];
    self.view.backgroundColor = [UIColor blackColor];
    
    RLog(RptrLogAreaInfo, @"loadView - Using default view creation");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Don't force orientation update - we're locked to landscape right
    
    // Ensure view uses full screen without safe area constraints
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;
    
    // Ensure full screen presentation
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.definesPresentationContext = YES;
    
    // Disable safe area layout guides
    if (@available(iOS 11.0, *)) {
        self.additionalSafeAreaInsets = UIEdgeInsetsZero;
        self.viewRespectsSystemMinimumLayoutMargins = NO;
    }
    
    // Set the preferred content size to full screen
    self.preferredContentSize = [[UIScreen mainScreen] bounds].size;
    
    self.view.backgroundColor = [UIColor blackColor];
    
    // Initialize quality mode before any camera setup
    self.currentQualityMode = RptrVideoQualityModeReliable;
    
    // Log the initial view frame for debugging
    RLog(RptrLogAreaInfo, @"viewDidLoad - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaInfo, @"viewDidLoad - Screen bounds: %@", NSStringFromCGRect([[UIScreen mainScreen] bounds]));
    
    // Check iOS version
    if (@available(iOS 17.6, *)) {
        RLog(RptrLogAreaInfo, @"iOS version check passed: %@", [[UIDevice currentDevice] systemVersion]);
    } else {
        // Show alert for unsupported iOS version
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iOS Version Not Supported"
                                                                       message:@"This app requires iOS 17.6 or later. Please update your device."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            exit(0);
        }]];
        // Present immediately - no need for delay
        [self presentViewController:alert animated:YES completion:^{
            RLog(RptrLogAreaInfo, @"iOS version alert presented");
        }];
        return;
    }
    
    // Initialize diagnostics monitoring
    RptrDiagnostics *diagnostics = [RptrDiagnostics sharedDiagnostics];
    diagnostics.delegate = self;
    diagnostics.anrThreshold = 3.0;  // 3 seconds for streaming app
    diagnostics.memoryCheckInterval = 10.0;  // Check every 10 seconds
    [diagnostics startMonitoring];
    RLogInfo(@"Diagnostics monitoring started");
    
    // Initialize overlay queue for thread-safe pixel buffer operations
    self.overlayQueue = dispatch_queue_create("com.rptr.overlay.queue", DISPATCH_QUEUE_SERIAL);
        
        // Initialize motion manager to detect actual device orientation
        _motionManager = [[CMMotionManager alloc] init];
        _motionManager.deviceMotionUpdateInterval = 0.2; // Update 5 times per second
        _lastDeviceOrientation = UIDeviceOrientationPortrait; // Default
        
        // Start monitoring device motion to detect orientation
        if (_motionManager.isDeviceMotionAvailable) {
            [_motionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                                withHandler:^(CMDeviceMotion * _Nullable motion, NSError * _Nullable error) {
                if (!error && motion) {
                    // Calculate device orientation from gravity vector
                    CMAcceleration gravity = motion.gravity;
                    UIDeviceOrientation newOrientation = UIDeviceOrientationPortrait;
                    
                    // Determine orientation based on gravity
                    if (fabs(gravity.x) > fabs(gravity.y)) {
                        if (gravity.x > 0) {
                            newOrientation = UIDeviceOrientationLandscapeLeft;
                        } else {
                            newOrientation = UIDeviceOrientationLandscapeRight;
                        }
                    } else {
                        if (gravity.y > 0) {
                            newOrientation = UIDeviceOrientationPortraitUpsideDown;
                        } else {
                            newOrientation = UIDeviceOrientationPortrait;
                        }
                    }
                    
                    if (newOrientation != self->_lastDeviceOrientation) {
                        self->_lastDeviceOrientation = newOrientation;
                        RLogVideo(@"Device orientation changed to: %ld", (long)newOrientation);
                        
                        // Update camera connections with new rotation
                        [self updateCameraRotationForOrientation:newOrientation];
                    }
                }
            }];
        }
        
        // Preload UI components immediately in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self preloadUIComponents];
            });
        });
        
        
        // Move notification observers to background to avoid blocking startup
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(sessionWasInterrupted:)
                                                         name:AVCaptureSessionWasInterruptedNotification
                                                       object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(sessionInterruptionEnded:)
                                                         name:AVCaptureSessionInterruptionEndedNotification
                                                       object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(sessionRuntimeError:)
                                                         name:AVCaptureSessionRuntimeErrorNotification
                                                       object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(appWillTerminate:)
                                                         name:UIApplicationWillTerminateNotification
                                                       object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(appDidEnterBackground:)
                                                         name:UIApplicationDidEnterBackgroundNotification
                                                       object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(didReceiveMemoryWarning:)
                                                         name:UIApplicationDidReceiveMemoryWarningNotification
                                                       object:nil];
        });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Check permissions once view is fully visible
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self checkAndSetupIfPermissionsGranted];
    });
    
    RLog(RptrLogAreaInfo, @"viewDidAppear - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaInfo, @"viewDidAppear - Window bounds: %@", NSStringFromCGRect(self.view.window.bounds));
    
    // Check parent view controller
    if (self.parentViewController) {
        RLog(RptrLogAreaInfo, @"Parent view controller: %@", NSStringFromClass([self.parentViewController class]));
        RLog(RptrLogAreaInfo, @"Parent view frame: %@", NSStringFromCGRect(self.parentViewController.view.frame));
    }
    
    // Check if we're in a container
    if (self.navigationController) {
        RLog(RptrLogAreaInfo, @"In navigation controller");
    }
    if (self.tabBarController) {
        RLog(RptrLogAreaInfo, @"In tab bar controller");
    }
    if (self.splitViewController) {
        RLog(RptrLogAreaInfo, @"In split view controller");
    }
    
    // Log safe area insets
    if (@available(iOS 11.0, *)) {
        RLog(RptrLogAreaInfo, @"Safe area insets: %@", NSStringFromUIEdgeInsets(self.view.safeAreaInsets));
        RLog(RptrLogAreaInfo, @"Layout margins: %@", NSStringFromUIEdgeInsets(self.view.layoutMargins));
    }
    
    // If view isn't filling window, force it
    if (!CGRectEqualToRect(self.view.frame, self.view.window.bounds)) {
        RLog(RptrLogAreaInfo, @"View not filling window, forcing resize");
        self.view.frame = self.view.window.bounds;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }
    
    // Log all subviews to check hierarchy
    RLog(RptrLogAreaInfo, @"View subviews count: %lu", (unsigned long)self.view.subviews.count);
    for (UIView *subview in self.view.subviews) {
        RLog(RptrLogAreaInfo, @"Subview: %@ frame: %@", NSStringFromClass([subview class]), NSStringFromCGRect(subview.frame));
    }
    
    // Landscape orientation is already enforced by Info.plist and supported orientations
    
    // Ensure preview layer fills the view after orientation change
    if (self.previewLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.previewLayer.frame = self.view.bounds;
        [CATransaction commit];
        RLog(RptrLogAreaInfo, @"viewDidAppear - Updated preview layer frame: %@", NSStringFromCGRect(self.previewLayer.frame));
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // Just log what's happening
    RLog(RptrLogAreaInfo, @"viewDidLayoutSubviews - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaInfo, @"viewDidLayoutSubviews - View bounds: %@", NSStringFromCGRect(self.view.bounds));
    RLog(RptrLogAreaInfo, @"viewDidLayoutSubviews - View transform: %@", NSStringFromCGAffineTransform(self.view.transform));
    
    // CRITICAL: Ensure preview layer maintains landscape orientation
    if (self.previewLayer && !_isLockingOrientation) {
        _isLockingOrientation = YES;
        
        // Force the preview layer to stay in landscape orientation
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        
        // Reset any transforms that might have been applied
        self.previewLayer.affineTransform = CGAffineTransformIdentity;
        self.previewLayer.frame = self.view.bounds;
        
        // Let the motion manager handle rotation - don't set fixed values here
        
        [CATransaction commit];
        _isLockingOrientation = NO;
    }
    
    
    // Update stream button position for landscape orientation
    if (self.streamButton) {
        CGFloat streamButtonSize = 44;
        self.streamButton.frame = CGRectMake(20, self.view.frame.size.height - streamButtonSize - 50, streamButtonSize, streamButtonSize);
    }
    
    // Update endpoint labels and copy buttons
    CGFloat yOffset = 40;
    for (NSInteger i = 0; i < self.endpointLabels.count; i++) {
        UILabel *label = self.endpointLabels[i];
        UIButton *button = self.endpointCopyButtons[i];
        
        // Calculate the actual text size to preserve the width
        UIFont *urlFont = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        NSDictionary *attributes = @{NSFontAttributeName: urlFont};
        CGSize textSize = [label.text sizeWithAttributes:attributes];
        CGFloat labelWidth = textSize.width + 10;
        CGFloat labelX = self.view.frame.size.width - labelWidth - 30;
        
        label.frame = CGRectMake(labelX, yOffset, labelWidth, 22);
        button.frame = CGRectMake(self.view.frame.size.width - 25, yOffset, 20, 22);
        
        yOffset += 22;
    }
}

- (void)setupCameraPreview {
    // Initialize dictionaries for cameras
    self.captureSessions = [NSMutableDictionary dictionary];
    // No movie file outputs needed - this app only streams
    self.videoDataOutputs = [NSMutableDictionary dictionary];
    
    // Only use single camera setup
    RLog(RptrLogAreaInfo, @"Setting up single camera session");
    [self setupSingleCameraSession];
}


- (void)setupSingleCameraSession {
    
    // Get ONLY the back camera - this is a rear camera only app
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionBack];  // REAR CAMERA ONLY
    NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
    
    if (cameras.count == 0) {
        RLog(RptrLogAreaError, @"No rear camera available");
        return;
    }
    
    // Get the rear camera
    AVCaptureDevice *rearCamera = cameras.firstObject;
    RLogVideo(@"Using rear camera: %@", rearCamera.localizedName);
    
    // Set up session for rear camera only
    [self setupSessionForCamera:rearCamera];
    
    // Set current camera and session
    self.currentCameraDevice = rearCamera;
    self.captureSession = self.captureSessions[rearCamera.uniqueID];
    // No movie file output needed - streaming only
    self.videoDataOutput = self.videoDataOutputs[rearCamera.uniqueID];
    
    RLog(RptrLogAreaInfo, @"Rear camera selected: %@ (position: %ld, uniqueID: %@)", 
          rearCamera.localizedName, (long)rearCamera.position, rearCamera.uniqueID);
    
    // Defer preview layer creation to ensure proper bounds
    dispatch_async(dispatch_get_main_queue(), ^{
        // Log screen and window info
        CGRect screenBounds = [[UIScreen mainScreen] bounds];
        CGRect nativeBounds = [[UIScreen mainScreen] nativeBounds];
        CGFloat scale = [[UIScreen mainScreen] scale];
        CGFloat nativeScale = [[UIScreen mainScreen] nativeScale];
        RLog(RptrLogAreaInfo, @"Screen bounds: %@", NSStringFromCGRect(screenBounds));
        RLog(RptrLogAreaInfo, @"Native bounds: %@", NSStringFromCGRect(nativeBounds));
        RLog(RptrLogAreaInfo, @"Screen scale: %f, native scale: %f", scale, nativeScale);
        
        // Check current interface orientation using window scene (iOS 13+)
        UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            orientation = self.view.window.windowScene.interfaceOrientation;
        }
        RLogUI(@"Current interface orientation: %ld", (long)orientation);
        
        // Check if we're in zoomed display mode
        BOOL isZoomed = (screenBounds.size.width * scale != nativeBounds.size.width);
        RLog(RptrLogAreaInfo, @"Display zoomed: %@", isZoomed ? @"YES" : @"NO");
        
        // Create preview layer with current session
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer.frame = self.view.bounds;
        self.previewLayer.backgroundColor = [UIColor blackColor].CGColor;
        
        // Check the actual video dimensions
        AVCaptureInput *input = self.captureSession.inputs.firstObject;
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(deviceInput.device.activeFormat.formatDescription);
            RLog(RptrLogAreaInfo, @"Camera video dimensions: %d x %d", dimensions.width, dimensions.height);
        }
        
        // IMPORTANT: Connection might not exist yet when preview layer is first created
        // We'll set the orientation after adding the layer to the view
        RLogVideo(@"Preview layer created, will set orientation after adding to view");
        
        // Remove any existing preview layers first
        for (CALayer *layer in [self.view.layer.sublayers copy]) {
            if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
                [layer removeFromSuperlayer];
            }
        }
        
        [self.view.layer insertSublayer:self.previewLayer atIndex:0];
        
        // CRITICAL: Lock the preview layer transform to prevent automatic rotation
        // This is the key to preventing the camera from rotating with the device
        self.previewLayer.affineTransform = CGAffineTransformIdentity;
        
        // NOW set the orientation after the layer is added
        AVCaptureConnection *previewConnection = self.previewLayer.connection;
        if (previewConnection) {
            RLogVideo(@"Setting camera orientation AFTER adding preview layer");
            
            // CRITICAL: Disable ALL automatic adjustments to prevent device rotation from affecting preview
            if (previewConnection.isVideoMirroringSupported) {
                previewConnection.automaticallyAdjustsVideoMirroring = NO;
                previewConnection.videoMirrored = NO;  // Rear camera shouldn't be mirrored
            }
            
            // Disable video stabilization which can cause orientation issues
            if ([previewConnection isVideoStabilizationSupported]) {
                previewConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff;
                RLogVideo(@"Disabled video stabilization on preview connection");
            }
            
            // CRITICAL: Lock the connection to prevent any automatic rotation
            previewConnection.enabled = NO;
            previewConnection.enabled = YES;  // Re-enable after configuration
            
            // Don't set a fixed rotation here - let updateCameraRotationForOrientation handle it
            RLogVideo(@"Preview connection ready for dynamic rotation based on device orientation");
        } else {
            RLogError(@"No preview connection available after adding layer!");
        }
        
        // Force a layout update
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        
        RLog(RptrLogAreaInfo, @"Preview layer created with frame: %@", NSStringFromCGRect(self.previewLayer.frame));
        RLog(RptrLogAreaInfo, @"View layer bounds: %@", NSStringFromCGRect(self.view.layer.bounds));
        RLog(RptrLogAreaInfo, @"View layer frame: %@", NSStringFromCGRect(self.view.layer.frame));
        
        // Try setting the layer bounds explicitly
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.previewLayer.bounds = self.view.layer.bounds;
        self.previewLayer.position = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
        // Don't apply transform - use connection rotation instead
        [CATransaction commit];
        
        RLog(RptrLogAreaInfo, @"After explicit bounds set - Preview layer bounds: %@, position: %@", 
             NSStringFromCGRect(self.previewLayer.bounds), NSStringFromCGPoint(self.previewLayer.position));
    });
    
    RLog(RptrLogAreaInfo, @"Main preview layer created with session: %@", self.captureSession);
    
    
    // Add observer for session started notification
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(sessionDidStartRunning:)
                                                 name:AVCaptureSessionDidStartRunningNotification 
                                               object:self.captureSession];
    
    // Start the session for single camera
    [self.captureSession startRunning];
    
    // Initial rotation will be set when session starts via notification
}

- (void)setupSessionForCamera:(AVCaptureDevice *)camera {
    RLog(RptrLogAreaInfo, @"Setting up session for camera: %@", camera.localizedName);
    
    // Create session for this camera
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    
    // Always use high preset for capture session
    // The actual encoding resolution is handled by the HLS server
    session.sessionPreset = AVCaptureSessionPresetHigh;
    RLog(RptrLogAreaInfo, @"Using High preset for capture session");
    
    // Create video input
    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
    if (error) {
        RLog(RptrLogAreaError, @"Error creating video input for %@: %@", camera.localizedName, error.localizedDescription);
        return;
    }
    
    // Add video input to session
    if ([session canAddInput:videoInput]) {
        [session addInput:videoInput];
        
        // Configure frame rate based on quality settings
        if ([camera lockForConfiguration:&error]) {
            // Get current quality settings
            RptrVideoQualitySettings *settings = [RptrVideoQualitySettings settingsForMode:self.currentQualityMode];
            
            // Set the frame rate from quality settings
            CMTime frameDuration = CMTimeMake(1, (int32_t)settings.videoFrameRate);
            camera.activeVideoMinFrameDuration = frameDuration;
            camera.activeVideoMaxFrameDuration = frameDuration;
            
            // CRITICAL: Disable automatic adjustments that cause rotation
            // Try to disable geometric distortion correction if supported
            if (@available(iOS 13.0, *)) {
                // Just try to disable it - it will fail silently if not supported
                @try {
                    if (camera.isGeometricDistortionCorrectionEnabled) {
                        camera.geometricDistortionCorrectionEnabled = NO;
                        RLogVideo(@"Disabled geometric distortion correction");
                    }
                } @catch (NSException *exception) {
                    // Not supported on this device/format
                }
            }
            
            // Disable auto adjustments
            if ([camera isAutoFocusRangeRestrictionSupported]) {
                camera.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNone;
            }
            
            // Disable low light boost which can affect orientation
            if (camera.isLowLightBoostSupported) {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = NO;
                RLogVideo(@"Disabled automatic low light boost");
            }
            
            [camera unlockForConfiguration];
            RLog(RptrLogAreaInfo, @"Set frame rate to %ld fps for %@ (quality mode: %@)", 
                 (long)settings.videoFrameRate, camera.localizedName, 
                 self.currentQualityMode == RptrVideoQualityModeReliable ? @"Reliable" : @"Real-time");
        } else {
            RLog(RptrLogAreaError, @"Could not lock camera for configuration: %@", error.localizedDescription);
        }
    } else {
        RLog(RptrLogAreaError, @"Cannot add video input to session for %@", camera.localizedName);
        return;
    }
    
    // Add audio input for rear camera streaming
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioInput = nil;
    if (audioDevice) {
        audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
        if (error) {
            RLog(RptrLogAreaError, @"Error creating audio input: %@", error.localizedDescription);
            error = nil;
        }
    }
    
    if (audioInput && [session canAddInput:audioInput]) {
        [session addInput:audioInput];
        RLog(RptrLogAreaInfo, @"Added audio input to rear camera session");
    }
    
    // No movie file output needed - this app only streams, never records
    
    // Add video data output for motion/light detection and streaming
    AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    dataOutput.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    dataOutput.alwaysDiscardsLateVideoFrames = NO; // Keep all frames for smooth streaming
    
    // Create separate queue for each camera with safe name
    NSString *safeCameraName = [[camera.localizedName stringByReplacingOccurrencesOfString:@" " withString:@"_"] 
                                stringByReplacingOccurrencesOfString:@"'" withString:@""];
    NSString *queueName = [NSString stringWithFormat:@"videoQueue_%@", safeCameraName];
    dispatch_queue_t videoQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
    [dataOutput setSampleBufferDelegate:self queue:videoQueue];
    
    if ([session canAddOutput:dataOutput]) {
        [session addOutput:dataOutput];
        RLog(RptrLogAreaInfo, @"Video data output added for %@", camera.localizedName);
        
        // Set landscape orientation for rear camera streaming
        AVCaptureConnection *videoConnection = [dataOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConnection) {
            // CRITICAL: Disable automatic adjustments
            if (videoConnection.isVideoMirroringSupported) {
                videoConnection.automaticallyAdjustsVideoMirroring = NO;
                videoConnection.videoMirrored = NO;  // Rear camera shouldn't be mirrored
                RLogVideo(@"Disabled automatic video mirroring adjustments");
            }
            
            // Don't set a fixed rotation here - let updateCameraRotationForOrientation handle it
            RLogVideo(@"Video output connection ready for dynamic rotation based on device orientation");
        }
    }
    
    // Store in dictionaries
    self.captureSessions[camera.uniqueID] = session;
    // No movie file output storage needed
    self.videoDataOutputs[camera.uniqueID] = dataOutput;
    
    // Initialize detection properties (do this once in main setup)
    if (!self.ciContext) {
        self.ciContext = [CIContext contextWithOptions:nil];
        self.recentFrameBrightness = [NSMutableArray array];
        self.cameraActivityScores = [NSMutableDictionary dictionary];
        self.cameraSwitchTimestamps = [NSMutableDictionary dictionary];
        self.noActivityCount = 0;
        self.videoQueue = dispatch_queue_create("mainVideoQueue", DISPATCH_QUEUE_SERIAL);
    }
}

- (void)setupUI {
    // Initialize arrays for endpoint labels and copy buttons
    self.endpointLabels = [NSMutableArray array];
    self.endpointCopyButtons = [NSMutableArray array];
    
    // Initialize and start HLS server (not streaming yet)
    // Toggle this to test DIY implementation
    self.useDIYServer = YES; // SET TO YES TO TEST DIY SERVER
    
    if (self.useDIYServer) {
        // DIY HLS Server (NEW IMPLEMENTATION)
        RLog(RptrLogAreaProtocol, @"Initializing DIY HLS server on app launch");
        
        RptrVideoQualitySettings *settings = [RptrVideoQualitySettings settingsForMode:self.currentQualityMode];
        
        self.diyHLSServer = [[RptrDIYHLSServer alloc] 
            initWithWidth:settings.videoWidth
                   height:settings.videoHeight
                frameRate:settings.videoFrameRate
                  bitrate:settings.videoBitrate];
        
        self.diyHLSServer.delegate = self;
        self.diyHLSServer.segmentDuration = settings.segmentDuration;
        self.diyHLSServer.playlistWindowSize = 10;
        
        BOOL started = [self.diyHLSServer startServerOnPort:8080];
        if (started) {
            RLog(RptrLogAreaProtocol, @"DIY HLS server started successfully on port 8080");
            RLog(RptrLogAreaProtocol, @"DIY Playlist URL: %@", self.diyHLSServer.playlistURL);
            
            // Display streaming URLs in UI
            [self displayDIYStreamingURLs];
            
            // AUTO-START STREAMING FOR AUTOMATED TESTING
            // This allows Claude to test without manual button press
            #ifdef DEBUG
            BOOL autoStartEnabled = YES; // Set to YES for automated testing
            if (autoStartEnabled) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    RLog(RptrLogAreaProtocol, @"[AUTO-START] Automatically starting streaming for debug testing");
                    if (!self.isStreaming) {
                        [self startStreaming];
                    }
                });
            }
            #endif
            
            // The server will call hlsServerDidStart delegate method automatically
            // Don't call it manually here to avoid duplicate calls
        } else {
            RLog(RptrLogAreaError, @"Failed to start DIY HLS server");
        }
    } else {
        // Original HLS Server (FALLBACK)
        if (!self.hlsServer) {
            RLog(RptrLogAreaProtocol, @"Initializing original HLS server on app launch");
            self.hlsServer = [[HLSAssetWriterServer alloc] initWithPort:8080];
            self.hlsServer.delegate = self;
            
            // Set initial quality settings
            RptrVideoQualitySettings *settings = [RptrVideoQualitySettings settingsForMode:self.currentQualityMode];
            self.hlsServer.qualitySettings = settings;
            
            NSError *error = nil;
            BOOL started = [self.hlsServer startServer:&error];
            if (started) {
                RLog(RptrLogAreaProtocol, @"Original HLS server started successfully on port 8080");
            } else {
                RLog(RptrLogAreaError, @"Failed to start original HLS server: %@", error);
            }
        }
    }
    
    // Streaming LED indicator
    self.streamingLED = [[UIView alloc] initWithFrame:CGRectMake(20, 40, 12, 12)];
    self.streamingLED.backgroundColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0]; // Gray when off
    self.streamingLED.layer.cornerRadius = 6;
    self.streamingLED.layer.borderWidth = 1;
    self.streamingLED.layer.borderColor = [[UIColor colorWithWhite:0.3 alpha:1.0] CGColor];
    self.streamingLED.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.streamingLED];
    
    
    // Feedback display label (lower right corner)
    CGFloat feedbackWidth = 300;
    CGFloat feedbackHeight = 60;
    CGFloat feedbackPadding = 20;
    self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectMake(
        self.view.frame.size.width - feedbackWidth - feedbackPadding,
        self.view.frame.size.height - feedbackHeight - feedbackPadding,
        feedbackWidth,
        feedbackHeight
    )];
    self.feedbackLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    self.feedbackLabel.textColor = [UIColor whiteColor];
    self.feedbackLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.feedbackLabel.textAlignment = NSTextAlignmentCenter;
    self.feedbackLabel.numberOfLines = 2;
    self.feedbackLabel.layer.cornerRadius = 8;
    self.feedbackLabel.layer.masksToBounds = YES;
    self.feedbackLabel.layer.borderWidth = 1;
    self.feedbackLabel.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.3] CGColor];
    self.feedbackLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.feedbackLabel.hidden = YES;
    [self.view addSubview:self.feedbackLabel];
    
    // Initialize feedback queue with thread safety
    self.feedbackQueue = [NSMutableArray array];
    self.feedbackQueueLock = dispatch_queue_create("com.rptr.feedback.queue", DISPATCH_QUEUE_SERIAL);
    self.isDisplayingFeedback = NO;
    
    // Start UTC timer
    
    // Setup location manager
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    
    // Request location permission
    CLAuthorizationStatus locationStatus = self.locationManager.authorizationStatus;
    if (locationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    } else if (locationStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
               locationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager startUpdatingLocation];
    }
    
    // Setup location update timer to request location every 10 seconds
    self.locationUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 
                                                              target:self 
                                                            selector:@selector(requestLocationUpdate) 
                                                            userInfo:nil 
                                                             repeats:YES];
    
    // Stream button
    CGFloat streamButtonSize = 44;
    self.streamButton = [[UIButton alloc] initWithFrame:CGRectMake(20, self.view.frame.size.height - streamButtonSize - 50, streamButtonSize, streamButtonSize)];
    self.streamButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
    self.streamButton.layer.cornerRadius = streamButtonSize / 2;
    [self.streamButton setImage:[self broadcastIcon] forState:UIControlStateNormal];
    self.streamButton.tintColor = [UIColor whiteColor];
    [self.streamButton addTarget:self action:@selector(streamButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.streamButton];
    
}





#pragma mark - App Lifecycle

- (void)appWillTerminate:(NSNotification *)notification {
    RLog(RptrLogAreaProtocol, @"App will terminate - stopping HLS server gracefully");
    
    // Stop streaming first
    if (self.isStreaming) {
        [self stopStreaming];
    }
    
    // Stop the HLS server
    if (self.hlsServer) {
        [self.hlsServer stopServer];
        RLog(RptrLogAreaProtocol, @"HLS server stopped");
    }
    
    // Stop location updates
    if (self.locationManager) {
        [self.locationManager stopUpdatingLocation];
    }
    
    // Stop capture sessions
    for (NSString *cameraID in self.captureSessions) {
        AVCaptureSession *session = self.captureSessions[cameraID];
        if (session.isRunning) {
            [session stopRunning];
        }
    }
    
    RLog(RptrLogAreaProtocol, @"App termination cleanup completed");
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    RLog(RptrLogAreaInfo, @"Received memory warning in ViewController");
    
    // Clear any cached CIContext
    if (self.ciContext) {
        self.ciContext = nil;
        RLog(RptrLogAreaInfo, @"Cleared CIContext");
    }
    
    // Clear activity scores to free memory
    [self.cameraActivityScores removeAllObjects];
    
    // If not currently streaming, clear more aggressively
    if (!self.isStreaming) {
        // Clear preview layer to free GPU memory
        if (self.previewLayer) {
            [self.previewLayer removeFromSuperlayer];
            self.previewLayer = nil;
            RLog(RptrLogAreaInfo, @"Removed preview layer to free GPU memory");
        }
    }
    
    // Force garbage collection of any autorelease pools
    @autoreleasepool {
        // This forces the pool to drain
    }
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    RLog(RptrLogAreaProtocol, @"App entered background - pausing streaming");
    
    // Keep server running but pause streaming to save resources
    if (self.isStreaming) {
        // Don't call stopStreaming as that would affect UI state
        // Just pause the capture sessions
        for (NSString *cameraID in self.captureSessions) {
            AVCaptureSession *session = self.captureSessions[cameraID];
            if (session.isRunning) {
                [session stopRunning];
            }
        }
    }
}

- (void)dealloc {
    // Stop streaming immediately to prevent processing more frames
    self.isStreaming = NO;
    
    // Remove all capture delegates to prevent callbacks during dealloc
    for (AVCaptureVideoDataOutput *output in self.videoDataOutputs.allValues) {
        [output setSampleBufferDelegate:nil queue:nil];
    }
    
    // Remove all observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Stop motion manager
    if (_motionManager) {
        [_motionManager stopDeviceMotionUpdates];
        _motionManager = nil;
    }
    
    // Stop HLS server
    if (self.hlsServer) {
        [self.hlsServer stopServer];
    }
    
    // Stop all capture sessions
    for (AVCaptureSession *session in self.captureSessions.allValues) {
        if (session.isRunning) {
            [session stopRunning];
        }
    }
    
    // Invalidate timers
    [self.cameraEvaluationTimer invalidate];
    [self.locationUpdateTimer invalidate];
    
    // Stop location updates
    [self.locationManager stopUpdatingLocation];
    
    // Clean up notifications
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

#pragma mark - Camera Selection


- (UIImage *)broadcastIcon {
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    
    // Draw broadcast waves
    CGPoint center = CGPointMake(15, 20);
    
    // Draw transmitter dot
    UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(13, 18, 4, 4)];
    [[UIColor whiteColor] setFill];
    [dot fill];
    
    // Draw broadcast waves
    [[UIColor whiteColor] setStroke];
    
    // Small wave
    UIBezierPath *wave1 = [UIBezierPath bezierPathWithArcCenter:center
                                                         radius:6
                                                     startAngle:-M_PI_4
                                                       endAngle:-3*M_PI_4
                                                      clockwise:NO];
    wave1.lineWidth = 1.5;
    [wave1 stroke];
    
    // Medium wave
    UIBezierPath *wave2 = [UIBezierPath bezierPathWithArcCenter:center
                                                         radius:10
                                                     startAngle:-M_PI_4
                                                       endAngle:-3*M_PI_4
                                                      clockwise:NO];
    wave2.lineWidth = 1.5;
    [wave2 stroke];
    
    // Large wave
    UIBezierPath *wave3 = [UIBezierPath bezierPathWithArcCenter:center
                                                         radius:14
                                                     startAngle:-M_PI_4
                                                       endAngle:-3*M_PI_4
                                                      clockwise:NO];
    wave3.lineWidth = 1.5;
    [wave3 stroke];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return image;
}

- (UIImage *)overlayIcon {
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    
    [[UIColor whiteColor] setStroke];
    [[UIColor whiteColor] setFill];
    
    // Draw text overlay icon (simplified representation)
    // Rectangle representing video frame
    UIBezierPath *frame = [UIBezierPath bezierPathWithRect:CGRectMake(5, 8, 20, 14)];
    frame.lineWidth = 1.5;
    [frame stroke];
    
    // Text lines inside frame
    UIBezierPath *line1 = [UIBezierPath bezierPath];
    [line1 moveToPoint:CGPointMake(8, 12)];
    [line1 addLineToPoint:CGPointMake(22, 12)];
    line1.lineWidth = 1.0;
    [line1 stroke];
    
    UIBezierPath *line2 = [UIBezierPath bezierPath];
    [line2 moveToPoint:CGPointMake(8, 15)];
    [line2 addLineToPoint:CGPointMake(18, 15)];
    line2.lineWidth = 1.0;
    [line2 stroke];
    
    UIBezierPath *line3 = [UIBezierPath bezierPath];
    [line3 moveToPoint:CGPointMake(8, 18)];
    [line3 addLineToPoint:CGPointMake(20, 18)];
    line3.lineWidth = 1.0;
    [line3 stroke];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return image;
}

- (UIImage *)copyIcon {
    // Cache the icon to avoid recreating it
    if (self.cachedCopyIcon) {
        return self.cachedCopyIcon;
    }
    
    CGSize size = CGSizeMake(16, 16);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    
    [[UIColor whiteColor] setStroke];
    
    // Draw front document
    UIBezierPath *frontDoc = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 5, 9, 10)
                                                        cornerRadius:1];
    frontDoc.lineWidth = 1.0;
    [frontDoc stroke];
    
    // Draw back document
    UIBezierPath *backDoc = [UIBezierPath bezierPath];
    [backDoc moveToPoint:CGPointMake(11, 3)];
    [backDoc addLineToPoint:CGPointMake(11, 1)];
    [backDoc addCurveToPoint:CGPointMake(10, 0) controlPoint1:CGPointMake(11, 0.5) controlPoint2:CGPointMake(10.5, 0)];
    [backDoc addLineToPoint:CGPointMake(3, 0)];
    [backDoc addCurveToPoint:CGPointMake(2, 1) controlPoint1:CGPointMake(2.5, 0) controlPoint2:CGPointMake(2, 0.5)];
    [backDoc addLineToPoint:CGPointMake(2, 10)];
    [backDoc addCurveToPoint:CGPointMake(3, 11) controlPoint1:CGPointMake(2, 10.5) controlPoint2:CGPointMake(2.5, 11)];
    [backDoc addLineToPoint:CGPointMake(4, 11)];
    backDoc.lineWidth = 1.0;
    [backDoc stroke];
    
    UIImage *image2 = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    // Cache the icon
    self.cachedCopyIcon = image2;
    
    return image2;
}

- (void)copyButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < self.endpointLabels.count) {
        UILabel *label = self.endpointLabels[index];
        NSString *url = label.text;
        
        [[UIPasteboard generalPasteboard] setString:url];
        
        // Flash the button to indicate copy using animation completion
        UIColor *originalColor = sender.backgroundColor;
        [UIView animateWithDuration:0.1 
                              delay:0 
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            sender.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.6];
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.1 animations:^{
                sender.backgroundColor = originalColor;
            }];
        }];
    }
}

- (void)streamButtonTapped:(UIButton *)sender {
    @try {
        if (self.isStreaming) {
            [self stopStreaming];
        } else {
            [self startStreaming];
        }
    } @catch (NSException *exception) {
        RLog(RptrLogAreaError, @"Exception in streamButtonTapped: %@", exception);
        RLog(RptrLogAreaError, @"Stack trace: %@", exception.callStackSymbols);
        // Try to recover
        self.isStreaming = NO;
        [self stopStreaming];
    }
}


- (void)preloadUIComponents {
    // Only preload if we haven't already
    static BOOL keyboardPreloaded = NO;
    if (keyboardPreloaded) {
        return;
    }
    
    RLog(RptrLogAreaInfo, @"Starting keyboard and alert controller preload...");
    
    // First, preload UIAlertController with text field
    UIAlertController *dummyAlert = [UIAlertController alertControllerWithTitle:@""
                                                                        message:@""
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    
    // Add a text field to force loading of all alert controller resources
    [dummyAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    
    // Add dummy action to fully initialize the alert
    [dummyAlert addAction:[UIAlertAction actionWithTitle:@"" style:UIAlertActionStyleDefault handler:nil]];
    
    // Create the alert view hierarchy without presenting it
    UIView *dummyView = dummyAlert.view;
    dummyView.alpha = 0;
    
    // Now create a hidden text field to preload the keyboard
    UITextField *dummyTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, -200, 1, 1)];
    dummyTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    dummyTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    dummyTextField.hidden = YES;
    dummyTextField.alpha = 0;
    [self.view addSubview:dummyTextField];
    
    // Disable animations to make it less visible
    [UIView setAnimationsEnabled:NO];
    
    // Trigger keyboard load
    [dummyTextField becomeFirstResponder];
    
    // Use main queue async instead of timer - executes on next run loop
    dispatch_async(dispatch_get_main_queue(), ^{
        [dummyTextField resignFirstResponder];
        [dummyTextField removeFromSuperview];
        
        // Re-enable animations
        [UIView setAnimationsEnabled:YES];
        
        keyboardPreloaded = YES;
        RLog(RptrLogAreaInfo, @"Keyboard and alert controller preloaded successfully");
    });
}



- (void)startStreaming {
    RLog(RptrLogAreaProtocol, @"startStreaming called");
    
    // Server should already be running from app launch
    if (self.useDIYServer) {
        if (!self.diyHLSServer) {
            RLog(RptrLogAreaError, @"DIY HLS server not initialized");
            return;
        }
        // DIY server doesn't need prepareForStreaming
    } else {
        if (!self.hlsServer) {
            RLog(RptrLogAreaError, @"HLS server not initialized");
            return;
        }
        // Prepare the asset writer for streaming (needed after URL regeneration)
        [self.hlsServer prepareForStreaming];
    }
    
    // Start streaming based on server type
    if (self.useDIYServer) {
        // Start DIY HLS streaming
        if ([self.diyHLSServer startStreaming]) {
            RLog(RptrLogAreaProtocol, @"DIY HLS streaming started");
            self.isStreaming = YES;
            
            // Display streaming URLs
            [self displayDIYStreamingURLs];
        } else {
            RLog(RptrLogAreaError, @"Failed to start DIY HLS streaming");
            return;
        }
    } else {
        // Original server - just set the flag
        self.isStreaming = YES;
        RLog(RptrLogAreaProtocol, @"Original HLS streaming started (server already running)");
    }
    
    self.streamButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.8];
    
    // Update LED to green
    self.streamingLED.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0];
    
    // Debug: Verify video data output is ready
    RLog(RptrLogAreaProtocol, @"============ STREAMING STARTED ============");
    RLog(RptrLogAreaProtocol, @"self.videoDataOutput: %@", self.videoDataOutput);
    RLog(RptrLogAreaProtocol, @"Delegate: %@", self.videoDataOutput.sampleBufferDelegate);
    RLog(RptrLogAreaProtocol, @"isStreaming: %@", self.isStreaming ? @"YES" : @"NO");
    
    
    // Check all video data outputs
    RLog(RptrLogAreaProtocol, @"Checking all video data outputs:");
    for (NSString *cameraID in self.videoDataOutputs) {
        AVCaptureVideoDataOutput *output = self.videoDataOutputs[cameraID];
            RLog(RptrLogAreaProtocol, @"  Camera %@: Output=%@, Delegate=%@", 
                  cameraID, output, output.sampleBufferDelegate);
            
            // Check connection
            AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
            RLog(RptrLogAreaProtocol, @"  Connection: %@, Active: %@, Enabled: %@",
                  connection, 
                  connection.isActive ? @"YES" : @"NO",
                  connection.isEnabled ? @"YES" : @"NO");
        }
        
        // Check current capture session
        RLog(RptrLogAreaProtocol, @"Current capture session: %@", self.captureSession);
        RLog(RptrLogAreaProtocol, @"Session running: %@", self.captureSession.isRunning ? @"YES" : @"NO");
        RLog(RptrLogAreaProtocol, @"========================================");
        
        // Add pulsing animation
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        animation.duration = 1.0;
        animation.repeatCount = HUGE_VALF;
        animation.autoreverses = YES;
        animation.fromValue = @0.8;
        animation.toValue = @0.3;
        [self.streamButton.layer addAnimation:animation forKey:@"pulse"];
        
        RLog(RptrLogAreaProtocol, @"HLS streaming started on port %lu", (unsigned long)self.hlsServer.port);
        
        // Log network interface being used
        NSString *cellularIP = [self getCellularIPAddress];
        NSString *wifiIP = [self getWiFiIPAddress];
        RLog(RptrLogAreaProtocol, @"Available interfaces - Cellular: %@, WiFi: %@", 
              cellularIP ?: @"Not available", 
              wifiIP ?: @"Not available");
}

- (void)stopStreaming {
    // Stop streaming based on server type
    if (self.useDIYServer) {
        [self.diyHLSServer stopStreaming];
        RLog(RptrLogAreaProtocol, @"DIY HLS streaming stopped");
    }
    
    // Stop streaming flag to prevent new frames being sent
    self.isStreaming = NO;
    
    // Update UI
    self.streamButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
    [self.streamButton.layer removeAnimationForKey:@"pulse"];
    
    // Update LED to gray
    self.streamingLED.backgroundColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0];
    
    // Clear feedback display and queue
    [self clearFeedbackDisplay];
    
    // Tell HLS server to stop asset writer (but keep HTTP server running)
    if (self.hlsServer) {
        [self.hlsServer stopStreaming];
    }
    
    RLog(RptrLogAreaProtocol, @"HLS streaming stopped (server still running)");
}

- (void)updateStreamingURLs {
    // Call the delegate method to refresh the displayed URLs
    if (self.hlsServer) {
        NSArray *urls = [self.hlsServer getServerURLs];
        if (urls.count > 0) {
            [self hlsServerDidStart:urls.firstObject];
        }
    }
}

#pragma mark - HLSAssetWriterServerDelegate

- (void)hlsServerDidStart:(NSString *)baseURL {
    // Diagnostic: Track UI update timing
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    RLog(RptrLogAreaProtocol, @"hlsServerDidStart BEGIN on thread: %@", [NSThread isMainThread] ? @"main" : @"background");
    
    // This should now always be called on main queue
    if (![NSThread isMainThread]) {
        RLog(RptrLogAreaError, @"WARNING: hlsServerDidStart called on background thread!");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hlsServerDidStart:baseURL];
        });
        return;
    }
    
    NSArray *urls = [self.hlsServer getServerURLs];
    RLog(RptrLogAreaProtocol, @"Got %lu URLs", (unsigned long)urls.count);
    
    // Remove old endpoint labels and buttons
    RLog(RptrLogAreaProtocol, @"Removing old labels...");
    for (UILabel *label in self.endpointLabels) {
        [label removeFromSuperview];
    }
    for (UIButton *button in self.endpointCopyButtons) {
        [button removeFromSuperview];
    }
    [self.endpointLabels removeAllObjects];
    [self.endpointCopyButtons removeAllObjects];
    RLog(RptrLogAreaProtocol, @"Old labels removed");
    
    // Simplified URL display - just show http://ip:port
    CGFloat yOffset = 40;
    
    RLog(RptrLogAreaProtocol, @"Creating labels for %lu URLs", (unsigned long)urls.count);
    for (NSString *urlString in urls) {
        RLog(RptrLogAreaProtocol, @"Processing URL: %@", urlString);
        // Extract base URL (IP and port)
        NSURL *url = [NSURL URLWithString:urlString];
        NSString *baseURL = [NSString stringWithFormat:@"%@://%@:%@", 
                            url.scheme ?: @"http",
                            url.host ?: @"localhost",
                            url.port ?: @(self.hlsServer.port)];
        
        // Just show the base URL
        NSString *fullURL = baseURL;
        
        // Calculate the actual text size
        UIFont *urlFont = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        NSDictionary *attributes = @{NSFontAttributeName: urlFont};
        CGSize textSize = [fullURL sizeWithAttributes:attributes];
        
        // Add some padding to the width
        CGFloat labelWidth = textSize.width + 10;
        CGFloat labelX = self.view.frame.size.width - labelWidth - 30; // 30 for copy button
        
        // Create label with calculated width
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelX, yOffset, labelWidth, 22)];
        label.text = fullURL;
        label.textColor = [UIColor whiteColor];
        label.font = urlFont;
        label.textAlignment = NSTextAlignmentRight;
        label.adjustsFontSizeToFitWidth = NO;  // Don't shrink font
        label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self.view addSubview:label];
        [self.endpointLabels addObject:label];
        
        // Create copy button
        UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeCustom];
        copyButton.frame = CGRectMake(self.view.frame.size.width - 25, yOffset, 20, 22);
        
        // Use system image instead of custom drawing to avoid ANR
        if (@available(iOS 13.0, *)) {
            UIImage *copyImage = [UIImage systemImageNamed:@"doc.on.doc"];
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
            copyImage = [copyImage imageByApplyingSymbolConfiguration:config];
            [copyButton setImage:copyImage forState:UIControlStateNormal];
        } else {
            // Fallback for older iOS versions
            [copyButton setImage:[self copyIcon] forState:UIControlStateNormal];
        }
        copyButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
        copyButton.layer.cornerRadius = 4;
        copyButton.tag = self.endpointLabels.count - 1;
        [copyButton addTarget:self action:@selector(copyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        copyButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self.view addSubview:copyButton];
        [self.endpointCopyButtons addObject:copyButton];
        
        yOffset += 22;
        
        // Only show first URL's endpoints
        break;
    }
    
    
    // Log the URLs but don't show alert - it might be blocking
    RLog(RptrLogAreaProtocol, @"Stream started - URLs:");
    for (NSString *url in urls) {
        RLog(RptrLogAreaProtocol, @"  %@", url);
    }
        
    // Diagnostic: Log total UI update time
    CFAbsoluteTime totalTime = CFAbsoluteTimeGetCurrent() - startTime;
    if (totalTime > 0.1) {
        RLog(RptrLogAreaError, @"WARNING: hlsServerDidStart UI update took %.3fs (potential ANR)", totalTime);
    }
    RLog(RptrLogAreaProtocol, @"hlsServerDidStart END");
}

- (NSDictionary *)hlsServerRequestsLocation:(id)server {
    if (self.currentLocation) {
        return @{
            @"latitude": @(self.currentLocation.coordinate.latitude),
            @"longitude": @(self.currentLocation.coordinate.longitude),
            @"timestamp": @(self.currentLocation.timestamp.timeIntervalSince1970),
            @"accuracy": @(self.currentLocation.horizontalAccuracy)
        };
    } else {
        return @{}; // Return empty dictionary instead of nil
    }
}

- (void)hlsServerDidStop {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        // Remove endpoint labels and buttons
        for (UILabel *label in self.endpointLabels) {
            [label removeFromSuperview];
        }
        for (UIButton *button in self.endpointCopyButtons) {
            [button removeFromSuperview];
        }
        [self.endpointLabels removeAllObjects];
        [self.endpointCopyButtons removeAllObjects];
    });
}

- (void)hlsServer:(id)server clientConnected:(NSString *)clientAddress {
    dispatch_async(dispatch_get_main_queue(), ^{
        RLog(RptrLogAreaProtocol, @"Client connected: %@", clientAddress);
        
    });
}

- (void)hlsServer:(id)server clientDisconnected:(NSString *)clientAddress {
    dispatch_async(dispatch_get_main_queue(), ^{
        RLog(RptrLogAreaProtocol, @"Client disconnected: %@", clientAddress);
        
    });
}

- (void)hlsServer:(id)server didEncounterError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        [self stopStreaming];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"HLS Streaming Error"
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}



- (void)displayDIYStreamingURLs {
    // Get network interfaces
    NSMutableArray *urls = [NSMutableArray array];
    
    // Get primary IP address
    NSString *ipAddress = [self getIPAddress];
    if (ipAddress && ![ipAddress isEqualToString:@"error"]) {
        // Show simplified URL - just IP and port
        NSString *url = [NSString stringWithFormat:@"http://%@:8080", ipAddress];
        [urls addObject:url];
        RLogDIY(@"Streaming URL: http://%@:8080/view/%@", ipAddress, self.diyHLSServer.randomPath);
    } else {
        // Fallback to localhost
        NSString *url = @"http://localhost:8080";
        [urls addObject:url];
        RLogDIY(@"Using localhost URL (no network IP found): http://localhost:8080/view/%@", self.diyHLSServer.randomPath);
    }
    
    // Clear existing endpoint labels
    for (UILabel *label in self.endpointLabels) {
        [label removeFromSuperview];
    }
    [self.endpointLabels removeAllObjects];
    
    for (UIButton *button in self.endpointCopyButtons) {
        [button removeFromSuperview];
    }
    [self.endpointCopyButtons removeAllObjects];
    
    // Display URLs in UI
    CGFloat yOffset = 60;
    CGFloat labelHeight = 25;
    
    for (NSString *url in urls) {
        // Create endpoint label
        UILabel *endpointLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, self.view.bounds.size.width - 80, labelHeight)];
        endpointLabel.text = url;
        endpointLabel.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0];
        endpointLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        endpointLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
        endpointLabel.textAlignment = NSTextAlignmentLeft;
        endpointLabel.layer.cornerRadius = 5;
        endpointLabel.clipsToBounds = YES;
        endpointLabel.userInteractionEnabled = YES;
        endpointLabel.adjustsFontSizeToFitWidth = YES;
        endpointLabel.minimumScaleFactor = 0.5;
        
        // Add padding
        endpointLabel.text = [NSString stringWithFormat:@" %@", url];
        
        [self.view addSubview:endpointLabel];
        [self.endpointLabels addObject:endpointLabel];
        
        // Create copy button
        UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
        copyButton.frame = CGRectMake(self.view.bounds.size.width - 55, yOffset, 50, labelHeight);
        [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
        copyButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [copyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        copyButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
        copyButton.layer.cornerRadius = 5;
        copyButton.tag = self.endpointLabels.count - 1;
        [copyButton addTarget:self action:@selector(copyEndpoint:) forControlEvents:UIControlEventTouchUpInside];
        
        [self.view addSubview:copyButton];
        [self.endpointCopyButtons addObject:copyButton];
        
        yOffset += labelHeight + 5;
        
        // Only show first URL's endpoints
        break;
    }
    
    
    // Log the URLs
    RLogDIY(@"DIY HLS Stream URLs:");
    for (NSString *url in urls) {
        RLogDIY(@"  %@", url);
    }
}

// Override interface orientation methods for landscape-only app
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight; // Lock to single orientation
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)shouldAutorotate {
    return NO; // Prevent any rotation
}
#pragma clang diagnostic pop

// Override motion handling to prevent any orientation changes
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    // Do NOT call super - we don't want any size transitions
    // This prevents the system from trying to adjust our view for orientation changes
    RLogUI(@"Blocking view transition to size: %@", NSStringFromCGSize(size));
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    
    // Force landscape dimensions regardless of device orientation
    if (self.view.frame.size.width < self.view.frame.size.height) {
        // We're in portrait mode but should be landscape
        CGFloat temp = self.view.frame.size.width;
        self.view.frame = CGRectMake(0, 0, self.view.frame.size.height, temp);
        RLogUI(@"Forced landscape dimensions in viewWillLayoutSubviews");
    }
}

// Override to prevent any automatic view adjustments based on orientation
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    // Log but don't make adjustments based on safe area
    RLogUI(@"Safe area insets changed but ignoring for full-screen experience");
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

// Override to fix UIAlertController performance issues
// This helps prevent the ~700ms delay when presenting/dismissing alerts
- (BOOL)canBecomeFirstResponder {
    return YES;
}


#pragma mark - Video Processing

- (void)addTextOverlayToVideo:(NSURL *)inputURL completion:(void(^)(NSURL *))completion {
    AVAsset *asset = [AVAsset assetWithURL:inputURL];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    if (!videoTrack) {
        completion(nil);
        return;
    }
    
    // Create composition
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:videoTrack atTime:kCMTimeZero error:nil];
    
    // Add audio track if available
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (audioTrack) {
        AVMutableCompositionTrack *compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:audioTrack atTime:kCMTimeZero error:nil];
    }
    
    // Get the video orientation
    CGAffineTransform transform = videoTrack.preferredTransform;
    CGSize naturalSize = videoTrack.naturalSize;
    CGSize renderSize;
    
    // Determine if video is rotated
    if (transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0) {
        // Portrait
        renderSize = CGSizeMake(naturalSize.height, naturalSize.width);
    } else if (transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0) {
        // Portrait upside down
        renderSize = CGSizeMake(naturalSize.height, naturalSize.width);
    } else if (transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0) {
        // Landscape left
        renderSize = naturalSize;
    } else {
        // Landscape right or no rotation
        renderSize = naturalSize;
    }
    
    // Create video composition
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.renderSize = renderSize;
    videoComposition.frameDuration = CMTimeMake(1, 30);
    
    // Create text layer
    CALayer *parentLayer = [CALayer layer];
    CALayer *videoLayer = [CALayer layer];
    parentLayer.frame = CGRectMake(0, 0, renderSize.width, renderSize.height);
    videoLayer.frame = CGRectMake(0, 0, renderSize.width, renderSize.height);
    [parentLayer addSublayer:videoLayer];
    
    // Get overlay text
    // Get clean location text without label prefix
    NSString *locationText = @"Loc: --";
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"dd-MM-yy HH:mm:ss";
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    NSString *timeText = [NSString stringWithFormat:@"%@ UTC", [formatter stringFromDate:[NSDate date]]];
    
    // Create text layers
    CGFloat fontSize = renderSize.height * 0.018; // 1.8% of video height (smaller font)
    CGFloat yOffset = renderSize.height * 0.03; // Start closer to top
    CGFloat textWidth = renderSize.width * 0.4; // 40% of video width for text
    CGFloat xOffset = renderSize.width - 20; // 20 pixels from right edge
    
    NSArray *texts = @[locationText, timeText];
    for (NSInteger i = 0; i < texts.count; i++) {
        CATextLayer *textLayer = [CATextLayer layer];
        textLayer.string = texts[i];
        textLayer.font = (__bridge CFTypeRef)@"Helvetica-Bold";
        textLayer.fontSize = fontSize;
        textLayer.foregroundColor = [UIColor whiteColor].CGColor;
        textLayer.backgroundColor = [UIColor clearColor].CGColor;
        // Add shadow for better readability
        textLayer.shadowColor = [UIColor blackColor].CGColor;
        textLayer.shadowOffset = CGSizeMake(1, 1);
        textLayer.shadowOpacity = 0.8;
        textLayer.shadowRadius = 2.0;
        textLayer.alignmentMode = kCAAlignmentRight;
        textLayer.frame = CGRectMake(xOffset - textWidth, yOffset + (i * fontSize * 1.5), textWidth, fontSize * 1.4);
        textLayer.contentsScale = [[UIScreen mainScreen] scale];
        [parentLayer addSublayer:textLayer];
    }
    
    // Create video composition instruction
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTrack];
    
    // Apply the original transform to maintain orientation
    [layerInstruction setTransform:videoTrack.preferredTransform atTime:kCMTimeZero];
    
    instruction.layerInstructions = @[layerInstruction];
    videoComposition.instructions = @[instruction];
    videoComposition.animationTool = [AVVideoCompositionCoreAnimationTool videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayer:videoLayer inLayer:parentLayer];
    
    // Export
    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mov"]];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
    exportSession.videoComposition = videoComposition;
    exportSession.outputURL = outputURL;
    exportSession.outputFileType = AVFileTypeQuickTimeMovie;
    
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (exportSession.status == AVAssetExportSessionStatusCompleted) {
            completion(outputURL);
        } else {
            RLog(RptrLogAreaError, @"Export failed: %@", exportSession.error);
            completion(nil);
        }
    }];
}

#pragma mark - Helper Methods

- (void)sessionDidStartRunning:(NSNotification *)notification {
    RLogVideo(@"AVCaptureSession started running - setting initial rotation");
    // Set initial rotation when session actually starts
    [self updateCameraRotationForOrientation:self->_lastDeviceOrientation];
}

- (void)updateCameraRotationForOrientation:(UIDeviceOrientation)orientation {
    // Diagnostic: Track rotation update timing
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    RLogVideo(@"updateCameraRotationForOrientation BEGIN for orientation %ld", (long)orientation);
    
    // Calculate the rotation angle needed to compensate for device orientation
    CGFloat rotationAngle = 0.0;
    
    // We want the video to always appear in landscape right orientation
    // So we need to rotate based on current device orientation
    switch (orientation) {
        case UIDeviceOrientationPortrait:
            rotationAngle = 90.0;  // Rotate 90 degrees to get to landscape right
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            rotationAngle = 270.0; // Rotate 270 degrees
            break;
        case UIDeviceOrientationLandscapeLeft:
            rotationAngle = 180.0; // Rotate 180 degrees (device is opposite of desired)
            break;
        case UIDeviceOrientationLandscapeRight:
            rotationAngle = 0.0;   // No rotation needed - already correct
            break;
        default:
            rotationAngle = 90.0;  // Default to portrait compensation
            break;
    }
    
    RLogVideo(@"Updating camera rotation to %.0f degrees for device orientation %ld", rotationAngle, (long)orientation);
    
    // Update preview connection
    if (self.previewLayer) {
        AVCaptureConnection *previewConnection = self.previewLayer.connection;
        if (previewConnection) {
            if (@available(iOS 17.0, *)) {
                if ([previewConnection isVideoRotationAngleSupported:rotationAngle]) {
                    previewConnection.videoRotationAngle = rotationAngle;
                    RLogVideo(@"Updated preview rotation to %.0f degrees", rotationAngle);
                }
            } else {
                // For iOS 16 and below, map angle to orientation
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                AVCaptureVideoOrientation videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                switch ((int)rotationAngle) {
                    case 0:
                        videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                        break;
                    case 90:
                        videoOrientation = AVCaptureVideoOrientationPortrait;
                        break;
                    case 180:
                        videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                        break;
                    case 270:
                        videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                        break;
                }
                if (previewConnection.isVideoOrientationSupported) {
                    previewConnection.videoOrientation = videoOrientation;
                    RLogVideo(@"Updated preview orientation to %ld", (long)videoOrientation);
                }
                #pragma clang diagnostic pop
            }
        }
    }
    
    // Update video data output connection
    // Only update the active output, not all outputs
    if (self.videoDataOutput) {
        AVCaptureConnection *connection = [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
        if (connection) {
            if (@available(iOS 17.0, *)) {
                if ([connection isVideoRotationAngleSupported:rotationAngle]) {
                    connection.videoRotationAngle = rotationAngle;
                    RLogVideo(@"Updated video output rotation to %.0f degrees", rotationAngle);
                }
            } else {
                // Same mapping for iOS 16 and below
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                AVCaptureVideoOrientation videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                switch ((int)rotationAngle) {
                    case 0:
                        videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                        break;
                    case 90:
                        videoOrientation = AVCaptureVideoOrientationPortrait;
                        break;
                    case 180:
                        videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                        break;
                    case 270:
                        videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                        break;
                }
                if (connection.isVideoOrientationSupported) {
                    connection.videoOrientation = videoOrientation;
                    RLogVideo(@"Updated video output orientation to %ld", (long)videoOrientation);
                }
                #pragma clang diagnostic pop
            }
        }
    }
    
    // Diagnostic: Log total rotation update time
    CFAbsoluteTime totalTime = CFAbsoluteTimeGetCurrent() - startTime;
    if (totalTime > 0.1) {
        RLogVideo(@"WARNING: updateCameraRotationForOrientation took %.3fs (potential ANR)", totalTime);
    }
    RLogVideo(@"updateCameraRotationForOrientation END");
}

- (NSString *)getIPAddress {
    NSString *address = @"Not Connected";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if([interfaceName isEqualToString:@"en0"]) { // WiFi
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

- (NSString *)getCellularIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                
                // Check for cellular interfaces
                if ([interfaceName hasPrefix:@"pdp_ip"] || 
                    [interfaceName hasPrefix:@"rmnet"] ||
                    [interfaceName hasPrefix:@"en2"]) {
                    
                    char str[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr, str, INET_ADDRSTRLEN);
                    address = [NSString stringWithUTF8String:str];
                    
                    // Skip loopback and link-local addresses
                    if (![address hasPrefix:@"127."] && ![address hasPrefix:@"169.254."]) {
                        break;
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    freeifaddrs(interfaces);
    return address;
}

- (NSString *)getWiFiIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                
                if ([interfaceName isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    
                    // Skip loopback addresses
                    if (![address hasPrefix:@"127."]) {
                        break;
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    freeifaddrs(interfaces);
    return address;
}


- (void)requestLocationUpdate {
    // Request a single location update
    CLAuthorizationStatus locationStatus = self.locationManager.authorizationStatus;
    if (locationStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
        locationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        RLog(RptrLogAreaInfo, @"Requesting location update");
        
        // Use requestLocation for a single update instead of continuous updates
        if ([self.locationManager respondsToSelector:@selector(requestLocation)]) {
            [self.locationManager requestLocation];
        } else {
            // Fallback for older iOS versions - start updates
            // Will stop after first location update in didUpdateLocations delegate
            [self.locationManager startUpdatingLocation];
        }
    } else {
        RLog(RptrLogAreaInfo, @"Location permission not granted, skipping update");
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (location) {
        self.currentLocation = location;
        
        // Stop updates if we're using the fallback method (older iOS versions)
        if (![self.locationManager respondsToSelector:@selector(requestLocation)]) {
            [self.locationManager stopUpdatingLocation];
        }
        
    }
}

// This method is deprecated in iOS 14.0+, but kept for backwards compatibility
// For iOS 14.0+, use locationManagerDidChangeAuthorization: instead
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager startUpdatingLocation];
    }
}
#pragma clang diagnostic pop

// iOS 14.0+ authorization change handler
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager API_AVAILABLE(ios(14.0)) {
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    RLog(RptrLogAreaError, @"Location manager failed with error: %@", error.localizedDescription);
}

- (void)storeCameraPermissionStatus {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [[NSUserDefaults standardUserDefaults] setInteger:status forKey:@"CameraPermissionStatus"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)showCameraPermissionDeniedMessage {
    UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, self.view.frame.size.width - 40, 100)];
    messageLabel.text = @"Camera access is required.\nPlease enable it in Settings.";
    messageLabel.textColor = [UIColor whiteColor];
    messageLabel.font = [UIFont systemFontOfSize:18];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.center = self.view.center;
    [self.view addSubview:messageLabel];
}



#pragma mark - Session Notifications

- (void)sessionWasInterrupted:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
    
    NSString *sessionID = nil;
    for (NSString *cameraID in self.captureSessions) {
        if (self.captureSessions[cameraID] == session) {
            sessionID = cameraID;
            break;
        }
    }
    
    RLog(RptrLogAreaError, @"Session interrupted for camera %@, reason: %ld", sessionID, (long)reason);
    
    switch (reason) {
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
            RLog(RptrLogAreaError, @"Video device not available in background");
            break;
        case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
            RLog(RptrLogAreaError, @"Audio device in use by another client");
            break;
        case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
            RLog(RptrLogAreaError, @"Video device in use by another client");
            break;
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
            RLog(RptrLogAreaError, @"Video device not available with multiple foreground apps");
            break;
        default:
            break;
    }
}

- (void)sessionInterruptionEnded:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    RLog(RptrLogAreaStartup, @"Session interruption ended for: %@", session);
}

- (void)sessionRuntimeError:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    AVCaptureSession *session = notification.object;
    
    NSString *sessionID = nil;
    NSString *cameraName = @"unknown";
    for (NSString *cameraID in self.captureSessions) {
        if (self.captureSessions[cameraID] == session) {
            sessionID = cameraID;
            // Find camera name
            AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
            for (AVCaptureDevice *cam in cameras) {
                if ([cam.uniqueID isEqualToString:cameraID]) {
                    cameraName = cam.localizedName;
                    break;
                }
            }
            break;
        }
    }
    
    RLog(RptrLogAreaError, @"Session runtime error for camera %@ (%@): %@", sessionID, cameraName, error.localizedDescription);
    RLog(RptrLogAreaError, @"Error domain: %@, code: %ld", error.domain, (long)error.code);
    RLog(RptrLogAreaError, @"Error userInfo: %@", error.userInfo);
    
    // Check if it's a multi-cam session
    if (@available(iOS 13.0, *)) {
        if ([session isKindOfClass:[AVCaptureMultiCamSession class]]) {
            RLog(RptrLogAreaError, @"Error occurred in multi-cam session");
            
            // If recording error, check movie outputs
            if ([error.localizedDescription containsString:@"Cannot Record"]) {
                RLog(RptrLogAreaError, @"Recording error detected. Checking movie outputs...");
                
                for (NSString *camID in self.movieFileOutputs) {
                    AVCaptureMovieFileOutput *output = self.movieFileOutputs[camID];
                    if (!output) {
                        RLog(RptrLogAreaError, @"Movie output for %@: Not found", camID);
                        continue;
                    }
                    RLog(RptrLogAreaInfo, @"Movie output for %@:", camID);
                    RLog(RptrLogAreaInfo, @"  - isRecording: %@", output.isRecording ? @"YES" : @"NO");
                    RLog(RptrLogAreaInfo, @"  - connection count: %lu", (unsigned long)output.connections.count);
                    
                    // Check each connection
                    for (AVCaptureConnection *connection in output.connections) {
                        RLog(RptrLogAreaInfo, @"  - Connection active: %@, enabled: %@", 
                              connection.active ? @"YES" : @"NO",
                              connection.enabled ? @"YES" : @"NO");
                    }
                }
            }
        }
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        // Retain the sample buffer immediately to prevent deallocation
        if (sampleBuffer) {
            CFRetain(sampleBuffer);
        } else {
            RLog(RptrLogAreaError, @"ERROR: Received NULL sample buffer");
            return;
        }
    
    // Video orientation is now set during configuration, no need to set it here
    
    // Debug: Log sample buffer dimensions
    if (output == self.videoDataOutput) {
        static int dimensionLogCount = 0;
        if (dimensionLogCount < 5) {
            CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (formatDesc) {
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
                RLogVideo(@"Sample buffer dimensions: %d x %d (frame %d)", dimensions.width, dimensions.height, dimensionLogCount + 1);
                
                // Check connection rotation
                CGFloat rotation = 0;
                if (@available(iOS 17.0, *)) {
                    rotation = connection.videoRotationAngle;
                }
                RLogVideo(@"Connection rotation angle: %.0f degrees", rotation);
            }
            dimensionLogCount++;
        }
    }
    
    // Debug: Log any call to this method
    static int totalCalls = 0;
    totalCalls++;
    if (totalCalls <= 5) {
        RLog(RptrLogAreaProtocol, @"captureOutput called! Call #%d, Output class: %@", 
              totalCalls, NSStringFromClass([output class]));
    }
    
    // Log first frame to verify delegate is being called
    static BOOL firstFrameLogged = NO;
    if (!firstFrameLogged && output == self.videoDataOutput) {
        firstFrameLogged = YES;
        RLog(RptrLogAreaProtocol, @"FIRST FRAME RECEIVED - Video data output delegate is working!");
        RLog(RptrLogAreaProtocol, @"Output: %@, Connection active: %@, Streaming: %@",
              output, connection.isActive ? @"YES" : @"NO", self.isStreaming ? @"YES" : @"NO");
    }
    
    // Feed video to HLS streaming server if active
    // Find back camera's video data output (we only stream from back camera)
    AVCaptureVideoDataOutput *backCameraOutput = nil;
    for (NSString *cameraID in self.videoDataOutputs) {
        AVCaptureDevice *camera = [AVCaptureDevice deviceWithUniqueID:cameraID];
        if (camera && camera.position == AVCaptureDevicePositionBack) {
            backCameraOutput = self.videoDataOutputs[cameraID];
            break;
        }
    }
    
    if (self.isStreaming && output == backCameraOutput) {
        static int frameCount = 0;
        frameCount++;
        if (frameCount % 30 == 0) { // Log every 30 frames
            RLog(RptrLogAreaProtocol, @"ViewController sending frame %d to HLS server", frameCount);
            RLog(RptrLogAreaProtocol, @"HLS server instance: %@", self.hlsServer);
            RLog(RptrLogAreaProtocol, @"Sample buffer valid: %@", sampleBuffer ? @"YES" : @"NO");
        }
        
        // Ensure sample buffer is valid before processing
        if (self.useDIYServer) {
            // DIY HLS Server
            RptrDIYHLSServer *diyServer = self.diyHLSServer; // Local strong reference
            if (diyServer && sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
                @try {
                    [diyServer processVideoSampleBuffer:sampleBuffer];
                } @catch (NSException *exception) {
                    RLog(RptrLogAreaError, @"Exception processing video frame in DIY server: %@", exception);
                    RLog(RptrLogAreaError, @"Reason: %@", exception.reason);
                }
            }
        } else {
            // Original HLS Server
            HLSAssetWriterServer *hlsServer = self.hlsServer; // Local strong reference
            if (hlsServer && sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
                @try {
                    // Stream video directly without overlays
                    // Orientation is now forced to landscape at the connection level
                    [hlsServer processVideoSampleBuffer:sampleBuffer];
                } @catch (NSException *exception) {
                    RLog(RptrLogAreaError, @"Exception processing video frame: %@", exception);
                    RLog(RptrLogAreaError, @"Reason: %@", exception.reason);
                    // Don't stop streaming on single frame error
                }
            } else {
                if (!CMSampleBufferIsValid(sampleBuffer)) {
                    RLog(RptrLogAreaError, @"WARNING: Invalid sample buffer received");
                } else {
                    RLog(RptrLogAreaError, @"WARNING: Cannot send frame - hlsServer=%@, sampleBuffer=%@", 
                          self.hlsServer, sampleBuffer ? @"Valid" : @"NULL");
                }
            }
        }
    }
    
    
    // Find which camera this output belongs to
    NSString *cameraID = nil;
    AVCaptureDevice *camera = nil;
    for (NSString *camID in self.videoDataOutputs) {
        if (self.videoDataOutputs[camID] == output) {
            cameraID = camID;
            // Find the camera device
            AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
            for (AVCaptureDevice *cam in cameras) {
                if ([cam.uniqueID isEqualToString:camID]) {
                    camera = cam;
                    break;
                }
            }
            break;
        }
    }
    
    if (!cameraID || !camera) {
        CFRelease(sampleBuffer);
        return;
    }
    
    // Only analyze frames periodically for each camera
    static NSMutableDictionary *frameCounters = nil;
    if (!frameCounters) {
        frameCounters = [NSMutableDictionary dictionary];
    }
    
    NSNumber *frameCount = frameCounters[cameraID] ?: @0;
    frameCount = @(frameCount.intValue + 1);
    frameCounters[cameraID] = frameCount;
    
    if (frameCount.intValue % 15 != 0) {
        CFRelease(sampleBuffer);
        return;
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        CFRelease(sampleBuffer);
        return;
    }
    
    // Lock the pixel buffer for reading
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    CIImage *ciImage = [CIImage imageWithCVImageBuffer:imageBuffer];
    
    // Calculate average brightness with autorelease pool to prevent memory buildup
    CGFloat brightness = 0;
    @autoreleasepool {
        brightness = [self calculateBrightnessForImage:ciImage];
    }
    
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    // Store recent brightness values for motion detection per camera
    static NSMutableDictionary *cameraBrightnessHistory = nil;
    if (!cameraBrightnessHistory) {
        cameraBrightnessHistory = [NSMutableDictionary dictionary];
    }
    
    NSMutableArray *brightnessHistory = cameraBrightnessHistory[cameraID];
    if (!brightnessHistory) {
        brightnessHistory = [NSMutableArray array];
        cameraBrightnessHistory[cameraID] = brightnessHistory;
    }
    
    [brightnessHistory addObject:@(brightness)];
    if (brightnessHistory.count > 10) {
        [brightnessHistory removeObjectAtIndex:0];
    }
    
    // Detect motion for this camera
    BOOL hasMotion = [self detectMotionForCamera:cameraID withHistory:brightnessHistory];
    
    // Calculate activity score
    CGFloat motionScore = hasMotion ? 1.0 : 0.0;
    CGFloat lightScore = MIN(brightness * 2.0, 1.0);
    CGFloat activityScore = (motionScore + lightScore) / 2.0;
    
    // Store score for this camera
    self.cameraActivityScores[cameraID] = @(activityScore);
    RLog(RptrLogAreaInfo, @"Camera %@ activity score: %.3f (motion: %.1f, light: %.1f, brightness: %.3f)", 
          camera.localizedName, activityScore, motionScore, lightScore, brightness);
    
    // Update current camera's brightness if it's the active one
    if ([cameraID isEqualToString:self.currentCameraDevice.uniqueID]) {
        self.lastFrameBrightness = brightness;
    }
    
    // Release the sample buffer that we retained at the beginning
    CFRelease(sampleBuffer);
    } // End of @autoreleasepool
}

- (CGFloat)calculateBrightnessForImage:(CIImage *)image {
    NSParameterAssert(image != nil);
    
    if (!image) {
        RLog(RptrLogAreaError, @"Cannot calculate brightness for nil image");
        return 0.0;
    }
    
    CIVector *extent = [CIVector vectorWithX:image.extent.origin.x
                                            Y:image.extent.origin.y
                                            Z:image.extent.size.width
                                            W:image.extent.size.height];
    
    CIFilter *filter = [CIFilter filterWithName:@"CIAreaAverage"];
    [filter setValue:image forKey:kCIInputImageKey];
    [filter setValue:extent forKey:kCIInputExtentKey];
    
    CIImage *outputImage = filter.outputImage;
    if (!outputImage) {
        RLogError(@"CIAreaAverage filter failed to produce output");
        return 0;
    }
    
    // Create CIContext if needed - use thread-safe approach
    @synchronized(self) {
        if (!self.ciContext) {
            // Create context with software renderer for better stability
            NSDictionary *options = @{
                kCIContextUseSoftwareRenderer: @(YES),
                kCIContextPriorityRequestLow: @(YES)
            };
            self.ciContext = [CIContext contextWithOptions:options];
            if (!self.ciContext) {
                RLogError(@"Failed to create CIContext for brightness calculation");
                return 0;
            }
        }
    }
    
    // Get the actual extent of the output image
    CGRect imageExtent = [outputImage extent];
    if (CGRectIsEmpty(imageExtent) || CGRectIsInfinite(imageExtent)) {
        RLogError(@"Invalid image extent for brightness calculation");
        return 0;
    }
    
    // For CIAreaAverage, the output is typically 1x1 pixel, so use that directly
    CGRect sampleRect = imageExtent;
    
    // Protect CIContext operations with @synchronized
    CGImageRef cgImage = nil;
    @synchronized(self.ciContext) {
        cgImage = [self.ciContext createCGImage:outputImage fromRect:sampleRect];
    }
    
    if (!cgImage) {
        RLog(RptrLogAreaError, @"Failed to create CGImage from CIImage");
        return 0;
    }
    
    // Create a small bitmap context to sample the average color
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    size_t bytesPerRow = width * 4;
    
    unsigned char *pixelData = calloc(width * height * 4, sizeof(unsigned char));
    if (!pixelData) {
        CGImageRelease(cgImage);
        RLogError(@"Failed to allocate pixel buffer for brightness calculation");
        return 0;
    }
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixelData,
                                                 width, height,
                                                 8, bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    
    if (!context) {
        free(pixelData);
        CGImageRelease(cgImage);
        RLogError(@"Failed to create bitmap context for brightness calculation");
        return 0;
    }
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGImageRelease(cgImage);
    
    // Calculate average brightness from all pixels using luminance formula
    double totalBrightness = 0;
    size_t pixelCount = width * height;
    
    for (size_t i = 0; i < pixelCount; i++) {
        size_t offset = i * 4;
        // Use luminance formula: 0.299*R + 0.587*G + 0.114*B
        double pixelBrightness = (pixelData[offset] * 0.299 + 
                                 pixelData[offset + 1] * 0.587 + 
                                 pixelData[offset + 2] * 0.114) / 255.0;
        totalBrightness += pixelBrightness;
    }
    
    free(pixelData);
    
    CGFloat brightness = totalBrightness / (double)pixelCount;
    return brightness;
}

- (BOOL)detectMotionForCamera:(NSString *)cameraID withHistory:(NSMutableArray *)brightnessHistory {
    if (brightnessHistory.count < 5) {
        return YES; // Not enough data, assume motion
    }
    
    // Calculate variance in brightness values
    CGFloat sum = 0;
    CGFloat sumSquared = 0;
    NSInteger count = brightnessHistory.count;
    
    for (NSNumber *brightness in brightnessHistory) {
        CGFloat value = brightness.floatValue;
        sum += value;
        sumSquared += value * value;
    }
    
    CGFloat mean = sum / count;
    CGFloat variance = (sumSquared / count) - (mean * mean);
    
    // Motion threshold - adjust for sensitivity
    return variance > 0.0002;
}

- (BOOL)detectMotion {
    if (self.recentFrameBrightness.count < 5) {
        return YES; // Not enough data, assume motion
    }
    
    // Calculate variance in brightness values
    CGFloat sum = 0;
    CGFloat sumSquared = 0;
    
    for (NSNumber *brightness in self.recentFrameBrightness) {
        CGFloat value = [brightness floatValue];
        sum += value;
        sumSquared += value * value;
    }
    
    CGFloat mean = sum / self.recentFrameBrightness.count;
    CGFloat variance = (sumSquared / self.recentFrameBrightness.count) - (mean * mean);
    
    // Motion detected if variance is above threshold
    BOOL motion = variance > 0.00005; // Lower threshold for better sensitivity
    RLog(RptrLogAreaInfo, @"Motion variance: %.6f, detected: %@", variance, motion ? @"YES" : @"NO");
    return motion;
}

- (void)evaluateAndSwitchToBestCamera {
    
    RLog(RptrLogAreaInfo, @"\n=== Camera Evaluation ===");
    
    // Apply decay to all camera scores to ensure fairness
    [self decayAllCameraScores];
    
    // Get all cameras
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
    if (cameras.count < 2) {
        return;
    }
    
    // Check if we have scores for all cameras
    BOOL allCamerasEvaluated = YES;
    for (AVCaptureDevice *camera in cameras) {
        if (!self.cameraActivityScores[camera.uniqueID]) {
            allCamerasEvaluated = NO;
            RLog(RptrLogAreaInfo, @"Camera %@ not yet evaluated", camera.localizedName);
        }
    }
    
    // If not all cameras evaluated, try an unevaluated one
    if (!allCamerasEvaluated) {
        [self tryAlternateCameraWithEvaluation];
        return;
    }
    
    // Find camera with highest activity score
    AVCaptureDevice *bestCamera = nil;
    CGFloat bestScore = -1;
    CGFloat currentScore = 0;
    
    for (AVCaptureDevice *camera in cameras) {
        NSNumber *scoreNumber = self.cameraActivityScores[camera.uniqueID];
        CGFloat score = (scoreNumber != nil) ? [scoreNumber floatValue] : 0.0;
        
        RLog(RptrLogAreaInfo, @"Camera %@ score: %.3f %@", 
              camera.localizedName, score,
              [camera.uniqueID isEqualToString:self.currentCameraDevice.uniqueID] ? @"(current)" : @"");
        
        if ([camera.uniqueID isEqualToString:self.currentCameraDevice.uniqueID]) {
            currentScore = score;
        }
        
        if (score > bestScore) {
            bestScore = score;
            bestCamera = camera;
        }
    }
    
    // Check if enough time has passed since last switch to current camera
    NSDate *lastSwitch = self.cameraSwitchTimestamps[self.currentCameraDevice.uniqueID];
    NSTimeInterval timeSinceSwitch = lastSwitch ? [[NSDate date] timeIntervalSinceDate:lastSwitch] : 10.0;
    
    // Only switch if the best camera has significantly better score
    // Use absolute difference for low scores to avoid percentage issues
    CGFloat threshold = currentScore < 0.3 ? currentScore + 0.1 : currentScore * 1.2;
    
    // AND at least 3 seconds have passed since switching to current camera
    if (bestCamera && ![bestCamera.uniqueID isEqualToString:self.currentCameraDevice.uniqueID] && 
        bestScore > threshold && timeSinceSwitch > 3.0) {
        RLog(RptrLogAreaInfo, @"Switching to %@ (score: %.3f) from %@ (score: %.3f) - %.0f%% better", 
              bestCamera.localizedName, bestScore,
              self.currentCameraDevice.localizedName, currentScore,
              ((bestScore - currentScore) / currentScore) * 100);
        
        // Camera switching disabled
        // [self switchToCamera:bestCamera];
    } else {
        RLog(RptrLogAreaInfo, @"Keeping current camera %@ (score: %.3f, best: %.3f)", 
              self.currentCameraDevice.localizedName, currentScore, bestScore);
        
        // If current camera has very low score, force evaluation of other camera
        if (currentScore < 0.1) {
            RLog(RptrLogAreaInfo, @"Current camera has very low activity, forcing alternate camera");
            [self tryAlternateCameraWithEvaluation];
        }
    }
    
    RLog(RptrLogAreaInfo, @"=== End Evaluation ===\n");
}

- (void)tryAlternateCameraWithEvaluation {
    // Get all cameras
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
    
    // Find alternate camera
    for (AVCaptureDevice *camera in cameras) {
        if (![camera.uniqueID isEqualToString:self.currentCameraDevice.uniqueID]) {
            RLog(RptrLogAreaInfo, @"Switching to alternate camera: %@ for evaluation", camera.localizedName);
            // Camera switching disabled
            // [self switchToCamera:camera];
            
            // Don't reset the evaluation timer - let it continue on its schedule
            break;
        }
    }
}

- (void)decayAllCameraScores {
    NSMutableDictionary *decayedScores = [NSMutableDictionary dictionary];
    
    for (NSString *cameraID in self.cameraActivityScores) {
        CGFloat score = [self.cameraActivityScores[cameraID] floatValue];
        // Decay inactive camera scores more aggressively
        if ([cameraID isEqualToString:self.currentCameraDevice.uniqueID]) {
            // Current camera: keep score as is (it's being updated)
            decayedScores[cameraID] = @(score);
        } else {
            // Inactive cameras: decay by 20% each evaluation
            CGFloat decayedScore = score * 0.8;
            decayedScores[cameraID] = @(decayedScore);
            RLog(RptrLogAreaInfo, @"Decaying inactive camera score: %.3f -> %.3f", score, decayedScore);
        }
    }
    
    self.cameraActivityScores = decayedScores;
}

#pragma mark - Permission Handling
- (void)checkAndSetupIfPermissionsGranted {
    PermissionManager *permissionManager = [PermissionManager sharedManager];
    
    // Check if essential permissions are already granted (camera and microphone)
    BOOL cameraGranted = ([permissionManager statusForPermission:PermissionTypeCamera] == PermissionStatusAuthorized);
    BOOL microphoneGranted = ([permissionManager statusForPermission:PermissionTypeMicrophone] == PermissionStatusAuthorized);
    
    if (cameraGranted && microphoneGranted) {
        // Setup immediately if we have the essential permissions
        [self setupCameraPreview];
        [self setupUI];
        
        
        // Check location permission separately (non-blocking)
        if ([permissionManager statusForPermission:PermissionTypeLocation] == PermissionStatusAuthorized) {
            [self setupLocationManager];
        }
    } else {
        // Show request permission UI
        [self showPermissionRequestUI];
    }
}

- (void)showPermissionRequestUI {
    
    // Show a button to request permissions
    UIButton *requestButton = [UIButton buttonWithType:UIButtonTypeSystem];
    requestButton.frame = CGRectMake(0, 0, 300, 50);
    requestButton.center = self.view.center;
    [requestButton setTitle:@"Grant Camera & Microphone Access" forState:UIControlStateNormal];
    requestButton.titleLabel.font = [UIFont systemFontOfSize:18];
    [requestButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    requestButton.backgroundColor = [UIColor systemBlueColor];
    requestButton.layer.cornerRadius = 8;
    [requestButton addTarget:self action:@selector(requestPermissionsButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:requestButton];
}

- (void)requestPermissionsButtonTapped {
    [self requestAllPermissions];
}

- (void)requestAllPermissions {
    PermissionManager *permissionManager = [PermissionManager sharedManager];
    
    // Check if all permissions are already granted
    if ([permissionManager hasAllRequiredPermissions]) {
        [self setupCameraPreview];
        [self setupUI];
        
        
        [self setupLocationManager];
        return;
    }
    
    // Request all required permissions (photo library will be requested when needed)
    NSArray *requiredPermissions = @[
        @(PermissionTypeCamera),
        @(PermissionTypeMicrophone),
        @(PermissionTypeLocation)
    ];
    
    [permissionManager requestPermissions:requiredPermissions completion:^(NSDictionary<NSNumber *,NSNumber *> *results) {
        BOOL cameraGranted = [results[@(PermissionTypeCamera)] boolValue];
        BOOL microphoneGranted = [results[@(PermissionTypeMicrophone)] boolValue];
        BOOL locationGranted = [results[@(PermissionTypeLocation)] boolValue];
        
        if (cameraGranted && microphoneGranted) {
            [self setupCameraPreview];
            [self setupUI];
            
            if (locationGranted) {
                [self setupLocationManager];
            }
        } else {
            [self showPermissionDeniedUI];
        }
    }];
}

- (void)showPermissionDeniedUI {
    // Remove any existing UI
    for (UIView *subview in self.view.subviews) {
        [subview removeFromSuperview];
    }
    
    // Create permission denied message
    UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    messageLabel.text = @"Camera and Microphone access are required to use this app.\n\nPlease grant permissions in Settings.";
    messageLabel.textColor = [UIColor whiteColor];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.font = [UIFont systemFontOfSize:18];
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self.view addSubview:messageLabel];
    
    // Create settings button
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setTitle:@"Open Settings" forState:UIControlStateNormal];
    settingsButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [settingsButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    settingsButton.backgroundColor = [UIColor whiteColor];
    settingsButton.layer.cornerRadius = 10;
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    
    [self.view addSubview:settingsButton];
    
    // Setup constraints
    [NSLayoutConstraint activateConstraints:@[
        [messageLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [messageLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-50],
        [messageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [messageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
        
        [settingsButton.topAnchor constraintEqualToAnchor:messageLabel.bottomAnchor constant:30],
        [settingsButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [settingsButton.widthAnchor constraintEqualToConstant:200],
        [settingsButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

- (void)openSettings {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] 
                                       options:@{} 
                             completionHandler:nil];
}

- (void)setupLocationManager {
    if (!self.locationManager) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
        [self.locationManager startUpdatingLocation];
    }
}




- (void)displayNextFeedback {
    // Check if we should display feedback
    if (!self.isStreaming) {
        self.isDisplayingFeedback = NO;
        return;
    }
    
    // Thread-safe retrieval of next message
    dispatch_async(self.feedbackQueueLock, ^{
        if (self.feedbackQueue.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isDisplayingFeedback = NO;
            });
            return;
        }
        
        // Get next message from queue
        NSString *message = [self.feedbackQueue firstObject];
        [self.feedbackQueue removeObjectAtIndex:0];
        NSUInteger remainingCount = self.feedbackQueue.count;
        
        RLogNetwork(@"Displaying feedback: %@ (queue size: %lu)", message, (unsigned long)remainingCount);
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isDisplayingFeedback = YES;
            
            // Update feedback label text
            self.feedbackLabel.text = message;
            
            // Animate the feedback label appearance
            if (self.feedbackLabel.hidden) {
                self.feedbackLabel.alpha = 0;
                self.feedbackLabel.hidden = NO;
                
                [UIView animateWithDuration:0.3 animations:^{
                    self.feedbackLabel.alpha = 1.0;
                }];
            } else {
                // Already visible, just update text with subtle animation
                [UIView transitionWithView:self.feedbackLabel
                                  duration:0.2
                                   options:UIViewAnimationOptionTransitionCrossDissolve
                                animations:^{
                                    self.feedbackLabel.text = message;
                                }
                                completion:nil];
            }
            
            // Cancel any existing dismiss timer
            if (self.feedbackDismissTimer) {
                [self.feedbackDismissTimer invalidate];
                self.feedbackDismissTimer = nil;
            }
            
            // Set timer to auto-dismiss after 10 seconds
            self.feedbackDismissTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                                          target:self
                                                                        selector:@selector(dismissFeedback)
                                                                        userInfo:nil
                                                                         repeats:NO];
        });
    });
}

- (void)dismissFeedback {
    // Thread-safe check for more messages
    dispatch_async(self.feedbackQueueLock, ^{
        BOOL hasMoreMessages = self.feedbackQueue.count > 0;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasMoreMessages && self.isStreaming) {
                // Display next message immediately
                [self displayNextFeedback];
            } else {
                // No more messages, hide the label
                [UIView animateWithDuration:0.3 animations:^{
                    self.feedbackLabel.alpha = 0;
                } completion:^(BOOL finished) {
                    self.feedbackLabel.hidden = YES;
                    self.feedbackLabel.text = @"";
                    self.isDisplayingFeedback = NO;
                }];
                
                // Clear the timer reference
                self.feedbackDismissTimer = nil;
            }
        });
    });
}

- (void)clearFeedbackDisplay {
    // Cancel timer
    if (self.feedbackDismissTimer) {
        [self.feedbackDismissTimer invalidate];
        self.feedbackDismissTimer = nil;
    }
    
    // Thread-safe queue clear
    dispatch_async(self.feedbackQueueLock, ^{
        [self.feedbackQueue removeAllObjects];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Hide feedback label immediately
            self.feedbackLabel.hidden = YES;
            self.feedbackLabel.text = @"";
            self.feedbackLabel.alpha = 0;
            self.isDisplayingFeedback = NO;
            
            RLogNetwork(@"Cleared feedback display and queue");
        });
    });
}

#pragma mark - RptrDiagnosticsDelegate

- (void)diagnostics:(RptrDiagnostics *)diagnostics didDetectMemoryPressure:(RptrMemoryPressureLevel)level stats:(RptrMemoryStats *)stats {
    RLogWarning(@"Memory pressure detected: Level=%ld, Available=%.1fMB, Footprint=%.1fMB", 
                (long)level,
                stats.availableBytes / (1024.0 * 1024.0),
                stats.footprintBytes / (1024.0 * 1024.0));
    
    // Take action based on pressure level
    switch (level) {
        case RptrMemoryPressureWarning:
            // Reduce quality if in real-time mode
            if (self.currentQualityMode == RptrVideoQualityModeRealtime && self.isStreaming) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.currentQualityMode = RptrVideoQualityModeReliable;
                    RptrVideoQualitySettings *settings = [RptrVideoQualitySettings settingsForMode:RptrVideoQualityModeReliable];
                    [self.hlsServer updateQualitySettings:settings];
                    RLogInfo(@"Switched to reliable mode due to memory pressure");
                });
            }
            break;
            
        case RptrMemoryPressureCritical:
            // Clear old segments more aggressively
            if (self.hlsServer) {
                [self.hlsServer cleanupOldSegments];
            }
            break;
            
        case RptrMemoryPressureTerminal:
            // Emergency: stop streaming to avoid termination
            if (self.isStreaming) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self stopStreaming];
                    
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Low Memory"
                                                                                   message:@"Streaming stopped due to critically low memory"
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                });
            }
            break;
            
        default:
            break;
    }
}

- (void)diagnostics:(RptrDiagnostics *)diagnostics didDetectANR:(RptrANREvent *)event {
    RLogError(@"ANR detected! Duration: %.2fs, Severity: %ld", event.duration, (long)event.severity);
    
    // Log the stack trace for debugging
    if (event.stackTrace.length > 0) {
        RLogDebug(@"ANR Stack trace:\n%@", event.stackTrace);
    }
    
    // If severe ANR during streaming, consider stopping
    if (event.severity >= RptrANRSeveritySevere && self.isStreaming) {
        RLogError(@"Severe ANR during streaming - consider stopping stream");
        
        // Update UI to show warning
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.streamStatusLabel) {
                self.streamStatusLabel.text = @"⚠️ Performance Issue";
                self.streamStatusLabel.textColor = [UIColor orangeColor];
            }
        });
    }
}

- (void)diagnostics:(RptrDiagnostics *)diagnostics didRecoverFromANR:(RptrANREvent *)event {
    RLogInfo(@"Recovered from ANR (duration: %.2fs)", event.duration);
    
    // Clear warning if shown
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.streamStatusLabel && [self.streamStatusLabel.text isEqualToString:@"⚠️ Performance Issue"]) {
            self.streamStatusLabel.text = @"";
            self.streamStatusLabel.textColor = [UIColor whiteColor];
        }
    });
}

- (void)diagnostics:(RptrDiagnostics *)diagnostics didReceiveMetricPayload:(MXMetricPayload *)payload {
    if (@available(iOS 13.0, *)) {
        // Log interesting metrics
        if (payload.memoryMetrics) {
            RLogInfo(@"MetricKit - Peak memory: %.1fMB over last 24h",
                     payload.memoryMetrics.peakMemoryUsage.doubleValue / (1024.0 * 1024.0));
        }
        
        if (@available(iOS 14.0, *)) {
            if (payload.applicationExitMetrics) {
                NSInteger foregroundExits = payload.applicationExitMetrics.foregroundExitData.cumulativeNormalAppExitCount;
                NSInteger backgroundExits = payload.applicationExitMetrics.backgroundExitData.cumulativeNormalAppExitCount;
                
                if (foregroundExits > 0 || backgroundExits > 0) {
                    RLogWarning(@"App terminations in last 24h - Foreground: %ld, Background: %ld",
                                (long)foregroundExits, (long)backgroundExits);
                }
            }
        }
    }
}

#pragma mark - RptrDIYHLSServerDelegate

- (void)diyServer:(RptrDIYHLSServer *)server didStartOnPort:(NSInteger)port {
    RLogDIY(@"[DELEGATE] Server started on port %ld", (long)port);
    dispatch_async(dispatch_get_main_queue(), ^{
        RLogDIY(@"[UI] Server status would update here");
    });
}

- (void)diyServer:(RptrDIYHLSServer *)server didGenerateInitSegment:(NSData *)initSegment {
    RLogDIY(@"[DELEGATE] Init segment generated: %lu bytes", 
         (unsigned long)initSegment.length);
}

- (void)diyServer:(RptrDIYHLSServer *)server 
didGenerateMediaSegment:(NSData *)segment 
               duration:(NSTimeInterval)duration
         sequenceNumber:(uint32_t)sequenceNumber {
    RLogDIY(@"[DELEGATE] Segment %u: %.3fs, %lu bytes",
         sequenceNumber, duration, (unsigned long)segment.length);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        RLogDIY(@"[UI] Segment count: %u", sequenceNumber + 1);
    });
}

- (void)diyServer:(RptrDIYHLSServer *)server didEncounterError:(NSError *)error {
    RLog(RptrLogAreaError, @"[DIY-DELEGATE] Error: %@", error);
}

- (void)diyServerDidStop:(RptrDIYHLSServer *)server {
    RLogDIY(@"[DELEGATE] Server stopped");
    dispatch_async(dispatch_get_main_queue(), ^{
        RLogDIY(@"[UI] Server stopped status would update here");
    });
}

#pragma mark - Button Actions

- (void)copyEndpoint:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < self.endpointLabels.count) {
        UILabel *label = self.endpointLabels[index];
        NSString *endpoint = label.text;
        
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = endpoint;
        
        // Visual feedback
        UIColor *originalColor = sender.backgroundColor;
        sender.backgroundColor = [UIColor systemGreenColor];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sender.backgroundColor = originalColor;
        });
        
        RLogUI(@"Copied endpoint to clipboard: %@", endpoint);
    }
}

@end