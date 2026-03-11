#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh
set -euo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
OUT_FILE="${OUT_DIR}/nic-inventory-merged-${DATE_STR}.csv"
PARALLEL=8
TEMP_DIR="${OUT_DIR}/tmp_raw"
# Local path on jumpbox to the engine
LOCAL_ENGINE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
# Temporary path on the worker node
REMOTE_TMP_EXE="/tmp/nic-mapping-univ.sh"
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

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
    
    echo "[INFO] (${node}) streaming discovery script..."

    # 1. We pipe the local script into 'bash -s'
    # 2. We skip chmod because we are executing the stream directly
    # 3. We ensure the output only contains the CSV data
    if kubectl debug "node/${node}" -it --quiet --image="$DEBUG_IMAGE" --profile=general -- \
        chroot /host bash -s -- --csv --print < "$LOCAL_ENGINE" > "$node_csv" 2>/dev/null; then
        
        # 4. VALIDATION: Check if the first line is actually a CSV header
        if head -n 1 "$node_csv" | grep -q "HOSTNAME"; then
            echo "[SUCCESS] (${node}) data captured."
        else
            echo "[ERROR] (${node}) captured error instead of data. Check node sudoers."
            rm -f "$node_csv"
        fi
    else
        echo "[ERROR] (${node}) connection failed."
    fi
}

export -f run_node
export TEMP_DIR LOCAL_ENGINE REMOTE_TMP_EXE DEBUG_IMAGE DATE_STR

echo "$NODES" | tr ' ' '\n' | xargs -I {} -P "$PARALLEL" bash -c 'run_node "{}"'

# --- PHASE 2: MERGE DATA (Same logic as before) ---
echo "[INFO] Merging results into $OUT_FILE..."
shopt -s nullglob
FILES=("$TEMP_DIR"/*-"$DATE_STR".csv)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "ERROR: No data captured. Check kubectl permissions." >&2
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

echo "[OK] Merged inventory: $OUT_FILE"
