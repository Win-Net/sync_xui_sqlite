#!/usr/bin/env bash

DB_DEFAULT="/etc/x-ui/x-ui.db"
INTERVAL=30
COOLDOWN=120
SERVICE_NAME="enforce_expiry"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENFORCE_SCRIPT_PATH="/usr/local/bin/enforce_expiry.sh"

now_ms() { date +%s%3N; }
now_s()  { date +%s; }

info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "[ERROR] must be run as root"; exit 1; }
}

detect_db() {
  local paths=(
    /etc/x-ui/x-ui.db
    /etc/3x-ui/x-ui.db
    /usr/local/x-ui/x-ui.db
    /usr/local/3x-ui/x-ui.db
    /opt/x-ui/x-ui.db
    /opt/3x-ui/x-ui.db
    /var/lib/x-ui/x-ui.db
    /var/lib/3x-ui/x-ui.db
    /etc/x-ui/xui.db
    /etc/3x-ui/xui.db
  )
  local p
  for p in "${paths[@]}"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  local svc
  for svc in x-ui 3x-ui; do
    if systemctl cat "${svc}.service" &>/dev/null; then
      local wd
      wd="$(systemctl cat "${svc}.service" 2>/dev/null | sed -n 's/^WorkingDirectory=//p' | head -1)"
      local m
      for m in "$wd/x-ui.db" "$wd/xui.db"; do
        [[ -f "$m" ]] && { echo "$m"; return 0; }
      done
    fi
  done
  find /etc /usr/local /opt /var/lib -xdev -type f \
    \( -name 'x-ui.db' -o -name 'xui.db' \) 2>/dev/null | head -1
}

# دقیقاً همون منطق اسکریپت اصلی:
# فقط چک میکنه ترافیک تموم شده یا نه - کاری به enable نداره
get_depleted_clients() {
  local db="$1"
  local now
  now="$(now_ms)"
  sqlite3 -separator '|' "$db" "
    SELECT DISTINCT TRIM(email) AS email
    FROM client_traffics
    WHERE total > 0
      AND (up + down) >= total
      AND email IS NOT NULL
      AND TRIM(email) <> ''
    ORDER BY email;
  " 2>/dev/null || true
}

get_expired_by_date_clients() {
  local db="$1"
  local now
  now="$(now_ms)"
  sqlite3 -separator '|' "$db" "
    SELECT DISTINCT TRIM(email) AS email
    FROM client_traffics
    WHERE expiry_time > 0
      AND expiry_time <= ${now}
      AND email IS NOT NULL
      AND TRIM(email) <> ''
    ORDER BY email;
  " 2>/dev/null || true
}

do_restart() {
  if command -v x-ui &>/dev/null; then
    if x-ui restart &>/dev/null; then
      info "x-ui restart executed"
      return 0
    fi
  fi
  if systemctl restart x-ui &>/dev/null; then
    info "systemctl restart x-ui executed"
    return 0
  fi
  if systemctl restart 3x-ui &>/dev/null; then
    info "systemctl restart 3x-ui executed"
    return 0
  fi
  error "restart failed — no working restart method found"
}

run_monitor() {
  local db="${1:-${DB_DEFAULT}}"
  local interval="${2:-${INTERVAL}}"
  local cooldown="${3:-${COOLDOWN}}"

  [[ -f "$db" ]] || { error "DB not found: $db"; exit 1; }

  info "monitor started | db=${db} interval=${interval}s cooldown=${cooldown}s"

  local last_restart=0
  local last_depleted=""

  while true; do
    local depleted_traffic depleted_date all_depleted
    depleted_traffic="$(get_depleted_clients "$db")"
    depleted_date="$(get_expired_by_date_clients "$db")"

    # ترکیب هر دو و حذف تکراری
    all_depleted="$(printf '%s\n%s\n' "$depleted_traffic" "$depleted_date" \
      | grep -v '^[[:space:]]*$' | sort -u)"

    if [[ -n "$all_depleted" ]]; then
      local now elapsed
      now="$(now_s)"
      elapsed=$(( now - last_restart ))

      if [[ "$all_depleted" != "$last_depleted" ]] && (( elapsed >= cooldown )); then
        warn "depleted clients detected:"
        while IFS= read -r email; do
          [[ -z "$email" ]] && continue
          warn "  → email=${email}"
        done <<< "$all_depleted"

        local count
        count="$(echo "$all_depleted" | grep -c '[^[:space:]]')"
        info "triggering restart for ${count} depleted client(s)"
        do_restart
        last_restart="$(now_s)"
        last_depleted="$all_depleted"

      elif [[ "$all_depleted" == "$last_depleted" ]]; then
        info "no change in depleted clients"
      else
        info "cooldown active — $(( cooldown - elapsed ))s remaining"
      fi
    else
      if [[ -n "$last_depleted" ]]; then
        info "no depleted clients"
        last_depleted=""
      else
        info "checking... no depleted clients"
      fi
    fi

    sleep "$interval"
  done
}

cmd_install() {
  require_root
  command -v sqlite3 &>/dev/null || { error "sqlite3 not found — apt install sqlite3"; exit 1; }

  local db
  db="$(detect_db)"
  [[ -z "$db" ]] && { error "x-ui database not found"; exit 1; }
  info "database detected: $db"

  cp -f "$0" "${ENFORCE_SCRIPT_PATH}"
  chmod +x "${ENFORCE_SCRIPT_PATH}"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XUI Enforce Expiry
After=network.target

[Service]
Type=simple
ExecStart=${ENFORCE_SCRIPT_PATH} monitor ${db} ${INTERVAL} ${COOLDOWN}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service"
  info "installed and started"
}

cmd_uninstall() {
  require_root
  systemctl stop    "${SERVICE_NAME}.service" &>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" &>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -f "${ENFORCE_SCRIPT_PATH}"
  info "uninstalled"
}

cmd_status() {
  systemctl status "${SERVICE_NAME}.service" --no-pager || true
  echo ""
  journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager || true
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  monitor)   run_monitor "${2:-}" "${3:-}" "${4:-}" ;;
  *)
    echo "Usage: $0 {install|uninstall|status|monitor [db] [interval] [cooldown]}"
    exit 1
    ;;
esac
