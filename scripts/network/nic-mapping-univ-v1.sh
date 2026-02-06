#!/bin/bash
# nic-mapping-univ-v12.sh

# Color Definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Header: Widened IFACE to 15 and PERM MAC to 20
printf "%-15s %-20s %-20s %-10s %-12s %-15s %-50s\n" "IFACE" "CURR MAC" "PERM MAC" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"
printf "%-15s %-20s %-20s %-10s %-12s %-15s %-50s\n" "---------------" "-------------------" "-------------------" "----------" "------------" "---------------" "--------------------------------------------------"

for dev in /sys/class/net/*; do
    [ -e "$dev/device" ] || continue
    IFACE=$(basename "$dev")
    # Filter out virtual/logical interfaces
    [[ "$IFACE" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb ]] && continue

    # 1. Get Current MAC
    CURR_MAC=$(cat "$dev/address")
    
    # 2. Get Permanent MAC
    PERM_MAC=$(ethtool -P "$IFACE" 2>/dev/null | awk '{print $3}')
    [ -z "$PERM_MAC" ] && PERM_MAC="N/A"

    # 3. Get Status with Color Logic
    RAW_STATUS=$(cat "$dev/operstate")
    if [ "$RAW_STATUS" = "up" ]; then
        STATUS_DISPLAY="${GREEN}UP${NC}"
        STATUS_PLAIN="UP"
    else
        STATUS_DISPLAY="${RED}DOWN${NC}"
        STATUS_PLAIN="DOWN"
    fi

    # 4. Get Hardware Details
    PCI_FULL=$(basename "$(readlink -f "$dev/device")")
    SUB_DEV=$(cat "$dev/device/subsystem_device" 2>/dev/null)
    DESC=$(lspci -s "$PCI_FULL" | cut -d':' -f3 | sed 's/^[ \t]*//')

    # 5. Type Logic (Mellanox BlueField-3 specific)
    if echo "$DESC" | grep -iq "BlueField-3"; then
        case "$SUB_DEV" in
            "0x0020"|"0x0009") TYPE="SmartNIC" ;;
            "0x0039"|"0x0021") TYPE="SuperNIC" ;;
            *) TYPE="BlueField-3" ;;
        esac
    else
        TYPE="Generic-NIC"
    fi

    # 6. Printing with Alignment
    # We print IFACE, MACs normally. 
    # For STATUS, we print the color version, then manually pad based on the PLAIN text length.
    printf "%-15s %-20s %-20s %b" "$IFACE" "$CURR_MAC" "$PERM_MAC" "$STATUS_DISPLAY"
    
    # Calculate padding for Status (Total column width 10 minus length of "UP" or "DOWN")
    PAD_LEN=$(( 10 - ${#STATUS_PLAIN} ))
    printf "%${PAD_LEN}s" "" 

    printf "%-12s %-15s %-50s\n" "$TYPE" "$PCI_FULL" "$DESC"
done
