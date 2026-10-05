#import <Foundation/Foundation.h>
#import "../iOS/M7VideoReframe.h"
#include <assert.h>
#include <math.h>
#include <string.h>

static void Near(CGFloat a, CGFloat b) { assert(fabs(a-b) < .01); }

static void CheckCover(CGSize natural, CGAffineTransform preferred, CGSize target,
    CGRect expectedBounds) {
    CGAffineTransform transform = M7AspectFillVideoTransform(natural, preferred, target);
    CGRect mapped = CGRectApplyAffineTransform((CGRect){CGPointZero, natural}, transform);
    Near(mapped.origin.x, expectedBounds.origin.x);
    Near(mapped.origin.y, expectedBounds.origin.y);
    Near(mapped.size.width, expectedBounds.size.width);
    Near(mapped.size.height, expectedBounds.size.height);
    assert(CGRectGetMinX(mapped) <= .01 && CGRectGetMinY(mapped) <= .01);
    assert(CGRectGetMaxX(mapped) + .01 >= target.width);
    assert(CGRectGetMaxY(mapped) + .01 >= target.height);
    Near(CGRectGetMidX(mapped), target.width/2.0);
    Near(CGRectGetMidY(mapped), target.height/2.0);
}

static NSURL *MakeFixture(NSURL *directory) {
    NSURL *url = [directory URLByAppendingPathComponent:@"fixture.mov"];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
    assert(writer && !error);
    NSDictionary *settings = @{AVVideoCodecKey:AVVideoCodecTypeH264,
        AVVideoWidthKey:@320, AVVideoHeightKey:@240};
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
        outputSettings:settings];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey:@320, (id)kCVPixelBufferHeightKey:@240}];
    assert([writer canAddInput:input]); [writer addInput:input];
    assert([writer startWriting]); [writer startSessionAtSourceTime:kCMTimeZero];
    for (int frame = 0; frame < 15; ++frame) {
        while (!input.readyForMoreMediaData) [NSThread sleepForTimeInterval:.001];
        CVPixelBufferRef pixel = NULL;
        assert(CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixel) == kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel, 0);
        memset(CVPixelBufferGetBaseAddress(pixel), frame * 7, CVPixelBufferGetDataSize(pixel));
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        assert([adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame, 30)]);
        CVPixelBufferRelease(pixel);
    }
    [input markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC)) == 0);
    assert(writer.status == AVAssetWriterStatusCompleted);
    return url;
}

static void CheckExport(NSURL *source, NSURL *directory, M7VideoFrame frame) {
    NSString *name = frame == M7VideoFrameVertical ? @"vertical.mp4" : @"horizontal.mp4";
    NSURL *output = [directory URLByAppendingPathComponent:name];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    __block NSDictionary *details = nil;
    M7ExportVideoFrame(source, output, frame, ^(NSDictionary *value, NSError *error) {
        details = value; failure = error; dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC)) == 0);
    assert(!failure && [details[@"exists"] boolValue] && [details[@"bytes"] integerValue] > 0);
    CGSize expected = M7VideoFrameSize(frame);
    Near([details[@"displayWidth"] doubleValue], expected.width);
    Near([details[@"displayHeight"] doubleValue], expected.height);
}

int main(void) {
    @autoreleasepool {
        assert(CGSizeEqualToSize(M7VideoFrameSize(M7VideoFrameHorizontal), CGSizeMake(1920, 1080)));
        assert(CGSizeEqualToSize(M7VideoFrameSize(M7VideoFrameVertical), CGSizeMake(1080, 1920)));
        CheckCover(CGSizeMake(1920, 1440), CGAffineTransformIdentity, CGSizeMake(1920, 1080),
            CGRectMake(0, -180, 1920, 1440));
        CheckCover(CGSizeMake(1920, 1440), CGAffineTransformIdentity, CGSizeMake(1080, 1920),
            CGRectMake(-740, 0, 2560, 1920));
        // A portrait transform must first normalize its negative/translated
        // bounds, then apply the same centered aspect-fill rule.
        CGAffineTransform portrait = CGAffineTransformMake(0, 1, -1, 0, 1440, 0);
        CheckCover(CGSizeMake(1920, 1440), portrait, CGSizeMake(1080, 1920),
            CGRectMake(-180, 0, 1440, 1920));
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *fixture = MakeFixture(directory);
        CheckExport(fixture, directory, M7VideoFrameHorizontal);
        CheckExport(fixture, directory, M7VideoFrameVertical);
        assert([NSFileManager.defaultManager removeItemAtURL:directory error:nil]);
        puts("Video reframe: centered transforms and real 16:9/9:16 AVFoundation exports passed.");
    }
    return 0;
}
