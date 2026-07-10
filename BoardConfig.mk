#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/infinix/Infinix-X695C

# Inherit from mt6785-common
include device/transsion/mt6785-common/BoardConfigCommon.mk

# Assert
TARGET_OTA_ASSERT_DEVICE := X695C,Infinix-X695C

# Init
TARGET_INIT_VENDOR_LIB := libinit_Infinix-X695C
TARGET_RECOVERY_DEVICE_MODULES := libinit_Infinix-X695C

# Device-specific partition sizes (moved from common BoardConfigCommon.mk)
BOARD_BOOTIMAGE_PARTITION_SIZE := 33554432
BOARD_SUPER_PARTITION_SIZE := 8663334912
BOARD_MAIN_SIZE := 8659103744

# Device-specific display config (moved from common BoardConfigCommon.mk)
TW_DEFAULT_BRIGHTNESS := 1200
TW_MAX_BRIGHTNESS := 2460
TARGET_SCREEN_HEIGHT := 2460

# StatusBar (moved from common BoardConfigCommon.mk)
TW_STATUS_ICONS_ALIGN := center
TW_CUSTOM_CPU_POS := "245"
TW_CUSTOM_CLOCK_POS := "70"
TW_CUSTOM_BATTERY_POS := "790"
