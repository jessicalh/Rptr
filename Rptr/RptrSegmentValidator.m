//
//  RptrSegmentValidator.m
//  Rptr
//
//  Debug-only validator for fMP4 segments using iOS native APIs
//

#import "RptrSegmentValidator.h"
#import "RptrLogger.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

@implementation RptrSegmentValidationResult

- (instancetype)init {
    if (self = [super init]) {
        _isValid = YES;
        _errors = [NSMutableArray array];
        _info = [NSMutableDictionary dictionary];
    }
    return self;
}

@end

@implementation RptrSegmentValidator

+ (RptrSegmentValidationResult *)validateSegment:(NSData *)segmentData 
                                      initSegment:(NSData *)initSegment
                                   sequenceNumber:(uint32_t)sequenceNumber {
    
    RptrSegmentValidationResult *result = [[RptrSegmentValidationResult alloc] init];
    
    RLogDIY(@"[SEGMENT-VALIDATOR] ===== Validating Segment %u =====", sequenceNumber);
    RLogDIY(@"[SEGMENT-VALIDATOR] Segment size: %lu bytes", (unsigned long)segmentData.length);
    
    // 1. Parse box structure
    NSString *boxStructure = [self detailedBoxStructure:segmentData];
    RLogDIY(@"[SEGMENT-VALIDATOR] Box structure:\n%@", boxStructure);
    result.info[@"box_structure"] = boxStructure;
    
    // 2. Try AVAssetReader validation (most thorough)
    if (initSegment) {
        RLogDIY(@"[SEGMENT-VALIDATOR] Testing with AVAssetReader...");
        RptrSegmentValidationResult *avResult = [self validateWithAVAssetReader:segmentData 
                                                                     initSegment:initSegment];
        [result.errors addObjectsFromArray:avResult.errors];
        [result.info addEntriesFromDictionary:avResult.info];
        if (!avResult.isValid) {
            result.isValid = NO;
            RLogError(@"[SEGMENT-VALIDATOR] AVAssetReader validation FAILED");
        } else {
            RLogDIY(@"[SEGMENT-VALIDATOR] AVAssetReader validation PASSED");
        }
    }
    
    // 3. Try CMSampleBuffer validation
    RLogDIY(@"[SEGMENT-VALIDATOR] Testing with CMSampleBuffer APIs...");
    RptrSegmentValidationResult *cmResult = [self validateWithCMSampleBuffer:segmentData];
    [result.errors addObjectsFromArray:cmResult.errors];
    [result.info addEntriesFromDictionary:cmResult.info];
    if (!cmResult.isValid) {
        result.isValid = NO;
        RLogError(@"[SEGMENT-VALIDATOR] CMSampleBuffer validation FAILED");
    } else {
        RLogDIY(@"[SEGMENT-VALIDATOR] CMSampleBuffer validation PASSED");
    }
    
    // 4. Try VideoToolbox validation
    RLogDIY(@"[SEGMENT-VALIDATOR] Testing with VideoToolbox...");
    RptrSegmentValidationResult *vtResult = [self validateWithVideoToolbox:segmentData];
    [result.errors addObjectsFromArray:vtResult.errors];
    [result.info addEntriesFromDictionary:vtResult.info];
    if (!vtResult.isValid) {
        result.isValid = NO;
        RLogError(@"[SEGMENT-VALIDATOR] VideoToolbox validation FAILED");
    } else {
        RLogDIY(@"[SEGMENT-VALIDATOR] VideoToolbox validation PASSED");
    }
    
    // Summary
    RLogDIY(@"[SEGMENT-VALIDATOR] ===== Validation Summary =====");
    RLogDIY(@"[SEGMENT-VALIDATOR] Result: %@", result.isValid ? @"VALID" : @"INVALID");
    if (result.errors.count > 0) {
        RLogError(@"[SEGMENT-VALIDATOR] Errors: %@", [result.errors componentsJoinedByString:@", "]);
    }
    RLogDIY(@"[SEGMENT-VALIDATOR] =============================");
    
    return result;
}

+ (RptrSegmentValidationResult *)quickValidateSegment:(NSData *)segmentData {
    return [self validateWithCMSampleBuffer:segmentData];
}

+ (RptrSegmentValidationResult *)validateWithAVAssetReader:(NSData *)segmentData 
                                                initSegment:(NSData *)initSegment {
    
    RptrSegmentValidationResult *result = [[RptrSegmentValidationResult alloc] init];
    
    @try {
        // Combine init and media segments
        NSMutableData *completeData = [NSMutableData dataWithData:initSegment];
        [completeData appendData:segmentData];
        
        // Write to temp file (AVAssetReader needs a file URL)
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"segment_test_%u.mp4", arc4random()]];
        [completeData writeToFile:tempPath atomically:YES];
        NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
        
        // Create AVAsset and load its tracks asynchronously
        AVAsset *asset = [AVAsset assetWithURL:fileURL];
        
        // Load tracks asynchronously - this is crucial for AVAsset to work properly
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block NSError *loadError = nil;
        
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"playable", @"readable"] completionHandler:^{
            NSError *error = nil;
            AVKeyValueStatus tracksStatus = [asset statusOfValueForKey:@"tracks" error:&error];
            if (tracksStatus != AVKeyValueStatusLoaded) {
                loadError = error ?: [NSError errorWithDomain:@"RptrValidator" code:1 
                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to load tracks"}];
            }
            dispatch_semaphore_signal(semaphore);
        }];
        
        // Wait for loading to complete (with timeout)
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            [result.errors addObject:@"Timeout loading asset tracks"];
            result.isValid = NO;
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            return result;
        }
        
        if (loadError) {
            [result.errors addObject:[NSString stringWithFormat:@"Failed to load asset tracks: %@", 
                                      loadError.localizedDescription]];
            result.isValid = NO;
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            return result;
        }
        
        // Now try to create AVAssetReader
        NSError *readerError = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
        
        if (readerError) {
            [result.errors addObject:[NSString stringWithFormat:@"AVAssetReader creation failed: %@", 
                                      readerError.localizedDescription]];
            result.isValid = NO;
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            return result;
        }
        
        // Check if asset is readable
        if (!asset.readable) {
            [result.errors addObject:@"Asset is not readable"];
            result.isValid = NO;
        }
        
        // Now get video tracks after loading
        NSArray *allTracks = [asset tracks];
        RLogDIY(@"[SEGMENT-VALIDATOR] Total tracks found: %lu", (unsigned long)allTracks.count);
        for (AVAssetTrack *track in allTracks) {
            RLogDIY(@"[SEGMENT-VALIDATOR] Track %d: mediaType=%@, formatDescriptions=%@", 
                    track.trackID, track.mediaType, track.formatDescriptions);
        }
        
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            [result.errors addObject:@"No video tracks found"];
            result.isValid = NO;
        } else {
            AVAssetTrack *videoTrack = videoTracks.firstObject;
            result.info[@"naturalSize"] = [NSString stringWithFormat:@"%.0fx%.0f", 
                                           videoTrack.naturalSize.width, 
                                           videoTrack.naturalSize.height];
            result.info[@"nominalFrameRate"] = @(videoTrack.nominalFrameRate);
            result.info[@"timeRange"] = [NSString stringWithFormat:@"%.3f-%.3f", 
                                          CMTimeGetSeconds(videoTrack.timeRange.start),
                                          CMTimeGetSeconds(videoTrack.timeRange.duration)];
            
            // Try to read samples
            AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput 
                                                      assetReaderTrackOutputWithTrack:videoTrack
                                                      outputSettings:nil];
            [reader addOutput:trackOutput];
            
            if ([reader startReading]) {
                int sampleCount = 0;
                while (reader.status == AVAssetReaderStatusReading) {
                    CMSampleBufferRef sample = [trackOutput copyNextSampleBuffer];
                    if (sample) {
                        sampleCount++;
                        
                        // Log first sample timing
                        if (sampleCount == 1) {
                            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                            CMTime dts = CMSampleBufferGetDecodeTimeStamp(sample);
                            result.info[@"first_pts"] = @(CMTimeGetSeconds(pts));
                            result.info[@"first_dts"] = CMTIME_IS_VALID(dts) ? @(CMTimeGetSeconds(dts)) : @"invalid";
                        }
                        
                        CFRelease(sample);
                    } else {
                        break;
                    }
                }
                
                result.info[@"samples_read"] = @(sampleCount);
                
                if (reader.status == AVAssetReaderStatusFailed) {
                    [result.errors addObject:[NSString stringWithFormat:@"Reader failed: %@", 
                                              reader.error.localizedDescription]];
                    result.isValid = NO;
                } else if (sampleCount == 0) {
                    [result.errors addObject:@"No samples could be read"];
                    result.isValid = NO;
                }
            } else {
                [result.errors addObject:[NSString stringWithFormat:@"Failed to start reading: %@", 
                                          reader.error.localizedDescription]];
                result.isValid = NO;
            }
        }
        
        // Clean up
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        
    } @catch (NSException *exception) {
        [result.errors addObject:[NSString stringWithFormat:@"Exception: %@", exception.reason]];
        result.isValid = NO;
    }
    
    return result;
}

+ (RptrSegmentValidationResult *)validateWithCMSampleBuffer:(NSData *)segmentData {
    RptrSegmentValidationResult *result = [[RptrSegmentValidationResult alloc] init];
    
    @try {
        // Parse moof/mdat structure manually
        const uint8_t *bytes = segmentData.bytes;
        NSUInteger offset = 0;
        
        while (offset + 8 <= segmentData.length) {
            uint32_t size = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset));
            uint32_t type = *(uint32_t *)(bytes + offset + 4);
            
            if (type == 'moof' || type == CFSwapInt32HostToBig('moof')) {
                result.info[@"moof_found"] = @YES;
                result.info[@"moof_size"] = @(size);
                
                // Parse moof contents for tfdt
                NSUInteger moofOffset = offset + 8;
                NSUInteger moofEnd = offset + size;
                
                while (moofOffset + 8 <= moofEnd) {
                    uint32_t subSize = CFSwapInt32BigToHost(*(uint32_t *)(bytes + moofOffset));
                    uint32_t subType = *(uint32_t *)(bytes + moofOffset + 4);
                    
                    if (subType == 'tfdt' || subType == CFSwapInt32HostToBig('tfdt')) {
                        uint8_t version = bytes[moofOffset + 8];
                        uint64_t decodeTime = 0;
                        
                        if (version == 0) {
                            decodeTime = CFSwapInt32BigToHost(*(uint32_t *)(bytes + moofOffset + 12));
                        } else {
                            decodeTime = CFSwapInt64BigToHost(*(uint64_t *)(bytes + moofOffset + 12));
                        }
                        
                        result.info[@"tfdt_decode_time"] = @(decodeTime);
                        result.info[@"tfdt_seconds"] = @(decodeTime / 90000.0);
                        
                        // Check if decode time is reasonable
                        if (decodeTime > 90000 * 3600) { // More than 1 hour
                            [result.errors addObject:[NSString stringWithFormat:
                                @"tfdt decode time too large: %llu (%.2f seconds)", 
                                decodeTime, decodeTime / 90000.0]];
                            result.isValid = NO;
                        }
                        break;
                    }
                    
                    moofOffset += subSize;
                    if (subSize == 0) break;
                }
            } else if (type == 'mdat' || type == CFSwapInt32HostToBig('mdat')) {
                result.info[@"mdat_found"] = @YES;
                result.info[@"mdat_size"] = @(size);
            }
            
            offset += size;
            if (size == 0) break;
        }
        
        if (!result.info[@"moof_found"]) {
            [result.errors addObject:@"No moof box found"];
            result.isValid = NO;
        }
        if (!result.info[@"mdat_found"]) {
            [result.errors addObject:@"No mdat box found"];
            result.isValid = NO;
        }
        
    } @catch (NSException *exception) {
        [result.errors addObject:[NSString stringWithFormat:@"Exception: %@", exception.reason]];
        result.isValid = NO;
    }
    
    return result;
}

+ (RptrSegmentValidationResult *)validateWithVideoToolbox:(NSData *)segmentData {
    RptrSegmentValidationResult *result = [[RptrSegmentValidationResult alloc] init];
    
    @try {
        // Extract NAL units from mdat
        const uint8_t *bytes = segmentData.bytes;
        NSUInteger offset = 0;
        BOOL foundMdat = NO;
        
        while (offset + 8 <= segmentData.length) {
            uint32_t size = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset));
            uint32_t type = *(uint32_t *)(bytes + offset + 4);
            
            if (type == 'mdat' || type == CFSwapInt32HostToBig('mdat')) {
                foundMdat = YES;
                NSUInteger mdatOffset = offset + 8;
                NSUInteger mdatEnd = offset + size;
                int naluCount = 0;
                
                // Parse length-prefixed NAL units
                while (mdatOffset + 4 <= mdatEnd) {
                    uint32_t naluLength = CFSwapInt32BigToHost(*(uint32_t *)(bytes + mdatOffset));
                    mdatOffset += 4;
                    
                    if (mdatOffset + naluLength > mdatEnd) {
                        [result.errors addObject:@"Invalid NAL unit length"];
                        result.isValid = NO;
                        break;
                    }
                    
                    if (naluLength > 0) {
                        uint8_t naluType = bytes[mdatOffset] & 0x1F;
                        naluCount++;
                        
                        if (naluCount == 1) {
                            result.info[@"first_nalu_type"] = @(naluType);
                            result.info[@"first_nalu_type_name"] = [self naluTypeName:naluType];
                        }
                    }
                    
                    mdatOffset += naluLength;
                }
                
                result.info[@"nalu_count"] = @(naluCount);
                break;
            }
            
            offset += size;
            if (size == 0) break;
        }
        
        if (!foundMdat) {
            [result.errors addObject:@"No mdat box found for NAL parsing"];
            result.isValid = NO;
        }
        
    } @catch (NSException *exception) {
        [result.errors addObject:[NSString stringWithFormat:@"VideoToolbox validation exception: %@", exception.reason]];
        result.isValid = NO;
    }
    
    return result;
}

+ (NSString *)naluTypeName:(uint8_t)naluType {
    switch (naluType) {
        case 1: return @"Non-IDR slice";
        case 5: return @"IDR slice";
        case 6: return @"SEI";
        case 7: return @"SPS";
        case 8: return @"PPS";
        case 9: return @"AUD";
        default: return [NSString stringWithFormat:@"Type %d", naluType];
    }
}

+ (NSString *)detailedBoxStructure:(NSData *)segmentData {
    NSMutableString *structure = [NSMutableString string];
    const uint8_t *bytes = segmentData.bytes;
    int indent = 0;
    
    [structure appendString:@"Box Structure:\n"];
    [self parseBoxAtOffset:0 
                     bytes:bytes 
                    length:segmentData.length 
                    indent:indent 
                    output:structure];
    
    return structure;
}

+ (void)parseBoxAtOffset:(NSUInteger)offset 
                   bytes:(const uint8_t *)bytes 
                  length:(NSUInteger)length 
                  indent:(int)indent 
                  output:(NSMutableString *)output {
    
    while (offset + 8 <= length) {
        uint32_t size = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset));
        char typeStr[5] = {0};
        memcpy(typeStr, bytes + offset + 4, 4);
        
        // Indent
        for (int i = 0; i < indent; i++) {
            [output appendString:@"  "];
        }
        
        [output appendFormat:@"%s (%u bytes)", typeStr, size];
        
        // Special handling for certain boxes
        if (strcmp(typeStr, "tfdt") == 0 && offset + 20 <= length) {
            uint8_t version = bytes[offset + 8];
            uint64_t decodeTime = 0;
            
            if (version == 0 && offset + 16 <= length) {
                decodeTime = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset + 12));
            } else if (version == 1 && offset + 20 <= length) {
                decodeTime = CFSwapInt64BigToHost(*(uint64_t *)(bytes + offset + 12));
            }
            
            [output appendFormat:@" [decode_time=%llu (%.3fs)]", decodeTime, decodeTime / 90000.0];
        } else if (strcmp(typeStr, "trun") == 0 && offset + 16 <= length) {
            uint32_t flags = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset + 8)) & 0xFFFFFF;
            uint32_t sampleCount = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset + 12));
            [output appendFormat:@" [%u samples, flags=0x%06x]", sampleCount, flags];
        }
        
        [output appendString:@"\n"];
        
        // Parse nested boxes for container types
        if (strcmp(typeStr, "moof") == 0 || strcmp(typeStr, "traf") == 0 || 
            strcmp(typeStr, "moov") == 0 || strcmp(typeStr, "trak") == 0 ||
            strcmp(typeStr, "mdia") == 0 || strcmp(typeStr, "minf") == 0 ||
            strcmp(typeStr, "stbl") == 0 || strcmp(typeStr, "mvex") == 0 ||
            strcmp(typeStr, "dinf") == 0) {
            [self parseBoxAtOffset:offset + 8 
                             bytes:bytes 
                            length:offset + size 
                            indent:indent + 1 
                            output:output];
        }
        
        offset += size;
        if (size == 0) break;
    }
}

@end