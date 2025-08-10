//
//  RptrH264Decoder.m
//  Rptr
//
//  H.264 Parameter Set Decoder and Validator Implementation
//

#import "RptrH264Decoder.h"
#import "RptrLogger.h"

@implementation RptrSPSInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        _validationErrors = [NSMutableArray array];
        _validationWarnings = [NSMutableArray array];
    }
    return self;
}

@end

@implementation RptrPPSInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        _validationErrors = [NSMutableArray array];
        _validationWarnings = [NSMutableArray array];
    }
    return self;
}

@end

@interface RptrBitstreamReader ()
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) const uint8_t *bytes;
@property (nonatomic, assign) NSUInteger length;
@property (nonatomic, assign) NSUInteger byteIndex;
@property (nonatomic, assign) int bitIndex;
@property (nonatomic, assign) NSUInteger totalBitsRead;
@end

@implementation RptrBitstreamReader

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        _data = data;
        _bytes = data.bytes;
        _length = data.length;
        _byteIndex = 0;
        _bitIndex = 7;
        _totalBitsRead = 0;
    }
    return self;
}

- (uint32_t)readBits:(int)numBits {
    uint32_t result = 0;
    
    for (int i = 0; i < numBits; i++) {
        if (self.byteIndex >= self.length) {
            RLogError(@"[H264-DECODER] Bitstream overrun at byte %lu", (unsigned long)self.byteIndex);
            return 0;
        }
        
        uint8_t bit = (self.bytes[self.byteIndex] >> self.bitIndex) & 0x01;
        result = (result << 1) | bit;
        
        self.bitIndex--;
        if (self.bitIndex < 0) {
            self.bitIndex = 7;
            self.byteIndex++;
        }
        self.totalBitsRead++;
    }
    
    return result;
}

- (uint32_t)readUnsignedExpGolomb {
    int leadingZeroBits = 0;
    
    // Count leading zeros
    while ([self readBits:1] == 0) {
        leadingZeroBits++;
        if (leadingZeroBits > 31) {
            RLogError(@"[H264-DECODER] ExpGolomb decode error: too many leading zeros");
            return 0;
        }
    }
    
    if (leadingZeroBits == 0) {
        return 0;
    }
    
    uint32_t value = [self readBits:leadingZeroBits];
    return (1 << leadingZeroBits) - 1 + value;
}

- (int32_t)readSignedExpGolomb {
    uint32_t codeNum = [self readUnsignedExpGolomb];
    
    if (codeNum == 0) {
        return 0;
    }
    
    int32_t value = (codeNum + 1) / 2;
    if ((codeNum & 0x01) == 0) {
        value = -value;
    }
    
    return value;
}

- (BOOL)hasMoreData {
    return self.byteIndex < self.length || (self.byteIndex == self.length - 1 && self.bitIndex >= 0);
}

- (NSUInteger)bytesRead {
    return self.byteIndex + (self.bitIndex < 7 ? 1 : 0);
}

- (NSUInteger)bitsRead {
    return self.totalBitsRead;
}

@end

@implementation RptrH264Decoder

+ (RptrSPSInfo *)decodeSPS:(NSData *)spsData {
    if (!spsData || spsData.length < 4) {
        RLogError(@"[H264-DECODER] SPS data too short: %lu bytes", (unsigned long)spsData.length);
        return nil;
    }
    
    RptrSPSInfo *sps = [[RptrSPSInfo alloc] init];
    RptrBitstreamReader *reader = [[RptrBitstreamReader alloc] initWithData:spsData];
    
    @try {
        // NAL Unit Header
        uint8_t nalHeader = [reader readBits:8];
        uint8_t forbiddenZeroBit = (nalHeader >> 7) & 0x01;
        // uint8_t nalRefIdc = (nalHeader >> 5) & 0x03; // Currently unused
        sps.nalUnitType = nalHeader & 0x1F;
        
        // Validate NAL header
        if (forbiddenZeroBit != 0) {
            [sps.validationErrors addObject:@"Forbidden zero bit is not zero"];
        }
        
        if (sps.nalUnitType != 7) {
            [sps.validationErrors addObject:[NSString stringWithFormat:@"Wrong NAL unit type: %d (expected 7)", sps.nalUnitType]];
            sps.isValid = NO;
            return sps;
        }
        
        // Profile, constraint flags, and level
        sps.profileIdc = [reader readBits:8];
        sps.constraintSetFlags = [reader readBits:8];
        sps.levelIdc = [reader readBits:8];
        
        // seq_parameter_set_id
        sps.seqParameterSetId = [reader readUnsignedExpGolomb];
        if (sps.seqParameterSetId > 31) {
            [sps.validationErrors addObject:[NSString stringWithFormat:@"Invalid SPS ID: %u (max 31)", sps.seqParameterSetId]];
        }
        
        // Profile-specific parameters
        if (sps.profileIdc == 100 || sps.profileIdc == 110 || sps.profileIdc == 122 ||
            sps.profileIdc == 244 || sps.profileIdc == 44 || sps.profileIdc == 83 ||
            sps.profileIdc == 86 || sps.profileIdc == 118 || sps.profileIdc == 128) {
            
            uint32_t chromaFormatIdc = [reader readUnsignedExpGolomb];
            if (chromaFormatIdc == 3) {
                [reader readBits:1]; // separate_colour_plane_flag
            }
            
            [reader readUnsignedExpGolomb]; // bit_depth_luma_minus8
            [reader readUnsignedExpGolomb]; // bit_depth_chroma_minus8
            [reader readBits:1]; // qpprime_y_zero_transform_bypass_flag
            
            uint32_t seqScalingMatrixPresentFlag = [reader readBits:1];
            if (seqScalingMatrixPresentFlag) {
                int numScalingLists = (chromaFormatIdc != 3) ? 8 : 12;
                for (int i = 0; i < numScalingLists; i++) {
                    uint32_t seqScalingListPresentFlag = [reader readBits:1];
                    if (seqScalingListPresentFlag) {
                        // Skip scaling list parsing for now
                        [sps.validationWarnings addObject:@"Scaling lists present but not fully parsed"];
                    }
                }
            }
        }
        
        // log2_max_frame_num_minus4
        sps.log2MaxFrameNumMinus4 = [reader readUnsignedExpGolomb];
        if (sps.log2MaxFrameNumMinus4 > 12) {
            [sps.validationErrors addObject:[NSString stringWithFormat:@"Invalid log2_max_frame_num: %u (max 12)", sps.log2MaxFrameNumMinus4]];
        }
        
        // pic_order_cnt_type
        sps.picOrderCntType = [reader readUnsignedExpGolomb];
        if (sps.picOrderCntType == 0) {
            sps.log2MaxPicOrderCntLsbMinus4 = [reader readUnsignedExpGolomb];
        } else if (sps.picOrderCntType == 1) {
            [reader readBits:1]; // delta_pic_order_always_zero_flag
            [reader readSignedExpGolomb]; // offset_for_non_ref_pic
            [reader readSignedExpGolomb]; // offset_for_top_to_bottom_field
            uint32_t numRefFramesInPicOrderCntCycle = [reader readUnsignedExpGolomb];
            for (uint32_t i = 0; i < numRefFramesInPicOrderCntCycle; i++) {
                [reader readSignedExpGolomb]; // offset_for_ref_frame[i]
            }
        }
        
        // max_num_ref_frames
        sps.maxNumRefFrames = [reader readUnsignedExpGolomb];
        
        // gaps_in_frame_num_value_allowed_flag
        sps.gapsInFrameNumValueAllowedFlag = [reader readBits:1];
        
        // pic_width_in_mbs_minus1
        sps.picWidthInMbsMinus1 = [reader readUnsignedExpGolomb];
        
        // pic_height_in_map_units_minus1
        sps.picHeightInMapUnitsMinus1 = [reader readUnsignedExpGolomb];
        
        // frame_mbs_only_flag
        sps.frameMbsOnlyFlag = [reader readBits:1];
        
        if (!sps.frameMbsOnlyFlag) {
            sps.mbAdaptiveFrameFieldFlag = [reader readBits:1];
        }
        
        // direct_8x8_inference_flag
        sps.direct8x8InferenceFlag = [reader readBits:1];
        
        // frame_cropping_flag
        sps.frameCroppingFlag = [reader readBits:1];
        if (sps.frameCroppingFlag) {
            sps.frameCropLeftOffset = [reader readUnsignedExpGolomb];
            sps.frameCropRightOffset = [reader readUnsignedExpGolomb];
            sps.frameCropTopOffset = [reader readUnsignedExpGolomb];
            sps.frameCropBottomOffset = [reader readUnsignedExpGolomb];
        }
        
        // vui_parameters_present_flag
        if ([reader hasMoreData]) {
            sps.vuiParametersPresentFlag = [reader readBits:1];
            if (sps.vuiParametersPresentFlag) {
                [sps.validationWarnings addObject:@"VUI parameters present but not parsed"];
            }
        }
        
        // Calculate dimensions
        sps.width = (sps.picWidthInMbsMinus1 + 1) * 16;
        sps.height = (sps.picHeightInMapUnitsMinus1 + 1) * 16 * (sps.frameMbsOnlyFlag ? 1 : 2);
        
        if (sps.frameCroppingFlag) {
            sps.width -= (sps.frameCropLeftOffset + sps.frameCropRightOffset) * 2;
            sps.height -= (sps.frameCropTopOffset + sps.frameCropBottomOffset) * 2;
        }
        
        // Set profile string
        switch (sps.profileIdc) {
            case 66: sps.profileString = @"Baseline"; break;
            case 77: sps.profileString = @"Main"; break;
            case 88: sps.profileString = @"Extended"; break;
            case 100: sps.profileString = @"High"; break;
            case 110: sps.profileString = @"High 10"; break;
            case 122: sps.profileString = @"High 4:2:2"; break;
            case 244: sps.profileString = @"High 4:4:4"; break;
            default: sps.profileString = [NSString stringWithFormat:@"Unknown (%d)", sps.profileIdc];
        }
        
        // Set level string
        float level = sps.levelIdc / 10.0;
        if (sps.levelIdc % 10 == 0) {
            sps.levelString = [NSString stringWithFormat:@"%.0f", level];
        } else {
            sps.levelString = [NSString stringWithFormat:@"%.1f", level];
        }
        
        sps.isValid = (sps.validationErrors.count == 0);
        
        RLogDIY(@"[H264-DECODER] SPS decoded: %@x%u, %@ Profile, Level %@",
                @(sps.width), sps.height, sps.profileString, sps.levelString);
        
    } @catch (NSException *exception) {
        [sps.validationErrors addObject:[NSString stringWithFormat:@"Exception during parsing: %@", exception.reason]];
        sps.isValid = NO;
    }
    
    return sps;
}

+ (RptrPPSInfo *)decodePPS:(NSData *)ppsData {
    if (!ppsData || ppsData.length < 2) {
        RLogError(@"[H264-DECODER] PPS data too short: %lu bytes", (unsigned long)ppsData.length);
        return nil;
    }
    
    RptrPPSInfo *pps = [[RptrPPSInfo alloc] init];
    RptrBitstreamReader *reader = [[RptrBitstreamReader alloc] initWithData:ppsData];
    
    @try {
        // NAL Unit Header
        uint8_t nalHeader = [reader readBits:8];
        uint8_t forbiddenZeroBit = (nalHeader >> 7) & 0x01;
        pps.nalUnitType = nalHeader & 0x1F;
        
        if (forbiddenZeroBit != 0) {
            [pps.validationErrors addObject:@"Forbidden zero bit is not zero"];
        }
        
        if (pps.nalUnitType != 8) {
            [pps.validationErrors addObject:[NSString stringWithFormat:@"Wrong NAL unit type: %d (expected 8)", pps.nalUnitType]];
            pps.isValid = NO;
            return pps;
        }
        
        // pic_parameter_set_id
        pps.picParameterSetId = [reader readUnsignedExpGolomb];
        if (pps.picParameterSetId > 255) {
            [pps.validationErrors addObject:[NSString stringWithFormat:@"Invalid PPS ID: %u (max 255)", pps.picParameterSetId]];
        }
        
        // seq_parameter_set_id
        pps.seqParameterSetId = [reader readUnsignedExpGolomb];
        if (pps.seqParameterSetId > 31) {
            [pps.validationErrors addObject:[NSString stringWithFormat:@"Invalid SPS ID reference: %u (max 31)", pps.seqParameterSetId]];
        }
        
        // entropy_coding_mode_flag
        pps.entropyCodingModeFlag = [reader readBits:1];
        
        // bottom_field_pic_order_in_frame_present_flag
        pps.bottomFieldPicOrderInFramePresentFlag = [reader readBits:1];
        
        // num_slice_groups_minus1
        pps.numSliceGroupsMinus1 = [reader readUnsignedExpGolomb];
        
        if (pps.numSliceGroupsMinus1 > 0) {
            // Skip slice group map parsing for now
            [pps.validationWarnings addObject:@"Slice groups present but not fully parsed"];
        }
        
        // num_ref_idx_l0_default_active_minus1
        pps.numRefIdxL0DefaultActiveMinus1 = [reader readUnsignedExpGolomb];
        
        // num_ref_idx_l1_default_active_minus1
        pps.numRefIdxL1DefaultActiveMinus1 = [reader readUnsignedExpGolomb];
        
        // weighted_pred_flag
        pps.weightedPredFlag = [reader readBits:1];
        
        // weighted_bipred_idc
        pps.weightedBipredIdc = [reader readBits:2];
        
        // pic_init_qp_minus26
        pps.picInitQpMinus26 = [reader readSignedExpGolomb];
        if (pps.picInitQpMinus26 < -26 || pps.picInitQpMinus26 > 25) {
            [pps.validationErrors addObject:[NSString stringWithFormat:@"Invalid pic_init_qp: %d (range -26 to 25)", pps.picInitQpMinus26]];
        }
        
        // pic_init_qs_minus26
        pps.picInitQsMinus26 = [reader readSignedExpGolomb];
        
        // chroma_qp_index_offset
        pps.chromaQpIndexOffset = [reader readSignedExpGolomb];
        if (pps.chromaQpIndexOffset < -12 || pps.chromaQpIndexOffset > 12) {
            [pps.validationWarnings addObject:[NSString stringWithFormat:@"Unusual chroma_qp_index_offset: %d", pps.chromaQpIndexOffset]];
        }
        
        // deblocking_filter_control_present_flag
        pps.deblockingFilterControlPresentFlag = [reader readBits:1];
        
        // constrained_intra_pred_flag
        pps.constrainedIntraPredFlag = [reader readBits:1];
        
        // redundant_pic_cnt_present_flag
        pps.redundantPicCntPresentFlag = [reader readBits:1];
        
        pps.isValid = (pps.validationErrors.count == 0);
        
        RLogDIY(@"[H264-DECODER] PPS decoded: ID %u, SPS ref %u, QP %d, Entropy: %@",
                pps.picParameterSetId, pps.seqParameterSetId, 
                pps.picInitQpMinus26 + 26,
                pps.entropyCodingModeFlag ? @"CABAC" : @"CAVLC");
        
    } @catch (NSException *exception) {
        [pps.validationErrors addObject:[NSString stringWithFormat:@"Exception during parsing: %@", exception.reason]];
        pps.isValid = NO;
    }
    
    return pps;
}

+ (NSDictionary *)validateSPSPPSPair:(NSData *)spsData pps:(NSData *)ppsData {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableArray *errors = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];
    
    RptrSPSInfo *sps = [self decodeSPS:spsData];
    RptrPPSInfo *pps = [self decodePPS:ppsData];
    
    if (!sps) {
        [errors addObject:@"Failed to decode SPS"];
    } else {
        [errors addObjectsFromArray:sps.validationErrors];
        [warnings addObjectsFromArray:sps.validationWarnings];
        result[@"sps"] = @{
            @"profile": sps.profileString ?: @"Unknown",
            @"level": sps.levelString ?: @"Unknown",
            @"width": @(sps.width),
            @"height": @(sps.height),
            @"id": @(sps.seqParameterSetId)
        };
    }
    
    if (!pps) {
        [errors addObject:@"Failed to decode PPS"];
    } else {
        [errors addObjectsFromArray:pps.validationErrors];
        [warnings addObjectsFromArray:pps.validationWarnings];
        result[@"pps"] = @{
            @"id": @(pps.picParameterSetId),
            @"sps_ref": @(pps.seqParameterSetId),
            @"qp": @(pps.picInitQpMinus26 + 26),
            @"entropy": pps.entropyCodingModeFlag ? @"CABAC" : @"CAVLC"
        };
    }
    
    // Cross-validation
    if (sps && pps) {
        if (pps.seqParameterSetId != sps.seqParameterSetId) {
            [warnings addObject:[NSString stringWithFormat:@"PPS references SPS %u but decoded SPS has ID %u",
                                pps.seqParameterSetId, sps.seqParameterSetId]];
        }
    }
    
    result[@"valid"] = @(errors.count == 0);
    result[@"errors"] = errors;
    result[@"warnings"] = warnings;
    
    return result;
}

+ (NSString *)generateDetailedReport:(NSData *)spsData pps:(NSData *)ppsData {
    NSMutableString *report = [NSMutableString string];
    
    [report appendString:@"\n==== H.264 Parameter Set Analysis ====\n\n"];
    
    // SPS Analysis
    [report appendFormat:@"SPS Size: %lu bytes\n", (unsigned long)spsData.length];
    if (spsData && spsData.length > 0) {
        [report appendString:@"SPS Hex: "];
        const uint8_t *spsBytes = spsData.bytes;
        for (int i = 0; i < MIN(spsData.length, 32); i++) {
            [report appendFormat:@"%02X ", spsBytes[i]];
        }
        if (spsData.length > 32) {
            [report appendString:@"..."];
        }
        [report appendString:@"\n\n"];
        
        RptrSPSInfo *sps = [self decodeSPS:spsData];
        if (sps) {
            [report appendFormat:@"SPS Decoded:\n"];
            [report appendFormat:@"  NAL Type: %u (expected 7)\n", sps.nalUnitType];
            [report appendFormat:@"  Profile: %@ (%u)\n", sps.profileString, sps.profileIdc];
            [report appendFormat:@"  Level: %@ (%u)\n", sps.levelString, sps.levelIdc];
            [report appendFormat:@"  SPS ID: %u\n", sps.seqParameterSetId];
            [report appendFormat:@"  Resolution: %ux%u\n", sps.width, sps.height];
            [report appendFormat:@"  Frame MBs Only: %@\n", sps.frameMbsOnlyFlag ? @"YES" : @"NO"];
            [report appendFormat:@"  Max Ref Frames: %u\n", sps.maxNumRefFrames];
            [report appendFormat:@"  VUI Parameters: %@\n", sps.vuiParametersPresentFlag ? @"Present" : @"Absent"];
            
            if (sps.validationErrors.count > 0) {
                [report appendString:@"  ERRORS:\n"];
                for (NSString *error in sps.validationErrors) {
                    [report appendFormat:@"    - %@\n", error];
                }
            }
            
            if (sps.validationWarnings.count > 0) {
                [report appendString:@"  Warnings:\n"];
                for (NSString *warning in sps.validationWarnings) {
                    [report appendFormat:@"    - %@\n", warning];
                }
            }
        } else {
            [report appendString:@"  ERROR: Failed to decode SPS\n"];
        }
    } else {
        [report appendString:@"  ERROR: No SPS data\n"];
    }
    
    [report appendString:@"\n"];
    
    // PPS Analysis
    [report appendFormat:@"PPS Size: %lu bytes\n", (unsigned long)ppsData.length];
    if (ppsData && ppsData.length > 0) {
        [report appendString:@"PPS Hex: "];
        const uint8_t *ppsBytes = ppsData.bytes;
        for (int i = 0; i < MIN(ppsData.length, 32); i++) {
            [report appendFormat:@"%02X ", ppsBytes[i]];
        }
        if (ppsData.length > 32) {
            [report appendString:@"..."];
        }
        [report appendString:@"\n\n"];
        
        RptrPPSInfo *pps = [self decodePPS:ppsData];
        if (pps) {
            [report appendFormat:@"PPS Decoded:\n"];
            [report appendFormat:@"  NAL Type: %u (expected 8)\n", pps.nalUnitType];
            [report appendFormat:@"  PPS ID: %u\n", pps.picParameterSetId];
            [report appendFormat:@"  SPS Reference: %u\n", pps.seqParameterSetId];
            [report appendFormat:@"  Entropy Coding: %@\n", pps.entropyCodingModeFlag ? @"CABAC" : @"CAVLC"];
            [report appendFormat:@"  QP Initial: %d\n", pps.picInitQpMinus26 + 26];
            [report appendFormat:@"  Weighted Prediction: %@\n", pps.weightedPredFlag ? @"YES" : @"NO"];
            [report appendFormat:@"  Deblocking Filter: %@\n", pps.deblockingFilterControlPresentFlag ? @"Controlled" : @"Default"];
            
            if (pps.validationErrors.count > 0) {
                [report appendString:@"  ERRORS:\n"];
                for (NSString *error in pps.validationErrors) {
                    [report appendFormat:@"    - %@\n", error];
                }
            }
            
            if (pps.validationWarnings.count > 0) {
                [report appendString:@"  Warnings:\n"];
                for (NSString *warning in pps.validationWarnings) {
                    [report appendFormat:@"    - %@\n", warning];
                }
            }
        } else {
            [report appendString:@"  ERROR: Failed to decode PPS\n"];
        }
    } else {
        [report appendString:@"  ERROR: No PPS data\n"];
    }
    
    [report appendString:@"\n==== HLS Compatibility Check ====\n"];
    
    NSMutableArray *hlsErrors = [NSMutableArray array];
    BOOL meetsHLS = [self meetsHLSRequirements:spsData pps:ppsData errors:&hlsErrors];
    
    if (meetsHLS) {
        [report appendString:@"✓ Parameter sets meet HLS requirements\n"];
    } else {
        [report appendString:@"✗ Parameter sets DO NOT meet HLS requirements:\n"];
        for (NSString *error in hlsErrors) {
            [report appendFormat:@"  - %@\n", error];
        }
    }
    
    [report appendString:@"\n==== Recommendations ====\n"];
    
    if (spsData.length < 15) {
        [report appendString:@"- SPS is unusually small. Consider including VUI parameters for better compatibility\n"];
    }
    
    if (ppsData.length < 5) {
        [report appendString:@"- PPS is minimal. This is valid but may lack advanced features\n"];
    }
    
    RptrSPSInfo *sps = [self decodeSPS:spsData];
    if (sps && !sps.vuiParametersPresentFlag) {
        [report appendString:@"- No VUI parameters. Consider adding for timing/aspect ratio information\n"];
    }
    
    if (sps && sps.profileIdc != 66 && sps.profileIdc != 77) {
        [report appendString:@"- Using advanced profile. Ensure target devices support this profile\n"];
    }
    
    [report appendString:@"\n=====================================\n"];
    
    return report;
}

+ (BOOL)meetsHLSRequirements:(NSData *)spsData pps:(NSData *)ppsData errors:(NSMutableArray<NSString *> **)errors {
    NSMutableArray *localErrors = [NSMutableArray array];
    
    if (!spsData || spsData.length < 4) {
        [localErrors addObject:@"SPS missing or too short (minimum 4 bytes)"];
    }
    
    if (!ppsData || ppsData.length < 2) {
        [localErrors addObject:@"PPS missing or too short (minimum 2 bytes)"];
    }
    
    RptrSPSInfo *sps = [self decodeSPS:spsData];
    RptrPPSInfo *pps = [self decodePPS:ppsData];
    
    if (sps) {
        if (sps.nalUnitType != 7) {
            [localErrors addObject:@"Invalid SPS NAL type"];
        }
        
        if (sps.width == 0 || sps.height == 0) {
            [localErrors addObject:@"Invalid resolution in SPS"];
        }
        
        if (sps.width > 4096 || sps.height > 2160) {
            [localErrors addObject:@"Resolution exceeds common HLS limits"];
        }
        
        if (sps.profileIdc != 66 && sps.profileIdc != 77 && sps.profileIdc != 100) {
            [localErrors addObject:@"Uncommon H.264 profile for HLS"];
        }
        
        [localErrors addObjectsFromArray:sps.validationErrors];
    } else {
        [localErrors addObject:@"Failed to decode SPS"];
    }
    
    if (pps) {
        if (pps.nalUnitType != 8) {
            [localErrors addObject:@"Invalid PPS NAL type"];
        }
        
        [localErrors addObjectsFromArray:pps.validationErrors];
    } else {
        [localErrors addObject:@"Failed to decode PPS"];
    }
    
    if (errors) {
        *errors = localErrors;
    }
    
    return (localErrors.count == 0);
}

@end