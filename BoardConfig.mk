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

# Filter-out twrpfastboot=1 from INTERNAL_KERNEL_CMDLINE
# This runs in BoardConfig phase, after vendor/twrp adds twrpfastboot=1
INTERNAL_KERNEL_CMDLINE := $(filter-out twrpfastboot=1,$(INTERNAL_KERNEL_CMDLINE))
