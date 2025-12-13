#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

# =================================================
# fadzPay Uninstaller (Termux)
# - stop tmux + watchdog + forwarder
# - remove Termux:Boot autostart
# - remove install directory
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

BASE_DIR="${HOME}/fadzpay"
TMUX_SESSION="fadzpay"
BOOT_FILE="${HOME}/.termux/boot/fadzpay.sh"

print_banner(){
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════╗"
  echo "║         fadzPay Uninstaller          ║"
  echo "╚══════════════════════════════════════╝"
  echo -e "${NC}"
}

print_banner

if [ ! -d "$BASE_DIR" ]; then
  warn "Folder tidak ditemukan: $BASE_DIR"
  warn "Aku tetap coba stop proses & hapus boot script..."
fi

info "Stopping services (best effort)..."

# stop tmux session
if need_cmd tmux; then
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    ok "Stopped tmux session: $TMUX_SESSION"
  else
    info "tmux session not found: $TMUX_SESSION"
  fi
else
  info "tmux not installed, skipping tmux stop"
fi

# kill watchdog & forwarder processes
pkill -f "$BASE_DIR/bin/watchdog.sh" 2>/dev/null || true
pkill -f "$BASE_DIR/bin/forwarder.sh" 2>/dev/null || true
pkill -f "$BASE_DIR/bin/fadzpay" 2>/dev/null || true

# remove notifications + wake lock
termux-notification-remove walletfw 2>/dev/null || true
termux-notification-remove walletwd 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true
ok "Stopped background processes (best effort)"

info "Removing Termux:Boot autostart..."
if [ -f "$BOOT_FILE" ]; then
  rm -f "$BOOT_FILE"
  ok "Removed boot file: $BOOT_FILE"
else
  info "Boot file not found: $BOOT_FILE"
fi

info "Removing install directory..."
if [ -d "$BASE_DIR" ]; then
  rm -rf "$BASE_DIR"
  ok "Removed directory: $BASE_DIR"
else
  info "Directory already absent"
fi

# Optional: re-enable doze (only if previously disabled)
if command -v su >/dev/null 2>&1; then
  echo
  warn "Optional root step:"
  echo "Kalau sebelumnya kamu sempat pilih 'disable doze total', ini bisa dibalikin."
  read -rp "Enable DOZE lagi? (y/n): " -n 1 rr; echo
  if [[ "${rr:-n}" =~ ^[Yy]$ ]]; then
    su -c "dumpsys deviceidle enable" >/dev/null 2>&1 || true
    su -c "cmd deviceidle enable" >/dev/null 2>&1 || true
    ok "Doze enabled (best effort)"
  else
    info "Skipped doze enable"
  fi
fi

echo
ok "Uninstall selesai ✅"
