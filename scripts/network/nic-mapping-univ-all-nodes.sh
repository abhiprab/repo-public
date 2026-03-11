#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/out"
# Change output to the NDT standard path
NDT_OUT="/cm/shared/scripts/net-mapping/out/manual_inventory.csv"
SCRIPT_ON_NODE="/cm/shared/scripts/nic-mapping-univ.sh"
# Use profile=general to stop the legacy warning
DEBUG_OPTS="--quiet --image=registry.k8s.io/e2e-test-images/busybox:1.29 --profile=general"

mkdir -p "$OUT_DIR"

# --- COLLECTION FUNCTION ---
run_node() {
    local node="$1"
    local out_csv="${OUT_DIR}/${node}-${DATE_STR}.csv"
    echo -e "${BLUE}[INFO]${NC} (${node}) collecting..."

    # Executing via debug pod, writing directly to shared mount
    # Using 'bash -lc' ensures the shared path is in the environment
    if kubectl debug "node/${node}" $DEBUG_OPTS -- \
        chroot /host bash -lc "'$SCRIPT_ON_NODE' --csv --out '$out_csv'" >/dev/null 2>&1; then
        
        # Settle loop: Wait up to 5 seconds for NFS to show the file on the Jumpbox
        local retry=0
        while [ ! -f "$out_csv" ] && [ $retry -lt 5 ]; do
            sleep 1
            ((retry++))
        done

        if [ -f "$out_csv" ]; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) captured."
        else
            echo -e "${YELLOW}[WARN]${NC} (${node}) File written but not visible on Jumpbox yet."
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) debug pod failed."
    fi
}

export -f run_node
export SCRIPT_ON_NODE OUT_DIR DEBUG_OPTS DATE_STR BLUE GREEN RED YELLOW NC

# Run parallel collection
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')
printf "%s\n" $NODES | xargs -I{} -P 8 bash -c 'run_node "{}"'

# --- MERGE LOGIC ---
echo -e "${BLUE}[INFO] Finalizing merge...${NC}"
sleep 2 # Final breath for NFS sync
shopt -s nullglob
files=( "${OUT_DIR}"/*"${DATE_STR}".csv )

if [[ ${#files[@]} -gt 0 ]]; then
    # Create the NDT master CSV
    head -n 1 "${files[0]}" > "$NDT_OUT"
    for f in "${files[@]}"; do
        tail -n +2 "$f" >> "$NDT_OUT"
    done
    echo -e "${GREEN}[OK] Merged ${#files[@]} nodes into $NDT_OUT${NC}"
else
    echo -e "${RED}[ERROR] No CSV files found for this run.${NC}"
    exit 1
fi
