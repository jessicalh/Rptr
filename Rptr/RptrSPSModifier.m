//
//  RptrSPSModifier.m
//  Rptr
//
//  Adds VUI parameters to VideoToolbox-generated SPS for Safari compatibility
//

#import "RptrSPSModifier.h"
#import "RptrLogger.h"

@implementation RptrSPSModifier

+ (NSData *)addVUIParametersToSPS:(NSData *)originalSPS frameRate:(float)frameRate {
    if (!originalSPS || originalSPS.length < 4) {
        RLogError(@"[SPS-MODIFIER] Invalid SPS data");
        return originalSPS;
    }
    
    const uint8_t *bytes = originalSPS.bytes;
    NSUInteger length = originalSPS.length;
    
    // Skip NAL header if present
    NSUInteger startOffset = 0;
    if (bytes[0] == 0x27 || bytes[0] == 0x67) {
        startOffset = 1;
    }
    
    // Check if VUI parameters are already present (last bit before rbsp_trailing_bits)
    // For our typical 10-byte SPS, the vui_parameters_present_flag is in the last byte
    uint8_t lastByte = bytes[length - 1];
    
    // Our SPS typically ends with 0x68 (0110 1000 in binary)
    // The last '0' before the rbsp_trailing_bits (1000) is the vui_parameters_present_flag
    // We need to change it to '1' and add VUI data
    
    NSMutableData *modifiedSPS = [NSMutableData dataWithData:originalSPS];
    
    // Get the last byte and check the vui_parameters_present_flag
    uint8_t *mutableBytes = modifiedSPS.mutableBytes;
    uint8_t originalLastByte = mutableBytes[length - 1];
    
    // For a byte ending in binary 0110 1000 (0x68), we need to:
    // 1. Set the vui_parameters_present_flag to 1: 0110 1000 -> 0110 1100 (0x6C)
    // 2. Remove the rbsp_trailing_bits (1000) since we'll add them after VUI
    
    if (originalLastByte == 0x68) {
        // Change to 0x6C (set vui_parameters_present_flag = 1, keep other bits)
        mutableBytes[length - 1] = 0x6C;
        
        // Now append minimal VUI parameters
        // We'll add only the essential timing information
        NSMutableData *vuiData = [NSMutableData data];
        
        // Build VUI parameters bit by bit
        uint8_t vuiBits = 0;
        int bitPos = 0;
        NSMutableData *vuiBuffer = [NSMutableData data];
        
        // aspect_ratio_info_present_flag = 0
        // overscan_info_present_flag = 0
        // video_signal_type_present_flag = 0
        // chroma_loc_info_present_flag = 0
        // timing_info_present_flag = 1
        // First byte: 0000 0001 (only timing_info_present_flag set)
        uint8_t vuiByte1 = 0x01;
        [vuiBuffer appendBytes:&vuiByte1 length:1];
        
        // Now add timing information
        // num_units_in_tick (32 bits) - for 15 fps: 1000
        // time_scale (32 bits) - for 15 fps: 30000 (15 * 2 * 1000)
        uint32_t num_units_in_tick = 1000;
        uint32_t time_scale = (uint32_t)(frameRate * 2 * 1000);
        
        // Convert to big-endian
        uint32_t num_units_be = CFSwapInt32HostToBig(num_units_in_tick);
        uint32_t time_scale_be = CFSwapInt32HostToBig(time_scale);
        
        [vuiBuffer appendBytes:&num_units_be length:4];
        [vuiBuffer appendBytes:&time_scale_be length:4];
        
        // fixed_frame_rate_flag = 0, followed by other VUI flags all = 0
        // nal_hrd_parameters_present_flag = 0
        // vcl_hrd_parameters_present_flag = 0
        // pic_struct_present_flag = 0
        // bitstream_restriction_flag = 0
        // Then rbsp_trailing_bits (10000000)
        uint8_t vuiEnd = 0x80; // 1000 0000 (rbsp_stop_bit + alignment)
        [vuiBuffer appendBytes:&vuiEnd length:1];
        
        // Append VUI data to modified SPS
        [modifiedSPS appendData:vuiBuffer];
        
        RLogDIY(@"[SPS-MODIFIER] Added VUI parameters for %.1f fps", frameRate);
        RLogDIY(@"[SPS-MODIFIER] Original SPS: %lu bytes, Modified: %lu bytes", 
                (unsigned long)originalSPS.length, (unsigned long)modifiedSPS.length);
        
        // Log hex for debugging
        [self logHexData:originalSPS label:@"Original SPS"];
        [self logHexData:modifiedSPS label:@"Modified SPS"];
        
        return modifiedSPS;
    } else if (originalLastByte == 0xBF) {
        // For Baseline profile SPS ending with 0xBF (1011 1111)
        // This indicates vui_parameters_present_flag might already be 1
        // or the structure is different
        RLogDIY(@"[SPS-MODIFIER] SPS ends with 0x%02X, might have different structure", originalLastByte);
        
        // Try a different approach for 0xBF ending
        // The bit pattern 1011 1111 suggests different field values
        // We'll need to carefully modify this
        
        // For now, return original
        return originalSPS;
    }
    
    RLogDIY(@"[SPS-MODIFIER] SPS ends with unexpected byte: 0x%02X", originalLastByte);
    return originalSPS;
}

+ (void)logHexData:(NSData *)data label:(NSString *)label {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length && i < 40; i++) {
        [hex appendFormat:@"%02X ", bytes[i]];
    }
    if (data.length > 40) {
        [hex appendString:@"..."];
    }
    RLogDIY(@"[SPS-MODIFIER] %@: %@", label, hex);
}

+ (void)analyzeSPS:(NSData *)spsData label:(NSString *)label {
    if (!spsData || spsData.length < 4) {
        RLogError(@"[SPS-ANALYZER] Invalid SPS data for %@", label);
        return;
    }
    
    const uint8_t *bytes = spsData.bytes;
    NSUInteger length = spsData.length;
    
    RLogDIY(@"[SPS-ANALYZER] === %@ ===", label);
    RLogDIY(@"[SPS-ANALYZER] Size: %lu bytes", (unsigned long)length);
    
    // Log hex
    [self logHexData:spsData label:label];
    
    // Basic analysis
    uint8_t nalHeader = bytes[0];
    if (nalHeader == 0x27 || nalHeader == 0x67) {
        uint8_t profile = bytes[1];
        uint8_t constraints = bytes[2];
        uint8_t level = bytes[3];
        
        RLogDIY(@"[SPS-ANALYZER] NAL Type: SPS (0x%02X)", nalHeader);
        RLogDIY(@"[SPS-ANALYZER] Profile: 0x%02X (%@)", profile,
                profile == 0x42 ? @"Baseline" :
                profile == 0x4D ? @"Main" :
                profile == 0x64 ? @"High" : @"Unknown");
        RLogDIY(@"[SPS-ANALYZER] Constraints: 0x%02X", constraints);
        RLogDIY(@"[SPS-ANALYZER] Level: 0x%02X (Level %d.%d)", level, level/10, level%10);
        
        // Check last byte for VUI flag
        uint8_t lastByte = bytes[length - 1];
        RLogDIY(@"[SPS-ANALYZER] Last byte: 0x%02X (binary: %@)", lastByte,
                [self byteToBinaryString:lastByte]);
        
        // The vui_parameters_present_flag is typically one of the last bits
        // before the rbsp_trailing_bits
        BOOL likelyHasVUI = (length > 15); // Heuristic: VUI adds significant bytes
        RLogDIY(@"[SPS-ANALYZER] Likely has VUI: %@", likelyHasVUI ? @"YES" : @"NO");
    }
}

+ (NSString *)byteToBinaryString:(uint8_t)byte {
    NSMutableString *binary = [NSMutableString string];
    for (int i = 7; i >= 0; i--) {
        [binary appendString:((byte >> i) & 1) ? @"1" : @"0"];
        if (i == 4) [binary appendString:@" "]; // Add space in middle for readability
    }
    return binary;
}

@end