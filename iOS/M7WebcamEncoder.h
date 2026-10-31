#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "M7WebcamCodec.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger M7WebcamTargetFPS;
FOUNDATION_EXPORT const CGFloat M7WebcamJPEGQuality;

// How the iPhone is mounted, which sets the orientation of the video data
// output buffers. Landscape (Home button on the right) is the back sensor's
// native orientation: the buffer is 1920x1440 and needs no rotation.
typedef NS_ENUM(NSInteger, M7CameraMount) {
    M7CameraMountLandscape = 0,
    M7CameraMountLandscapeInverted = 1,
    M7CameraMountPortrait = 2,
};

// MJPEG keeps 1280x720 / 720x1280 for older clients. H.264 publishes the
// crop that is native to the buffer: 16:9 of a 1920x1440 landscape buffer is
// 1920x1080 and 9:16 of a 1440x1920 portrait buffer is 1080x1920. The crosswise
// crops (1440x810 and 810x1440) stay at 720p instead of being upscaled.
FOUNDATION_EXPORT CGSize M7WebcamOutputSize(M7WebcamCodec codec, BOOL vertical, BOOL landscapeSource);

// Top-left normalized point of a buffer delivered for `mount` to the
// AVCaptureDevice point of interest (landscape, Home button on the right).
FOUNDATION_EXPORT CGPoint M7CameraMountDevicePoint(M7CameraMount mount, CGPoint bufferPoint);
FOUNDATION_EXPORT int32_t M7WebcamH264BitRate(CGSize outputSize);

// Converts one VideoToolbox H.264 sample (AVCC, length-prefixed NAL units) to
// an Annex-B access unit. Keyframes are prefixed with SPS/PPS so a client can
// start decoding from any of them.
FOUNDATION_EXPORT NSData * _Nullable M7WebcamAnnexBFromSampleBuffer(CMSampleBufferRef _Nullable sample,
    BOOL * _Nullable keyframe);

// normalizedCenter uses the same top-left origin as the M7 preview/tracker.
FOUNDATION_EXPORT CGRect M7WebcamCropRect(CGSize sourceSize, CGSize targetSize,
    CGPoint normalizedCenter);

// Maps a top-left normalized point of the published webcam frame to the
// AVFoundation device point of interest of a source buffer delivered for
// `mount`. Pass targetSize == sourceSize for the uncropped camera frame.
FOUNDATION_EXPORT CGPoint M7WebcamDevicePointForMount(M7CameraMount mount, CGSize sourceSize,
    CGSize targetSize, CGPoint normalizedCenter, CGPoint framePoint);
// Portrait-buffer shorthand of M7WebcamDevicePointForMount.
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
// NO after the first H.264 failure; the H.264 clients must then be closed.
@property (atomic, readonly) BOOL h264Available;
@property (atomic, readonly) int32_t h264Status;
// Camera frame rate; the H.264 session is rebuilt when it changes.
@property (atomic) NSUInteger frameRate;
- (NSData * _Nullable)JPEGDataForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    vertical:(BOOL)vertical
                            normalizedCenter:(CGPoint)center
                                       error:(NSError **)error;
// Synchronous: returns the Annex-B access unit of this frame.
- (NSData * _Nullable)H264AccessUnitForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                          vertical:(BOOL)vertical
                                  normalizedCenter:(CGPoint)center
                                  presentationTime:(CMTime)presentationTime
                                     forceKeyframe:(BOOL)forceKeyframe
                                          keyframe:(BOOL * _Nullable)keyframe
                                             error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
