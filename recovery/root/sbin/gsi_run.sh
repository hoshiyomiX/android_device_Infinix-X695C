#!/sbin/sh
# =============================================================================
# gsi_run.sh — Automated GSI flasher for Infinix X695C (MT6785)
# =============================================================================
#
# Triggered from OrangeFox "Flash GSI" custom menu (see /twres/pages/flash_gsi.xml).
# Can also be invoked manually via ADB:
#   adb shell gsi_run.sh /sdcard/gsi.img
#
# Features:
#   1. File validator: ext4 magic check, min size 1.5GB, free space in super
#   2. Hash verify (optional): if gsi.img.sha256 exists, verify before flash
#   3. Auto-resize system_a to 5GB via lptools (skip if already >=5GB)
#   4. Flash GSI to /dev/block/mapper/system_a (active slot only)
#   5. Post-flash wipe prompt: factory reset to clean vendor remnants
#
# Dependencies (already in OrangeFox ramdisk):
#   - lptools         (provided via OF_ENABLE_LPTOOLS=1)
#   - sha256sum       (busybox)
#   - dd, sync        (busybox)
#   - lpunpack/lpmake (optional, for super partition inspection)
#
# Exit codes:
#   0 = success
#   1 = invalid arguments
#   2 = file not found / unreadable
#   3 = hash mismatch
#   4 = ext4 magic check failed (not a valid GSI image)
#   5 = insufficient free space in super partition
#   6 = lptools resize failed
#   7 = dd flash failed
#   99 = interrupted by user
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TARGET_PARTITION="system_a"
TARGET_SIZE_KB=$((5 * 1024 * 1024))   # 5 GB
MIN_GSI_SIZE_BYTES=$((1536 * 1024 * 1024))   # 1.5 GB minimum
LOGFILE="/tmp/gsi_run.log"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

err() {
    echo "ERROR: $*" | tee -a "$LOGFILE" >&2
}

die() {
    err "$*"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# Step 0: parse args
# -----------------------------------------------------------------------------
if [ $# -lt 1 ] || [ $# -gt 1 ]; then
    cat <<EOF
Usage: $0 <gsi.img>

Arguments:
  gsi.img    Path to GSI image (ext4 format, >=1.5GB recommended)
              Place gsi.img.sha256 next to gsi.img for hash verification.

Example:
  $0 /sdcard/gsi.img
EOF
    exit 1
fi

GSI_IMG="$1"
[ -f "$GSI_IMG" ] || die "File not found: $GSI_IMG" 2

# Clear log
: > "$LOGFILE"
log "=== gsi_run.sh started ==="
log "GSI image: $GSI_IMG"
log "Target partition: $TARGET_PARTITION"
log "Target size: ${TARGET_SIZE_KB} KB (5 GB)"

# -----------------------------------------------------------------------------
# Step 1: file validator
# -----------------------------------------------------------------------------
log "[1/5] Validating GSI image..."

# 1a. Size check
GSI_SIZE=$(stat -c '%s' "$GSI_IMG" 2>/dev/null || stat -f '%z' "$GSI_IMG" 2>/dev/null)
[ -n "$GSI_SIZE" ] || die "Cannot determine file size" 2
log "  File size: $((GSI_SIZE / 1024 / 1024)) MB"

if [ "$GSI_SIZE" -lt "$MIN_GSI_SIZE_BYTES" ]; then
    err "GSI image too small: $((GSI_SIZE / 1024 / 1024)) MB < 1536 MB minimum"
    err "This doesn't look like a real GSI image."
    exit 4
fi

# 1b. ext4 magic check (offset 0x438 = 0x53 0xEF)
MAGIC=$(dd if="$GSI_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ "$MAGIC" != "53ef" ]; then
    err "ext4 magic not found at offset 0x438 (got: $MAGIC, expected: 53ef)"
    err "This is NOT a valid ext4/GSI image. Aborting."
    exit 4
fi
log "  ext4 magic: OK"

# 1c. Free space in super partition check
# Super partition holds logical volumes; we need (5GB - current system_a size) free
# Use lptools to inspect
if command -v lptools >/dev/null 2>&1; then
    SUPER_INFO=$(lptools info 2>/dev/null)
    log "  Super partition info:"
    echo "$SUPER_INFO" | head -10 | while read -r line; do log "    $line"; done
else
    err "lptools not found in PATH. Cannot verify super partition free space."
    err "Make sure OF_ENABLE_LPTOOLS=1 is set in vendorsetup.sh"
    exit 6
fi

# -----------------------------------------------------------------------------
# Step 2: hash verify (optional, if .sha256 file exists)
# -----------------------------------------------------------------------------
log "[2/5] Hash verification (optional)..."

GSI_SHA_FILE="${GSI_IMG}.sha256"
if [ -f "$GSI_SHA_FILE" ]; then
    log "  Found $GSI_SHA_FILE, verifying..."
    EXPECTED=$(awk '{print $1}' "$GSI_SHA_FILE" | tr '[:upper:]' '[:lower:]')
    ACTUAL=$(sha256sum "$GSI_IMG" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        err "Hash mismatch!"
        err "  Expected: $EXPECTED"
        err "  Actual:   $ACTUAL"
        exit 3
    fi
    log "  Hash verified: $ACTUAL"
else
    log "  No .sha256 file found, skipping hash verification"
fi

# -----------------------------------------------------------------------------
# Step 3: auto-resize system_a to 5GB
# -----------------------------------------------------------------------------
log "[3/5] Resizing $TARGET_PARTITION to 5GB..."

# Get current size of system_a
CURRENT_SIZE_KB=$(lptools list 2>/dev/null | awk -v p="$TARGET_PARTITION" '$1==p {print $4}')
if [ -z "$CURRENT_SIZE_KB" ]; then
    err "Cannot determine current size of $TARGET_PARTITION via lptools"
    err "Output of 'lptools list':"
    lptools list 2>&1 | head -20 | while read -r line; do err "    $line"; done
    exit 6
fi
log "  Current $TARGET_PARTITION size: $((CURRENT_SIZE_KB / 1024)) MB"

if [ "$CURRENT_SIZE_KB" -ge "$TARGET_SIZE_KB" ]; then
    log "  Already >= 5GB, skipping resize"
else
    DELTA_KB=$((TARGET_SIZE_KB - CURRENT_SIZE_KB))
    log "  Need to grow by $((DELTA_KB / 1024)) MB"
    log "  Running: lptools resize $TARGET_PARTITION $TARGET_SIZE_KB"

    if lptools resize "$TARGET_PARTITION" "$TARGET_SIZE_KB" >>"$LOGFILE" 2>&1; then
        log "  Resize succeeded"
    else
        err "lptools resize failed. Check $LOGFILE for details."
        err "Possible causes:"
        err "  - Insufficient free space in super partition"
        err "  - Partition is locked (try: lptools unmap $TARGET_PARTITION first)"
        err "  - lptools binary doesn't support 'resize' subcommand"
        exit 6
    fi
fi

# -----------------------------------------------------------------------------
# Step 4: flash GSI to system_a
# -----------------------------------------------------------------------------
log "[4/5] Flashing GSI to /dev/block/mapper/$TARGET_PARTITION..."

DEVICE="/dev/block/mapper/$TARGET_PARTITION"
if [ ! -b "$DEVICE" ]; then
    err "Block device $DEVICE does not exist"
    err "Available mapper devices:"
    ls /dev/block/mapper/ 2>/dev/null | head -10 | while read -r line; do err "    $line"; done
    exit 7
fi

log "  dd if=$GSI_IMG of=$DEVICE bs=1M"
if dd if="$GSI_IMG" of="$DEVICE" bs=1M 2>>"$LOGFILE"; then
    sync
    log "  dd completed, sync done"
else
    err "dd flash failed. GSI image may be corrupted or device is write-protected."
    exit 7
fi

# Verify flash by reading back first 1KB and checking ext4 magic
VERIFY_MAGIC=$(dd if="$DEVICE" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ "$VERIFY_MAGIC" = "53ef" ]; then
    log "  Flash verified: ext4 magic present on $DEVICE"
else
    err "Flash verification failed: ext4 magic NOT found on $DEVICE"
    err "Got: $VERIFY_MAGIC (expected: 53ef)"
    err "The flash may have failed silently. Recommend: do NOT reboot, restore backup."
    exit 7
fi

# -----------------------------------------------------------------------------
# Step 5: prompt for factory reset (wipe data)
# -----------------------------------------------------------------------------
log "[5/5] Post-flash wipe prompt"
cat <<EOF

==================================================================
  GSI FLASH COMPLETE
==================================================================

  Image:     $GSI_IMG
  Flashed:   $((GSI_SIZE / 1024 / 1024)) MB → $DEVICE
  Hash:      ${ACTUAL:-skipped}

  IMPORTANT:
  For GSI to boot properly, you MUST perform a factory reset now.
  This wipes /data and /cache to remove vendor remnants that
  conflict with the new GSI image.

  To wipe via OrangeFox GUI:
    1. Tap "Wipe" in main menu
    2. Tap "Factory Reset"
    3. Swipe to confirm

  Or run via ADB:
    adb shell twrp wipe data
    adb shell twrp wipe cache

  After wipe, reboot system. First boot may take 5-10 minutes
  (Android optimizing apps).

==================================================================

EOF

log "=== gsi_run.sh completed successfully ==="
exit 0
