#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import "../iOS/M7WebcamEncoder.h"
#include <assert.h>
#include <math.h>

static void AssertNear(CGFloat actual, CGFloat expected) {
    assert(fabs(actual - expected) < .01);
}

// First NAL unit type of an Annex-B access unit.
static int FirstNALType(NSData *accessUnit) {
    const uint8_t *bytes = accessUnit.bytes;
    assert(accessUnit.length > 5 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1);
    return bytes[4] & 0x1f;
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

        // Portrait 1440x1920 buffer; device space is the landscape sensor.
        CGSize portrait = CGSizeMake(1440, 1920);
        CGPoint middle = M7WebcamDevicePoint(portrait, portrait, CGPointMake(.5, .5), CGPointMake(.5, .5));
        AssertNear(middle.x, .5); AssertNear(middle.y, .5);
        CGPoint topLeft = M7WebcamDevicePoint(portrait, portrait, CGPointMake(.5, .5), CGPointMake(0, 0));
        AssertNear(topLeft.x, 0); AssertNear(topLeft.y, 1);
        CGPoint topRight = M7WebcamDevicePoint(portrait, portrait, CGPointMake(.5, .5), CGPointMake(1, 0));
        AssertNear(topRight.x, 0); AssertNear(topRight.y, 0);
        CGPoint webcamTop = M7WebcamDevicePoint(portrait, CGSizeMake(1280, 720), CGPointMake(.5, .5),
            CGPointMake(.5, 0));
        AssertNear(webcamTop.x, 555.0/1920.0); AssertNear(webcamTop.y, .5);

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
        // H.264 takes the crop native to the buffer; MJPEG keeps 720p for old clients.
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, YES, NO).width, 1080);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, YES, NO).height, 1920);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, NO, YES).width, 1920);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, NO, YES).height, 1080);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, NO, NO).width, 1280);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecH264, YES, YES).height, 1280);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecMJPEG, NO, YES).width, 1280);
        AssertNear(M7WebcamOutputSize(M7WebcamCodecMJPEG, YES, NO).width, 720);

        // Landscape (Home right) is the device space itself; inverted is 180°.
        CGSize landscape = CGSizeMake(1920, 1440);
        CGPoint corner = M7WebcamDevicePointForMount(M7CameraMountLandscape, landscape, landscape,
            CGPointMake(.5, .5), CGPointMake(0, 0));
        AssertNear(corner.x, 0); AssertNear(corner.y, 0);
        CGPoint inverted = M7WebcamDevicePointForMount(M7CameraMountLandscapeInverted, landscape, landscape,
            CGPointMake(.5, .5), CGPointMake(.25, 0));
        AssertNear(inverted.x, .75); AssertNear(inverted.y, 1);
        // The top edge of the 1920x1080 crop sits 180 px below the buffer's top.
        CGPoint landscapeTop = M7WebcamDevicePointForMount(M7CameraMountLandscape, landscape,
            CGSizeMake(1920, 1080), CGPointMake(.5, .5), CGPointMake(.5, 0));
        AssertNear(landscapeTop.x, .5); AssertNear(landscapeTop.y, 180.0/1440.0);
        CGPoint portraitCorner = M7CameraMountDevicePoint(M7CameraMountPortrait, CGPointMake(0, 0));
        AssertNear(portraitCorner.x, 0); AssertNear(portraitCorner.y, 1);
        assert(M7WebcamH264BitRate(CGSizeMake(1080, 1920)) > M7WebcamH264BitRate(CGSizeMake(1280, 720)));
        assert(M7WebcamAnnexBFromSampleBuffer(NULL, NULL) == nil);

        // CI runners may lack an H.264 encoder; then the instance must say so.
        BOOL keyframe = NO;
        NSData *first = [encoder H264AccessUnitForPixelBuffer:pixel vertical:YES
            normalizedCenter:CGPointMake(.5, .5) presentationTime:CMTimeMake(0, 30)
            forceKeyframe:YES keyframe:&keyframe error:&error];
        if (first) {
            assert(encoder.h264Available && keyframe);
            assert(FirstNALType(first) == 7);  // SPS leads every keyframe.
            NSData *second = nil;
            for (int64_t frame = 1; frame < 4 && !second.length; ++frame)
                second = [encoder H264AccessUnitForPixelBuffer:pixel vertical:YES
                    normalizedCenter:CGPointMake(.5, .5) presentationTime:CMTimeMake(frame, 30)
                    forceKeyframe:NO keyframe:&keyframe error:&error];
            assert(second.length && !keyframe && FirstNALType(second) != 7);
            NSData *forced = [encoder H264AccessUnitForPixelBuffer:pixel vertical:YES
                normalizedCenter:CGPointMake(.5, .5) presentationTime:CMTimeMake(5, 30)
                forceKeyframe:YES keyframe:&keyframe error:&error];
            assert(forced.length && keyframe && FirstNALType(forced) == 7);
            printf("Webcam H.264: keyframe %lu bytes, P-frame %lu bytes.\n",
                (unsigned long)first.length, (unsigned long)second.length);
        } else {
            assert(!encoder.h264Available && error);
            printf("Webcam H.264 unavailable on this runner (status %d).\n", encoder.h264Status);
        }
        CVPixelBufferRelease(pixel);
        assert(([@[@"videoToolbox", @"coreImage"] containsObject:encoder.backend]));
        printf("Webcam encoder backend: %s (VideoToolbox status %d).\n",
            encoder.backend.UTF8String, encoder.hardwareStatus);
        puts("Webcam encoder: crop, focus point mapping, tracking-center clamp, 16:9/9:16 JPEG sizes and H.264 access units passed.");
    }
    return 0;
}
