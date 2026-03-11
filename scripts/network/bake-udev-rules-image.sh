#!/usr/bin/env bash
# generate-udev-rules.sh - Version 1.3
# Interactive Rule Generator with consistent worker node status header.

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

# Consistent Header with the Collector Script
echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"

# 1. Capture raw kubectl output
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

# 2. SELECTION MENU
echo -e "${YELLOW}Select Nodes for Rule Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    # Check inventory status for the hint
    inv_hint=$([[ -f "$INPUT_CSV" ]] && grep -q "^${node}," "$INPUT_CSV" && echo -e "${GREEN}(In Inventory)${NC}" || echo -e "${RED}(Missing Data)${NC}")
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data"
echo -e " q) Quit"

read -p ">> Selection: " choice

SELECTED_NODES=()

# 3. PROCESSING SELECTION
if [[ "$choice" == "a" ]]; then
    for node in "${ALL_NODES[@]}"; do
        [[ -f "$INPUT_CSV" ]] && grep -q "^${node}," "$INPUT_CSV" && SELECTED_NODES+=("$node")
    done
elif [[ "$choice" != "q" && -n "$choice" ]]; then
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        node="${ALL_NODES[$((idx-1))]}"
        
        # Check for missing data and offer Quick Scan
        if ! grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
            echo -e "${YELLOW}[WARN]${NC} $node has no inventory data."
            read -p "Would you like to run a Quick Scan for $node now? (y/n): " do_scan
            if [[ "$do_scan" == "y" ]]; then
                bash "$COLLECTOR_SCRIPT" "$node"
            fi
        fi
        
        # Re-verify after potential scan and add to list
        grep -q "^${node}," "$INPUT_CSV" 2>/dev/null && SELECTED_NODES+=("$node")
    done
fi

# 4. EXECUTION
if [[ ${#SELECTED_NODES[@]} -gt 0 ]]; then
    # Prepare a clean filtered CSV for the Python script
    FILTERED_CSV="${OUT_DIR}/filtered_selection.csv"
    head -n 1 "$INPUT_CSV" > "$FILTERED_CSV"
    for n in "${SELECTED_NODES[@]}"; do 
        grep "^${n}," "$INPUT_CSV" >> "$FILTERED_CSV"
    done
    
    echo -e "\n${BLUE}[INFO] Generating rules for:${NC} ${SELECTED_NODES[*]}"
    python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"
    echo -e "${GREEN}[SUCCESS] UDEV rules generated in $OUT_DIR${NC}"
else
    echo -e "${RED}[EXIT] No nodes with data selected. Rules were not updated.${NC}"
fi
