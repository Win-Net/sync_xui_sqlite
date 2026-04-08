#!/usr/bin/env bash
set -euo pipefail

DB_DEFAULT="/etc/x-ui/x-ui.db"
INTERVAL=30
COOLDOWN=120
SERVICE_NAME="xui-enforce-expiry"
BASE_DIR="/opt/${SERVICE_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ─── helpers ────────────────────────────────────────────────────────────────

now_ms() { date +%s%3N; }
now_s()  { date +%s; }

info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "[ERROR] must be run as root"; exit 1; }
}

# ─── db detection ───────────────────────────────────────────────────────────

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

  # از systemd بخون
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

  # find به عنوان آخرین راه
  find /etc /usr/local /opt /var/lib -xdev -type f \
    \( -name 'x-ui.db' -o -name 'xui.db' \) 2>/dev/null | head -1
}

# ─── core logic ─────────────────────────────────────────────────────────────

q() { sqlite3 -separator '|' "$DB_PATH" "$1" 2>/dev/null; }

get_expired_clients() {
  local now
  now="$(now_ms)"
  # کاربرایی که enable=1 هستن ولی:
  #   ترافیکشون تموم شده (total>0 و up+down>=total)
  #   یا تاریخشون گذشته (expiry_time>0 و expiry_time<=now_ms)
  q "
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
  "
}

disable_client_traffic() {
  local iid="$1" email="$2"
  sqlite3 "$DB_PATH" \
    "UPDATE client_traffics SET enable=0
     WHERE inbound_id=${iid} AND email='${email}';" 2>/dev/null
}

disable_client_inbound() {
  # enable=false رو داخل JSON جدول inbounds ست می‌کنه
  local iid="$1" email="$2"

  if ! command -v python3 &>/dev/null; then
    return 0
  fi

  python3 - "$DB_PATH" "$iid" "$email" <<'PYEOF'
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
  if x-ui restart &>/dev/null; then
    info "x-ui restart executed"
    return 0
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
  return 1
}

# ─── main loop ──────────────────────────────────────────────────────────────

run_monitor() {
  DB_PATH="${1:-${DB_DEFAULT}}"
  [[ -f "$DB_PATH" ]] || { error "DB not found: $DB_PATH"; exit 1; }

  info "monitor started | db=${DB_PATH} interval=${INTERVAL}s cooldown=${COOLDOWN}s"

  local last_restart=0
  local last_disabled=""

  while true; do
    local expired
    expired="$(get_expired_clients)"

    if [[ -n "$expired" ]]; then
      local now
      now="$(now_s)"
      local elapsed=$(( now - last_restart ))

      if [[ "$expired" != "$last_disabled" ]] && (( elapsed >= COOLDOWN )); then
        info "expired clients detected:"
        local line iid email changed=0
        while IFS='|' read -r iid email; do
          [[ -z "$email" ]] && continue
          warn "  disabling → inbound_id=${iid} email=${email}"
          disable_client_traffic "$iid" "$email" && (( changed++ )) || true
          disable_client_inbound "$iid" "$email" || true
        done <<< "$expired"

        if (( changed > 0 )); then
          info "disabled ${changed} client(s) → triggering restart"
          do_restart && last_restart="$(now_s)" || true
        fi

        last_disabled="$expired"
      elif [[ "$expired" == "$last_disabled" ]]; then
        : # تغییری نبوده
      else
        info "cooldown active — $(( COOLDOWN - elapsed ))s remaining"
      fi
    else
      if [[ -n "$last_disabled" ]]; then
        info "all clients within limits"
        last_disabled=""
      fi
    fi

    sleep "$INTERVAL"
  done
}

# ─── install / uninstall / status ───────────────────────────────────────────

cmd_install() {
  require_root
  command -v sqlite3 &>/dev/null || { error "sqlite3 not found — install it first"; exit 1; }

  local db
  db="$(detect_db)"
  [[ -z "$db" ]] && { error "x-ui database not found"; exit 1; }
  info "database detected: $db"

  mkdir -p "$BASE_DIR"
  cp -f "$0" "${BASE_DIR}/enforce_expiry.sh"
  chmod +x "${BASE_DIR}/enforce_expiry.sh"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XUI Enforce Expiry
After=network.target

[Service]
Type=simple
ExecStart=${BASE_DIR}/enforce_expiry.sh monitor ${db}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service"
  info "installed and started — use: journalctl -u ${SERVICE_NAME} -f"
}

cmd_uninstall() {
  require_root
  systemctl stop    "${SERVICE_NAME}.service" &>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" &>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
  info "uninstalled"
}

cmd_status() {
  systemctl status "${SERVICE_NAME}.service" --no-pager || true
  echo ""
  journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager || true
}

# ─── entrypoint ─────────────────────────────────────────────────────────────

case "${1:-}" in
  install)   cmd_install   ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status    ;;
  monitor)   run_monitor "${2:-}" ;;
  *)
    echo "Usage: $0 {install|uninstall|status|monitor [db_path]}"
    exit 1
    ;;
esac
