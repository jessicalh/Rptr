//
//  RptrH264Decoder.h
//  Rptr
//
//  H.264 Parameter Set Decoder and Validator
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// H.264 Profile IDs
typedef NS_ENUM(uint8_t, RptrH264Profile) {
    RptrH264ProfileBaseline = 66,
    RptrH264ProfileMain = 77,
    RptrH264ProfileExtended = 88,
    RptrH264ProfileHigh = 100,
    RptrH264ProfileHigh10 = 110,
    RptrH264ProfileHigh422 = 122,
    RptrH264ProfileHigh444 = 244
};

// SPS Decoded Information
@interface RptrSPSInfo : NSObject
@property (nonatomic, assign) uint8_t nalUnitType;
@property (nonatomic, assign) uint8_t profileIdc;
@property (nonatomic, assign) uint8_t constraintSetFlags;
@property (nonatomic, assign) uint8_t levelIdc;
@property (nonatomic, assign) uint32_t seqParameterSetId;
@property (nonatomic, assign) uint32_t log2MaxFrameNumMinus4;
@property (nonatomic, assign) uint32_t picOrderCntType;
@property (nonatomic, assign) uint32_t log2MaxPicOrderCntLsbMinus4;
@property (nonatomic, assign) uint32_t maxNumRefFrames;
@property (nonatomic, assign) BOOL gapsInFrameNumValueAllowedFlag;
@property (nonatomic, assign) uint32_t picWidthInMbsMinus1;
@property (nonatomic, assign) uint32_t picHeightInMapUnitsMinus1;
@property (nonatomic, assign) BOOL frameMbsOnlyFlag;
@property (nonatomic, assign) BOOL mbAdaptiveFrameFieldFlag;
@property (nonatomic, assign) BOOL direct8x8InferenceFlag;
@property (nonatomic, assign) BOOL frameCroppingFlag;
@property (nonatomic, assign) uint32_t frameCropLeftOffset;
@property (nonatomic, assign) uint32_t frameCropRightOffset;
@property (nonatomic, assign) uint32_t frameCropTopOffset;
@property (nonatomic, assign) uint32_t frameCropBottomOffset;
@property (nonatomic, assign) BOOL vuiParametersPresentFlag;

// Calculated values
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, strong) NSString *profileString;
@property (nonatomic, strong) NSString *levelString;

// Validation results
@property (nonatomic, assign) BOOL isValid;
@property (nonatomic, strong) NSMutableArray<NSString *> *validationErrors;
@property (nonatomic, strong) NSMutableArray<NSString *> *validationWarnings;
@end

// PPS Decoded Information
@interface RptrPPSInfo : NSObject
@property (nonatomic, assign) uint8_t nalUnitType;
@property (nonatomic, assign) uint32_t picParameterSetId;
@property (nonatomic, assign) uint32_t seqParameterSetId;
@property (nonatomic, assign) BOOL entropyCodingModeFlag;
@property (nonatomic, assign) BOOL bottomFieldPicOrderInFramePresentFlag;
@property (nonatomic, assign) uint32_t numSliceGroupsMinus1;
@property (nonatomic, assign) uint32_t numRefIdxL0DefaultActiveMinus1;
@property (nonatomic, assign) uint32_t numRefIdxL1DefaultActiveMinus1;
@property (nonatomic, assign) BOOL weightedPredFlag;
@property (nonatomic, assign) uint8_t weightedBipredIdc;
@property (nonatomic, assign) int32_t picInitQpMinus26;
@property (nonatomic, assign) int32_t picInitQsMinus26;
@property (nonatomic, assign) int32_t chromaQpIndexOffset;
@property (nonatomic, assign) BOOL deblockingFilterControlPresentFlag;
@property (nonatomic, assign) BOOL constrainedIntraPredFlag;
@property (nonatomic, assign) BOOL redundantPicCntPresentFlag;

// Validation results
@property (nonatomic, assign) BOOL isValid;
@property (nonatomic, strong) NSMutableArray<NSString *> *validationErrors;
@property (nonatomic, strong) NSMutableArray<NSString *> *validationWarnings;
@end

// Bitstream Reader for Exponential-Golomb Decoding
@interface RptrBitstreamReader : NSObject
- (instancetype)initWithData:(NSData *)data;
- (uint32_t)readBits:(int)numBits;
- (uint32_t)readUnsignedExpGolomb;
- (int32_t)readSignedExpGolomb;
- (BOOL)hasMoreData;
- (NSUInteger)bytesRead;
- (NSUInteger)bitsRead;
@end

// H.264 Parameter Set Decoder
@interface RptrH264Decoder : NSObject

// Decode and validate SPS
+ (RptrSPSInfo *)decodeSPS:(NSData *)spsData;

// Decode and validate PPS
+ (RptrPPSInfo *)decodePPS:(NSData *)ppsData;

// Validate SPS/PPS pair for compatibility
+ (NSDictionary *)validateSPSPPSPair:(NSData *)spsData pps:(NSData *)ppsData;

// Generate detailed report for logging
+ (NSString *)generateDetailedReport:(NSData *)spsData pps:(NSData *)ppsData;

// Check if parameter sets meet HLS requirements
+ (BOOL)meetsHLSRequirements:(NSData *)spsData pps:(NSData *)ppsData errors:(NSMutableArray<NSString *> * _Nullable * _Nullable)errors;

@end

NS_ASSUME_NONNULL_END