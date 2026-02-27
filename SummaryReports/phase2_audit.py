import os
import glob
import gzip
import re
from collections import defaultdict

# --- CONFIGURATION ---
nodes = ["NBG01-SMTP-02", "NBG01-SMTP-04", "NBG01-SMTP-08"]
output_file = "Phase2_Standard_Activity_Report.txt"

def get_all_authorized_domains(base_path):
    """Gathers all domains from standard postfix configs and transport maps."""
    domains = set()
    # Patterns to find ALL config files that define what we handle
    search_patterns = [
        f"{base_path}/**/etc/postfix/transport",
        f"{base_path}/**/etc/postfix/relaydomains",
        f"{base_path}/**/etc/postfix/virtual",
        f"{base_path}/**/etc/postfix/net/**/transport",
        f"{base_path}/**/etc/postfix/net/**/relaydomains"
    ]
    for pattern in search_patterns:
        for filepath in glob.glob(pattern, recursive=True):
            try:
                with open(filepath, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#'):
                            # Take the first column (the domain)
                            domains.add(line.split()[0].lower())
            except Exception:
                continue
    return domains

def scan_standard_logs(base_path, authorized_list):
    """Scans logs for activity NOT associated with the bulk instance."""
    activity = defaultdict(int)
    log_pattern = f"{base_path}/**/logs/maillog*"
    
    for log_path in glob.glob(log_pattern, recursive=True):
        opener = gzip.open if log_path.endswith('.gz') else open
        try:
            with opener(log_path, 'rt', errors='ignore') as f:
                for line in f:
                    # Filter for standard activity: MUST have 'to=<' but MUST NOT be 'postfix-bulk'
                    if "to=<" in line and "postfix-bulk" not in line:
                        match = re.search(r'to=<[^@]+@([^>]+)>', line)
                        if match:
                            domain = match.group(1).lower()
                            if domain in authorized_list:
                                activity[domain] += 1
        except Exception as e:
            print(f"Error reading {log_path}: {e}")
    return activity

# --- EXECUTION ---
print(f"[*] Starting Phase 2 Audit (Standard Traffic) across: {', '.join(nodes)}")
master_report = {}

for node in nodes:
    print(f"  -> Extracting Standard Configs for {node}...")
    authorized = get_all_authorized_domains(node)
    
    print(f"  -> Scanning Standard Logs for {node}...")
    hits = scan_standard_logs(node, authorized)
    
    for domain, count in hits.items():
        if domain not in master_report:
            master_report[domain] = {'total_hits': 0, 'nodes': set()}
        master_report[domain]['total_hits'] += count
        master_report[domain]['nodes'].add(node)

# --- REPORT GENERATION ---
with open(output_file, 'w') as f:
    f.write(f"PHASE 2: STANDARD EMAIL USAGE REPORT\n")
    f.write(f"{'DOMAIN':<40} | {'TOTAL HITS':<10} | {'ACTIVE NODES'}\n")
    f.write("-" * 80 + "\n")
    
    sorted_report = sorted(master_report.items(), key=lambda x: x[1]['total_hits'], reverse=True)
    
    for domain, data in sorted_report:
        node_list = ", ".join(sorted(data['nodes']))
        f.write(f"{domain:<40} | {data['total_hits']:<10} | {node_list}\n")

print(f"\n[!] Phase 2 Audit Complete. Results saved to: {output_file}")
