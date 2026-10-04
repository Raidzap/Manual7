// Native ImageIO checks. Run on macOS with tests/run_jpeg_native.sh.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../iOS/M7JPEG.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSData *Fixture(NSInteger orientation, CFStringRef type) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 640, 480, 8, 640*4, space, kCGImageAlphaPremultipliedLast);
    Check(context != NULL, @"fixture context");
    CGContextSetRGBFillColor(context, .9, .1, .2, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 640, 480));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData new];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, type, 1, NULL);
    Check(dest != NULL, @"fixture destination");
    NSDictionary *metadata = @{
        (id)kCGImagePropertyOrientation:@(orientation),
        (id)kCGImagePropertyExifDictionary:@{
            (id)kCGImagePropertyExifISOSpeedRatings:@[@160],
            (id)kCGImagePropertyExifExposureTime:@.008}};
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)metadata);
    Check(CGImageDestinationFinalize(dest), @"fixture encode");
    CFRelease(dest); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(space);
    return data;
}

int main(void) {
    @autoreleasepool {
        for (NSNumber *orientation in @[@1, @6, @8]) {
            NSData *source = Fixture(orientation.integerValue, CFSTR("public.jpeg"));
            NSError *error = nil;
            Check([M7JPEGForLongEdge(source, 0, &error) isEqualToData:source], @"Original must be byte-identical");
            Check([M7JPEGForLongEdge(source, 1280, &error) isEqualToData:source], @"No upscale");
            for (NSNumber *size in @[@320, @256, @128]) {
                NSData *result = M7JPEGForLongEdge(source, size.unsignedIntegerValue, &error);
                Check(result != nil && error == nil, @"JPEG reduction succeeds");
                NSDictionary *properties = M7ImageProperties(result);
                NSUInteger w = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
                NSUInteger h = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
                NSUInteger longer = size.unsignedIntegerValue, shorter = longer * 3 / 4;
                Check(w == (orientation.intValue == 1 ? longer : shorter), @"oriented width");
                Check(h == (orientation.intValue == 1 ? shorter : longer), @"oriented height");
                NSNumber *outputOrientation = properties[(id)kCGImagePropertyOrientation];
                Check(!outputOrientation || outputOrientation.intValue == 1, @"normalized orientation");
                NSDictionary *exif = properties[(id)kCGImagePropertyExifDictionary];
                Check([exif[(id)kCGImagePropertyExifISOSpeedRatings] isEqual:@[@160]], @"ISO metadata preserved");
                Check(fabs([exif[(id)kCGImagePropertyExifExposureTime] doubleValue] - .008) < .000001, @"exposure metadata preserved");
                Check([exif[(id)kCGImagePropertyExifPixelXDimension] unsignedIntegerValue] == w, @"EXIF width");
                Check([exif[(id)kCGImagePropertyExifPixelYDimension] unsignedIntegerValue] == h, @"EXIF height");
            }
        }
        NSError *error = nil;
        Check(M7JPEGForLongEdge([NSData data], 128, &error) == nil && error != nil, @"empty input rejected");
        error = nil;
        Check(M7JPEGForLongEdge(Fixture(1, CFSTR("public.tiff")), 128, &error) == nil && error != nil, @"non-JPEG rejected");
        NSLog(@"PASS: original bytes, no upscale, three sizes, orientations 1/6/8, EXIF, invalid input");
    }
    return 0;
}
