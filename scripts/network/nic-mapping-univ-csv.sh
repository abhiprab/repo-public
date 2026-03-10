#!/bin/bash
# nic-mapping-univ.sh
# Original working NIC mapping + optional CSV output
#
# Default: print table to screen (same behavior as your old script)
# --csv            : write CSV file (default ./nic-mapping-<hostname>-<timestamp>.csv)
# --out <file.csv> : specify CSV output path (only with --csv)
# --print          : with --csv, also print CSV to screen
# --no-color       : disable UP/DOWN coloring in table

set -u

MODE="table"
CSV_WRITE=0
CSV_PRINT=0
OUT=""
COLOR=1

usage() {
  cat <<'USAGE'
Usage:
  nic-mapping-univ.sh                  # table to screen (default)
  nic-mapping-univ.sh --no-color       # table, no colors
  nic-mapping-univ.sh --csv            # write CSV file (default name)
  nic-mapping-univ.sh --csv --out /path/file.csv
  nic-mapping-univ.sh --csv --print    # write CSV + print CSV to screen
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) MODE="csv"; CSV_WRITE=1; shift ;;
    --out)
      OUT="${2:-}"
      [[ -n "$OUT" ]] || { echo "ERROR: --out requires a path" >&2; exit 1; }
      shift 2
      ;;
    --print) CSV_PRINT=1; shift ;;
    --no-color) COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TMP_DATA="$(mktemp)"
MAP_FILE="$(mktemp)"
cleanup() { rm -f "$TMP_DATA" "$MAP_FILE"; }
trap cleanup EXIT

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

csv_escape() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf "%s" "$s"
}

HOST="$(hostname -s 2>/dev/null || hostname)"

if [[ "$CSV_WRITE" -eq 1 && -z "$OUT" ]]; then
  ts="$(date +%F-%H%M%S)"
  OUT="./nic-mapping-${HOST}-${ts}.csv"
fi

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

# --- 2) Gather data per interface ---
for dev in /sys/class/net/*; do
  [[ -e "$dev/device" ]] || continue
  iface="$(basename "$dev")"
  [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb ]] && continue

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
    # Strict SmartNIC detection: CURR != PERM -> SmartNIC
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

  # widths
  (( ${#iface} > w_iface )) && w_iface=${#iface}
  (( ${#func} > w_func )) && w_func=${#func}
  (( ${#parent_pci} > w_parent )) && w_parent=${#parent_pci}
  (( ${#parent_iface} > w_piface )) && w_piface=${#parent_iface}
  (( ${#bond} > w_bond )) && w_bond=${#bond}
  (( ${#cmac} > w_cmac )) && w_cmac=${#cmac}
  (( ${#pmac} > w_pmac )) && w_pmac=${#pmac}
  (( ${#sn} > w_sn )) && w_sn=${#sn}
  (( ${#pn} > w_pn )) && w_pn=${#pn}
  (( ${#fw} > w_fw )) && w_fw=${#fw}
  (( ${#stat} > w_stat )) && w_stat=${#stat}
  (( ${#type} > w_type )) && w_type=${#type}
  (( ${#pci} > w_pci )) && w_pci=${#pci}
  (( ${#desc} > w_desc )) && w_desc=${#desc}

  # store row INCLUDING HOSTNAME
  echo "$HOST|$iface|$func|$parent_pci|$parent_iface|$bond|$cmac|$pmac|$sn|$pn|$fw|$stat|$type|$pci|$desc" >> "$TMP_DATA"
  count=$((count+1))
done

if [[ "$count" -eq 0 ]]; then
  echo "No NICs found under /sys/class/net (after filtering)." >&2
  exit 1
fi

write_csv() {
  local file="$1"
  {
    echo "HOSTNAME,IFACE,FUNC,PARENT_PCI,PARENT_IFACE,BOND,CURR_MAC,PERM_MAC,SERIAL,PN,FW,STATUS,TYPE,PCI,MODEL_DESCRIPTION"
    while IFS='|' read -r h iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
      echo "\"$(csv_escape "$h")\",\"$(csv_escape "$iface")\",\"$(csv_escape "$func")\",\"$(csv_escape "$p_pci")\",\"$(csv_escape "$p_iface")\",\"$(csv_escape "$bond")\",\"$(csv_escape "$cmac")\",\"$(csv_escape "$pmac")\",\"$(csv_escape "$sn")\",\"$(csv_escape "$pn")\",\"$(csv_escape "$fw")\",\"$(csv_escape "$stat")\",\"$(csv_escape "$type")\",\"$(csv_escape "$pci")\",\"$(csv_escape "$desc")\""
    done < "$TMP_DATA"
  } > "$file"
}

if [[ "$MODE" == "csv" ]]; then
  write_csv "$OUT"
  echo "[OK] wrote CSV: $OUT" >&2
  [[ "$CSV_PRINT" -eq 1 ]] && cat "$OUT"
  exit 0
fi

# --- Table output (same as old script, plus HOST not shown to keep it identical) ---
fmt="%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_piface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %-$(($w_stat+2))s %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n"

printf "$fmt" \
  "IFACE" "FUNC" "PARENT PCI" "PARENT IFACE" "BOND" "CURR MAC" "PERM MAC" "SERIAL" "PN" "FW" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"

while IFS='|' read -r h iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
  s_disp="$stat"
  if [[ "$COLOR" -eq 1 ]]; then
    if [[ "$stat" == "up" ]]; then s_disp="${GREEN}UP${NC}"; else s_disp="${RED}DOWN${NC}"; fi
  fi

  printf "%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_piface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %-$(($w_stat+2))b %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n" \
    "$iface" "$func" "$p_pci" "$p_iface" "$bond" "$cmac" "$pmac" "$sn" "$pn" "$fw" "$s_disp" "$type" "$pci" "$desc"
done < "$TMP_DATA"
