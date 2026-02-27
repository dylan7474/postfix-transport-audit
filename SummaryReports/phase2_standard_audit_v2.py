import os, glob, gzip, re
from collections import defaultdict

nodes = ["NBG01-SMTP-02", "NBG01-SMTP-04", "NBG01-SMTP-08"]
output_file = "Phase2_Standard_Full_Picture.txt"

def get_standard_domains(base_path):
    domains = set()
    search_patterns = [f"{base_path}/**/etc/postfix/transport", f"{base_path}/**/etc/postfix/relaydomains"]
    for pattern in search_patterns:
        for filepath in glob.glob(pattern, recursive=True):
            try:
                with open(filepath, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#'): domains.add(line.split()[0].lower())
            except: continue
    return domains

def scan_standard_logs(base_path, authorized_list):
    activity = defaultdict(lambda: defaultdict(int))
    log_pattern = f"{base_path}/**/logs/maillog*"
    for log_path in glob.glob(log_pattern, recursive=True):
        opener = gzip.open if log_path.endswith('.gz') else open
        try:
            msg_data = {}
            with opener(log_path, 'rt', errors='ignore') as f:
                for line in f:
                    if "postfix-bulk" in line: continue
                    msg_id_match = re.search(r'postfix/\w+\[\d+\]: ([A-F0-9]+):', line)
                    if not msg_id_match: continue
                    msg_id = msg_id_match.group(1)

                    if "from=<" in line:
                        src_match = re.search(r'from=<[^@]*@?([^>]+)>', line)
                        if src_match: msg_data[msg_id] = src_match.group(1).lower()

                    if "to=<" in line and msg_id in msg_data:
                        dest_match = re.search(r'to=<[^@]+@([^>]+)>', line)
                        if dest_match:
                            src_domain = msg_data[msg_id]
                            dest_domain = dest_match.group(1).lower()
                            if dest_domain in authorized_list:
                                activity[src_domain][dest_domain] += 1
        except Exception as e: print(f"Error reading {log_path}: {e}")
    return activity

print(f"[*] Starting Phase 2 (Standard) Full Audit...")
master_activity = defaultdict(lambda: defaultdict(int))

for node in nodes:
    print(f"  -> Processing {node}...")
    authorized = get_standard_domains(node)
    hits = scan_standard_logs(node, authorized)
    for src, dests in hits.items():
        for dest, count in dests.items():
            master_activity[src][dest] += count

with open(output_file, 'w') as f:
    f.write(f"{'SOURCE DOMAIN (FROM)':<40} | {'DEST DOMAIN (TO)':<40} | {'HITS'}\n")
    f.write("-" * 100 + "\n")
    for src in sorted(master_activity.keys()):
        for dest in sorted(master_activity[src].keys()):
            f.write(f"{src:<40} | {dest:<40} | {master_activity[src][dest]}\n")

print(f"[!] Results saved to: {output_file}")
