#!/usr/bin/env bash
# generate-udev-rules-interactive.sh - Version 1.1
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

echo -e "${BLUE}[INFO] Querying Kubernetes Node Status...${NC}"
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

echo -e "${YELLOW}Select Nodes for Rule Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    inv_hint=$([[ -f "$INPUT_CSV" ]] && grep -q "^${node}," "$INPUT_CSV" && echo -e "${GREEN}(In Inventory)${NC}" || echo -e "${RED}(Missing Data)${NC}")
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data\n q) Quit"
read -p ">> " choice

SELECTED_NODES=()
if [[ "$choice" == "a" ]]; then
    for node in "${ALL_NODES[@]}"; do
        [[ -f "$INPUT_CSV" ]] && grep -q "^${node}," "$INPUT_CSV" && SELECTED_NODES+=("$node")
    done
elif [[ "$choice" != "q" ]]; then
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        node="${ALL_NODES[$((idx-1))]}"
        
        # --- MISSING DATA AUTO-FIX ---
        if ! grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
            echo -e "${YELLOW}[WARN]${NC} $node is missing data."
            read -p "Run Quick Scan for $node now? (y/n): " do_scan
            if [[ "$do_scan" == "y" ]]; then
                bash "$COLLECTOR_SCRIPT" "$node"
            fi
        fi
        
        # Verify again after potential scan
        grep -q "^${node}," "$INPUT_CSV" 2>/dev/null && SELECTED_NODES+=("$node")
    done
fi

if [[ ${#SELECTED_NODES[@]} -gt 0 ]]; then
    # Filter CSV and run Python
    FILTERED_CSV="${OUT_DIR}/filtered_selection.csv"
    head -n 1 "$INPUT_CSV" > "$FILTERED_CSV"
    for n in "${SELECTED_NODES[@]}"; do grep "^${n}," "$INPUT_CSV" >> "$FILTERED_CSV"; done
    
    python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"
    echo -e "${GREEN}[SUCCESS] Rules generated.${NC}"
else
    echo -e "${RED}[EXIT] No nodes with data selected.${NC}"
fi
