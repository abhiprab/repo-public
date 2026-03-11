#!/usr/bin/env bash
# bake-udev-images.sh - Version 1.1
# Renames existing rules to .old and bakes new cluster-wide rules into worker images.

set -u

# --- CONFIGURATION ---
UDEV_ROOT="/cm/shared/scripts/net-mapping/out/udev_rules"
DEFAULT_SOURCE="${UDEV_ROOT}/latest/cluster_wide_baked.rules"
IMAGES_ROOT="/cm/images"
TARGET_FILE="80-cluster-wide-nics.rules"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- AUTO-DISCOVERY ---
SOURCE_RULES="${1:-$DEFAULT_SOURCE}"

if [[ ! -f "$SOURCE_RULES" ]]; then
    echo -e "${RED}[ERROR] No rules file found at: $SOURCE_RULES${NC}"
    exit 1
fi

FILE_TIME=$(date -r "$SOURCE_RULES" "+%Y-%m-%d %H:%M:%S")
echo -e "${BLUE}[INFO] Found Rules: ${NC}$(basename "$SOURCE_RULES") ($FILE_TIME)"

# --- BAKING PROCESS ---
shopt -s nullglob
worker_images=("$IMAGES_ROOT"/*worker*)

for img_path in "${worker_images[@]}"; do
    if [[ -d "$img_path" && -d "${img_path}/etc" ]]; then
        IMG_NAME=$(basename "$img_path")
        DEST_DIR="${img_path}/etc/udev/rules.d"
        FULL_DEST_PATH="${DEST_DIR}/${TARGET_FILE}"
        
        echo -e "${BLUE}>>> Image: $IMG_NAME${NC}"
        sudo mkdir -p "$DEST_DIR"

        # --- ROTATION LOGIC ---
        if [[ -f "$FULL_DEST_PATH" ]]; then
            # Create a timestamp for the old file to prevent overwriting previous backups
            OLD_FILE_TS=$(date -r "$FULL_DEST_PATH" +%F-%H%M%S)
            echo -e "    ${YELLOW}[BACKUP]${NC} Renaming existing rules to ${TARGET_FILE}.${OLD_FILE_TS}.old"
            sudo mv "$FULL_DEST_PATH" "${FULL_DEST_PATH}.${OLD_FILE_TS}.old"
        fi

        # --- COPY NEW RULES ---
        if sudo cp -f "$SOURCE_RULES" "$FULL_DEST_PATH"; then
            echo -e "    ${GREEN}[OK]${NC} New rules baked successfully."
        else
            echo -e "    ${RED}[FAILED]${NC} Error copying to $IMG_NAME"
        fi
    fi
done

echo -e "\n${GREEN}[SUCCESS] All worker images updated.${NC}"
