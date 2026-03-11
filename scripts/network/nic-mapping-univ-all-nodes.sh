#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh - Version 5.8 (Interactive Node Selection)
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

# --- 1. INTERACTIVE NODE SELECTION ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker nodes...${NC}"
mapfile -t ALL_NODES < <(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

if [[ ${#ALL_NODES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No worker nodes found via kubectl.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Available Worker Nodes:${NC}"
echo -e "---------------------------------------"
for i in "${!ALL_NODES[@]}"; do
    printf "%2d) %s\n" "$((i+1))" "${ALL_NODES[$i]}"
done
echo -e "---------------------------------------"
echo -e " a) ALL Worker Nodes"
echo -e " q) Quit"

echo -e "\n${CYAN}Select nodes to scan (e.g., 1,2,5 or 'a'):${NC}"
read -p ">> " node_choice

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

# --- 2. SSH CAPTURE LOGIC ---
run_node() {
    local node="$1"
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    local node_err="${TEMP_DIR}/${node}-${DATE_STR}.err"

    echo -e "${BLUE}[INFO]${NC} (${node}) capturing via SSH..."

    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node" \
        "sudo -n $SCRIPT_ON_NODE --csv --print" > "$node_csv" 2>"$node_err"; then

        sed -i 's/\r//g' "$node_csv"

        if [[ -s "$node_csv" ]] && head -n 1 "$node_csv" | grep -q '^HOSTNAME,IFACE,FUNC,'; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) captured."
            rm -f "$node_err"
        else
            echo -e "${RED}[ERROR]${NC} (${node}) invalid output."
            rm -f "$node_csv"
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) SSH/Sudo failed."
        rm -f "$node_csv"
    fi
}

export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DATE_STR

# Run selection in parallel
printf "%s\n" "${SELECTED_NODES[@]}" | xargs -I{} -P 8 bash -c 'run_node "{}"'

# --- 3. MERGE ---
echo -e "\n${BLUE}[INFO] Finalizing merge into $OUT_FILE...${NC}"
shopt -s nullglob
files=( "$TEMP_DIR"/*"${DATE_STR}".csv )

if [[ ${#files[@]} -gt 0 ]]; then
    head -n 1 "${files[0]}" > "$OUT_FILE"
    for f in "${files[@]}"; do
        tail -n +2 "$f" >> "$OUT_FILE"
    done
    echo -e "${GREEN}[OK] Merged ${#files[@]} selected nodes into $OUT_FILE${NC}"
else
    echo -e "${RED}[ERROR] No data collected.${NC}"
    exit 1
fi
