#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
TEMP_DIR="${OUT_DIR}/tmp_raw"
SCRIPT_ON_NODE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

# Colors
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export NC='\033[0m'

mkdir -p "$TEMP_DIR"

# Resolve Node List
NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

# --- THE COLLECTION FUNCTION ---
run_node() {
  local node="$1"
  local out_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
  
  echo -e "${BLUE}[INFO]${NC} (${node}) collecting via stream..."

  # 1. We use -i (interactive) without -t (TTY) to stream raw CSV data
  # 2. --profile=general stops the legacy warning
  # 3. Output is redirected to the JUMPBOX local disk
  if kubectl debug "node/${node}" -i --quiet --image="${DEBUG_IMAGE}" --profile=general -- \
    chroot /host bash -lc "'${SCRIPT_ON_NODE}' --csv --print" > "$out_csv" 2>/dev/null; then
    
    # Strip any potential TTY carriage returns and validate header
    sed -i 's/\r//g' "$out_csv"
    
    if [[ -s "$out_csv" ]] && grep -q "HOSTNAME" "$out_csv"; then
      echo -e "${GREEN}[SUCCESS]${NC} (${node}) captured."
    else
      echo -e "${RED}[ERROR]${NC} (${node}) capture failed or empty."
      rm -f "$out_csv"
    fi
  else
    echo -e "${RED}[ERROR]${NC} (${node}) kubectl connection failed."
  fi
}

# Export function and variables for xargs subshell
export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DEBUG_IMAGE DATE_STR BLUE GREEN RED NC

# --- EXECUTION ---
printf "%s\n" $NODES | xargs -I{} -P 4 bash -c 'run_node "{}"'

# --- MERGE ---
shopt -s nullglob
files=( "$TEMP_DIR"/*-"$DATE_STR".csv )

if [[ ${#files[@]} -gt 0 ]]; then
  # Use the first file for the header
  head -n 1 "${files[0]}" > "${OUT_DIR}/manual_inventory.csv"
  # Append data from all files, skipping headers
  for f in "${files[@]}"; do
    tail -n +2 "$f" >> "${OUT_DIR}/manual_inventory.csv"
  done
  echo -e "${GREEN}[OK] Merged results into ${OUT_DIR}/manual_inventory.csv${NC}"
else
  echo -e "${RED}[ERROR] No data captured from any nodes.${NC}"
  exit 1
fi
