#import <Foundation/Foundation.h>

// Single source for the encoder's exported constants and the server snapshot.
#define M7_WEBCAM_TARGET_FPS 30
#define M7_WEBCAM_JPEG_QUALITY 0.68

typedef NS_ENUM(NSInteger, M7WebcamCodec) {
    M7WebcamCodecMJPEG = 0,
    M7WebcamCodecH264 = 1,
};
