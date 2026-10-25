#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger M7WebcamTargetFPS;
FOUNDATION_EXPORT const CGFloat M7WebcamJPEGQuality;

// normalizedCenter uses the same top-left origin as the M7 preview/tracker.
FOUNDATION_EXPORT CGRect M7WebcamCropRect(CGSize sourceSize, CGSize targetSize,
    CGPoint normalizedCenter);

// Maps a top-left normalized point of the published webcam frame to the
// AVFoundation device point of interest of a portrait-oriented source buffer.
// Pass targetSize == sourceSize for the uncropped camera frame.
FOUNDATION_EXPORT CGPoint M7WebcamDevicePoint(CGSize portraitSourceSize, CGSize targetSize,
    CGPoint normalizedCenter, CGPoint framePoint);

// Confine an encoder instance to one serial queue. The JPEG comes from the
// VideoToolbox encoder when it works and from Core Image otherwise; the
// first VideoToolbox failure switches the instance to Core Image for good.
@interface M7WebcamEncoder : NSObject
// "videoToolbox" or "coreImage"; readable from any queue.
@property (atomic, readonly, copy) NSString *backend;
// Last VideoToolbox OSStatus, 0 when it never failed.
@property (atomic, readonly) int32_t hardwareStatus;
- (NSData * _Nullable)JPEGDataForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    vertical:(BOOL)vertical
                            normalizedCenter:(CGPoint)center
                                       error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
