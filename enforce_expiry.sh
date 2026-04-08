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
  )
  local p
  for p in "${paths[@]}"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  local svc
  for svc in x-ui 3x-ui; do
    if systemctl cat "${svc}.service" &>/dev/null; then
      local wd
      wd="$(systemctl cat "${svc}.service" 2>/dev/null \
            | sed -n 's/^WorkingDirectory=//p' | head -1)"
      local m
      for m in "$wd/x-ui.db" "$wd/xui.db"; do
        [[ -f "$m" ]] && { echo "$m"; return 0; }
      done
    fi
  done
  find /etc /usr/local /opt /var/lib -xdev -type f \
    \( -name 'x-ui.db' -o -name 'xui.db' \) 2>/dev/null | head -1
}

get_expired_clients() {
  local db="$1"
  local now
  now="$(now_ms)"
  sqlite3 -separator '|' "$db" "
    SELECT inbound_id, email
    FROM client_traffics
    WHERE enable = 1
      AND (
        (total > 0 AND (up + down) >= total)
        OR
        (expiry_time > 0 AND expiry_time <= ${now})
      )
      AND email IS NOT NULL AND TRIM(email) <> ''
    ORDER BY inbound_id, email;
  " 2>/dev/null || true
}

disable_client_traffic() {
  local db="$1" iid="$2" email="$3"
  sqlite3 "$db" \
    "UPDATE client_traffics SET enable=0
     WHERE inbound_id=${iid} AND email='${email}';" 2>/dev/null || true
}

disable_client_inbound() {
  local db="$1" iid="$2" email="$3"
  command -v python3 &>/dev/null || return 0
  python3 - "$db" "$iid" "$email" <<'PYEOF'
import sys, sqlite3, json
db, iid, email = sys.argv[1], int(sys.argv[2]), sys.argv[3]
conn = sqlite3.connect(db, timeout=10)
cur  = conn.cursor()
cur.execute("SELECT id, settings FROM inbounds WHERE id=?", (iid,))
row = cur.fetchone()
if not row:
    conn.close(); sys.exit(0)
rid, raw = row
try:
    s = json.loads(raw)
except Exception:
    conn.close(); sys.exit(0)
changed = False
for c in s.get("clients", []):
    if (c.get("email") or "") == email:
        c["enable"] = False
        changed = True
if changed:
    cur.execute("UPDATE inbounds SET settings=? WHERE id=?",
                (json.dumps(s, ensure_ascii=False, separators=(",",":")), rid))
    conn.commit()
conn.close()
PYEOF
}

do_restart() {
  if command -v x-ui &>/dev/null; then
    x-ui restart &>/dev/null && info "x-ui restart executed" && return 0
  fi
  if systemctl restart x-ui &>/dev/null; then
    info "systemctl restart x-ui executed"
    return 0
  fi
  if systemctl restart 3x-ui &>/dev/null; then
    info "systemctl restart 3x-ui executed"
    return 0
  fi
  error "restart failed"
}

run_monitor() {
  local db="${1:-${DB_DEFAULT}}"
  local interval="${2:-${INTERVAL}}"
  local cooldown="${3:-${COOLDOWN}}"

  [[ -f "$db" ]] || { error "DB not found: $db"; exit 1; }

  info "monitor started | db=${db} interval=${interval}s cooldown=${cooldown}s"

  local last_restart=0
  local last_expired=""

  while true; do
    local expired
    expired="$(get_expired_clients "$db")"

    if [[ -n "$expired" ]]; then
      local now elapsed
      now="$(now_s)"
      elapsed=$(( now - last_restart ))

      if [[ "$expired" != "$last_expired" ]] && (( elapsed >= cooldown )); then
        local changed=0
        local iid email
        while IFS='|' read -r iid email; do
          [[ -z "$email" ]] && continue
          warn "disabling → inbound_id=${iid} email=${email}"
          disable_client_traffic "$db" "$iid" "$email"
          disable_client_inbound "$db" "$iid" "$email"
          changed=$(( changed + 1 ))
        done <<< "$expired"

        if (( changed > 0 )); then
          info "disabled ${changed} client(s) → triggering restart"
          do_restart
          last_restart="$(now_s)"
        fi

        last_expired="$expired"

      elif [[ "$expired" == "$last_expired" ]]; then
        info "no change in expired clients"
      else
        info "cooldown active — $(( cooldown - elapsed ))s remaining"
      fi
    else
      if [[ -n "$last_expired" ]]; then
        info "all clients within limits"
        last_expired=""
      else
        info "checking... no expired clients"
      fi
    fi

    sleep "$interval"
  done
}

cmd_install() {
  require_root
  command -v sqlite3 &>/dev/null || { error "sqlite3 not found"; exit 1; }

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
