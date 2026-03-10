#!/usr/bin/env bash
set -euo pipefail

CSV="${CSV:-nic-inventory-merged-2026-03-06-123441.csv}"
SSH_USER="${SSH_USER:-root}"
REMOTE_RULE="${REMOTE_RULE:-/etc/udev/rules.d/80-supernic-rails.rules}"
WORKDIR="${WORKDIR:-./udev_rail_build}"
DEPLOY="${DEPLOY:-true}"       # DEPLOY=false -> only generate files locally
REBOOT="${REBOOT:-false}"      # REBOOT=true -> reboot nodes after install (recommended)
RELOAD_ONLY="${RELOAD_ONLY:-false}"  # try udev trigger without reboot (less reliable)

mkdir -p "$WORKDIR/rules"

echo "[INFO] CSV=$CSV"
echo "[INFO] WORKDIR=$WORKDIR"
echo "[INFO] SSH_USER=$SSH_USER"
echo "[INFO] DEPLOY=$DEPLOY REBOOT=$REBOOT RELOAD_ONLY=$RELOAD_ONLY"
echo

# --- Generate per-host udev rules safely from CSV ---
CSV="$CSV" WORKDIR="$WORKDIR" python3 - <<'PY'
import csv, os, sys
from collections import defaultdict

csv_path = os.environ["CSV"]
workdir = os.environ["WORKDIR"]
outdir = os.path.join(workdir, "rules")
os.makedirs(outdir, exist_ok=True)

needed = {"HOSTNAME","FUNC","TYPE","PCI","PERM_MAC","CURR_MAC"}
per_host = defaultdict(list)

def pci_key(pci: str):
    # 0000:19:00.0
    try:
        dom, bus, rest = pci.split(":")
        dev, func = rest.split(".")
        return (int(dom,16), int(bus,16), int(dev,16), int(func,16))
    except Exception:
        return (9999,9999,9999,9999)

with open(csv_path, newline="") as f:
    r = csv.DictReader(f)
    missing = needed - set(r.fieldnames or [])
    if missing:
        sys.stderr.write(f"[ERROR] Missing columns: {sorted(missing)}\n")
        sys.stderr.write(f"[ERROR] Found columns: {r.fieldnames}\n")
        sys.exit(2)

    for row in r:
        if row.get("TYPE","").strip() != "SuperNIC":
            continue
        if row.get("FUNC","").strip() != "PF":
            continue

        host = row.get("HOSTNAME","").strip()
        pci  = row.get("PCI","").strip()
        mac  = (row.get("PERM_MAC","") or row.get("CURR_MAC","")).strip().lower()

        if not host or not pci or not mac:
            continue

        per_host[host].append((pci, mac))

if not per_host:
    sys.stderr.write("[ERROR] No rows matched TYPE=SuperNIC and FUNC=PF\n")
    sys.exit(3)

# write host list
hosts_txt = os.path.join(workdir, "hosts.txt")
with open(hosts_txt, "w") as hf:
    for h in sorted(per_host.keys()):
        hf.write(h + "\n")

# write per-host rules
warn = 0
for host, items in per_host.items():
    items = sorted(items, key=lambda x: pci_key(x[0]))
    if len(items) != 8:
        warn += 1
        sys.stderr.write(f"[WARN] {host}: found {len(items)} SuperNIC PFs (expected 8)\n")

    if len(items) > 8:
        items = items[:8]

    lines = []
    lines.append("# Generated SuperNIC PF rail naming")
    lines.append("# Filter: TYPE=SuperNIC and FUNC=PF")
    lines.append("# rail index is assigned by sorting PFs by PCI address on THIS host")
    lines.append("")
    for rail, (pci, mac) in enumerate(items):
        lines.append(f"# {host}: rail{rail}pf  PCI={pci}  MAC={mac}")
        lines.append(f'SUBSYSTEM=="net", ACTION=="add", ATTR{{address}}=="{mac}", NAME="rail{rail}pf"')
        lines.append("")

    with open(os.path.join(outdir, f"{host}.rules"), "w") as out:
        out.write("\n".join(lines))

print(f"[OK] Generated rules in {outdir}")
print(f"[OK] Hosts list: {hosts_txt}")
if warn:
    print(f"[WARN] {warn} host(s) did not have exactly 8 PFs in the CSV. Review their rules.")
PY

echo
echo "[INFO] Sample generated rules:"
SAMPLE="$(ls -1 "$WORKDIR/rules"/*.rules | head -n 1 || true)"
if [[ -n "${SAMPLE:-}" ]]; then
  echo "----- $SAMPLE -----"
  sed -n '1,40p' "$SAMPLE"
  echo "-------------------"
fi

if [[ "$DEPLOY" != "true" ]]; then
  echo "[INFO] DEPLOY=false -> stopping after generation."
  exit 0
fi

# --- Deploy to nodes ---
echo
echo "[INFO] Deploying to nodes..."
while read -r HOST; do
  [[ -z "$HOST" ]] && continue
  RULE_FILE="$WORKDIR/rules/${HOST}.rules"

  echo
  echo "[INFO] -> $HOST"
  scp "$RULE_FILE" "${SSH_USER}@${HOST}:/tmp/80-supernic-rails.rules"

  ssh "${SSH_USER}@${HOST}" "sudo mkdir -p /etc/udev/rules.d && \
    sudo mv /tmp/80-supernic-rails.rules '$REMOTE_RULE' && \
    sudo chmod 644 '$REMOTE_RULE' && \
    sudo udevadm control --reload"

  if [[ "$RELOAD_ONLY" == "true" ]]; then
    # Might not fully rename without reboot if services already grabbed old names
    ssh "${SSH_USER}@${HOST}" "sudo udevadm trigger -c add -s net || true"
  fi

  if [[ "$REBOOT" == "true" ]]; then
    echo "[INFO] Rebooting $HOST"
    ssh "${SSH_USER}@${HOST}" "sudo reboot" || true
  fi
done < "$WORKDIR/hosts.txt"

echo
echo "[OK] Done."
echo "After nodes are back, verify:"
echo "  ip -br link | egrep 'rail[0-7]pf'"
