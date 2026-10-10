#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger M7WebcamTargetFPS;
FOUNDATION_EXPORT const CGFloat M7WebcamJPEGQuality;

// normalizedCenter uses the same top-left origin as the M7 preview/tracker.
FOUNDATION_EXPORT CGRect M7WebcamCropRect(CGSize sourceSize, CGSize targetSize,
    CGPoint normalizedCenter);

// Confine an encoder instance to one serial queue.
@interface M7WebcamEncoder : NSObject
- (NSData * _Nullable)JPEGDataForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    vertical:(BOOL)vertical
                            normalizedCenter:(CGPoint)center
                                       error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
