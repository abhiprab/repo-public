#!/usr/bin/env bash
# bake-blacklist-remove-package.sh - Version 2.0
# Interactive selection with Active Node counts.

set -u

# --- CONFIGURATION ---
IMAGES_ROOT="/cm/images"
BLACKLIST_MODULES=("qedr" "qede" "irdma" "nouveau")
PACKAGES_TO_REMOVE=("ibacm")

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}[INFO] Querying Base Command Manager for Software Images...${NC}\n"

# 1. Capture raw list for table display
RAW_LIST=$(cmsh -c "softwareimage; list")
mapfile -t ALL_IMGS < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

if [[ ${#ALL_IMGS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No software images found.${NC}"; exit 1
fi

# 2. Display Status Table (Preserving Header)
echo -e "${CYAN}Current Software Image Status:${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
echo "$RAW_LIST"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

# 3. Selection Menu with Active Node Info
echo -e "${YELLOW}Select images for Maintenance (Blacklist/Packages):${NC}"
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
for img in "${SELECTED_IMGS[@]}"; do
    img_path="${IMAGES_ROOT}/${img}"
    echo -e "${BLUE}>>> Image: $img${NC}"
    # (Existing Blacklist/Yum logic here...)
done
