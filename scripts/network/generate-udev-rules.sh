#!/usr/bin/env bash
# generate-udev-rules.sh - Version 2.4
# Purpose: Generate NVIDIA-compliant UDEV rules (eth_rX_pY) locally.
# Logic: Aborts if inventory is missing; Sanitizes input to prevent "Missing Data" errors.

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out/udev_rules/latest"
INPUT_CSV="${BASE_DIR}/out/manual_inventory.csv"
PYTHON_GEN="${BASE_DIR}/generate-udev-rules.py"

# Colors
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

mkdir -p "$OUT_DIR"

# --- 1. PRE-FLIGHT CHECK ---
if [[ ! -f "$INPUT_CSV" ]]; then
    echo -e "${RED}[ERROR] Inventory database not found!${NC}"
    echo -e "${YELLOW}Path:${NC} $INPUT_CSV"
    echo -e "\n${BLUE}[ACTION REQUIRED]${NC} Please run Option 2 (Inventory Scan) first."
    echo -e "----------------------------------------------------------------------------"
    exit 1
fi

# --- 2. DEEP SANITIZATION ---
# This creates a temporary clean CSV (no quotes, no CR, no trailing spaces) 
# to ensure the 'grep' and the 'Python engine' match Kubernetes names exactly.
CLEAN_CSV="/tmp/ndt_inventory_clean.csv"
tr -d '\r"' < "$INPUT_CSV" | sed 's/[[:space:]]*//g' > "$CLEAN_CSV"

# --- 3. NODE STATUS QUERY ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

# --- 4. SELECTION MENU ---
echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

echo -e "${YELLOW}Select Nodes for NVIDIA Rule Generation (eth_rX_pY):${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    # Check against the CLEANED version of the database
    if grep -q "^${node}," "$CLEAN_CSV" 2>/dev/null; then
        inv_hint="${GREEN}(In Inventory)${NC}"
    else
        inv_hint="${RED}(Missing Data)${NC}"
    fi
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$inv_hint"
done
echo -e " a) ALL Nodes with Inventory Data"
echo -e " q) Quit"

read -p ">> Selection: " choice

# --- 5. PROCESSING SELECTION ---
SELECTED_NODES=()
if [[ "$choice" == "a" ]]; then
    for node in "${ALL_NODES[@]}"; do
        grep -q "^${node}," "$CLEAN_CSV" && SELECTED_NODES+=("$node")
    done
elif [[ "$choice" != "q" && -n "$choice" ]]; then
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        node="${ALL_NODES[$((idx-1))]}"
        if ! grep -q "^${node}," "$CLEAN_CSV" 2>/dev/null; then
            echo -e "${RED}[ERROR]${NC} Node '$node' has no inventory data. Aborting."
            exit 1
        fi
        SELECTED_NODES+=("$node")
    done
fi

# --- 6. EXECUTION (LOCAL GENERATION ONLY) ---
if [[ ${#SELECTED_NODES[@]} -gt 0 ]]; then
    # Prepare a specific filtered CSV for the Python Engine
    FILTERED_CSV="${OUT_DIR}/filtered_selection.csv"
    head -n 1 "$CLEAN_CSV" > "$FILTERED_CSV"
    for n in "${SELECTED_NODES[@]}"; do 
        grep "^${n}," "$CLEAN_CSV" >> "$FILTERED_CSV"
    done
    
    echo -e "\n${BLUE}[INFO] Running Rule Engine...${NC}"
    # Calls the Python script to handle the PCI sorting and naming logic
    if python3 "$PYTHON_GEN" "$FILTERED_CSV" "$OUT_DIR"; then
        
        echo -e "\n${BLUE}==============================================================${NC}"
        echo -e "${GREEN}[SUCCESS] NVIDIA Rules Generated Locally!${NC}"
        echo -e "${BLUE}==============================================================${NC}"
        
        echo -e "${YELLOW}Output Directory:${NC} $OUT_DIR"
        echo -e "${YELLOW}Files Created:${NC}"
        shopt -s nullglob
        for rule in "$OUT_DIR"/*.rules; do
            echo -e "  - $(basename "$rule")"
        done

        RULE_COUNT=$(ls -1 "$OUT_DIR"/*.rules 2>/dev/null | wc -l)
        echo -e "\n${CYAN}Summary:${NC}"
        echo -e "  Total Files Created : $RULE_COUNT"
        echo -e "  Naming Convention   : NVIDIA Spectrum-X (Rail/Plane)"
        echo -e "--------------------------------------------------------------"
        echo -e "${YELLOW}[INFO]${NC} Rules are ready. Use the Deployment or Baking scripts next."
        echo -e "${BLUE}==============================================================${NC}"
    else
        echo -e "${RED}[ERROR] Python engine failed. Please check $PYTHON_GEN${NC}"
    fi
else
    echo -e "${RED}[EXIT] No valid nodes selected.${NC}"
fi

# Cleanup temp files
rm -f "$CLEAN_CSV"
