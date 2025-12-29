#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# =================================================
# fadzPay (Termux) - GoPay Merchant Notification Forwarder
# Optimized + Samsung/OEM anti-boomerang edition (FIXED)
#
# Fixes:
# - No stray "EOF" line at end (no more: EOF: command not found)
# - Root listener component quoting fixed (prevents $NotificationService expansion)
#
# Features:
# - Smart reinstall, TMUX, Watchdog, Heartbeat hang detection
# - Queue + retry + backoff + ttl + net-check + dedupe
# - Robust termux-notification-list: timeout + retry + auto-heal (root)
# - Root helper: Termux:API KeepAliveService + allow_listener NotificationListener
# - Boot via Termux:Boot
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALLER_VERSION="2025.12.29-fix1"

print_header() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║                 fadzPay Installer                    ║"
  echo "║     GoPay Merchant Forwarder (TMUX + Queue + Heal)   ║"
  echo "║               v${INSTALLER_VERSION}                      ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

die(){ err "$1"; exit 1; }

print_header

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------
BASE_DIR="${HOME}/fadzpay"
BIN_DIR="$BASE_DIR/bin"
LOG_DIR="$BASE_DIR/logs"
STATE_DIR="$BASE_DIR/state"
CONF_DIR="$BASE_DIR/config"
QUEUE_DIR="$BASE_DIR/queue"
MARKER_FILE="$BASE_DIR/.fadzpay_installed_marker"

TMUX_SESSION="fadzpay"
BOOT_FILE="${HOME}/.termux/boot/fadzpay.sh"

AUTO_YES="${AUTO_YES:-0}"   # AUTO_YES=1 ./install_fadzpay.sh

# IMPORTANT: keep \$ in the component so it survives through root shell parsing
TERMUX_API_NL_COMPONENT='com.termux.api/com.termux.api.apis.NotificationListAPI\$NotificationService'

stop_everything_best_effort() {
  info "Stopping existing services (best effort)..."

  if need_cmd tmux; then
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null && tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi

  pkill -f "$BASE_DIR/bin/watchdog.sh" 2>/dev/null || true
  pkill -f "$BASE_DIR/bin/forwarder.sh" 2>/dev/null || true
  pkill -f "$BASE_DIR/bin/notif_keeper.sh" 2>/dev/null || true

  rm -f "$STATE_DIR/forwarder.pid" 2>/dev/null || true
  rm -f "$STATE_DIR/watchdog.pid" 2>/dev/null || true
  rm -f "$STATE_DIR/notif_keeper.pid" 2>/dev/null || true

  termux-notification-remove walletfw 2>/dev/null || true
  termux-notification-remove walletwd 2>/dev/null || true
  termux-notification-remove walletnk 2>/dev/null || true
  termux-wake-unlock 2>/dev/null || true

  ok "Stop step done"
}

backup_or_remove_old_install() {
  if [ ! -d "$BASE_DIR" ]; then
    return 0
  fi

  info "Detected existing folder: $BASE_DIR"
  stop_everything_best_effort

  if [ -f "$MARKER_FILE" ]; then
    info "Old install detected (marker found). Removing old install..."
    rm -rf "$BASE_DIR"
    ok "Old install removed"
  else
    ts="$(date '+%Y%m%d_%H%M%S')"
    backup="${HOME}/fadzpay_backup_${ts}"
    warn "Folder exists but marker NOT found."
    warn "Auto-backup rename to: $backup"
    mv "$BASE_DIR" "$backup"
    ok "Backup created"
  fi
}

gen_device_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
    return 0
  fi
  local a
  a="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  echo "${a:0:8}-${a:8:4}-${a:12:4}-${a:16:4}-${a:20:12}"
}

normalize_url() {
  local u="$1"
  while [[ "$u" == */ ]]; do u="${u%/}"; done
  echo "$u"
}

# ============================================================================
# 1) Update & Install Dependencies
# ============================================================================
info "[1/9] Updating packages..."
pkg update -y >/dev/null 2>&1 && ok "Package index updated" || warn "pkg update failed (skip)"
pkg upgrade -y >/dev/null 2>&1 && ok "Packages upgraded" || warn "pkg upgrade failed (skip)"

info "[2/9] Installing dependencies..."
PACKAGES=(curl jq coreutils grep sed openssl-tool gawk procps termux-api tmux)
for p in "${PACKAGES[@]}"; do
  if pkg install -y "$p" >/dev/null 2>&1; then ok "Installed: $p"; else warn "Failed install: $p (maybe already)"; fi
done

if ! need_cmd termux-notification-list; then
  echo
  err "termux-notification-list tidak ditemukan!"
  echo -e "${YELLOW}Wajib:${NC}"
  echo "1) Install Termux:API (F-Droid / sumber yang sama dengan Termux)"
  echo "2) Buka Termux:API sekali"
  echo "3) Settings → Apps → Special access → Notification access → enable Termux:API"
  echo
  read -rp "Lanjutkan instalasi? (y/n): " -n 1 c; echo
  [[ "${c:-n}" =~ ^[Yy]$ ]] || exit 1
fi

# ============================================================================
# 3) Smart Reinstall Detect
# ============================================================================
info "[3/9] Smart install detector..."
backup_or_remove_old_install

# ============================================================================
# 4) Setup Directories
# ============================================================================
info "[4/9] Setting up directories..."
mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR" "$CONF_DIR" "$QUEUE_DIR"
touch "$MARKER_FILE"
chmod 600 "$MARKER_FILE" 2>/dev/null || true
ok "Prepared: $BASE_DIR"

# ============================================================================
# 5) Configuration Input
# ============================================================================
info "[5/9] Configuration setup..."
echo

while true; do
  read -rp "$(echo -e ${CYAN}API_BASE_URL${NC}) (contoh: https://domainkamu.id): " API_BASE
  API_BASE="$(normalize_url "${API_BASE:-}")"
  if [ -z "$API_BASE" ]; then
    err "API_BASE_URL wajib diisi!"
  elif [[ ! "$API_BASE" =~ ^https?:// ]]; then
    err "URL harus dimulai dengan http:// atau https://"
  else
    ok "URL set: $API_BASE"
    break
  fi
done

while true; do
  read -rsp "$(echo -e ${CYAN}TOKEN${NC}) (harus sama dengan TOKEN di server kamu): " TOKEN
  echo
  if [ -z "${TOKEN:-}" ]; then err "TOKEN wajib diisi!"; else ok "Token configured (${#TOKEN} chars)"; break; fi
done

DEFAULT_SECRET="$(openssl rand -hex 16 2>/dev/null || echo "changeme")"
read -rsp "$(echo -e ${CYAN}SECRET${NC}) [default: auto-generated]: " SECRET
echo
SECRET="${SECRET:-$DEFAULT_SECRET}"
ok "Secret set (${#SECRET} chars)"

DEFAULT_PIN="123456"
read -rsp "$(echo -e ${CYAN}PIN${NC}) [default: $DEFAULT_PIN]: " PIN
echo
PIN="${PIN:-$DEFAULT_PIN}"
ok "PIN configured"

DEFAULT_DEVICE_ID="$(gen_device_id)"
read -rp "$(echo -e ${CYAN}DEVICE_ID${NC}) (opsional, contoh: S8-WIFI / S8-PLUS-DATA) [enter=auto]: " DEVICE_ID
DEVICE_ID="${DEVICE_ID:-$DEFAULT_DEVICE_ID}"
ok "Device ID: ${DEVICE_ID}"

read -rp "$(echo -e ${CYAN}INTERVAL_SEC${NC}) (boleh float, contoh 0.5) [default: 0.5]: " INTERVAL_SEC
INTERVAL_SEC="${INTERVAL_SEC:-0.5}"
if ! [[ "$INTERVAL_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  warn "INTERVAL_SEC invalid, set to 0.5"
  INTERVAL_SEC="0.5"
fi
if ! awk -v v="$INTERVAL_SEC" 'BEGIN{exit !(v>=0.2)}'; then
  warn "INTERVAL_SEC terlalu kecil, set ke 0.5"
  INTERVAL_SEC="0.5"
fi
ok "Interval: ${INTERVAL_SEC}s"

read -rp "$(echo -e ${CYAN}MIN_AMOUNT${NC}) (Rp) [default: 1]: " MIN_AMOUNT
MIN_AMOUNT="${MIN_AMOUNT:-1}"
if ! [[ "$MIN_AMOUNT" =~ ^[0-9]+$ ]] || [ "$MIN_AMOUNT" -lt 1 ]; then
  warn "MIN_AMOUNT invalid, set to 1"
  MIN_AMOUNT=1
fi
ok "Min amount: Rp $MIN_AMOUNT"

read -rp "$(echo -e ${CYAN}WATCHDOG_INTERVAL${NC}) detik [default: 20]: " WATCHDOG_INTERVAL
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-20}"
if ! [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]] || [ "$WATCHDOG_INTERVAL" -lt 5 ]; then
  warn "WATCHDOG_INTERVAL invalid, set to 20"
  WATCHDOG_INTERVAL=20
fi
ok "Watchdog interval: ${WATCHDOG_INTERVAL}s"

read -rp "$(echo -e ${CYAN}HEARTBEAT_STALE_SEC${NC}) watchdog restart kalau forwarder ngehang (detik) [default: 90]: " HEARTBEAT_STALE_SEC
HEARTBEAT_STALE_SEC="${HEARTBEAT_STALE_SEC:-90}"
if ! [[ "$HEARTBEAT_STALE_SEC" =~ ^[0-9]+$ ]] || [ "$HEARTBEAT_STALE_SEC" -lt 30 ]; then
  warn "HEARTBEAT_STALE_SEC invalid, set to 90"
  HEARTBEAT_STALE_SEC=90
fi
ok "Heartbeat stale: ${HEARTBEAT_STALE_SEC}s"

read -rp "$(echo -e ${CYAN}QUEUE_MAX_LINES${NC}) [default: 3000]: " QUEUE_MAX_LINES
QUEUE_MAX_LINES="${QUEUE_MAX_LINES:-3000}"
if ! [[ "$QUEUE_MAX_LINES" =~ ^[0-9]+$ ]] || [ "$QUEUE_MAX_LINES" -lt 200 ]; then
  warn "QUEUE_MAX_LINES invalid, set to 3000"
  QUEUE_MAX_LINES=3000
fi
ok "Queue max lines: ${QUEUE_MAX_LINES}"

read -rp "$(echo -e ${CYAN}QUEUE_TTL_HOURS${NC}) (drop pending lewat TTL) [default: 48]: " QUEUE_TTL_HOURS
QUEUE_TTL_HOURS="${QUEUE_TTL_HOURS:-48}"
if ! [[ "$QUEUE_TTL_HOURS" =~ ^[0-9]+$ ]] || [ "$QUEUE_TTL_HOURS" -lt 1 ]; then
  warn "QUEUE_TTL_HOURS invalid, set to 48"
  QUEUE_TTL_HOURS=48
fi
ok "Queue TTL: ${QUEUE_TTL_HOURS} hours"

read -rp "$(echo -e ${CYAN}NETCHECK_ENABLE${NC}) (skip flush jika net down) y/n [default: y]: " NETCHECK_ENABLE
NETCHECK_ENABLE="${NETCHECK_ENABLE:-y}"
[[ "$NETCHECK_ENABLE" =~ ^[Yy]$ ]] && NETCHECK_ENABLE="1" || NETCHECK_ENABLE="0"
ok "Net-check: $([ "$NETCHECK_ENABLE" = "1" ] && echo enabled || echo disabled)"

DEFAULT_TITLE_REGEX='Pembayaran[[:space:]]+diterima'
DEFAULT_CONTENT_REGEX='QRIS.*[Rr][Pp][[:space:]]*[0-9]'
read -rp "$(echo -e ${CYAN}TITLE_REGEX${NC}) (grep -E) [default: $DEFAULT_TITLE_REGEX]: " TITLE_REGEX
TITLE_REGEX="${TITLE_REGEX:-$DEFAULT_TITLE_REGEX}"
ok "TITLE_REGEX: $TITLE_REGEX"

read -rp "$(echo -e ${CYAN}CONTENT_REGEX${NC}) (grep -E) [default: $DEFAULT_CONTENT_REGEX]: " CONTENT_REGEX
CONTENT_REGEX="${CONTENT_REGEX:-$DEFAULT_CONTENT_REGEX}"
ok "CONTENT_REGEX: $CONTENT_REGEX"

DEFAULT_ALLOW_PACKAGES='com.gojek.gopaymerchant'
read -rp "$(echo -e ${CYAN}ALLOW_PACKAGES${NC}) (comma-separated) [default: $DEFAULT_ALLOW_PACKAGES]: " ALLOW_PACKAGES
ALLOW_PACKAGES="${ALLOW_PACKAGES:-$DEFAULT_ALLOW_PACKAGES}"
ok "Allow packages: $ALLOW_PACKAGES"

read -rp "$(echo -e ${CYAN}NOTIF_CMD_TIMEOUT${NC}) timeout termux-notification-list (detik) [default: 4]: " NOTIF_CMD_TIMEOUT
NOTIF_CMD_TIMEOUT="${NOTIF_CMD_TIMEOUT:-4}"
if ! [[ "$NOTIF_CMD_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$NOTIF_CMD_TIMEOUT" -lt 2 ]; then
  warn "NOTIF_CMD_TIMEOUT invalid, set to 4"
  NOTIF_CMD_TIMEOUT=4
fi
ok "Notif cmd timeout: ${NOTIF_CMD_TIMEOUT}s"

read -rp "$(echo -e ${CYAN}NOTIF_RETRY_COUNT${NC}) retry saat notif list error [default: 3]: " NOTIF_RETRY_COUNT
NOTIF_RETRY_COUNT="${NOTIF_RETRY_COUNT:-3}"
if ! [[ "$NOTIF_RETRY_COUNT" =~ ^[0-9]+$ ]] || [ "$NOTIF_RETRY_COUNT" -lt 1 ] || [ "$NOTIF_RETRY_COUNT" -gt 10 ]; then
  warn "NOTIF_RETRY_COUNT invalid, set to 3"
  NOTIF_RETRY_COUNT=3
fi
ok "Notif retry count: ${NOTIF_RETRY_COUNT}"

read -rp "$(echo -e ${CYAN}NOTIF_RETRY_DELAY${NC}) jeda antar retry (boleh float) [default: 0.2]: " NOTIF_RETRY_DELAY
NOTIF_RETRY_DELAY="${NOTIF_RETRY_DELAY:-0.2}"
if ! [[ "$NOTIF_RETRY_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  warn "NOTIF_RETRY_DELAY invalid, set to 0.2"
  NOTIF_RETRY_DELAY="0.2"
fi
ok "Notif retry delay: ${NOTIF_RETRY_DELAY}s"

ROOT_HEAL_ENABLE_DEFAULT="1"
TERMUX_API_KEEPALIVE_ENABLE_DEFAULT="1"
if ! command -v su >/dev/null 2>&1; then
  ROOT_HEAL_ENABLE_DEFAULT="0"
  TERMUX_API_KEEPALIVE_ENABLE_DEFAULT="0"
fi

read -rp "$(echo -e ${CYAN}ROOT_HEAL_ENABLE${NC}) auto-heal notif listener (root) y/n [default: $([ "$ROOT_HEAL_ENABLE_DEFAULT" = "1" ] && echo y || echo n)]: " ROOT_HEAL_ENABLE_IN
ROOT_HEAL_ENABLE_IN="${ROOT_HEAL_ENABLE_IN:-$([ "$ROOT_HEAL_ENABLE_DEFAULT" = "1" ] && echo y || echo n)}"
[[ "$ROOT_HEAL_ENABLE_IN" =~ ^[Yy]$ ]] && ROOT_HEAL_ENABLE="1" || ROOT_HEAL_ENABLE="0"
ok "Root heal: $([ "$ROOT_HEAL_ENABLE" = "1" ] && echo enabled || echo disabled)"

read -rp "$(echo -e ${CYAN}TERMUX_API_KEEPALIVE_ENABLE${NC}) start Termux:API KeepAliveService (root) y/n [default: $([ "$TERMUX_API_KEEPALIVE_ENABLE_DEFAULT" = "1" ] && echo y || echo n)]: " KEEPALIVE_IN
KEEPALIVE_IN="${KEEPALIVE_IN:-$([ "$TERMUX_API_KEEPALIVE_ENABLE_DEFAULT" = "1" ] && echo y || echo n)}"
[[ "$KEEPALIVE_IN" =~ ^[Yy]$ ]] && TERMUX_API_KEEPALIVE_ENABLE="1" || TERMUX_API_KEEPALIVE_ENABLE="0"
ok "Termux:API keepalive: $([ "$TERMUX_API_KEEPALIVE_ENABLE" = "1" ] && echo enabled || echo disabled)"

CONFIG_FILE="$CONF_DIR/config.env"
cat > "$CONFIG_FILE" <<EOF
# fadzPay Config (auto-generated)
API_BASE='${API_BASE}'
TOKEN='${TOKEN}'
SECRET='${SECRET}'
PIN='${PIN}'
DEVICE_ID='${DEVICE_ID}'
INTERVAL_SEC='${INTERVAL_SEC}'
MIN_AMOUNT='${MIN_AMOUNT}'
WATCHDOG_INTERVAL='${WATCHDOG_INTERVAL}'
HEARTBEAT_STALE_SEC='${HEARTBEAT_STALE_SEC}'
TMUX_SESSION='${TMUX_SESSION}'

# Notification matching
ALLOW_PACKAGES='${ALLOW_PACKAGES}'
TITLE_REGEX='${TITLE_REGEX}'
CONTENT_REGEX='${CONTENT_REGEX}'

# termux-notification-list robustness
NOTIF_CMD_TIMEOUT='${NOTIF_CMD_TIMEOUT}'
NOTIF_RETRY_COUNT='${NOTIF_RETRY_COUNT}'
NOTIF_RETRY_DELAY='${NOTIF_RETRY_DELAY}'

# Queue features
QUEUE_MAX_LINES='${QUEUE_MAX_LINES}'
QUEUE_TTL_HOURS='${QUEUE_TTL_HOURS}'
NETCHECK_ENABLE='${NETCHECK_ENABLE}'

# Anti-boomerang (root)
ROOT_HEAL_ENABLE='${ROOT_HEAL_ENABLE}'
TERMUX_API_KEEPALIVE_ENABLE='${TERMUX_API_KEEPALIVE_ENABLE}'
TERMUX_API_NL_COMPONENT='${TERMUX_API_NL_COMPONENT}'
EOF
chmod 600 "$CONFIG_FILE"
ok "Saved config: $CONFIG_FILE (chmod 600)"

# ============================================================================
# 6) Create Scripts
# ============================================================================
info "[6/9] Creating scripts..."

cat > "$BIN_DIR/scan_notifs.sh" <<'SCAN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ missing: $1"; exit 1; }; }
need termux-notification-list
need jq

BASE_DIR="$HOME/fadzpay"
CONF="$BASE_DIR/config/config.env"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true

ALLOW_PACKAGES="${ALLOW_PACKAGES:-com.gojek.gopaymerchant}"

echo "════════════════════════════════════════════════════════════"
echo "  fadzPay Notification Scanner"
echo "════════════════════════════════════════════════════════════"
echo
echo "Allow packages: $ALLOW_PACKAGES"
echo

echo "📱 All Notifications (package │ title │ content):"
echo "────────────────────────────────────────────────────────────"
termux-notification-list | jq -r '.[] | "\(.packageName)\t│\t\(.title)\t│\t\(.content)"' 2>/dev/null || echo "No notifications"

echo
echo "────────────────────────────────────────────────────────────"
echo "🎯 Filtered (ALLOW_PACKAGES):"
echo "────────────────────────────────────────────────────────────"
IFS=',' read -r -a P <<<"$ALLOW_PACKAGES"
termux-notification-list | jq -r '.[] | "\(.packageName)\t│\t\(.title)\t│\t\(.content)\t│\twhen=\(.when)\t│\tkey=\(.key // .id)"' 2>/dev/null | while IFS= read -r line; do
  pkg="$(printf '%s' "$line" | cut -f1)"
  for x in "${P[@]}"; do
    x="${x//[[:space:]]/}"
    [ -n "$x" ] && [ "$pkg" = "$x" ] && echo "$line"
  done
done
SCAN_EOF
chmod +x "$BIN_DIR/scan_notifs.sh"
ok "Created: scan_notifs.sh"

cat > "$BIN_DIR/doctor.sh" <<'DOC_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BASE_DIR="$HOME/fadzpay"
CONF="$BASE_DIR/config/config.env"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }

need termux-notification-list
need jq
need timeout

echo "════════════════════════════════════════════════════════════"
echo "  fadzPay Doctor"
echo "════════════════════════════════════════════════════════════"

info "Config: $CONF"
info "Allow packages: ${ALLOW_PACKAGES:-com.gojek.gopaymerchant}"
info "Regex title : ${TITLE_REGEX:-}"
info "Regex cont  : ${CONTENT_REGEX:-}"
echo

info "Test termux-notification-list..."
raw="$(timeout "${NOTIF_CMD_TIMEOUT:-4}" termux-notification-list 2>&1 || true)"
if jq -e 'type=="array"' <<<"$raw" >/dev/null 2>&1; then
  ok "termux-notification-list OK (JSON array). count=$(jq 'length' <<<"$raw" 2>/dev/null || echo '?')"
elif jq -e 'type=="object" and has("error")' <<<"$raw" >/dev/null 2>&1; then
  err "Termux:API returned error JSON: $(jq -r '.error' <<<"$raw")"
else
  warn "termux-notification-list output not JSON array. raw: ${raw:0:120}"
fi
echo

if command -v su >/dev/null 2>&1; then
  info "Root detected. Checking notification listener enabled..."
  comp="${TERMUX_API_NL_COMPONENT:-com.termux.api/com.termux.api.apis.NotificationListAPI\$NotificationService}"
  cur="$(su -c "settings get secure enabled_notification_listeners" 2>/dev/null || true)"
  if printf '%s' "$cur" | grep -qF "$comp"; then
    ok "Notification listener is listed in enabled_notification_listeners"
  else
    warn "Listener NOT found in enabled_notification_listeners"
    warn "Try: su -c \"cmd notification allow_listener '$comp'\""
  fi

  info "Starting Termux:API KeepAliveService (best effort)..."
  su -c "am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 && ok "KeepAliveService startservice issued" || warn "KeepAliveService startservice failed (ignored)"
else
  info "No root (su not found). Skipping root checks."
fi
echo
ok "Doctor done."
DOC_EOF
chmod +x "$BIN_DIR/doctor.sh"
ok "Created: doctor.sh"

cat > "$BIN_DIR/forwarder.sh" <<'FORWARDER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
umask 077

BASE_DIR="__BASE_DIR__"
CONFIG_FILE="$BASE_DIR/config/config.env"

LOG_FILE="$BASE_DIR/logs/fadzpay-forwarder.log"
STATE_FILE="$BASE_DIR/state/seen_fingerprints.txt"
HEARTBEAT_FILE="$BASE_DIR/state/heartbeat.ts"

QUEUE_DIR="$BASE_DIR/queue"
QUEUE_FILE="$QUEUE_DIR/pending.jsonl"
QUEUE_TMP="$QUEUE_DIR/pending.tmp"

STATE_MAX_LINES=7000
MAX_AMOUNT=100000000

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }
need jq; need curl; need openssl; need awk; need grep; need sed; need sha256sum; need wc; need tail; need mv; need mkdir; need timeout
need termux-notification-list; need termux-notification

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")" "$QUEUE_DIR" "$BASE_DIR/state"
touch "$LOG_FILE" "$STATE_FILE" "$QUEUE_FILE" "$HEARTBEAT_FILE"
chmod 600 "$STATE_FILE" "$QUEUE_FILE" "$HEARTBEAT_FILE" 2>/dev/null || true

if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ Config missing: $CONFIG_FILE" | tee -a "$LOG_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

API_BASE="${API_BASE%/}"
WEBHOOK_URL="${API_BASE}/webhook/payment"

QUEUE_MAX_LINES="${QUEUE_MAX_LINES:-3000}"
QUEUE_TTL_HOURS="${QUEUE_TTL_HOURS:-48}"
NETCHECK_ENABLE="${NETCHECK_ENABLE:-1}"
INTERVAL_SEC="${INTERVAL_SEC:-0.5}"
MIN_AMOUNT="${MIN_AMOUNT:-1}"

ALLOW_PACKAGES="${ALLOW_PACKAGES:-com.gojek.gopaymerchant}"
TITLE_REGEX="${TITLE_REGEX:-Pembayaran[[:space:]]+diterima}"
CONTENT_REGEX="${CONTENT_REGEX:-QRIS.*[Rr][Pp][[:space:]]*[0-9]}"

NOTIF_CMD_TIMEOUT="${NOTIF_CMD_TIMEOUT:-4}"
NOTIF_RETRY_COUNT="${NOTIF_RETRY_COUNT:-3}"
NOTIF_RETRY_DELAY="${NOTIF_RETRY_DELAY:-0.2}"

ROOT_HEAL_ENABLE="${ROOT_HEAL_ENABLE:-0}"
TERMUX_API_KEEPALIVE_ENABLE="${TERMUX_API_KEEPALIVE_ENABLE:-0}"
TERMUX_API_NL_COMPONENT="${TERMUX_API_NL_COMPONENT:-com.termux.api/com.termux.api.apis.NotificationListAPI\$NotificationService}"

TTL_MS=$(( QUEUE_TTL_HOURS * 60 * 60 * 1000 ))

DEVICE_ID_STATE="$BASE_DIR/state/device_id.txt"

log(){ echo "$*" | tee -a "$LOG_FILE"; }

trim_file_by_lines(){
  local f="$1" max="$2"
  local lines keep
  lines="$(wc -l < "$f" | tr -d ' ' 2>/dev/null || echo 0)"
  if [ "${lines:-0}" -gt "$max" ]; then
    keep=$(( max * 80 / 100 ))
    tail -n "$keep" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  fi
}
trim_state(){ trim_file_by_lines "$STATE_FILE" "$STATE_MAX_LINES"; }
trim_queue(){ trim_file_by_lines "$QUEUE_FILE" "$QUEUE_MAX_LINES"; }

extract_amount(){
  local s="$1" a
  a=$(printf '%s' "$s" | sed -nE 's/.*[Rr][Pp][[:space:]]*([0-9][0-9\.\,]*).*/\1/p' | head -n1 || true)
  a="${a//[^0-9]/}"
  [ -n "$a" ] && echo "$a" || echo ""
}

now_ms(){
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  if [ -n "$t" ] && [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"; else echo $(( $(date +%s) * 1000 )); fi
}

gen_device_id(){
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
    return 0
  fi
  local a
  a="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  echo "${a:0:8}-${a:8:4}-${a:12:4}-${a:16:4}-${a:20:12}"
}

DEVICE_ID="${DEVICE_ID:-}"
if [ -z "${DEVICE_ID}" ] && [ -s "$DEVICE_ID_STATE" ]; then
  DEVICE_ID="$(head -n1 "$DEVICE_ID_STATE" 2>/dev/null | tr -d '\r\n' || true)"
fi
if [ -z "${DEVICE_ID}" ]; then
  DEVICE_ID="$(gen_device_id)"
  echo "$DEVICE_ID" > "$DEVICE_ID_STATE"
  chmod 600 "$DEVICE_ID_STATE" 2>/dev/null || true
fi

hmac_sig_hex(){
  local msg="$1"
  printf '%s' "$msg" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}'
}

post_json(){
  local body="$1"
  local ts sig input out
  ts="$(now_ms)"
  input="${ts}.${body}"
  sig="$(hmac_sig_hex "$input")"

  out="$(curl -sS --max-time 12 --connect-timeout 6 \
    --retry 1 --retry-delay 1 --retry-connrefused \
    -o /dev/null -w "HTTP=%{http_code}" \
    -H "Content-Type: application/json" \
    -H "X-Forwarder-Token: ${TOKEN}" \
    -H "X-Forwarder-Pin: ${PIN}" \
    -H "X-Device-Id: ${DEVICE_ID}" \
    -H "X-TS: ${ts}" \
    -H "X-Signature: ${sig}" \
    -X POST "$WEBHOOK_URL" \
    --data-raw "$body" 2>&1 || true)"

  echo "$out"
}

is_http_2xx(){ [[ "$1" =~ HTTP=2[0-9][0-9]$ ]]; }

net_is_up(){
  local code
  code="$(curl -sS -I --max-time 5 --connect-timeout 4 "$API_BASE" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")"
  [ "$code" != "000" ]
}

has_root(){ command -v su >/dev/null 2>&1; }

root_start_keepalive(){
  [ "$TERMUX_API_KEEPALIVE_ENABLE" = "1" ] || return 0
  has_root || return 0
  su -c "am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 || true
}

root_allow_notif_listener(){
  [ "$ROOT_HEAL_ENABLE" = "1" ] || return 0
  has_root || return 0

  # ✅ IMPORTANT: quote the component in root shell to prevent $ expansion
  su -c "cmd notification allow_listener '$TERMUX_API_NL_COMPONENT'" >/dev/null 2>&1 && return 0

  # fallback: secure settings (best effort)
  local cur new
  cur="$(su -c "settings get secure enabled_notification_listeners" 2>/dev/null || true)"
  if printf '%s' "$cur" | grep -qF "$TERMUX_API_NL_COMPONENT"; then
    return 0
  fi
  if [ -z "$cur" ] || [ "$cur" = "null" ]; then
    new="$TERMUX_API_NL_COMPONENT"
  else
    new="${cur}:${TERMUX_API_NL_COMPONENT}"
  fi
  su -c "settings put secure enabled_notification_listeners '$new'" >/dev/null 2>&1 || true
}

root_heal_notif_backend(){
  [ "$ROOT_HEAL_ENABLE" = "1" ] || return 0
  has_root || return 0

  root_start_keepalive
  root_allow_notif_listener

  # optional force rebind (quoted)
  su -c "cmd notification disallow_listener '$TERMUX_API_NL_COMPONENT'" >/dev/null 2>&1 || true
  su -c "cmd notification allow_listener '$TERMUX_API_NL_COMPONENT'" >/dev/null 2>&1 || true
}

declare -A SEEN
while read -r fp; do
  [ -n "$fp" ] && SEEN["$fp"]=1 || true
done < <(tail -n 8000 "$STATE_FILE" 2>/dev/null || true)

declare -A QIDX
if [ -s "$QUEUE_FILE" ]; then
  while read -r fp; do
    [ -n "$fp" ] && QIDX["$fp"]=1 || true
  done < <(jq -r '.fingerprint // empty' "$QUEUE_FILE" 2>/dev/null | tail -n 12000 || true)
fi

rebuild_qidx(){
  unset QIDX 2>/dev/null || true
  declare -A QIDX
  if [ -s "$QUEUE_FILE" ]; then
    while read -r fp; do
      [ -n "$fp" ] && QIDX["$fp"]=1 || true
    done < <(jq -r '.fingerprint // empty' "$QUEUE_FILE" 2>/dev/null | tail -n 12000 || true)
  fi
}

queue_push(){
  local fingerprint="$1"
  local payload="$2"
  local now

  if [[ -n "${QIDX[$fingerprint]:-}" ]]; then
    return 0
  fi

  now="$(now_ms)"
  jq -nc \
    --arg fp "$fingerprint" \
    --argjson payload "$payload" \
    --arg now "$now" \
    '{fingerprint:$fp, payload:$payload, next_try_ms:($now|tonumber), attempts:0, created_ms:($now|tonumber)}' \
    >> "$QUEUE_FILE"

  QIDX["$fingerprint"]=1
  trim_queue
}

queue_flush(){
  [ -s "$QUEUE_FILE" ] || return 0

  if [ "$NETCHECK_ENABLE" = "1" ]; then
    if ! net_is_up; then
      return 0
    fi
  fi

  local now line fp payload next_try attempts created resp backoff new_next age
  now="$(now_ms)"

  : > "$QUEUE_TMP"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    fp="$(jq -r '.fingerprint // ""' <<<"$line" 2>/dev/null || echo "")"
    payload="$(jq -c '.payload // empty' <<<"$line" 2>/dev/null || echo "")"
    next_try="$(jq -r '.next_try_ms // 0' <<<"$line" 2>/dev/null || echo 0)"
    attempts="$(jq -r '.attempts // 0' <<<"$line" 2>/dev/null || echo 0)"
    created="$(jq -r '.created_ms // 0' <<<"$line" 2>/dev/null || echo 0)"

    if [ -n "$fp" ] && [[ -n "${SEEN[$fp]:-}" ]]; then
      unset 'QIDX[$fp]' 2>/dev/null || true
      continue
    fi

    if [ "${created:-0}" -gt 0 ]; then
      age=$(( now - created ))
      if [ "$age" -gt "$TTL_MS" ]; then
        log "⚠ [QUEUE] drop TTL | fp=${fp:0:10} | age_ms=$age"
        unset 'QIDX[$fp]' 2>/dev/null || true
        continue
      fi
    fi

    if [ "${next_try:-0}" -gt "$now" ]; then
      echo "$line" >> "$QUEUE_TMP"
      continue
    fi

    [ -n "$payload" ] || { unset 'QIDX[$fp]' 2>/dev/null || true; continue; }

    resp="$(post_json "$payload" || true)"

    if is_http_2xx "$resp"; then
      if [ -n "$fp" ]; then
        SEEN["$fp"]=1
        echo "$fp" >> "$STATE_FILE"
        trim_state
        unset 'QIDX[$fp]' 2>/dev/null || true
      fi
      log "✓ [QUEUE] sent | fp=${fp:0:10} | ${resp}"
      continue
    fi

    attempts=$(( attempts + 1 ))
    backoff=$(( 5 * (2 ** (attempts - 1)) ))
    [ "$backoff" -gt 600 ] && backoff=600
    new_next=$(( now + backoff * 1000 ))

    jq -nc \
      --arg fp "$fp" \
      --argjson payload "$payload" \
      --argjson next_try_ms "$new_next" \
      --argjson attempts "$attempts" \
      --argjson created_ms "$created" \
      '{fingerprint:$fp, payload:$payload, next_try_ms:$next_try_ms, attempts:$attempts, created_ms:$created_ms}' \
      >> "$QUEUE_TMP"

    log "✗ [QUEUE] failed | fp=${fp:0:10} | attempts=$attempts | retry_in=${backoff}s | ${resp:0:120}"
  done < "$QUEUE_FILE"

  mv "$QUEUE_TMP" "$QUEUE_FILE"
  trim_queue
  rebuild_qidx
}

declare -A ALLOW_PKG
IFS=',' read -r -a _pkgs <<<"$ALLOW_PACKAGES"
for p in "${_pkgs[@]}"; do
  p="${p//[[:space:]]/}"
  [ -n "$p" ] && ALLOW_PKG["$p"]=1 || true
done
is_allowed_pkg(){ [[ -n "${ALLOW_PKG[$1]:-}" ]]; }

termux-wake-lock 2>/dev/null || true

cleanup(){
  termux-notification-remove walletfw 2>/dev/null || true
  termux-wake-unlock 2>/dev/null || true
}
trap cleanup EXIT INT TERM

termux-notification \
  --id walletfw \
  --title "fadzPay" \
  --content "🚀 Running..." \
  --ongoing --priority low --alert-once 2>/dev/null || true

log "════════════════════════════════════════════════════════════"
log "  fadzPay Forwarder (GoPay Merchant) + Queue + Auto-Heal"
log "════════════════════════════════════════════════════════════"
log "▶️  Started: $(date '+%Y-%m-%d %H:%M:%S')"
log "🎯 Target : $WEBHOOK_URL"
log "📱 Device : $DEVICE_ID"
log "⏱️  Interval: ${INTERVAL_SEC}s"
log "💰 Min Amount: Rp ${MIN_AMOUNT}"
log "🧩 Allow packages: $ALLOW_PACKAGES"
log "🔎 Regex title : $TITLE_REGEX"
log "🔎 Regex cont  : $CONTENT_REGEX"
log "📦 Queue file: $QUEUE_FILE (max_lines=$QUEUE_MAX_LINES, ttl_h=$QUEUE_TTL_HOURS)"
log "🌐 Net-check: $([ "$NETCHECK_ENABLE" = "1" ] && echo enabled || echo disabled)"
log "🛠 Root heal : $([ "$ROOT_HEAL_ENABLE" = "1" ] && echo enabled || echo disabled)"
log "🧷 API keepalive: $([ "$TERMUX_API_KEEPALIVE_ENABLE" = "1" ] && echo enabled || echo disabled)"
log "════════════════════════════════════════════════════════════"

root_start_keepalive || true
root_allow_notif_listener || true

PROCESSED_COUNT=0
ERROR_COUNT=0
LAST_STATUS_PUSH=0
STATUS_EVERY_MS=15000

LAST_HEARTBEAT_MS=0
HEARTBEAT_EVERY_MS=5000

NOTIF_FAIL_STREAK=0
LAST_HEAL_TS=0
HEAL_COOLDOWN_SEC=120
HEAL_STREAK_THRESHOLD=5

NOTIF_LAST_RAW=""

notif_list_json(){
  local i out
  NOTIF_LAST_RAW=""
  for ((i=1; i<=NOTIF_RETRY_COUNT; i++)); do
    out="$(timeout "$NOTIF_CMD_TIMEOUT" termux-notification-list 2>&1 || true)"
    NOTIF_LAST_RAW="$out"

    if jq -e 'type=="array"' <<<"$out" >/dev/null 2>&1; then
      echo "$out"
      return 0
    fi
    if jq -e 'type=="object" and has("error")' <<<"$out" >/dev/null 2>&1; then
      log "⚠ [NOTIF] Termux:API error: $(jq -r '.error' <<<"$out" 2>/dev/null || echo "unknown")"
      echo "[]"
      return 0
    fi

    sleep "$NOTIF_RETRY_DELAY"
  done
  return 1
}

maybe_heal_notif(){
  local now_s
  now_s="$(date +%s)"
  [ "$ROOT_HEAL_ENABLE" = "1" ] || return 0
  [ "$NOTIF_FAIL_STREAK" -ge "$HEAL_STREAK_THRESHOLD" ] || return 0
  [ $((now_s - LAST_HEAL_TS)) -ge "$HEAL_COOLDOWN_SEC" ] || return 0

  LAST_HEAL_TS="$now_s"
  log "🛠 [NOTIF] Healing backend (streak=$NOTIF_FAIL_STREAK)..."
  root_heal_notif_backend || true
  NOTIF_FAIL_STREAK=0
}

while :; do
  now="$(now_ms)"
  if [ $((now - LAST_HEARTBEAT_MS)) -ge "$HEARTBEAT_EVERY_MS" ]; then
    LAST_HEARTBEAT_MS="$now"
    printf '%s' "$(date +%s)" > "$HEARTBEAT_FILE" 2>/dev/null || true
  fi

  queue_flush || true

  if json="$(notif_list_json)"; then
    NOTIF_FAIL_STREAK=0
  else
    NOTIF_FAIL_STREAK=$((NOTIF_FAIL_STREAK + 1))
    log "⚠ [NOTIF] termux-notification-list failed (streak=$NOTIF_FAIL_STREAK). raw=${NOTIF_LAST_RAW:0:120}"
    maybe_heal_notif || true
    sleep "$INTERVAL_SEC"
    continue
  fi

  while IFS=$'\t' read -r pkg title content when key; do
    [ -n "$pkg" ] || continue
    is_allowed_pkg "$pkg" || continue

    printf '%s' "$title"   | grep -Eiq "$TITLE_REGEX"   || continue
    printf '%s' "$content" | grep -Eiq "$CONTENT_REGEX" || continue

    [ "$when" = "null" ] && when=""
    [ "$key"  = "null" ] && key=""

    amt="$(extract_amount "$content")"
    [ -n "$amt" ] || continue
    if [ "$amt" -lt "$MIN_AMOUNT" ] || [ "$amt" -gt "$MAX_AMOUNT" ]; then
      continue
    fi

    fingerprint="$(printf '%s' "$pkg|$title|$content|$when|$key" | sha256sum | awk '{print $1}')"

    if [[ -n "${SEEN[$fingerprint]:-}" ]]; then
      continue
    fi
    if [[ -n "${QIDX[$fingerprint]:-}" ]]; then
      continue
    fi

    payload="$(jq -nc \
      --arg source "gopay_merchant" \
      --arg package "$pkg" \
      --arg title "$title" \
      --arg content "$content" \
      --arg when "$when" \
      --arg key "$key" \
      --arg fingerprint "$fingerprint" \
      --arg amount "$amt" \
      --arg device_id "$DEVICE_ID" \
      '{
        source: $source,
        package: $package,
        title: $title,
        content: $content,
        when: $when,
        key: $key,
        fingerprint: $fingerprint,
        amount: ($amount|tonumber),
        device_id: $device_id
      }'
    )"

    tslog="$(date '+%Y-%m-%d %H:%M:%S')"
    resp="$(post_json "$payload" || true)"

    if is_http_2xx "$resp"; then
      SEEN["$fingerprint"]=1
      echo "$fingerprint" >> "$STATE_FILE"
      trim_state
      log "✓ $tslog | Rp ${amt} | ${resp} | ${content:0:70}..."
      PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    else
      queue_push "$fingerprint" "$payload"
      log "✗ $tslog | Rp ${amt} | QUEUED | ${resp:0:120} | ${content:0:70}..."
      ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
  done < <(jq -r '.[] | [
      (.packageName // ""),
      (.title // ""),
      (.content // ""),
      ((.when // "")|tostring),
      ((.key // (.id|tostring) // "")|tostring)
    ] | @tsv' <<<"$json" 2>/dev/null || true)

  now="$(now_ms)"
  if [ $((now - LAST_STATUS_PUSH)) -ge "$STATUS_EVERY_MS" ]; then
    LAST_STATUS_PUSH="$now"
    qlines="$(wc -l < "$QUEUE_FILE" | tr -d ' ' 2>/dev/null || echo 0)"
    termux-notification \
      --id walletfw \
      --title "fadzPay" \
      --content "✓ ${PROCESSED_COUNT} | ✗ ${ERROR_COUNT} | Q ${qlines} | $(date '+%H:%M:%S')" \
      --ongoing --priority low --alert-once 2>/dev/null || true
  fi

  sleep "$INTERVAL_SEC"
done
FORWARDER_EOF

sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BIN_DIR/forwarder.sh"
chmod +x "$BIN_DIR/forwarder.sh"
ok "Created: forwarder.sh"

cat > "$BIN_DIR/forwarderctl.sh" <<'CTL_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BASE_DIR="__BASE_DIR__"
SCRIPT="$BASE_DIR/bin/forwarder.sh"
CONFIG="$BASE_DIR/config/config.env"
TMUX_SESSION="fadzpay"

# shellcheck disable=SC1090
[ -f "$CONFIG" ] && source "$CONFIG" || true
[ -n "${TMUX_SESSION:-}" ] && TMUX_SESSION="${TMUX_SESSION}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
need(){ command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}✗${NC} Missing: $1"; exit 1; }; }
need tmux

start(){
  [ -x "$SCRIPT" ] || { echo -e "${RED}✗${NC} Script not executable: $SCRIPT"; exit 1; }
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} Already running (tmux: $TMUX_SESSION)"
    exit 0
  fi
  echo -e "${BLUE}▶${NC} Starting (tmux: $TMUX_SESSION)..."
  termux-wake-lock 2>/dev/null || true
  tmux new-session -d -s "$TMUX_SESSION" "bash '$SCRIPT'"
  sleep 1
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null && echo -e "${GREEN}✓${NC} Started" || { echo -e "${RED}✗${NC} Failed"; exit 1; }
}

stop(){
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${YELLOW}⏹${NC} Stopping (tmux: $TMUX_SESSION)"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    termux-wake-unlock 2>/dev/null || true
    termux-notification-remove walletfw 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Stopped"
  else
    echo -e "${BLUE}ℹ${NC} Not running"
  fi
}

status(){
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Running (tmux: $TMUX_SESSION)"
    exit 0
  fi
  echo -e "${RED}✗${NC} Not running"
  exit 1
}

attach(){ tmux attach -t "$TMUX_SESSION"; }

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop || true; sleep 1; start ;;
  status) status ;;
  attach) attach ;;
  *)
    echo "Usage: $0 start|stop|restart|status|attach"
    exit 1
    ;;
esac
CTL_EOF

sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BIN_DIR/forwarderctl.sh"
chmod +x "$BIN_DIR/forwarderctl.sh"
ok "Created: forwarderctl.sh"

cat > "$BIN_DIR/notif_keeper.sh" <<'NK_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

BASE_DIR="__BASE_DIR__"
CONF="$BASE_DIR/config/config.env"
LOG="$BASE_DIR/logs/fadzpay-notif-keeper.log"
PID_FILE="$BASE_DIR/state/notif_keeper.pid"

mkdir -p "$BASE_DIR/logs" "$BASE_DIR/state"
touch "$LOG"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true

INTERVAL="${1:-60}"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

if [ -f "$PID_FILE" ]; then
  oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "NOTIF_KEEPER already running (pid=$oldpid). Exit."
    exit 0
  fi
fi
echo $$ > "$PID_FILE"
chmod 600 "$PID_FILE" 2>/dev/null || true

cleanup(){ rm -f "$PID_FILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

ROOT_HEAL_ENABLE="${ROOT_HEAL_ENABLE:-0}"
TERMUX_API_KEEPALIVE_ENABLE="${TERMUX_API_KEEPALIVE_ENABLE:-0}"
TERMUX_API_NL_COMPONENT="${TERMUX_API_NL_COMPONENT:-com.termux.api/com.termux.api.apis.NotificationListAPI\$NotificationService}"

if ! command -v su >/dev/null 2>&1; then
  log "su not found -> notif_keeper disabled."
  exit 0
fi

log "NOTIF_KEEPER start | interval=${INTERVAL}s | root_heal=$ROOT_HEAL_ENABLE | keepalive=$TERMUX_API_KEEPALIVE_ENABLE"

while :; do
  if [ "$TERMUX_API_KEEPALIVE_ENABLE" = "1" ]; then
    su -c "am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 || true
  fi

  if [ "$ROOT_HEAL_ENABLE" = "1" ]; then
    # ✅ quote component to avoid $ expansion
    su -c "cmd notification allow_listener '$TERMUX_API_NL_COMPONENT'" >/dev/null 2>&1 || true
  fi

  termux-notification \
    --id walletnk \
    --title "fadzPay NotifKeeper" \
    --content "KeepAlive+Listener OK @ $(date '+%H:%M:%S')" \
    --priority low --alert-once 2>/dev/null || true

  sleep "$INTERVAL"
done
NK_EOF

sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BIN_DIR/notif_keeper.sh"
chmod +x "$BIN_DIR/notif_keeper.sh"
ok "Created: notif_keeper.sh"

cat > "$BIN_DIR/watchdog.sh" <<'WD_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

BASE_DIR="__BASE_DIR__"
CONF="$BASE_DIR/config/config.env"
CTL="$BASE_DIR/bin/forwarderctl.sh"
NK="$BASE_DIR/bin/notif_keeper.sh"
WD_LOG="$BASE_DIR/logs/fadzpay-watchdog.log"
PID_FILE="$BASE_DIR/state/watchdog.pid"
HEARTBEAT_FILE="$BASE_DIR/state/heartbeat.ts"

INTERVAL="${1:-20}"

mkdir -p "$BASE_DIR/logs" "$BASE_DIR/state"
touch "$WD_LOG"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true
[ -n "${WATCHDOG_INTERVAL:-}" ] && INTERVAL="${WATCHDOG_INTERVAL}"

HEARTBEAT_STALE_SEC="${HEARTBEAT_STALE_SEC:-90}"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$WD_LOG"; }

if [ -f "$PID_FILE" ]; then
  oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "WATCHDOG already running (pid=$oldpid). Exit."
    exit 0
  fi
fi
echo $$ > "$PID_FILE"
chmod 600 "$PID_FILE" 2>/dev/null || true

termux-wake-lock 2>/dev/null || true

cleanup(){ rm -f "$PID_FILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fail_burst=0
MAX_FAIL_BURST=5

log "WATCHDOG start | interval=${INTERVAL}s | heartbeat_stale=${HEARTBEAT_STALE_SEC}s"

nohup bash "$NK" 60 >/dev/null 2>&1 & disown || true

while :; do
  if "$CTL" status >/dev/null 2>&1; then
    if [ -f "$HEARTBEAT_FILE" ]; then
      last="$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
      now="$(date +%s)"
      if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ]; then
        age=$((now - last))
        if [ "$age" -gt "$HEARTBEAT_STALE_SEC" ]; then
          log "Heartbeat stale (${age}s > ${HEARTBEAT_STALE_SEC}s). Restarting forwarder..."
          "$CTL" restart >/dev/null 2>&1 || true
          termux-notification \
            --id walletwd \
            --title "fadzPay Watchdog" \
            --content "Heartbeat stale -> restarted @ $(date '+%H:%M:%S')" \
            --priority low --alert-once 2>/dev/null || true
        fi
      fi
    fi
    fail_burst=0
  else
    fail_burst=$((fail_burst + 1))
    log "Forwarder DOWN (burst=$fail_burst). Restarting..."
    "$CTL" start >/dev/null 2>&1 || true

    termux-notification \
      --id walletwd \
      --title "fadzPay Watchdog" \
      --content "Restarted @ $(date '+%H:%M:%S')" \
      --priority low --alert-once 2>/dev/null || true

    if [ "$fail_burst" -ge "$MAX_FAIL_BURST" ]; then
      log "Too many fails. Cooling down 120s..."
      sleep 120
      fail_burst=0
    fi
  fi
  sleep "$INTERVAL"
done
WD_EOF

sed -i "s|__BASE_DIR__|$BASE_DIR|g" "$BIN_DIR/watchdog.sh"
chmod +x "$BIN_DIR/watchdog.sh"
ok "Created: watchdog.sh"

cat > "$BIN_DIR/start-fadzpay.sh" <<'BOOT_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

BASE_DIR="$HOME/fadzpay"
CONF="$BASE_DIR/config/config.env"
CTL="$BASE_DIR/bin/forwarderctl.sh"
WD="$BASE_DIR/bin/watchdog.sh"
NK="$BASE_DIR/bin/notif_keeper.sh"

sleep 8
termux-wake-lock 2>/dev/null || true

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true

if command -v su >/dev/null 2>&1; then
  if [ "${TERMUX_API_KEEPALIVE_ENABLE:-0}" = "1" ]; then
    su -c "am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 || true
  fi
  if [ "${ROOT_HEAL_ENABLE:-0}" = "1" ]; then
    comp="${TERMUX_API_NL_COMPONENT:-com.termux.api/com.termux.api.apis.NotificationListAPI\$NotificationService}"
    su -c "cmd notification allow_listener '$comp'" >/dev/null 2>&1 || true
  fi
fi

"$CTL" start >/dev/null 2>&1 || true
nohup bash "$WD" >/dev/null 2>&1 & disown || true
nohup bash "$NK" 60 >/dev/null 2>&1 & disown || true
BOOT_EOF

chmod +x "$BIN_DIR/start-fadzpay.sh"
mkdir -p "$HOME/.termux/boot"
cp -f "$BIN_DIR/start-fadzpay.sh" "$BOOT_FILE"
chmod +x "$BOOT_FILE"
ok "Created boot script: $BOOT_FILE"

# ============================================================================
# 7) Optional: Root anti-doze (dedicated device)
# ============================================================================
info "[7/9] Optional root optimization (anti-doze)..."
if command -v su >/dev/null 2>&1; then
  rr="n"
  if [ "$AUTO_YES" = "1" ]; then rr="y"; fi

  if [ "$AUTO_YES" != "1" ]; then
    echo -e "${YELLOW}Kamu root. Apply anti-doze biar notif gak ketahan?${NC}"
    echo "Will run (best effort):"
    echo "  deviceidle whitelist + com.termux/com.termux.api/com.termux.boot/com.gojek.gopaymerchant"
    echo "  appops allow background + wakelock"
    echo "  set-standby-bucket active (kalau supported)"
    echo "  enable notification listener via cmd notification allow_listener (Termux:API)"
    read -rp "Apply sekarang? (y/n): " -n 1 rr; echo
  else
    info "AUTO_YES=1 -> applying root anti-doze automatically"
  fi

  if [[ "${rr:-n}" =~ ^[Yy]$ ]]; then
    for pkg in com.termux com.termux.api com.termux.boot com.gojek.gopaymerchant; do
      su -c "dumpsys deviceidle whitelist +$pkg" >/dev/null 2>&1 || true
      su -c "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" >/dev/null 2>&1 || true
      su -c "cmd appops set $pkg WAKE_LOCK allow" >/dev/null 2>&1 || true
      su -c "cmd appops set $pkg RUN_IN_BACKGROUND allow" >/dev/null 2>&1 || true
      su -c "am set-standby-bucket $pkg active" >/dev/null 2>&1 || true
    done

    su -c "am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 || true
    # ✅ quote component
    su -c "cmd notification allow_listener '$TERMUX_API_NL_COMPONENT'" >/dev/null 2>&1 || true

    rr2="n"
    if [ "$AUTO_YES" != "1" ]; then
      read -rp "Disable DOZE total? (y/n) [disarankan n untuk device harian]: " -n 1 rr2; echo
    fi
    if [[ "${rr2:-n}" =~ ^[Yy]$ ]]; then
      su -c "dumpsys deviceidle disable" >/dev/null 2>&1 || true
      su -c "cmd deviceidle disable" >/dev/null 2>&1 || true
      ok "Doze disabled (best effort)"
    fi

    ok "Root optimization applied (best effort)"
  else
    warn "Skipped root optimization"
  fi
else
  warn "su not found, skip root optimization"
fi

# ============================================================================
# 8) Start services (tmux + watchdog + notif_keeper)
# ============================================================================
info "[8/9] Starting services..."
"$BIN_DIR/forwarderctl.sh" start || true
nohup bash "$BIN_DIR/watchdog.sh" >/dev/null 2>&1 & disown || true
nohup bash "$BIN_DIR/notif_keeper.sh" 60 >/dev/null 2>&1 & disown || true
ok "Started fadzPay + watchdog + notif_keeper"

# ============================================================================
# 9) Done
# ============================================================================
info "[9/9] Done"

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 INSTALL DONE ✅                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}📁 Directory:${NC} $BASE_DIR"
echo -e "${CYAN}⚙️ Config:${NC} $CONFIG_FILE (chmod 600)"
echo
echo -e "${CYAN}🔧 Commands:${NC}"
echo "  Status  : $BIN_DIR/forwarderctl.sh status"
echo "  Attach  : $BIN_DIR/forwarderctl.sh attach"
echo "  Restart : $BIN_DIR/forwarderctl.sh restart"
echo "  Stop    : $BIN_DIR/forwarderctl.sh stop"
echo "  Logs    : tail -f $BASE_DIR/logs/fadzpay-forwarder.log"
echo "  WD Logs : tail -f $BASE_DIR/logs/fadzpay-watchdog.log"
echo "  NK Logs : tail -f $BASE_DIR/logs/fadzpay-notif-keeper.log"
echo "  Queue   : wc -l $BASE_DIR/queue/pending.jsonl"
echo "  Doctor  : $BIN_DIR/doctor.sh"
echo
echo -e "${CYAN}🚀 Auto-start:${NC} $BOOT_FILE"
echo
echo -e "${RED}🔐 SECURITY:${NC} Jangan share SECRET/PIN/TOKEN."
ok "fadzPay ready ✅"
