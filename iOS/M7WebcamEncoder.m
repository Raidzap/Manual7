#import "M7WebcamEncoder.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

const NSUInteger M7WebcamTargetFPS = 30;
const CGFloat M7WebcamJPEGQuality = .68;

static CGFloat M7WebcamClamp(CGFloat value, CGFloat lower, CGFloat upper) {
    return MIN(upper, MAX(lower, value));
}

CGRect M7WebcamCropRect(CGSize source, CGSize target, CGPoint center) {
    if (source.width <= 0 || source.height <= 0 || target.width <= 0 || target.height <= 0)
        return CGRectZero;
    CGFloat targetAspect = target.width / target.height;
    CGFloat cropWidth = source.width, cropHeight = source.height;
    if (source.width / source.height > targetAspect) cropWidth = source.height * targetAspect;
    else cropHeight = source.width / targetAspect;
    CGFloat x = M7WebcamClamp(center.x, 0, 1) * source.width - cropWidth / 2.0;
    // Core Image is bottom-left; the M7 preview and tracker are top-left.
    CGFloat y = (1.0-M7WebcamClamp(center.y, 0, 1)) * source.height - cropHeight / 2.0;
    x = M7WebcamClamp(x, 0, source.width - cropWidth);
    y = M7WebcamClamp(y, 0, source.height - cropHeight);
    return CGRectMake(x, y, cropWidth, cropHeight);
}

@interface M7WebcamEncoder ()
@property (nonatomic) CIContext *context;
@end


@implementation M7WebcamEncoder

- (instancetype)init {
    if ((self = [super init]))
        _context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO,
            kCIContextCacheIntermediates:@NO}];
    return self;
}

- (NSData *)JPEGDataForPixelBuffer:(CVPixelBufferRef)pixel vertical:(BOOL)vertical
    normalizedCenter:(CGPoint)center error:(NSError **)error {
    if (!pixel) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Frame da webcam sem pixel buffer."}];
        return nil;
    }
    CGSize target = vertical ? CGSizeMake(720, 1280) : CGSizeMake(1280, 720);
    CIImage *source = [CIImage imageWithCVPixelBuffer:pixel];
    CGRect extent = source.extent;
    CGRect localCrop = M7WebcamCropRect(extent.size, target, center);
    CGRect crop = CGRectOffset(localCrop, extent.origin.x, extent.origin.y);
    if (CGRectIsEmpty(crop)) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"Geometria inválida para a webcam."}];
        return nil;
    }
    CIImage *image = [source imageByCroppingToRect:crop];
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(
        target.width/crop.size.width, target.height/crop.size.height)];
    CGRect output = CGRectMake(0, 0, target.width, target.height);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSData *data = [self.context JPEGRepresentationOfImage:[image imageByCroppingToRect:output]
        colorSpace:colorSpace options:@{
            (id)kCGImageDestinationLossyCompressionQuality:@(M7WebcamJPEGQuality) }];
    CGColorSpaceRelease(colorSpace);
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:3
            userInfo:@{NSLocalizedDescriptionKey:@"Core Image não codificou o JPEG da webcam."}];
        return nil;
    }
    return data;
}

@end
