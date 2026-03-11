#!/usr/bin/env bash
# bake-udev-rules-image.sh - Version 1.5
# Includes Pre-Flight check to ensure rules exist before selection.

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
UDEV_ROOT="${BASE_DIR}/out/udev_rules"
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

# --- 1. PRE-FLIGHT CHECK ---
# Check if the source rules file exists before doing anything else
if [[ ! -f "$DEFAULT_SOURCE" ]]; then
    echo -e "${RED}[ERROR] Required UDEV rules file is missing!${NC}"
    echo -e "${YELLOW}Path:${NC} $DEFAULT_SOURCE"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC}"
    echo -e "You must generate the cluster-wide rules first."
    echo -e "Please go back to the Main Menu and choose ${CYAN}Option 3 (Generate UDEV Rules)${NC}."
    echo -e "----------------------------------------------------------------------------"
    exit 1
fi

# --- 2. IMAGE DISCOVERY ---
echo -e "${BLUE}[INFO] Querying Bright Cluster Manager for Software Images...${NC}\n"

RAW_LIST=$(cmsh -c "softwareimage; list")
mapfile -t ALL_IMGS < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

if [[ ${#ALL_IMGS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No software images found.${NC}"; exit 1
fi

# --- 3. DISPLAY STATUS TABLE ---
echo -e "${CYAN}Current Software Image Status:${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
echo "$RAW_LIST"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

# --- 4. SELECTION MENU ---
echo -e "${YELLOW}Select images to bake UDEV rules into:${NC}"
for i in "${!ALL_IMGS[@]}"; do
    node_count=$(echo "$RAW_LIST" | grep "^${ALL_IMGS[$i]} " | awk '{print $NF}')
    hint=$([[ "$node_count" -gt 0 ]] && echo -e " ${GREEN}(Active: $node_count nodes)${NC}" || echo "")
    printf "%2d) %-25s %b\n" "$((i+1))" "${ALL_IMGS[$i]}" "$hint"
done
echo -e " a) ALL Images\n q) Quit"

echo -e "\n${CYAN}Selection (e.g. 1,2 or 'a'):${NC}"
read -p ">> " choice

# --- 5. SELECTION PROCESSING ---
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

# --- 6. EXECUTION ---
echo -e "\n${BLUE}[INFO] Baking Rules into Selected Images...${NC}"
for img in "${SELECTED_IMGS[@]}"; do
    img_path="${IMAGES_ROOT}/${img}"
    if [[ -d "$img_path" && -d "${img_path}/etc" ]]; then
        DEST_DIR="${img_path}/etc/udev/rules.d"
        echo -ne "  --> $img: "
        sudo mkdir -p "$DEST_DIR"
        if sudo cp -f "$DEFAULT_SOURCE" "${DEST_DIR}/${TARGET_FILE}"; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[FAILED]${NC}"
        fi
    else
        echo -e "  --> $img: ${RED}[SKIP]${NC} (Invalid path)"
    fi
done

echo -e "\n${GREEN}[SUCCESS] UDEV rules baked into selected images.${NC}"
