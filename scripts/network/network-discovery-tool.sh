#!/usr/bin/env bash
# NETWORK DISCOVERY TOOL (NDT) - Version 5.6
set -u

# --- CONFIGURATION ---
REPO_URL="https://github.com/abhiprab/repo-public.git"
REPO_SUBDIR="scripts/network"
TARGET_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${TARGET_DIR}/out"
UDEV_ROOT="${OUT_DIR}/udev_rules"
BACKUP_DIR="${TARGET_DIR}/backup"

MAPPING_SCRIPT="nic-mapping-univ.sh"
COLLECT_SCRIPT="nic-mapping-univ-all-nodes.sh"
GEN_RULES_SCRIPT="generate-udev-rules.sh"

REQUIRED_FILES=("$MAPPING_SCRIPT" "$COLLECT_SCRIPT" "$GEN_RULES_SCRIPT")
SSH_USER="root"

# --- UI COLORS ---
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export RED='\033[0;31m'
export NC='\033[0m'

# --- 1. SYNC ENVIRONMENT (Git Restoration) ---
sync_env() {
    echo -e "${BLUE}[INFO] Initializing NDT Environment...${NC}"
    # Ensure root target directory exists and is owned by current user
    [ ! -d "$TARGET_DIR" ] && sudo mkdir -p "$TARGET_DIR" && sudo chown $USER:$USER "$TARGET_DIR"
    mkdir -p "$OUT_DIR" "$BACKUP_DIR" "$UDEV_ROOT" "$OUT_DIR/tmp_raw"

    echo -e "${YELLOW}[INFO] Syncing NDT components from GitHub...${NC}"
    TMP_CLONE=$(mktemp -d)
    
    # Clone logic to pull fresh scripts
    if git clone --depth 1 "$REPO_URL" "$TMP_CLONE" --quiet; then
        for file in "${REQUIRED_FILES[@]}"; do
            if [ -f "${TMP_CLONE}/${REPO_SUBDIR}/${file}" ]; then
                cp -f "${TMP_CLONE}/${REPO_SUBDIR}/${file}" "$TARGET_DIR/"
                chmod +x "${TARGET_DIR}/${file}"
                echo -e "  ${GREEN}++ Verified:${NC} $file"
            fi
        done
        rm -rf "$TMP_CLONE"
        echo -e "${GREEN}[SUCCESS] NDT Environment Synchronized.${NC}"
    else
        echo -e "${RED}[ERROR] GitHub Sync Failed. Check connectivity or SSH keys.${NC}"
        exit 1
    fi
}

# --- 2. CORE LOGIC (Rules & Discovery) ---
do_rule_gen() {
    local ts=$(date +%F-%H%M%S)
    local master_csv="${OUT_DIR}/manual_inventory.csv"
    local current_udev_run="${UDEV_ROOT}/${ts}"

    echo -e "\n${BLUE}==============================================================${NC}"
    echo -e "${CYAN}[$(date +%T)] NDT: Starting Cluster-Wide Discovery...${NC}"

    # Step A: Run Orchestrator (Orchestrator handles the "Total Sweep" of tmp_raw)
    "${TARGET_DIR}/${COLLECT_SCRIPT}"

    # Step B: Validate CSV result
    if [ ! -s "$master_csv" ] || [ $(wc -l < "$master_csv") -le 1 ]; then
        echo -e "${RED}[ERROR] Inventory captured no data. Rule generation aborted.${NC}"
        return 1
    fi

    mkdir -p "$current_udev_run"
    echo -e "${CYAN}[$(date +%T)] NDT: Generating Rules...${NC}"

    # Step C: Execute Rule Engine (Auto-detect Python vs Bash)
    if grep -q "import " "${TARGET_DIR}/${GEN_RULES_SCRIPT}"; then
        python3 "${TARGET_DIR}/${GEN_RULES_SCRIPT}" "$master_csv" "$current_udev_run"
    else
        bash "${TARGET_DIR}/${GEN_RULES_SCRIPT}" "$master_csv" "$current_udev_run"
    fi

    # Step D: Finalize Rules
    if ls "$current_udev_run"/*.rules >/dev/null 2>&1; then
        ln -sfn "$current_udev_run" "${UDEV_ROOT}/latest"
        echo -e "${GREEN}[SUCCESS] Rules generated in: $current_udev_run${NC}"
    else
        echo -e "${RED}[ERROR] Rule engine failed to produce .rules files.${NC}"
        return 1
    fi
    echo -e "${BLUE}==============================================================${NC}\n"
}

# --- 3. MAIN MENU ---
sync_env 

while true; do
    echo -e "\n${YELLOW}--- NETWORK DISCOVERY TOOL (NDT) ---${NC}"
    echo -e "1. Generate Local Host Network Inventory"
    echo -e "2. Generate Cluster Wide Network Inventory (Individual + Merged)"
    echo -e "3. Generate UDEV Rules"
    echo -e "4. Generate Inventory and Deploy UDEV Rules Cluster Wide"
    echo -e "q. Exit"
    
    read -p "Option: " opt
    case "${opt:-}" in
        1) 
            sudo "${TARGET_DIR}/${MAPPING_SCRIPT}" --print 
            read -p "Press Enter..." ;;
        2) 
            "${TARGET_DIR}/${COLLECT_SCRIPT}" 
            read -p "Press Enter..." ;;
        3) 
            do_rule_gen 
            read -p "Press Enter..." ;;
        4) 
            do_rule_gen && {
                echo -e "${YELLOW}[NDT] Deploying rules to cluster...${NC}"
                for rule in "${UDEV_ROOT}/latest"/*.rules; do
                    host=$(basename "$rule" | sed -e 's/_nics.rules//' -e 's/.rules//')
                    echo -e "${BLUE}>>> $host...${NC}"
                    scp -q "$rule" "${SSH_USER}@${host}:/etc/udev/rules.d/80-cluster-nics.rules"
                    ssh "${SSH_USER}@${host}" "sudo udevadm control --reload-rules && sudo udevadm trigger"
                done
                echo -e "${GREEN}[SUCCESS] Deployment complete.${NC}"
            } ; read -p "Press Enter..." ;;
        q) 
            echo -e "${BLUE}Exiting NDT Session.${NC}"
            exit 0 ;;
        *) 
            echo -e "${RED}Invalid selection.${NC}" ; sleep 1 ;;
    esac
done
