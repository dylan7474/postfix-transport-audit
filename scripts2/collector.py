#!/bin/bash
# ==============================================================================
# Universal Log & Config Collector
# Collects ALL traffic and configurations for comprehensive local analysis.
# Run this repeatedly to verify traffic dropping to zero.
# ==============================================================================

HOSTNAME=$(hostname)
OUT_DIR="/tmp/${HOSTNAME}_universal_data"
ARCHIVE="/tmp/${HOSTNAME}_complete_export.tar.gz"

echo "[*] Starting universal data collection on $HOSTNAME..."

# 1. Create temporary staging area
mkdir -p "$OUT_DIR/logs"
mkdir -p "$OUT_DIR/config"

# 2. Collect ALL raw maillogs
# Copying the raw files is safer for /tmp disk space than uncompressing gigabytes of text
echo "  -> Copying all raw maillog files..."
cp /var/log/maillog* "$OUT_DIR/logs/" 2>/dev/null

# 3. Collect ALL Postfix configurations, maps, and transport lists
echo "  -> Copying entire Postfix configuration directory..."
cp -r /etc/postfix "$OUT_DIR/config/" 2>/dev/null

# 4. Package everything into a single tarball
echo "  -> Archiving data (this may take a moment depending on log size)..."
tar -czf "$ARCHIVE" -C /tmp "${HOSTNAME}_universal_data"

# 5. Clean up the staging directory to free up space
rm -rf "$OUT_DIR"

echo ""
echo "[!] Collection complete. Export file created:"
echo "    $ARCHIVE"
echo "    Transfer this file to your local Linux server for comprehensive analysis."
