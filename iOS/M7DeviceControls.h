#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Call on the capture session owner's serial queue after configuration.
// This adapter neither owns nor reconfigures the session. The owner must not
// change device, format or modes concurrently and must wait for asynchronous
// exposure/focus completion before enabling capture.
@interface M7DeviceControls : NSObject
@property (nonatomic, readonly) AVCaptureDevice *device;
- (instancetype)initWithDevice:(AVCaptureDevice *)device;
- (instancetype)init NS_UNAVAILABLE;
- (NSDictionary<NSString *, id> *)capabilities;
- (BOOL)setISO:(float)iso shutterIndex:(int)index
    completion:(nullable void (^)(CMTime))completion error:(NSError **)error;
- (BOOL)setManualFocus:(float)position
    completion:(nullable void (^)(CMTime))completion error:(NSError **)error;
- (BOOL)enableAutoExposure:(NSError **)error;
- (BOOL)enableAutoFocus:(NSError **)error;
- (BOOL)lockExposure:(NSError **)error;
- (BOOL)lockFocus:(NSError **)error;
// Third-stop EV bias is accepted only in continuous autoexposure mode.
- (BOOL)setExposureBiasThirds:(NSInteger)thirds
    completion:(nullable void (^)(CMTime))completion error:(NSError **)error;
// Call only with output connected to the same device/session.
// Returned settings request a genuine Bayer RAW photo in an explicitly
// validated DNG container. The optional JPEG uses an explicitly validated
// JPEG codec/container pair and is intended for the diagnostic comparison.
- (nullable AVCapturePhotoSettings *)rawSettingsForOutput:(AVCapturePhotoOutput *)output
    includeProcessedJPEG:(BOOL)includeJPEG diagnostic:(NSDictionary * _Nullable * _Nullable)diagnostic
    error:(NSError **)error;
- (NSDictionary *)rawCompatibilityForOutput:(AVCapturePhotoOutput *)output;
// Selects the best real-time 4:3 format at the requested frame rate. The
// capture session owner must wrap this call in begin/commitConfiguration.
- (nullable NSDictionary *)configureVideoFormatAtFPS:(NSInteger)fps error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
