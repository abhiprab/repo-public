#!/usr/bin/env bash
# generate-udev-rules.sh - Version 2.7
# Logic: SuperNICs => Renamed to eth_rX | SmartNICs => Anchored to current name

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out/udev_rules/latest"
INPUT_CSV="${BASE_DIR}/out/manual_inventory.csv"

# Colors
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

mkdir -p "$OUT_DIR"

# --- 1. SANITIZATION ---
CLEAN_CSV="/tmp/ndt_inventory_clean.csv"
tr -d '\r"' < "$INPUT_CSV" > "$CLEAN_CSV"

# --- 2. NODE STATUS QUERY ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker nodes...${NC}"
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

echo -e "\n${CYAN}Select Nodes for Hybrid UDEV Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    printf "%2d) %-20s\n" "$((i+1))" "$node"
done

read -p ">> Selection: " choice
[[ "$choice" == "a" ]] && SELECTED_NODES=("${ALL_NODES[@]}") || SELECTED_NODES=("${ALL_NODES[$((choice-1))]}")

# --- 3. HYBRID RULE GENERATION ---
for node in "${SELECTED_NODES[@]}"; do
    output_file="${OUT_DIR}/${node}_cluster.rules"
    echo -e "${BLUE}[GEN] Processing $node...${NC}"

    {
        echo "# Hybrid NIC Configuration for $node"
        echo "# SuperNICs: Renamed to Rail/Plane (Topology Network)"
        echo "# SmartNICs: Anchored to current names (N-S Network)"
        echo ""
    } > "$output_file"

    # --- PART A: SuperNICs (Rail-Based Renaming) ---
    mapfile -t SUPER_PCI_LIST < <(grep "^${node}," "$CLEAN_CSV" | grep "SuperNIC" | cut -d',' -f14 | sort)
    
    rail=0
    for pci in "${SUPER_PCI_LIST[@]}"; do
        echo -e "  -> Found SuperNIC at $pci (Naming: eth_r${rail}_p0)"
        echo "ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"$pci\", NAME=\"eth_r${rail}_p0\"" >> "$output_file"
        # Optional: Add RDMA if needed, otherwise skip
        ((rail++))
    done

    # --- PART B: SmartNICs (Persistence/Same Name) ---
    # We find SmartNICs, extract their Current Name (Col 2) and PCI (Col 14)
    grep "^${node}," "$CLEAN_CSV" | grep "SmartNIC" | while IFS=',' read -r host iface func parent pif bond mac pmac serial pn fw status type pci desc; do
        echo -e "  -> Found SmartNIC at $pci (Anchoring: $iface)"
        echo "ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"$pci\", NAME=\"$iface\"" >> "$output_file"
    done

done

echo -e "\n${GREEN}[SUCCESS] Hybrid rules generated in $OUT_DIR${NC}"
rm -f "$CLEAN_CSV"
