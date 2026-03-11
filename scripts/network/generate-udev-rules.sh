#!/usr/bin/env bash
# generate-udev-rules-interactive.sh
# Wraps Python generator with a consistent UI for node selection.

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

echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"

# 1. Capture raw kubectl output for display
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

if [[ ${#ALL_NODES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No worker nodes found via kubectl.${NC}"; exit 1
fi

# 2. Display Node Status Table
echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

# 3. Selection Menu
echo -e "${YELLOW}Select Nodes to Generate UDEV Rules for:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    node_status=$(echo "$RAW_NODES" | grep "^${node} " | awk '{print $2}')
    
    # Check if node exists in the CSV inventory
    inventory_hint=""
    if grep -q "^${node}," "$INPUT_CSV" 2>/dev/null; then
        inventory_hint="${GREEN}(In Inventory)${NC}"
    else
        inventory_hint="${RED}(Missing from Inventory)${NC}"
    fi

    status_hint=""
    [[ "$node_status" != "Ready" ]] && status_hint=" ${RED}[$node_status]${NC}"

    printf "%2d) %-20s %b %b\n" "$((i+1))" "$node" "$inventory_hint" "$status_hint"
done
echo -e " a) ALL Nodes in Inventory"
echo -e " q) Quit"

read -p ">> Selection: " choice

# 4. Process Selection
SELECTED_NODES=()
if [[ "$choice" == "a" ]]; then
    # Grab all node names that are actually in the CSV
    SELECTED_NODES=($(awk -F, 'NR>1 {print $1}' "$INPUT_CSV" | sort -u))
elif [[ "$choice" == "q" || -z "$choice" ]]; then
    exit 0
else
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#ALL_NODES[@]}" ]; then
            SELECTED_NODES+=("${ALL_NODES[$((idx-1))]}")
        fi
    done
fi

if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No nodes selected.${NC}"; exit 1
fi

# 5. Create a filtered CSV for Python to process
# This ensures Python only generates rules for the nodes you picked
FILTERED_CSV="${OUT_DIR}/filtered_selection.csv"
head -n 1 "$INPUT_CSV" > "$FILTERED_CSV"
for node in "${SELECTED_NODES[@]}"; do
    grep "^${node}," "$INPUT_CSV" >> "$FILTERED_CSV" || echo -e "${YELLOW}[WARN]${NC} Node $node has no inventory data."
done

# 6. Call your Python Script
echo -e "\n${BLUE}[INFO] Running Python UDEV Generator...${NC}"
python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"

echo -e "\n${GREEN}[SUCCESS] Interaction complete.${NC}"
