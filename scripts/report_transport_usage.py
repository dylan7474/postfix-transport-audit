#!/usr/bin/env python3
"""
CHANGE CONTROL ANNOTATION
-------------------------
Purpose:
    Parse transport override definitions and correlate them against maillog
    evidence to classify override domains as active/inactive.

How this script works (execution flow):
    1) Parse all_transport into (domain, transport) tuples, skipping blanks/comments.
    2) Build a deduplicated override-domain set for constant-time membership checks.
    3) Stream maillog.ALL line-by-line and extract recipient domain, status, relay.
    4) Accumulate per-domain counters only when recipient domain is in overrides.
    5) Split domains into active/inactive based on observed hit counts.
    6) Emit deterministic plain-text report sections for board/operator review.

Safety and change scope:
    - Read-only processing of input files.
    - No network calls and no modification of source artifacts.
    - Designed for conservative interpretation (reports observed evidence only).
"""
import re
import sys
import ipaddress
from collections import Counter, defaultdict


def read_overrides(all_transport_path: str):
    """Read override mappings from all_transport.

    Parsing rules:
      - Ignore empty lines and comments.
      - Split on whitespace and require at least two fields.
      - Field[0] is treated as domain; field[1] as transport.
      - Domain is normalized to lowercase for log correlation.
    """
    overrides = []
    with open(all_transport_path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            domain = parts[0].strip().lower()
            transport = parts[1].strip()
            overrides.append((domain, transport))
    return overrides


# Extract recipient domain from to=<user@domain>
TO_RE = re.compile(r"\bto=<[^>]*@([^>]+)>", re.IGNORECASE)
STATUS_RE = re.compile(r"\bstatus=([a-z]+)\b", re.IGNORECASE)
RELAY_RE = re.compile(r"\brelay=([^, ]+)", re.IGNORECASE)
CLIENT_RE = re.compile(r"\bclient=([^\[ ]+)?\[([^\]]+)\]", re.IGNORECASE)


def read_client_access(client_access_path: str):
    """Read sender whitelist entries from client_access.

    Parsing rules:
      - Ignore empty lines and comments.
      - Keep only lines that contain " OK" (case-insensitive).
      - Capture first field as candidate IP/CIDR and normalize via ipaddress.
      - Return exact-IP map and CIDR map keyed by canonical string.
    """
    exact_ip_map = {}
    cidr_map = {}

    with open(client_access_path, "r", errors="replace") as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            if " ok" not in stripped.lower():
                continue

            first_col = stripped.split()[0]
            try:
                if "/" in first_col:
                    net = ipaddress.ip_network(first_col, strict=False)
                    cidr_map[str(net)] = net
                else:
                    ip = ipaddress.ip_address(first_col)
                    exact_ip_map[str(ip)] = ip
            except ValueError:
                continue

    return exact_ip_map, cidr_map


def main():
    # CHANGE CONTROL ANNOTATION
    # -------------------------
    # Purpose:
    #   Expand CLI contract to accept optional client_access evidence input.
    #
    # How this block works (execution flow):
    #   1) Require all_transport + maillog.ALL positional arguments.
    #   2) Accept an optional third argument for client_access sender whitelist.
    #
    # Safety and change scope:
    #   - Backward compatible: two-argument invocation still works.
    #   - Read-only input handling only.
    if len(sys.argv) not in (3, 4):
        print(
            "Usage: report_transport_usage.py <all_transport> <maillog.ALL> [client_access]",
            file=sys.stderr,
        )
        return 2

    all_transport, maillog = sys.argv[1], sys.argv[2]
    client_access = sys.argv[3] if len(sys.argv) == 4 else None
    overrides = read_overrides(all_transport)
    client_exact_ips, client_cidr_nets = ({}, {}) if not client_access else read_client_access(client_access)

    # Deduplicate domains so duplicate lines in all_transport do not inflate totals.
    override_domains = sorted({d for d, _ in overrides})

    # Constant-time membership lookup during maillog scan.
    override_set = set(override_domains)

    # hits: any matching recipient-domain line
    # status_counts: delivered/deferred/bounced/etc per domain
    # relay_counts: relay target distribution per domain
    hits = Counter()
    status_counts = defaultdict(Counter)
    relay_counts = defaultdict(Counter)

    # Tracks only smtp/error daemon lines, for outbound-attempt signal.
    outbound_attempts = Counter()

    # CHANGE CONTROL ANNOTATION
    # -------------------------
    # Purpose:
    #   Track sender-access whitelist activity from maillog client=... tokens.
    #
    # How this block works (execution flow):
    #   1) Parse client IP from each line using CLIENT_RE.
    #   2) Test exact IP and CIDR membership using ipaddress primitives.
    #   3) Count hits per whitelisted key for active/inactive classification.
    #
    # Safety and change scope:
    #   - Single-pass log processing preserved.
    #   - Invalid/unparseable IP tokens are ignored conservatively.
    sender_hits = Counter()

    # Single-pass log scan keeps memory bounded for large log windows.
    with open(maillog, "r", errors="replace") as f:
        for line in f:
            cm = CLIENT_RE.search(line)
            if cm:
                log_client_ip = cm.group(2).strip()
                try:
                    ip_obj = ipaddress.ip_address(log_client_ip)
                except ValueError:
                    ip_obj = None

                if ip_obj is not None:
                    canonical_ip = str(ip_obj)
                    if canonical_ip in client_exact_ips:
                        sender_hits[canonical_ip] += 1

                    for cidr_key, cidr_net in client_cidr_nets.items():
                        if ip_obj in cidr_net:
                            sender_hits[cidr_key] += 1

            # Domain extraction is anchored on Postfix to=<...> tokens.
            m = TO_RE.search(line)
            if not m:
                continue
            rcpt_domain = m.group(1).strip().lower()

            # Ignore domains not present in override map.
            if rcpt_domain not in override_set:
                continue

            hits[rcpt_domain] += 1

            sm = STATUS_RE.search(line)
            if sm:
                status_counts[rcpt_domain][sm.group(1).lower()] += 1

            rm = RELAY_RE.search(line)
            if rm:
                relay_counts[rcpt_domain][rm.group(1)] += 1
            else:
                # Some failure lines include relay=none; normalize into relay counts.
                if " relay=none" in line or " relay=none," in line:
                    relay_counts[rcpt_domain]["none"] += 1

            if "postfix/smtp" in line or "postfix/error" in line:
                outbound_attempts[rcpt_domain] += 1

    # Domain classification depends only on observed hit count in provided window.
    active = [d for d in override_domains if hits[d] > 0]
    inactive = [d for d in override_domains if hits[d] == 0]

    # Report sections are intentionally fixed-order and plain text for easy diffing.
    print("=== SUMMARY ===")
    print(f"Override domains total: {len(override_domains)}")
    print(f"Active (seen in logs):  {len(active)}")
    print(f"Inactive (no hits):    {len(inactive)}")
    print()

    # CHANGE CONTROL ANNOTATION
    # -------------------------
    # Purpose:
    #   Emit sender whitelist evidence and decommission kill-list candidates.
    #
    # How this block works (execution flow):
    #   1) Build a deterministic combined whitelist key list.
    #   2) Classify active vs inactive keys by observed sender hits.
    #   3) Print summary + explicit kill list for zero-activity whitelist entries.
    #
    # Safety and change scope:
    #   - Reporting only; no automatic pruning actions are performed.
    whitelist_keys = sorted(list(client_exact_ips.keys()) + list(client_cidr_nets.keys()))
    sender_active = [k for k in whitelist_keys if sender_hits[k] > 0]
    sender_inactive = [k for k in whitelist_keys if sender_hits[k] == 0]

    print("=== SENDER ACCESS AUDIT ===")
    print(f"Whitelisted entries total: {len(whitelist_keys)}")
    print(f"Active (seen in logs):     {len(sender_active)}")
    print(f"Inactive (no hits):        {len(sender_inactive)}")
    print()

    print("=== KILL LIST (whitelisted IP/CIDR with zero log activity) ===")
    for entry in sender_inactive:
        print(entry)
    print()

    print("=== INACTIVE DOMAINS (no log hits in provided window) ===")
    for d in inactive:
        print(d)
    print()

    print("=== ACTIVE DOMAINS (evidence of usage) ===")
    for d in sorted(active, key=lambda x: hits[x], reverse=True):
        print()
        print(f"{d}: hits={hits[d]} outbound_attempts={outbound_attempts[d]}")
        if status_counts[d]:
            sc = " ".join(f"{k}={v}" for k, v in status_counts[d].most_common())
            print(f"  status: {sc}")
        if relay_counts[d]:
            top = ", ".join(f"{k}({v})" for k, v in relay_counts[d].most_common(8))
            print(f"  top relays: {top}")

    print()
    print("=== NOTE ===")
    print("hits=any log line where recipient domain matched an override.")
    print("outbound_attempts=only postfix/smtp or postfix/error lines for that domain.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
