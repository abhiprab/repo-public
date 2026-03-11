#!/usr/bin/env bash
# bake-udev-rules-image.sh - Version 1.4
# Reference Logic: generate-ramdisk.sh

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
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}[INFO] Querying Bright Cluster Manager for Software Images...${NC}\n"

# 1. Capture raw list
RAW_LIST=$(cmsh -c "softwareimage; list")
mapfile -t ALL_IMGS < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

# 2. Display Table
echo -e "${CYAN}Current Software Image Status:${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
echo "$RAW_LIST"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

# 3. Selection Menu with Active Node Info
echo -e "${YELLOW}Select images to bake UDEV rules into:${NC}"
for i in "${!ALL_IMGS[@]}"; do
    node_count=$(echo "$RAW_LIST" | grep "^${ALL_IMGS[$i]} " | awk '{print $NF}')
    hint=""
    [[ "$node_count" -gt 0 ]] && hint=" ${GREEN}(Active: $node_count nodes)${NC}"
    printf "%2d) %-25s %b\n" "$((i+1))" "${ALL_IMGS[$i]}" "$hint"
done
echo -e " a) ALL Images\n q) Quit"

echo -e "\n${CYAN}Selection (e.g. 1,2 or 'a'):${NC}"
read -p ">> " choice

# --- 4. SELECTION PROCESSING ---
SELECTED_IMGS=()
if [[ "$choice" == "a" ]]; then SELECTED_IMGS=("${ALL_IMGS[@]}")
elif [[ "$choice" == "q" || -z "$choice" ]]; then exit 0
else
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -le "${#ALL_IMGS[@]}" ]] && SELECTED_IMGS+=("${ALL_IMGS[$((idx-1))]}")
    done
fi

# --- 5. EXECUTION ---
SOURCE_RULES="${1:-$DEFAULT_SOURCE}"
if [[ ! -f "$SOURCE_RULES" ]]; then
    echo -e "${RED}[ERROR] Rules file not found at: $SOURCE_RULES${NC}"; exit 1
fi

echo -e "\n${BLUE}[INFO] Baking Rules into Selected Images...${NC}"
for img in "${SELECTED_IMGS[@]}"; do
    img_path="${IMAGES_ROOT}/${img}"
    DEST_DIR="${img_path}/etc/udev/rules.d"
    echo -ne "  --> $img: "
    sudo mkdir -p "$DEST_DIR"
    if sudo cp -f "$SOURCE_RULES" "${DEST_DIR}/${TARGET_FILE}"; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${RED}[FAILED]${NC}"
    fi
done
