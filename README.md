# postfix-transport-audit

Based on <https://chatgpt.com/c/69833e1f-99e4-8387-b4c0-94f19a618162>.

Repeatable, auditable process to:

1. Collect Postfix config + logs from a source server (including legacy RHEL6).
2. Transfer a single bundle to an analysis host (Debian).
3. Generate a report showing which transport overrides are active vs inactive.

## Why this exists

We have Postfix transport overrides (per-client destination routing) and need evidence to:

- Identify which clients still use special routing.
- Propose safe removal of inactive overrides.
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
```

Transfer that tar to Debian (scp/rsync/whatever process you have).

## Operator instructions (step-by-step, confirmation-driven)

Follow these steps exactly, and **confirm each step before moving on**. Do not
skip ahead or infer results. This keeps the process auditable and safe.

### 1) Preparation (source server)

- **Confirm scope**: Identify the specific host(s) and the exact time window you
  intend to analyze. Be explicit about which logs are in-scope.
- **Confirm access**: Ensure you have read access to Postfix configs and logs.
- **Confirm safety**: This process is **read-only**. Do not modify production
  configs or queues.

### 2) Collection (source server)

Run the bundle collection script:

```bash
git clone <this repo> postfix-transport-audit
cd postfix-transport-audit
chmod +x scripts/collect_source.sh
scripts/collect_source.sh
```

**What to collect (minimum set):**

- `/etc/postfix/` (best-effort)
- `/etc/postfix/net/smtp/*` and related maps (best-effort)
- `/var/log/maillog*`
- `postconf -n`, `postqueue -p`, `mailq`
- basic routing + firewall snapshot

**Confirm** the script produced a single tar bundle before proceeding.

### 3) Transfer (to analysis host)

- Transfer **only** the bundle tar file to the analysis host.
- Use your standard, approved transfer method (scp/rsync/etc.).
- **Do not** copy raw logs or configs outside the bundle.

**Confirm** the bundle arrived intact on the analysis host.

### 4) Analysis (analysis host)

Run the analysis script using the bundle tar:

```bash
cd postfix-transport-audit
chmod +x scripts/analyze_bundle.sh
scripts/analyze_bundle.sh /path/to/postfix-audit-<host>-<timestamp>.tar
```

**Confirm** you see outputs in `runs/run-YYYYMMDD-HHMMSS/` before proceeding.

### 5) Cleanup & data handling

- **Do not commit** any run artifacts to this repo.
- Store audit outputs **outside** the repo in a controlled location.
- If required by policy, delete the bundle from the source host after transfer.
- Apply your org’s retention policy to analysis outputs.

### 6) Precautions & safety notes

- This repo **must never** contain real customer data.
- Avoid assumptions: only make decisions based on evidence in logs.
- Always keep a clear audit trail of what was collected, when, and by whom.

Debian: analyze bundle

```bash
cd postfix-transport-audit
chmod +x scripts/analyze_bundle.sh
scripts/analyze_bundle.sh /path/to/postfix-audit-<host>-<timestamp>.tar
```

Outputs in `runs/run-YYYYMMDD-HHMMSS/`:

- `REPORT.md` (human readable summary)
- `transport-usage-report.txt` (full detail)
- `maillog.ALL` (combined logs used)

## Interpreting results

"Inactive domains" = no matching `to=<...@domain>` hits in the log window provided.

"Active domains" = seen in logs, with:

- `hits` = any match
- `outbound_attempts` = only `postfix/smtp` or `postfix/error` lines (actual outbound attempts)

Important: Some domains may be active through local injection paths (LMTP/content_filter),
so do not rely solely on outbound attempts for safety decisions.

## Audit trail

Store audit outputs **outside** this repository. Do not commit any run artifacts
or reports here, even if they look sanitized. This keeps the repo tooling-only
and avoids accidental exposure of customer data.

## Next steps / extensions

- Add a retention window policy (e.g., 90 days) before declaring an override "inactive".
- Add correlation with live queue snapshots to block removals when queue contains that domain.
- Add a change-plan generator that produces a proposed `all_transport` diff.
