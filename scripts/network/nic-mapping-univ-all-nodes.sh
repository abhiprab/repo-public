#!/usr/bin/env bash
set -euo pipefail

DATE_STR=$(date +%F-%H%M%S)
OUT_DIR="/cm/shared/scripts/net-mapping/out"
TEMP_DIR="${OUT_DIR}/tmp_raw"
SCRIPT_ON_NODE="/cm/shared/scripts/net-mapping/nic-mapping-univ.sh"

mkdir -p "$TEMP_DIR"

run_node() {
    local node="$1"
    local node_csv="${TEMP_DIR}/${node}-${DATE_STR}.csv"
    local node_err="${TEMP_DIR}/${node}-${DATE_STR}.err"
    local script_path="${SCRIPT_ON_NODE}"

    echo -e "${BLUE}[INFO]${NC} (${node}) capturing via SSH..."

    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node" \
        "sudo -n $script_path --csv --print" > "$node_csv" 2>"$node_err"; then

        sed -i 's/\r//g' "$node_csv"

        if [[ -s "$node_csv" ]] && head -n 1 "$node_csv" | grep -q '^HOSTNAME,IFACE,FUNC,'; then
            echo -e "${GREEN}[SUCCESS]${NC} (${node}) captured."
            rm -f "$node_err"
        else
            echo -e "${RED}[ERROR]${NC} (${node}) command ran but output is invalid."
            echo "  First line: $(head -n 1 "$node_csv" 2>/dev/null || true)"
            [[ -s "$node_err" ]] && sed 's/^/  /' "$node_err"
            rm -f "$node_csv"
        fi
    else
        if [[ -s "$node_err" ]]; then
            if grep -qi "a password is required\|sudo:" "$node_err"; then
                echo -e "${RED}[ERROR]${NC} (${node}) sudo requires a password."
            else
                echo -e "${RED}[ERROR]${NC} (${node}) SSH/remote command failed."
                sed 's/^/  /' "$node_err"
            fi
        else
            echo -e "${RED}[ERROR]${NC} (${node}) SSH connection failed."
        fi
        rm -f "$node_csv"
    fi
}

export -f run_node
export SCRIPT_ON_NODE TEMP_DIR DATE_STR BLUE GREEN RED NC

NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')
printf "%s\n" $NODES | xargs -I{} -P 8 bash -c 'run_node "{}"'

echo -e "${BLUE}[INFO] Finalizing merge...${NC}"
shopt -s nullglob
files=( "$TEMP_DIR"/*"${DATE_STR}".csv )

if [[ ${#files[@]} -gt 0 ]]; then
    head -n 1 "${files[0]}" > "${OUT_DIR}/manual_inventory.csv"
    for f in "${files[@]}"; do
        tail -n +2 "$f" >> "${OUT_DIR}/manual_inventory.csv"
    done
    echo -e "${GREEN}[OK] Merged ${#files[@]} nodes into ${OUT_DIR}/manual_inventory.csv${NC}"
else
    echo -e "${RED}[ERROR] No data streamed back to jumpbox.${NC}"
    exit 1
fi
