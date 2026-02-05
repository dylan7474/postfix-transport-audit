#!/usr/bin/env python3
import re
import sys
from collections import Counter, defaultdict

def read_overrides(all_transport_path: str):
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
    if len(sys.argv) != 3:
        print("Usage: report_transport_usage.py <all_transport> <maillog.ALL>", file=sys.stderr)
        return 2

    all_transport, maillog = sys.argv[1], sys.argv[2]
    overrides = read_overrides(all_transport)
    override_domains = sorted({d for d, _ in overrides})

    # Quick map for filtering
    override_set = set(override_domains)

    hits = Counter()
    status_counts = defaultdict(Counter)
    relay_counts = defaultdict(Counter)

    # also track outbound-only attempts (postfix/smtp and postfix/error)
    outbound_attempts = Counter()

    with open(maillog, "r", errors="replace") as f:
        for line in f:
            m = TO_RE.search(line)
            if not m:
                continue
            rcpt_domain = m.group(1).strip().lower()

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
                # Many of your failures show relay=none; track that too for clarity
                if " relay=none" in line or " relay=none," in line:
                    relay_counts[rcpt_domain]["none"] += 1

            if "postfix/smtp" in line or "postfix/error" in line:
                outbound_attempts[rcpt_domain] += 1

    active = [d for d in override_domains if hits[d] > 0]
    inactive = [d for d in override_domains if hits[d] == 0]

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
