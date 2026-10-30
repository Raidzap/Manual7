#import "M7WebcamEncoder.h"
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

const NSUInteger M7WebcamTargetFPS = M7_WEBCAM_TARGET_FPS;
const CGFloat M7WebcamJPEGQuality = M7_WEBCAM_JPEG_QUALITY;

static CGFloat M7WebcamClamp(CGFloat value, CGFloat lower, CGFloat upper) {
    return MIN(upper, MAX(lower, value));
}

CGSize M7WebcamOutputSize(M7WebcamCodec codec, BOOL vertical, BOOL landscapeSource) {
    if (codec == M7WebcamCodecH264 && vertical && !landscapeSource) return CGSizeMake(1080, 1920);
    if (codec == M7WebcamCodecH264 && !vertical && landscapeSource) return CGSizeMake(1920, 1080);
    return vertical ? CGSizeMake(720, 1280) : CGSizeMake(1280, 720);
}

CGPoint M7CameraMountDevicePoint(M7CameraMount mount, CGPoint point) {
    CGFloat x = M7WebcamClamp(point.x, 0, 1), y = M7WebcamClamp(point.y, 0, 1);
    switch (mount) {
        case M7CameraMountPortrait: return CGPointMake(y, 1.0 - x);
        case M7CameraMountLandscapeInverted: return CGPointMake(1.0 - x, 1.0 - y);
        default: return CGPointMake(x, y);
    }
}

// About 0.1 bit per pixel at 30 fps: 2.8 Mbit/s for 720p, 6.2 Mbit/s for
// 1080x1920. A fraction of the MJPEG stream it replaces.
int32_t M7WebcamH264BitRate(CGSize size) {
    return (int32_t)MAX(1000000.0, round(size.width * size.height * M7WebcamTargetFPS * .1));
}

NSData *M7WebcamAnnexBFromSampleBuffer(CMSampleBufferRef sample, BOOL *keyframe) {
    CMBlockBufferRef block = sample ? CMSampleBufferGetDataBuffer(sample) : NULL;
    CMFormatDescriptionRef format = sample ? CMSampleBufferGetFormatDescription(sample) : NULL;
    if (!block || !format) return nil;
    BOOL key = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments && CFArrayGetCount(attachments)) {
        CFDictionaryRef first = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(first, kCMSampleAttachmentKey_NotSync);
        key = !(notSync && CFBooleanGetValue(notSync));
    }
    size_t parameterCount = 0; int headerLength = 0;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL,
        &parameterCount, &headerLength) != noErr || headerLength < 1 || headerLength > 4) return nil;
    static const uint8_t startCode[] = {0, 0, 0, 1};
    NSMutableData *output = [NSMutableData new];
    for (size_t index = 0; key && index < parameterCount; ++index) {
        const uint8_t *set = NULL; size_t setLength = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &set, &setLength,
            NULL, NULL) != noErr || !set || !setLength) return nil;
        [output appendBytes:startCode length:sizeof(startCode)];
        [output appendBytes:set length:setLength];
    }
    size_t length = CMBlockBufferGetDataLength(block);
    NSMutableData *avcc = [NSMutableData dataWithLength:length];
    if (!length || CMBlockBufferCopyDataBytes(block, 0, length, avcc.mutableBytes) != kCMBlockBufferNoErr)
        return nil;
    const uint8_t *bytes = avcc.bytes;
    size_t offset = 0;
    while (offset + (size_t)headerLength <= length) {
        size_t nalLength = 0;
        for (int i = 0; i < headerLength; ++i) nalLength = (nalLength << 8) | bytes[offset + i];
        offset += (size_t)headerLength;
        if (!nalLength || nalLength > length - offset) return nil;
        [output appendBytes:startCode length:sizeof(startCode)];
        [output appendBytes:bytes + offset length:nalLength];
        offset += nalLength;
    }
    if (offset != length) return nil;
    if (keyframe) *keyframe = key;
    return output;
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

CGPoint M7WebcamDevicePointForMount(M7CameraMount mount, CGSize source, CGSize target,
    CGPoint center, CGPoint point) {
    CGRect crop = M7WebcamCropRect(source, target, center);
    if (CGRectIsEmpty(crop)) return CGPointMake(.5, .5);
    CGFloat u = M7WebcamClamp(point.x, 0, 1), v = M7WebcamClamp(point.y, 0, 1);
    CGFloat x = CGRectGetMinX(crop) + u * CGRectGetWidth(crop);
    CGFloat yTop = source.height - CGRectGetMaxY(crop) + v * CGRectGetHeight(crop);
    return M7CameraMountDevicePoint(mount, CGPointMake(x / source.width, yTop / source.height));
}

CGPoint M7WebcamDevicePoint(CGSize source, CGSize target, CGPoint center, CGPoint point) {
    return M7WebcamDevicePointForMount(M7CameraMountPortrait, source, target, center, point);
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
@property (nonatomic) VTCompressionSessionRef h264;
@property (nonatomic) CGSize h264Size;
@property (atomic, readwrite) BOOL h264Available;
@property (atomic, readwrite) int32_t h264Status;
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
        _h264Available = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidateCompression];
    [self invalidateH264];
    CGColorSpaceRelease(_colorSpace);
}

- (void)invalidateH264 {
    if (!_h264) return;
    VTCompressionSessionInvalidate(_h264);
    CFRelease(_h264);
    _h264 = NULL;
}

- (void)disableH264:(OSStatus)status {
    self.h264Status = status ?: -1;
    self.h264Available = NO;
    [self invalidateH264];
}

// Real time, no frame reordering (B-frames would add a frame of latency) and
// a keyframe at least every 2 s so a client that joins mid-stream recovers.
- (BOOL)prepareH264ForSize:(CGSize)size {
    if (self.h264 && CGSizeEqualToSize(self.h264Size, size)) return YES;
    [self invalidateH264];
    int32_t width = (int32_t)size.width, height = (int32_t)size.height;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{} };
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
        kCMVideoCodecType_H264, NULL, (__bridge CFDictionaryRef)attributes, NULL, NULL, NULL, &session);
    if (status != noErr || !session) { [self disableH264:status]; return NO; }
    int32_t bitRate = M7WebcamH264BitRate(size);
    NSDictionary *properties = @{
        (id)kVTCompressionPropertyKey_RealTime:@YES,
        (id)kVTCompressionPropertyKey_ProfileLevel:(id)kVTProfileLevel_H264_High_AutoLevel,
        (id)kVTCompressionPropertyKey_AllowFrameReordering:@NO,
        (id)kVTCompressionPropertyKey_MaxKeyFrameInterval:@(M7WebcamTargetFPS * 2),
        (id)kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:@2,
        (id)kVTCompressionPropertyKey_ExpectedFrameRate:@(M7WebcamTargetFPS),
        (id)kVTCompressionPropertyKey_AverageBitRate:@(bitRate),
        (id)kVTCompressionPropertyKey_DataRateLimits:@[@(bitRate / 8 * 3 / 2), @1],
        (id)kVTCompressionPropertyKey_ColorPrimaries:(id)kCVImageBufferColorPrimaries_ITU_R_709_2,
        (id)kVTCompressionPropertyKey_TransferFunction:(id)kCVImageBufferTransferFunction_ITU_R_709_2,
        (id)kVTCompressionPropertyKey_YCbCrMatrix:(id)kCVImageBufferYCbCrMatrix_ITU_R_709_2 };
    status = VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties);
    if (status == noErr) status = VTCompressionSessionPrepareToEncodeFrames(session);
    if (status != noErr) {
        VTCompressionSessionInvalidate(session); CFRelease(session);
        [self disableH264:status];
        return NO;
    }
    self.h264 = session;
    self.h264Size = size;
    return YES;
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

- (CIImage *)imageForPixelBuffer:(CVPixelBufferRef)pixel target:(CGSize)target
    normalizedCenter:(CGPoint)center error:(NSError **)error {
    if (!pixel) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Frame da webcam sem pixel buffer."}];
        return nil;
    }
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
    return [image imageByCroppingToRect:CGRectMake(0, 0, target.width, target.height)];
}

- (NSData *)JPEGDataForPixelBuffer:(CVPixelBufferRef)pixel vertical:(BOOL)vertical
    normalizedCenter:(CGPoint)center error:(NSError **)error {
    CGSize target = M7WebcamOutputSize(M7WebcamCodecMJPEG, vertical, NO);
    CIImage *image = [self imageForPixelBuffer:pixel target:target normalizedCenter:center error:error];
    if (!image) return nil;
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

- (NSData *)H264AccessUnitForPixelBuffer:(CVPixelBufferRef)pixel vertical:(BOOL)vertical
    normalizedCenter:(CGPoint)center presentationTime:(CMTime)presentationTime
    forceKeyframe:(BOOL)forceKeyframe keyframe:(BOOL *)keyframe error:(NSError **)error {
    BOOL landscapeSource = pixel && CVPixelBufferGetWidth(pixel) > CVPixelBufferGetHeight(pixel);
    CGSize target = M7WebcamOutputSize(M7WebcamCodecH264, vertical, landscapeSource);
    NSError *(^failure)(NSInteger, NSString *) = ^(NSInteger code, NSString *message) {
        return [NSError errorWithDomain:@"Manual7.WebcamEncoder" code:code userInfo:@{
            NSLocalizedDescriptionKey:message, @"osStatus":@(self.h264Status)}];
    };
    if (!self.h264Available || ![self prepareH264ForSize:target]) {
        if (error) *error = failure(4, @"O encoder H.264 da webcam não está disponível.");
        return nil;
    }
    CIImage *image = [self imageForPixelBuffer:pixel target:target normalizedCenter:center error:error];
    if (!image) return nil;
    CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(self.h264);
    CVPixelBufferRef buffer = NULL;
    CVReturn created = pool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        : kCVReturnInvalidArgument;
    if (created != kCVReturnSuccess || !buffer) {
        [self disableH264:created];
        if (error) *error = failure(5, @"Sem buffer para o encoder H.264 da webcam.");
        return nil;
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    [self.context render:image toCVPixelBuffer:buffer
        bounds:CGRectMake(0, 0, target.width, target.height) colorSpace:nil];
    if (!CMTIME_IS_VALID(presentationTime))
        presentationTime = CMTimeMake(self.frameIndex, (int32_t)M7WebcamTargetFPS);
    ++self.frameIndex;
    NSDictionary *options = forceKeyframe ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame:@YES} : nil;
    __block NSData *accessUnit = nil;
    __block BOOL accessUnitKeyframe = NO;
    __block OSStatus outputStatus = noErr;
    OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(self.h264, buffer,
        presentationTime, kCMTimeInvalid, (__bridge CFDictionaryRef)options, NULL,
        ^(OSStatus result, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
            outputStatus = result;
            // A frame the rate controller drops arrives without a sample.
            if (result != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) return;
            accessUnit = M7WebcamAnnexBFromSampleBuffer(sample, &accessUnitKeyframe);
        });
    if (status == noErr) status = VTCompressionSessionCompleteFrames(self.h264, kCMTimeInvalid);
    CVPixelBufferRelease(buffer);
    if (status != noErr || outputStatus != noErr) {
        [self disableH264:status ?: outputStatus];
        if (error) *error = failure(6, @"O encoder H.264 da webcam falhou.");
        return nil;
    }
    if (keyframe) *keyframe = accessUnitKeyframe;
    return accessUnit;
}

@end
