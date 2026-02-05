#!/bin/bash
set -euo pipefail

# Collect Postfix-related config + logs + minimal system metadata into a tarball.
# Designed to run on old RHEL6 (no fancy dependencies).

OUTDIR="${OUTDIR:-/tmp/postfix-audit}"
BASENAME="${BASENAME:-postfix-audit}"
HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
BUNDLE="${BASENAME}-${HOST}-${TS}.tar"

mkdir -p "$OUTDIR/work"
WORK="$OUTDIR/work/${BASENAME}-${HOST}-${TS}"
mkdir -p "$WORK"

echo "[*] Writing metadata..."
{
  echo "host=$HOST"
  echo "timestamp=$TS"
  echo "uname=$(uname -a)"
  echo "date_rfc=$(date -R)"
} > "$WORK/metadata.txt"

# Minimal commands if available
{
  echo "=== postconf -n ==="
  postconf -n 2>/dev/null || true
  echo
  echo "=== postconf -m ==="
  postconf -m 2>/dev/null || true
} > "$WORK/postfix-postconf.txt"

# Config capture (best-effort)
echo "[*] Copying postfix config..."
mkdir -p "$WORK/etc"
if [ -d /etc/postfix ]; then
  cp -a /etc/postfix "$WORK/etc/" 2>/dev/null || true
fi

# Your custom maps (best-effort)
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

# Log capture (copy only, no compression on source)
echo "[*] Copying logs..."
mkdir -p "$WORK/logs"
# Adjust if you also need /var/log/messages, etc.
for f in /var/log/maillog*; do
  [ -e "$f" ] && cp -p "$f" "$WORK/logs/" || true
done

# Queue snapshot (optional but helpful)
echo "[*] Capturing queue snapshot..."
postqueue -p > "$WORK/postqueue.txt" 2>/dev/null || true
mailq > "$WORK/mailq.txt" 2>/dev/null || true

# Network sanity (helps prove timeouts are real)
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

echo "[*] Building tarball..."
( cd "$WORK/.." && tar -cf "$OUTDIR/$BUNDLE" "$(basename "$WORK")" )

echo
echo "[OK] Bundle created:"
echo "  $OUTDIR/$BUNDLE"
echo
echo "Transfer this tar to Debian and run scripts/analyze_bundle.sh on it."
