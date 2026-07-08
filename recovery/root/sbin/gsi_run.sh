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
#   1. File validator: ext4 magic check, min size 1.5GB
#   2. Hash verify (optional): if gsi.img.sha256 exists, verify before flash
#   3. Smart resize:
#      - Target size = GSI_size + 200MB headroom (capped 1.5GB min, 6GB max)
#      - If current system >= target, skip resize
#      - If super free >= delta needed, resize directly
#      - If super free < delta, shrink system_ext → product (NEVER vendor)
#        to free up space, then resize system
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
#   5 = insufficient free space in super partition (even after shrinking others)
#   6 = lptools operation failed (resize/remove)
#   7 = dd flash failed
#   99 = interrupted by user
# =============================================================================

# -e: exit on any command failure
# -u: error on unset variable
set -eu

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TARGET_PARTITION="system_a"
DEVICE="/dev/block/mapper/$TARGET_PARTITION"

# Resize bounds (bytes)
# MIN: enough for smallest known GSI (1.5GB) + 200MB headroom = ~1.7GB
# MAX: 6GB — avoid consuming entire super partition, leave room for other partitions
MIN_SYSTEM_SIZE_BYTES=$((1700 * 1024 * 1024))           # 1.7 GB
MAX_SYSTEM_SIZE_BYTES=$((6 * 1024 * 1024 * 1024))       # 6 GB
HEADROOM_BYTES=$((200 * 1024 * 1024))                   # 200 MB filesystem metadata

# GSI validation
MIN_GSI_SIZE_BYTES=$((1536 * 1024 * 1024))              # 1.5 GB minimum

# Partisi yang BOLEH dikorbankan untuk free up super space (urutan prioritas):
# system_ext dulu (paling tidak critical untuk boot), baru product.
# JANGAN pernah korbankan vendor — vendor berisi HAL drivers yang dibutuh
# untuk boot Android. Tanpa vendor, device akan bootloop.
SACRIFICE_PARTITIONS="system_ext_a system_ext product_a product"

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

# Get partition size in bytes via blockdev (returns 0 if device doesn't exist)
get_part_size() {
    local dev="/dev/block/mapper/$1"
    if [ -b "$dev" ]; then
        blockdev --getsize64 "$dev" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Get super partition free bytes via lptools
get_super_free() {
    lptools free 2>/dev/null || echo 0
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

# -----------------------------------------------------------------------------
# Step 1: file validator
# -----------------------------------------------------------------------------
log "[1/5] Validating GSI image..."

# 1a. Size check
GSI_SIZE=$(stat -c '%s' "$GSI_IMG" 2>/dev/null || stat -f '%z' "$GSI_IMG" 2>/dev/null) || \
    die "Cannot determine file size" 2
log "  GSI file size: $((GSI_SIZE / 1024 / 1024)) MB"

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

# 1c. Verify lptools available
if ! command -v lptools >/dev/null 2>&1; then
    err "lptools not found in PATH."
    err "Make sure OF_ENABLE_LPTOOLS=1 is set in vendorsetup.sh"
    exit 6
fi

# 1d. Verify target device exists
if [ ! -b "$DEVICE" ]; then
    err "Block device $DEVICE does not exist"
    err "Available mapper devices:"
    ls /dev/block/mapper/ 2>/dev/null | head -10 | while read -r line; do err "    $line"; done
    exit 7
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
# Step 3: smart resize system_a
# -----------------------------------------------------------------------------
log "[3/5] Smart resize $TARGET_PARTITION..."

# Compute target size: GSI_size + headroom, clamped to [MIN, MAX]
DESIRED_SIZE=$((GSI_SIZE + HEADROOM_BYTES))
if [ "$DESIRED_SIZE" -lt "$MIN_SYSTEM_SIZE_BYTES" ]; then
    TARGET_SIZE_BYTES=$MIN_SYSTEM_SIZE_BYTES
elif [ "$DESIRED_SIZE" -gt "$MAX_SYSTEM_SIZE_BYTES" ]; then
    TARGET_SIZE_BYTES=$MAX_SYSTEM_SIZE_BYTES
else
    TARGET_SIZE_BYTES=$DESIRED_SIZE
fi
log "  GSI size: $((GSI_SIZE / 1024 / 1024)) MB"
log "  Headroom: $((HEADROOM_BYTES / 1024 / 1024)) MB"
log "  Target system size: $((TARGET_SIZE_BYTES / 1024 / 1024)) MB (clamped to 1.7-6 GB)"

CURRENT_SIZE_BYTES=$(get_part_size "$TARGET_PARTITION")
log "  Current $TARGET_PARTITION size: $((CURRENT_SIZE_BYTES / 1024 / 1024)) MB"

if [ "$CURRENT_SIZE_BYTES" -ge "$TARGET_SIZE_BYTES" ]; then
    log "  Current size >= target — no resize needed"
else
    DELTA_NEEDED=$((TARGET_SIZE_BYTES - CURRENT_SIZE_BYTES))
    log "  Need to grow by: $((DELTA_NEEDED / 1024 / 1024)) MB"

    SUPER_FREE=$(get_super_free)
    log "  Super partition free: $((SUPER_FREE / 1024 / 1024)) MB"

    # If free >= delta, resize directly
    if [ "$SUPER_FREE" -ge "$DELTA_NEEDED" ]; then
        log "  Free space sufficient — resizing directly"
    else
        # Need to free up space by shrinking other partitions
        SHORTFALL=$((DELTA_NEEDED - SUPER_FREE))
        log "  Free space insufficient by: $((SHORTFALL / 1024 / 1024)) MB"
        log "  Attempting to free space by shrinking non-critical partitions..."
        log "  Sacrifice candidates (in order): $SACRIFICE_PARTITIONS"
        log "  NOTE: vendor is NEVER touched (needed for boot)"

        FREED_SO_FAR=0
        for part in $SACRIFICE_PARTITIONS; do
            if [ "$FREED_SO_FAR" -ge "$SHORTFALL" ]; then
                break
            fi

            PART_SIZE=$(get_part_size "$part")
            if [ "$PART_SIZE" -eq 0 ]; then
                log "  - $part: not present or size 0, skipping"
                continue
            fi
            log "  - $part: $((PART_SIZE / 1024 / 1024)) MB present"

            # Shrink this partition to 1MB minimum (essentially deactivating it).
            # We use 1MB instead of 0 because lptools may refuse resize to 0.
            # The partition stays in the super metadata but consumes minimal space.
            MIN_KEEP_BYTES=$((1 * 1024 * 1024))  # 1 MB
            RECLAIMABLE=$((PART_SIZE - MIN_KEEP_BYTES))
            if [ "$RECLAIMABLE" -le 0 ]; then
                log "    no reclaimable space (already at minimum)"
                continue
            fi

            log "    shrinking $part to 1 MB (reclaiming $((RECLAIMABLE / 1024 / 1024)) MB)"
            if lptools resize "$part" "$MIN_KEEP_BYTES" >>"$LOGFILE" 2>&1; then
                FREED_SO_FAR=$((FREED_SO_FAR + RECLAIMABLE))
                log "    OK — total freed so far: $((FREED_SO_FAR / 1024 / 1024)) MB"
            else
                err "    failed to shrink $part (lptools resize returned non-zero)"
                err "    continuing to next candidate"
            fi
        done

        if [ "$FREED_SO_FAR" -lt "$SHORTFALL" ]; then
            err "Could not free enough space."
            err "  Needed: $((SHORTFALL / 1024 / 1024)) MB"
            err "  Freed:  $((FREED_SO_FAR / 1024 / 1024)) MB"
            err "Super partition is too full. Manual intervention required:"
            err "  - Use 'lptools remove system_ext_a' to fully delete (will lose data)"
            err "  - Or flash a smaller GSI image"
            err "  - Or repartition super via fastbootd (advanced, risky)"
            exit 5
        fi

        # Re-check free space after shrinking
        SUPER_FREE=$(get_super_free)
        log "  Super free after shrinking: $((SUPER_FREE / 1024 / 1024)) MB"
        if [ "$SUPER_FREE" -lt "$DELTA_NEEDED" ]; then
            err "BUG: free space still insufficient after shrinking all candidates"
            err "  This shouldn't happen — please report this issue."
            exit 5
        fi
    fi

    # Now resize system_a to target
    log "  Running: lptools resize $TARGET_PARTITION $TARGET_SIZE_BYTES"
    if lptools resize "$TARGET_PARTITION" "$TARGET_SIZE_BYTES" >>"$LOGFILE" 2>&1; then
        log "  Resize succeeded"
        # Verify new size
        NEW_SIZE=$(get_part_size "$TARGET_PARTITION")
        log "  New $TARGET_PARTITION size: $((NEW_SIZE / 1024 / 1024)) MB"
        if [ "$NEW_SIZE" -lt "$TARGET_SIZE_BYTES" ]; then
            err "WARNING: actual size $((NEW_SIZE / 1024 / 1024)) MB < target $((TARGET_SIZE_BYTES / 1024 / 1024)) MB"
            err "lptools may have rounded down. Continuing — flash may still succeed if GSI fits."
        fi
    else
        err "lptools resize failed. Check $LOGFILE for details."
        err "Possible causes:"
        err "  - Insufficient free space in super partition (shouldn't happen after shrinking)"
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
  System size: $((TARGET_SIZE_BYTES / 1024 / 1024)) MB (target)

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
