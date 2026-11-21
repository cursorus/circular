TARGET := iphone:clang:latest:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = circularprefs
circularprefs_FILES = CIRRootListController.m
circularprefs_FRAMEWORKS = UIKit
circularprefs_LDFLAGS = -undefined dynamic_lookup
circularprefs_INSTALL_PATH = /Library/PreferenceBundles
circularprefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
