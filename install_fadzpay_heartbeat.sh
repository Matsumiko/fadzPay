#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }
info(){ echo -e "${BLUE}ℹ${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║           fadzPay Heartbeat Installer (Addon)        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

BASE_DIR="$HOME/fadzpay"
BIN_DIR="$BASE_DIR/bin"
CONF="$BASE_DIR/config/config.env"
BOOT_DIR="$HOME/.termux/boot"
BOOT_FILE="$BOOT_DIR/fadzpay-heartbeat.sh"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

info "[1/4] Install dependencies..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y curl jq openssl-tool coreutils termux-api >/dev/null 2>&1 || true
ok "Deps installed (best effort)"

if [ ! -d "$BASE_DIR" ]; then
  err "Folder fadzPay belum ada: $BASE_DIR"
  err "Install fadzPay dulu, baru run installer heartbeat ini."
  exit 1
fi
if [ ! -f "$CONF" ]; then
  err "Config fadzPay tidak ditemukan: $CONF"
  err "Pastikan fadzPay sudah terpasang & config.env ada."
  exit 1
fi

mkdir -p "$BIN_DIR" "$BOOT_DIR" "$BASE_DIR/logs" "$BASE_DIR/state" "$BASE_DIR/queue"
ok "Dirs ready"

info "[2/4] Writing heartbeat.sh ..."
cat > "$BIN_DIR/heartbeat.sh" <<'HB_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="$HOME/fadzpay"
CONF="$BASE_DIR/config/config.env"
LOG="$BASE_DIR/logs/fadzpay-heartbeat.log"
QUEUE_FILE="$BASE_DIR/queue/pending.jsonl"

mkdir -p "$BASE_DIR/logs" "$BASE_DIR/queue"
touch "$LOG"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
need(){ command -v "$1" >/dev/null 2>&1 || { log "Missing: $1"; exit 1; }; }

need curl
need jq
need openssl
need awk
need sed
need date
need wc
need tr

if [ ! -f "$CONF" ]; then
  log "Config not found: $CONF"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

API_BASE="${API_BASE%/}"

# endpoint heartbeat di server publik
STATUS_URL="${API_BASE}/status/heartbeat?token=${TOKEN}"
STATUS_VIEW="${API_BASE}/status?token=${TOKEN}"

DEVICE_NAME="$(getprop ro.product.model 2>/dev/null || echo "android")"
DEVICE_ID="$(getprop ro.serialno 2>/dev/null || echo "unknown")"

now_ms(){
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  if [ -n "$t" ] && [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"; else echo $(( $(date +%s) * 1000 )); fi
}

hmac_sig_hex(){
  local msg="$1"
  printf '%s' "$msg" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}'
}

http_probe(){
  # returns "CODE LAT_MS"
  local url="$1" out code tt lat
  out="$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 4 --max-time 6 "$url" 2>/dev/null || echo "000 0")"
  code="$(awk '{print $1}' <<<"$out")"
  tt="$(awk '{print $2}' <<<"$out")"
  lat="$(awk -v t="$tt" 'BEGIN{printf("%d", t*1000)}')"
  echo "$code $lat"
}

wifi_info_json(){
  if command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
    termux-wifi-connectioninfo 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}

telephony_info_json(){
  if command -v termux-telephony-deviceinfo >/dev/null 2>&1; then
    termux-telephony-deviceinfo 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}

queue_lines(){
  if [ -f "$QUEUE_FILE" ]; then
    wc -l < "$QUEUE_FILE" | tr -d ' ' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

tmux_running(){
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "${TMUX_SESSION:-fadzpay}" 2>/dev/null; then echo "1"; else echo "0"; fi
  else
    echo "0"
  fi
}

send_once(){
  local ts code lat qlines tmux_ok wifi tel payload sig input resp
  ts="$(now_ms)"
  read -r code lat < <(http_probe "$API_BASE")

  qlines="$(queue_lines)"
  tmux_ok="$(tmux_running)"
  wifi="$(wifi_info_json)"
  tel="$(telephony_info_json)"

  payload="$(jq -nc \
    --arg app "fadzPay" \
    --arg device_name "$DEVICE_NAME" \
    --arg device_id "$DEVICE_ID" \
    --arg api_base "$API_BASE" \
    --arg http_code "$code" \
    --arg latency_ms "$lat" \
    --arg queue_lines "$qlines" \
    --arg tmux_ok "$tmux_ok" \
    --argjson wifi "$wifi" \
    --argjson telephony "$tel" \
    --arg ts "$ts" \
    '{
      app:$app,
      device:{name:$device_name,id:$device_id},
      api_base:$api_base,
      probe:{http_code:($http_code|tonumber), latency_ms:($latency_ms|tonumber)},
      queue:{lines:($queue_lines|tonumber)},
      forwarder:{tmux_running:($tmux_ok|tonumber)},
      wifi:$wifi,
      telephony:$telephony,
      ts_ms:($ts|tonumber)
    }'
  )"

  input="${ts}.${payload}"
  sig="$(hmac_sig_hex "$input")"

  resp="$(curl -sS --max-time 8 --connect-timeout 5 \
    -H "Content-Type: application/json" \
    -H "X-Forwarder-Pin: ${PIN}" \
    -H "X-TS: ${ts}" \
    -H "X-Signature: ${sig}" \
    -X POST "$STATUS_URL" \
    --data-raw "$payload" \
    -w " HTTP=%{http_code}" 2>&1 || true)"

  if [[ "$resp" =~ HTTP=2[0-9][0-9]$ ]]; then
    log "HB OK | code=$code lat=${lat}ms q=$qlines tmux=$tmux_ok | $resp"
  else
    log "HB FAIL | code=$code lat=${lat}ms q=$qlines tmux=$tmux_ok | $resp"
  fi
}

usage(){
  echo "Usage:"
  echo "  $0 once"
  echo "  $0 daemon <interval_sec>"
  echo "  $0 view"
}

case "${1:-}" in
  once)
    send_once
    ;;
  daemon)
    interval="${2:-15}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 5 ]; then interval=15; fi
    log "Heartbeat daemon start interval=${interval}s | view: ${STATUS_VIEW}"
    termux-wake-lock 2>/dev/null || true
    while :; do
      send_once || true
      sleep "$interval"
    done
    ;;
  view)
    echo "$STATUS_VIEW"
    ;;
  *)
    usage
    exit 1
    ;;
esac
HB_EOF

chmod +x "$BIN_DIR/heartbeat.sh"
ok "Installed: $BIN_DIR/heartbeat.sh"

info "[3/4] Writing heartbeatctl.sh ..."
cat > "$BIN_DIR/heartbeatctl.sh" <<'CTL_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="$HOME/fadzpay"
HB="$BASE_DIR/bin/heartbeat.sh"
PID_FILE="$BASE_DIR/state/heartbeat.pid"
LOG="$BASE_DIR/logs/fadzpay-heartbeat.log"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need ps
need kill
need nohup

is_running(){
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$HB"
}

start(){
  interval="${1:-15}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 5 ]; then interval=15; fi

  if [ -f "$PID_FILE" ]; then
    oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_running "$oldpid"; then
      echo "Already running (pid=$oldpid)"
      exit 0
    else
      rm -f "$PID_FILE"
    fi
  fi

  mkdir -p "$BASE_DIR/state" "$BASE_DIR/logs"
  touch "$LOG"

  nohup bash "$HB" daemon "$interval" >>"$LOG" 2>&1 & echo $! > "$PID_FILE"
  sleep 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if is_running "$pid"; then
    echo "Started heartbeat (pid=$pid) interval=${interval}s"
    echo "View: $(bash "$HB" view)"
  else
    echo "Failed to start heartbeat. Check log: $LOG"
    rm -f "$PID_FILE"
    exit 1
  fi
}

stop(){
  if [ ! -f "$PID_FILE" ]; then
    echo "Not running"
    exit 0
  fi
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if is_running "$pid"; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    is_running "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "Stopped"
}

status(){
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_running "$pid"; then
      echo "Running (pid=$pid)"
      exit 0
    fi
  fi
  echo "Not running"
  exit 1
}

case "${1:-}" in
  start) start "${2:-15}" ;;
  stop) stop ;;
  restart) stop || true; start "${2:-15}" ;;
  status) status ;;
  once) bash "$HB" once ;;
  view) bash "$HB" view ;;
  *)
    echo "Usage: $0 start [interval]|stop|restart [interval]|status|once|view"
    exit 1
    ;;
esac
CTL_EOF

chmod +x "$BIN_DIR/heartbeatctl.sh"
ok "Installed: $BIN_DIR/heartbeatctl.sh"

info "[4/4] Creating Termux:Boot script (separate) ..."
cat > "$BOOT_FILE" <<'BOOT_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE_DIR="$HOME/fadzpay"
CTL="$BASE_DIR/bin/heartbeatctl.sh"

sleep 10
termux-wake-lock 2>/dev/null || true

# default interval 15s (edit if you want)
"$CTL" start 15 >/dev/null 2>&1 || true
BOOT_EOF

chmod +x "$BOOT_FILE"
ok "Boot enabled: $BOOT_FILE"

echo
ok "Heartbeat addon installed ✅"
echo "Run:"
echo "  $BIN_DIR/heartbeatctl.sh once"
echo "  $BIN_DIR/heartbeatctl.sh start 15"
echo "Public view url:"
echo "  $($BIN_DIR/heartbeat.sh view)"
