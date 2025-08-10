//
//  RptrSegmentValidator.h
//  Rptr
//
//  Debug-only validator for fMP4 segments using iOS native APIs
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RptrSegmentValidationResult : NSObject
@property (nonatomic, assign) BOOL isValid;
@property (nonatomic, strong) NSMutableArray<NSString *> *errors;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *info;
@end

@interface RptrSegmentValidator : NSObject

// Comprehensive validation using multiple iOS APIs
+ (RptrSegmentValidationResult *)validateSegment:(NSData *)segmentData 
                                      initSegment:(NSData *)initSegment
                                   sequenceNumber:(uint32_t)sequenceNumber;

// Quick validation without init segment (for media segments only)
+ (RptrSegmentValidationResult *)quickValidateSegment:(NSData *)segmentData;

// Validate using AVAssetReader (most thorough)
+ (RptrSegmentValidationResult *)validateWithAVAssetReader:(NSData *)segmentData 
                                                initSegment:(NSData *)initSegment;

// Validate using CMSampleBuffer APIs
+ (RptrSegmentValidationResult *)validateWithCMSampleBuffer:(NSData *)segmentData;

// Parse and log all boxes in detail
+ (NSString *)detailedBoxStructure:(NSData *)segmentData;

@end

NS_ASSUME_NONNULL_END