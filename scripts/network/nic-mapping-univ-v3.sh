#!/bin/bash
# nic-mapping-univ-v16.sh

# Color Definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Temporary file to store gathered data
TMP_DATA=$(mktemp)

# 1. Gather Data and Find Max Widths
# Initialize widths with header lengths
w_iface=5; w_func=4; w_parent=9; w_cmac=8; w_pmac=8; w_sn=6; w_stat=6; w_type=4; w_pci=3; w_desc=17

for dev in /sys/class/net/*; do
    [ -e "$dev/device" ] || continue
    iface=$(basename "$dev")
    [[ "$iface" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb ]] && continue

    # Identify PF/VF
    dev_path="/sys/class/net/$iface/device"
    if [ -e "$dev_path/physfn" ]; then
        func="VF"; parent=$(basename "$(readlink -f "$dev_path/physfn")")
    else
        func="PF"; parent="N/A"
    fi

    # Network & Hardware Details
    cmac=$(cat "$dev/address")
    pmac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $3}')
    [ -z "$pmac" ] && pmac="N/A"
    
    pci=$(basename "$(readlink -f "$dev/device")")
    sn=$(mstvpd "$pci" 2>/dev/null | grep "SN:" | awk '{print $2}')
    [ -z "$sn" ] && sn=$(lspci -vv -s "$pci" 2>/dev/null | grep "Serial number" | awk '{print $4}')
    [ -z "$sn" ] && sn="N/A"

    stat=$(cat "$dev/operstate")
    
    desc=$(lspci -s "$pci" | cut -d':' -f3 | sed 's/^[ \t]*//')
    sub_dev=$(cat "$dev/device/subsystem_device" 2>/dev/null)
    if echo "$desc" | grep -iq "BlueField-3"; then
        [[ "$sub_dev" =~ 0x0020|0x0009 ]] && type="SmartNIC" || type="SuperNIC"
    else
        type="Generic-NIC"
    fi

    # Update Max Widths
    (( ${#iface} > w_iface )) && w_iface=${#iface}
    (( ${#func} > w_func )) && w_func=${#func}
    (( ${#parent} > w_parent )) && w_parent=${#parent}
    (( ${#cmac} > w_cmac )) && w_cmac=${#cmac}
    (( ${#pmac} > w_pmac )) && w_pmac=${#pmac}
    (( ${#sn} > w_sn )) && w_sn=${#sn}
    (( ${#stat} > w_stat )) && w_stat=${#stat}
    (( ${#type} > w_type )) && w_type=${#type}
    (( ${#pci} > w_pci )) && w_pci=${#pci}
    (( ${#desc} > w_desc )) && w_desc=${#desc}

    # Store for second pass
    echo "$iface|$func|$parent|$cmac|$pmac|$sn|$stat|$type|$pci|$desc" >> "$TMP_DATA"
done

# 2. Print Header with Dynamic Widths
fmt="%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s %-$(($w_stat+2))b %-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n"

printf "$fmt" "IFACE" "FUNC" "PARENT PF" "CURR MAC" "PERM MAC" "SERIAL" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"

# 3. Print Rows
while IFS='|' read -r iface func parent cmac pmac sn stat type pci desc; do
    if [ "$stat" = "up" ]; then s_disp="${GREEN}UP${NC}"; else s_disp="${RED}DOWN${NC}"; fi
    
    # We use a trick for the color column to keep alignment
    printf "%-$(($w_iface+2))s %-$(($w_func+2))s %-$(($w_parent+2))s %-$(($w_cmac+2))s %-$(($w_pmac+2))s %-$(($w_sn+2))s " \
           "$iface" "$func" "$parent" "$cmac" "$pmac" "$sn"
    
    printf "%b" "$s_disp"
    # Pad the rest of the status column
    pad=$(( (w_stat + 2) - ${#stat} ))
    printf "%${pad}s" ""
    
    printf "%-$(($w_type+2))s %-$(($w_pci+2))s %-$(($w_desc))s\n" "$type" "$pci" "$desc"
done < "$TMP_DATA"

rm "$TMP_DATA"
