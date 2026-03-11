#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh - Version 5.9
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

# --- 1. INTERACTIVE NODE SELECTION WITH STATUS ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"

# Capture raw kubectl output for display
# Columns: NAME, STATUS, ROLES, VERSION
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)

# Extract just the names into an array for logic
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

if [[ ${#ALL_NODES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No worker nodes found via kubectl.${NC}"
    exit 1
fi

echo -e "\n${CYAN}Cluster Worker Node Status:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"
echo "$RAW_NODES"
echo -e "${BLUE}-----------------------------------------------------------------------${NC}"

echo -e "${YELLOW}Select Nodes for Inventory Scan:${NC}"
for i in "${!ALL_NODES[@]}"; do
    # Check if the node is Ready to provide a hint
    node_status=$(echo "$RAW_NODES" | grep "^${ALL_NODES[$i]} " | awk '{print $2}')
    
    status_hint=""
    if [[ "$node_status" == "Ready" ]]; then
        status_hint="${GREEN}(Ready for Scan)${NC}"
    else
        status_hint="${RED}($node_status)${NC}"
    fi

    printf "%2d) %-20s %b\n" "$((i+1))" "${ALL_NODES[$i]}" "$status_hint"
done
echo -e " a) ALL Worker Nodes"
echo -e " q) Quit"

echo -e "\n${CYAN}Selection (e.g., 1,2 or 'a'):${NC}"
read -p ">> " node_choice

# --- 2. SELECTION PROCESSING ---
SELECTED_NODES=()
if [[ "$node_choice" == "a" ]]; then
    SELECTED_NODES=("${ALL_NODES[@]}")
elif [[ "$node_choice" == "q" || -z "$node_choice" ]]; then
    echo -e "${BLUE}Exiting.${NC}"
    exit 0
else
    IFS=',' read -ra ADDR <<< "$node_choice"
    for idx in "${ADDR[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#ALL_NODES[@]}" ] && [ "$idx" -gt 0 ]; then
            SELECTED_NODES+=("${ALL_NODES[$((idx-1))]}")
        fi
    done
fi

if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No valid nodes selected.${NC}"
    exit 1
fi

# --- 3. PARALLEL SSH DISCOVERY ---
run_node() {
    local node="$1"
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    echo -e "${BLUE}[INFO]${NC} (${node}) capturing via SSH..."

    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node" \
        "sudo -n $SCRIPT_ON_NODE --csv --print" > "$node_csv" 2>/dev/null; then
        
        sed -i 's/\r//g' "$node_csv"
        if [[ -s "$node_csv" ]] && head -n 1 "$node_csv" | grep -q '^HOSTNAME,'; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) data received."
        else
            echo -e "${RED}[ERROR]${NC} (${node}) received empty/corrupt data."
            rm -f "$node_csv"
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) SSH connection failed."
        rm -f "$node_csv"
    fi
}

export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DATE_STR

printf "%s\n" "${SELECTED_NODES[@]}" | xargs -I{} -P 8 bash -c 'run_node "{}"'

# --- 4. MERGE ---
# (Existing merge logic follows)
