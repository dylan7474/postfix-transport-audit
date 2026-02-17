#!/bin/bash
set -euo pipefail

# CHANGE CONTROL ANNOTATION
# -------------------------
# Purpose:
#   Render a concise Markdown summary from a completed analysis run directory.
#
# How this script works (execution flow):
#   1) Validate run-directory input.
#   2) Resolve the raw analyzer report path.
#   3) Attempt to locate metadata.txt under extracted bundle content.
#   4) Emit Markdown sections in fixed order:
#      title -> generated timestamp -> metadata block -> key results -> outputs.
#
# Safety and change scope:
#   - Read-only with respect to input artifacts.
#   - No mutation of collected evidence.

WORK="${1:-}"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "Usage: $0 <run-directory>"
  exit 1
fi

# REPORT is required output from report_transport_usage.py.
REPORT="$WORK/transport-usage-report.txt"
# META is optional; find first match in extracted input tree.
META="$(find "$WORK/in" -name metadata.txt | head -n 1 || true)"

# Markdown is written to stdout so caller can redirect to REPORT.md.
echo "# Postfix Transport Override Audit"
echo
echo "Generated: $(date -R)"
echo

# Include original source-host metadata when available.
if [ -f "$META" ]; then
  echo "## Source metadata"
  echo
  echo '```'
  cat "$META"
  echo '```'
  echo
fi

# Show first portion of analyzer output as executive summary.
echo "## Key results"
echo
echo '```'
sed -n '1,120p' "$REPORT"
echo '```'
echo

# Enumerate generated artifacts for traceability.
echo "## Files produced"
echo
echo "- \`$WORK/maillog.ALL\` (combined logs)"
echo "- \`$WORK/transport-usage-report.txt\` (full analyzer output)"
echo "- \`$WORK/REPORT.md\` (this summary)"
