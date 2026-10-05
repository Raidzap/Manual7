ARCHS = arm64
TARGET = iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Manual7
Manual7_FILES = Tweak.m iOS/M7CameraController.m iOS/M7DeviceControls.m iOS/M7JPEG.m iOS/M7Storage.m iOS/M7ErrorDetails.m iOS/M7CaptureResult.m iOS/M7VideoRecorder.m iOS/M7VideoReframe.m iOS/M7SubjectTracker.m Core/M7Math.c
Manual7_CFLAGS = -fobjc-arc -Wall -Wextra
Manual7_FRAMEWORKS = UIKit AVFoundation AudioToolbox CoreMedia CoreVideo CoreGraphics QuartzCore Photos ImageIO Vision

include $(THEOS_MAKE_PATH)/tweak.mk
