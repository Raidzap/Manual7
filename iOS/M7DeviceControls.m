#import "M7DeviceControls.h"
#import "../Core/M7Math.h"
#import <math.h>
#import <limits.h>

static BOOL M7Fail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"Manual7" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}

@implementation M7DeviceControls

- (instancetype)initWithDevice:(AVCaptureDevice *)device {
    if ((self = [super init])) _device = device;
    return self;
}

- (NSDictionary<NSString *, id> *)capabilities {
    AVCaptureDevice *d = self.device;
    AVCaptureDeviceFormat *f = d.activeFormat;
    int first = 0, last = 0;
    BOOL grid = m7_shutter_range(CMTimeGetSeconds(f.minExposureDuration),
                                CMTimeGetSeconds(f.maxExposureDuration), &first, &last);
    return @{@"deviceID": d.uniqueID, @"deviceType": d.deviceType,
             @"minISO": @(f.minISO), @"maxISO": @(f.maxISO),
             @"minSeconds": @(CMTimeGetSeconds(f.minExposureDuration)),
             @"maxSeconds": @(CMTimeGetSeconds(f.maxExposureDuration)),
             @"hasShutterGrid": @(grid), @"firstShutterIndex": @(first),
             @"lastShutterIndex": @(last),
             @"manualExposure": @([d isExposureModeSupported:AVCaptureExposureModeCustom]),
             @"manualFocus": @(d.isLockingFocusWithCustomLensPositionSupported),
             @"exposureLock": @([d isExposureModeSupported:AVCaptureExposureModeLocked]),
             @"focusLock": @([d isFocusModeSupported:AVCaptureFocusModeLocked]),
             @"minEV": @(d.minExposureTargetBias), @"maxEV": @(d.maxExposureTargetBias)};
}

- (BOOL)setISO:(float)iso shutterIndex:(int)index
    completion:(void (^)(CMTime))completion error:(NSError **)error {
    AVCaptureDevice *d = self.device;
    if (![d lockForConfiguration:error]) return NO;
    @try {
        if (![d isExposureModeSupported:AVCaptureExposureModeCustom])
            return M7Fail(error, @"Exposição manual indisponível nesta câmera.");
        AVCaptureDeviceFormat *f = d.activeFormat;
        double seconds = m7_shutter_seconds(index);
        if (!isfinite(iso) || iso < f.minISO || iso > f.maxISO ||
            !isfinite(seconds) || seconds < CMTimeGetSeconds(f.minExposureDuration) ||
            seconds > CMTimeGetSeconds(f.maxExposureDuration))
            return M7Fail(error, @"ISO ou obturador fora dos limites do formato ativo.");
        CMTime duration = CMTimeMakeWithSeconds(seconds, 1000000000);
        // CMTime quantization may cross a hardware endpoint by a nanosecond.
        if (CMTimeCompare(duration, f.minExposureDuration) < 0) duration = f.minExposureDuration;
        if (CMTimeCompare(duration, f.maxExposureDuration) > 0) duration = f.maxExposureDuration;
        [d setExposureModeCustomWithDuration:duration ISO:iso completionHandler:completion];
        return YES;
    } @finally { [d unlockForConfiguration]; }
}

- (BOOL)setManualFocus:(float)position
    completion:(void (^)(CMTime))completion error:(NSError **)error {
    AVCaptureDevice *d = self.device;
    if (![d lockForConfiguration:error]) return NO;
    @try {
        if (!d.isLockingFocusWithCustomLensPositionSupported)
            return M7Fail(error, @"Foco manual indisponível nesta câmera.");
        if (!isfinite(position) || position < 0 || position > 1)
            return M7Fail(error, @"A posição do foco deve estar entre 0 e 1.");
        [d setFocusModeLockedWithLensPosition:position completionHandler:completion];
        return YES;
    } @finally { [d unlockForConfiguration]; }
}

- (BOOL)changeExposureMode:(AVCaptureExposureMode)mode error:(NSError **)error {
    AVCaptureDevice *d = self.device;
    if (![d lockForConfiguration:error]) return NO;
    @try {
        if (![d isExposureModeSupported:mode])
            return M7Fail(error, @"Modo de exposição indisponível.");
        d.exposureMode = mode;
        return YES;
    } @finally { [d unlockForConfiguration]; }
}

- (BOOL)changeFocusMode:(AVCaptureFocusMode)mode error:(NSError **)error {
    AVCaptureDevice *d = self.device;
    if (![d lockForConfiguration:error]) return NO;
    @try {
        if (![d isFocusModeSupported:mode])
            return M7Fail(error, @"Modo de foco indisponível.");
        d.focusMode = mode;
        return YES;
    } @finally { [d unlockForConfiguration]; }
}

- (BOOL)enableAutoExposure:(NSError **)error {
    return [self changeExposureMode:AVCaptureExposureModeContinuousAutoExposure error:error];
}
- (BOOL)enableAutoFocus:(NSError **)error {
    return [self changeFocusMode:AVCaptureFocusModeContinuousAutoFocus error:error];
}
- (BOOL)lockExposure:(NSError **)error {
    return [self changeExposureMode:AVCaptureExposureModeLocked error:error];
}
- (BOOL)lockFocus:(NSError **)error {
    return [self changeFocusMode:AVCaptureFocusModeLocked error:error];
}

- (BOOL)setExposureBiasThirds:(NSInteger)thirds
    completion:(void (^)(CMTime))completion error:(NSError **)error {
    AVCaptureDevice *d = self.device;
    if (![d lockForConfiguration:error]) return NO;
    @try {
        if (d.exposureMode != AVCaptureExposureModeContinuousAutoExposure)
            return M7Fail(error, @"Compensação EV requer exposição automática desbloqueada.");
        double bias = (double)thirds / 3.0;
        if (bias < d.minExposureTargetBias || bias > d.maxExposureTargetBias)
            return M7Fail(error, @"Compensação EV fora dos limites da câmera.");
        [d setExposureTargetBias:(float)bias completionHandler:completion];
        return YES;
    } @finally { [d unlockForConfiguration]; }
}

- (AVCapturePhotoSettings *)rawSettingsForOutput:(AVCapturePhotoOutput *)output
    error:(NSError **)error {
    NSNumber *bayer = nil;
    for (NSNumber *format in output.availableRawPhotoPixelFormatTypes) {
        if ([AVCapturePhotoOutput isBayerRAWPixelFormat:format.unsignedIntValue]) {
            bayer = format; break;
        }
    }
    if (!bayer) {
        M7Fail(error, @"RAW Bayer indisponível na sessão atual; selecione uma lente física.");
        return nil;
    }
    AVCapturePhotoSettings *s = [AVCapturePhotoSettings
        photoSettingsWithRawPixelFormatType:bayer.unsignedIntValue];
    s.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationSpeed;
    s.flashMode = AVCaptureFlashModeOff;
    return s;
}

- (NSDictionary *)configureVideoFormatAtFPS:(NSInteger)fps error:(NSError **)error {
    AVCaptureDevice *device = self.device;
    AVCaptureDeviceFormat *bestFourThirds = nil;
    AVCaptureDeviceFormat *bestFallback = nil;
    int64_t bestFourScore = LLONG_MIN, bestFallbackScore = LLONG_MIN;
    NSUInteger compatible = 0;
    for (AVCaptureDeviceFormat *format in device.formats) {
        BOOL supportsFPS = NO;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (range.minFrameRate <= fps && range.maxFrameRate >= fps) { supportsFPS = YES; break; }
        }
        if (!supportsFPS) continue;
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        NSInteger width = MAX(size.width, size.height), height = MIN(size.width, size.height);
        if (width < 640 || height < 480) continue;
        ++compatible;
        int64_t pixels = (int64_t)width * height;
        double ratio = (double)width / height;
        BOOL fourThirds = fabs(ratio - 4.0/3.0) < .035;
        // Prefer the largest format up to 1920x1440. If only larger formats
        // exist, prefer the closest one to keep A10 encoding sustainable.
        int64_t budget = 1920LL * 1440LL;
        int64_t resolutionScore = pixels <= budget ? pixels : budget - (pixels - budget);
        int64_t score = resolutionScore - (int64_t)(fabs(ratio - 4.0/3.0) * 1000000.0);
        if (fourThirds && score > bestFourScore) { bestFourScore = score; bestFourThirds = format; }
        if (score > bestFallbackScore) { bestFallbackScore = score; bestFallback = format; }
    }
    AVCaptureDeviceFormat *selected = bestFourThirds ?: bestFallback;
    if (!selected) {
        M7Fail(error, @"Nenhum formato de vídeo compatível com 30 fps foi encontrado.");
        return nil;
    }
    if (![device lockForConfiguration:error]) return nil;
    @try {
        device.activeFormat = selected;
        CMTime frameDuration = CMTimeMake(1, (int32_t)fps);
        device.activeVideoMinFrameDuration = frameDuration;
        device.activeVideoMaxFrameDuration = frameDuration;
    } @finally { [device unlockForConfiguration]; }
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(selected.formatDescription);
    NSInteger width = MAX(size.width, size.height), height = MIN(size.width, size.height);
    return @{ @"width":@(width), @"height":@(height), @"fps":@(fps),
        @"fourThirds":@(selected == bestFourThirds), @"compatibleFormats":@(compatible),
        @"pixelFormat":@(CMFormatDescriptionGetMediaSubType(selected.formatDescription)),
        @"minISO":@(selected.minISO), @"maxISO":@(selected.maxISO),
        @"minExposure":@(CMTimeGetSeconds(selected.minExposureDuration)),
        @"maxExposure":@(CMTimeGetSeconds(selected.maxExposureDuration)) };
}
@end
