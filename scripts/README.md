# Scripts overview

This folder contains the minimal collection, analysis, and reporting tooling for
Postfix transport override audits. The intended workflow is **sequential** and
run against specific targets as described below.

> **Note:** This repository must only contain tooling. Do **not** place real
> customer data, logs, or configuration in this repo. Use synthetic examples if
> needed.

## Execution order and targets

### 1) `collect_source.sh` (target: legacy Postfix source host)

**Purpose:** Collects Postfix configuration, selected custom maps, logs, queue
snapshots, and basic system/network metadata into a tarball bundle.

**Target environment:** The legacy relay host (e.g., RHEL 6.x) you are auditing.
Run it **on the source host** so it can read `/etc/postfix`, `/var/log/maillog*`,
queue state, and network information.

**Output:** A tarball in `$OUTDIR` (default: `/tmp/postfix-audit`) named
`postfix-audit-<host>-<timestamp>.tar`.

### 2) `analyze_bundle.sh` (target: analysis workstation)

**Purpose:** Extracts the tarball bundle, locates the `all_transport` map,
builds a chronological `maillog.ALL`, runs the transport usage analysis, and
renders a Markdown summary report.

**Target environment:** A safe analysis host (e.g., Debian-based utility VM).
Run it **on the analysis workstation** against the bundle transferred from the
source host.

**Output:** A time-stamped run directory under `runs/` containing:
- `maillog.ALL` (combined logs)
- `transport-usage-report.txt` (full analyzer output)
- `REPORT.md` (summary report)

### 3) `report_transport_usage.py` (invoked by `analyze_bundle.sh`)

**Purpose:** Parses `all_transport` override domains and cross-references them
against `maillog.ALL` to identify active vs inactive overrides, delivery
statuses, and relay usage.

**Target environment:** Runs on the analysis workstation (via `python3`).
It is **not** intended to run on the legacy source host.

### 4) `report_render.sh` (invoked by `analyze_bundle.sh`)

**Purpose:** Produces a concise Markdown report summarizing source metadata and
key findings from the transport usage report.

**Target environment:** Runs on the analysis workstation (via `bash`).

## Typical workflow summary

1. On the **source host**: run `collect_source.sh` to produce a bundle.
2. Transfer the bundle **off-host** to the analysis workstation.
3. On the **analysis workstation**: run `analyze_bundle.sh` against the bundle.

## Safety and data handling

- Keep all real data **outside** the repository (work in `runs/` or another
  external working directory).
- Use only synthetic domains/IPs if you need to demonstrate examples.
- Do not modify or apply production configuration as part of this workflow.
