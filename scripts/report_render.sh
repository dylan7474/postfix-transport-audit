#!/bin/bash
set -euo pipefail

WORK="${1:-}"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "Usage: $0 <run-directory>"
  exit 1
fi

REPORT="$WORK/transport-usage-report.txt"
META="$(find "$WORK/in" -name metadata.txt | head -n 1 || true)"

echo "# Postfix Transport Override Audit"
echo
echo "Generated: $(date -R)"
echo

if [ -f "$META" ]; then
  echo "## Source metadata"
  echo
  echo '```'
  cat "$META"
  echo '```'
  echo
fi

echo "## Key results"
echo
echo '```'
sed -n '1,120p' "$REPORT"
echo '```'
echo
echo "## Files produced"
echo
echo "- \`$WORK/maillog.ALL\` (combined logs)"
echo "- \`$WORK/transport-usage-report.txt\` (full analyzer output)"
echo "- \`$WORK/REPORT.md\` (this summary)"
