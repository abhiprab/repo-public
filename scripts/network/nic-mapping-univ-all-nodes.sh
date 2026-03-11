#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh - Version 6.0
set -uo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out"
TEMP_DIR="${OUT_DIR}/tmp_raw"
SCRIPT_ON_NODE="${BASE_DIR}/nic-mapping-univ.sh"
OUT_FILE="${OUT_DIR}/manual_inventory.csv"

# Colors
export BLUE='\033[0;34m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export RED='\033[0;31m'
export NC='\033[0m'

mkdir -p "$TEMP_DIR"

# --- ARGUMENT OR INTERACTIVE SELECTION ---
SELECTED_NODES=()

if [[ $# -eq 1 ]]; then
    # Direct mode: Scan the single node passed as an argument
    SELECTED_NODES=("$1")
    echo -e "${BLUE}[INFO] Quick Scan initiated for node: $1${NC}"
else
    # Interactive mode: Show the status table
    echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"
    RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
    mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

    echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
    echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
    echo "$RAW_NODES"
    echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

    echo -e "${YELLOW}Select Nodes for Inventory Scan:${NC}"
    for i in "${!ALL_NODES[@]}"; do
        node_status=$(echo "$RAW_NODES" | grep "^${ALL_NODES[$i]} " | awk '{print $2}')
        hint=$([[ "$node_status" == "Ready" ]] && echo -e "${GREEN}(Ready)${NC}" || echo -e "${RED}($node_status)${NC}")
        printf "%2d) %-20s %b\n" "$((i+1))" "${ALL_NODES[$i]}" "$hint"
    done
    echo -e " a) ALL Worker Nodes\n q) Quit"
    read -p ">> Selection: " choice

    if [[ "$choice" == "a" ]]; then SELECTED_NODES=("${ALL_NODES[@]}")
    elif [[ "$choice" == "q" || -z "$choice" ]]; then exit 0
    else
        IFS=',' read -ra ADDR <<< "$choice"
        for idx in "${ADDR[@]}"; do
            idx=$(echo "$idx" | tr -d ' ')
            [[ "$idx" =~ ^[0-9]+$ ]] && SELECTED_NODES+=("${ALL_NODES[$((idx-1))]}")
        done
    fi
fi

# --- SCANNING LOGIC ---
run_node() {
    local node="$1"
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node" \
        "sudo -n $SCRIPT_ON_NODE --csv --print" > "$node_csv" 2>/dev/null; then
        sed -i 's/\r//g' "$node_csv"
        echo -e "${GREEN}[SUCCESS]${NC} ($node) Captured."
    else
        echo -e "${RED}[ERROR]${NC} ($node) Failed."
        rm -f "$node_csv"
    fi
}
export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DATE_STR

printf "%s\n" "${SELECTED_NODES[@]}" | xargs -I{} -P 8 bash -c 'run_node "{}"'

# --- MERGE (Smart Merge: If single node, update existing CSV; if all, overwrite) ---
echo -e "\n${BLUE}[INFO] Finalizing Inventory...${NC}"
shopt -s nullglob
files=( "$TEMP_DIR"/*"${DATE_STR}".csv )

if [[ ${#files[@]} -gt 0 ]]; then
    if [[ ! -f "$OUT_FILE" ]]; then
        head -n 1 "${files[0]}" > "$OUT_FILE"
    fi
    for f in "${files[@]}"; do
        node_name=$(basename "$f" | cut -d'-' -f1-3)
        # Remove old entry for this node if it exists to prevent duplicates
        sed -i "/^$node_name,/d" "$OUT_FILE"
        tail -n +2 "$f" >> "$OUT_FILE"
    done
    echo -e "${GREEN}[OK] Inventory Updated.${NC}"
else
    echo -e "${RED}[ERROR] No data collected.${NC}"
fi
