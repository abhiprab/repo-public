#!/bin/bash
# universal-nic-mapping-v11.sh

# Color Definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Header: Added PERM MAC
printf "%-10s %-20s %-20s %-10s %-12s %-15s %-50s\n" "IFACE" "CURR MAC" "PERM MAC" "STATUS" "TYPE" "PCI" "MODEL DESCRIPTION"
printf "%-10s %-20s %-20s %-10s %-12s %-15s %-50s\n" "----------" "-------------------" "-------------------" "----------" "------------" "---------------" "--------------------------------------------------"

for dev in /sys/class/net/*; do
    [ -e "$dev/device" ] || continue
    IFACE=$(basename "$dev")
    [[ "$IFACE" =~ ^lo$|^docker|^veth|^br-|^bond|^tun|^usb ]] && continue

    # 1. Get Current MAC Address
    CURR_MAC=$(cat "$dev/address")
    
    # 2. Get Permanent MAC Address
    # We check the sysfs 'phys_port_name' or 'bonding_slave/perm_hwaddr' 
    # but the most universal way for physical NICs is reading the 'address' 
    # if it hasn't been spoofed, or using ethtool -P.
    PERM_MAC=$(ethtool -P "$IFACE" 2>/dev/null | awk '{print $3}')
    
    # Fallback if ethtool -P fails (e.g., virtual interfaces or certain drivers)
    if [ -z "$PERM_MAC" ] || [ "$PERM_MAC" = "00:00:00:00:00:00" ]; then
        PERM_MAC="Same as Curr"
    fi

    RAW_STATUS=$(cat "$dev/operstate")
    
    if [ "$RAW_STATUS" = "up" ]; then
        STATUS_COLOR="${GREEN}UP${NC}"
        STATUS_PLAIN="UP"
    else
        STATUS_COLOR="${RED}DOWN${NC}"
        STATUS_PLAIN="DOWN"
    fi

    PCI_FULL=$(basename "$(readlink -f "$dev/device")")
    PCI_ID=$(echo "$PCI_FULL" | cut -d'.' -f1)
    SUB_DEV=$(cat "$dev/device/subsystem_device")
    DESC=$(lspci -s "$PCI_FULL" | cut -d':' -f3 | sed 's/^[ \t]*//')

    # Logic for NIC Type (SmartNIC vs SuperNIC)
    if echo "$DESC" | grep -iq "BlueField-3"; then
        case "$SUB_DEV" in
            "0x0020"|"0x0009") TYPE="SmartNIC" ;;
            "0x0039"|"0x0021") TYPE="SuperNIC" ;;
            *)
                PORT_COUNT=$(lspci -d 15b3: | grep -c "^${PCI_ID}")
                if [ "$PORT_COUNT" -gt 1 ]; then TYPE="SmartNIC"; else TYPE="SuperNIC"; fi
                ;;
        esac
    elif echo "$DESC" | grep -iq "ConnectX-6 Lx"; then
        TYPE="NIC"
    else
        TYPE="Generic-NIC"
    fi

    # Print Row
    printf "%-10s %-20s %-20s %b" "$IFACE" "$CURR_MAC" "$PERM_MAC" "$STATUS_COLOR"
    
    # Pad Status for Alignment
    PAD_LEN=$(( 10 - ${#STATUS_PLAIN} ))
    printf "%${PAD_LEN}s" "" 

    printf "%-12s %-15s %-50s\n" "$TYPE" "$PCI_FULL" "$DESC"
done
