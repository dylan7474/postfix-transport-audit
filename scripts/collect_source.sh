#!/bin/bash
set -euo pipefail

# CHANGE CONTROL ANNOTATION
# -------------------------
# Purpose:
#   Collect a point-in-time evidence bundle from a source Postfix relay host.
#   This script is intentionally read-only against source configuration/log files
#   and writes output only under OUTDIR as a tar archive for offline analysis.
#
# How this script works (execution flow):
#   1) Resolve runtime identifiers (host + timestamp) and output paths.
#   2) Create an isolated working directory under OUTDIR/work.
#   3) Capture lightweight metadata and Postfix runtime config (postconf).
#   4) Copy candidate configuration trees/maps if present.
#   5) Copy maillog files and queue snapshots.
#   6) Capture network state relevant to delivery troubleshooting.
#   7) Tar the working directory into a single portable artifact.
#
# Safety and change scope:
#   - No in-place modification of Postfix/runtime system configuration.
#   - Best-effort capture is used for non-critical commands/files (|| true).
#   - Designed for compatibility with legacy systems (e.g., RHEL6).

# Collect Postfix-related config + logs + minimal system metadata into a tarball.
# Designed to run on old RHEL6 (no fancy dependencies).

# Environment-driven destination controls; defaults keep output local to /tmp.
OUTDIR="${OUTDIR:-/tmp/postfix-audit}"
BASENAME="${BASENAME:-postfix-audit}"

# Host + timestamp become stable identifiers embedded in folder and tar names,
# so each run is unique and can be audited later.
HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
BUNDLE="${BASENAME}-${HOST}-${TS}.tar"

# Staging happens in OUTDIR/work/<run-id>, then gets archived.
mkdir -p "$OUTDIR/work"
WORK="$OUTDIR/work/${BASENAME}-${HOST}-${TS}"
mkdir -p "$WORK"

echo "[*] Writing metadata..."
{
  # CHANGE CONTROL ANNOTATION
  # -------------------------
  # Purpose:
  #   Extend metadata capture with Postfix multi-instance visibility.
  #
  # How this block works (execution flow):
  #   1) Write baseline host/time/system keys.
  #   2) Append postmulti -l output to record instance inventory/state.
  #
  # Safety and change scope:
  #   - Read-only command execution.
  #   - Best-effort behavior retained via || true for legacy compatibility.
  # Keep metadata simple and grep-friendly (key=value format).
  echo "host=$HOST"
  echo "timestamp=$TS"
  echo "uname=$(uname -a)"
  echo "date_rfc=$(date -R)"
  echo
  echo "=== postmulti -l ==="
  postmulti -l 2>/dev/null || true
} > "$WORK/metadata.txt"

# Capture Postfix runtime configuration in one file.
# postconf failures should not abort collection, because missing data is still
# better than no bundle at all in incident/decommission evidence gathering.
{
  echo "=== postconf -n ==="
  postconf -n 2>/dev/null || true
  echo
  echo "=== postconf -m ==="
  postconf -m 2>/dev/null || true
} > "$WORK/postfix-postconf.txt"

# Copy /etc/postfix recursively if present.
# cp errors are tolerated to avoid aborting on permissions/edge files.
echo "[*] Copying postfix config..."
mkdir -p "$WORK/etc"
if [ -d /etc/postfix ]; then
  cp -a /etc/postfix "$WORK/etc/" 2>/dev/null || true
fi
if [ -d /etc/postfix-bulk ]; then
  # CHANGE CONTROL ANNOTATION
  # -------------------------
  # Purpose:
  #   Capture secondary Postfix instance configuration when present.
  #
  # How this block works (execution flow):
  #   1) Detect canonical bulk-instance path used on multi-instance hosts.
  #   2) Copy the tree into bundle/etc for offline correlation.
  #
  # Safety and change scope:
  #   - Read-only source access.
  #   - Best-effort cp preserves prior collector resilience profile.
  cp -a /etc/postfix-bulk "$WORK/etc/" 2>/dev/null || true
fi

# Copy common custom map paths individually.
# This explicit list gives predictable coverage across legacy hosts.
mkdir -p "$WORK/custom"
for p in \
  /etc/postfix/net/smtp \
  /etc/postfix/net \
  /etc/postfix/transport \
  /etc/postfix/virtual \
  /etc/postfix/relaydomains \
  /etc/postfix/relay_recipient_maps \
  /etc/postfix/client_access \
  /etc/postfix/local_domains
do
  if [ -e "$p" ]; then
    cp -a "$p" "$WORK/custom/" 2>/dev/null || true
  fi
done

# Copy mail logs verbatim; no recompression/transformation on source host.
echo "[*] Copying logs..."
mkdir -p "$WORK/logs"
for f in /var/log/maillog*; do
  [ -e "$f" ] && cp -p "$f" "$WORK/logs/" || true
done

# Queue snapshots capture in-flight/deferred context at collection time.
echo "[*] Capturing queue snapshot..."
postqueue -p > "$WORK/postqueue.txt" 2>/dev/null || true
mailq > "$WORK/mailq.txt" 2>/dev/null || true

# Network diagnostics are captured into a single file for correlation with
# timeout/deferred behavior seen in logs.
{
  echo "=== ip addr ==="
  ip addr 2>/dev/null || /sbin/ifconfig 2>/dev/null || true
  echo
  echo "=== ip route ==="
  ip route 2>/dev/null || /sbin/route -n 2>/dev/null || true
  echo
  echo "=== iptables -S ==="
  iptables -S 2>/dev/null || true
  echo
  echo "=== iptables -L -n -v ==="
  iptables -L -n -v --line-numbers 2>/dev/null || true
} > "$WORK/network.txt"

# Archive only the run folder (not entire OUTDIR/work).
echo "[*] Building tarball..."
( cd "$WORK/.." && tar -cf "$OUTDIR/$BUNDLE" "$(basename "$WORK")" )

echo
echo "[OK] Bundle created:"
echo "  $OUTDIR/$BUNDLE"
echo
echo "Transfer this tar to Debian and run scripts/analyze_bundle.sh on it."
