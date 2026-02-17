#!/bin/bash
set -euo pipefail

# CHANGE CONTROL ANNOTATION
# -------------------------
# Purpose:
#   Perform offline analysis of a collected Postfix audit bundle and generate
#   deterministic outputs for operator/auditor review.
#
# How this script works (execution flow):
#   1) Validate the bundle argument and create a timestamped run workspace.
#   2) Extract the tarball under runs/run-<timestamp>/in.
#   3) Locate the extracted root directory and the all_transport source file.
#   4) Reconstruct maillog.ALL by concatenating rotated logs + current log.
#   5) Invoke Python analyzer to produce transport-usage-report.txt.
#   6) Invoke Markdown renderer to produce REPORT.md.
#
# Safety and change scope:
#   - No writes to source systems or source bundle.
#   - Fails closed if required evidence (all_transport/logs) is absent.
#   - All generated artifacts are local analysis products only.

# Enforce explicit input to avoid accidentally analyzing the wrong file.
BUNDLE="${1:-}"
if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE" ]; then
  echo "Usage: $0 /path/to/postfix-audit-<host>-<ts>.tar"
  exit 1
fi

# ROOT anchors helper script paths; RUNS stores immutable run outputs.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="$ROOT/runs"
mkdir -p "$RUNS"

# One directory per execution keeps analysis reproducible and side-effect scoped.
TS="$(date +%Y%m%d-%H%M%S)"
WORK="$RUNS/run-$TS"
mkdir -p "$WORK"

echo "[*] Extracting bundle into $WORK/in..."
mkdir -p "$WORK/in"
tar -xf "$BUNDLE" -C "$WORK/in"

# Expected bundle shape is: in/<single top-level directory>/...
# We intentionally pick the first top-level directory as bundle root.
BUNDLEDIR="$(find "$WORK/in" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$BUNDLEDIR" ]; then
  echo "Could not locate extracted directory"
  exit 1
fi

echo "[*] Locating all_transport..."
# Lookup order is specific-first, generic-fallback:
#   1) canonical captured postfix path
#   2) custom/ fallback path used by collector
#   3) full-tree search as last resort
ALL_TRANSPORT=""
if [ -f "$BUNDLEDIR/etc/postfix/net/smtp/all_transport" ]; then
  ALL_TRANSPORT="$BUNDLEDIR/etc/postfix/net/smtp/all_transport"
elif [ -f "$BUNDLEDIR/custom/smtp/all_transport" ]; then
  ALL_TRANSPORT="$BUNDLEDIR/custom/smtp/all_transport"
else
  ALL_TRANSPORT="$(find "$BUNDLEDIR" -type f -name 'all_transport' | head -n 1 || true)"
fi

# all_transport is mandatory for override-vs-log correlation; abort if absent.
if [ -z "$ALL_TRANSPORT" ] || [ ! -f "$ALL_TRANSPORT" ]; then
  echo "ERROR: all_transport not found in bundle."
  echo "Searched under: $BUNDLEDIR"
  exit 1
fi

echo "[*] Building maillog.ALL (chronological)..."
LOGDIR="$BUNDLEDIR/logs"
if [ ! -d "$LOGDIR" ]; then
  echo "ERROR: logs dir not found at $LOGDIR"
  exit 1
fi

# Build merged log stream in deterministic order:
#   - rotated files sorted by name (e.g., maillog-YYYYMMDD)
#   - current maillog appended last
OUTLOG="$WORK/maillog.ALL"
(
  ls -1 "$LOGDIR"/maillog-* 2>/dev/null | sort || true
  [ -f "$LOGDIR/maillog" ] && echo "$LOGDIR/maillog"
) | while read -r f; do
  [ -n "$f" ] && cat "$f"
done > "$OUTLOG"

# Analyzer reads all_transport + merged logs and prints report to stdout.
echo "[*] Running transport usage report..."
python3 "$ROOT/scripts/report_transport_usage.py" "$ALL_TRANSPORT" "$OUTLOG" > "$WORK/transport-usage-report.txt"

# Renderer transforms raw report into board-friendly Markdown summary.
echo "[*] Rendering summary report..."
bash "$ROOT/scripts/report_render.sh" "$WORK" > "$WORK/REPORT.md"

echo
echo "[OK] Run complete:"
echo "  $WORK/REPORT.md"
echo "  $WORK/transport-usage-report.txt"
echo "  $WORK/maillog.ALL"
