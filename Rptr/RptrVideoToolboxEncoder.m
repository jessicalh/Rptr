//
//  RptrVideoToolboxEncoder.m
//  Rptr
//
//  VideoToolbox-based H.264 encoder implementation
//

#import "RptrVideoToolboxEncoder.h"
#import "RptrLogger.h"
#import "RptrH264Decoder.h"
#import "RptrSPSModifier.h"

@implementation RptrEncodedFrame
@end

@interface RptrVideoToolboxEncoder ()
@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) BOOL isEncoding;
@property (nonatomic, assign) BOOL forceKeyframeOnNext;
@property (nonatomic, assign) int64_t frameNumber;
@property (nonatomic, strong) NSData *sps;
@property (nonatomic, strong) NSData *pps;
@property (nonatomic, strong) dispatch_queue_t encoderQueue;
@end

@implementation RptrVideoToolboxEncoder

- (instancetype)initWithWidth:(NSInteger)width 
                        height:(NSInteger)height
                     frameRate:(NSInteger)frameRate
                       bitrate:(NSInteger)bitrate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _frameRate = frameRate;
        _bitrate = bitrate;
        _keyframeInterval = frameRate; // Default: 1 keyframe per second
        _encoderQueue = dispatch_queue_create("com.rptr.videoencoder", DISPATCH_QUEUE_SERIAL);
        _frameNumber = 0;
        
        RLogDIY(@"[VT-ENCODER] Initialized: %ldx%ld @ %ldfps, bitrate: %ld", 
                 (long)width, (long)height, (long)frameRate, (long)bitrate);
    }
    return self;
}

- (void)dealloc {
    [self stopEncoding];
}

#pragma mark - Compression Callback

static void compressionOutputCallback(void * _Nullable outputCallbackRefCon,
                                     void * _Nullable sourceFrameRefCon,
                                     OSStatus status,
                                     VTEncodeInfoFlags infoFlags,
                                     CMSampleBufferRef  _Nullable sampleBuffer) {
    if (status != noErr) {
        RLogError(@"[VT-ENCODER] Compression failed with status: %d", (int)status);
        return;
    }
    
    if (!sampleBuffer) {
        RLogError(@"[VT-ENCODER] No sample buffer in callback");
        return;
    }
    
    RptrVideoToolboxEncoder *encoder = (__bridge RptrVideoToolboxEncoder *)outputCallbackRefCon;
    [encoder handleEncodedSampleBuffer:sampleBuffer];
}

#pragma mark - Public Methods

- (BOOL)startEncoding {
    if (self.isEncoding) {
        RLogDIY(@"[VT-ENCODER] Already encoding");
        return YES;
    }
    
    // Create encoder specification for hardware acceleration
    CFMutableDictionaryRef encoderSpec = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    
    CFDictionarySetValue(encoderSpec,
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
        kCFBooleanTrue);
    CFDictionarySetValue(encoderSpec,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
        kCFBooleanFalse); // Fall back to software if needed
    
    // Create compression session
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        (int32_t)self.width,
        (int32_t)self.height,
        kCMVideoCodecType_H264,
        encoderSpec,
        NULL, // pixelBufferAttributes
        NULL, // compressedDataAllocator
        compressionOutputCallback,
        (__bridge void *)self,
        &_compressionSession);
    
    CFRelease(encoderSpec);
    
    if (status != noErr) {
        RLogError(@"[VT-ENCODER] Failed to create compression session: %d", (int)status);
        return NO;
    }
    
    // Configure session properties
    [self configureCompressionSession];
    
    // Prepare to encode
    status = VTCompressionSessionPrepareToEncodeFrames(self.compressionSession);
    if (status != noErr) {
        RLogError(@"[VT-ENCODER] Failed to prepare encoding: %d", (int)status);
        VTCompressionSessionInvalidate(self.compressionSession);
        CFRelease(self.compressionSession);
        self.compressionSession = NULL;
        return NO;
    }
    
    self.isEncoding = YES;
    self.frameNumber = 0;
    
    RLogDIY(@"[VT-ENCODER] Started encoding session");
    
    if ([self.delegate respondsToSelector:@selector(encoderDidStartSession:)]) {
        [self.delegate encoderDidStartSession:self];
    }
    
    return YES;
}

- (void)stopEncoding {
    if (!self.isEncoding || !self.compressionSession) {
        return;
    }
    
    RLogDIY(@"[VT-ENCODER] Stopping encoding session");
    
    // Flush any pending frames
    VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
    
    // Invalidate and release session
    VTCompressionSessionInvalidate(self.compressionSession);
    CFRelease(self.compressionSession);
    self.compressionSession = NULL;
    
    self.isEncoding = NO;
    
    if ([self.delegate respondsToSelector:@selector(encoderDidEndSession:)]) {
        [self.delegate encoderDidEndSession:self];
    }
}

- (void)configureCompressionSession {
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    // Profile level - Main Profile like Apple's sample streams
    // Apple's bipbop sample uses Main Profile (0x64) with Level 3.2 for 960x540
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_ProfileLevel,
        kVTProfileLevel_H264_Main_3_2);
    
    // Bitrate
    int bitrate = (int)self.bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);
    
    // Keyframe interval
    int keyframeInterval = (int)self.keyframeInterval;
    CFNumberRef keyframeIntervalRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyframeInterval);
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeIntervalRef);
    CFRelease(keyframeIntervalRef);
    
    // Frame rate
    int frameRate = (int)self.frameRate;
    CFNumberRef frameRateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &frameRate);
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_ExpectedFrameRate, frameRateRef);
    CFRelease(frameRateRef);
    
    // Allow frame reordering (B-frames) - NO for lowest latency
    VTSessionSetProperty(self.compressionSession,
        kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    
    RLogDIY(@"[VT-ENCODER] Configured: H.264 Main Profile Level 3.2, %d bps, keyframe every %d frames",
             bitrate, keyframeInterval);
}

#pragma mark - Encoding

- (void)encodeVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isEncoding || !self.compressionSession) {
        RLogDIY(@"[VT-ENCODER] Not encoding, dropping frame");
        return;
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        RLogError(@"[VT-ENCODER] No image buffer in sample");
        return;
    }
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    
    [self encodePixelBuffer:imageBuffer presentationTime:presentationTime duration:duration];
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer 
         presentationTime:(CMTime)presentationTime 
                 duration:(CMTime)duration {
    if (!self.isEncoding || !self.compressionSession) {
        return;
    }
    
    // Frame properties
    CFMutableDictionaryRef frameProperties = NULL;
    
    // Force keyframe if needed (for segment boundaries)
    if (self.forceKeyframeOnNext || (self.frameNumber % self.keyframeInterval == 0)) {
        frameProperties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(frameProperties,
            kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
        
        RLogDIY(@"[VT-ENCODER] Forcing keyframe at frame %lld", self.frameNumber);
        self.forceKeyframeOnNext = NO;
    }
    
    // Encode the frame
    VTEncodeInfoFlags infoFlagsOut;
    OSStatus status = VTCompressionSessionEncodeFrame(
        self.compressionSession,
        pixelBuffer,
        presentationTime,
        duration,
        frameProperties,
        NULL, // sourceFrameRefcon
        &infoFlagsOut);
    
    if (frameProperties) {
        CFRelease(frameProperties);
    }
    
    if (status != noErr) {
        RLogError(@"[VT-ENCODER] Failed to encode frame %lld: %d", self.frameNumber, (int)status);
        
        NSError *error = [NSError errorWithDomain:@"RptrVideoToolboxEncoder"
                                            code:status
                                        userInfo:@{NSLocalizedDescriptionKey: @"Failed to encode frame"}];
        [self.delegate encoder:self didEncounterError:error];
    }
    
    self.frameNumber++;
}

- (void)forceKeyframe {
    self.forceKeyframeOnNext = YES;
    RLogDIY(@"[VT-ENCODER] Will force keyframe on next frame");
}

- (void)flush {
    if (self.compressionSession) {
        VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
        RLogDIY(@"[VT-ENCODER] Flushed pending frames");
    }
}

#pragma mark - Handle Encoded Output

- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Check if this is a keyframe
    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef dependsOnOthers = CFDictionaryGetValue(attachment,
            kCMSampleAttachmentKey_DependsOnOthers);
        isKeyframe = (dependsOnOthers == kCFBooleanFalse);
    }
    
    // Get format description for parameter sets
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format && isKeyframe) {
        [self extractParameterSets:format];
    }
    
    // Extract NALUs from block buffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (blockBuffer) {
        [self extractNALUs:blockBuffer 
              sampleBuffer:sampleBuffer 
               isKeyframe:isKeyframe];
    }
}

- (void)extractParameterSets:(CMFormatDescriptionRef)format {
    // First check how many parameter sets exist
    size_t parameterSetCount = 0;
    int nalUnitHeaderLengthOut = 0;
    
    // OSStatus countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
    //     format, 0, NULL, NULL, &parameterSetCount, &nalUnitHeaderLengthOut);
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, 0, NULL, NULL, &parameterSetCount, &nalUnitHeaderLengthOut);
    
    RLogDIY(@"[VT-ENCODER] Total parameter sets: %zu, NAL header length: %d", 
            parameterSetCount, nalUnitHeaderLengthOut);
    
    // Extract SPS
    size_t spsSize = 0;
    size_t spsCount = 0;
    const uint8_t *spsData = NULL;
    
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, 0, &spsData, &spsSize, &spsCount, NULL);
    
    RLogDIY(@"[VT-ENCODER] SPS extraction status: %d, size: %zu, count: %zu", 
            (int)status, spsSize, spsCount);
    
    if (status == noErr && spsData && spsSize > 0) {
        NSData *newSPS = [NSData dataWithBytes:spsData length:spsSize];
        
        // Extract PPS
        size_t ppsSize = 0;
        size_t ppsCount = 0;
        const uint8_t *ppsData = NULL;
        
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, 1, &ppsData, &ppsSize, &ppsCount, NULL);
        
        if (status == noErr && ppsData && ppsSize > 0) {
            NSData *newPPS = [NSData dataWithBytes:ppsData length:ppsSize];
            
            // Add VUI parameters to SPS for Safari compatibility
            NSData *modifiedSPS = [RptrSPSModifier addVUIParametersToSPS:newSPS frameRate:self.frameRate];
            
            // Only notify if parameter sets changed
            if (![modifiedSPS isEqualToData:self.sps] || ![newPPS isEqualToData:self.pps]) {
                self.sps = modifiedSPS;
                self.pps = newPPS;
                
                RLogDIY(@"[VT-ENCODER] Extracted parameter sets - SPS: %lu bytes (modified from %lu), PPS: %lu bytes",
                        (unsigned long)modifiedSPS.length, (unsigned long)spsSize, (unsigned long)ppsSize);
                
                // Log hex dump of raw SPS/PPS for analysis
                const uint8_t *spsBytes = self.sps.bytes;
                NSMutableString *spsHex = [NSMutableString string];
                for (int i = 0; i < self.sps.length; i++) {
                    [spsHex appendFormat:@"%02X ", spsBytes[i]];
                }
                RLogDIY(@"[VT-ENCODER] SPS hex: %@", spsHex);
                
                const uint8_t *ppsBytes = self.pps.bytes;
                NSMutableString *ppsHex = [NSMutableString string];
                for (int i = 0; i < self.pps.length; i++) {
                    [ppsHex appendFormat:@"%02X ", ppsBytes[i]];
                }
                RLogDIY(@"[VT-ENCODER] PPS hex: %@", ppsHex);
                
                // Analyze original vs modified SPS for debugging
                [RptrSPSModifier analyzeSPS:newSPS label:@"Original VideoToolbox SPS"];
                [RptrSPSModifier analyzeSPS:modifiedSPS label:@"Modified SPS with VUI"];
                
                // Validate and log parameter sets using decoder
                NSString *analysisReport = [RptrH264Decoder generateDetailedReport:self.sps pps:self.pps];
                RLogDIY(@"[VT-ENCODER] Parameter Set Analysis:%@", analysisReport);
                
                // Check HLS compatibility
                NSMutableArray *hlsErrors = [NSMutableArray array];
                BOOL meetsHLS = [RptrH264Decoder meetsHLSRequirements:self.sps pps:self.pps errors:&hlsErrors];
                
                if (!meetsHLS) {
                    RLogError(@"[VT-ENCODER] Parameter sets DO NOT meet HLS requirements!");
                    for (NSString *error in hlsErrors) {
                        RLogError(@"[VT-ENCODER] HLS Error: %@", error);
                    }
                }
                
                [self.delegate encoder:self didEncodeParameterSets:self.sps pps:self.pps];
            }
        }
    }
}

- (void)extractNALUs:(CMBlockBufferRef)blockBuffer 
        sampleBuffer:(CMSampleBufferRef)sampleBuffer
         isKeyframe:(BOOL)isKeyframe {
    size_t totalLength = 0;
    size_t lengthAtOffset = 0;
    char *dataPointer = NULL;
    
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset,
                                                  &totalLength, &dataPointer);
    if (status != noErr) {
        RLogError(@"[VT-ENCODER] Failed to get data pointer: %d", (int)status);
        return;
    }
    
    // Get timing information
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    
    if (CMTIME_IS_INVALID(dts)) {
        dts = pts;
    }
    
    // For fMP4, we need to keep AVCC format (length-prefixed)
    // Just copy the entire block buffer as-is
    NSMutableData *frameData = [NSMutableData dataWithBytes:dataPointer length:totalLength];
    
    // For keyframes, prepend SPS and PPS in AVCC format
    if (isKeyframe && self.sps && self.pps) {
        NSMutableData *keyframeData = [NSMutableData data];
        
        // Add SPS with 4-byte length prefix
        uint32_t spsLength = CFSwapInt32HostToBig((uint32_t)self.sps.length);
        [keyframeData appendBytes:&spsLength length:4];
        [keyframeData appendData:self.sps];
        
        // Add PPS with 4-byte length prefix  
        uint32_t ppsLength = CFSwapInt32HostToBig((uint32_t)self.pps.length);
        [keyframeData appendBytes:&ppsLength length:4];
        [keyframeData appendData:self.pps];
        
        // Add the rest of the frame data
        [keyframeData appendData:frameData];
        frameData = keyframeData;
    }
    
    if (frameData.length > 0) {
        RptrEncodedFrame *frame = [[RptrEncodedFrame alloc] init];
        frame.data = frameData;
        frame.presentationTime = pts;
        frame.decodeTime = dts;
        frame.duration = duration;
        frame.isKeyframe = isKeyframe;
        frame.isParameterSet = NO;
        
        RLogDIY(@"[VT-ENCODER] Encoded frame: %lu bytes, keyframe: %@, pts: %.3f",
                 (unsigned long)frameData.length,
                 isKeyframe ? @"YES" : @"NO",
                 CMTimeGetSeconds(pts));
        
        [self.delegate encoder:self didEncodeFrame:frame];
    }
}

@end