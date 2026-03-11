#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
TEMP_DIR="${OUT_DIR}/tmp_raw"
SCRIPT_ON_NODE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
DEBUG_OPTS="--quiet --image=registry.k8s.io/e2e-test-images/busybox:1.29 --profile=general"

mkdir -p "$TEMP_DIR"

# --- COLLECTION FUNCTION ---
run_node() {
    local node="$1"
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    # The absolute path to the script as seen by the worker nodes
    local script_path="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
    
    echo -e "${BLUE}[INFO]${NC} (${node}) capturing via SSH..."

    # -o BatchMode=yes: Don't hang on password prompts
    # -o ConnectTimeout=5: Fail fast if node is down
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$node" \
        "sudo $script_path --csv --print" > "$node_csv" 2>/dev/null; then
        
        # Clean TTY garbage
        sed -i 's/\r//g' "$node_csv"

        if [[ -s "$node_csv" ]] && grep -q "HOSTNAME" "$node_csv"; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) captured."
        else
            echo -e "${RED}[ERROR]${NC} (${node}) failed. Check if sudo requires a password."
            rm -f "$node_csv"
        fi
    else
        echo -e "${RED}[ERROR]${NC} (${node}) SSH connection failed."
    fi
}

export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DEBUG_OPTS DATE_STR BLUE GREEN RED NC

# Parallel Execute
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')
printf "%s\n" $NODES | xargs -I{} -P 8 bash -c 'run_node "{}"'

# --- MERGE ---
echo -e "${BLUE}[INFO] Finalizing merge...${NC}"
shopt -s nullglob
files=( "$TEMP_DIR"/*"${DATE_STR}".csv )

if [[ ${#files[@]} -gt 0 ]]; then
    # Create the master file on the Jumpbox's local disk
    head -n 1 "${files[0]}" > "${OUT_DIR}/manual_inventory.csv"
    for f in "${files[@]}"; do
        tail -n +2 "$f" >> "${OUT_DIR}/manual_inventory.csv"
    done
    echo -e "${GREEN}[OK] Merged ${#files[@]} nodes into ${OUT_DIR}/manual_inventory.csv${NC}"
else
    echo -e "${RED}[ERROR] No data streamed back to jumpbox.${NC}"
    exit 1
fi
