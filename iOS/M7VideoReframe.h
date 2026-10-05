#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, M7VideoFrame) {
    M7VideoFrameHorizontal = 0,
    M7VideoFrameVertical = 1,
};

FOUNDATION_EXPORT CGSize M7VideoFrameSize(M7VideoFrame frame);
FOUNDATION_EXPORT CGAffineTransform M7AspectFillVideoTransform(CGSize naturalSize,
    CGAffineTransform preferredTransform, CGSize renderSize);
FOUNDATION_EXPORT NSDictionary *M7VideoFileDetails(NSURL *url);
FOUNDATION_EXPORT void M7ExportVideoFrame(NSURL *sourceURL, NSURL *outputURL,
    M7VideoFrame frame, void (^completion)(NSDictionary *details, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
