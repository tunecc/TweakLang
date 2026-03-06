TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Preferences
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TweakLang

TweakLang_FILES = Tweak.x
TweakLang_CFLAGS = -fobjc-arc
TweakLang_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += tweaklangprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
