//
//  ViewController.m
//  Rptr
//
//  Created by Jessica Hansberry on 23/07/2025.
//

#import "ViewController.h"
#import "PermissionManager.h"
#import "RptrLogger.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>

@interface ViewController ()

@end

@implementation ViewController

- (void)loadView {
    // Create view manually to ensure full screen
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    view.backgroundColor = [UIColor blackColor];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
    
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"loadView - Created view with frame: %@", NSStringFromCGRect(view.frame));
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
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
    
    // Log the initial view frame for debugging
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLoad - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLoad - Screen bounds: %@", NSStringFromCGRect([[UIScreen mainScreen] bounds]));
    
    // Check iOS version
    if (@available(iOS 17.6, *)) {
        RLog(RptrLogAreaUI, @"iOS version check passed: %@", [[UIDevice currentDevice] systemVersion]);
    } else {
        // Show alert for unsupported iOS version
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iOS Version Not Supported"
                                                                       message:@"This app requires iOS 17.6 or later. Please update your device."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            exit(0);
        }]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }
    
    // Initialize immediately without delay
        // Initialize overlay queue for thread-safe pixel buffer operations
        self.overlayQueue = dispatch_queue_create("com.rptr.overlay.queue", DISPATCH_QUEUE_SERIAL);
        
        // Enable device orientation notifications
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        
        // Preload UI components immediately in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self preloadUIComponents];
            });
        });
        
        // Load saved interval or default to 15 seconds
        // Interval functionality removed
        
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
        
        // Only check permissions, don't request them yet
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkAndSetupIfPermissionsGranted];
        });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidAppear - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidAppear - Window bounds: %@", NSStringFromCGRect(self.view.window.bounds));
    
    // Check parent view controller
    if (self.parentViewController) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Parent view controller: %@", NSStringFromClass([self.parentViewController class]));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Parent view frame: %@", NSStringFromCGRect(self.parentViewController.view.frame));
    }
    
    // Check if we're in a container
    if (self.navigationController) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"In navigation controller");
    }
    if (self.tabBarController) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"In tab bar controller");
    }
    if (self.splitViewController) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"In split view controller");
    }
    
    // Log safe area insets
    if (@available(iOS 11.0, *)) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Safe area insets: %@", NSStringFromUIEdgeInsets(self.view.safeAreaInsets));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Layout margins: %@", NSStringFromUIEdgeInsets(self.view.layoutMargins));
    }
    
    // If view isn't filling window, force it
    if (!CGRectEqualToRect(self.view.frame, self.view.window.bounds)) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"View not filling window, forcing resize");
        self.view.frame = self.view.window.bounds;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }
    
    // Log all subviews to check hierarchy
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"View subviews count: %lu", (unsigned long)self.view.subviews.count);
    for (UIView *subview in self.view.subviews) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Subview: %@ frame: %@", NSStringFromClass([subview class]), NSStringFromCGRect(subview.frame));
    }
    
    // Force landscape orientation now that scene is connected
    [self enforceImmediateLandscapeOrientation];
    
    // Force landscape orientation
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    
    // Ensure preview layer fills the view after orientation change
    if (self.previewLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.previewLayer.frame = self.view.bounds;
        [CATransaction commit];
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidAppear - Updated preview layer frame: %@", NSStringFromCGRect(self.previewLayer.frame));
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // Log view hierarchy and transforms
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - View bounds: %@", NSStringFromCGRect(self.view.bounds));
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - View frame: %@", NSStringFromCGRect(self.view.frame));
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - View transform: %@", NSStringFromCGAffineTransform(self.view.transform));
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - View superview: %@", self.view.superview);
    if (self.view.superview) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - Superview bounds: %@", NSStringFromCGRect(self.view.superview.bounds));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"viewDidLayoutSubviews - Superview frame: %@", NSStringFromCGRect(self.view.superview.frame));
    }
    
    // Force view to fill its superview
    if (self.view.superview && !CGRectEqualToRect(self.view.frame, self.view.superview.bounds)) {
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"View not filling superview, forcing resize");
        self.view.frame = self.view.superview.bounds;
    }
    
    // Ensure preview layer fills the entire view
    if (self.previewLayer) {
        self.previewLayer.frame = self.view.bounds;
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Preview layer frame updated to: %@", NSStringFromCGRect(self.previewLayer.frame));
    }
    
    
    // Update stream button position for landscape orientation
    if (self.streamButton) {
        CGFloat streamButtonSize = 44;
        self.streamButton.frame = CGRectMake(20, self.view.frame.size.height - streamButtonSize - 50, streamButtonSize, streamButtonSize);
    }
    
    // Update info labels position
    if (self.locationLabel) {
        self.locationLabel.frame = CGRectMake(self.view.frame.size.width - 210, 65, 200, 22);
        self.utcTimeLabel.frame = CGRectMake(self.view.frame.size.width - 210, 90, 200, 22);
        self.streamInfoLabel.frame = CGRectMake(self.view.frame.size.width - 210, 115, 200, 22);
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
    self.movieFileOutputs = [NSMutableDictionary dictionary];
    self.videoDataOutputs = [NSMutableDictionary dictionary];
    
    // Only use single camera setup
    RLog(RptrLogAreaCamera, @"Setting up single camera session");
    [self setupSingleCameraSession];
}


- (void)setupSingleCameraSession {
    
    // Get all cameras using AVCaptureDeviceDiscoverySession (iOS 10+)
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *cameras = discoverySession.devices;
    RLogVideo(@"Found %lu cameras", (unsigned long)cameras.count);
    
    
    // Set up a session for each camera (but only one will work at a time)
    for (NSInteger i = 0; i < cameras.count; i++) {
        AVCaptureDevice *camera = cameras[i];
        [self setupSessionForCamera:camera];
    }
    
    // Select initial camera
    NSString *savedCameraID = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedCameraID"];
    AVCaptureDevice *initialCamera = nil;
    
    if (savedCameraID) {
        for (AVCaptureDevice *camera in cameras) {
            if ([camera.uniqueID isEqualToString:savedCameraID]) {
                initialCamera = camera;
                break;
            }
        }
    }
    
    if (!initialCamera) {
        initialCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    if (!initialCamera) {
        RLog(RptrLogAreaCamera | RptrLogAreaError, @"No cameras available");
        return;
    }
    
    // Set current camera and session
    self.currentCameraDevice = initialCamera;
    self.captureSession = self.captureSessions[initialCamera.uniqueID];
    self.movieFileOutput = self.movieFileOutputs[initialCamera.uniqueID];
    self.videoDataOutput = self.videoDataOutputs[initialCamera.uniqueID];
    
    RLog(RptrLogAreaCamera, @"Initial camera selected: %@ (position: %ld, uniqueID: %@)", 
          initialCamera.localizedName, (long)initialCamera.position, initialCamera.uniqueID);
    
    // Defer preview layer creation to ensure proper bounds
    dispatch_async(dispatch_get_main_queue(), ^{
        // Log screen and window info
        CGRect screenBounds = [[UIScreen mainScreen] bounds];
        CGRect nativeBounds = [[UIScreen mainScreen] nativeBounds];
        CGFloat scale = [[UIScreen mainScreen] scale];
        CGFloat nativeScale = [[UIScreen mainScreen] nativeScale];
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Screen bounds: %@", NSStringFromCGRect(screenBounds));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Native bounds: %@", NSStringFromCGRect(nativeBounds));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Screen scale: %f, native scale: %f", scale, nativeScale);
        
        // Check current interface orientation using window scene (iOS 13+)
        UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            orientation = self.view.window.windowScene.interfaceOrientation;
        }
        RLogUI(@"Current interface orientation: %ld", (long)orientation);
        
        // Check if we're in zoomed display mode
        BOOL isZoomed = (screenBounds.size.width * scale != nativeBounds.size.width);
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Display zoomed: %@", isZoomed ? @"YES" : @"NO");
        
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
            RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Camera video dimensions: %d x %d", dimensions.width, dimensions.height);
        }
        
        // Set the orientation to landscape using rotation angle (iOS 17+)
        AVCaptureConnection *previewConnection = self.previewLayer.connection;
        if (previewConnection && [previewConnection isVideoRotationAngleSupported:90]) {
            previewConnection.videoRotationAngle = 90; // 90 degrees for landscape right
        }
        
        // Remove any existing preview layers first
        for (CALayer *layer in [self.view.layer.sublayers copy]) {
            if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
                [layer removeFromSuperlayer];
            }
        }
        
        [self.view.layer insertSublayer:self.previewLayer atIndex:0];
        
        // Force a layout update
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Preview layer created with frame: %@", NSStringFromCGRect(self.previewLayer.frame));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"View layer bounds: %@", NSStringFromCGRect(self.view.layer.bounds));
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"View layer frame: %@", NSStringFromCGRect(self.view.layer.frame));
        
        // Try setting the layer bounds explicitly
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.previewLayer.bounds = self.view.layer.bounds;
        self.previewLayer.position = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
        [CATransaction commit];
        
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"After explicit bounds set - Preview layer bounds: %@, position: %@", 
             NSStringFromCGRect(self.previewLayer.bounds), NSStringFromCGPoint(self.previewLayer.position));
    });
    
    RLog(RptrLogAreaCamera, @"Main preview layer created with session: %@", self.captureSession);
    
    
    // Start the session for single camera
    [self.captureSession startRunning];
    
}

- (void)setupSessionForCamera:(AVCaptureDevice *)camera {
    RLog(RptrLogAreaCamera, @"Setting up session for camera: %@", camera.localizedName);
    
    // Create session for this camera
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    
    // Use a lower quality preset for secondary camera to reduce resource usage
    if (camera.position == AVCaptureDevicePositionFront) {
        session.sessionPreset = AVCaptureSessionPresetMedium;
        RLog(RptrLogAreaCamera, @"Using Medium preset for front camera to reduce resource usage");
    } else {
        session.sessionPreset = AVCaptureSessionPresetHigh;
        RLog(RptrLogAreaCamera, @"Using High preset for back camera");
    }
    
    // Create video input
    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
    if (error) {
        RLog(RptrLogAreaCamera | RptrLogAreaError, @"Error creating video input for %@: %@", camera.localizedName, error.localizedDescription);
        return;
    }
    
    // Add video input to session
    if ([session canAddInput:videoInput]) {
        [session addInput:videoInput];
        
        // Configure frame rate to 24 fps
        if ([camera lockForConfiguration:&error]) {
            // Set the frame rate to 24 fps
            CMTime frameDuration = CMTimeMake(1, 24);
            camera.activeVideoMinFrameDuration = frameDuration;
            camera.activeVideoMaxFrameDuration = frameDuration;
            [camera unlockForConfiguration];
            RLog(RptrLogAreaCamera | RptrLogAreaVideo, @"Set frame rate to 24 fps for %@", camera.localizedName);
        } else {
            RLog(RptrLogAreaCamera | RptrLogAreaError, @"Could not lock camera for configuration: %@", error.localizedDescription);
        }
    } else {
        RLog(RptrLogAreaCamera | RptrLogAreaError, @"Cannot add video input to session for %@", camera.localizedName);
        return;
    }
    
    // Only add audio input to the primary camera session to avoid conflicts
    // Audio will be recorded only from one source
    if (camera.position == AVCaptureDevicePositionBack || 
        (camera.position == AVCaptureDevicePositionUnspecified && [camera.localizedName containsString:@"Back"])) {
        AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        AVCaptureDeviceInput *audioInput = nil;
        if (audioDevice) {
            audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
            if (error) {
                RLog(RptrLogAreaAudio | RptrLogAreaError, @"Error creating audio input: %@", error.localizedDescription);
                error = nil;
            }
        }
        
        if (audioInput && [session canAddInput:audioInput]) {
            [session addInput:audioInput];
            RLog(RptrLogAreaAudio, @"Added audio input to %@ camera session", camera.localizedName);
        }
    } else {
        RLog(RptrLogAreaAudio, @"Skipping audio input for %@ camera to avoid conflicts", camera.localizedName);
    }
    
    // Add movie file output
    AVCaptureMovieFileOutput *movieOutput = [[AVCaptureMovieFileOutput alloc] init];
    if ([session canAddOutput:movieOutput]) {
        [session addOutput:movieOutput];
    }
    
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
        RLog(RptrLogAreaVideo, @"Video data output added for %@", camera.localizedName);
        
        // Force landscape orientation on the video connection using rotation angle
        AVCaptureConnection *videoConnection = [dataOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConnection && [videoConnection isVideoRotationAngleSupported:90]) {
            videoConnection.videoRotationAngle = 90; // 90 degrees for landscape right
            RLogVideo(@"Forced landscape orientation (90°) on video connection for %@", camera.localizedName);
        }
    }
    
    // Add audio data output for streaming (only on primary camera)
    if (camera.position == AVCaptureDevicePositionBack || 
        (camera.position == AVCaptureDevicePositionUnspecified && [camera.localizedName containsString:@"Back"])) {
        AVCaptureAudioDataOutput *audioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
        NSString *audioQueueName = [NSString stringWithFormat:@"audioQueue_%@", safeCameraName];
        dispatch_queue_t audioQueue = dispatch_queue_create([audioQueueName UTF8String], DISPATCH_QUEUE_SERIAL);
        [audioDataOutput setSampleBufferDelegate:self queue:audioQueue];
        
        if ([session canAddOutput:audioDataOutput]) {
            [session addOutput:audioDataOutput];
            self.audioDataOutput = audioDataOutput;
            RLog(RptrLogAreaAudio | RptrLogAreaHLS, @"Audio data output added for streaming");
        }
    }
    
    // Store in dictionaries
    self.captureSessions[camera.uniqueID] = session;
    self.movieFileOutputs[camera.uniqueID] = movieOutput;
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
    if (!self.hlsServer) {
        RLog(RptrLogAreaHLS, @"Initializing HLS server on app launch");
        self.hlsServer = [[HLSAssetWriterServer alloc] initWithPort:8080];
        self.hlsServer.delegate = self;
        
        NSError *error = nil;
        BOOL started = [self.hlsServer startServer:&error];
        if (started) {
            RLog(RptrLogAreaHLS, @"HLS server started successfully on port 8080");
        } else {
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"Failed to start HLS server: %@", error);
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
    
    // Audio level meter container
    self.audioLevelMeter = [[UIView alloc] initWithFrame:CGRectMake(40, 40, 100, 12)];
    self.audioLevelMeter.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
    self.audioLevelMeter.layer.cornerRadius = 6;
    self.audioLevelMeter.layer.borderWidth = 1;
    self.audioLevelMeter.layer.borderColor = [[UIColor colorWithWhite:0.3 alpha:0.5] CGColor];
    self.audioLevelMeter.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.audioLevelMeter.hidden = YES; // Hidden by default
    [self.view addSubview:self.audioLevelMeter];
    
    // Create audio level bars
    self.audioLevelBars = [NSMutableArray array];
    for (int i = 0; i < 10; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(2 + (i * 10), 2, 8, 8)];
        bar.backgroundColor = [UIColor greenColor];
        bar.layer.cornerRadius = 1;
        bar.alpha = 0.3; // Dim by default
        [self.audioLevelMeter addSubview:bar];
        [self.audioLevelBars addObject:bar];
    }
    
    // Location label
    self.locationLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 210, 65, 200, 22)];
    self.locationLabel.textColor = [UIColor whiteColor];
    self.locationLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.locationLabel.textAlignment = NSTextAlignmentRight;
    self.locationLabel.text = @"Location: --";
    self.locationLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.locationLabel.layer.shouldRasterize = YES;
    self.locationLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
    [self.view addSubview:self.locationLabel];
    
    // UTC Time label
    self.utcTimeLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 210, 90, 200, 22)];
    self.utcTimeLabel.textColor = [UIColor whiteColor];
    self.utcTimeLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.utcTimeLabel.textAlignment = NSTextAlignmentRight;
    [self updateUTCTime];
    self.utcTimeLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.utcTimeLabel.layer.shouldRasterize = YES;
    self.utcTimeLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
    [self.view addSubview:self.utcTimeLabel];
    
    // Stream info label
    self.streamInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.frame.size.width - 210, 115, 200, 22)];
    self.streamInfoLabel.textColor = [UIColor whiteColor];
    self.streamInfoLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.streamInfoLabel.textAlignment = NSTextAlignmentRight;
    self.streamInfoLabel.text = @"";
    self.streamInfoLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.streamInfoLabel.layer.shouldRasterize = YES;
    self.streamInfoLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
    self.streamInfoLabel.hidden = YES;
    [self.view addSubview:self.streamInfoLabel];
    
    // Start UTC timer
    self.utcTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateUTCTime) userInfo:nil repeats:YES];
    
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
    
    // Camera button removed - stream button will take its place
    
    // Interval button removed
    
    // MPEG-4 Stream button - positioned where camera button was
    CGFloat streamButtonSize = 44;
    self.streamButton = [[UIButton alloc] initWithFrame:CGRectMake(20, self.view.frame.size.height - streamButtonSize - 50, streamButtonSize, streamButtonSize)];
    self.streamButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
    self.streamButton.layer.cornerRadius = streamButtonSize / 2;
    [self.streamButton setImage:[self broadcastIcon] forState:UIControlStateNormal];
    self.streamButton.tintColor = [UIColor whiteColor];
    [self.streamButton addTarget:self action:@selector(streamButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.streamButton];
    
    // Share button - positioned above regenerate button
    UIButton *shareButton = [[UIButton alloc] initWithFrame:CGRectMake(20, self.view.frame.size.height - streamButtonSize - 200, streamButtonSize, streamButtonSize)];
    shareButton.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.8];
    shareButton.layer.cornerRadius = streamButtonSize / 2;
    [shareButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    shareButton.tintColor = [UIColor whiteColor];
    [shareButton addTarget:self action:@selector(shareButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:shareButton];
    
    // Regenerate URL button - positioned above title button
    UIButton *regenerateButton = [[UIButton alloc] initWithFrame:CGRectMake(20, self.view.frame.size.height - streamButtonSize - 150, streamButtonSize, streamButtonSize)];
    regenerateButton.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.8];
    regenerateButton.layer.cornerRadius = streamButtonSize / 2;
    [regenerateButton setImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] forState:UIControlStateNormal];
    regenerateButton.tintColor = [UIColor whiteColor];
    [regenerateButton addTarget:self action:@selector(regenerateButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:regenerateButton];
    
    // Title button - positioned above stream button
    UIButton *titleButton = [[UIButton alloc] initWithFrame:CGRectMake(20, self.view.frame.size.height - streamButtonSize - 100, streamButtonSize, streamButtonSize)];
    titleButton.backgroundColor = [[UIColor systemGrayColor] colorWithAlphaComponent:0.8];
    titleButton.layer.cornerRadius = streamButtonSize / 2;
    [titleButton setTitle:@"T" forState:UIControlStateNormal];
    titleButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleButton.tintColor = [UIColor whiteColor];
    [titleButton addTarget:self action:@selector(titleButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:titleButton];
}





#pragma mark - App Lifecycle

- (void)appWillTerminate:(NSNotification *)notification {
    RLog(RptrLogAreaHLS | RptrLogAreaLifecycle, @"App will terminate - stopping HLS server gracefully");
    
    // Stop streaming first
    if (self.isStreaming) {
        [self stopStreaming];
    }
    
    // Stop the HLS server
    if (self.hlsServer) {
        [self.hlsServer stopServer];
        RLog(RptrLogAreaHLS, @"HLS server stopped");
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
    
    RLog(RptrLogAreaHLS | RptrLogAreaLifecycle, @"App termination cleanup completed");
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    RLog(RptrLogAreaMemory, @"Received memory warning in ViewController");
    
    // Clear any cached CIContext
    if (self.ciContext) {
        self.ciContext = nil;
        RLog(RptrLogAreaMemory, @"Cleared CIContext");
    }
    
    // Clear activity scores to free memory
    [self.cameraActivityScores removeAllObjects];
    
    // If not currently streaming, clear more aggressively
    if (!self.isStreaming) {
        // Clear preview layer to free GPU memory
        if (self.previewLayer) {
            [self.previewLayer removeFromSuperlayer];
            self.previewLayer = nil;
            RLog(RptrLogAreaMemory, @"Removed preview layer to free GPU memory");
        }
    }
    
    // Force garbage collection of any autorelease pools
    @autoreleasepool {
        // This forces the pool to drain
    }
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    RLog(RptrLogAreaHLS | RptrLogAreaLifecycle, @"App entered background - pausing streaming");
    
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
    if (self.audioDataOutput) {
        [self.audioDataOutput setSampleBufferDelegate:nil queue:nil];
    }
    
    // Remove all observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
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
    [self.utcTimer invalidate];
    [self.burstTimer invalidate];
    [self.cameraEvaluationTimer invalidate];
    [self.locationUpdateTimer invalidate];
    
    // Stop location updates
    [self.locationManager stopUpdatingLocation];
    
    // Clean up notifications
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

#pragma mark - Camera Selection

// Camera switching functionality has been removed

// Clock icon has been removed

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
    
    return image2;
}

- (void)copyButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < self.endpointLabels.count) {
        UILabel *label = self.endpointLabels[index];
        NSString *url = label.text;
        
        [[UIPasteboard generalPasteboard] setString:url];
        
        // Flash the button to indicate copy
        UIColor *originalColor = sender.backgroundColor;
        sender.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.6];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sender.backgroundColor = originalColor;
        });
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
        RLog(RptrLogAreaHLS | RptrLogAreaError, @"Exception in streamButtonTapped: %@", exception);
        RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Stack trace: %@", exception.callStackSymbols);
        // Try to recover
        self.isStreaming = NO;
        [self stopStreaming];
    }
}

- (void)shareButtonTapped:(UIButton *)sender {
    if (!self.isStreaming) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stream Not Active"
                                                                       message:@"Start streaming first to share the URL"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:okAction];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    // Construct the full stream URL
    NSArray<NSString *> *urls = [self.hlsServer getServerURLs];
    if (urls.count == 0) {
        return;
    }
    
    NSString *urlString = urls.firstObject;
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *baseURL = [NSString stringWithFormat:@"%@://%@:%@", 
                        url.scheme ?: @"http",
                        url.host ?: @"localhost",
                        url.port ?: @(self.hlsServer.port)];
    
    NSString *fullStreamURL = [NSString stringWithFormat:@"%@/view/%@", baseURL, self.hlsServer.randomPath];
    
    // Create activity items
    NSMutableArray *activityItems = [NSMutableArray array];
    
    // Add the URL
    [activityItems addObject:fullStreamURL];
    
    // Add a message with the title if available
    if (self.hlsServer.streamTitle && self.hlsServer.streamTitle.length > 0) {
        NSString *shareMessage = [NSString stringWithFormat:@"Watch \"%@\" live: %@", self.hlsServer.streamTitle, fullStreamURL];
        [activityItems addObject:shareMessage];
    }
    
    // Create the activity view controller
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:activityItems
                                                                             applicationActivities:nil];
    
    // Configure excluded activities (optional)
    activityVC.excludedActivityTypes = @[
        UIActivityTypeAddToReadingList,
        UIActivityTypeAssignToContact,
        UIActivityTypePrint,
        UIActivityTypeSaveToCameraRoll
    ];
    
    // For iPad, we need to set the popover presentation controller
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = sender;
        activityVC.popoverPresentationController.sourceRect = sender.bounds;
    }
    
    // Present the share sheet
    [self presentViewController:activityVC animated:YES completion:^{
        RLog(RptrLogAreaUI, @"Share sheet presented with URL: %@", fullStreamURL);
    }];
}

- (void)preloadUIComponents {
    // Only preload if we haven't already
    static BOOL keyboardPreloaded = NO;
    if (keyboardPreloaded) {
        return;
    }
    
    RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Starting keyboard and alert controller preload...");
    
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
    
    // Immediately dismiss it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [dummyTextField resignFirstResponder];
        [dummyTextField removeFromSuperview];
        
        // Re-enable animations
        [UIView setAnimationsEnabled:YES];
        
        keyboardPreloaded = YES;
        RLog(RptrLogAreaUI | RptrLogAreaDebug, @"Keyboard and alert controller preloaded successfully");
    });
}

- (void)titleButtonTapped:(UIButton *)sender {
    // Disable the button immediately to prevent multiple taps
    sender.enabled = NO;
    
    // Get current title directly - atomic property access is fast
    NSString *currentTitle = [self.hlsServer getStreamTitle];
    
    // Create the alert controller on main thread
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set Stream Title"
                                                                   message:@"Enter a title for your stream"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    // Configure the text field
    __weak typeof(self) weakSelf = self;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Stream Title";
        textField.text = currentTitle ?: @"";
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        textField.enablesReturnKeyAutomatically = YES;
        textField.returnKeyType = UIReturnKeyDone;
    }];
    
    // Create the set action
    UIAlertAction *setAction = [UIAlertAction actionWithTitle:@"Set" 
                                                        style:UIAlertActionStyleDefault 
                                                      handler:^(UIAlertAction *action) {
        NSString *newTitle = alert.textFields.firstObject.text;
        if (newTitle.length > 0 && weakSelf) {
            // Update the title using thread-safe method
            [weakSelf.hlsServer setStreamTitleAsync:newTitle];
            RLog(RptrLogAreaUI, @"Stream title updated to: %@", newTitle);
        }
    }];
    
    // Create the cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" 
                                                            style:UIAlertActionStyleCancel 
                                                          handler:nil];
    
    // Add actions
    [alert addAction:cancelAction];
    [alert addAction:setAction];
    
    // Present the alert
    [self presentViewController:alert animated:YES completion:^{
        // Re-enable the button after presentation
        sender.enabled = YES;
    }];
}

- (void)regenerateButtonTapped:(UIButton *)sender {
    // Create confirmation alert
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Regenerate Stream URL?"
                                                                   message:@"This will create a new stream URL and disconnect all current viewers. You will need to share the new URL with anyone watching."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    // Create the regenerate action
    UIAlertAction *regenerateAction = [UIAlertAction actionWithTitle:@"Regenerate" 
                                                               style:UIAlertActionStyleDestructive 
                                                             handler:^(UIAlertAction *action) {
        // Force stop streaming if active
        if (self.isStreaming) {
            RLog(RptrLogAreaUI, @"Stopping streaming before URL regeneration");
            [self stopStreaming];
        }
        
        // Regenerate the random path
        [self.hlsServer regenerateRandomPath];
        
        // Update the displayed URLs
        [self updateStreamingURLs];
        
        RLog(RptrLogAreaUI, @"Stream URL regenerated");
        
        // Show a brief confirmation
        UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"URL Regenerated"
                                                                            message:@"New stream URL created. All viewers have been disconnected. Streaming has been stopped."
                                                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
        [confirmAlert addAction:okAction];
        [self presentViewController:confirmAlert animated:YES completion:nil];
    }];
    
    // Create the cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" 
                                                            style:UIAlertActionStyleCancel 
                                                          handler:nil];
    
    // Add actions
    [alert addAction:cancelAction];
    [alert addAction:regenerateAction];
    
    // Present the alert
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startStreaming {
    RLog(RptrLogAreaHLS, @"startStreaming called");
    
    // Server should already be running from app launch
    if (!self.hlsServer) {
        RLog(RptrLogAreaHLS | RptrLogAreaError, @"HLS server not initialized");
        return;
    }
    
    // Prepare the asset writer for streaming (needed after URL regeneration)
    [self.hlsServer prepareForStreaming];
    
    // Just set the streaming flag - server is already running
    self.isStreaming = YES;
    self.streamButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.8];
    
    // Update LED to green
    self.streamingLED.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0];
    
    // Show audio meter
    self.audioLevelMeter.hidden = NO;
    
    // Notify delegate to start accepting video/audio samples
    RLog(RptrLogAreaHLS, @"Starting HLS streaming (server already running)");
    
    // Debug: Verify video data output is ready
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"============ STREAMING STARTED ============");
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"self.videoDataOutput: %@", self.videoDataOutput);
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Delegate: %@", self.videoDataOutput.sampleBufferDelegate);
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"isStreaming: %@", self.isStreaming ? @"YES" : @"NO");
    
    // Check all video data outputs
    RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Checking all video data outputs:");
    for (NSString *cameraID in self.videoDataOutputs) {
        AVCaptureVideoDataOutput *output = self.videoDataOutputs[cameraID];
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"  Camera %@: Output=%@, Delegate=%@", 
                  cameraID, output, output.sampleBufferDelegate);
            
            // Check connection
            AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"  Connection: %@, Active: %@, Enabled: %@",
                  connection, 
                  connection.isActive ? @"YES" : @"NO",
                  connection.isEnabled ? @"YES" : @"NO");
        }
        
        // Check current capture session
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Current capture session: %@", self.captureSession);
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Session running: %@", self.captureSession.isRunning ? @"YES" : @"NO");
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"========================================");
        
        // Add pulsing animation
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        animation.duration = 1.0;
        animation.repeatCount = HUGE_VALF;
        animation.autoreverses = YES;
        animation.fromValue = @0.8;
        animation.toValue = @0.3;
        [self.streamButton.layer addAnimation:animation forKey:@"pulse"];
        
        RLog(RptrLogAreaHLS, @"HLS streaming started on port %lu", (unsigned long)self.hlsServer.port);
        
        // Log network interface being used
        NSString *cellularIP = [self getCellularIPAddress];
        NSString *wifiIP = [self getWiFiIPAddress];
        RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Available interfaces - Cellular: %@, WiFi: %@", 
              cellularIP ?: @"Not available", 
              wifiIP ?: @"Not available");
}

- (void)stopStreaming {
    // Stop streaming flag to prevent new frames being sent
    self.isStreaming = NO;
    
    // Update UI
    self.streamButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
    [self.streamButton.layer removeAnimationForKey:@"pulse"];
    self.streamInfoLabel.hidden = YES;
    
    // Update LED to gray
    self.streamingLED.backgroundColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0];
    
    // Hide audio meter
    self.audioLevelMeter.hidden = YES;
    
    // Tell HLS server to stop asset writer (but keep HTTP server running)
    if (self.hlsServer) {
        [self.hlsServer stopStreaming];
    }
    
    RLog(RptrLogAreaHLS, @"HLS streaming stopped (server still running)");
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
    NSArray *urls = [self.hlsServer getServerURLs];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Remove old endpoint labels and buttons
        for (UILabel *label in self.endpointLabels) {
            [label removeFromSuperview];
        }
        for (UIButton *button in self.endpointCopyButtons) {
            [button removeFromSuperview];
        }
        [self.endpointLabels removeAllObjects];
        [self.endpointCopyButtons removeAllObjects];
        
        // Create endpoint label for /view with random path
        NSString *viewPath = [NSString stringWithFormat:@"/view/%@", self.hlsServer.randomPath];
        NSArray *endpoints = @[viewPath];
        CGFloat yOffset = 40;
        
        for (NSString *urlString in urls) {
            // Extract base URL (IP and port)
            NSURL *url = [NSURL URLWithString:urlString];
            NSString *baseURL = [NSString stringWithFormat:@"%@://%@:%@", 
                                url.scheme ?: @"http",
                                url.host ?: @"localhost",
                                url.port ?: @(self.hlsServer.port)];
            
            // Create labels for each endpoint
            for (NSString *endpoint in endpoints) {
                NSString *fullURL = [baseURL stringByAppendingString:endpoint];
                
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
                [copyButton setImage:[self copyIcon] forState:UIControlStateNormal];
                copyButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
                copyButton.layer.cornerRadius = 4;
                copyButton.tag = self.endpointLabels.count - 1;
                [copyButton addTarget:self action:@selector(copyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
                copyButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
                [self.view addSubview:copyButton];
                [self.endpointCopyButtons addObject:copyButton];
                
                yOffset += 22;
            }
            
            // Only show first URL's endpoints
            break;
        }
        
        self.streamInfoLabel.text = [NSString stringWithFormat:@"HLS: Port %lu", 
                                     (unsigned long)self.hlsServer.port];
        self.streamInfoLabel.hidden = NO;
        
        // Log the URLs but don't show alert - it might be blocking
        RLog(RptrLogAreaHLS, @"Stream started - URLs:");
        for (NSString *url in urls) {
            RLog(RptrLogAreaHLS, @"  %@", url);
        }
    });
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
        return nil;
    }
}

- (void)hlsServerDidStop {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamInfoLabel.hidden = YES;
        
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
        RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Client connected: %@", clientAddress);
        self.streamInfoLabel.text = [NSString stringWithFormat:@"HLS: %lu clients", 
                                     (unsigned long)self.hlsServer.connectedClients];
    });
}

- (void)hlsServer:(id)server clientDisconnected:(NSString *)clientAddress {
    dispatch_async(dispatch_get_main_queue(), ^{
        RLog(RptrLogAreaHLS | RptrLogAreaNetwork, @"Client disconnected: %@", clientAddress);
        NSUInteger clientCount = self.hlsServer.connectedClients;
        if (clientCount > 0) {
            self.streamInfoLabel.text = [NSString stringWithFormat:@"HLS: %lu clients", 
                                         (unsigned long)clientCount];
        } else {
            self.streamInfoLabel.text = [NSString stringWithFormat:@"HLS: Port %lu", 
                                         (unsigned long)self.hlsServer.port];
        }
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

// Interval button functionality has been removed

- (CGFloat)videoRotationAngleFromDeviceOrientation {
    // Always return 90 degrees to lock orientation to landscape right
    return 90;
}

// Override interface orientation methods
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)shouldAutorotate {
    return NO; // Prevent auto-rotation
}
#pragma clang diagnostic pop

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

// Override to fix UIAlertController performance issues
// This helps prevent the ~700ms delay when presenting/dismissing alerts
- (BOOL)canBecomeFirstResponder {
    return YES;
}

#pragma mark - Orientation Enforcement

- (void)enforceImmediateLandscapeOrientation {
    // Force device orientation change immediately
    if (@available(iOS 16.0, *)) {
        // iOS 16+ approach - request geometry update
        NSArray *connectedScenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        UIWindowScene *windowScene = (UIWindowScene *)connectedScenes.firstObject;
        if (windowScene) {
            UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
            geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscapeRight;
            
            [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError * _Nonnull error) {
                RLog(RptrLogAreaUI | RptrLogAreaError, @"Failed to enforce landscape orientation: %@", error.localizedDescription);
            }];
        }
    } else {
        // iOS 15 and earlier - use device orientation
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeRight) forKey:@"orientation"];
    }
    
    // Also ensure the view controller reports correct orientation
    [self setNeedsUpdateOfSupportedInterfaceOrientations];
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
    CGSize renderSize = naturalSize;
    
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
    if (self.locationLabel.text && ![self.locationLabel.text isEqualToString:@"Location: --"]) {
        // Extract just the coordinates
        locationText = [NSString stringWithFormat:@"Loc: %@", self.locationLabel.text];
    }
    
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
            RLog(RptrLogAreaVideo | RptrLogAreaError, @"Export failed: %@", exportSession.error);
            completion(nil);
        }
    }];
}

#pragma mark - Helper Methods

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

- (void)updateUTCTime {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"dd-MM-yy HH:mm:ss";
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    self.utcTimeLabel.text = [NSString stringWithFormat:@"%@ UTC", [formatter stringFromDate:[NSDate date]]];
}

- (void)requestLocationUpdate {
    // Request a single location update
    CLAuthorizationStatus locationStatus = self.locationManager.authorizationStatus;
    if (locationStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
        locationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        RLog(RptrLogAreaUI | RptrLogAreaLocation | RptrLogAreaDebug, @"Requesting location update");
        
        // Use requestLocation for a single update instead of continuous updates
        if ([self.locationManager respondsToSelector:@selector(requestLocation)]) {
            [self.locationManager requestLocation];
        } else {
            // Fallback for older iOS versions - start and stop updates
            [self.locationManager startUpdatingLocation];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.locationManager stopUpdatingLocation];
            });
        }
    } else {
        RLog(RptrLogAreaUI | RptrLogAreaLocation | RptrLogAreaDebug, @"Location permission not granted, skipping update");
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (location) {
        self.currentLocation = location;
        NSString *latLon = [NSString stringWithFormat:@"%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude];
        self.locationLabel.text = latLon;
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
    RLog(RptrLogAreaUI | RptrLogAreaLocation | RptrLogAreaError, @"Location manager failed with error: %@", error.localizedDescription);
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

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // Force layout update before animation to prevent duplication
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Clear any drawing artifacts
        [self.view.layer setNeedsDisplay];
        
        self.previewLayer.frame = self.view.bounds;
        
        // Update info labels position
        self.locationLabel.frame = CGRectMake(size.width - 210, 65, 200, 22);
        self.utcTimeLabel.frame = CGRectMake(size.width - 210, 90, 200, 22);
        self.streamInfoLabel.frame = CGRectMake(size.width - 210, 115, 200, 22);
        
        // Update endpoint labels and copy buttons
        CGFloat yOffset = 40;
        for (NSInteger i = 0; i < self.endpointLabels.count; i++) {
            UILabel *label = self.endpointLabels[i];
            UIButton *button = self.endpointCopyButtons[i];
            
            label.frame = CGRectMake(size.width - 280, yOffset, 250, 20);
            button.frame = CGRectMake(size.width - 25, yOffset, 20, 20);
            
            yOffset += 22;
        }
        
        // Update stream button position
        CGFloat streamButtonSize = 44;
        self.streamButton.frame = CGRectMake(20, size.height - streamButtonSize - 50, streamButtonSize, streamButtonSize);
        
        // Interval button removed
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Force final layout update after rotation to clean up any artifacts
        [self.view setNeedsDisplay];
        [CATransaction flush];
    }];
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
    
    RLog(RptrLogAreaCamera | RptrLogAreaSession | RptrLogAreaError, @"Session interrupted for camera %@, reason: %ld", sessionID, (long)reason);
    
    switch (reason) {
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
            RLog(RptrLogAreaCamera | RptrLogAreaError, @"Video device not available in background");
            break;
        case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
            RLog(RptrLogAreaAudio | RptrLogAreaError, @"Audio device in use by another client");
            break;
        case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
            RLog(RptrLogAreaVideo | RptrLogAreaError, @"Video device in use by another client");
            break;
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
            RLog(RptrLogAreaVideo | RptrLogAreaError, @"Video device not available with multiple foreground apps");
            break;
        default:
            break;
    }
}

- (void)sessionInterruptionEnded:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    RLog(RptrLogAreaCamera | RptrLogAreaSession, @"Session interruption ended for: %@", session);
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
    
    RLog(RptrLogAreaCamera | RptrLogAreaSession | RptrLogAreaError, @"Session runtime error for camera %@ (%@): %@", sessionID, cameraName, error.localizedDescription);
    RLog(RptrLogAreaError | RptrLogAreaDebug, @"Error domain: %@, code: %ld", error.domain, (long)error.code);
    RLog(RptrLogAreaError | RptrLogAreaDebug, @"Error userInfo: %@", error.userInfo);
    
    // Check if it's a multi-cam session
    if (@available(iOS 13.0, *)) {
        if ([session isKindOfClass:[AVCaptureMultiCamSession class]]) {
            RLog(RptrLogAreaCamera | RptrLogAreaError, @"Error occurred in multi-cam session");
            
            // If recording error, check movie outputs
            if ([error.localizedDescription containsString:@"Cannot Record"]) {
                RLog(RptrLogAreaVideo | RptrLogAreaError, @"Recording error detected. Checking movie outputs...");
                
                for (NSString *camID in self.movieFileOutputs) {
                    AVCaptureMovieFileOutput *output = self.movieFileOutputs[camID];
                    if (!output) {
                        RLog(RptrLogAreaVideo | RptrLogAreaError | RptrLogAreaDebug, @"Movie output for %@: Not found", camID);
                        continue;
                    }
                    RLog(RptrLogAreaVideo | RptrLogAreaDebug, @"Movie output for %@:", camID);
                    RLog(RptrLogAreaVideo | RptrLogAreaDebug, @"  - isRecording: %@", output.isRecording ? @"YES" : @"NO");
                    RLog(RptrLogAreaVideo | RptrLogAreaDebug, @"  - connection count: %lu", (unsigned long)output.connections.count);
                    
                    // Check each connection
                    for (AVCaptureConnection *connection in output.connections) {
                        RLog(RptrLogAreaVideo | RptrLogAreaDebug, @"  - Connection active: %@, enabled: %@", 
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
            RLog(RptrLogAreaHLS | RptrLogAreaError, @"ERROR: Received NULL sample buffer");
            return;
        }
    
    // Video orientation is now set during configuration, no need to set it here
    
    // Debug: Log any call to this method
    static int totalCalls = 0;
    totalCalls++;
    if (totalCalls <= 5) {
        RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"captureOutput called! Call #%d, Output class: %@", 
              totalCalls, NSStringFromClass([output class]));
    }
    
    // Log first frame to verify delegate is being called
    static BOOL firstFrameLogged = NO;
    if (!firstFrameLogged && output == self.videoDataOutput) {
        firstFrameLogged = YES;
        RLog(RptrLogAreaHLS | RptrLogAreaVideo, @"FIRST FRAME RECEIVED - Video data output delegate is working!");
        RLog(RptrLogAreaHLS | RptrLogAreaVideo | RptrLogAreaDebug, @"Output: %@, Connection active: %@, Streaming: %@",
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
            RLog(RptrLogAreaHLS | RptrLogAreaVideo, @"ViewController sending frame %d to HLS server", frameCount);
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"HLS server instance: %@", self.hlsServer);
            RLog(RptrLogAreaHLS | RptrLogAreaDebug, @"Sample buffer valid: %@", sampleBuffer ? @"YES" : @"NO");
        }
        
        // Ensure sample buffer is valid before processing
        HLSAssetWriterServer *hlsServer = self.hlsServer; // Local strong reference
        if (hlsServer && sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
            @try {
                // Stream video directly without overlays
                // Orientation is now forced to landscape at the connection level
                [hlsServer processVideoSampleBuffer:sampleBuffer];
            } @catch (NSException *exception) {
                RLog(RptrLogAreaHLS | RptrLogAreaVideo | RptrLogAreaError, @"Exception processing video frame: %@", exception);
                RLog(RptrLogAreaHLS | RptrLogAreaError | RptrLogAreaDebug, @"Reason: %@", exception.reason);
                // Don't stop streaming on single frame error
            }
        } else {
            if (!CMSampleBufferIsValid(sampleBuffer)) {
                RLog(RptrLogAreaHLS | RptrLogAreaVideo | RptrLogAreaError, @"WARNING: Invalid sample buffer received");
            } else {
                RLog(RptrLogAreaHLS | RptrLogAreaVideo | RptrLogAreaError, @"WARNING: Cannot send frame - hlsServer=%@, sampleBuffer=%@", 
                      self.hlsServer, sampleBuffer ? @"Valid" : @"NULL");
            }
        }
    }
    
    // Handle audio output for streaming
    if (self.isStreaming && output == self.audioDataOutput) {
        HLSAssetWriterServer *hlsServer = self.hlsServer; // Local strong reference
        if (hlsServer && sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
            @try {
                [hlsServer processAudioSampleBuffer:sampleBuffer];
                
                // Calculate audio level for meter
                [self calculateAudioLevelFromSampleBuffer:sampleBuffer];
            } @catch (NSException *exception) {
                RLog(RptrLogAreaHLS | RptrLogAreaAudio | RptrLogAreaError, @"Exception processing audio frame: %@", exception);
                // Don't stop streaming on single frame error
            }
        }
        CFRelease(sampleBuffer);
        return; // Audio doesn't need activity monitoring
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
    
    // Calculate average brightness
    CGFloat brightness = [self calculateBrightnessForImage:ciImage];
    
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
    RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"Camera %@ activity score: %.3f (motion: %.1f, light: %.1f, brightness: %.3f)", 
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
        RLog(RptrLogAreaVideo | RptrLogAreaError, @"Cannot calculate brightness for nil image");
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
    
    // Create CIContext if needed
    if (!self.ciContext) {
        self.ciContext = [CIContext context];
        NSAssert(self.ciContext != nil, @"Failed to create CIContext");
    }
    
    // Render to a 1x1 pixel to get average color
    CGRect outputExtent = CGRectMake(0, 0, 1, 1);
    CGImageRef cgImage = [self.ciContext createCGImage:outputImage fromRect:outputExtent];
    
    if (!cgImage) {
        RLog(RptrLogAreaVideo | RptrLogAreaError, @"Failed to create CGImage from CIImage");
        return 0;
    }
    
    // Get pixel data
    unsigned char pixel[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel,
                                                 1, 1,
                                                 8, 4,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), cgImage);
    CGContextRelease(context);
    CGImageRelease(cgImage);
    
    // Calculate brightness from RGB values
    CGFloat brightness = (pixel[0] * 0.299 + pixel[1] * 0.587 + pixel[2] * 0.114) / 255.0;
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
    RLog(RptrLogAreaVideo | RptrLogAreaDebug, @"Motion variance: %.6f, detected: %@", variance, motion ? @"YES" : @"NO");
    return motion;
}

- (void)evaluateAndSwitchToBestCamera {
    
    RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"\n=== Camera Evaluation ===");
    
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
            RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"Camera %@ not yet evaluated", camera.localizedName);
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
        CGFloat score = scoreNumber ? [scoreNumber floatValue] : 0.0;
        
        RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"Camera %@ score: %.3f %@", 
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
        RLog(RptrLogAreaCamera, @"Switching to %@ (score: %.3f) from %@ (score: %.3f) - %.0f%% better", 
              bestCamera.localizedName, bestScore,
              self.currentCameraDevice.localizedName, currentScore,
              ((bestScore - currentScore) / currentScore) * 100);
        
        // Camera switching disabled
        // [self switchToCamera:bestCamera];
    } else {
        RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"Keeping current camera %@ (score: %.3f, best: %.3f)", 
              self.currentCameraDevice.localizedName, currentScore, bestScore);
        
        // If current camera has very low score, force evaluation of other camera
        if (currentScore < 0.1) {
            RLog(RptrLogAreaCamera, @"Current camera has very low activity, forcing alternate camera");
            [self tryAlternateCameraWithEvaluation];
        }
    }
    
    RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"=== End Evaluation ===\n");
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
            RLog(RptrLogAreaCamera, @"Switching to alternate camera: %@ for evaluation", camera.localizedName);
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
            RLog(RptrLogAreaCamera | RptrLogAreaDebug, @"Decaying inactive camera score: %.3f -> %.3f", score, decayedScore);
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


- (void)calculateAudioLevelFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    if (numSamples == 0) return;
    
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return;
    
    size_t length;
    char *dataPointer;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &length, &dataPointer);
    if (status != noErr) return;
    
    // Assuming 16-bit PCM audio
    int16_t *samples = (int16_t *)dataPointer;
    size_t sampleCount = length / sizeof(int16_t);
    
    float sum = 0.0;
    for (size_t i = 0; i < sampleCount; i++) {
        float sample = samples[i] / 32768.0f; // Normalize to -1.0 to 1.0
        sum += sample * sample;
    }
    
    float rms = sqrtf(sum / sampleCount);
    float db = 20.0f * log10f(rms);
    
    // Convert to 0-1 range (assuming -40dB to 0dB range)
    float normalizedLevel = (db + 40.0f) / 40.0f;
    normalizedLevel = fmaxf(0.0f, fminf(1.0f, normalizedLevel));
    
    self.currentAudioLevel = normalizedLevel;
    
    // Update UI on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAudioLevelMeter];
    });
}

- (void)updateAudioLevelMeter {
    if (!self.isStreaming || self.audioLevelMeter.hidden) return;
    
    NSInteger activeBars = (NSInteger)(self.currentAudioLevel * self.audioLevelBars.count);
    
    for (NSInteger i = 0; i < self.audioLevelBars.count; i++) {
        UIView *bar = self.audioLevelBars[i];
        if (i < activeBars) {
            bar.alpha = 1.0;
            // Color gradient from green to yellow to red
            if (i < 6) {
                bar.backgroundColor = [UIColor greenColor];
            } else if (i < 8) {
                bar.backgroundColor = [UIColor yellowColor];
            } else {
                bar.backgroundColor = [UIColor redColor];
            }
        } else {
            bar.alpha = 0.3;
            bar.backgroundColor = [UIColor greenColor];
        }
    }
}

@end