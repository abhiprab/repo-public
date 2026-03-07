#!/usr/bin/env bash
# merge-nic-reports.sh
# Combine per-node NIC inventory CSVs into one merged CSV.
#
# Usage:
#   ./merge-nic-reports.sh
#   ./merge-nic-reports.sh --dir /cm/shared/scripts/out
#   ./merge-nic-reports.sh --pattern '*.csv'
#   ./merge-nic-reports.sh --out /cm/shared/scripts/out/nic-inventory-merged.csv
#
# Notes:
# - By default it merges ONLY per-node files like <hostname>-YYYY-mm-dd-HHMMSS.csv
#   and ignores already-merged files like nic-inventory-*.csv to avoid duplicates.
# - Keeps exactly one header (from the first file).

set -euo pipefail

DIR="/cm/shared/scripts/out"
PATTERN="*.csv"
OUT="${DIR}/nic-inventory-merged-$(date +%F-%H%M%S).csv"

usage() {
  cat <<USAGE
Usage:
  $0 [--dir <dir>] [--pattern <glob>] [--out <merged.csv>]

Defaults:
  --dir     $DIR
  --pattern $PATTERN
  --out     $OUT
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --pattern) PATTERN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

cd "$DIR"

# Prefer per-node files (exclude nic-inventory-*.csv and other merged outputs)
mapfile -t FILES < <(ls -1 $PATTERN 2>/dev/null \
  | grep -vE '^nic-inventory-.*\.csv$' \
  | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no per-node CSVs found in $DIR matching '$PATTERN' (excluding nic-inventory-*.csv)" >&2
  echo "Files present:" >&2
  ls -la >&2 || true
  exit 1
fi

# Write header from first file
head -n 1 "${FILES[0]}" > "$OUT"

# Append rows from all files (skip headers)
for f in "${FILES[@]}"; do
  tail -n +2 "$f" >> "$OUT"
done

echo "[OK] merged ${#FILES[@]} files into: $OUT"
echo "[INFO] source files:"
printf "  - %s\n" "${FILES[@]}"
