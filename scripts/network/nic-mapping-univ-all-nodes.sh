#!/usr/bin/env bash
# nic-mapping-univ-all-nodes.sh
# 1. Collects NIC data from all K8s workers in parallel.
# 2. Saves individual node CSVs.
# 3. Merges them into one master CSV.

set -euo pipefail

# --- CONFIGURATION ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
OUT_FILE="${OUT_DIR}/nic-inventory-merged-${DATE_STR}.csv"
PARALLEL=8
TEMP_DIR="${OUT_DIR}/tmp_raw"
ENGINE_PATH="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

usage() {
    echo "Usage: $0 --out <file.csv> --parallel <N>"
    exit 1
}

# --- PARSE ARGS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_FILE="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        *) usage ;;
    esac
done

# Ensure directories exist
mkdir -p "$OUT_DIR"
mkdir -p "$TEMP_DIR"

# --- PHASE 1: COLLECT DATA ---
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

run_node() {
    local node=$1
    # Individual file saved with hostname and timestamp
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    
    echo "[INFO] (${node}) collecting details..."
    
    kubectl debug "node/${node}" -it --quiet --image="$DEBUG_IMAGE" -- \
        chroot /host bash -c "sudo $ENGINE_PATH --csv --out $node_csv" > /dev/null 2>&1
    
    if [[ -s "$node_csv" ]]; then
        echo "[SUCCESS] (${node}) data captured."
    else
        echo "[ERROR] (${node}) failed to capture data."
    fi
}

export -f run_node
export TEMP_DIR ENGINE_PATH DEBUG_IMAGE DATE_STR

echo "$NODES" | tr ' ' '\n' | xargs -n 1 -P "$PARALLEL" -I {} bash -c 'run_node "{}"'

# --- PHASE 2: MERGE DATA ---
echo "[INFO] Merging per-node files into $OUT_FILE..."

# Get the list of individual CSVs just created
mapfile -t FILES < <(ls -1 "$TEMP_DIR"/*-${DATE_STR}.csv 2>/dev/null | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "ERROR: No individual node CSVs found to merge." >&2
    exit 1
fi

# Write header from first file
head -n 1 "${FILES[0]}" > "$OUT_FILE"

# Append rows from all files (skip headers)
for f in "${FILES[@]}"; do
    if [ -s "$f" ]; then
        tail -n +2 "$f" >> "$OUT_FILE"
    fi
done

# --- PHASE 3: ORGANIZE INDIVIDUAL FILES ---
# Instead of deleting them, we keep them in a subfolder for reference
NODE_OUT_DIR="${OUT_DIR}/node_reports/${DATE_STR}"
mkdir -p "$NODE_OUT_DIR"
mv "$TEMP_DIR"/*-${DATE_STR}.csv "$NODE_OUT_DIR/"

echo "[OK] Individual node reports saved to: $NODE_OUT_DIR"
echo "[OK] Master cluster inventory created: $OUT_FILE"
