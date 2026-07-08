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
#   - lptools         (phhusson/vendor_lptools via OF_ENABLE_LPTOOLS=1)
#                       Subcommands: create|remove|resize|rename|map|unmap|free
#                       NOTE: NO 'info' or 'list' subcommand — use 'lptools free'
#                       for free space and blockdev for current partition size.
#   - sha256sum       (busybox)
#   - dd, sync        (busybox)
#   - blockdev        (busybox)
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

# -e: exit on any command failure
# -u: error on unset variable
# -o pipefail: a pipeline fails if ANY command fails (default sh doesn't have this,
#   but busybox ash/toybox sh support it; if not, the explicit checks below catch it)
set -eu

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TARGET_PARTITION="system_a"
# lptools expects size in BYTES (verified from phhusson/vendor_lptools source:
#   atoll(argv[2]) -> uint64_t bytes
# 5 GB = 5 * 1024 * 1024 * 1024 = 5368709120 bytes
TARGET_SIZE_BYTES=$((5 * 1024 * 1024 * 1024))
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
if [ $# -ne 1 ]; then
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
log "Target size: ${TARGET_SIZE_BYTES} bytes (5 GB)"

# -----------------------------------------------------------------------------
# Step 1: file validator
# -----------------------------------------------------------------------------
log "[1/5] Validating GSI image..."

# 1a. Size check (busybox stat supports -c on Linux, fallback to -f for BSD/macOS)
GSI_SIZE=$(stat -c '%s' "$GSI_IMG" 2>/dev/null || stat -f '%z' "$GSI_IMG" 2>/dev/null) || \
    die "Cannot determine file size" 2
log "  File size: $((GSI_SIZE / 1024 / 1024)) MB"

if [ "$GSI_SIZE" -lt "$MIN_GSI_SIZE_BYTES" ]; then
    err "GSI image too small: $((GSI_SIZE / 1024 / 1024)) MB < 1536 MB minimum"
    err "This doesn't look like a real GSI image."
    exit 4
fi

# 1b. ext4 magic check (offset 0x438 = 0x53 0xEF, decimal offset 1080)
MAGIC=$(dd if="$GSI_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ "$MAGIC" != "53ef" ]; then
    err "ext4 magic not found at offset 0x438 (got: $MAGIC, expected: 53ef)"
    err "This is NOT a valid ext4/GSI image. Aborting."
    exit 4
fi
log "  ext4 magic: OK"

# 1c. Free space in super partition check
# lptools supports 'free' subcommand — prints free bytes in super partition.
# lptools does NOT have 'info' or 'list' — those were invalid subcommands.
if ! command -v lptools >/dev/null 2>&1; then
    err "lptools not found in PATH."
    err "Make sure OF_ENABLE_LPTOOLS=1 is set in vendorsetup.sh"
    exit 6
fi

SUPER_FREE_BYTES=$(lptools free 2>/dev/null) || die "lptools free failed" 6
log "  Super partition free space: $((SUPER_FREE_BYTES / 1024 / 1024)) MB"

# Compute delta needed (only if resize will run; we don't know current size yet,
# so we conservatively check that at least (5GB - 0) = 5GB is free if resize is needed.
# The actual resize step will fail gracefully if there's not enough space.
if [ "$SUPER_FREE_BYTES" -lt "$TARGET_SIZE_BYTES" ]; then
    err "WARNING: super partition free space ($((SUPER_FREE_BYTES / 1024 / 1024)) MB)"
    err "is less than target size (5120 MB). Resize may fail."
    err "Continuing anyway — will fail at resize step if needed."
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

# Get current size of system_a via blockdev (lptools has no 'list' subcommand).
# blockdev --getsize64 returns size in bytes.
DEVICE="/dev/block/mapper/$TARGET_PARTITION"
if [ ! -b "$DEVICE" ]; then
    err "Block device $DEVICE does not exist"
    err "Available mapper devices:"
    ls /dev/block/mapper/ 2>/dev/null | head -10 | while read -r line; do err "    $line"; done
    exit 7
fi

CURRENT_SIZE_BYTES=$(blockdev --getsize64 "$DEVICE" 2>/dev/null) || \
    die "Cannot determine current size of $DEVICE via blockdev" 6
log "  Current $TARGET_PARTITION size: $((CURRENT_SIZE_BYTES / 1024 / 1024)) MB"

if [ "$CURRENT_SIZE_BYTES" -ge "$TARGET_SIZE_BYTES" ]; then
    log "  Already >= 5GB, skipping resize"
else
    DELTA_BYTES=$((TARGET_SIZE_BYTES - CURRENT_SIZE_BYTES))
    log "  Need to grow by $((DELTA_BYTES / 1024 / 1024)) MB"
    log "  Running: lptools resize $TARGET_PARTITION $TARGET_SIZE_BYTES"

    # lptools resize <partition_name> <new_size_in_bytes>
    if lptools resize "$TARGET_PARTITION" "$TARGET_SIZE_BYTES" >>"$LOGFILE" 2>&1; then
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
log "[4/5] Flashing GSI to $DEVICE..."

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
