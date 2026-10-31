ARCHS = arm64
TARGET = iphone:clang:15.6:15.0
# ROOTFUL=1 builds the iphoneos-arm package for rootful jailbreaks (palera1n
# -f); the default is the rootless /var/jb package for Dopamine and palera1n.
ifeq ($(ROOTFUL),1)
THEOS_PACKAGE_SCHEME =
else
THEOS_PACKAGE_SCHEME = rootless
endif
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Manual7
Manual7_FILES = Tweak.m iOS/M7CameraController.m iOS/M7DeviceControls.m iOS/M7RAWConfiguration.m iOS/M7JPEG.m iOS/M7Storage.m iOS/M7ErrorDetails.m iOS/M7CaptureResult.m iOS/M7VideoRecorder.m iOS/M7VideoReframe.m iOS/M7SubjectTracker.m iOS/M7RemoteServer.m iOS/M7OpenSSHStatus.m iOS/M7WebcamEncoder.m iOS/M7WebcamServer.m iOS/M7PairingManager.m Core/M7Math.c
Manual7_CFLAGS = -fobjc-arc -Wall -Wextra
Manual7_FRAMEWORKS = UIKit AVFoundation AudioToolbox CoreMedia CoreVideo CoreGraphics CoreImage QuartzCore Photos ImageIO Vision VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = manual7bridge
manual7bridge_FILES = Bridge/manual7bridge.c
manual7bridge_CFLAGS = -std=c11 -Wall -Wextra -Werror -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/module-cache
manual7bridge_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

ifeq ($(ROOTFUL),1)
THEOS_PACKAGE_ARCH := iphoneos-arm

# The layout is written for rootless; rootful installs the same files at /.
before-package::
	$(ECHO_NOTHING)perl -pi -e 's#/var/jb##g' "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm" \
		"$(THEOS_STAGING_DIR)/Library/LaunchDaemons/dev.manual7.bridge.plist"$(ECHO_END)
endif
