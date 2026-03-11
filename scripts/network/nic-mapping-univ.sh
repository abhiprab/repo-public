#!/usr/bin/env bash
# nic-mapping-univ.sh
# Final corrected version for NDT:
# - proper CSV output with HOSTNAME
# - pretty table output
# - safe bond detection
# - restored serial / PN fallback logic
# - broader virtual interface filtering

set -uo pipefail

# --- CONFIGURATION ---
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

cleanup() { rm -f "$TMP_DATA" "$TMP_CSV" "$MAP_FILE"; }
trap cleanup EXIT

# --- HELPERS ---
have_cmd() { command -v "$1" >/dev/null 2>&1; }
sysread() { [[ -r "$1" ]] && cat "$1" || echo "N/A"; }
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

csv_escape() {
    local s="${1:-}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

safe_readlink_basename() {
    local out
    out="$(readlink -f "$1" 2>/dev/null || true)"
    [[ -n "$out" ]] && basename "$out" || echo "N/A"
}

safe_lspci_desc() {
    local pci="$1"
    if have_cmd lspci && [[ "$pci" != "N/A" ]]; then
        lspci -s "$pci" 2>/dev/null | cut -d':' -f3- | trim
    else
        echo "N/A"
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

pn_from_vpd() {
    local pci="$1"
    local vpd_file="/sys/bus/pci/devices/$pci/vpd"
    [[ -r "$vpd_file" ]] || return 0
    have_cmd strings || return 0

    strings "$vpd_file" 2>/dev/null | awk '
        BEGIN{IGNORECASE=1}
        /(^|[^A-Z0-9])(PN|P\/N|PART[ -]?NO|PART[ -]?NUMBER)[^A-Z0-9]/{print; exit}
    ' | trim
}

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv) OUTPUT_CSV=true; shift ;;
        --print) PRINT_STDOUT=true; shift ;;
        --out)
            OUT_FILE="${2:-}"
            [[ -n "$OUT_FILE" ]] || { echo "ERROR: --out requires a file path" >&2; exit 1; }
            shift 2
            ;;
        -h|--help)
            cat <<'USAGE'
Usage:
  nic-mapping-univ.sh [--csv] [--print] [--out FILE]

Options:
  --csv         Emit CSV format
  --print       Print output to stdout
  --out FILE    Write output to FILE
  -h, --help    Show help
USAGE
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[[ "$OUTPUT_CSV" == false && -z "$OUT_FILE" ]] && PRINT_STDOUT=true

# --- 1) BUILD PCI MAP ---
for d in /sys/class/net/*; do
    [[ -e "$d/device" ]] || continue
    pci_addr="$(safe_readlink_basename "$d/device")"
    echo "$pci_addr|$(basename "$d")" >> "$MAP_FILE"
done

# Initialize CSV header
echo "HOSTNAME,IFACE,FUNC,PARENT_PCI,PARENT_IFACE,BOND,CURR_MAC,PERM_MAC,SERIAL,PN,FW,STATUS,TYPE,PCI,MODEL_DESCRIPTION" > "$TMP_CSV"

# Initialize widths
w_iface=5; w_func=4; w_p_pci=10; w_p_iface=12; w_bond=4
w_cmac=17; w_pmac=17; w_sn=6; w_pn=6; w_fw=8; w_stat=6
w_type=10; w_pci=12; w_desc=17

count=0

# --- 2) GATHER DATA ---
for dev in /sys/class/net/*; do
    [[ -e "$dev/device" ]] || continue
    iface="$(basename "$dev")"

    [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb|^cni|^flannel|^cali|^virbr|^ovs-system|^vxlan|^genev_sys ]] && continue

    pci="$(safe_readlink_basename "$dev/device")"
    desc="$(safe_lspci_desc "$pci")"
    [[ -z "${desc:-}" ]] && desc="N/A"

    func="PF"
    p_pci="N/A"
    p_iface="N/A"
    if [[ -e "$dev/device/physfn" ]]; then
        func="VF"
        p_pci="$(safe_readlink_basename "$dev/device/physfn")"
        p_iface="$(grep -m1 "^$p_pci|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || true)"
        [[ -z "${p_iface:-}" ]] && p_iface="N/A"
    fi

    # Bond detection
    bond="N/A"
    if [[ -L "$dev/master" ]]; then
        bond="$(basename "$(readlink -f "$dev/master" 2>/dev/null || true)")"
        [[ -z "$bond" ]] && bond="N/A"
    fi

    cmac="$(sysread "$dev/address")"
    pmac="$(safe_ethtool_perm_mac "$iface")"
    [[ -z "${pmac:-}" ]] && pmac="N/A"

    stat="$(sysread "$dev/operstate")"
    [[ -z "${stat:-}" ]] && stat="N/A"

    fw="$(safe_ethtool_fw "$iface")"
    [[ -z "${fw:-}" ]] && fw="N/A"

    # Serial logic
    sn="N/A"
    if [[ -r "$dev/device/serial" ]]; then
        sn="$(sysread "$dev/device/serial" | head -n1 | trim)"
        [[ -z "${sn:-}" ]] && sn="N/A"
    fi
    if [[ "$sn" == "N/A" ]]; then
        sn="$(safe_lspci_serial "$pci")"
        [[ -z "${sn:-}" ]] && sn="N/A"
    fi

    # Part number logic
    pn="N/A"
    pn="$(pn_from_vpd "$pci" || true)"
    [[ -z "${pn:-}" ]] && pn="N/A"
    if [[ "$pn" == "N/A" ]]; then
        pn="$(safe_lspci_partnum "$pci")"
        [[ -z "${pn:-}" ]] && pn="N/A"
    fi

    # Type detection
    type="Generic-NIC"
    if echo "$desc" | grep -qi "BlueField-3"; then
        type="SuperNIC"
        [[ "$pmac" != "N/A" && "$cmac" != "$pmac" ]] && type="SmartNIC"
    fi

    # Sibling promotion
    if [[ "$type" == "SuperNIC" ]]; then
        slot="${pci%.*}"
        for sibpath in /sys/bus/pci/devices/"${slot}".*; do
            [[ -e "$sibpath" ]] || continue
            sibpci="$(basename "$sibpath")"
            sibiface="$(grep -m1 "^${sibpci}|" "$MAP_FILE" 2>/dev/null | cut -d'|' -f2 || true)"
            [[ -z "${sibiface:-}" ]] && continue
            s_pmac="$(safe_ethtool_perm_mac "$sibiface")"
            [[ -z "${s_pmac:-}" ]] && s_pmac="N/A"
            s_cmac="$(sysread "/sys/class/net/$sibiface/address")"
            [[ -z "${s_cmac:-}" ]] && s_cmac="N/A"
            if [[ "$s_pmac" != "N/A" && "$s_cmac" != "$s_pmac" ]]; then
                type="SmartNIC"
                break
            fi
        done
    fi

    # Update widths
    for var in iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
        val="${!var}"
        len=${#val}
        w_var="w_$var"
        if [[ "$len" -gt "${!w_var}" ]]; then
            printf -v "$w_var" '%s' "$len"
        fi
    done

    echo "$iface|$func|$p_pci|$p_iface|$bond|$cmac|$pmac|$sn|$pn|$fw|$stat|$type|$pci|$desc" >> "$TMP_DATA"

    {
        csv_escape "$HOSTNAME_SHORT"; printf ','
        csv_escape "$iface"; printf ','
        csv_escape "$func"; printf ','
        csv_escape "$p_pci"; printf ','
        csv_escape "$p_iface"; printf ','
        csv_escape "$bond"; printf ','
        csv_escape "$cmac"; printf ','
        csv_escape "$pmac"; printf ','
        csv_escape "$sn"; printf ','
        csv_escape "$pn"; printf ','
        csv_escape "$fw"; printf ','
        csv_escape "$stat"; printf ','
        csv_escape "$type"; printf ','
        csv_escape "$pci"; printf ','
        csv_escape "$desc"
        printf '\n'
    } >> "$TMP_CSV"

    count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
    echo "No NICs found under /sys/class/net (after filtering)." >&2
    exit 1
fi

# --- 3) OUTPUT ---
if [[ -n "$OUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUT_FILE")"
    cat "$TMP_CSV" > "$OUT_FILE"
fi

if [[ "$PRINT_STDOUT" == "true" ]]; then
    if [[ "$OUTPUT_CSV" == "true" ]]; then
        cat "$TMP_CSV"
    else
        fmt="%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_p_pci+2))s %-$(($w_p_iface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %-$(($w_stat+2))b %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n"
        printf "$fmt" "IFACE" "FUNC" "PARENT PCI" "PARENT IFACE" "BOND" "CURR MAC" "PERM MAC" "SERIAL" "PN" "FW" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"

        while IFS='|' read -r iface func p_pci p_iface bond cmac pmac sn pn fw stat type pci desc; do
            [[ "$stat" == "up" ]] && s_disp="${GREEN}UP${NC}" || s_disp="${RED}DOWN${NC}"

            printf "%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_p_pci+2))s %-$(($w_p_iface+2))s %-$(($w_bond+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_pn+2))s %-$(($w_fw+2))s %b" \
                "$iface" "$func" "$p_pci" "$p_iface" "$bond" "$cmac" "$pmac" "$sn" "$pn" "$fw" "$s_disp"
            printf "%$(( (w_stat + 2) - ${#stat} ))s%-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n" "" "$type" "$pci" "$desc"
        done < "$TMP_DATA"
    fi
fi
