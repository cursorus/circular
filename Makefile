TARGET := iphone:clang:latest:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = circular
circular_FILES = Tweak.x
circular_FRAMEWORKS = UIKit CoreMotion
circular_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += circularprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
