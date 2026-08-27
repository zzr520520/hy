TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := wespy

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := WespyAudioEnhancer
WespyAudioEnhancer_FILES := Tweak.x
WespyAudioEnhancer_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
