Based on https://chatgpt.com/c/69833e1f-99e4-8387-b4c0-94f19a618162

# postfix-transport-audit

Repeatable, auditable process to:
1) Collect Postfix config + logs from a source server (including legacy RHEL6),
2) Transfer a single bundle to an analysis host (Debian),
3) Generate a report showing which transport overrides are active vs inactive.

## Why this exists

We have Postfix transport overrides (per-client destination routing) and need evidence to:
- Identify which clients still use special routing,
- Propose safe removal of inactive overrides,
- Provide an auditable trail for change control.

## What gets collected

- `/etc/postfix/` (best-effort)
- `/etc/postfix/net/smtp/*` and related maps (best-effort)
- `/var/log/maillog*`
- `postconf -n`, `postqueue -p`, `mailq`
- basic routing + firewall snapshot

## Source server: create bundle

Run as root (or a user with read access to the logs/config):

```bash
git clone <this repo> postfix-transport-audit
cd postfix-transport-audit
chmod +x scripts/collect_source.sh
scripts/collect_source.sh

Transfer that tar to Debian (scp/rsync/whatever process you have).

Debian: analyze bundle
cd postfix-transport-audit
chmod +x scripts/analyze_bundle.sh
scripts/analyze_bundle.sh /path/to/postfix-audit-<host>-<timestamp>.tar


Outputs in runs/run-YYYYMMDD-HHMMSS/:

REPORT.md (human readable summary)

transport-usage-report.txt (full detail)

maillog.ALL (combined logs used)

Interpreting results

"Inactive domains" = no matching to=<...@domain> hits in the log window provided.

"Active domains" = seen in logs, with:

hits = any match

outbound_attempts = only postfix/smtp or postfix/error lines (actual outbound attempts)

Important: Some domains may be active through local injection paths (LMTP/content_filter),
so do not rely solely on outbound attempts for safety decisions.

Audit trail

Commit:

runs/run-.../REPORT.md

runs/run-.../transport-usage-report.txt

Do NOT commit:

maillog.ALL (large + potentially sensitive)

Next steps / extensions

Add a retention window policy (e.g., 90 days) before declaring an override "inactive".

Add correlation with live queue snapshots to block removals when queue contains that domain.

Add a change-plan generator that produces a proposed all_transport diff.
