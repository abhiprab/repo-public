#!/usr/bin/env python3
# generate-udev-rules.sh
import csv, os, sys
from collections import defaultdict

def main(csv_path, out_dir):
    # Dictionaries to hold data per host
    # Format: host -> list of (pci, mac, original_iface)
    super_nics = defaultdict(list)
    smart_nics = defaultdict(list)

    if not os.path.exists(csv_path):
        print(f"[ERROR] CSV not found: {csv_path}")
        sys.exit(1)

    # Path for the single merged file
    merged_file_path = os.path.join(out_dir, "cluster_wide_baked.rules")
    
    # Initialize/Clear the merged file
    with open(merged_file_path, "w") as mf:
        mf.write("# Cluster-Wide Merged Rules for Image Baking\n")
        mf.write("# Generated from: " + os.path.basename(csv_path) + "\n\n")

    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            host = row["HOSTNAME"]
            # Filter for Physical Functions only
            if row.get("FUNC") != "PF":
                continue
            
            iface = row["IFACE"]
            pci = row["PCI"]
            mac = (row.get("PERM_MAC") or row.get("CURR_MAC")).lower()
            nic_type = row.get("TYPE", "Generic-NIC")

            # Store tuple including original interface name
            if nic_type == "SuperNIC":
                super_nics[host].append((pci, mac, iface))
            elif nic_type == "SmartNIC":
                smart_nics[host].append((pci, mac, iface))

    all_hosts = sorted(list(set(super_nics.keys()) | set(smart_nics.keys())))

    for host in all_hosts:
        rule_path = os.path.join(out_dir, f"{host}_nics.rules")
        
        # Prepare content for this specific host
        host_rules = []
        host_rules.append(f"# Persistent naming for {host}\n")

        # --- Process SuperNICs (Custom Rail Naming) ---
        if host in super_nics:
            host_rules.append("# --- SuperNIC Rail Interfaces ---\n")
            # Sort by PCI for geographic consistency
            sorted_super = sorted(super_nics[host], key=lambda x: x[0])
            for i, (pci, mac, iface) in enumerate(sorted_super):
                host_rules.append(f'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{{address}}=="{mac}", NAME="rail{i}pf"\n')
            host_rules.append("\n")

        # --- Process SmartNICs (Preserve Existing Names) ---
        if host in smart_nics:
            host_rules.append("# --- SmartNIC Management Interfaces (Preserved Names) ---\n")
            sorted_smart = sorted(smart_nics[host], key=lambda x: x[0])
            for pci, mac, iface in sorted_smart:
                # Use 'iface' variable directly to keep ethX/ethY
                host_rules.append(f'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{{address}}=="{mac}", NAME="{iface}"\n')

        # 1. Write the individual node file
        with open(rule_path, "w") as f:
            f.writelines(host_rules)

        # 2. Append to the single merged file
        with open(merged_file_path, "a") as mf:
            mf.write(f"# Host: {host}\n")
            mf.writelines(host_rules)
            mf.write("\n" + "="*60 + "\n\n")

        print(f"  [OK] {host}: Generated rules for {len(super_nics.get(host, []))} SuperNICs and {len(smart_nics.get(host, []))} SmartNICs")

    print(f"\n[SUCCESS] Individual rules and merged file 'cluster_wide_baked.rules' created in {out_dir}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ./generate-udev-rules.sh <input_csv> <output_dir>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
