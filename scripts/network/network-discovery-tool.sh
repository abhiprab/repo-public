#!/usr/bin/env bash
# NETWORK DISCOVERY TOOL (NDT) - Version 6.1
# Unified Management Suite with Strict Linear Workflow Enforcement.
set -u

# --- CONFIGURATION ---
TARGET_DIR="/cm/shared/scripts/net-mapping"
REPO_URL="https://github.com/abhiprab/repo-public.git"
REPO_SUBDIR="scripts/network"

# Standardized Script Mapping
MAPPING_SCRIPT="nic-mapping-univ.sh"
COLLECT_SCRIPT="nic-mapping-univ-all-nodes.sh"
GEN_RULES_SCRIPT="generate-udev-rules.sh"
DEPLOY_RULES_SCRIPT="deploy-udev-rules.sh" # Option 4: Push to live nodes
BAKE_MAINT_SCRIPT="bake-blacklist-remove-package.sh"
GEN_RAMDISK_SCRIPT="generate-ramdisk.sh"
TRIGGER_UPDATE_SCRIPT="node-image-update.sh"
TRIGGER_UDEV_SCRIPT="apply-udev-live.sh"

REQUIRED_FILES=(
    "$MAPPING_SCRIPT" "$COLLECT_SCRIPT" "$GEN_RULES_SCRIPT" 
    "$DEPLOY_RULES_SCRIPT" "$BAKE_MAINT_SCRIPT" "$GEN_RAMDISK_SCRIPT"
    "$TRIGGER_UPDATE_SCRIPT" "$TRIGGER_UDEV_SCRIPT"
)

# --- UI COLORS ---
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export RED='\033[0;31m'
export NC='\033[0m'

# --- 1. SYNC ENVIRONMENT ---
sync_env() {
    echo -e "${BLUE}[INFO] Synchronizing NDT Toolkit...${NC}"
    [ ! -d "$TARGET_DIR" ] && sudo mkdir -p "$TARGET_DIR" && sudo chown $USER:$USER "$TARGET_DIR"
    
    TMP_CLONE=$(mktemp -d)
    if git clone --depth 1 "$REPO_URL" "$TMP_CLONE" --quiet; then
        for file in "${REQUIRED_FILES[@]}"; do
            if [ -f "${TMP_CLONE}/${REPO_SUBDIR}/${file}" ]; then
                cp -f "${TMP_CLONE}/${REPO_SUBDIR}/${file}" "$TARGET_DIR/"
                chmod +x "${TARGET_DIR}/${file}"
            fi
        done
        rm -rf "$TMP_CLONE"
        echo -e "${GREEN}[SUCCESS] Environment updated to Version 6.1${NC}"
    else
        echo -e "${RED}[ERROR] GitHub Sync Failed. Check connectivity.${NC}"
        exit 1
    fi
}

# --- 2. MAIN MENU ---
sync_env 

while true; do
    echo -e "\n${YELLOW}==============================================================${NC}"
    echo -e "${CYAN}   NETWORK DISCOVERY & IMAGE MANAGEMENT SUITE (NDT)${NC}"
    echo -e "${YELLOW}==============================================================${NC}"
    echo -e "${BLUE}INVENTORY & RULES:${NC}"
    echo -e "  1) Local Node Network Scan"
    echo -e "  2) Cluster-Wide Network Inventory (Worker Nodes)"
    echo -e "  3) Generate UDEV Rules (Requires Option 2 first)"
    echo -e "  4) Push UDEV Rules to Live Nodes (SCP/SSH)"
    echo -e ""
    echo -e "${BLUE}IMAGE MAINTENANCE:${NC}"
    echo -e "  5) Blacklist Modules and Remove Packages from Images"
    echo -e "  6) Generate/Rebuild Image Ramdisks (createramdisk)"
    echo -e ""
    echo -e "${BLUE}LIVE NODE SYNC:${NC}"
    echo -e "  7) Trigger Image Update Signal (cmsh imageupdate)"
    echo -e "  8) Trigger Live UDEV Command (reload/trigger/settle)"
    echo -e ""
    echo -e "${RED}  q) Exit NDT Session${NC}"
    echo -e "--------------------------------------------------------------"
    
    read -p "Select Option: " opt
    case "${opt:-}" in
        1) sudo "${TARGET_DIR}/${MAPPING_SCRIPT}" --print ; read -p "Press Enter..." ;;
        2) bash "${TARGET_DIR}/${COLLECT_SCRIPT}" ; read -p "Press Enter..." ;;
        3) bash "${TARGET_DIR}/${GEN_RULES_SCRIPT}" ; read -p "Press Enter..." ;;
        4) bash "${TARGET_DIR}/${DEPLOY_RULES_SCRIPT}" ; read -p "Press Enter..." ;;
        5) bash "${TARGET_DIR}/${BAKE_MAINT_SCRIPT}" ; read -p "Press Enter..." ;;
        6) bash "${TARGET_DIR}/${GEN_RAMDISK_SCRIPT}" ; read -p "Press Enter..." ;;
        7) bash "${TARGET_DIR}/${TRIGGER_UPDATE_SCRIPT}" ; read -p "Press Enter..." ;;
        8) bash "${TARGET_DIR}/${TRIGGER_UDEV_SCRIPT}" ; read -p "Press Enter..." ;;
        q) echo -e "${BLUE}Exiting NDT Session.${NC}" ; exit 0 ;;
        *) echo -e "${RED}Invalid selection.${NC}" ; sleep 1 ;;
    esac
done
