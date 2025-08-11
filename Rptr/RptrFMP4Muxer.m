//
//  RptrFMP4Muxer.m
//  Rptr
//
//  Fragmented MP4 muxer implementation
//

#import "RptrFMP4Muxer.h"
#import "RptrLogger.h"
#import "RptrH264Decoder.h"

@implementation RptrFMP4TrackConfig
@end

@implementation RptrFMP4Sample
@end

@implementation RptrFMP4Segment
@end

@interface RptrFMP4Muxer ()
@property (nonatomic, strong) NSMutableArray<RptrFMP4TrackConfig *> *tracks;
@property (nonatomic, assign) uint32_t nextTrackID;
@property (nonatomic, assign) CMTime streamStartTime;
@property (nonatomic, assign) BOOL streamStartTimeSet;
@end

@implementation RptrFMP4Muxer

- (instancetype)init {
    self = [super init];
    if (self) {
        _tracks = [NSMutableArray array];
        _nextTrackID = 1;
        _streamStartTime = kCMTimeInvalid;
        _streamStartTimeSet = NO;
    }
    return self;
}

#pragma mark - Track Management

- (void)addTrack:(RptrFMP4TrackConfig *)trackConfig {
    if (!trackConfig.trackID) {
        trackConfig.trackID = self.nextTrackID++;
    }
    [self.tracks addObject:trackConfig];
    
    RLogDIY(@"[FMP4-MUXER] Added %@ track ID %u", trackConfig.mediaType, trackConfig.trackID);
}

- (void)removeTrackWithID:(uint32_t)trackID {
    [self.tracks removeObjectsInArray:[self.tracks filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"trackID == %u", trackID]]];
}

- (void)removeAllTracks {
    [self.tracks removeAllObjects];
    self.nextTrackID = 1;
}

#pragma mark - Stream Management

- (void)resetStreamStartTime {
    self.streamStartTime = kCMTimeInvalid;
    self.streamStartTimeSet = NO;
    RLogDIY(@"[FMP4-MUXER] Stream start time reset");
}

#pragma mark - Box Writing Utilities

- (void)writeUInt32:(uint32_t)value to:(NSMutableData *)data {
    uint32_t bigEndian = CFSwapInt32HostToBig(value);
    [data appendBytes:&bigEndian length:4];
}

- (void)writeUInt64:(uint64_t)value to:(NSMutableData *)data {
    uint64_t bigEndian = CFSwapInt64HostToBig(value);
    [data appendBytes:&bigEndian length:8];
}

- (void)writeUInt16:(uint16_t)value to:(NSMutableData *)data {
    uint16_t bigEndian = CFSwapInt16HostToBig(value);
    [data appendBytes:&bigEndian length:2];
}

- (void)writeUInt8:(uint8_t)value to:(NSMutableData *)data {
    [data appendBytes:&value length:1];
}

- (void)writeFourCC:(NSString *)fourCC to:(NSMutableData *)data {
    NSData *fourCCData = [fourCC dataUsingEncoding:NSASCIIStringEncoding];
    NSAssert(fourCCData.length == 4, @"FourCC must be 4 characters");
    [data appendData:fourCCData];
}

- (NSData *)wrapInBox:(NSString *)type data:(NSData *)boxData {
    NSMutableData *box = [NSMutableData data];
    [self writeUInt32:(uint32_t)(8 + boxData.length) to:box];
    [self writeFourCC:type to:box];
    [box appendData:boxData];
    return box;
}

#pragma mark - Initialization Segment

- (nullable NSData *)createInitializationSegment {
    if (self.tracks.count == 0) {
        RLogError(@"[FMP4-MUXER] No tracks configured");
        return nil;
    }
    
    NSMutableData *initSegment = [NSMutableData data];
    
    // Add ftyp box
    [initSegment appendData:[self createFtypBox]];
    
    // Add moov box
    [initSegment appendData:[self createMoovBoxWithTracks:self.tracks]];
    
    RLogDIY(@"[FMP4-MUXER] Created init segment: %lu bytes", (unsigned long)initSegment.length);
    return initSegment;
}

- (NSData *)createFtypBox {
    NSMutableData *ftyp = [NSMutableData data];
    
    // File type box - identifies this as an MP4 file compatible with HLS
    // mp42 = ISO Base Media File Format v2 - standard for HLS fragmented MP4
    [self writeFourCC:@"mp42" to:ftyp];     // Major brand - ISO MP4 v2 spec
    [self writeUInt32:1 to:ftyp];            // Minor version 1 - indicates file format version
    [self writeFourCC:@"mp41" to:ftyp];     // Compatible with ISO MP4 v1
    [self writeFourCC:@"mp42" to:ftyp];     // Compatible with ISO MP4 v2
    [self writeFourCC:@"isom" to:ftyp];     // ISO Base Media File Format
    [self writeFourCC:@"hlsf" to:ftyp];     // HLS fragmented MP4 - Apple-specific brand for fMP4 HLS
    
    return [self wrapInBox:@"ftyp" data:ftyp];
}

#pragma mark - Movie Box (moov)

- (NSData *)createMoovBoxWithTracks:(NSArray<RptrFMP4TrackConfig *> *)tracks {
    NSMutableData *moov = [NSMutableData data];
    
    // Add mvhd (movie header)
    [moov appendData:[self createMvhdBox]];
    
    // Add tracks
    for (RptrFMP4TrackConfig *track in tracks) {
        [moov appendData:[self createTrakBoxForTrack:track]];
    }
    
    // Add mvex (movie extends) for fragmentation
    [moov appendData:[self createMvexBoxWithTracks:tracks]];
    
    return [self wrapInBox:@"moov" data:moov];
}

- (NSData *)createMvhdBox {
    NSMutableData *mvhd = [NSMutableData data];
    
    [self writeUInt8:0 to:mvhd];           // Version
    [self writeUInt8:0 to:mvhd];           // Flags (3 bytes)
    [self writeUInt16:0 to:mvhd];
    
    [self writeUInt32:0 to:mvhd];          // Creation time
    [self writeUInt32:0 to:mvhd];          // Modification time
    [self writeUInt32:90000 to:mvhd];      // Timescale - 90000 Hz (90 kHz) standard for MPEG-TS compatibility
    [self writeUInt32:0 to:mvhd];          // Duration - 0 for live streams (unknown duration)
    
    [self writeUInt32:0x00010000 to:mvhd]; // Playback rate - 0x00010000 = 1.0 in 16.16 fixed-point
    [self writeUInt16:0x0100 to:mvhd];     // Volume - 0x0100 = 1.0 in 8.8 fixed-point format
    [self writeUInt16:0 to:mvhd];          // Reserved
    [self writeUInt32:0 to:mvhd];          // Reserved
    [self writeUInt32:0 to:mvhd];          // Reserved
    
    // Transformation matrix - identity matrix for no transformation
    // Format: 3x3 matrix in 16.16 fixed-point (except last row which is 2.30 fixed-point)
    [self writeUInt32:0x00010000 to:mvhd]; [self writeUInt32:0 to:mvhd]; [self writeUInt32:0 to:mvhd];  // [1.0, 0, 0]
    [self writeUInt32:0 to:mvhd]; [self writeUInt32:0x00010000 to:mvhd]; [self writeUInt32:0 to:mvhd];  // [0, 1.0, 0]
    [self writeUInt32:0 to:mvhd]; [self writeUInt32:0 to:mvhd]; [self writeUInt32:0x40000000 to:mvhd];  // [0, 0, 1.0] - 0x40000000 = 1.0 in 2.30 format
    
    // Pre-defined
    for (int i = 0; i < 6; i++) {
        [self writeUInt32:0 to:mvhd];
    }
    
    [self writeUInt32:self.nextTrackID to:mvhd]; // Next track ID
    
    return [self wrapInBox:@"mvhd" data:mvhd];
}

#pragma mark - Track Box (trak)

- (NSData *)createTrakBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *trak = [NSMutableData data];
    
    // Add tkhd (track header)
    [trak appendData:[self createTkhdBoxForTrack:track]];
    
    // Add mdia (media)
    [trak appendData:[self createMdiaBoxForTrack:track]];
    
    return [self wrapInBox:@"trak" data:trak];
}

- (NSData *)createTkhdBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *tkhd = [NSMutableData data];
    
    [self writeUInt8:0 to:tkhd];           // Version
    [self writeUInt8:0 to:tkhd];           // Flags (track enabled)
    [self writeUInt8:0 to:tkhd];
    [self writeUInt8:3 to:tkhd];           // Track enabled + in movie
    
    [self writeUInt32:0 to:tkhd];          // Creation time
    [self writeUInt32:0 to:tkhd];          // Modification time
    [self writeUInt32:track.trackID to:tkhd]; // Track ID
    [self writeUInt32:0 to:tkhd];          // Reserved
    [self writeUInt32:0 to:tkhd];          // Duration
    
    [self writeUInt32:0 to:tkhd];          // Reserved
    [self writeUInt32:0 to:tkhd];          // Reserved
    [self writeUInt16:0 to:tkhd];          // Layer
    [self writeUInt16:0 to:tkhd];          // Alternate group
    
    if ([track.mediaType isEqualToString:@"audio"]) {
        [self writeUInt16:0x0100 to:tkhd]; // Volume (1.0 for audio)
    } else {
        [self writeUInt16:0 to:tkhd];      // Volume (0 for video)
    }
    
    [self writeUInt16:0 to:tkhd];          // Reserved
    
    // Matrix (identity)
    [self writeUInt32:0x00010000 to:tkhd]; [self writeUInt32:0 to:tkhd]; [self writeUInt32:0 to:tkhd];
    [self writeUInt32:0 to:tkhd]; [self writeUInt32:0x00010000 to:tkhd]; [self writeUInt32:0 to:tkhd];
    [self writeUInt32:0 to:tkhd]; [self writeUInt32:0 to:tkhd]; [self writeUInt32:0x40000000 to:tkhd];
    
    // Width and height (16.16 fixed point)
    if ([track.mediaType isEqualToString:@"video"]) {
        [self writeUInt32:(uint32_t)(track.width << 16) to:tkhd];
        [self writeUInt32:(uint32_t)(track.height << 16) to:tkhd];
    } else {
        [self writeUInt32:0 to:tkhd];
        [self writeUInt32:0 to:tkhd];
    }
    
    return [self wrapInBox:@"tkhd" data:tkhd];
}

#pragma mark - Media Box (mdia)

- (NSData *)createMdiaBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *mdia = [NSMutableData data];
    
    // Add mdhd (media header)
    [mdia appendData:[self createMdhdBoxForTrack:track]];
    
    // Add hdlr (handler)
    [mdia appendData:[self createHdlrBoxForTrack:track]];
    
    // Add minf (media information)
    [mdia appendData:[self createMinfBoxForTrack:track]];
    
    return [self wrapInBox:@"mdia" data:mdia];
}

- (NSData *)createMdhdBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *mdhd = [NSMutableData data];
    
    [self writeUInt8:0 to:mdhd];           // Version
    [self writeUInt8:0 to:mdhd];           // Flags
    [self writeUInt16:0 to:mdhd];
    
    [self writeUInt32:0 to:mdhd];          // Creation time
    [self writeUInt32:0 to:mdhd];          // Modification time
    [self writeUInt32:track.timescale to:mdhd]; // Timescale
    [self writeUInt32:0 to:mdhd];          // Duration
    
    [self writeUInt16:0x55C4 to:mdhd];     // Language (und)
    [self writeUInt16:0 to:mdhd];          // Pre-defined
    
    return [self wrapInBox:@"mdhd" data:mdhd];
}

- (NSData *)createHdlrBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *hdlr = [NSMutableData data];
    
    [self writeUInt8:0 to:hdlr];           // Version
    [self writeUInt8:0 to:hdlr];           // Flags
    [self writeUInt16:0 to:hdlr];
    
    [self writeUInt32:0 to:hdlr];          // Pre-defined
    
    if ([track.mediaType isEqualToString:@"video"]) {
        [self writeFourCC:@"vide" to:hdlr];
    } else {
        [self writeFourCC:@"soun" to:hdlr];
    }
    
    // Reserved
    [self writeUInt32:0 to:hdlr];
    [self writeUInt32:0 to:hdlr];
    [self writeUInt32:0 to:hdlr];
    
    // Name
    NSString *name = [track.mediaType isEqualToString:@"video"] ? @"VideoHandler" : @"SoundHandler";
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    [hdlr appendData:nameData];
    [self writeUInt8:0 to:hdlr]; // Null terminator
    
    return [self wrapInBox:@"hdlr" data:hdlr];
}

#pragma mark - Media Information Box (minf)

- (NSData *)createMinfBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *minf = [NSMutableData data];
    
    // Add media header (vmhd for video, smhd for audio)
    if ([track.mediaType isEqualToString:@"video"]) {
        [minf appendData:[self createVmhdBox]];
    } else {
        [minf appendData:[self createSmhdBox]];
    }
    
    // Add dinf (data information)
    [minf appendData:[self createDinfBox]];
    
    // Add stbl (sample table)
    [minf appendData:[self createStblBoxForTrack:track]];
    
    return [self wrapInBox:@"minf" data:minf];
}

- (NSData *)createVmhdBox {
    NSMutableData *vmhd = [NSMutableData data];
    
    [self writeUInt8:0 to:vmhd];           // Version
    [self writeUInt8:0 to:vmhd];           // Flags
    [self writeUInt8:0 to:vmhd];
    [self writeUInt8:1 to:vmhd];
    
    [self writeUInt16:0 to:vmhd];          // Graphics mode
    [self writeUInt16:0 to:vmhd];          // Opcolor R
    [self writeUInt16:0 to:vmhd];          // Opcolor G
    [self writeUInt16:0 to:vmhd];          // Opcolor B
    
    return [self wrapInBox:@"vmhd" data:vmhd];
}

- (NSData *)createSmhdBox {
    NSMutableData *smhd = [NSMutableData data];
    
    [self writeUInt8:0 to:smhd];           // Version
    [self writeUInt8:0 to:smhd];           // Flags
    [self writeUInt16:0 to:smhd];
    
    [self writeUInt16:0 to:smhd];          // Balance
    [self writeUInt16:0 to:smhd];          // Reserved
    
    return [self wrapInBox:@"smhd" data:smhd];
}

- (NSData *)createDinfBox {
    NSMutableData *dinf = [NSMutableData data];
    
    // Add dref (data reference)
    NSMutableData *dref = [NSMutableData data];
    [self writeUInt8:0 to:dref];           // Version
    [self writeUInt8:0 to:dref];           // Flags
    [self writeUInt16:0 to:dref];
    [self writeUInt32:1 to:dref];          // Entry count
    
    // URL box (self-contained)
    NSMutableData *url = [NSMutableData data];
    [self writeUInt8:0 to:url];            // Version
    [self writeUInt8:0 to:url];            // Flags (self-contained)
    [self writeUInt8:0 to:url];
    [self writeUInt8:1 to:url];
    
    [dref appendData:[self wrapInBox:@"url " data:url]];
    [dinf appendData:[self wrapInBox:@"dref" data:dref]];
    
    return [self wrapInBox:@"dinf" data:dinf];
}

#pragma mark - Sample Table Box (stbl)

- (NSData *)createStblBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *stbl = [NSMutableData data];
    
    // Add stsd (sample description)
    if ([track.mediaType isEqualToString:@"video"]) {
        [stbl appendData:[self createVideoStsdForTrack:track]];
    } else {
        [stbl appendData:[self createAudioStsdForTrack:track]];
    }
    
    // Add empty boxes required for fragmented MP4
    [stbl appendData:[self createEmptyBox:@"stts"]]; // Time to sample
    [stbl appendData:[self createEmptyBox:@"stsc"]]; // Sample to chunk
    [stbl appendData:[self createStszBox]];          // Sample size (special handling)
    [stbl appendData:[self createEmptyBox:@"stco"]]; // Chunk offset
    
    return [self wrapInBox:@"stbl" data:stbl];
}

- (NSData *)createVideoStsdForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *stsd = [NSMutableData data];
    
    [self writeUInt8:0 to:stsd];           // Version
    [self writeUInt8:0 to:stsd];           // Flags
    [self writeUInt16:0 to:stsd];
    [self writeUInt32:1 to:stsd];          // Entry count
    
    // AVC1 sample entry
    NSMutableData *avc1 = [NSMutableData data];
    
    // Reserved and data reference index
    for (int i = 0; i < 6; i++) {
        [self writeUInt8:0 to:avc1];
    }
    [self writeUInt16:1 to:avc1];          // Data reference index
    
    // Video specific
    [self writeUInt16:0 to:avc1];          // Pre-defined
    [self writeUInt16:0 to:avc1];          // Reserved
    [self writeUInt32:0 to:avc1];          // Pre-defined
    [self writeUInt32:0 to:avc1];          // Pre-defined
    [self writeUInt32:0 to:avc1];          // Pre-defined
    
    [self writeUInt16:track.width to:avc1];
    [self writeUInt16:track.height to:avc1];
    
    [self writeUInt32:0x00480000 to:avc1]; // Horizontal resolution - 0x00480000 = 72.0 DPI in 16.16 fixed-point
    [self writeUInt32:0x00480000 to:avc1]; // Vertical resolution - 0x00480000 = 72.0 DPI in 16.16 fixed-point
    
    [self writeUInt32:0 to:avc1];          // Reserved
    [self writeUInt16:1 to:avc1];          // Frame count
    
    // Compressor name (32 bytes)
    for (int i = 0; i < 32; i++) {
        [self writeUInt8:0 to:avc1];
    }
    
    [self writeUInt16:0x0018 to:avc1];     // Color depth - 0x0018 = 24 bits (standard RGB)
    [self writeUInt16:0xFFFF to:avc1];     // Pre-defined - always -1 (0xFFFF) per ISO spec
    
    // Add avcC box with SPS/PPS
    if (track.sps && track.pps) {
        [avc1 appendData:[self createAvcCBoxWithSPS:track.sps PPS:track.pps]];
    }
    
    [stsd appendData:[self wrapInBox:@"avc1" data:avc1]];
    
    return [self wrapInBox:@"stsd" data:stsd];
}

- (NSData *)createAvcCBoxWithSPS:(NSData *)sps PPS:(NSData *)pps {
    // Validate parameter sets before creating avcC box
    RLogDIY(@"[FMP4-MUXER] Creating avcC box with SPS: %lu bytes, PPS: %lu bytes", 
            (unsigned long)sps.length, (unsigned long)pps.length);
    
    // Use decoder to validate parameter sets
    NSString *analysisReport = [RptrH264Decoder generateDetailedReport:sps pps:pps];
    RLogDIY(@"[FMP4-MUXER] Parameter Set Validation for avcC:%@", analysisReport);
    
    NSMutableArray *hlsErrors = [NSMutableArray array];
    BOOL meetsHLS = [RptrH264Decoder meetsHLSRequirements:sps pps:pps errors:&hlsErrors];
    
    if (!meetsHLS) {
        RLogError(@"[FMP4-MUXER] Warning: Parameter sets may not meet HLS requirements");
        for (NSString *error in hlsErrors) {
            RLogError(@"[FMP4-MUXER] Issue: %@", error);
        }
    }
    
    NSMutableData *avcC = [NSMutableData data];
    
    [self writeUInt8:1 to:avcC];           // Configuration version - always 1 for avcC format
    
    // Check if SPS is valid and has enough bytes
    if (sps.length < 4) {
        RLogError(@"[FMP4-MUXER] SPS too short: %lu bytes", (unsigned long)sps.length);
        // Use default values for baseline profile
        [self writeUInt8:0x42 to:avcC];    // Profile - 0x42 = 66 = Baseline Profile
        [self writeUInt8:0x00 to:avcC];    // Profile compatibility - no constraints
        [self writeUInt8:0x1E to:avcC];    // Level - 0x1E = 30 = Level 3.0
    } else {
        const uint8_t *spsBytes = [sps bytes];
        // SPS NALU starts with header byte, profile is at index 1
        [self writeUInt8:spsBytes[1] to:avcC]; // Profile
        [self writeUInt8:spsBytes[2] to:avcC]; // Profile compatibility
        [self writeUInt8:spsBytes[3] to:avcC]; // Level
    }
    [self writeUInt8:0xFF to:avcC];        // NALU length size minus one - 0xFF = 3, so 4-byte length prefixes
    
    // SPS
    [self writeUInt8:0xE1 to:avcC];        // Number of SPS NALUs - 0xE1 = 0b11100001, lower 5 bits = 1 SPS
    [self writeUInt16:sps.length to:avcC];
    [avcC appendData:sps];
    
    // PPS
    [self writeUInt8:1 to:avcC];           // Number of PPS NALUs - 1 PPS
    [self writeUInt16:pps.length to:avcC];
    [avcC appendData:pps];
    
    RLogDIY(@"[FMP4-MUXER] Created avcC box: %lu bytes total", (unsigned long)avcC.length + 8);
    
    return [self wrapInBox:@"avcC" data:avcC];
}

- (NSData *)createAudioStsdForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *stsd = [NSMutableData data];
    
    [self writeUInt8:0 to:stsd];           // Version
    [self writeUInt8:0 to:stsd];           // Flags
    [self writeUInt16:0 to:stsd];
    [self writeUInt32:1 to:stsd];          // Entry count
    
    // MP4A sample entry
    NSMutableData *mp4a = [NSMutableData data];
    
    // Reserved
    for (int i = 0; i < 6; i++) {
        [self writeUInt8:0 to:mp4a];
    }
    [self writeUInt16:1 to:mp4a];          // Data reference index - points to first entry in dref box
    
    // Audio specific
    [self writeUInt32:0 to:mp4a];          // Reserved
    [self writeUInt32:0 to:mp4a];          // Reserved
    
    [self writeUInt16:track.channelCount to:mp4a];
    [self writeUInt16:16 to:mp4a];         // Sample size - 16 bits per sample (standard for AAC)
    
    [self writeUInt16:0 to:mp4a];          // Pre-defined
    [self writeUInt16:0 to:mp4a];          // Reserved
    
    [self writeUInt32:(uint32_t)(track.sampleRate << 16) to:mp4a]; // Sample rate in 16.16 fixed-point format (e.g., 48000 Hz << 16)
    
    // Add esds box with audio config
    if (track.audioSpecificConfig) {
        [mp4a appendData:[self createEsdsBoxWithConfig:track.audioSpecificConfig]];
    }
    
    [stsd appendData:[self wrapInBox:@"mp4a" data:mp4a]];
    
    return [self wrapInBox:@"stsd" data:stsd];
}

- (NSData *)createEsdsBoxWithConfig:(NSData *)audioConfig {
    // Simplified ESDS creation - would need full implementation for production
    NSMutableData *esds = [NSMutableData data];
    
    [self writeUInt8:0 to:esds];           // Version
    [self writeUInt8:0 to:esds];           // Flags
    [self writeUInt16:0 to:esds];
    
    // ES descriptor
    [self writeUInt8:0x03 to:esds];        // Tag
    [self writeUInt8:0x80 to:esds];        // Length (to be calculated)
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:34 + audioConfig.length to:esds];
    
    [self writeUInt16:0 to:esds];          // ES ID
    [self writeUInt8:0 to:esds];           // Flags
    
    // Decoder config descriptor
    [self writeUInt8:0x04 to:esds];        // Tag
    [self writeUInt8:0x80 to:esds];        // Length
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:20 + audioConfig.length to:esds];
    
    [self writeUInt8:0x40 to:esds];        // Object type (AAC)
    [self writeUInt8:0x15 to:esds];        // Stream type
    
    // Buffer size and bitrate
    [self writeUInt8:0 to:esds];
    [self writeUInt16:0 to:esds];
    [self writeUInt32:0 to:esds];          // Max bitrate
    [self writeUInt32:0 to:esds];          // Avg bitrate
    
    // Decoder specific info
    [self writeUInt8:0x05 to:esds];        // Tag
    [self writeUInt8:0x80 to:esds];        // Length
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:0x80 to:esds];
    [self writeUInt8:audioConfig.length to:esds];
    [esds appendData:audioConfig];
    
    // SL config descriptor
    [self writeUInt8:0x06 to:esds];        // Tag
    [self writeUInt8:0x01 to:esds];        // Length
    [self writeUInt8:0x02 to:esds];        // Pre-defined
    
    return [self wrapInBox:@"esds" data:esds];
}

- (NSData *)createEmptyBox:(NSString *)type {
    NSMutableData *box = [NSMutableData data];
    
    [self writeUInt8:0 to:box];            // Version
    [self writeUInt8:0 to:box];            // Flags
    [self writeUInt16:0 to:box];
    [self writeUInt32:0 to:box];           // Entry count
    
    return [self wrapInBox:type data:box];
}

- (NSData *)createStszBox {
    // stsz box needs to be 20 bytes total (not 16) to match Apple's format
    NSMutableData *stsz = [NSMutableData data];
    
    [self writeUInt8:0 to:stsz];           // Version
    [self writeUInt8:0 to:stsz];           // Flags
    [self writeUInt16:0 to:stsz];
    [self writeUInt32:0 to:stsz];          // Sample size (0 = varied)
    [self writeUInt32:0 to:stsz];          // Sample count
    
    return [self wrapInBox:@"stsz" data:stsz];
}

#pragma mark - Movie Extends Box (mvex)

- (NSData *)createMvexBoxWithTracks:(NSArray<RptrFMP4TrackConfig *> *)tracks {
    NSMutableData *mvex = [NSMutableData data];
    
    // Add mehd (movie extends header) - optional but helps compatibility
    NSMutableData *mehd = [NSMutableData data];
    [self writeUInt8:1 to:mehd];           // Version 1 (64-bit)
    [self writeUInt8:0 to:mehd];           // Flags
    [self writeUInt16:0 to:mehd];
    [self writeUInt64:0 to:mehd];          // Fragment duration (0 = unknown)
    [mvex appendData:[self wrapInBox:@"mehd" data:mehd]];
    
    // Add trex for each track
    for (RptrFMP4TrackConfig *track in tracks) {
        [mvex appendData:[self createTrexBoxForTrack:track]];
    }
    
    return [self wrapInBox:@"mvex" data:mvex];
}

- (NSData *)createTrexBoxForTrack:(RptrFMP4TrackConfig *)track {
    NSMutableData *trex = [NSMutableData data];
    
    [self writeUInt8:0 to:trex];           // Version
    [self writeUInt8:0 to:trex];           // Flags
    [self writeUInt16:0 to:trex];
    
    [self writeUInt32:track.trackID to:trex]; // Track ID
    [self writeUInt32:1 to:trex];          // Default sample description index
    [self writeUInt32:0 to:trex];          // Default sample duration
    [self writeUInt32:0 to:trex];          // Default sample size
    [self writeUInt32:0 to:trex];          // Default sample flags
    
    return [self wrapInBox:@"trex" data:trex];
}

#pragma mark - Media Segment Creation

- (nullable NSData *)createMediaSegmentWithSamples:(NSArray<RptrFMP4Sample *> *)samples
                                     sequenceNumber:(uint32_t)sequenceNumber
                                      baseMediaTime:(CMTime)baseMediaTime {
    if (samples.count == 0) {
        RLogDIY(@"[FMP4-MUXER] No samples for segment");
        return nil;
    }
    
    // Set stream start time on first segment
    if (!self.streamStartTimeSet && CMTIME_IS_VALID(baseMediaTime)) {
        self.streamStartTime = baseMediaTime;
        self.streamStartTimeSet = YES;
        RLogDIY(@"[FMP4-MUXER] Stream start time set: %.3f", CMTimeGetSeconds(self.streamStartTime));
    }
    
    NSMutableData *segment = [NSMutableData data];
    
    // Add moof box
    [segment appendData:[self createMoofBoxWithSamples:samples 
                                         sequenceNumber:sequenceNumber]];
    
    // Add mdat box
    [segment appendData:[self createMdatBoxWithSamples:samples]];
    
    RLogDIY(@"[FMP4-MUXER] Created segment %u: %lu bytes, %lu samples",
            sequenceNumber, (unsigned long)segment.length, (unsigned long)samples.count);
    
    return segment;
}

- (NSData *)createMoofBoxWithSamples:(NSArray<RptrFMP4Sample *> *)samples
                       sequenceNumber:(uint32_t)sequenceNumber {
    NSMutableData *moof = [NSMutableData data];
    
    // Add mfhd (movie fragment header)
    NSMutableData *mfhd = [NSMutableData data];
    [self writeUInt8:0 to:mfhd];           // Version
    [self writeUInt8:0 to:mfhd];           // Flags
    [self writeUInt16:0 to:mfhd];
    [self writeUInt32:sequenceNumber to:mfhd];
    NSData *mfhdBox = [self wrapInBox:@"mfhd" data:mfhd];
    [moof appendData:mfhdBox];
    
    // Group samples by track (should only be one track for our video-only case)
    NSMutableDictionary *samplesByTrack = [NSMutableDictionary dictionary];
    for (RptrFMP4Sample *sample in samples) {
        NSNumber *trackKey = @(sample.trackID);
        if (!samplesByTrack[trackKey]) {
            samplesByTrack[trackKey] = [NSMutableArray array];
        }
        [samplesByTrack[trackKey] addObject:sample];
    }
    
    // Calculate total size of all samples for mdat
    uint32_t mdatDataSize = 0;
    for (RptrFMP4Sample *sample in samples) {
        mdatDataSize += sample.data.length;
    }
    
    // Build traf boxes and calculate their sizes
    NSMutableArray *trafBoxes = [NSMutableArray array];
    uint32_t totalTrafSize = 0;
    
    for (NSNumber *trackKey in samplesByTrack) {
        NSArray *trackSamples = samplesByTrack[trackKey];
        NSData *trafBox = [self createTrafBoxForTrack:trackKey.unsignedIntValue
                                              samples:trackSamples
                                           baseDataOffset:0 // Will update with correct offset
                                           sequenceNumber:sequenceNumber];
        [trafBoxes addObject:trafBox];
        totalTrafSize += (uint32_t)trafBox.length;
    }
    
    // Calculate the actual data offset
    // moof box = 8 (box header) + mfhd box size + traf boxes size
    uint32_t moofSize = 8 + (uint32_t)mfhdBox.length + totalTrafSize;
    // Data offset from start of moof to start of mdat data = moof size + 8 (mdat header)
    uint32_t actualDataOffset = moofSize + 8;
    
    // Now create traf boxes with correct offset
    for (NSNumber *trackKey in samplesByTrack) {
        NSArray *trackSamples = samplesByTrack[trackKey];
        NSData *trafBox = [self createTrafBoxForTrack:trackKey.unsignedIntValue
                                              samples:trackSamples
                                           baseDataOffset:actualDataOffset
                                           sequenceNumber:sequenceNumber];
        [moof appendData:trafBox];
    }
    
    return [self wrapInBox:@"moof" data:moof];
}

- (NSData *)createTrafBoxForTrack:(uint32_t)trackID
                          samples:(NSArray<RptrFMP4Sample *> *)samples
                    baseDataOffset:(uint32_t)baseDataOffset
                    sequenceNumber:(uint32_t)sequenceNumber {
    NSMutableData *traf = [NSMutableData data];
    
    // Add tfhd (track fragment header)
    NSMutableData *tfhd = [NSMutableData data];
    uint32_t tfhdFlags = 0x020000; // 0x020000 = default-base-is-moof flag - data offsets relative to moof start
    [self writeUInt8:0 to:tfhd];           // Version
    [self writeUInt8:(tfhdFlags >> 16) & 0xFF to:tfhd];  // Flags
    [self writeUInt8:(tfhdFlags >> 8) & 0xFF to:tfhd];
    [self writeUInt8:tfhdFlags & 0xFF to:tfhd];
    [self writeUInt32:trackID to:tfhd];
    [traf appendData:[self wrapInBox:@"tfhd" data:tfhd]];
    
    // Add tfdt (decode time) - REQUIRED for fMP4
    if (samples.count > 0) {
        RptrFMP4Sample *firstSample = samples[0];
        NSMutableData *tfdt = [NSMutableData data];
        [self writeUInt8:1 to:tfdt];       // Version 1 - use 64-bit baseMediaDecodeTime for large timestamps
        [self writeUInt8:0 to:tfdt];       // Flags
        [self writeUInt16:0 to:tfdt];
        
        // Calculate relative decode time from stream start
        uint64_t decodeTime = 0;
        if (self.streamStartTimeSet && CMTIME_IS_VALID(self.streamStartTime)) {
            // Log the raw values for debugging
            RLogDIY(@"[FMP4-MUXER] Segment %u: firstSample.decodeTime=%.6f, streamStartTime=%.6f",
                    sequenceNumber,
                    CMTimeGetSeconds(firstSample.decodeTime),
                    CMTimeGetSeconds(self.streamStartTime));
            
            // Calculate time offset from stream start
            CMTime relativeTime = CMTimeSubtract(firstSample.decodeTime, self.streamStartTime);
            // Convert to 90 kHz timescale - standard for MPEG-TS/HLS video timestamps
            CMTime relativeTimeScaled = CMTimeConvertScale(relativeTime, 90000, kCMTimeRoundingMethod_RoundTowardZero);
            decodeTime = (uint64_t)relativeTimeScaled.value;
            
            // For first segment, this should be 0 or very close to 0
            if (sequenceNumber == 0) {
                RLogDIY(@"[FMP4-MUXER] First segment tfdt: %llu (%.3f seconds)", 
                        decodeTime, (double)decodeTime / 90000.0);
            }
        } else {
            // Fallback: use 0 for first segment
            RLogDIY(@"[FMP4-MUXER] Warning: Stream start time not set, using 0 for tfdt");
        }
        
        [self writeUInt64:decodeTime to:tfdt];
        [traf appendData:[self wrapInBox:@"tfdt" data:tfdt]];
    }
    
    // Add trun (track run) with correct data offset
    [traf appendData:[self createTrunBoxForSamples:samples baseDataOffset:baseDataOffset]];
    
    return [self wrapInBox:@"traf" data:traf];
}

- (NSData *)createTrunBoxForSamples:(NSArray<RptrFMP4Sample *> *)samples
                      baseDataOffset:(uint32_t)baseDataOffset {
    NSMutableData *trun = [NSMutableData data];
    
    // Trun flags bitmap: 
    // 0x000001 = data-offset present
    // 0x000100 = sample-duration present
    // 0x000200 = sample-size present
    // 0x000400 = sample-flags present
    // 0x000800 = sample-composition-time-offset (not used - no B-frames)
    uint32_t flags = 0x000701;  // 0x01 + 0x100 + 0x200 + 0x400 = all fields except composition offset
    
    [self writeUInt8:0 to:trun];           // Version 0
    [self writeUInt8:(flags >> 16) & 0xFF to:trun]; // Flags
    [self writeUInt8:(flags >> 8) & 0xFF to:trun];
    [self writeUInt8:flags & 0xFF to:trun];
    
    [self writeUInt32:(uint32_t)samples.count to:trun]; // Sample count
    
    // Write data offset (relative to start of moof)
    [self writeUInt32:baseDataOffset to:trun];
    
    // Write sample entries
    for (NSUInteger i = 0; i < samples.count; i++) {
        RptrFMP4Sample *sample = samples[i];
        
        // Calculate duration to next sample or use default
        uint32_t duration;
        if (i < samples.count - 1) {
            RptrFMP4Sample *nextSample = samples[i + 1];
            CMTime diff = CMTimeSubtract(nextSample.decodeTime, sample.decodeTime);
            CMTime diffScaled = CMTimeConvertScale(diff, 90000, kCMTimeRoundingMethod_RoundTowardZero);  // Convert to 90 kHz units
            duration = (uint32_t)diffScaled.value;
        } else {
            // Last sample - use the sample's duration
            CMTime durationScaled = CMTimeConvertScale(sample.duration, 90000, kCMTimeRoundingMethod_RoundTowardZero);  // Convert to 90 kHz units
            duration = (uint32_t)durationScaled.value;
        }
        [self writeUInt32:duration to:trun];
        
        // Sample size - use actual AVCC data size
        [self writeUInt32:(uint32_t)sample.data.length to:trun];
        
        // Sample flags bitmap (ISO/IEC 14496-12 Section 8.8.3.1):
        // Bits 0-1: reserved = 00
        // Bits 2-3: is_leading: 00 = unknown leading status
        // Bits 4-5: sample_depends_on: 01 = depends on others (P-frame), 10 = does not depend (I-frame)
        // Bits 6-7: sample_is_depended_on: 01 = other samples depend on this one
        // Bits 8-9: sample_has_redundancy: 00 = unknown redundancy
        // Bits 10-12: sample_padding_value: 000 = no padding
        // Bit 13: sample_is_non_sync_sample: 0 = sync sample (I-frame), 1 = non-sync (P-frame)
        // Bits 14-15: reserved = 00
        // Bits 16-31: sample_degradation_priority: 0x0000 = no degradation priority
        
        uint32_t sampleFlags;
        if (sample.isSync) {
            // I-frame (sync sample): does not depend on others, is depended on, is sync
            sampleFlags = 0x02010000;  // depends_on=10, is_depended_on=01, is_sync=0
        } else {
            // P-frame (non-sync): depends on others, is depended on, is non-sync  
            sampleFlags = 0x01010001;  // depends_on=01, is_depended_on=01, is_non_sync=1
        }
        [self writeUInt32:sampleFlags to:trun];
    }
    
    return [self wrapInBox:@"trun" data:trun];
}

// This method is no longer needed since we keep AVCC format

- (NSData *)createMdatBoxWithSamples:(NSArray<RptrFMP4Sample *> *)samples {
    NSMutableData *mdat = [NSMutableData data];
    
    // For fMP4, we need to keep AVCC format (length-prefixed) to match the avcC box
    // The avcC box in the init segment tells the decoder to expect AVCC format
    for (RptrFMP4Sample *sample in samples) {
        // Keep the original AVCC format data as-is
        [mdat appendData:sample.data];
    }
    
    return [self wrapInBox:@"mdat" data:mdat];
}

- (NSData *)convertAVCCToAnnexB:(NSData *)avccData {
    NSMutableData *annexBData = [NSMutableData data];
    const uint8_t *bytes = avccData.bytes;
    NSUInteger length = avccData.length;
    NSUInteger offset = 0;
    
    // Annex B start code - 0x00000001 is the H.264 NALU delimiter per ITU-T H.264 spec
    const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    
    while (offset + 4 <= length) {
        // Read 4-byte length in big-endian
        uint32_t naluLength = (bytes[offset] << 24) | 
                             (bytes[offset+1] << 16) | 
                             (bytes[offset+2] << 8) | 
                             bytes[offset+3];
        offset += 4;
        
        if (offset + naluLength > length) {
            RLogError(@"[FMP4-MUXER] Invalid NALU length: %u at offset %lu", naluLength, (unsigned long)offset);
            break;
        }
        
        // Replace length with start code
        [annexBData appendBytes:startCode length:4];
        
        // Append NALU data
        [annexBData appendBytes:&bytes[offset] length:naluLength];
        offset += naluLength;
    }
    
    return annexBData;
}

#pragma mark - Convenience Methods

- (nullable NSData *)createVideoSegmentWithNALUs:(NSArray<NSData *> *)nalus
                                         keyframes:(NSArray<NSNumber *> *)keyframes
                                    sequenceNumber:(uint32_t)sequenceNumber
                                     baseMediaTime:(CMTime)baseMediaTime {
    // This is a convenience method that creates samples from NALUs
    // For now, we'll create basic samples with the provided data
    
    if (nalus.count == 0 || nalus.count != keyframes.count) {
        RLogError(@"[FMP4-MUXER] Invalid NALU or keyframe data");
        return nil;
    }
    
    NSMutableArray<RptrFMP4Sample *> *samples = [NSMutableArray array];
    CMTime currentTime = baseMediaTime;
    CMTime frameDuration = CMTimeMake(1001, 30000); // 30fps default
    
    for (NSUInteger i = 0; i < nalus.count; i++) {
        RptrFMP4Sample *sample = [[RptrFMP4Sample alloc] init];
        sample.data = nalus[i];
        sample.duration = frameDuration;
        sample.presentationTime = currentTime;
        sample.decodeTime = currentTime;
        sample.isSync = [keyframes[i] boolValue];  // Changed from isKeyframe to isSync
        
        [samples addObject:sample];
        currentTime = CMTimeAdd(currentTime, frameDuration);
    }
    
    // Find the video track
    RptrFMP4TrackConfig *videoTrack = nil;
    for (RptrFMP4TrackConfig *track in self.tracks) {
        if ([track.mediaType isEqualToString:@"video"]) {  // Changed from handlerType to mediaType
            videoTrack = track;
            break;
        }
    }
    
    if (!videoTrack) {
        RLogError(@"[FMP4-MUXER] No video track configured");
        return nil;
    }
    
    // Set track ID for all samples
    for (RptrFMP4Sample *sample in samples) {
        sample.trackID = videoTrack.trackID;
    }
    
    // Create segment using simpler approach
    NSMutableData *segment = [NSMutableData data];
    
    // Create moof box with samples
    NSData *moof = [self createMoofBoxWithSamples:samples
                                    sequenceNumber:sequenceNumber];
    if (!moof) {
        RLogError(@"[FMP4-MUXER] Failed to create moof box");
        return nil;
    }
    [segment appendData:moof];
    
    // Create mdat box
    NSMutableData *mdat = [NSMutableData data];
    for (RptrFMP4Sample *sample in samples) {
        [mdat appendData:sample.data];
    }
    NSData *mdatBox = [self wrapInBox:@"mdat" data:mdat];
    [segment appendData:mdatBox];
    
    return segment;
}

@end