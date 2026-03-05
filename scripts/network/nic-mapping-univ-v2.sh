#!/bin/bash
# nic-mapping-univ-v13.sh

# Color Definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Header: Added SERIAL column (width 15)
printf "%-15s %-20s %-20s %-15s %-10s %-12s %-15s %-50s\n" "IFACE" "CURR MAC" "PERM MAC" "SERIAL" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"
printf "%-15s %-20s %-20s %-15s %-10s %-12s %-15s %-50s\n" "---------------" "-------------------" "-------------------" "---------------" "----------" "------------" "---------------" "--------------------------------------------------"

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

    # 3. Get Serial Number (NVIDIA/Mellanox via mstvpd)
    PCI_FULL=$(basename "$(readlink -f "$dev/device")")
    # mstvpd works best on the physical function (.0). We trim the function for the lookup if needed.
    SERIAL=$(mstvpd "$PCI_FULL" 2>/dev/null | grep "SN:" | awk '{print $2}')
    
    # Fallback for Generic NICs or if mstvpd is missing
    if [ -z "$SERIAL" ]; then
        SERIAL=$(lspci -vv -s "$PCI_FULL" 2>/dev/null | grep "Serial number" | awk '{print $4}')
    fi
    [ -z "$SERIAL" ] && SERIAL="N/A"

    # 4. Get Status with Color Logic
    RAW_STATUS=$(cat "$dev/operstate")
    if [ "$RAW_STATUS" = "up" ]; then
        STATUS_DISPLAY="${GREEN}UP${NC}"
        STATUS_PLAIN="UP"
    else
        STATUS_DISPLAY="${RED}DOWN${NC}"
        STATUS_PLAIN="DOWN"
    fi

    # 5. Get Hardware Details
    SUB_DEV=$(cat "$dev/device/subsystem_device" 2>/dev/null)
    DESC=$(lspci -s "$PCI_FULL" | cut -d':' -f3 | sed 's/^[ \t]*//')

    # 6. Type Logic (Mellanox BlueField-3 specific)
    if echo "$DESC" | grep -iq "BlueField-3"; then
        case "$SUB_DEV" in
            "0x0020"|"0x0009") TYPE="SmartNIC" ;;
            "0x0039"|"0x0021") TYPE="SuperNIC" ;;
            *) TYPE="BlueField-3" ;;
        esac
    else
        TYPE="Generic-NIC"
    fi

    # 7. Printing with Alignment
    # Print IFACE, MACs, and SERIAL
    printf "%-15s %-20s %-20s %-15s %b" "$IFACE" "$CURR_MAC" "$PERM_MAC" "$SERIAL" "$STATUS_DISPLAY"

    # Calculate padding for Status (Total column width 10 minus length of "UP" or "DOWN")
    PAD_LEN=$(( 10 - ${#STATUS_PLAIN} ))
    printf "%${PAD_LEN}s" ""

    printf "%-12s %-15s %-50s\n" "$TYPE" "$PCI_FULL" "$DESC"
done
