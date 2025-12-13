#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="$HOME/fadzpay"
BIN_DIR="$BASE_DIR/bin"
BOOT_FILE="$HOME/.termux/boot/fadzpay-heartbeat.sh"

echo "Stopping heartbeat..."
if [ -x "$BIN_DIR/heartbeatctl.sh" ]; then
  "$BIN_DIR/heartbeatctl.sh" stop || true
fi

rm -f "$BIN_DIR/heartbeat.sh" "$BIN_DIR/heartbeatctl.sh" 2>/dev/null || true
rm -f "$BASE_DIR/state/heartbeat.pid" 2>/dev/null || true
rm -f "$BOOT_FILE" 2>/dev/null || true

echo "✅ Heartbeat addon removed"
