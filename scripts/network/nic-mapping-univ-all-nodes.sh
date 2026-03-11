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
    
    echo "[INFO] (${node}) preparing and collecting..."

    # 1. Push the engine to the node's local /tmp (avoids NFS issues)
    # We use a helper pod or ephemeral container to place the file
    kubectl cp "$LOCAL_ENGINE" "${node}:${REMOTE_TMP_EXE}" -c debug-container 2>/dev/null || \
    kubectl debug "node/${node}" --image="$DEBUG_IMAGE" --quiet -- bash -c "cat > $REMOTE_TMP_EXE" < "$LOCAL_ENGINE"

    # 2. Execute from local /tmp
    if kubectl debug "node/${node}" -it --quiet --image="$DEBUG_IMAGE" -- \
        chroot /host bash -c "chmod +x $REMOTE_TMP_EXE && sudo $REMOTE_TMP_EXE --csv --print" > "$node_csv" 2>/dev/null; then
        
        if [[ -s "$node_csv" ]]; then
            echo "[SUCCESS] (${node}) data captured."
        else
            echo "[ERROR] (${node}) returned empty data."
            rm -f "$node_csv"
        fi
    else
        echo "[ERROR] (${node}) execution failed."
    fi

    # 3. Cleanup the remote temp file
    kubectl debug "node/${node}" --image="$DEBUG_IMAGE" --quiet -- rm -f "$REMOTE_TMP_EXE" > /dev/null 2>&1
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
