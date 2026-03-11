#!/usr/bin/env bash
# nic-mapping-univ.sh
# Fixed width tracking and indirect expansion for NDT tool

set -u  # nounset is active, so we must initialize variables

# --- CONFIGURATION ---
PRINT_STDOUT=false
OUTPUT_CSV=false
OUT_FILE=""

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Create temp files safely
TMP_DATA="$(mktemp)"
TMP_CSV="$(mktemp)"
MAP_FILE="$(mktemp)"

cleanup() { rm -f "$TMP_DATA" "$TMP_CSV" "$MAP_FILE"; }
trap cleanup EXIT

# --- HELPERS ---
have_cmd() { command -v "$1" >/dev/null 2>&1; }
sysread() { [[ -r "$1" ]] && cat "$1" || echo "N/A"; }
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

safe_readlink_basename() {
    local out
    out="$(readlink -f "$1" 2>/dev/null || true)"
    [[ -n "$out" ]] && basename "$out" || echo "N/A"
}

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv) OUTPUT_CSV=true; shift ;;
        --print) PRINT_STDOUT=true; shift ;;
        --out) OUT_FILE="${2:-}"; shift 2 ;;
        *) shift 1 ;;
    esac
done

[[ "$OUTPUT_CSV" == false && -z "$OUT_FILE" ]] && PRINT_STDOUT=true

# --- 1) BUILD PCI MAP ---
for d in /sys/class/net/*; do
    [[ -e "$d/device" ]] || continue
    pci_addr="$(safe_readlink_basename "$d/device")"
    echo "$pci_addr|$(basename "$d")" >> "$MAP_FILE"
done

# Initialize CSV Header
echo "HOSTNAME,IFACE,FUNC,PARENT_PCI,PARENT_IFACE,BOND,CURR_MAC,PERM_MAC,SERIAL,PN,FW,STATUS,TYPE,PCI,MODEL_DESCRIPTION" > "$TMP_CSV"

# --- 2) INITIALIZE WIDTHS (Fixes 'unbound variable' error) ---
w_iface=5; w_func=4; w_p_pci=10; w_p_iface=12; w_bond=4
w_cmac=17; w_pmac=17; w_sn=6; w_pn=6; w_fw=8; w_stat=6
w_type=10; w_pci=12; w_desc=17

count=0

# --- 3) GATHER DATA ---
for dev in /sys/class/net/*; do
    [[ -e "$dev/device" ]] || continue
    iface="$(basename "$dev")"
    [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb ]] && continue

    pci="$(safe_readlink_basename "$dev/device")"
    desc="$(lspci -s "$pci" 2>/dev/null | cut -d':' -f3- | trim || echo "N/A")"

    func="PF"; p_pci="N/A"; p_iface="N/A"
    if [[ -e "$dev/device/physfn" ]]; then
        func="VF"
        p_pci="$(safe_readlink_basename "$dev/device/physfn")"
        p_iface="$(grep -m1 "^$p_pci|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || echo "N/A")"
    fi

    bond="$(sysread "$dev/master" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")"
    cmac="$(sysread "$dev/address")"
    pmac="$(ethtool -P "$iface" 2>/dev/null | awk '{print $3}' || echo "N/A")"
    stat="$(sysread "$dev/operstate")"
    fw="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/firmware-version:/{print $2; exit}' | trim || echo "N/A")"

    sn="N/A"
    [[ -r "$dev/device/serial" ]] && sn="$(sysread "$dev/device/serial" | trim)"
    [[ "$sn" == "N/A" ]] && sn="$(lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '/Serial number/{print $2; exit}' | trim || echo "N/A")"
    
    pn="N/A"
    vpd_file="/sys/bus/pci/devices/$pci/vpd"
    if [[ -r "$vpd_file" ]] && have_cmd strings; then
        pn="$(strings "$vpd_file" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /(^|[^A-Z0-9])(PN|P\/N|PART[ -]?NO|PART[ -]?NUMBER)[^A-Z0-9]/{print; exit}' | trim || echo "N/A")"
    fi
    [[ "$pn" == "N/A" ]] && pn="$(lspci -vv -s "$pci" 2>/dev/null | awk -F': ' '/part number/{print $2; exit}' | trim || echo "N/A")"

    type="Generic-NIC"
    if echo "$desc" | grep -qi "BlueField-3"; then
        type="SuperNIC"
        [[ "$pmac" != "N/A" && "$cmac" != "$pmac" ]] && type="SmartNIC"
    fi

    # Sibling Promotion logic
    if [[ "$type" == "SuperNIC" ]]; then
        slot="${pci%.*}"
        for sibpath in /sys/bus/pci/devices/"${slot}".*; do
            [[ -e "$sibpath" ]] || continue
            sibpci="$(basename "$sibpath")"
            sibiface="$(grep -m1 "^${sibpci}|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || true)"
            [[ -z "${sibiface:-}" ]] && continue
            s_pmac="$(ethtool -P "$sibiface" 2>/dev/null | awk '{print $3}' || echo "N/A")"
            s_cmac="$(sysread "/sys/class/net/$sibiface/address")"
            if [[ "$s_pmac" != "N/A" && "$s_cmac" != "$s_pmac" ]]; then
                type="SmartNIC"
                break
            fi
        done
    fi

    # Update Widths (Fixed logic for set -u)
    for var in iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
        val="${!var}"
        len=${#val}
        w_var="w_$var"
        # Indirect check: if length > current width, update it
        if [ "$len" -gt "${!w_var}" ]; then
            eval "w_$var=$len"
        fi
    done

    echo "$iface|$func|$p_pci|$p_iface|$bond|$cmac|$pmac|$sn|$pn|$fw|$stat|$type|$pci|$desc" >> "$TMP_DATA"
    echo "$HOSTNAME_SHORT,$iface,$func,$p_pci,$p_iface,$bond,$cmac,$pmac,$sn,$pn,$fw,$stat,$type,$pci,\"$desc\"" >> "$TMP_CSV"
    count=$count+1
done

# --- 4) OUTPUT ---
if [[ -n "$OUT_FILE" ]]; then
    cat "$TMP_CSV" > "$OUT_FILE"
fi

if [[ "$PRINT_STDOUT" == "true" ]]; then
    if [[ "$OUTPUT_CSV" == "true" ]]; then
        cat "$TMP_CSV"
    else
        # Correctly formatted table
        fmt="%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_p_pci+2))s %-$(($w_p_iface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %-$(($w_stat+2))b %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n"
        printf "$fmt" "IFACE" "FUNC" "PARENT PCI" "PARENT IFACE" "BOND" "CURR MAC" "PERM MAC" "SERIAL" "PN" "FW" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"

        while IFS='|' read -r iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
            [[ "$stat" == "up" ]] && s_disp="${GREEN}UP${NC}" || s_disp="${RED}DOWN${NC}"
            
            printf "%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_p_pci+2))s %-$(($w_p_iface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s " \
                "$iface" "$func" "$p_pci" "$p_iface" "$bond" "$cmac" "$pmac" "$sn" "$pn" "$fw"
            printf "%b" "$s_disp"
            pad=$(( (w_stat + 2) - ${#stat} ))
            printf "%${pad}s" ""
            printf "%-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n" "$type" "$pci" "$desc"
        done < "$TMP_DATA"
    fi
fi
