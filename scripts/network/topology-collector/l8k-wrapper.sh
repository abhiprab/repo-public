#!/usr/bin/env bash
#
# k8s-topology-wrapper.sh
# Identifies unique server OEM/model combinations in a k8s cluster and runs
# collect-topology.sh exactly once per unique make/model.

set -euo pipefail

TOPOLOGY_SCRIPT=${1:-"collect-topology.sh"}
NAMESPACE=${NAMESPACE:-"default"}
DISCOVERY_IMAGE=${DISCOVERY_IMAGE:-"alpine:latest"}
COLLECTOR_IMAGE=${COLLECTOR_IMAGE:-"ubuntu:22.04"}
DISCOVERY_TIMEOUT_SECONDS=${DISCOVERY_TIMEOUT_SECONDS:-90}
JOB_TIMEOUT_SECONDS=${JOB_TIMEOUT_SECONDS:-300}
DISCOVERY_PARALLELISM=${DISCOVERY_PARALLELISM:-10}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
AUTO_CTX=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed "s/[^a-zA-Z0-9]/-/g"); CLUSTER_NAME=${CLUSTER_NAME:-$AUTO_CTX}
OUTPUT_DIR="${CLUSTER_NAME:+$CLUSTER_NAME-}topology-reports-$TIMESTAMP"
DISCOVERY_DIR="$OUTPUT_DIR/.discovery"
CONFIGMAP_NAME=""
NODE_SELECTOR=${NODE_SELECTOR:-"node-role.kubernetes.io/worker"}

declare -a JOB_NAMES=()
declare -a DISCOVERY_PODS=()

usage() {
    cat <<EOF
Usage: $0 [path-to-collect-topology.sh]

Environment overrides:
  NAMESPACE                  Kubernetes namespace to use (default: default)
  DISCOVERY_IMAGE            Image used for model discovery (default: alpine:latest)
  COLLECTOR_IMAGE            Image used for topology collection (default: ubuntu:22.04)
  DISCOVERY_TIMEOUT_SECONDS  Per-node discovery timeout (default: 90)
  JOB_TIMEOUT_SECONDS        Per-job completion timeout (default: 300)
  DISCOVERY_PARALLELISM      Max concurrent discovery pods (default: 10)
EOF
}

log_section() {
    echo ""
    echo "$1"
}

safe_resource_name() {
    local prefix="$1"
    local raw="$2"
    local hash suffix max_base_len sanitized trimmed

    hash=$(printf '%s' "$raw" | sha1sum | cut -c1-8)
    sanitized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//; s/\.+$//')
    if [[ -z "$sanitized" ]]; then
        sanitized="node"
    fi

    suffix="-$hash"
    max_base_len=$((63 - ${#prefix} - ${#suffix}))
    if (( max_base_len < 1 )); then
        echo "Error: resource prefix '$prefix' is too long to fit Kubernetes naming rules." >&2
        exit 1
    fi

    trimmed=$(printf '%s' "$sanitized" | cut -c1-"$max_base_len" | sed -E 's/[-.]+$//')
    if [[ -z "$trimmed" ]]; then
        trimmed="node"
    fi

    printf '%s%s%s\n' "$prefix" "$trimmed" "$suffix"
}

safe_path_component() {
    local raw="$1"
    local sanitized

    sanitized=$(printf '%s' "$raw" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    if [[ -z "$sanitized" ]]; then
        sanitized="Unknown"
    fi

    printf '%s\n' "$sanitized"
}

cleanup() {
    local resource

    if [[ ${#JOB_NAMES[@]} -gt 0 ]]; then
        for resource in "${JOB_NAMES[@]}"; do
            kubectl delete job "$resource" --namespace="$NAMESPACE" --wait=false >/dev/null 2>&1 || true
        done
    fi

    if [[ ${#DISCOVERY_PODS[@]} -gt 0 ]]; then
        for resource in "${DISCOVERY_PODS[@]}"; do
            kubectl delete pod "$resource" --namespace="$NAMESPACE" --wait=false >/dev/null 2>&1 || true
        done
    fi

    if [[ -n "$CONFIGMAP_NAME" ]]; then
        kubectl delete configmap "$CONFIGMAP_NAME" --namespace="$NAMESPACE" --wait=false >/dev/null 2>&1 || true
    fi

    rm -rf "$DISCOVERY_DIR"
}

wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= DISCOVERY_PARALLELISM )); do
        sleep 1
    done
}

discover_identity_for_node() {
    local node="$1"
    local pod_name="$2"
    local identity

    kubectl run "$pod_name" \
        --image="$DISCOVERY_IMAGE" \
        --restart=Never \
        --namespace="$NAMESPACE" \
        --command -- \
        sh -c 'vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true); product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true); printf "%s|%s\n" "${vendor:-Unknown_OEM}" "${product:-Unknown_Model}"' \
        --overrides='{
            "spec": {
                "nodeName": "'"$node"'",
                "tolerations": [{"operator": "Exists"}],
                "containers": [{
                    "name": "detect",
                    "image": "'"$DISCOVERY_IMAGE"'",
                    "command": ["sh", "-c", "vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true); product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true); printf \"%s|%s\\n\" \"${vendor:-Unknown_OEM}\" \"${product:-Unknown_Model}\""],
                    "volumeMounts": [{"name": "dmi", "mountPath": "/sys/class/dmi", "readOnly": true}]
                }],
                "volumes": [{"name": "dmi", "hostPath": {"path": "/sys/class/dmi"}}]
            }
        }' >/dev/null 2>&1 || {
        echo "Unknown_OEM|Unknown_Model|$node" >> "$DISCOVERY_DIR/map.txt"
        echo "  [WARNING] Failed to create discovery pod for node $node; using Unknown_OEM/Unknown_Model."
        touch "$DISCOVERY_DIR/failed_flag" && exit 1
    }

    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded --timeout="${DISCOVERY_TIMEOUT_SECONDS}s" "pod/$pod_name" --namespace="$NAMESPACE" >/dev/null 2>&1; then
        echo "Unknown_OEM|Unknown_Model|$node" >> "$DISCOVERY_DIR/map.txt"
        echo "  [WARNING] Discovery pod for node $node did not become ready within ${DISCOVERY_TIMEOUT_SECONDS}s; using Unknown_OEM/Unknown_Model."
        kubectl delete pod "$pod_name" --namespace="$NAMESPACE" --wait=false >/dev/null 2>&1 || true
        touch "$DISCOVERY_DIR/failed_flag" && exit 1
    fi

    identity=$(kubectl logs "$pod_name" --namespace="$NAMESPACE" 2>/dev/null | tr -d '\r' || true)
    identity=$(printf '%s' "$identity" | head -n1)
    if [[ -z "$identity" || "$identity" != *"|"* ]]; then
        identity="Unknown_OEM|Unknown_Model"
    fi

    echo "$identity|$node" >> "$DISCOVERY_DIR/map.txt"
    kubectl delete pod "$pod_name" --namespace="$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -f "$TOPOLOGY_SCRIPT" ]]; then
    echo "Error: Topology script '$TOPOLOGY_SCRIPT' not found."
    usage
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is required but not installed or not in PATH."
    exit 1
fi

echo "========================================================================"
echo " Kubernetes Topology Collection Wrapper"
echo "========================================================================"
echo "Namespace: $NAMESPACE"
echo "Output Directory: $OUTPUT_DIR"
mkdir -p "$DISCOVERY_DIR"
: > "$DISCOVERY_DIR/map.txt"

log_section "[1/4] Discovering hardware make/model across all nodes..."
NODES=$(kubectl get nodes -l "$NODE_SELECTOR" -o jsonpath='{.items[*].metadata.name}')
if [[ -z "$NODES" ]]; then
    echo "Error: No nodes found in the current Kubernetes context."
    exit 1
fi

for NODE in $NODES; do
    POD_NAME=$(safe_resource_name "discover-hw-" "$NODE")
    DISCOVERY_PODS+=("$POD_NAME")
    wait_for_slot
    discover_identity_for_node "$NODE" "$POD_NAME" &
done

wait
if [[ -f "$DISCOVERY_DIR/failed_flag" ]]; then
    echo "[ERROR] Discovery phase encountered a failure. Halting script."
    exit 1
fi

if [[ ! -s "$DISCOVERY_DIR/map.txt" ]]; then
    echo "Error: Hardware discovery did not produce any results."
    exit 1
fi

UNIQUE_MAP=$(awk -F'|' '!seen[$1 FS $2]++ {print $1 FS $2 FS $3}' "$DISCOVERY_DIR/map.txt")
if [[ -z "$UNIQUE_MAP" ]]; then
    echo "Error: Failed to derive unique hardware make/model identities from discovery output."
    exit 1
fi

echo "Discovery complete."
echo ""
echo "Found the following unique server make/model combinations:"
echo "---------------------------------------------------"
while IFS='|' read -r OEM MODEL NODE; do
    [[ -z "$OEM" || -z "$MODEL" || -z "$NODE" ]] && continue
    echo " - OEM: $OEM | Model: $MODEL (Representative Node: $NODE)"
done <<< "$UNIQUE_MAP"
echo "---------------------------------------------------"

log_section "[2/4] Uploading $TOPOLOGY_SCRIPT to the cluster as a ConfigMap..."
CONFIGMAP_NAME=$(safe_resource_name "topo-script-" "$TIMESTAMP")
kubectl create configmap "$CONFIGMAP_NAME" --from-file=script.sh="$TOPOLOGY_SCRIPT" --namespace="$NAMESPACE" >/dev/null

log_section "[3/4] Dispatching topology collection jobs..."
while IFS='|' read -r OEM MODEL NODE; do
    [[ -z "$OEM" || -z "$MODEL" || -z "$NODE" ]] && continue

    SAFE_OEM=$(safe_path_component "$OEM")
    SAFE_MODEL=$(safe_path_component "$MODEL")
    SAFE_PLATFORM="${SAFE_MODEL}"
    JOB_NAME=$(safe_resource_name "topo-collect-" "$NODE-$TIMESTAMP")
    JOB_NAMES+=("$JOB_NAME")

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $JOB_TIMEOUT_SECONDS
  template:
    spec:
      nodeName: $NODE
      hostNetwork: true
      hostPID: true
      hostIPC: true
      tolerations:
      - operator: "Exists"
      containers:
      - name: collector
        image: $COLLECTOR_IMAGE
        securityContext:
          privileged: true
        command: ["chroot", "/host", "/bin/bash", "-c", "/bin/bash /tmp/topo-scripts/script.sh"]
        volumeMounts:
        - name: host-root
          mountPath: /host
        - name: script-vol
          mountPath: /host/tmp/topo-scripts
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: script-vol
        configMap:
          name: $CONFIGMAP_NAME
          defaultMode: 0777
      restartPolicy: Never
EOF

    echo "  -> Started Job $JOB_NAME on node $NODE ($OEM / $MODEL)"
    echo "$JOB_NAME|$SAFE_PLATFORM|$NODE|$OEM|$MODEL|$SAFE_OEM|$SAFE_MODEL" >> "$DISCOVERY_DIR/jobs.txt"
done <<< "$UNIQUE_MAP"

log_section "[4/4] Waiting for jobs to complete and extracting reports..."
while IFS='|' read -r JOB_NAME SAFE_PLATFORM NODE OEM MODEL SAFE_OEM SAFE_MODEL; do
    [[ -z "$JOB_NAME" || -z "$SAFE_PLATFORM" || -z "$NODE" ]] && continue

    REPORT_DIR="$OUTPUT_DIR/$SAFE_PLATFORM"
    REPORT_FILE="$REPORT_DIR/topology.yaml"
    mkdir -p "$REPORT_DIR"

    if kubectl wait --for=condition=complete --timeout="${JOB_TIMEOUT_SECONDS}s" "job/$JOB_NAME" --namespace="$NAMESPACE" >/dev/null 2>&1; then
        kubectl logs "job/$JOB_NAME" --namespace="$NAMESPACE" > "$REPORT_FILE" 2>/dev/null || true
        if [[ ! -s "$REPORT_FILE" ]]; then
            {
                echo "[WARNING] Job completed but produced no logs."
                echo "Job: $JOB_NAME"
                echo "Node: $NODE"
                echo "OEM: ${OEM:-Unknown_OEM}"
                echo "Model: ${MODEL:-Unknown_Model}"
            } > "$REPORT_FILE"
        fi
        echo "  -> Saved report for make/model '$OEM / $MODEL' to: $REPORT_FILE"
        continue
    fi

    {
        echo "[ERROR] Job did not complete successfully within ${JOB_TIMEOUT_SECONDS}s."
        echo "Job: $JOB_NAME"
        echo "Node: $NODE"
        echo "OEM: ${OEM:-Unknown_OEM}"
        echo "Model: ${MODEL:-Unknown_Model}"
        echo ""
        echo "Job description:"
        kubectl describe job "$JOB_NAME" --namespace="$NAMESPACE" 2>/dev/null || true
        echo ""
        echo "Available pod logs:"
        kubectl logs "job/$JOB_NAME" --namespace="$NAMESPACE" 2>/dev/null || true
    } > "$REPORT_FILE"
    echo "  [ERROR] Job $JOB_NAME on $NODE failed or timed out. Halting script."; exit 1
done < "$DISCOVERY_DIR/jobs.txt"

echo ""
echo "========================================================================"
echo " Finished! All unique model reports have been saved in: ./$OUTPUT_DIR/"
echo "=======================================
