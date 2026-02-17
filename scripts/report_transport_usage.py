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


def main():
    # Strict CLI contract: exactly two positional arguments.
    if len(sys.argv) != 3:
        print("Usage: report_transport_usage.py <all_transport> <maillog.ALL>", file=sys.stderr)
        return 2

    all_transport, maillog = sys.argv[1], sys.argv[2]
    overrides = read_overrides(all_transport)

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

    # Single-pass log scan keeps memory bounded for large log windows.
    with open(maillog, "r", errors="replace") as f:
        for line in f:
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
