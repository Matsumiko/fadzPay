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
echo "║   fadzPay Heartbeat Installer (SAFE REINSTALL)       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

BASE_DIR="$HOME/fadzpay"
BIN_DIR="$BASE_DIR/bin"
CONF_DIR="$BASE_DIR/config"
FADZPAY_CONF="$CONF_DIR/config.env"

HB_CONF="$CONF_DIR/heartbeat.env"
BOOT_DIR="$HOME/.termux/boot"
BOOT_FILE="$BOOT_DIR/fadzpay-heartbeat.sh"

HB_SH="$BIN_DIR/heartbeat.sh"
HB_CTL="$BIN_DIR/heartbeatctl.sh"

STATE_DIR="$BASE_DIR/state"
PID_FILE="$STATE_DIR/heartbeat.pid"
UID_FILE="$STATE_DIR/device_uid"
LOG_FILE="$BASE_DIR/logs/fadzpay-heartbeat.log"

ts_now(){ date '+%Y%m%d-%H%M%S'; }

safe_backup(){
  # backup only heartbeat-related files if exists
  local stamp="$1"
  local bdir="$STATE_DIR/heartbeat-backup-$stamp"
  mkdir -p "$bdir"

  local any=0
  for f in "$HB_CONF" "$HB_SH" "$HB_CTL" "$BOOT_FILE" "$PID_FILE" "$UID_FILE" "$LOG_FILE"; do
    if [ -f "$f" ]; then
      any=1
      cp -f "$f" "$bdir/" 2>/dev/null || true
    fi
  done

  if [ "$any" -eq 1 ]; then
    ok "Backup heartbeat lama: $bdir"
  else
    info "Tidak ada file heartbeat lama untuk dibackup."
    rmdir "$bdir" 2>/dev/null || true
  fi
}

stop_old_heartbeat(){
  # best-effort stop heartbeat daemon if running; only touches heartbeat pid / ctl
  if [ -x "$HB_CTL" ]; then
    "$HB_CTL" stop >/dev/null 2>&1 || true
  fi

  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
  fi
}

detect_existing(){
  if [ -f "$HB_CONF" ] || [ -f "$HB_SH" ] || [ -f "$HB_CTL" ] || [ -f "$BOOT_FILE" ] || [ -f "$PID_FILE" ]; then
    return 0
  fi
  return 1
}

remove_old_files_safe(){
  # remove only heartbeat-related files; keep device_uid by default (optional)
  rm -f "$HB_CONF" "$HB_SH" "$HB_CTL" "$BOOT_FILE" "$PID_FILE" 2>/dev/null || true
}

reset_uid_prompt(){
  # ask user whether to reset device_uid (optional)
  if [ -f "$UID_FILE" ]; then
    echo
    warn "Ditemukan UID lama: $UID_FILE (ini bikin device_id stabil)."
    read -rp "$(echo -e ${CYAN}Reset device UID?${NC}) (y/N): " ans
    ans="${ans:-N}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      rm -f "$UID_FILE" 2>/dev/null || true
      ok "device_uid direset (akan generate UID baru)."
    else
      ok "device_uid dipertahankan (recommended)."
    fi
  fi
}

info "[1/5] Install dependencies..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y curl jq openssl-tool coreutils termux-api procps >/dev/null 2>&1 || true
ok "Deps installed (best effort)"

if [ ! -d "$BASE_DIR" ]; then
  err "Folder fadzPay belum ada: $BASE_DIR"
  err "Install fadzPay dulu, baru run installer heartbeat ini."
  exit 1
fi

mkdir -p "$BIN_DIR" "$BOOT_DIR" "$BASE_DIR/logs" "$STATE_DIR"
ok "Dirs ready"

# -------------------------------------------------------------------
# SAFE REINSTALL: stop + backup + remove old heartbeat files only
# -------------------------------------------------------------------
if detect_existing; then
  echo
  warn "Heartbeat lama terdeteksi. Akan dilakukan SAFE REINSTALL (stop + backup + replace)."
  stamp="$(ts_now)"
  stop_old_heartbeat
  safe_backup "$stamp"
  reset_uid_prompt
  remove_old_files_safe
  ok "Heartbeat lama dibersihkan (hanya file heartbeat)."
else
  info "Tidak ada heartbeat lama, lanjut install fresh."
fi

# -------------------------------------------------------------------
# INPUT CONFIG HEARTBEAT
# -------------------------------------------------------------------
info "[2/5] Setup Heartbeat config..."
echo

# STATUS_BASE_URL
while true; do
  read -rp "$(echo -e ${CYAN}STATUS_BASE_URL${NC}) (contoh: https://status.domainkamu.id): " STATUS_BASE_URL
  STATUS_BASE_URL="${STATUS_BASE_URL:-}"
  if [ -z "$STATUS_BASE_URL" ]; then
    err "STATUS_BASE_URL wajib diisi!"
  elif [[ ! "$STATUS_BASE_URL" =~ ^https?:// ]]; then
    err "Harus diawali http:// atau https://"
  else
    STATUS_BASE_URL="${STATUS_BASE_URL%/}"
    ok "STATUS_BASE_URL set: $STATUS_BASE_URL"
    break
  fi
done

# DEVICE_NAME
read -rp "$(echo -e ${CYAN}DEVICE_NAME${NC}) (wajib unik per device, contoh: dev-1 / backup-2) [default: android]: " DEVICE_NAME
DEVICE_NAME="${DEVICE_NAME:-android}"
ok "DEVICE_NAME set: $DEVICE_NAME"

# PIN
while true; do
  read -rsp "$(echo -e ${CYAN}STATUS_PIN${NC}) (harus sama dengan env.STATUS_PIN di Worker): " STATUS_PIN
  echo
  if [ -z "${STATUS_PIN:-}" ]; then
    err "STATUS_PIN wajib diisi!"
  else
    ok "PIN configured"
    break
  fi
done

# SECRET (wajib sama dengan Worker)
while true; do
  echo -e "${YELLOW}NOTE:${NC} STATUS_SECRET ini HARUS sama persis dengan env.STATUS_SECRET di Worker (copy-paste)."
  read -rsp "$(echo -e ${CYAN}STATUS_SECRET${NC}) (wajib sama dengan Worker): " STATUS_SECRET
  echo
  if [ -z "${STATUS_SECRET:-}" ]; then
    err "STATUS_SECRET wajib diisi (jangan kosong)!"
  else
    ok "Secret configured (${#STATUS_SECRET} chars)"
    break
  fi
done

# INTERVAL
read -rp "$(echo -e ${CYAN}HEARTBEAT_INTERVAL${NC}) detik [default: 15]: " HEARTBEAT_INTERVAL
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-15}"
if ! [[ "$HEARTBEAT_INTERVAL" =~ ^[0-9]+$ ]] || [ "$HEARTBEAT_INTERVAL" -lt 5 ]; then
  warn "HEARTBEAT_INTERVAL invalid, set to 15"
  HEARTBEAT_INTERVAL=15
fi
ok "Interval: ${HEARTBEAT_INTERVAL}s"

# Optional: tmux session name (ambil dari fadzPay config kalau ada)
TMUX_SESSION="fadzpay"
if [ -f "$FADZPAY_CONF" ]; then
  # shellcheck disable=SC1090
  source "$FADZPAY_CONF" || true
  TMUX_SESSION="${TMUX_SESSION:-fadzpay}"
fi

# Save heartbeat config
cat > "$HB_CONF" <<EOF
# fadzPay Heartbeat Config (auto-generated)
STATUS_BASE_URL='${STATUS_BASE_URL}'
DEVICE_NAME='${DEVICE_NAME}'
STATUS_PIN='${STATUS_PIN}'
STATUS_SECRET='${STATUS_SECRET}'
HEARTBEAT_INTERVAL='${HEARTBEAT_INTERVAL}'
TMUX_SESSION='${TMUX_SESSION}'
EOF
chmod 600 "$HB_CONF"
ok "Saved heartbeat config: $HB_CONF (chmod 600)"

# -------------------------------------------------------------------
# WRITE heartbeat.sh
# -------------------------------------------------------------------
info "[3/5] Writing heartbeat.sh (FIXED DEVICE_ID) ..."
cat > "$HB_SH" <<'HB_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="$HOME/fadzpay"
CONF="$BASE_DIR/config/heartbeat.env"
LOG="$BASE_DIR/logs/fadzpay-heartbeat.log"
STATE_DIR="$BASE_DIR/state"
UID_FILE="$STATE_DIR/device_uid"   # persist unique uid per device

mkdir -p "$BASE_DIR/logs" "$STATE_DIR"
touch "$LOG"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
need(){ command -v "$1" >/dev/null 2>&1 || { log "Missing: $1"; exit 1; }; }

need curl; need jq; need openssl; need awk; need sed; need date; need wc; need tr; need sha256sum

if [ ! -f "$CONF" ]; then
  log "Heartbeat config not found: $CONF"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

STATUS_BASE_URL="${STATUS_BASE_URL%/}"
STATUS_URL="${STATUS_BASE_URL}/status/heartbeat"
STATUS_VIEW="${STATUS_BASE_URL}/"
PROBE_URL="${STATUS_BASE_URL}/health"

DEVICE_MODEL="$(getprop ro.product.model 2>/dev/null || echo "android")"
ANDROID_VER="$(getprop ro.build.version.release 2>/dev/null || echo "-")"
DEVICE_NAME="${DEVICE_NAME:-android}"

# stable per-device UID (avoid collision even if serial unknown)
if [ -f "$UID_FILE" ]; then
  DEVICE_UID="$(cat "$UID_FILE" 2>/dev/null | tr -d '\r\n' || true)"
fi

if [ -z "${DEVICE_UID:-}" ]; then
  DEVICE_UID="$(openssl rand -hex 8 2>/dev/null || date +%s%N | sha256sum | awk '{print $1}' | cut -c1-16)"
  printf '%s\n' "$DEVICE_UID" > "$UID_FILE"
  chmod 600 "$UID_FILE" || true
fi

DEVICE_ID="$(printf '%s' "${DEVICE_NAME}|${DEVICE_UID}" | sha256sum | awk '{print $1}' | cut -c1-12)"

now_ms(){
  local t
  t="$(date +%s%3N 2>/dev/null || true)"
  if [ -n "$t" ] && [[ "$t" =~ ^[0-9]+$ ]]; then
    echo "$t"
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

hmac_sig_hex(){
  local msg="$1"
  printf '%s' "$msg" | openssl dgst -sha256 -hmac "$STATUS_SECRET" | awk '{print $2}'
}

http_probe(){
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

tmux_running(){
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "${TMUX_SESSION:-fadzpay}" 2>/dev/null; then echo "1"; else echo "0"; fi
  else
    echo "0"
  fi
}

forwarder_running(){
  if [ -x "$BASE_DIR/bin/forwarderctl.sh" ]; then
    "$BASE_DIR/bin/forwarderctl.sh" status >/dev/null 2>&1 && echo "1" || echo "0"
  else
    pgrep -f "$BASE_DIR/bin/forwarder.sh" >/dev/null 2>&1 && echo "1" || echo "0"
  fi
}

send_once(){
  local ts code lat tmux_ok fw_ok wifi tel payload sig input resp
  ts="$(now_ms)"

  read -r code lat < <(http_probe "$PROBE_URL")

  tmux_ok="$(tmux_running)"
  fw_ok="$(forwarder_running)"
  wifi="$(wifi_info_json)"
  tel="$(telephony_info_json)"

  payload="$(jq -nc \
    --arg app "fadzPay" \
    --arg model "$DEVICE_MODEL" \
    --arg android "$ANDROID_VER" \
    --arg device_id "$DEVICE_ID" \
    --arg device_name "$DEVICE_NAME" \
    --arg device_uid "$DEVICE_UID" \
    --arg base "$STATUS_BASE_URL" \
    --arg http_code "$code" \
    --arg latency_ms "$lat" \
    --arg tmux_ok "$tmux_ok" \
    --arg fw_ok "$fw_ok" \
    --argjson wifi "$wifi" \
    --argjson telephony "$tel" \
    --arg ts "$ts" \
    '{
      app:$app,
      device:{model:$model, android:$android, id:$device_id, name:$device_name, uid:$device_uid},
      status_base:$base,
      probe:{http_code:($http_code|tonumber), latency_ms:($latency_ms|tonumber)},
      forwarder:{tmux_running:($tmux_ok|tonumber), running:($fw_ok|tonumber)},
      wifi:$wifi,
      telephony:$telephony,
      ts_ms:($ts|tonumber)
    }'
  )"

  input="${ts}.${payload}"
  sig="$(hmac_sig_hex "$input")"

  resp="$(curl -sS --max-time 8 --connect-timeout 5 \
    -H "Content-Type: application/json" \
    -H "X-Forwarder-Pin: ${STATUS_PIN}" \
    -H "X-TS: ${ts}" \
    -H "X-Signature: ${sig}" \
    -X POST "$STATUS_URL" \
    --data-raw "$payload" \
    -w " HTTP=%{http_code}" 2>&1 || true)"

  if [[ "$resp" =~ HTTP=2[0-9][0-9]$ ]]; then
    log "HB OK | name=$DEVICE_NAME id=$DEVICE_ID uid=$DEVICE_UID | probe=$code lat=${lat}ms tmux=$tmux_ok fw=$fw_ok | $resp"
  else
    log "HB FAIL | name=$DEVICE_NAME id=$DEVICE_ID uid=$DEVICE_UID | probe=$code lat=${lat}ms tmux=$tmux_ok fw=$fw_ok | $resp"
  fi
}

usage(){
  echo "Usage:"
  echo "  $0 once"
  echo "  $0 daemon [interval_sec]"
  echo "  $0 view"
}

case "${1:-}" in
  once) send_once ;;
  daemon)
    interval="${2:-${HEARTBEAT_INTERVAL:-15}}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 5 ]; then interval=15; fi
    log "Heartbeat daemon start interval=${interval}s | view: ${STATUS_VIEW}"
    termux-wake-lock 2>/dev/null || true
    while :; do
      send_once || true
      sleep "$interval"
    done
    ;;
  view) echo "$STATUS_VIEW" ;;
  *) usage; exit 1 ;;
esac
HB_EOF

chmod +x "$HB_SH"
ok "Installed: $HB_SH"

# -------------------------------------------------------------------
# WRITE heartbeatctl.sh (unchanged)
# -------------------------------------------------------------------
info "[4/5] Writing heartbeatctl.sh ..."
cat > "$HB_CTL" <<'CTL_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077

BASE_DIR="$HOME/fadzpay"
HB="$BASE_DIR/bin/heartbeat.sh"
CONF="$BASE_DIR/config/heartbeat.env"
PID_FILE="$BASE_DIR/state/heartbeat.pid"
LOG="$BASE_DIR/logs/fadzpay-heartbeat.log"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need ps; need kill; need nohup; need grep

interval_default(){
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    source "$CONF" || true
    echo "${HEARTBEAT_INTERVAL:-15}"
  else
    echo "15"
  fi
}

is_running(){
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$HB"
}

start(){
  interval="${1:-$(interval_default)}"
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
  start) start "${2:-}" ;;
  stop) stop ;;
  restart) stop || true; start "${2:-}" ;;
  status) status ;;
  once) bash "$HB" once ;;
  view) bash "$HB" view ;;
  *)
    echo "Usage: $0 start [interval]|stop|restart [interval]|status|once|view"
    exit 1
    ;;
esac
CTL_EOF

chmod +x "$HB_CTL"
ok "Installed: $HB_CTL"

# -------------------------------------------------------------------
# BOOT SCRIPT
# -------------------------------------------------------------------
info "[5/5] Creating Termux:Boot script (separate) ..."
cat > "$BOOT_FILE" <<'BOOT_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BASE_DIR="$HOME/fadzpay"
CTL="$BASE_DIR/bin/heartbeatctl.sh"

sleep 10
termux-wake-lock 2>/dev/null || true
"$CTL" start >/dev/null 2>&1 || true
BOOT_EOF

chmod +x "$BOOT_FILE"
ok "Boot enabled: $BOOT_FILE"

echo
ok "Heartbeat addon installed ✅"
echo "Run:"
echo "  $BIN_DIR/heartbeatctl.sh once"
echo "  $BIN_DIR/heartbeatctl.sh start"
echo "Public view url:"
echo "  $($BIN_DIR/heartbeat.sh view)"
