#!/usr/bin/env bash
# generate-udev-rules.sh - Version 1.9
# Hard-gate: Aborts with standardized UI error if inventory is missing.
# Includes Post-Generation file summary.

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
    echo -e "${RED}[ERROR] Inventory data is missing!${NC}"
    echo -e "${YELLOW}Path:${NC} $INPUT_CSV"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC}"
    echo -e "You must perform an initial inventory scan first."
    echo -e "Please go back to the Main Menu and choose ${CYAN}Option 2 (Inventory Scan)${NC}."
    echo -e "----------------------------------------------------------------------------"
    exit 1
fi

# --- 2. NODE STATUS QUERY & VALIDATION ---
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

# --- 3. SELECTION MENU ---
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

# --- 4. SELECTION PROCESSING ---
SELECTED_NODES=()
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
            echo -e "${RED}[ERROR]${NC} Node '$node' is missing inventory data. Run Option 2 first."
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
    if python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"; then
        
        # --- FINALIZATION SUMMARY ---
        echo -e "\n${BLUE}==============================================================${NC}"
        echo -e "${GREEN}[SUCCESS] UDEV Rules Generated Successfully!${NC}"
        echo -e "${BLUE}==============================================================${NC}"
        
        echo -e "${YELLOW}Generated Files & Paths:${NC}"
        echo -e "  ${CYAN}Directory :${NC} $OUT_DIR"
        echo -e "  ${CYAN}Rules List:${NC}"
        
        # List the actual .rules files generated
        shopt -s nullglob
        for rule in "$OUT_DIR"/*.rules; do
            echo -e "    - $(basename "$rule")"
        done

        RULE_COUNT=$(ls -1 "$OUT_DIR"/*.rules 2>/dev/null | wc -l)
        echo -e "\n${CYAN}Summary:${NC}"
        echo -e "--------------------------------------------------------------"
        echo -e "  Total Rule Files: ${GREEN}${RULE_COUNT}${NC}"
        echo -e "  Master Mapping  : ${CYAN}filtered_selection.csv${NC}"
        echo -e "--------------------------------------------------------------"

        echo -e "\n${YELLOW}[NEXT STEP]${NC} You can now proceed to ${CYAN}Option 4${NC} to Deploy or ${CYAN}Option 5/6${NC} to Bake."
        echo -e "${BLUE}==============================================================${NC}"
    else
        echo -e "${RED}[ERROR] Python rule generator failed.${NC}"
    fi
else
    echo -e "${RED}[EXIT] No nodes selected.${NC}"
fi
