#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

void M7MarkSessionOwned(AVCaptureSession *session);
void M7BeginCameraOwnership(void);
void M7EndCameraOwnership(BOOL foreground);

@interface M7CameraController : UIViewController
@end

// AVFoundation marks these optional, but our RAW/JPEG capture path needs both.
// Requiring the Objective-C selectors makes a Swift-style spelling fail build.
@protocol M7RequiredPhotoCaptureDelegate <AVCapturePhotoCaptureDelegate>
@required
- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error;
- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error;
@end
