import os
import glob
import gzip
import re
from collections import defaultdict

# --- CONFIGURATION ---
nodes = ["NBG01-SMTP-02", "NBG01-SMTP-04", "NBG01-SMTP-08"]
output_file = "Master_Bulk_Activity_Report.txt"

def get_authorized_domains(base_path):
    """Scrapes transport and relay files for configured domains."""
    domains = set()
    # Search for config files in the nested structure identified in your tree
    search_paths = [
        f"{base_path}/**/etc/postfix/net/smtp/scan_transport",
        f"{base_path}/**/etc/postfix/net/smtp/relaydomains",
        f"{base_path}/**/custom/smtp/scan_transport",
        f"{base_path}/**/custom/smtp/relaydomains"
    ]
    for pattern in search_paths:
        for filepath in glob.glob(pattern, recursive=True):
            with open(filepath, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        # Take the first column (the domain)
                        domains.add(line.split()[0].lower())
    return domains

def scan_logs(base_path, authorized_list):
    """Performs a one-pass scan of maillogs for bulk activity."""
    activity = defaultdict(int)
    log_pattern = f"{base_path}/**/logs/maillog*"
    
    for log_path in glob.glob(log_pattern, recursive=True):
        opener = gzip.open if log_path.endswith('.gz') else open
        try:
            with opener(log_path, 'rt', errors='ignore') as f:
                for line in f:
                    if "postfix-bulk" in line and "to=<" in line:
                        # Extract domain from to=<user@domain.tld>
                        match = re.search(r'to=<[^@]+@([^>]+)>', line)
                        if match:
                            domain = match.group(1).lower()
                            if domain in authorized_list:
                                activity[domain] += 1
        except Exception as e:
            print(f"Error reading {log_path}: {e}")
    return activity

# --- EXECUTION ---
print(f"[*] Starting Master Audit across nodes: {', '.join(nodes)}")
master_report = {}

for node in nodes:
    print(f"  -> Processing {node}...")
    authorized = get_authorized_domains(node)
    hits = scan_logs(node, authorized)
    
    for domain, count in hits.items():
        if domain not in master_report:
            master_report[domain] = {'total_hits': 0, 'nodes': set()}
        master_report[domain]['total_hits'] += count
        master_report[domain]['nodes'].add(node)

# --- REPORT GENERATION ---
with open(output_file, 'w') as f:
    f.write(f"{'DOMAIN':<40} | {'TOTAL HITS':<10} | {'ACTIVE NODES'}\n")
    f.write("-" * 80 + "\n")
    
    # Sort by total hits descending
    sorted_report = sorted(master_report.items(), key=lambda x: x[1]['total_hits'], reverse=True)
    
    for domain, data in sorted_report:
        node_list = ", ".join(sorted(data['nodes']))
        f.write(f"{domain:<40} | {data['total_hits']:<10} | {node_list}\n")

print(f"\n[!] Audit Complete. Results saved to: {output_file}")
