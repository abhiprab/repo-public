#!/usr/bin/env bash
# bake-udev-images.sh - Version 1.2
# Interactive selection for baking UDEV rules into Bright Software Images.

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

# --- 1. IMAGE DISCOVERY ---
echo -e "${BLUE}[INFO] Querying Bright Cluster Manager for Software Images...${NC}\n"

# Capture raw list for table display
RAW_LIST=$(cmsh -c "softwareimage; list")
# Map image names into an array
mapfile -t ALL_IMGS < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

if [[ ${#ALL_IMGS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No software images found.${NC}"
    exit 1
fi

# --- 2. DISPLAY STATUS TABLE ---
echo -e "${CYAN}Current Software Image Status:${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
echo "$RAW_LIST"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

# --- 3. SELECTION MENU ---
echo -e "${YELLOW}Select images to bake UDEV rules into:${NC}"
for i in "${!ALL_IMGS[@]}"; do
    node_count=$(echo "$RAW_LIST" | grep "^${ALL_IMGS[$i]} " | awk '{print $NF}')
    hint=""
    [[ "$node_count" -gt 0 ]] && hint=" ${GREEN}(Active: $node_count nodes)${NC}"
    printf "%2d) %-25s %b\n" "$((i+1))" "${ALL_IMGS[$i]}" "$hint"
done
echo -e " a) ALL Images"
echo -e " q) Quit"

echo -e "\n${CYAN}Selection (e.g. 1,2 or 'a'):${NC}"
read -p ">> " choice

# --- 4. PROCESS SELECTION ---
SELECTED_IMGS=()
if [[ "$choice" == "a" ]]; then
    SELECTED_IMGS=("${ALL_IMGS[@]}")
elif [[ "$choice" == "q" || -z "$choice" ]]; then
    echo -e "${BLUE}Action cancelled.${NC}"
    exit 0
else
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#ALL_IMGS[@]}" ] && [ "$idx" -gt 0 ]; then
            SELECTED_IMGS+=("${ALL_IMGS[$((idx-1))]}")
        fi
    done
fi

if [[ ${#SELECTED_IMGS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No valid selections made.${NC}"
    exit 1
fi

# --- 5. SOURCE VALIDATION ---
SOURCE_RULES="${1:-$DEFAULT_SOURCE}"
if [[ ! -f "$SOURCE_RULES" ]]; then
    echo -e "${RED}[ERROR] No rules file found at: $SOURCE_RULES${NC}"
    exit 1
fi

# --- 6. BAKING PROCESS ---
echo -e "\n${BLUE}[INFO] Baking Rules into Selected Images...${NC}"
for img in "${SELECTED_IMGS[@]}"; do
    img_path="${IMAGES_ROOT}/${img}"
    if [[ -d "$img_path" && -d "${img_path}/etc" ]]; then
        DEST_DIR="${img_path}/etc/udev/rules.d"
        FULL_DEST_PATH="${DEST_DIR}/${TARGET_FILE}"
        
        echo -e "${BLUE}>>> Processing Image: $img${NC}"
        sudo mkdir -p "$DEST_DIR"

        # Rotation Logic
        if [[ -f "$FULL_DEST_PATH" ]]; then
            OLD_FILE_TS=$(date -r "$FULL_DEST_PATH" +%F-%H%M%S)
            echo -e "    ${YELLOW}[BACKUP]${NC} Existing rules saved as .${OLD_FILE_TS}.old"
            sudo mv "$FULL_DEST_PATH" "${FULL_DEST_PATH}.${OLD_FILE_TS}.old"
        fi

        # Copy Rules
        if sudo cp -f "$SOURCE_RULES" "$FULL_DEST_PATH"; then
            echo -e "    ${GREEN}[OK]${NC} New rules baked successfully."
        else
            echo -e "    ${RED}[FAILED]${NC} Error copying to $img"
        fi
    else
        echo -e "    ${RED}[SKIP]${NC} $img (Path not found or invalid)"
    fi
done

echo -e "\n${GREEN}[SUCCESS] Image baking cycle complete.${NC}"
