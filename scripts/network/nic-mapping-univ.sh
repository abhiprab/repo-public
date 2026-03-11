#!/usr/bin/env bash
# nic-mapping-univ.sh
# Vendor-neutral NIC mapping (PN-focused, Cisco-safe) + BOND + sibling promotion
#
# Features:
# - Pretty table output by default
# - Proper CSV output with HOSTNAME column
# - Supports:
#     --csv         Emit CSV
#     --print       Print to stdout
#     --out <file>  Write output to file
#
# SmartNIC detection (strict):
#   * BlueField-3 AND (CURR MAC != PERM MAC) => SmartNIC
#   * Otherwise BlueField-3 => SuperNIC
# Sibling promotion:
#   * if any sibling function in same PCI slot shows SmartNIC pattern,
#     promote the entire slot to SmartNIC

set -euo pipefail

PRINT_STDOUT=false
OUTPUT_CSV=false
OUT_FILE=""

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

TMP_DATA="$(mktemp)"
TMP_CSV="$(mktemp)"
MAP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_DATA" "$TMP_CSV" "$MAP_FILE"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  nic-mapping-univ.sh [--csv] [--print] [--out FILE]

Options:
  --csv         Emit CSV format
  --print       Print output to stdout
  --out FILE    Write output to FILE
  -h, --help    Show help

Default:
  If no options are given, prints a human-readable table to stdout.

Examples:
  ./nic-mapping-univ.sh
  ./nic-mapping-univ.sh --csv --print
  ./nic-mapping-univ.sh --csv --out /tmp/nics.csv
  ./nic-mapping-univ.sh --csv --print --out /tmp/nics.csv
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) OUTPUT_CSV=true; shift ;;
    --print) PRINT_STDOUT=true; shift ;;
    --out)
      OUT_FILE="${2:-}"
      [[ -n "${OUT_FILE}" ]] || { echo "ERROR: --out requires a file path" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${OUTPUT_CSV}" == false && -z "${OUT_FILE}" ]]; then
  PRINT_STDOUT=true
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

sysread() { [[ -r "$1" ]] && cat "$1" || echo "N/A"; }
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

safe_readlink_basename() {
  local out
  out="$(readlink -f "$1" 2>/dev/null || true)"
  [[ -n "$out" ]] && basename "$out" || echo "N/A"
}

safe_ethtool_perm_mac() {
  local iface="$1"
  if have_cmd ethtool; then
    ethtool -P "$iface" 2>/dev/null | awk '{print $3}' | head -n1
  fi
}

safe_ethtool_fw() {
  local iface="$1"
  if have_cmd ethtool; then
    ethtool -i "$iface" 2>/dev/null | awk -F': ' '/firmware-version:/{print $2; exit}' | trim
  fi
}

safe_lspci_desc() {
  local pci="$1"
  if have_cmd lspci && [[ "$pci" != "N/A" ]]; then
    lspci -s "$pci" 2>/dev/null | cut -d':' -f3- | trim
  fi
}

safe_lspci_serial() {
  local pci="$1"
  if have_cmd lspci && [[ "$pci" != "N/A" ]]; then
    lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '/Serial number/{print $2; exit}' | trim
  fi
}

safe_lspci_partnum() {
  local pci="$1"
  if have_cmd lspci && [[ "$pci" != "N/A" ]]; then
    lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '
      BEGIN{IGNORECASE=1}
      /part number/{print $2; exit}
    ' | trim
  fi
}

pn_from_vpd() {
  local pci="$1"
  local vpd="/sys/bus/pci/devices/$pci/vpd"
  [[ -r "$vpd" ]] || return 0
  have_cmd strings || return 0

  strings "$vpd" 2>/dev/null | awk '
    BEGIN{IGNORECASE=1}
    /(^|[^A-Z0-9])(PN|P\/N|PART[ -]?NO|PART[ -]?NUMBER)[^A-Z0-9]/{print; exit}
  ' | trim
}

bond_master_of_iface() {
  local iface="$1"
  local m="/sys/class/net/$iface/master"
  if [[ -L "$m" ]]; then
    local master_name
    master_name="$(basename "$(readlink -f "$m" 2>/dev/null || true)")"
    if [[ "$master_name" =~ ^bond[0-9]+$ ]]; then
      echo "$master_name"
      return 0
    fi
  fi
  echo "N/A"
}

csv_quote() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

write_csv_header() {
  cat <<'EOF' > "$TMP_CSV"
HOSTNAME,IFACE,FUNC,PARENT_PCI,PARENT_IFACE,BOND,CURR_MAC,PERM_MAC,SERIAL,PN,FW,STATUS,TYPE,PCI,MODEL_DESCRIPTION
EOF
}

append_csv_row() {
  local hostname="$1"
  local iface="$2"
  local func="$3"
  local parent_pci="$4"
  local parent_iface="$5"
  local bond="$6"
  local curr_mac="$7"
  local perm_mac="$8"
  local serial="$9"
  local pn="${10}"
  local fw="${11}"
  local status="${12}"
  local type="${13}"
  local pci="${14}"
  local desc="${15}"

  {
    csv_quote "$hostname"; printf ','
    csv_quote "$iface"; printf ','
    csv_quote "$func"; printf ','
    csv_quote "$parent_pci"; printf ','
    csv_quote "$parent_iface"; printf ','
    csv_quote "$bond"; printf ','
    csv_quote "$curr_mac"; printf ','
    csv_quote "$perm_mac"; printf ','
    csv_quote "$serial"; printf ','
    csv_quote "$pn"; printf ','
    csv_quote "$fw"; printf ','
    csv_quote "$status"; printf ','
    csv_quote "$type"; printf ','
    csv_quote "$pci"; printf ','
    csv_quote "$desc"
    printf '\n'
  } >> "$TMP_CSV"
}

# --- 1) Build PCI -> iface map (for sibling lookup) ---
for d in /sys/class/net/*; do
  [[ -e "$d/device" ]] || continue
  pci_addr="$(safe_readlink_basename "$d/device")"
  iface_name="$(basename "$d")"
  [[ "$pci_addr" == "N/A" ]] && continue
  echo "$pci_addr|$iface_name" >> "$MAP_FILE"
done

# Column widths (min)
w_iface=5; w_func=4; w_parent=12; w_piface=12
w_cmac=8; w_pmac=8; w_sn=6; w_pn=6; w_fw=8
w_bond=4
w_stat=6; w_type=10; w_pci=12; w_desc=17

count=0
write_csv_header

# --- 2) Gather data per interface ---
for dev in /sys/class/net/*; do
  [[ -e "$dev/device" ]] || continue
  iface="$(basename "$dev")"
  [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb|^cni|^flannel|^cali|^virbr|^ovs-system|^vxlan|^genev_sys ]] && continue

  dev_path="/sys/class/net/$iface/device"

  # PF/VF + Parent
  if [[ -e "$dev_path/physfn" ]]; then
    func="VF"
    parent_pci="$(safe_readlink_basename "$dev_path/physfn")"
    parent_iface="$(grep -m1 "^$parent_pci|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || true)"
    [[ -z "${parent_iface:-}" ]] && parent_iface="N/A"
  else
    func="PF"
    parent_pci="N/A"
    parent_iface="N/A"
  fi

  # Bond master (if any)
  bond="$(bond_master_of_iface "$iface")"

  # MACs
  cmac="$(sysread "$dev/address")"
  pmac="$(safe_ethtool_perm_mac "$iface")"
  [[ -z "${pmac:-}" ]] && pmac="N/A"

  # PCI BDF
  pci="$(safe_readlink_basename "$dev/device")"

  # Description
  desc="$(safe_lspci_desc "$pci")"
  [[ -z "${desc:-}" ]] && desc="N/A"

  # Firmware
  fw="$(safe_ethtool_fw "$iface")"
  [[ -z "${fw:-}" ]] && fw="N/A"

  # Serial
  sn="N/A"
  if [[ -r "$dev_path/serial" ]]; then
    sn="$(sysread "$dev_path/serial" | head -n1 | trim)"
    [[ -z "${sn:-}" ]] && sn="N/A"
  fi
  if [[ "$sn" == "N/A" ]]; then
    sn2="$(safe_lspci_serial "$pci")"
    [[ -n "${sn2:-}" ]] && sn="$sn2"
  fi
  if [[ "$sn" == "N/A" ]] && have_cmd dmidecode; then
    sn3="$(sudo dmidecode -s system-serial-number 2>/dev/null | head -n1 | trim || true)"
    [[ -n "${sn3:-}" ]] && sn="$sn3"
  fi

  # PN
  pn="$(pn_from_vpd "$pci" || true)"
  [[ -z "${pn:-}" ]] && pn="$(safe_lspci_partnum "$pci")"
  [[ -z "${pn:-}" ]] && pn="N/A"

  # Status
  stat="$(sysread "$dev/operstate")"
  [[ -z "${stat:-}" ]] && stat="unknown"

  # Initial TYPE (BlueField detection)
  type="Generic-NIC"
  if echo "$desc" | grep -qi "BlueField-3"; then
    type="SuperNIC"
    if [[ "$pmac" != "N/A" && "$cmac" != "N/A" && "$cmac" != "$pmac" ]]; then
      type="SmartNIC"
    fi
  fi

  # SIBLING PROMOTION
  if [[ "$type" == "SuperNIC" && "$pci" != "N/A" ]]; then
    slot="${pci%.*}"
    for sibpath in /sys/bus/pci/devices/"${slot}".*; do
      [[ -e "$sibpath" ]] || continue
      sibpci="$(basename "$sibpath")"
      sibiface="$(grep -m1 "^${sibpci}|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || true)"
      [[ -z "${sibiface:-}" ]] && continue
      sib_pmac="$(ethtool -P "$sibiface" 2>/dev/null | awk '{print $3}' || true)"
      [[ -z "${sib_pmac:-}" ]] && sib_pmac="N/A"
      sib_cmac="$(sysread "/sys/class/net/$sibiface/address" 2>/dev/null || true)"
      [[ -z "${sib_cmac:-}" ]] && sib_cmac="N/A"
      if [[ "$sib_pmac" != "N/A" && "$sib_cmac" != "N/A" && "$sib_cmac" != "$sib_pmac" ]]; then
        type="SmartNIC"
        break
      fi
    done
  fi

  # Update widths for pretty table
if (( ${#iface} > w_iface )); then w_iface=${#iface}; fi
if (( ${#func} > w_func )); then w_func=${#func}; fi
if (( ${#parent_pci} > w_parent )); then w_parent=${#parent_pci}; fi
if (( ${#parent_iface} > w_piface )); then w_piface=${#parent_iface}; fi
if (( ${#bond} > w_bond )); then w_bond=${#bond}; fi
if (( ${#cmac} > w_cmac )); then w_cmac=${#cmac}; fi
if (( ${#pmac} > w_pmac )); then w_pmac=${#pmac}; fi
if (( ${#sn} > w_sn )); then w_sn=${#sn}; fi
if (( ${#pn} > w_pn )); then w_pn=${#pn}; fi
if (( ${#fw} > w_fw )); then w_fw=${#fw}; fi
if (( ${#stat} > w_stat )); then w_stat=${#stat}; fi
if (( ${#type} > w_type )); then w_type=${#type}; fi
if (( ${#pci} > w_pci )); then w_pci=${#pci}; fi
if (( ${#desc} > w_desc )); then w_desc=${#desc}; fi

  echo "$iface|$func|$parent_pci|$parent_iface|$bond|$cmac|$pmac|$sn|$pn|$fw|$stat|$type|$pci|$desc" >> "$TMP_DATA"

  append_csv_row \
    "$HOSTNAME_SHORT" \
    "$iface" \
    "$func" \
    "$parent_pci" \
    "$parent_iface" \
    "$bond" \
    "$cmac" \
    "$pmac" \
    "$sn" \
    "$pn" \
    "$fw" \
    "$stat" \
    "$type" \
    "$pci" \
    "$desc"

  count=$((count+1))
  done

if [[ "$count" -eq 0 ]]; then
  echo "No NICs found under /sys/class/net (after filtering)." >&2
  exit 1
fi

print_table() {
  local fmt
  fmt="%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_piface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %-$(($w_stat+2))s %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n"

  printf "$fmt" \
    "IFACE" "FUNC" "PARENT PCI" "PARENT IFACE" "BOND" "CURR MAC" "PERM MAC" "SERIAL" "PN" "FW" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"

  while IFS='|' read -r iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
    if [[ "$stat" == "up" ]]; then
      s_disp="${GREEN}UP${NC}"
    else
      s_disp="${RED}DOWN${NC}"
    fi

    printf "%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_piface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s " \
      "$iface" "$func" "$p_pci" "$p_iface" "$bond" "$cmac" "$pmac" "$sn" "$pn" "$fw"

    printf "%b" "$s_disp"
    pad=$(( (w_stat + 2) - ${#stat} ))
    printf "%${pad}s" ""

    printf "%-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n" "$type" "$pci" "$desc"
  done < "$TMP_DATA"
}

if [[ -n "${OUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUT_FILE}")"
  cp "$TMP_CSV" "$OUT_FILE"
fi

if [[ "${PRINT_STDOUT}" == true ]]; then
  if [[ "${OUTPUT_CSV}" == true ]]; then
    cat "$TMP_CSV"
  else
    print_table
  fi
fi
