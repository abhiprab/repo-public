#!/usr/bin/env bash
#
# collect-topology.sh - Collect system topology information for NVIDIA GPU
# and Mellanox NIC environments.
#
# Collects: system info, PCI topology, Mellanox NICs, NVIDIA GPUs, NUMA topology.
# Designed to continue on failure — missing tools or inaccessible sysfs paths
# are logged and skipped.

SCRIPT_VERSION="1.0.0"

# Vendor IDs for sysfs comparison (with 0x prefix)
MELLANOX_VENDOR_ID="0x15b3"
NVIDIA_VENDOR_ID="0x10de"

# Vendor IDs for lspci -d filter (without 0x prefix)
MELLANOX_PCI_ID="15b3"
NVIDIA_PCI_ID="10de"

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

OUTPUT_DIR=""
OUTPUT_FILE=""

# =============================================================================
# Argument parsing
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Collect system topology information for NVIDIA GPU and Mellanox NIC environments.

Options:
  --output-dir <dir>    Save report to a timestamped file in <dir>
  --help                Show this help message
  --version             Show script version

Examples:
  sudo ./collect-topology.sh
  sudo ./collect-topology.sh --output-dir /tmp
  sudo ./collect-topology.sh 2>&1 | tee report.txt

Report file naming: topology-report-<hostname>-<YYYYMMDD-HHMMSS>.txt
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        --version)
            echo "collect-topology.sh version $SCRIPT_VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# =============================================================================
# Output setup
# =============================================================================

if [[ -n "$OUTPUT_DIR" ]]; then
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "Error: output directory '$OUTPUT_DIR' does not exist."
        exit 1
    fi
    OUTPUT_FILE="${OUTPUT_DIR}/topology-report-${HOSTNAME_SHORT}-${TIMESTAMP}.txt"
fi

# Do not exit on command failures
set +e

# =============================================================================
# Utility functions
# =============================================================================

print_banner() {
    local title="$1"
    echo ""
    echo "========================================================================"
    echo "  $title"
    echo "========================================================================"
    echo ""
}

print_sub_banner() {
    local title="$1"
    echo ""
    echo "--- $title ---"
    echo ""
}

# Run a command, printing what is being executed and logging failures.
# Always returns 0 so the script never exits on failure.
run_cmd() {
    local description="$1"
    shift
    local cmd="$*"

    print_sub_banner "$description"
    echo "[CMD] $cmd"
    echo ""

    eval "$cmd" 2>&1
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        echo ""
        echo "[WARNING] Command failed with exit code $rc: $cmd"
    fi
    echo ""
    return 0
}

# Like run_cmd but first checks if the binary is available.
# Prints [SKIP] if the binary is not found.
run_cmd_if_available() {
    local description="$1"
    local binary="$2"
    shift 2
    local cmd="$*"

    if ! command -v "$binary" &>/dev/null; then
        print_sub_banner "$description"
        echo "[SKIP] '$binary' is not installed or not in PATH"
        echo ""
        return 0
    fi

    run_cmd "$description" "$cmd"
}

# Return list of network interface names whose vendor is Mellanox (0x15b3).
get_mellanox_netdevs() {
    local devs=()
    for dev_path in /sys/class/net/*/device/vendor; do
        if [[ -f "$dev_path" ]]; then
            local vendor
            vendor="$(cat "$dev_path" 2>/dev/null)"
            if [[ "$vendor" == "$MELLANOX_VENDOR_ID" ]]; then
                local dev_name
                dev_name="$(basename "$(dirname "$(dirname "$dev_path")")")"
                devs+=("$dev_name")
            fi
        fi
    done
    echo "${devs[@]}"
}

# Return PCI addresses of all Mellanox (15b3) devices via lspci.
get_mellanox_pci_addrs() {
    if ! command -v lspci &>/dev/null; then
        return 0
    fi
    lspci -D -d "${MELLANOX_PCI_ID}:" 2>/dev/null | awk '{print $1}'
}

# Return PCI addresses of NVIDIA GPU-class devices.
get_nvidia_gpu_pci_addrs() {
    if ! command -v lspci &>/dev/null; then
        return 0
    fi
    lspci -D -d "${NVIDIA_PCI_ID}:" 2>/dev/null \
        | grep -iE '3D controller|VGA compatible|Processing accelerator' \
        | awk '{print $1}'
}

# Read a sysfs attribute, return "N/A" if missing.
read_sysfs() {
    local path="$1"
    if [[ -f "$path" ]]; then
        cat "$path" 2>/dev/null
    else
        echo "N/A"
    fi
}

# =============================================================================
# Collection functions
# =============================================================================

collect_report_header() {
    print_banner "TOPOLOGY COLLECTION REPORT"
    echo "Hostname:       $(hostname -f 2>/dev/null || hostname)"
    echo "Date:           $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Kernel:         $(uname -r)"
    echo "Script Version: $SCRIPT_VERSION"
    echo "User:           $(whoami) ($(id))"
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "Output File:    $OUTPUT_FILE"
    fi
    echo ""

    if [[ $(id -u) -ne 0 ]]; then
        echo "[WARNING] Not running as root. Some commands may fail or return incomplete data."
        echo ""
    fi
}

# ---- Section 1: System Information ------------------------------------------

collect_system_info() {
    print_banner "SECTION 1: SYSTEM INFORMATION"

    run_cmd "Product Name" "cat /sys/class/dmi/id/product_name"
    run_cmd_if_available "Detailed System Info (dmidecode)" "dmidecode" \
        "dmidecode -t system"
    run_cmd "OS Release" "cat /etc/os-release"
    run_cmd "Kernel Version" "uname -a"
    run_cmd_if_available "CPU/NUMA Layout (lscpu)" "lscpu" "lscpu"
}

# ---- Section 2: PCI Topology -----------------------------------------------

collect_pci_topology() {
    print_banner "SECTION 2: PCI TOPOLOGY"

    run_cmd_if_available "PCI Topology Tree (all devices)" "lspci" \
        "lspci -tv"
    run_cmd_if_available "Mellanox/NVIDIA NIC PCI Devices (detailed)" "lspci" \
        "lspci -nnn -vvv -d ${MELLANOX_PCI_ID}:"
    run_cmd_if_available "NVIDIA GPU PCI Devices (detailed)" "lspci" \
        "lspci -nnn -vvv -d ${NVIDIA_PCI_ID}:"
}

# ---- Section 3: Network Devices (Mellanox NICs) ----------------------------

collect_network_devices() {
    print_banner "SECTION 3: NETWORK DEVICES (Mellanox NICs)"

    run_cmd "Network Interfaces (sysfs)" "ls -l /sys/class/net/"
    run_cmd_if_available "IP Link Show" "ip" "ip link show"

    local mlnx_devs
    mlnx_devs="$(get_mellanox_netdevs)"

    if [[ -n "$mlnx_devs" ]]; then
        echo "[INFO] Discovered Mellanox NICs (via sysfs): $mlnx_devs"
        echo ""

        for dev in $mlnx_devs; do
            print_sub_banner "Mellanox NIC: $dev"

            echo "[INFO] sysfs attributes for $dev:"
            for attr in vendor device subsystem_vendor subsystem_device; do
                echo "  $attr = $(read_sysfs "/sys/class/net/$dev/device/$attr")"
            done
            echo ""

            # Resolve PCI address
            local pci_addr=""
            if [[ -L "/sys/class/net/$dev/device" ]]; then
                pci_addr="$(basename "$(readlink -f "/sys/class/net/$dev/device")")"
            fi

            if [[ -n "$pci_addr" ]]; then
                echo "[INFO] PCIe link info for $dev (PCI $pci_addr):"
                for attr in current_link_speed current_link_width max_link_speed max_link_width; do
                    echo "  $attr = $(read_sysfs "/sys/bus/pci/devices/$pci_addr/$attr")"
                done
                echo ""
            fi

            run_cmd_if_available "Driver info for $dev (ethtool -i)" "ethtool" \
                "ethtool -i $dev"
            run_cmd_if_available "Link info for $dev (ethtool)" "ethtool" \
                "ethtool $dev 2>&1 | head -20"
            run_cmd_if_available "Mellanox QoS config for $dev" "mlnx_qos" \
                "mlnx_qos -i $dev"
        done
    else
        echo "[INFO] No Mellanox network devices found via sysfs."
        echo ""
    fi

    # Discover Mellanox PCI devices via lspci (catches devices without a netdev)
    local mlnx_pci_addrs
    mlnx_pci_addrs="$(get_mellanox_pci_addrs)"
    if [[ -n "$mlnx_pci_addrs" ]]; then
        print_sub_banner "All Mellanox PCI Devices (via lspci)"
        for addr in $mlnx_pci_addrs; do
            local desc
            desc="$(lspci -s "${addr#*:}" -D 2>/dev/null | head -1)"
            echo "[INFO] Mellanox PCI $addr:"
            echo "  description = $desc"
            for attr in current_link_speed current_link_width max_link_speed max_link_width; do
                echo "  $attr = $(read_sysfs "/sys/bus/pci/devices/$addr/$attr")"
            done
            echo ""
        done
    fi

    # Additional Mellanox/RDMA tools
    run_cmd_if_available "InfiniBand to NetDev Mapping" "ibdev2netdev" \
        "ibdev2netdev"
    run_cmd_if_available "RDMA Link Show" "rdma" \
        "rdma link show"
}

# ---- Section 4: NVIDIA GPUs ------------------------------------------------

collect_nvidia_gpus() {
    print_banner "SECTION 4: NVIDIA GPUs"

    run_cmd_if_available "GPU Detailed Info" "nvidia-smi" \
        "nvidia-smi -q"
    run_cmd_if_available "GPU Topology Matrix" "nvidia-smi" \
        "nvidia-smi topo -m"
    run_cmd_if_available "GPU Topology Matrix (Physical)" "nvidia-smi" \
        "nvidia-smi topo -mp"
    run_cmd_if_available "GPU Topology P2P" "nvidia-smi" \
        "nvidia-smi topo -p"

    # PCIe link info for each GPU
    local gpu_addrs
    gpu_addrs="$(get_nvidia_gpu_pci_addrs)"

    if [[ -n "$gpu_addrs" ]]; then
        print_sub_banner "GPU PCIe Link Details"
        for addr in $gpu_addrs; do
            echo "[INFO] GPU PCI $addr:"
            for attr in current_link_speed current_link_width max_link_speed max_link_width; do
                echo "  $attr = $(read_sysfs "/sys/bus/pci/devices/$addr/$attr")"
            done
            echo ""
        done
    fi
}

# ---- Section 5: NUMA Topology ----------------------------------------------

collect_numa_topology() {
    print_banner "SECTION 5: NUMA TOPOLOGY"

    run_cmd_if_available "NUMA Policy" "numactl" "numactl --show"
    run_cmd_if_available "NUMA Hardware Info" "numactl" "numactl --hardware"

    # Per-device NUMA affinity for Mellanox devices
    print_sub_banner "NUMA Node Affinity: Mellanox Devices"

    # Try netdev-based discovery first
    local mlnx_devs
    mlnx_devs="$(get_mellanox_netdevs)"
    if [[ -n "$mlnx_devs" ]]; then
        for dev in $mlnx_devs; do
            local pci_addr=""
            if [[ -L "/sys/class/net/$dev/device" ]]; then
                pci_addr="$(basename "$(readlink -f "/sys/class/net/$dev/device")")"
            fi
            if [[ -n "$pci_addr" ]]; then
                run_cmd "NUMA node for $dev (PCI $pci_addr)" \
                    "cat /sys/bus/pci/devices/$pci_addr/numa_node"
            else
                echo "  $dev: PCI address not resolved"
            fi
        done
    fi

    # Also show all Mellanox PCI devices (catches IB/RDMA-only devices without netdev)
    local mlnx_pci_addrs
    mlnx_pci_addrs="$(get_mellanox_pci_addrs)"
    if [[ -n "$mlnx_pci_addrs" ]]; then
        for addr in $mlnx_pci_addrs; do
            local desc
            desc="$(lspci -s "${addr#*:}" -D 2>/dev/null | head -1)"
            run_cmd "NUMA node for Mellanox $addr ($desc)" \
                "cat /sys/bus/pci/devices/$addr/numa_node"
        done
    fi

    if [[ -z "$mlnx_devs" && -z "$mlnx_pci_addrs" ]]; then
        echo "  [INFO] No Mellanox devices found"
    fi
    echo ""

    # Per-device NUMA affinity for NVIDIA GPUs
    print_sub_banner "NUMA Node Affinity: NVIDIA GPUs"
    local gpu_addrs
    gpu_addrs="$(get_nvidia_gpu_pci_addrs)"
    if [[ -n "$gpu_addrs" ]]; then
        for addr in $gpu_addrs; do
            local desc
            desc="$(lspci -s "${addr#*:}" -D 2>/dev/null | head -1)"
            run_cmd "NUMA node for GPU $addr ($desc)" \
                "cat /sys/bus/pci/devices/$addr/numa_node"
        done
    else
        echo "  [INFO] No NVIDIA GPUs found"
    fi
    echo ""
}

# =============================================================================
# Report footer
# =============================================================================

collect_report_footer() {
    print_banner "END OF TOPOLOGY REPORT"
    echo "Completed at: $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "Report saved to: $OUTPUT_FILE"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    collect_report_header
    collect_system_info
    collect_pci_topology
    collect_network_devices
    collect_nvidia_gpus
    collect_numa_topology
    collect_report_footer
}

if [[ -n "$OUTPUT_FILE" ]]; then
    main "$@" 2>&1 | tee "$OUTPUT_FILE"
else
    main "$@"
fi
