#!/usr/bin/env bash
# generate-udev-rules.sh - Version 1.6
# Hard-gate enforcement: No rules can be generated without existing inventory.

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

# --- 1. PRE-FLIGHT CHECK (FILE LEVEL) ---
if [[ ! -f "$INPUT_CSV" ]]; then
    echo -e "${RED}[ERROR] Inventory database is missing!${NC}"
    echo -e "${YELLOW}Path:${NC} $INPUT_CSV"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC}"
    echo -e "You must perform a hardware scan first."
    echo -e "Go back to the Main Menu and choose ${CYAN}Option 2 (Inventory Scan)${NC}."
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
    # Check if node exists in the CSV
    if grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
        inv_hint="${GREEN}(In Inventory)${NC}"
    else
        inv_hint="${RED}(Missing Data)${NC}"
    fi
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data"
echo -e " q) Quit"

read -p ">> Selection: " choice

# --- 4. PROCESSING WITH HARD ERROR ---
SELECTED_NODES=()
if [[ "$choice" == "a" ]]; then
    for node in "${ALL_NODES[@]}"; do
        if grep -q "^${node}," "$INPUT_CSV"; then
            SELECTED_NODES+=("$node")
        fi
    done
elif [[ "$choice" != "q" && -n "$choice" ]]; then
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        node="${ALL_NODES[$((idx-1))]}"
        
        # --- THE HARD GATE ---
        if ! grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
            echo -e "\n${RED}[ERROR] Node '$node' has no inventory data!${NC}"
            echo -e "${YELLOW}[ACTION]${NC} You must scan this node using ${CYAN}Option 2${NC} before generating rules."
            echo -e "----------------------------------------------------------------------------"
            exit 1
        fi
        SELECTED_NODES+=("$node")
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
    echo -e "${RED}[EXIT] No nodes selected.${NC}"
fi
