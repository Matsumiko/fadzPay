#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="${HOME}/fadzpay"
TMUX_SESSION="fadzpay"
BOOT_FILE="${HOME}/.termux/boot/fadzpay.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

info "Stopping fadzPay (best effort)..."

if need_cmd tmux; then
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null && tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi

pkill -f "$BASE_DIR/bin/watchdog.sh" 2>/dev/null || true
pkill -f "$BASE_DIR/bin/forwarder.sh" 2>/dev/null || true

rm -f "$BASE_DIR/state/forwarder.pid" 2>/dev/null || true
rm -f "$BASE_DIR/state/watchdog.pid" 2>/dev/null || true

termux-notification-remove walletfw 2>/dev/null || true
termux-notification-remove walletwd 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true

ok "Services stopped"

info "Removing boot script..."
if [ -f "$BOOT_FILE" ]; then
  rm -f "$BOOT_FILE"
  ok "Removed: $BOOT_FILE"
else
  warn "Boot file not found: $BOOT_FILE"
fi

if [ -d "$BASE_DIR" ]; then
  ts="$(date '+%Y%m%d_%H%M%S')"
  backup="${HOME}/fadzpay_removed_${ts}"
  info "Backup folder -> $backup"
  mv "$BASE_DIR" "$backup"
  ok "Moved $BASE_DIR to $backup"
else
  warn "Folder not found: $BASE_DIR"
fi

info "Optional: revert some root settings?"
if command -v su >/dev/null 2>&1; then
  read -rp "Coba remove whitelist/appops untuk Termux/GoPay Merchant? (y/n): " -n 1 rr; echo
  if [[ "${rr:-n}" =~ ^[Yy]$ ]]; then
    for pkg in com.termux com.termux.api com.termux.boot com.gojek.gopaymerchant; do
      su -c "dumpsys deviceidle whitelist -$pkg" >/dev/null 2>&1 || true
      su -c "cmd appops reset $pkg" >/dev/null 2>&1 || true
    done
    ok "Root revert attempted (best effort)"
  else
    warn "Skipped root revert"
  fi
fi

ok "Uninstall done ✅"
