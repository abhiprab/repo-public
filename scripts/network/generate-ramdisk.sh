#!/usr/bin/env bash
# generate-ramdisk-images.sh - Version 1.3
# Displays full CMSH table with headings for informed selection.

set -u

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}[INFO] Querying Bright Cluster Manager for Software Images...${NC}\n"

# 1. Capture the raw list
RAW_LIST=$(cmsh -c "softwareimage; list")

# 2. Extract the keys (image names) into an array for the menu
# We skip NR==1 (headings) and NR==2 (dashes) for the array, but keep them for display
mapfile -t ALL_IMAGES < <(echo "$RAW_LIST" | awk 'NR>2 {print $1}')

if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No software images found.${NC}"
    exit 1
fi

# 3. Show the full CMSH table WITH headings
echo -e "${CYAN}Current Software Image Status:${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
echo "$RAW_LIST"
echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

# 4. Display the Numbered Selection Menu
echo -e "\n${YELLOW}Select images for Ramdisk Generation:${NC}"
for i in "${!ALL_IMAGES[@]}"; do
    # Calculate node count for the 'Recommended' hint
    # We look at the 4th column of the row matching the image name
    node_count=$(echo "$RAW_LIST" | grep "^${ALL_IMAGES[$i]} " | awk '{print $NF}')
    
    hint=""
    if [[ "$node_count" -gt 0 ]]; then
        hint=" ${GREEN}(Active: $node_count nodes)${NC}"
    fi

    printf "%2d) %-25s %b\n" "$((i+1))" "${ALL_IMAGES[$i]}" "$hint"
done
echo -e " a) ALL Images"
echo -e " q) Quit"

echo -e "\n${CYAN}Selection (e.g. 1,2 or 'a'):${NC}"
read -p ">> " choice

# 5. Process Selection
SELECTED_IMAGES=()
if [[ "$choice" == "a" ]]; then
    SELECTED_IMAGES=("${ALL_IMAGES[@]}")
elif [[ "$choice" == "q" || -z "$choice" ]]; then
    echo -e "${BLUE}Action cancelled.${NC}"
    exit 0
else
    # Parse comma-separated numbers
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#ALL_IMAGES[@]}" ] && [ "$idx" -gt 0 ]; then
            SELECTED_IMAGES+=("${ALL_IMAGES[$((idx-1))]}")
        fi
    done
fi

# 6. Execute Trigger
if [[ ${#SELECTED_IMAGES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No valid selections made.${NC}"
    exit 1
fi

echo -e "\n${BLUE}[INFO] Submitting createramdisk tasks...${NC}"
for img in "${SELECTED_IMAGES[@]}"; do
    echo -ne "  --> $img... "
    if cmsh -c "softwareimage; createramdisk $img" > /dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${RED}[FAILED]${NC}"
    fi
done

echo -e "\n${YELLOW}[TIP]${NC} Check progress with: ${CYAN}cmsh -c \"job; list\"${NC} or ${CYAN}tail -f /var/log/cm-cmdlog${NC}"
