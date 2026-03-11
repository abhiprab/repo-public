#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh
set -euo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
OUT_FILE="${OUT_DIR}/nic-inventory-merged-${DATE_STR}.csv"
PARALLEL=8
TEMP_DIR="${OUT_DIR}/tmp_raw"
LOCAL_ENGINE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

# Colors for xargs subshell
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export NC='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_FILE="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        *) shift 1 ;;
    esac
done

mkdir -p "$TEMP_DIR"

# --- PHASE 1: COLLECT DATA ---
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

run_node() {
    local node=$1
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    local host_path="/usr/local/bin/ndt-engine.sh"

    echo -e "${BLUE}[INFO]${NC} (${node}) capturing data..."

    # 1. Use -i (interactive stdin) but NO -t (no TTY)
    # 2. Redirect the script into the pod
    # 3. Use 'cat' to capture the output explicitly
    if kubectl debug "node/${node}" -i --quiet --image="$DEBUG_IMAGE" --profile=general -- \
        chroot /host bash -c "cat > $host_path && chmod +x $host_path && $host_path --csv --print && rm -f $host_path" < "$LOCAL_ENGINE" > "$node_csv" 2>/dev/null; then

        if grep -q "HOSTNAME" "$node_csv"; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) data captured."
        else
            # Debug: what did we get?
            echo -e "${RED}[ERROR]${NC} (${node}) no CSV data in output."
            rm -f "$node_csv"
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) connection failed."
    fi
}

export -f run_node
export TEMP_DIR LOCAL_ENGINE DEBUG_IMAGE DATE_STR

echo "$NODES" | tr ' ' '\n' | xargs -I {} -P "$PARALLEL" bash -c 'run_node "{}"'

# --- PHASE 2: MERGE DATA ---
echo -e "${BLUE}[INFO] Merging results into $OUT_FILE...${NC}"
shopt -s nullglob
FILES=("$TEMP_DIR"/*-"$DATE_STR".csv)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${RED}ERROR: No data captured. Check kubectl permissions.${NC}" >&2
    exit 1
fi

head -n 1 "${FILES[0]}" > "$OUT_FILE"
for f in "${FILES[@]}"; do
    tail -n +2 "$f" >> "$OUT_FILE"
done

# Organize
NODE_OUT_DIR="${OUT_DIR}/node_reports/${DATE_STR}"
mkdir -p "$NODE_OUT_DIR"
mv "$TEMP_DIR"/*-"$DATE_STR".csv "$NODE_OUT_DIR/"

echo -e "${GREEN}[OK] Merged inventory: $OUT_FILE${NC}"
