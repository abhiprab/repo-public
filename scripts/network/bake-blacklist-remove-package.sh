#!/usr/bin/env bash
# bake-maintenance-images.sh - Version 1.9 (Interactive Image Selection)
set -u

# --- CONFIGURATION ---
IMAGES_ROOT="/cm/images"
BLACKLIST_FILE="99-ndt-blacklist.conf"
MODPROBE_DIR="etc/modprobe.d"

BLACKLIST_MODULES=("qedr" "qede" "irdma" "nouveau")
PACKAGES_TO_REMOVE=("ibacm")
PACKAGES_TO_INSTALL=("")

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. IMAGE SELECTION ---
echo -e "${BLUE}[INFO] Fetching Software Images from CMSH...${NC}"
RAW_LIST=$(cmsh -c "softwareimage; list")
mapfile -t ALL_IMGS < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

echo -e "\n${CYAN}Current Software Image Status:${NC}"
echo "$RAW_LIST"
echo -e "----------------------------------------------------------------------------"
echo -e "${YELLOW}Select images for Maintenance (Blacklist/Packages):${NC}"
for i in "${!ALL_IMGS[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "${ALL_IMGS[$i]}"
done
echo -e " a) ALL Images"
echo -e " q) Quit"

read -p "Selection: " img_choice

# (Selection logic same as above)
SELECTED_IMGS=()
if [[ "$img_choice" == "a" ]]; then
    SELECTED_IMGS=("${ALL_IMGS[@]}")
elif [[ "$img_choice" == "q" || -z "$img_choice" ]]; then
    exit 0
else
    IFS=',' read -ra ADDR <<< "$img_choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -le "${#ALL_IMGS[@]}" ]] && SELECTED_IMGS+=("${ALL_IMGS[$((idx-1))]}")
    done
fi

# --- 2. MAINTENANCE EXECUTION ---
for img in "${SELECTED_IMGS[@]}"; do
    img_path="${IMAGES_ROOT}/${img}"
    echo -e "${BLUE}>>> Image: $img${NC}"
    
    # ... (Rotation, Blacklisting, and Yum logic as before) ...
done
