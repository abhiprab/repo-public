#!/usr/bin/env bash
# nic-mapping-univ.sh
# Vendor-neutral NIC mapping + BOND + sibling promotion
# Classification: SmartNIC (MAC Mismatch) vs SuperNIC (BlueField-3)

set -uo pipefail  # Removed -e to prevent hardware-call errors from killing the script

PRINT_STDOUT=false
OUTPUT_CSV=false
OUT_FILE=""

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Create temp files safely
TMP_DATA="$(mktemp /tmp/nic_data.XXXXXX)"
TMP_CSV="$(mktemp /tmp/nic_csv.XXXXXX)"
MAP_FILE="$(mktemp /tmp/nic_map.XXXXXX)"

cleanup() { 
    # Only remove files if they exist to avoid noise on exit
    rm -f "$TMP_DATA" "$TMP_CSV" "$MAP_FILE"
}
trap cleanup EXIT

# --- Helper Functions ---
sysread() { [[ -r "$1" ]] && cat "$1" || echo "N/A"; }
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) OUTPUT_CSV=true; shift ;;
    --print) PRINT_STDOUT=true; shift ;;
    --out) OUT_FILE="${2:-}"; shift 2 ;;
    -h|--help) 
      echo "Usage: $0 [--csv] [--print] [--out FILE]"
      exit 0 ;;
    *) shift 1 ;;
  esac
done

[[ "$OUTPUT_CSV" == false && -z "$OUT_FILE" ]] && PRINT_STDOUT=true

# --- 1) Pre-build PCI -> Iface Map ---
for d in /sys/class/net/*; do
  [[ -e "$d/device" ]] || continue
  pci_addr=$(basename "$(readlink -f "$d/device")")
  echo "$pci_addr|$(basename "$d")" >> "$MAP_FILE"
done

# Initialize CSV Header
echo "HOSTNAME,IFACE,FUNC,PARENT_PCI,PARENT_IFACE,BOND,CURR_MAC,PERM_MAC,SERIAL,PN,FW,STATUS,TYPE,PCI,MODEL_DESCRIPTION" > "$TMP_CSV"

# --- 2) Discovery Loop ---
count=0
for dev in /sys/class/net/*; do
  [[ -e "$dev/device" ]] || continue
  iface="$(basename "$dev")"
  
  # Filter noise
  [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb|^cni|^flannel|^cali|^virbr|^vxlan ]] && continue

  pci=$(basename "$(readlink -f "$dev/device")")
  desc=$(lspci -s "$pci" 2>/dev/null | cut -d':' -f3- | trim || echo "N/A")

  # PF/VF Logic
  func="PF"; p_pci="N/A"; p_iface="N/A"
  if [[ -e "$dev/device/physfn" ]]; then
    func="VF"
    p_pci=$(basename "$(readlink -f "$dev/device/physfn")")
    p_iface=$(grep "^$p_pci|" "$MAP_FILE" | cut -d'|' -f2 | head -n1 || echo "N/A")
  fi

  # MACs and Status
  cmac=$(sysread "$dev/address")
  pmac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $3}' || echo "N/A")
  stat=$(sysread "$dev/operstate")
  bond="N/A"; [[ -L "$dev/master" ]] && bond=$(basename "$(readlink -f "$dev/master")")
  fw=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/firmware-version:/{print $2}' || echo "N/A")

  # Serial Number Check
  sn="N/A"
  [[ -r "$dev/device/serial" ]] && sn=$(sysread "$dev/device/serial")
  if [[ "$sn" == "N/A" ]]; then
      sn=$(lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '/Serial number/{print $2; exit}' || echo "N/A")
  fi
  if [[ "$sn" == "N/A" ]] && have_cmd dmidecode; then
      sn=$(sudo dmidecode -s system-serial-number 2>/dev/null | head -n1 | trim || echo "N/A")
  fi

  # Part Number Check
  pn=$(lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '/part number/{print $2; exit}' || echo "N/A")
  [[ "$pn" == "N/A" && -r "$dev/device/vpd" ]] && pn=$(strings "$dev/device/vpd" 2>/dev/null | grep -i "PN" | head -n1 | trim || echo "N/A")

  # --- Type Detection (SmartNIC Promotion) ---
  type="Generic-NIC"
  if echo "$desc" | grep -qi "BlueField-3"; then
    type="SuperNIC"
    [[ "$pmac" != "N/A" && "$cmac" != "$pmac" ]] && type="SmartNIC"

    # Sibling Promotion
    if [[ "$type" == "SuperNIC" ]]; then
      slot="${pci%.*}"
      while IFS='|' read -r s_pci s_iface; do
        if [[ "$s_pci" == "$slot"* && "$s_pci" != "$pci" ]]; then
          s_cmac=$(sysread "/sys/class/net/$s_iface/address")
          s_pmac=$(ethtool -P "$s_iface" 2>/dev/null | awk '{print $3}' || echo "N/A")
          if [[ "$s_pmac" != "N/A" && "$s_cmac" != "$s_pmac" ]]; then
            type="SmartNIC"
            break
          fi
        fi
      done < "$MAP_FILE"
    fi
  fi

  # Accumulate Data
  echo "$iface|$func|$p_pci|$p_iface|$bond|$cmac|$pmac|$sn|$pn|$fw|$stat|$type|$pci|$desc" >> "$TMP_DATA"
  echo "$HOSTNAME_SHORT,$iface,$func,$p_pci,$p_iface,$bond,$cmac,$pmac,$sn,$pn,$fw,$stat,$type,$pci,\"$desc\"" >> "$TMP_CSV"
  
  count=$((count+1))
done

# --- 3) Final Output Logic ---
if [[ "$count" -eq 0 ]]; then
    echo "No matching NICs found." >&2
    exit 1
fi

# Write to file FIRST before trap cleanup triggers
if [[ -n "${OUT_FILE}" ]]; then
    mkdir -p "$(dirname "${OUT_FILE}")"
    cat "$TMP_CSV" > "$OUT_FILE"
    sync "$OUT_FILE"
fi

# Print to STDOUT last
if [[ "${PRINT_STDOUT}" == true ]]; then
    if [[ "${OUTPUT_CSV}" == true ]]; then
        cat "$TMP_CSV"
    else
        # Pretty Table Formatting
        (printf "IFACE|FUNC|P_PCI|P_IFACE|BOND|CURR_MAC|PERM_MAC|SERIAL|PN|FW|STATUS|TYPE|PCI|DESCRIPTION\n"; cat "$TMP_DATA") | \
        column -t -s '|' | \
        sed "s/\bup\b/${GREEN}UP${NC}/g; s/\bdown\b/${RED}DOWN${NC}/g"
    fi
fi
