#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh
set -euo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
OUT_FILE="${OUT_DIR}/nic-inventory-merged-${DATE_STR}.csv"
PARALLEL=8
TEMP_DIR="${OUT_DIR}/tmp_raw"
# The path as seen by the worker nodes
SHARED_ENGINE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"

export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export NC='\033[0m'

mkdir -p "$TEMP_DIR"

# Get worker nodes
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

run_node() {
    local node=$1
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    # This is the path as seen by the worker node's host OS
    local host_script="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"

    echo -e "${BLUE}[INFO]${NC} (${node}) executing via K8s host path..."

    # 1. We use --profile=general to get host access
    # 2. We chroot into /host so the script sees the real NICs
    # 3. We run the script directly from the shared mount
    if kubectl debug "node/${node}" --quiet --image="$DEBUG_IMAGE" --profile=general -- \
        chroot /host /bin/bash "$host_script" --csv --print > "$node_csv" 2>/dev/null; then

        if grep -q "HOSTNAME" "$node_csv"; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) data captured."
        else
            echo -e "${RED}[ERROR]${NC} (${node}) captured invalid data. Check if mount exists on node."
            rm -f "$node_csv"
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) kubectl debug failed for this node."
    fi
}

export -f run_node
export TEMP_DIR SHARED_ENGINE DATE_STR

echo "$NODES" | tr ' ' '\n' | xargs -I {} -P "$PARALLEL" bash -c 'run_node "{}"'

# --- MERGE LOGIC ---
echo -e "${BLUE}[INFO] Merging results into $OUT_FILE...${NC}"
shopt -s nullglob
FILES=("$TEMP_DIR"/*-"$DATE_STR".csv)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${RED}ERROR: No data captured. Is the script executable on the nodes?${NC}" >&2
    exit 1
fi

head -n 1 "${FILES[0]}" > "$OUT_FILE"
for f in "${FILES[@]}"; do
    tail -n +2 "$f" >> "$OUT_FILE"
done

echo -e "${GREEN}[OK] Merged inventory: $OUT_FILE${NC}"
