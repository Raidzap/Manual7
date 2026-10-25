#import "M7WebcamEncoder.h"
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

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

CGPoint M7WebcamDevicePoint(CGSize source, CGSize target, CGPoint center, CGPoint point) {
    CGRect crop = M7WebcamCropRect(source, target, center);
    if (CGRectIsEmpty(crop)) return CGPointMake(.5, .5);
    CGFloat u = M7WebcamClamp(point.x, 0, 1), v = M7WebcamClamp(point.y, 0, 1);
    CGFloat x = CGRectGetMinX(crop) + u * CGRectGetWidth(crop);
    CGFloat yTop = source.height - CGRectGetMaxY(crop) + v * CGRectGetHeight(crop);
    // Portrait buffer to the landscape sensor space used by AVCaptureDevice.
    return CGPointMake(yTop / source.height, 1.0 - x / source.width);
}

@interface M7WebcamEncoder ()
@property (nonatomic) CIContext *context;
@property (nonatomic) CGColorSpaceRef colorSpace;
@property (nonatomic) VTCompressionSessionRef compression;
@property (nonatomic) CGSize compressionSize;
@property (nonatomic) int64_t frameIndex;
@property (nonatomic) BOOL hardwareDisabled;
@property (atomic, readwrite, copy) NSString *backend;
@property (atomic, readwrite) int32_t hardwareStatus;
@end


@implementation M7WebcamEncoder

- (instancetype)init {
    if ((self = [super init])) {
        // A null working space skips the per-frame linearize/delinearize pass:
        // the webcam only crops and scales, so color matching buys nothing and
        // costs GPU time on the A10.
        _context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO,
            kCIContextCacheIntermediates:@NO, kCIContextWorkingColorSpace:NSNull.null}];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _backend = @"videoToolbox";
    }
    return self;
}

- (void)dealloc {
    [self invalidateCompression];
    CGColorSpaceRelease(_colorSpace);
}

- (void)invalidateCompression {
    if (!_compression) return;
    VTCompressionSessionInvalidate(_compression);
    CFRelease(_compression);
    _compression = NULL;
}

- (void)disableHardware:(OSStatus)status {
    self.hardwareStatus = status ?: -1;
    self.hardwareDisabled = YES;
    self.backend = @"coreImage";
    [self invalidateCompression];
}

// One session per output size; switching 16:9/9:16 recreates it.
- (BOOL)prepareCompressionForSize:(CGSize)size {
    if (self.compression && CGSizeEqualToSize(self.compressionSize, size)) return YES;
    [self invalidateCompression];
    int32_t width = (int32_t)size.width, height = (int32_t)size.height;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{} };
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
        kCMVideoCodecType_JPEG, NULL, (__bridge CFDictionaryRef)attributes, NULL, NULL, NULL, &session);
    if (status != noErr || !session) { [self disableHardware:status]; return NO; }
    VTSessionSetProperty(session, kVTCompressionPropertyKey_Quality,
        (__bridge CFNumberRef)@(M7WebcamJPEGQuality));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTCompressionSessionPrepareToEncodeFrames(session);
    self.compression = session;
    self.compressionSize = size;
    return YES;
}

- (NSData *)hardwareJPEGForImage:(CIImage *)image size:(CGSize)size {
    if (self.hardwareDisabled || ![self prepareCompressionForSize:size]) return nil;
    CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(self.compression);
    CVPixelBufferRef buffer = NULL;
    CVReturn created = pool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        : kCVReturnInvalidArgument;
    if (created != kCVReturnSuccess || !buffer) { [self disableHardware:created]; return nil; }
    // JPEG stores full-range BT.601 YCbCr; Core Image converts the GPU render
    // straight into the pooled buffer, so no RGB copy touches the CPU.
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        kCVAttachmentMode_ShouldPropagate);
    [self.context render:image toCVPixelBuffer:buffer
        bounds:CGRectMake(0, 0, size.width, size.height) colorSpace:nil];
    __block NSData *jpeg = nil;
    __block OSStatus outputStatus = noErr;
    OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(self.compression, buffer,
        CMTimeMake(self.frameIndex++, (int32_t)M7WebcamTargetFPS), kCMTimeInvalid, NULL, NULL,
        ^(OSStatus result, __unused VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
            outputStatus = result;
            CMBlockBufferRef block = result == noErr && sample ? CMSampleBufferGetDataBuffer(sample) : NULL;
            size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
            if (!length) return;
            NSMutableData *data = [NSMutableData dataWithLength:length];
            if (CMBlockBufferCopyDataBytes(block, 0, length, data.mutableBytes) == kCMBlockBufferNoErr)
                jpeg = data;
        });
    if (status == noErr) status = VTCompressionSessionCompleteFrames(self.compression, kCMTimeInvalid);
    CVPixelBufferRelease(buffer);
    const uint8_t *bytes = jpeg.bytes;
    BOOL validJPEG = jpeg.length > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (status != noErr || outputStatus != noErr || !validJPEG) {
        [self disableHardware:status ?: outputStatus];
        return nil;
    }
    return jpeg;
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
    image = [image imageByCroppingToRect:output];
    NSData *data = [self hardwareJPEGForImage:image size:target];
    if (!data.length) data = [self.context JPEGRepresentationOfImage:image
        colorSpace:self.colorSpace options:@{
            (id)kCGImageDestinationLossyCompressionQuality:@(M7WebcamJPEGQuality) }];
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:3
            userInfo:@{NSLocalizedDescriptionKey:@"Core Image não codificou o JPEG da webcam."}];
        return nil;
    }
    return data;
}

@end
