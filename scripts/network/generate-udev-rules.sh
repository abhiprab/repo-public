#!/usr/bin/env bash
# generate-udev-rules.sh - Version 1.8
# Hard-gate: Aborts with standardized UI error if inventory is missing.

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out/udev_rules/latest"
INPUT_CSV="${BASE_DIR}/out/manual_inventory.csv"
PYTHON_GEN="${BASE_DIR}/generate-udev-rules.py"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$OUT_DIR"

# --- 1. PRE-FLIGHT CHECK (MATCHING BAKE SCRIPT UI) ---
if [[ ! -f "$INPUT_CSV" ]]; then
    echo -e "${RED}[ERROR] Inventory database is missing!${NC}"
    echo -e "${YELLOW}Path:${NC} $INPUT_CSV"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC}"
    echo -e "You must perform an initial hardware scan first."
    echo -e "Please go back to the Main Menu and choose ${CYAN}Option 2 (Inventory Scan)${NC}."
    echo -e "----------------------------------------------------------------------------"
    exit 1
fi

# --- 2. NODE STATUS QUERY ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

# Check if ANY of these nodes exist in the CSV for a second-level hard gate
FOUND_ANY=0
for node in "${ALL_NODES[@]}"; do
    if grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
        FOUND_ANY=1
        break
    fi
done

if [[ $FOUND_ANY -eq 0 ]]; then
    echo -e "${RED}[ERROR] No inventory data found for any active worker nodes!${NC}"
    echo -e "${YELLOW}Path:${NC} $INPUT_CSV"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC}"
    echo -e "The inventory file exists but contains no data for these nodes."
    echo -e "Please go back to the Main Menu and choose ${CYAN}Option 2 (Inventory Scan)${NC}."
    echo -e "----------------------------------------------------------------------------"
    exit 1
fi

# --- 3. SELECTION MENU (If data exists) ---
echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

echo -e "${YELLOW}Select Nodes for Rule Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    inv_hint=$(grep -q "^${node}," "$INPUT_CSV" && echo -e "${GREEN}(In Inventory)${NC}" || echo -e "${RED}(Missing Data)${NC}")
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data"
echo -e " q) Quit"

read -p ">> Selection: " choice

# ... (Rest of processing logic) ...
