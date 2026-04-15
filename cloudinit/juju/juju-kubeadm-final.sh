#!/usr/bin/env bash
set -euo pipefail

CREATED_MACHINE_IDS=()

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

retry() {
  local attempts="$1"
  local sleep_seconds="$2"
  shift 2
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    sleep "$sleep_seconds"
    n=$((n+1))
  done
}

prompt_with_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local input_value

  read -r -p "$prompt_text [$default_value]: " input_value
  if [[ -z "$input_value" ]]; then
    printf -v "$var_name" '%s' "$default_value"
  else
    printf -v "$var_name" '%s' "$input_value"
  fi
}

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 && ${#CREATED_MACHINE_IDS[@]} -gt 0 ]]; then
    echo
    echo "Script failed. Cleaning up newly created Juju machines: ${CREATED_MACHINE_IDS[*]}"
    for m in "${CREATED_MACHINE_IDS[@]}"; do
      juju remove-machine "$m" --force --no-wait || true
    done
  fi
  exit $rc
}

trap cleanup_on_error EXIT

wait_machine_ready() {
  local mid="$1"
  local status_json

  status_json="$(juju status --format json 2>/dev/null || true)"
  [[ -n "$status_json" ]] || return 1

  python3 -c '
import json, sys

mid = sys.argv[1]
raw = sys.argv[2]

try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(1)

m = data.get("machines", {}).get(mid, {})
agent = m.get("juju-status", {}).get("current", "").lower()
instance = m.get("instance-status", {}).get("current", "").lower()
message = m.get("instance-status", {}).get("message", "").lower()

good_agent = agent == "started"
good_instance = instance in ("running", "started")
good_message = ("deployed" in message) or (message == "")

raise SystemExit(0 if (good_agent and good_instance and good_message) else 1)
' "$mid" "$status_json"
}

wait_machine_ssh() {
  local mid="$1"
  juju ssh "$mid" 'echo ok' >/dev/null 2>&1
}

echo
echo "Juju + MAAS + kubeadm upstream Kubernetes installer"
echo

prompt_with_default MAAS_NAME "Enter Juju cloud name" "maas-cloud"
prompt_with_default CONTROLLER_NAME "Enter Juju controller name" "maas-cloud-default"
prompt_with_default MODEL_NAME "Enter Juju model name" "sandbox-maas"
prompt_with_default MACHINE_TAG "Enter MAAS tag to select machines" "metal"
prompt_with_default MACHINE_COUNT "How many machines to allocate" "3"
prompt_with_default UBUNTU_BASE "Enter Ubuntu base" "ubuntu@24.04"
prompt_with_default K8S_MINOR "Enter Kubernetes minor repo version" "v1.35"
prompt_with_default POD_CIDR "Enter Pod CIDR" "192.168.0.0/16"
prompt_with_default CALICO_VERSION "Enter Calico version" "v3.30.3"

echo
echo "Configuration:"
echo "  Cloud        : $MAAS_NAME"
echo "  Controller   : $CONTROLLER_NAME"
echo "  Model        : $MODEL_NAME"
echo "  MAAS tag     : $MACHINE_TAG"
echo "  Machines     : $MACHINE_COUNT"
echo "  Ubuntu base  : $UBUNTU_BASE"
echo "  K8s repo     : $K8S_MINOR"
echo "  Pod CIDR     : $POD_CIDR"
echo "  Calico       : $CALICO_VERSION"
echo

read -r -p "Proceed? [y/N]: " PROCEED
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

if [[ "$MACHINE_COUNT" -ne 3 ]]; then
  echo "This script currently expects exactly 3 machines." >&2
  exit 1
fi

for bin in juju python3 awk sed grep curl fuser; do
  need_cmd "$bin"
done

log "Switching to controller/model"
juju switch "${CONTROLLER_NAME}:${MODEL_NAME}"

STATUS_JSON="$(juju status --format json 2>/dev/null || true)"
EXISTING_COUNT="$(
python3 -c '
import json, sys
raw = sys.argv[1].strip()
if not raw:
    print(0)
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print(0)
    raise SystemExit(0)
print(len(data.get("machines", {})))
' "$STATUS_JSON"
)"

if [[ "${EXISTING_COUNT:-0}" -gt 0 ]]; then
  echo "This model already has $EXISTING_COUNT machine record(s)." >&2
  echo "Refusing to allocate more machines into a non-empty model." >&2
  juju status || true
  exit 1
fi

log "Requesting $MACHINE_COUNT MAAS machines with tag=$MACHINE_TAG"
ADD_OUTPUT="$(juju add-machine -n "$MACHINE_COUNT" --base "$UBUNTU_BASE" --constraints "tags=${MACHINE_TAG}" 2>&1)"
echo "$ADD_OUTPUT"

mapfile -t NEW_MACHINE_IDS < <(
  printf '%s\n' "$ADD_OUTPUT" | awk '/created machine / {print $NF}'
)

if [[ "${#NEW_MACHINE_IDS[@]}" -ne 3 ]]; then
  echo "Expected 3 newly added machines, found ${#NEW_MACHINE_IDS[@]}" >&2
  exit 1
fi

CREATED_MACHINE_IDS=("${NEW_MACHINE_IDS[@]}")

CONTROL_PLANE="${NEW_MACHINE_IDS[0]}"
WORKER1="${NEW_MACHINE_IDS[1]}"
WORKER2="${NEW_MACHINE_IDS[2]}"

log "Selected machines"
echo "  control-plane: ${CONTROL_PLANE}"
echo "  worker1:       ${WORKER1}"
echo "  worker2:       ${WORKER2}"

log "Current Juju model view"
juju status || true

for m in "$CONTROL_PLANE" "$WORKER1" "$WORKER2"; do
  log "Waiting for machine $m to show started/deployed in juju status"
  retry 180 10 wait_machine_ready "$m" || {
    echo "Machine $m did not become ready in time" >&2
    juju status || true
    exit 1
  }

  log "Waiting for SSH access to machine $m"
  retry 90 10 wait_machine_ssh "$m" || {
    echo "Machine $m is deployed but not yet reachable with juju ssh" >&2
    juju status || true
    exit 1
  }
done

cat > /tmp/node-prep.sh <<'__NODE_PREP__'
#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_wait() {
  sudo bash -lc '
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "Waiting for apt/dpkg lock..."
      sleep 5
    done
  '
}

retry_cmd() {
  local attempts="$1"
  local sleep_seconds="$2"
  shift 2
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    echo "Retry $n failed for: $*"
    sleep "$sleep_seconds"
    n=$((n+1))
    apt_wait
  done
}

if command -v cloud-init >/dev/null 2>&1; then
  echo "Waiting for cloud-init to finish..."
  sudo cloud-init status --wait || true
fi

apt_wait
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab || true

cat <<MODS | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODS

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<SYSCTL | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL

sudo sysctl --system

apt_wait
retry_cmd 12 10 sudo apt-get update -o Acquire::Retries=5

apt_wait
retry_cmd 12 10 sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  containerd \
  curl \
  gpg \
  psmisc

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

sudo mkdir -p -m 755 /etc/apt/keyrings
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

retry_cmd 12 10 bash -lc "curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

apt_wait
retry_cmd 12 10 sudo apt-get update -o Acquire::Retries=5

apt_wait
retry_cmd 12 10 sudo apt-get install -y kubelet kubeadm kubectl

sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
__NODE_PREP__

chmod +x /tmp/node-prep.sh
[[ -f /tmp/node-prep.sh ]] || { echo "ERROR: /tmp/node-prep.sh was not created"; exit 1; }

for m in "$CONTROL_PLANE" "$WORKER1" "$WORKER2"; do
  log "Streaming prep script to machine $m"
  juju ssh "$m" "cat > /tmp/node-prep.sh && chmod +x /tmp/node-prep.sh" < /tmp/node-prep.sh
done

for m in "$CONTROL_PLANE" "$WORKER1" "$WORKER2"; do
  log "Preparing node $m"
  juju ssh "$m" "export K8S_MINOR='${K8S_MINOR}'; bash /tmp/node-prep.sh"
done

log "Initializing control plane on $CONTROL_PLANE"
juju ssh "$CONTROL_PLANE" "sudo kubeadm init --pod-network-cidr=${POD_CIDR}" | tee /tmp/kubeadm-init.log

JOIN_CMD="$(
  awk '
    /kubeadm join / {
      cmd=$0
      while (cmd ~ /\\$/) {
        sub(/\\$/, "", cmd)
        getline
        cmd=cmd " " $0
      }
      print cmd
    }
  ' /tmp/kubeadm-init.log | tail -1 | xargs
)"

if [[ -z "$JOIN_CMD" ]]; then
  echo "Could not extract kubeadm join command." >&2
  exit 1
fi

log "Join command"
echo "$JOIN_CMD"

log "Configuring kubectl on control plane"
juju ssh "$CONTROL_PLANE" '
set -euxo pipefail
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
'

log "Installing Calico"
juju ssh "$CONTROL_PLANE" \
  "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

for m in "$WORKER1" "$WORKER2"; do
  log "Joining worker $m"
  juju ssh "$m" "sudo bash -lc '$JOIN_CMD'"
done

log "Waiting briefly for cluster to settle"
sleep 30

log "kubectl get nodes"
juju ssh "$CONTROL_PLANE" "kubectl get nodes -o wide"

log "kubectl get pods -A"
juju ssh "$CONTROL_PLANE" "kubectl get pods -A"

trap - EXIT

echo
echo "Done."
echo "Control plane machine: $CONTROL_PLANE"
echo "Worker machines:      $WORKER1, $WORKER2"
echo
echo "Useful commands:"
echo "  juju switch ${CONTROLLER_NAME}:${MODEL_NAME}"
echo "  juju ssh ${CONTROL_PLANE}"
echo "  kubectl get nodes -o wide"
