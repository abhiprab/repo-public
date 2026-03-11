#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh
set -euo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
OUT_FILE="${OUT_DIR}/nic-inventory-merged-${DATE_STR}.csv"
PARALLEL=8
TEMP_DIR="${OUT_DIR}/tmp_raw"
ENGINE_PATH="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

# Parse Args
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
    
    # We use a subshell to capture the output of the debug pod
    # and write it directly from the master node to ensure the file is created.
    echo "[INFO] (${node}) starting collection..."

    # Execute and capture the STDOUT from the debug pod directly to our local disk
    # This bypasses the need for the node to have write access to the shared folder
    if kubectl debug "node/${node}" -it --quiet --image="$DEBUG_IMAGE" -- \
        chroot /host bash -c "sudo $ENGINE_PATH --csv --print" > "$node_csv" 2>/dev/null; then
        
        if [[ -s "$node_csv" ]]; then
            echo "[SUCCESS] (${node}) data captured."
        else
            echo "[ERROR] (${node}) returned empty data."
            rm -f "$node_csv"
        fi
    else
        echo "[ERROR] (${node}) connection failed."
        rm -f "$node_csv"
    fi
}

export -f run_node
export TEMP_DIR ENGINE_PATH DEBUG_IMAGE DATE_STR

# FIXED XARGS: Removed -n 1 to resolve the conflict with -I
echo "$NODES" | tr ' ' '\n' | xargs -I {} -P "$PARALLEL" bash -c 'run_node "{}"'

# --- PHASE 2: MERGE DATA ---
echo "[INFO] Merging per-node files into $OUT_FILE..."

# Check if any files were actually created
shopt -s nullglob
FILES=("$TEMP_DIR"/*-"$DATE_STR".csv)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "ERROR: No individual node CSVs found in $TEMP_DIR. Check if kubectl debug is permitted." >&2
    exit 1
fi

# Write header from first file
head -n 1 "${FILES[0]}" > "$OUT_FILE"

# Append rows (skipping header)
for f in "${FILES[@]}"; do
    tail -n +2 "$f" >> "$OUT_FILE"
done

# Organize reports
NODE_OUT_DIR="${OUT_DIR}/node_reports/${DATE_STR}"
mkdir -p "$NODE_OUT_DIR"
mv "$TEMP_DIR"/*-"$DATE_STR".csv "$NODE_OUT_DIR/"

echo "[OK] Master cluster inventory: $OUT_FILE"
