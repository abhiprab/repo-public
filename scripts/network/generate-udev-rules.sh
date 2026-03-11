#!/usr/bin/env bash
# generate-udev-rules.sh - Version 1.5
# Includes Pre-Flight check to ensure inventory exists before generation.

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out/udev_rules/latest"
INPUT_CSV="${BASE_DIR}/out/manual_inventory.csv"
PYTHON_GEN="${BASE_DIR}/generate-udev-rules.py"
COLLECTOR_SCRIPT="${BASE_DIR}/nic-mapping-univ-all-nodes.sh"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$OUT_DIR"

# --- 1. PRE-FLIGHT CHECK ---
# If the inventory file doesn't exist, we can't generate any rules.
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

echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

# --- 3. SELECTION MENU ---
echo -e "${YELLOW}Select Nodes for Rule Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    inv_hint=$(grep -q "^${node}," "$INPUT_CSV" && echo -e "${GREEN}(In Inventory)${NC}" || echo -e "${RED}(Missing Data)${NC}")
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data"
echo -e " q) Quit"

echo -e "\n${YELLOW}[NOTE]${NC} Nodes marked as ${RED}(Missing Data)${NC} will trigger a quick hardware scan"
echo -e "       to build inventory before rules are generated."

read -p ">> Selection: " choice

SELECTED_NODES=()

# --- 4. PROCESSING ---
if [[ "$choice" == "a" ]]; then
    for node in "${ALL_NODES[@]}"; do
        grep -q "^${node}," "$INPUT_CSV" && SELECTED_NODES+=("$node")
    done
elif [[ "$choice" != "q" && -n "$choice" ]]; then
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        node="${ALL_NODES[$((idx-1))]}"
        
        if ! grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
            echo -e "${YELLOW}[WARN]${NC} $node has no inventory data. Initiating scan..."
            bash "$COLLECTOR_SCRIPT" "$node"
        fi
        
        grep -q "^${node}," "$INPUT_CSV" 2>/dev/null && SELECTED_NODES+=("$node")
    done
fi

# --- 5. EXECUTION ---
if [[ ${#SELECTED_NODES[@]} -gt 0 ]]; then
    FILTERED_CSV="${OUT_DIR}/filtered_selection.csv"
    head -n 1 "$INPUT_CSV" > "$FILTERED_CSV"
    for n in "${SELECTED_NODES[@]}"; do 
        grep "^${n}," "$INPUT_CSV" >> "$FILTERED_CSV"
    done
    
    echo -e "\n${BLUE}[INFO] Generating rules for selected nodes...${NC}"
    python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"
    echo -e "${GREEN}[SUCCESS] UDEV rules generated in $OUT_DIR${NC}"
else
    echo -e "${RED}[EXIT] No nodes with data selected.${NC}"
fi
