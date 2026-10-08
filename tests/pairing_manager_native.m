#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import "../iOS/M7PairingManager.h"
#include <assert.h>
#include <stdio.h>

static CVPixelBufferRef QRPixelBuffer(NSString *message) {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[message dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"L" forKey:@"inputCorrectionLevel"];
    CIImage *code = filter.outputImage;
    // CIQRCodeGenerator has no quiet zone. Vision expects the four white
    // modules that a printed/displayed QR normally has around the code.
    CGRect quietExtent = CGRectInset(code.extent, -4, -4);
    CIImage *white = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]]
        imageByCroppingToRect:quietExtent];
    CIImage *image = [[code imageByCompositingOverImage:white]
        imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
    CGRect untranslated = CGRectIntegral(image.extent);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -untranslated.origin.x, -untranslated.origin.y)];
    CGRect extent = CGRectIntegral(image.extent);
    NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
    CVPixelBufferRef pixel = NULL;
    assert(CVPixelBufferCreate(kCFAllocatorDefault, extent.size.width, extent.size.height,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixel) == kCVReturnSuccess);
    CIContext *ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    CGImageRef cgImage = [ciContext createCGImage:image fromRect:extent];
    assert(cgImage);
    assert(CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixel),
        CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 8,
        CVPixelBufferGetBytesPerRow(pixel), colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    assert(bitmap);
    CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
    CGContextFillRect(bitmap, CGRectMake(0, 0, extent.size.width, extent.size.height));
    CGContextDrawImage(bitmap, CGRectMake(0, 0, extent.size.width, extent.size.height), cgImage);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(cgImage);
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    return pixel;
}

int main(void) {
    @autoreleasepool {
        NSString *token = @"abcdefghijklmnopqrstuvwxyzABCDEFG1234567890_-";
        NSString *payload = [NSString stringWithFormat:@"manual7://pair?callback=%@&token=%@&name=Linux",
            [@"http://192.168.1.20:43123/v1/pair" stringByAddingPercentEncodingWithAllowedCharacters:
                NSCharacterSet.URLQueryAllowedCharacterSet], token];
        NSError *error = nil;
        NSDictionary *parsed = M7ParsePairingPayload(payload, &error);
        assert(parsed && !error);
        assert([parsed[@"host"] isEqual:@"192.168.1.20"]);
        assert([parsed[@"port"] integerValue] == 43123);
        assert([parsed.description containsString:token]); // parser result is transient by design

        assert(!M7ParsePairingPayload(@"manual7://pair?callback=http://8.8.8.8:4000/v1/pair&token=abcdefghijklmnopqrstuvwxyzABCDEFG1234567890", &error));
        assert([error.domain isEqual:M7PairingErrorDomain]);

        M7PairingManager *manager = [M7PairingManager new];
        CVPixelBufferRef pixel = QRPixelBuffer(payload);
        error = nil;
        NSDictionary *detected = [manager pairingPayloadFromPixelBuffer:pixel error:&error];
        CVPixelBufferRelease(pixel);
        if (!detected || error) fprintf(stderr, "Vision result: %s\n",
            (error.localizedDescription ?: @"no QR observation").UTF8String);
        assert(detected && !error);
        NSDictionary *snapshot = manager.snapshot;
        assert([snapshot[@"state"] isEqual:@"recognized"]);
        assert(![snapshot.description containsString:token]);
        assert([snapshot[@"framesAnalyzed"] integerValue] == 1);
        puts("Pairing manager: payload validation, Vision QR and redacted snapshot passed.");
    }
    return 0;
}
