#!/bin/bash

# clone common device tree

# Partitions Recovery
export FOX_RECOVERY_BOOT_PARTITION="/dev/block/platform/bootdevice/by-name/boot"
export FOX_RECOVERY_SYSTEM_PARTITION="/dev/block/by-name/system"
export FOX_RECOVERY_VENDOR_PARTITION="/dev/block/by-name/vendor"
export FOX_RECOVERY_SYSTEM_EXT_PARTITION="/dev/block/by-name/system_ext"
export FOX_RECOVERY_PRODUCT_PARTITION="/dev/block/by-name/product"
    
# Device Partition Setup
export FOX_AB_DEVICE=1
export FOX_VIRTUAL_AB_DEVICE=1
export OF_DYNAMIC_PARTITION_SUPPORT=1
export OF_QUICK_BACKUP_RESTORE=1

# Build Optimizations
export FOX_DELETE_AROMAFM=1
export FOX_REMOVE_AAPT=1

# Feature Support
export FOX_ENABLE_APP_MANAGER=1
export FOX_USE_BASH_SHELL=1
export FOX_ASH_IS_BASH=true
export FOX_USE_NANO_EDITOR=1
export FOX_USE_TAR_BINARY=1
export FOX_USE_XZ_UTILS=1

# Build Metadata
export FOX_BUILD_TYPE="Unofficial"
export FOX_VERSION="R11.1"
export FOX_VARIANT="XOS"
export OF_MAINTAINER="Hoshiyomi"

# AVB & Treble
export OF_PATCH_AVB20=1
export OF_NO_TREBLE_COMPATIBILITY_CHECK=1

# UI & Hardware Features
export OF_USE_GREEN_LED=0
export OF_FLASHLIGHT_ENABLE=0
export OF_DISABLE_OTA_MENU=1
export OF_ALLOW_DISABLE_NAVBAR=0
export OF_FIX_OTA_UPDATE_MANUAL_FLASH_ERROR=1

# Encryption & Magisk Handling & GSI
export OF_DISABLE_FORCED_ENCRYPTION=1
export OF_DISABLE_DM_VERITY_FORCED_ENCRYPTION=1
export OF_USE_MAGISKBOOT=1
export OF_USE_MAGISKBOOT_FOR_ALL_PATCHES=1
export OF_SKIP_FBE_DECRYPTION_SDKVERSION=36
export OF_DONT_PATCH_ENCRYPTED_DEVICE=true
export OF_FIX_DECRYPTION_ON_DATA_MEDIA=1

# Advanced Functions
export OF_ENABLE_LPTOOLS=1
export OF_ADVANCED_SECURITY=1
export FOX_BUGGED_AOSP_ARB_WORKAROUND="1546300800"
export FOX_USE_DATA_RECOVERY_FOR_SETTINGS=1
export OF_LOOP_DEVICE_ERRORS_TO_LOG=1
export OF_DISABLE_MIUI_SPECIFIC_FEATURES=1 

# UI Layout Settings
export OF_SCREEN_H=2460
export OF_STATUS_H=100
export OF_STATUS_INDENT_LEFT=52
export OF_STATUS_INDENT_RIGHT=52
export OF_CLOCK_POS=1

# Backup & Post-Flash Config
export OF_QUICK_BACKUP_LIST="/boot;/data;"
export OF_SKIP_MULTIUSER_FOLDERS_BACKUP="1"
export OF_RUN_POST_FORMAT_PROCESS=1
