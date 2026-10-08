#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import "../iOS/M7PairingManager.h"
#include <assert.h>

static CVPixelBufferRef QRPixelBuffer(NSString *message) {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[message dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *image = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(12, 12)];
    CGRect extent = CGRectIntegral(image.extent);
    NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
    CVPixelBufferRef pixel = NULL;
    assert(CVPixelBufferCreate(kCFAllocatorDefault, extent.size.width, extent.size.height,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixel) == kCVReturnSuccess);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [[CIContext contextWithOptions:nil] render:image toCVPixelBuffer:pixel bounds:extent colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
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
        assert(detected && !error);
        NSDictionary *snapshot = manager.snapshot;
        assert([snapshot[@"state"] isEqual:@"recognized"]);
        assert(![snapshot.description containsString:token]);
        assert([snapshot[@"framesAnalyzed"] integerValue] == 1);
        puts("Pairing manager: payload validation, Vision QR and redacted snapshot passed.");
    }
    return 0;
}
