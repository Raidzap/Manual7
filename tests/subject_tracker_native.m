#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "../iOS/M7SubjectTracker.h"
#include <assert.h>
#include <math.h>
#include <string.h>

int main(void) {
    @autoreleasepool {
        CVPixelBufferRef pixel = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
        assert(CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &pixel) == kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel, 0);
        memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetDataSize(pixel));
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        M7SubjectTracker *tracker = [M7SubjectTracker new];
        for (NSUInteger index = 0; index < 6; ++index) {
            NSDictionary *result = [tracker analyzePixelBuffer:pixel timeOffset:index*.2 record:YES];
            assert(result[@"performed"] && result[@"detected"] && result[@"centerX"] && result[@"centerY"]);
        }
        NSDictionary *snapshot = tracker.snapshot;
        assert([snapshot[@"analyses"] integerValue] == 6);
        assert([snapshot[@"pointCount"] integerValue] == 6);
        assert(tracker.trackingPoints.count == 6);
        assert(fabs([snapshot[@"centerX"] doubleValue]-.5) < .001);
        assert(fabs([snapshot[@"centerY"] doubleValue]-.5) < .001);
        NSDictionary *report = @{@"snapshot":snapshot, @"points":tracker.trackingPoints};
        assert([NSJSONSerialization isValidJSONObject:report]);
        [tracker reset];
        assert([tracker.snapshot[@"analyses"] integerValue] == 0);
        CVPixelBufferRelease(pixel);
        puts("Subject tracker: Vision no-subject path, timed trace, snapshot and reset passed.");
    }
    return 0;
}
