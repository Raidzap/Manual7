#import "M7JPEG.h"
#import <ImageIO/ImageIO.h>

static NSData *M7JPEGError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Manual7.JPEG" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}

NSDictionary *M7ImageProperties(NSData *data) {
    if (!data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    return properties;
}

NSData *M7JPEGForLongEdge(NSData *data, NSUInteger maxLongEdge, NSError **error) {
    if (!data.length) return M7JPEGError(error, @"JPEG sem dados.");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
    if (!source) return M7JPEGError(error, @"Não foi possível abrir o JPEG.");
    CGImageRef image = NULL;
    CGImageDestinationRef destination = NULL;
    @try {
        CFStringRef type = CGImageSourceGetType(source);
        if (!type || !CFEqual(type, CFSTR("public.jpeg")))
            return M7JPEGError(error, @"Redimensionamento disponível apenas para JPEG.");
        NSMutableDictionary *properties = [CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) mutableCopy];
        NSUInteger width = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        NSUInteger height = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        if (!width || !height) return M7JPEGError(error, @"Dimensões do JPEG inválidas.");
        // Preserve original bytes for native size and for choices above the input.
        if (!maxLongEdge || maxLongEdge >= MAX(width, height)) return data;
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
            (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (id)kCGImageSourceThumbnailMaxPixelSize:@(maxLongEdge),
            (id)kCGImageSourceShouldCacheImmediately:@YES});
        if (!image) return M7JPEGError(error, @"Falha ao reduzir o JPEG.");
        NSNumber *outWidth = @(CGImageGetWidth(image)), *outHeight = @(CGImageGetHeight(image));
        properties[(id)kCGImagePropertyPixelWidth] = outWidth;
        properties[(id)kCGImagePropertyPixelHeight] = outHeight;
        properties[(id)kCGImagePropertyOrientation] = @1;
        NSMutableDictionary *exif = [properties[(id)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary new];
        exif[(id)kCGImagePropertyExifPixelXDimension] = outWidth;
        exif[(id)kCGImagePropertyExifPixelYDimension] = outHeight;
        properties[(id)kCGImagePropertyExifDictionary] = exif;
        NSMutableDictionary *tiff = [properties[(id)kCGImagePropertyTIFFDictionary] mutableCopy] ?: [NSMutableDictionary new];
        tiff[(id)kCGImagePropertyTIFFOrientation] = @1;
        properties[(id)kCGImagePropertyTIFFDictionary] = tiff;
        properties[(id)kCGImageDestinationLossyCompressionQuality] = @.95;
        // ImageIO encodes from the oriented image; never reuse an old thumbnail.
        NSMutableData *result = [NSMutableData new];
        destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result, CFSTR("public.jpeg"), 1, NULL);
        if (!destination) return M7JPEGError(error, @"Falha ao criar o JPEG de saída.");
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
        if (!CGImageDestinationFinalize(destination)) return M7JPEGError(error, @"Falha ao gravar o JPEG reduzido.");
        return result;
    } @finally {
        if (destination) CFRelease(destination);
        if (image) CGImageRelease(image);
        CFRelease(source);
    }
}
