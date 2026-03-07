#!/usr/bin/env bash
# collect-nic-inventory.sh
# Run nic-mapping-univ.sh on all (or selected) nodes and collect CSVs into one merged CSV.
#
# Requirements:
# - kubectl access as cluster-admin (for kubectl debug node/... and chroot /host)
# - /cm/shared/scripts mounted on nodes AND on the machine you run this from (or at least accessible on nodes)
# - nic-mapping-univ.sh already present and executable at /cm/shared/scripts/nic-mapping-univ.sh
#
# Usage:
#   ./collect-nic-inventory.sh
#   ./collect-nic-inventory.sh --selector 'node-role.kubernetes.io/worker='
#   ./collect-nic-inventory.sh --nodes n1,n2,n3
#   ./collect-nic-inventory.sh --out /cm/shared/scripts/out/all-nics.csv
#   ./collect-nic-inventory.sh --parallel 6

set -euo pipefail

SCRIPT_ON_NODE="/cm/shared/scripts/nic-mapping-univ.sh"
OUT_DIR="/cm/shared/scripts/out"
MERGED_OUT="${OUT_DIR}/nic-inventory-$(date +%F-%H%M%S).csv"
NODE_SELECTOR="node-role.kubernetes.io/worker="
NODES_CSV=""
PARALLEL=4
DEBUG_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29"

usage() {
  cat <<USAGE
Usage:
  $0 [--selector <label-selector>] [--nodes n1,n2] [--out <merged.csv>] [--parallel N] [--image <debug-image>]

Defaults:
  --selector  '${NODE_SELECTOR}'
  --parallel  ${PARALLEL}
  --out       ${MERGED_OUT}

Examples:
  $0
  $0 --selector 'kubernetes.io/os=linux'
  $0 --nodes pdx-g22r13-2894-lh2-w01,pdx-g24r31-2894-ch2-w06
  $0 --parallel 8 --out /cm/shared/scripts/out/all-nics.csv
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector) NODE_SELECTOR="${2:-}"; shift 2 ;;
    --nodes) NODES_CSV="${2:-}"; shift 2 ;;
    --out) MERGED_OUT="${2:-}"; shift 2 ;;
    --parallel) PARALLEL="${2:-}"; shift 2 ;;
    --image) DEBUG_IMAGE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

# Resolve node list
if [[ -n "$NODES_CSV" ]]; then
  IFS=',' read -r -a NODES <<< "$NODES_CSV"
else
  mapfile -t NODES < <(kubectl get nodes -l "$NODE_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: No nodes matched. selector='$NODE_SELECTOR' nodes='$NODES_CSV'" >&2
  exit 1
fi

echo "[INFO] Nodes to collect: ${#NODES[@]}"
printf '  - %s\n' "${NODES[@]}"

# Per-node runner
run_one_node() {
  local node="$1"
  local ts out_csv
  ts="$(date +%F-%H%M%S)"
  out_csv="${OUT_DIR}/${node}-${ts}.csv"

  echo "[INFO] (${node}) collecting -> ${out_csv}"

  # Run the script on the node host via debug + chroot /host
  # --quiet keeps output low; we write CSV on the node's mounted FS
  kubectl debug "node/${node}" -it --quiet --image="${DEBUG_IMAGE}" -- \
    chroot /host bash -lc "
      set -euo pipefail
      if [[ ! -x '${SCRIPT_ON_NODE}' ]]; then
        echo 'ERROR: ${SCRIPT_ON_NODE} not found or not executable on node ${node}' >&2
        exit 1
      fi
      mkdir -p '${OUT_DIR}'
      '${SCRIPT_ON_NODE}' --csv --out '${out_csv}'
    " >/dev/null

  # Verify file exists (best-effort from this machine; if you don't mount /cm, it will still exist on nodes)
  if [[ -f "$out_csv" ]]; then
    echo "[OK] (${node}) wrote $out_csv"
  else
    echo "[WARN] (${node}) CSV created on node, but not visible locally at $out_csv (is /cm mounted here?)" >&2
  fi
}

export -f run_one_node
export SCRIPT_ON_NODE OUT_DIR DEBUG_IMAGE

# Run in parallel
# shellcheck disable=SC2016
printf "%s\n" "${NODES[@]}" | xargs -P "$PARALLEL" -I{} bash -lc 'run_one_node "$@"' _ {}

# Merge all CSVs (only those visible from where this script runs)
shopt -s nullglob
csvs=( "${OUT_DIR}"/*.csv )

if [[ ${#csvs[@]} -eq 0 ]]; then
  echo "[ERROR] No CSV files found locally under ${OUT_DIR}/*.csv" >&2
  echo "        If /cm isn't mounted on this machine, copy them off nodes or run this script on a host that has /cm mounted." >&2
  exit 1
fi

# Pick newest per node? (optional) For now, merge everything created.
# Build merged file with one header.
{
  head -n 1 "${csvs[0]}"
  for f in "${csvs[@]}"; do
    tail -n +2 "$f"
  done
} > "$MERGED_OUT"

echo "[OK] Merged CSV written: $MERGED_OUT"
echo "[INFO] Source CSV count: ${#csvs[@]}"
