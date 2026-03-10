#!/usr/bin/env python3
# generate-udev-rules.sh
import csv, os, sys
from collections import defaultdict

def main(csv_path, out_dir):
    # Dictionaries to hold different NIC types per host
    super_nics = defaultdict(list)
    smart_nics = defaultdict(list)

    if not os.path.exists(csv_path):
        print(f"[ERROR] CSV not found: {csv_path}")
        sys.exit(1)

    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            host = row["HOSTNAME"]
            # Filter for Physical Functions only
            if row.get("FUNC") != "PF":
                continue
            
            pci = row["PCI"]
            mac = (row.get("PERM_MAC") or row.get("CURR_MAC")).lower()
            nic_type = row.get("TYPE", "Generic-NIC")

            if nic_type == "SuperNIC":
                super_nics[host].append((pci, mac))
            elif nic_type == "SmartNIC":
                smart_nics[host].append((pci, mac))

    all_hosts = set(super_nics.keys()) | set(smart_nics.keys())

    for host in all_hosts:
        rule_path = os.path.join(out_dir, f"{host}_nics.rules")
        with open(rule_path, "w") as f:
            f.write(f"# Persistent naming for {host}\n\n")

            # --- Process SuperNICs (Rails) ---
            if host in super_nics:
                f.write("# --- SuperNIC Rail Interfaces ---\n")
                # Sort by PCI for geographic consistency
                sorted_super = sorted(super_nics[host], key=lambda x: x[0])
                for i, (pci, mac) in enumerate(sorted_super):
                    f.write(f'SUBSYSTEM=="net", ACTION=="add", ATTR{{address}}=="{mac}", NAME="rail{i}pf"\n')
                f.write("\n")

            # --- Process SmartNICs ---
            if host in smart_nics:
                f.write("# --- SmartNIC Management Interfaces ---\n")
                sorted_smart = sorted(smart_nics[host], key=lambda x: x[0])
                for i, (pci, mac) in enumerate(sorted_smart):
                    f.write(f'SUBSYSTEM=="net", ACTION=="add", ATTR{{address}}=="{mac}", NAME="smart{i}pf"\n')

        print(f"  [OK] {host}: Generated rules for {len(super_nics.get(host, []))} SuperNICs and {len(smart_nics.get(host, []))} SmartNICs")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ./generate-udev-rules.sh <input_csv> <output_dir>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
