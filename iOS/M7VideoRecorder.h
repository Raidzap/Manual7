#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Receives AVCaptureVideoDataOutput and AVCaptureAudioDataOutput samples on one
// serial queue and writes a single 4:3 master. Every method is queue-confined.
@interface M7VideoRecorder : NSObject
@property (nonatomic, readonly) NSURL *outputURL;
@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly) BOOL finished;
- (instancetype)initWithOutputURL:(NSURL *)url;
- (nullable NSError *)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
                               mediaType:(AVMediaType)mediaType;
- (NSTimeInterval)timeOffsetForSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)noteDroppedVideoSample;
- (NSDictionary *)snapshot;
- (void)finishWithCompletion:(void (^)(NSURL *url, NSDictionary *summary,
                                       NSError * _Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
