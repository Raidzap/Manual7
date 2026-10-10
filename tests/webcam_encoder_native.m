#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import "../iOS/M7WebcamEncoder.h"
#include <assert.h>
#include <math.h>

static void AssertNear(CGFloat actual, CGFloat expected) {
    assert(fabs(actual - expected) < .01);
}

static void AssertJPEGSize(NSData *data, NSUInteger width, NSUInteger height) {
    assert(data.length > 1000);
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    assert(source);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    assert([properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue] == width);
    assert([properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue] == height);
}

int main(void) {
    @autoreleasepool {
        assert(M7WebcamTargetFPS == 30);
        assert(M7WebcamJPEGQuality > .5 && M7WebcamJPEGQuality < .8);
        CGRect horizontal = M7WebcamCropRect(CGSizeMake(1920, 1440), CGSizeMake(1280, 720),
            CGPointMake(.5, .5));
        AssertNear(horizontal.origin.x, 0); AssertNear(horizontal.origin.y, 180);
        AssertNear(horizontal.size.width, 1920); AssertNear(horizontal.size.height, 1080);
        CGRect vertical = M7WebcamCropRect(CGSizeMake(1920, 1440), CGSizeMake(720, 1280),
            CGPointMake(.5, .5));
        AssertNear(vertical.origin.x, 555); AssertNear(vertical.origin.y, 0);
        AssertNear(vertical.size.width, 810); AssertNear(vertical.size.height, 1440);
        CGRect edge = M7WebcamCropRect(CGSizeMake(1920, 1440), CGSizeMake(720, 1280),
            CGPointMake(2, -1));
        AssertNear(edge.origin.x, 1110); AssertNear(edge.origin.y, 0);
        CGRect horizontalTop = M7WebcamCropRect(CGSizeMake(1920, 1440), CGSizeMake(1280, 720),
            CGPointMake(.5, 0));
        AssertNear(horizontalTop.origin.y, 360);

        CVPixelBufferRef pixel = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
        assert(CVPixelBufferCreate(NULL, 640, 480, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &pixel) == kCVReturnSuccess);
        assert(CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess);
        uint8_t *base = CVPixelBufferGetBaseAddress(pixel);
        size_t stride = CVPixelBufferGetBytesPerRow(pixel);
        for (size_t y = 0; y < 480; ++y) for (size_t x = 0; x < 640; ++x) {
            uint8_t *p = base + y*stride + x*4;
            p[0] = (uint8_t)(x % 256); p[1] = (uint8_t)(y % 256);
            p[2] = (uint8_t)((x+y) % 256); p[3] = 255;
        }
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        M7WebcamEncoder *encoder = [M7WebcamEncoder new];
        NSError *error = nil;
        NSData *landscapeJPEG = [encoder JPEGDataForPixelBuffer:pixel vertical:NO
            normalizedCenter:CGPointMake(.5, .5) error:&error];
        assert(landscapeJPEG && !error); AssertJPEGSize(landscapeJPEG, 1280, 720);
        NSData *portraitJPEG = [encoder JPEGDataForPixelBuffer:pixel vertical:YES
            normalizedCenter:CGPointMake(.25, .75) error:&error];
        assert(portraitJPEG && !error); AssertJPEGSize(portraitJPEG, 720, 1280);
        CVPixelBufferRelease(pixel);
        puts("Webcam encoder: crop, tracking-center clamp and 16:9/9:16 JPEG sizes passed.");
    }
    return 0;
}
