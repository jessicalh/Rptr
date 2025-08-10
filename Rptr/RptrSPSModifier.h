//
//  RptrSPSModifier.h
//  Rptr
//
//  Created to add VUI parameters to VideoToolbox-generated SPS for Safari compatibility
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RptrSPSModifier : NSObject

/**
 * Adds VUI parameters with timing information to an H.264 SPS that lacks them.
 * This is required for Safari's native HLS player compatibility.
 *
 * @param originalSPS The original SPS data from VideoToolbox (typically 10 bytes for Main/Baseline)
 * @param frameRate The desired frame rate (e.g., 15.0 for 15 fps)
 * @return Modified SPS data with VUI parameters including timing information
 */
+ (NSData *)addVUIParametersToSPS:(NSData *)originalSPS frameRate:(float)frameRate;

/**
 * Analyzes an SPS and logs its structure for debugging
 */
+ (void)analyzeSPS:(NSData *)spsData label:(NSString *)label;

@end

NS_ASSUME_NONNULL_END