#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

void M7MarkSessionOwned(AVCaptureSession *session);
void M7BeginCameraOwnership(void);
void M7EndCameraOwnership(BOOL foreground);

@interface M7CameraController : UIViewController
@end
