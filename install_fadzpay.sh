#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

# =================================================
# fadzPay (Termux) - GoPay Merchant Notification Forwarder
# - Smart reinstall: detect old install, stop+cleanup, reinstall fresh
# - Safe: if BASE_DIR exists but not created by this installer -> auto backup rename
# - TMUX mode + WATCHDOG auto-restart
# - wake-lock + optional root anti-doze
# - boot via Termux:Boot (tmux + watchdog)
# - QUEUE + RETRY + BACKOFF (anti miss when internet/server down)
# - TTL queue (drop too-old pending items)
# - NET-CHECK (skip flush when network really down)
# - QUEUE DEDUPE (anti duplicate queue when offline)
# - INTERVAL_SEC supports float (e.g. 0.5)
# - DEVICE_ID (manual or auto UUID) -> sent to worker
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║                 fadzPay Installer                    ║"
  echo "║      GoPay Merchant Forwarder (TMUX + Queue)         ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

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

stop_everything_best_effort() {
  info "Stopping existing services (best effort)..."

  if need_cmd tmux; then
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null && tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi

  pkill -f "$BASE_DIR/bin/watchdog.sh" 2>/dev/null || true
  pkill -f "$BASE_DIR/bin/forwarder.sh" 2>/dev/null || true

  rm -f "$STATE_DIR/forwarder.pid" 2>/dev/null || true
  rm -f "$STATE_DIR/watchdog.pid" 2>/dev/null || true

  termux-notification-remove walletfw 2>/dev/null || true
  termux-notification-remove walletwd 2>/dev/null || true
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

# Generate device id (UUID)
gen_device_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid | tr -d '\n'
    return 0
  fi
  local a
  a="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  echo "${a:0:8}-${a:8:4}-${a:12:4}-${a:16:4}-${a:20:12}"
}

# ============================================================================
# 1) Update & Install Dependencies
# ============================================================================
info "[1/8] Updating packages..."
pkg update -y >/dev/null 2>&1 && ok "Package index updated" || true
pkg upgrade -y >/dev/null 2>&1 && ok "Packages upgraded" || true

info "[2/8] Installing dependencies..."
PACKAGES=(curl jq coreutils grep sed openssl-tool gawk procps termux-api tmux)
for p in "${PACKAGES[@]}"; do
  if pkg install -y "$p" >/dev/null 2>&1; then ok "Installed: $p"; else warn "Failed install: $p (maybe already)"; fi
done

if ! need_cmd termux-notification-list; then
  echo
  err "termux-notification-list tidak ditemukan!"
  echo -e "${YELLOW}Wajib:${NC}"
  echo "1) Install Termux:API (F-Droid)"
  echo "2) Buka Termux:API sekali"
  echo "3) Settings → Apps → Special access → Notification access → enable Termux:API"
  echo
  read -rp "Lanjutkan instalasi? (y/n): " -n 1 c; echo
  [[ "${c:-n}" =~ ^[Yy]$ ]] || exit 1
fi

# ============================================================================
# 3) Smart Reinstall Detect
# ============================================================================
info "[3/8] Smart install detector..."
backup_or_remove_old_install

# ============================================================================
# 4) Setup Directories
# ============================================================================
info "[4/8] Setting up directories..."
mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR" "$CONF_DIR" "$QUEUE_DIR"
touch "$MARKER_FILE"
chmod 600 "$MARKER_FILE" 2>/dev/null || true
ok "Prepared: $BASE_DIR"

# ============================================================================
# 5) Configuration Input
# ============================================================================
info "[5/8] Configuration setup..."
echo

normalize_url() {
  local u="$1"
  while [[ "$u" == */ ]]; do u="${u%/}"; done
  echo "$u"
}

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

# ✅ DEVICE_ID prompt (enter = auto UUID)
DEFAULT_DEVICE_ID="$(gen_device_id)"
read -rp "$(echo -e ${CYAN}DEVICE_ID${NC}) (opsional, contoh: S8-WIFI / S8-PLUS-DATA) [enter=auto]: " DEVICE_ID
DEVICE_ID="${DEVICE_ID:-$DEFAULT_DEVICE_ID}"
ok "Device ID: ${DEVICE_ID}"

# ✅ float interval support
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
TMUX_SESSION='${TMUX_SESSION}'

# Queue features
QUEUE_MAX_LINES='${QUEUE_MAX_LINES}'
QUEUE_TTL_HOURS='${QUEUE_TTL_HOURS}'
NETCHECK_ENABLE='${NETCHECK_ENABLE}'
EOF
chmod 600 "$CONFIG_FILE"
ok "Saved config: $CONFIG_FILE (chmod 600)"

# ============================================================================
# 6) Create Scripts
# ============================================================================
info "[6/8] Creating scripts..."

# scan_notifs.sh
cat > "$BIN_DIR/scan_notifs.sh" <<'SCAN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ missing: $1"; exit 1; }; }
need termux-notification-list
need jq

echo "════════════════════════════════════════════════════════════"
echo "  fadzPay Notification Scanner"
echo "════════════════════════════════════════════════════════════"
echo

echo "📱 All Notifications:"
echo "────────────────────────────────────────────────────────────"
termux-notification-list | jq -r '.[] | "\(.packageName)\t│\t\(.title)\t│\t\(.content)"' 2>/dev/null || echo "No notifications"

echo
echo "────────────────────────────────────────────────────────────"
echo "💰 GoPay Merchant Notifications:"
echo "────────────────────────────────────────────────────────────"
termux-notification-list | jq -r '.[] | select(.packageName=="com.gojek.gopaymerchant") | "Title: \(.title)\nContent: \(.content)\nWhen: \(.when)\nKey: \(.key // .id)\n"' 2>/dev/null || echo "No GoPay Merchant notifications"
SCAN_EOF
chmod +x "$BIN_DIR/scan_notifs.sh"
ok "Created: scan_notifs.sh"

# forwarder.sh (queue + retry + ttl + net-check + queue dedupe + device_id)
cat > "$BIN_DIR/forwarder.sh" <<'FORWARDER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="__BASE_DIR__"
CONFIG_FILE="$BASE_DIR/config/config.env"

LOG_FILE="$BASE_DIR/logs/fadzpay-forwarder.log"
STATE_FILE="$BASE_DIR/state/seen_fingerprints.txt"

QUEUE_DIR="$BASE_DIR/queue"
QUEUE_FILE="$QUEUE_DIR/pending.jsonl"
QUEUE_TMP="$QUEUE_DIR/pending.tmp"

STATE_MAX_LINES=7000
MAX_AMOUNT=100000000

PKG_ALLOW="com.gojek.gopaymerchant"
TITLE_REGEX='^Pembayaran diterima$'
CONTENT_REGEX='Pembayaran[[:space:]]+QRIS[[:space:]]+Rp'

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }
need jq; need curl; need openssl; need awk; need grep; need sed; need sha256sum; need wc; need tail; need mv; need mkdir
need termux-notification-list; need termux-notification

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")" "$QUEUE_DIR" "$BASE_DIR/state"
touch "$LOG_FILE" "$STATE_FILE" "$QUEUE_FILE"
chmod 600 "$STATE_FILE" "$QUEUE_FILE" 2>/dev/null || true

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
    cat /proc/sys/kernel/random/uuid | tr -d '\n'
    return 0
  fi
  local a
  a="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
  echo "${a:0:8}-${a:8:4}-${a:12:4}-${a:16:4}-${a:20:12}"
}

DEVICE_ID="${DEVICE_ID:-}"
if [ -z "${DEVICE_ID}" ] && [ -s "$DEVICE_ID_STATE" ]; then
  DEVICE_ID="$(cat "$DEVICE_ID_STATE" 2>/dev/null | head -n1 | tr -d '\r\n' || true)"
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
    -H "Content-Type: application/json" \
    -H "X-Forwarder-Token: ${TOKEN}" \
    -H "X-Forwarder-Pin: ${PIN}" \
    -H "X-Device-Id: ${DEVICE_ID}" \
    -H "X-TS: ${ts}" \
    -H "X-Signature: ${sig}" \
    -X POST "$WEBHOOK_URL" \
    --data-raw "$body" \
    -w " HTTP=%{http_code}" 2>&1 || true)"

  echo "$out"
}

is_http_2xx(){ [[ "$1" =~ HTTP=2[0-9][0-9]$ ]]; }

net_is_up(){
  local code
  code="$(curl -sS -I --max-time 5 --connect-timeout 4 "$API_BASE" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")"
  [ "$code" != "000" ]
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
log "  fadzPay Forwarder (GoPay Merchant) + Queue/TTL/NetCheck"
log "════════════════════════════════════════════════════════════"
log "▶️  Started: $(date '+%Y-%m-%d %H:%M:%S')"
log "🎯 Target : $WEBHOOK_URL"
log "📱 Device : $DEVICE_ID"
log "⏱️  Interval: ${INTERVAL_SEC}s"
log "💰 Min Amount: Rp ${MIN_AMOUNT}"
log "📦 Queue file: $QUEUE_FILE (max_lines=$QUEUE_MAX_LINES, ttl_h=$QUEUE_TTL_HOURS)"
log "🧠 Queue dedupe: enabled"
log "🌐 Net-check: $([ "$NETCHECK_ENABLE" = "1" ] && echo enabled || echo disabled)"
log "════════════════════════════════════════════════════════════"

PROCESSED_COUNT=0
ERROR_COUNT=0
QUEUED_COUNT=0
LAST_STATUS_PUSH=0
STATUS_EVERY_MS=15000

while :; do
  queue_flush || true

  json="$(termux-notification-list 2>/dev/null || echo "[]")"
  if [ -z "$json" ] || [ "$json" = "null" ]; then
    sleep "$INTERVAL_SEC"
    continue
  fi

  while read -r row; do
    pkg="$(jq -r '.packageName // ""' <<<"$row")"
    [ "$pkg" = "$PKG_ALLOW" ] || continue

    title="$(jq -r '.title // ""' <<<"$row")"
    content="$(jq -r '.content // ""' <<<"$row")"

    echo "$title"   | grep -Eq "$TITLE_REGEX"   || continue
    echo "$content" | grep -Eq "$CONTENT_REGEX" || continue

    when="$(jq -r '.when // ""' <<<"$row")"
    key="$(jq -r '.key // (.id|tostring) // ""' <<<"$row")"

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

    if [[ "$resp" =~ HTTP=2[0-9][0-9]$ ]]; then
      SEEN["$fingerprint"]=1
      echo "$fingerprint" >> "$STATE_FILE"
      trim_state
      log "✓ $tslog | Rp ${amt} | ${resp} | ${content:0:70}..."
      PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    else
      queue_push "$fingerprint" "$payload"
      log "✗ $tslog | Rp ${amt} | QUEUED | ${resp:0:120} | ${content:0:70}..."
      ERROR_COUNT=$((ERROR_COUNT + 1))
      QUEUED_COUNT=$((QUEUED_COUNT + 1))
    fi

  done < <(jq -c '.[]' <<<"$json" 2>/dev/null || true)

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

# forwarderctl.sh (tmux)
cat > "$BIN_DIR/forwarderctl.sh" <<'CTL_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

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

# watchdog.sh
cat > "$BIN_DIR/watchdog.sh" <<'WD_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="__BASE_DIR__"
CONF="$BASE_DIR/config/config.env"
CTL="$BASE_DIR/bin/forwarderctl.sh"
WD_LOG="$BASE_DIR/logs/fadzpay-watchdog.log"
PID_FILE="$BASE_DIR/state/watchdog.pid"

INTERVAL="${1:-20}"

mkdir -p "$BASE_DIR/logs" "$BASE_DIR/state"
touch "$WD_LOG"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF" || true
[ -n "${WATCHDOG_INTERVAL:-}" ] && INTERVAL="${WATCHDOG_INTERVAL}"

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

log "WATCHDOG start | interval=${INTERVAL}s"

while :; do
  if "$CTL" status >/dev/null 2>&1; then
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

# Boot script
cat > "$BIN_DIR/start-fadzpay.sh" <<'BOOT_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE_DIR="$HOME/fadzpay"
CTL="$BASE_DIR/bin/forwarderctl.sh"
WD="$BASE_DIR/bin/watchdog.sh"

sleep 8
termux-wake-lock 2>/dev/null || true

"$CTL" start >/dev/null 2>&1 || true
nohup bash "$WD" >/dev/null 2>&1 & disown || true
BOOT_EOF

chmod +x "$BIN_DIR/start-fadzpay.sh"
mkdir -p "$HOME/.termux/boot"
cp -f "$BIN_DIR/start-fadzpay.sh" "$BOOT_FILE"
chmod +x "$BOOT_FILE"
ok "Created boot script: $BOOT_FILE"

# ============================================================================
# 7) Optional: Root anti-doze (for dedicated device)
# ============================================================================
info "[7/8] Optional root optimization (anti-doze)..."
if command -v su >/dev/null 2>&1; then
  rr="n"
  if [ "$AUTO_YES" = "1" ]; then rr="y"; fi

  if [ "$AUTO_YES" != "1" ]; then
    echo -e "${YELLOW}Kamu root. Apply anti-doze biar notif gak ketahan?${NC}"
    echo "Will run (best effort):"
    echo "  dumpsys deviceidle whitelist +com.termux +com.termux.api +com.termux.boot +com.gojek.gopaymerchant"
    echo "  cmd appops set <pkg> RUN_ANY_IN_BACKGROUND allow"
    echo "  cmd appops set <pkg> WAKE_LOCK allow"
    echo "Optional: disable doze total"
    read -rp "Apply sekarang? (y/n): " -n 1 rr; echo
  else
    info "AUTO_YES=1 -> applying root anti-doze automatically"
  fi

  if [[ "${rr:-n}" =~ ^[Yy]$ ]]; then
    for pkg in com.termux com.termux.api com.termux.boot com.gojek.gopaymerchant; do
      su -c "dumpsys deviceidle whitelist +$pkg" >/dev/null 2>&1 || true
      su -c "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" >/dev/null 2>&1 || true
      su -c "cmd appops set $pkg WAKE_LOCK allow" >/dev/null 2>&1 || true
    done

    rr2="n"
    if [ "$AUTO_YES" = "1" ]; then rr2="y"; fi
    if [ "$AUTO_YES" != "1" ]; then
      read -rp "Disable DOZE total? (y/n): " -n 1 rr2; echo
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
# 8) Start services (tmux + watchdog)
# ============================================================================
info "[8/8] Starting services..."
"$BIN_DIR/forwarderctl.sh" start || true
nohup bash "$BIN_DIR/watchdog.sh" >/dev/null 2>&1 & disown || true
ok "Started fadzPay + watchdog"

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 INSTALL DONE ✅                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}📁 Directory:${NC} $BASE_DIR"
echo -e "${CYAN}⚙️ Config:${NC} $CONFIG_FILE (chmod 600)"
echo
echo -e "${CYAN}🔧 Commands:${NC}"
echo "  Status : $BIN_DIR/forwarderctl.sh status"
echo "  Attach : $BIN_DIR/forwarderctl.sh attach"
echo "  Restart: $BIN_DIR/forwarderctl.sh restart"
echo "  Stop   : $BIN_DIR/forwarderctl.sh stop"
echo "  Logs   : tail -f $BASE_DIR/logs/fadzpay-forwarder.log"
echo "  Watchdog: tail -f $BASE_DIR/logs/fadzpay-watchdog.log"
echo "  Queue  : wc -l $BASE_DIR/queue/pending.jsonl"
echo
echo -e "${CYAN}🚀 Auto-start:${NC} $BOOT_FILE"
echo
echo -e "${RED}🔐 SECURITY:${NC} Jangan share SECRET/PIN/TOKEN."
ok "fadzPay ready ✅"
