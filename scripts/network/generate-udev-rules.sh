#!/usr/bin/env bash
# generate-udev-rules.sh - Version 2.5 (Pure Bash Edition)
# No Python dependency. Handles NVIDIA Rail/Plane naming.

set -u

# --- CONFIGURATION ---
BASE_DIR="/cm/shared/scripts/net-mapping"
OUT_DIR="${BASE_DIR}/out/udev_rules/latest"
INPUT_CSV="${BASE_DIR}/out/manual_inventory.csv"

# Colors
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

mkdir -p "$OUT_DIR"

# --- 1. PRE-FLIGHT & SANITIZATION ---
if [[ ! -f "$INPUT_CSV" ]]; then
    echo -e "${RED}[ERROR] Inventory database not found!${NC}"
    exit 1
fi

# Clean the CSV of quotes and carriage returns for processing
CLEAN_CSV="/tmp/ndt_inventory_clean.csv"
tr -d '\r"' < "$INPUT_CSV" > "$CLEAN_CSV"

# --- 2. QUERY K8S NODES ---
echo -e "${BLUE}[INFO] Querying Kubernetes for worker node status...${NC}"
RAW_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=)
mapfile -t ALL_NODES < <(echo "$RAW_NODES" | awk 'NR>1 {print $1}')

# --- 3. SELECTION MENU ---
echo -e "\n${CYAN}Select Nodes for NVIDIA Rule Generation:${NC}"
for i in "${!ALL_NODES[@]}"; do
    node="${ALL_NODES[$i]}"
    if grep -q "^${node}," "$CLEAN_CSV" 2>/dev/null; then
        hint="${GREEN}(In Inventory)${NC}"
    else
        hint="${RED}(Missing Data)${NC}"
    fi
    printf "%2d) %-20s %b\n" "$((i+1))" "$node" "$hint"
done
read -p ">> Selection: " choice

# Handle 'a' or specific numbers
SELECTED_NODES=()
[[ "$choice" == "a" ]] && SELECTED_NODES=("${ALL_NODES[@]}") || {
    IFS=',' read -ra ADDR <<< "$choice"
    for idx in "${ADDR[@]}"; do SELECTED_NODES+=("${ALL_NODES[$((idx-1))]}"); done
}

# --- 4. RULE GENERATION LOGIC (PURE BASH) ---
for node in "${SELECTED_NODES[@]}"; do
    # Skip if no data
    if ! grep -q "^${node}," "$CLEAN_CSV"; then continue; fi

    output_file="${OUT_DIR}/${node}_cluster.rules"
    echo -e "${BLUE}[GEN] Creating rules for $node...${NC}"

    {
        echo "# NVIDIA SuperNIC Configuration for $node"
        echo "# Generated: $(date)"
        echo ""
    } > "$output_file"

    # Extract PCI IDs for this node and sort them numerically
    # This ensures Rail 0 is always the lowest PCI slot
    mapfile -t PCI_LIST < <(grep "^${node}," "$CLEAN_CSV" | cut -d',' -f3 | sort)

    rail=0
    for pci in "${PCI_LIST[@]}"; do
        # NET Rules
        echo "ACTION==\"add\", SUBSYSTEM==\"net\", KERNELS==\"$pci\", NAME=\"eth_r${rail}_p0\"" >> "$output_file"
        
        # RDMA Rules (using the specific rdma_rename program as per guide)
        echo "ACTION==\"add\", SUBSYSTEM==\"infiniband\", KERNELS==\"$pci\", PROGRAM=\"/usr/bin/rdma_rename %k NAME_FIXED roce_r${rail}_p0\"" >> "$output_file"
        
        ((rail++))
    done
done

echo -e "\n${GREEN}[SUCCESS] NVIDIA Rules Generated in $OUT_DIR${NC}"
rm -f "$CLEAN_CSV"
