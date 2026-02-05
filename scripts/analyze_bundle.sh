#!/bin/bash
set -euo pipefail

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE" ]; then
  echo "Usage: $0 /path/to/postfix-audit-<host>-<ts>.tar"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="$ROOT/runs"
mkdir -p "$RUNS"

TS="$(date +%Y%m%d-%H%M%S)"
WORK="$RUNS/run-$TS"
mkdir -p "$WORK"

echo "[*] Extracting bundle into $WORK/in..."
mkdir -p "$WORK/in"
tar -xf "$BUNDLE" -C "$WORK/in"

# Bundle folder is the single directory inside in/
BUNDLEDIR="$(find "$WORK/in" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$BUNDLEDIR" ]; then
  echo "Could not locate extracted directory"
  exit 1
fi

echo "[*] Locating all_transport..."
# Prefer the captured /etc/postfix/net/smtp/all_transport if present
ALL_TRANSPORT=""
if [ -f "$BUNDLEDIR/etc/postfix/net/smtp/all_transport" ]; then
  ALL_TRANSPORT="$BUNDLEDIR/etc/postfix/net/smtp/all_transport"
elif [ -f "$BUNDLEDIR/custom/smtp/all_transport" ]; then
  ALL_TRANSPORT="$BUNDLEDIR/custom/smtp/all_transport"
else
  # Fallback: search it
  ALL_TRANSPORT="$(find "$BUNDLEDIR" -type f -name 'all_transport' | head -n 1 || true)"
fi

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

# Sort rotated logs by name (works for your maillog-YYYYMMDD convention)
# Include current maillog last.
OUTLOG="$WORK/maillog.ALL"
(
  ls -1 "$LOGDIR"/maillog-* 2>/dev/null | sort || true
  [ -f "$LOGDIR/maillog" ] && echo "$LOGDIR/maillog"
) | while read -r f; do
  [ -n "$f" ] && cat "$f"
done > "$OUTLOG"

echo "[*] Running transport usage report..."
python3 "$ROOT/scripts/report_transport_usage.py" "$ALL_TRANSPORT" "$OUTLOG" > "$WORK/transport-usage-report.txt"

echo "[*] Rendering summary report..."
bash "$ROOT/scripts/report_render.sh" "$WORK" > "$WORK/REPORT.md"

echo
echo "[OK] Run complete:"
echo "  $WORK/REPORT.md"
echo "  $WORK/transport-usage-report.txt"
echo "  $WORK/maillog.ALL"
