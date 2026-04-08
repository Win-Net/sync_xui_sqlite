#!/usr/bin/env bash
set -euo pipefail

DB_DEFAULT="/etc/x-ui/x-ui.db"
INTERVAL=30
COOLDOWN=120
SERVICE_NAME="enforce_expiry"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENFORCE_SCRIPT_PATH="/usr/local/bin/enforce_expiry.sh"
BASE_DIR="/opt/xui-enforce-expiry"
STATE_FILE="${BASE_DIR}/state.json"
PY_FILE="${BASE_DIR}/monitor.py"

require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "[ERROR] must be run as root"; exit 1; }
}

detect_python3() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3; return 0
  fi
  for p in /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
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
  for svc in x-ui.service 3x-ui.service; do
    if systemctl cat "$svc" >/dev/null 2>&1; then
      local content direct_db workdir
      content="$(systemctl cat "$svc" 2>/dev/null || true)"
      direct_db="$(printf '%s\n' "$content" | grep -Eo '/[^"[:space:]]+/(x-ui|xui)\.db' | head -n 1 || true)"
      if [[ -n "$direct_db" && -f "$direct_db" ]]; then echo "$direct_db"; return 0; fi
      workdir="$(printf '%s\n' "$content" | sed -n 's/^WorkingDirectory=//p' | head -n 1 || true)"
      if [[ -n "$workdir" ]]; then
        local m
        for m in "$workdir/x-ui.db" "$workdir/xui.db" "$workdir/db/x-ui.db" "$workdir/db/xui.db"; do
          [[ -f "$m" ]] && { echo "$m"; return 0; }
        done
      fi
    fi
  done
  find /etc /usr/local /opt /var/lib /root /home \
    -xdev -type f \( -name 'x-ui.db' -o -name 'xui.db' \) \
    2>/dev/null | head -n 1 || true
}

detect_restart_targets() {
  local targets=()
  systemctl cat xray.service  >/dev/null 2>&1 && targets+=("xray.service")
  systemctl cat x-ui.service  >/dev/null 2>&1 && targets+=("x-ui.service")
  systemctl cat 3x-ui.service >/dev/null 2>&1 && targets+=("3x-ui.service")
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "xray.service x-ui.service 3x-ui.service"
  else
    printf '%s ' "${targets[@]}" | sed 's/[[:space:]]*$//'
  fi
}

write_monitor_py() {
  local py_bin="$1"
  mkdir -p "$BASE_DIR"

  cat > "$PY_FILE" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import json
import logging
import os
import signal
import sqlite3
import subprocess
import sys
import time
from typing import List

running = True

def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db-path",          required=True)
    parser.add_argument("--state-file",        required=True)
    parser.add_argument("--check-interval",    type=int, default=30)
    parser.add_argument("--restart-cooldown",  type=int, default=120)
    parser.add_argument("--sqlite-timeout",    type=int, default=10)
    parser.add_argument("--restart-target",    action="append", dest="restart_targets", default=[])
    return parser.parse_args()

def setup_logger():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )
    return logging.getLogger("enforce_expiry")

def load_state(state_file):
    if not os.path.exists(state_file):
        return {"last_restart_ts": 0, "last_depleted": []}
    try:
        with open(state_file, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"last_restart_ts": 0, "last_depleted": []}

def save_state(state_file, state):
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, state_file)

def get_depleted_users(db_path, sqlite_timeout):
    if not os.path.isfile(db_path):
        raise FileNotFoundError(f"Database not found: {db_path}")
    conn = sqlite3.connect(db_path, timeout=sqlite_timeout)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            SELECT DISTINCT TRIM(email) AS email
            FROM client_traffics
            WHERE total > 0
              AND (up + down) >= total
              AND email IS NOT NULL
              AND TRIM(email) <> ''
            ORDER BY email
            """
        ).fetchall()
        return [row["email"] for row in rows]
    finally:
        conn.close()

def restart_service(restart_targets, logger):
    for unit in restart_targets:
        exists = subprocess.run(
            ["systemctl", "status", unit],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if exists.returncode not in (0, 3, 4):
            continue
        result = subprocess.run(
            ["systemctl", "restart", unit],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode == 0:
            logger.warning("restart executed: %s", unit)
            return unit
    raise RuntimeError("no service could be restarted")

def main():
    args   = parse_args()
    logger = setup_logger()

    logger.info("monitor started | db=%s interval=%ss cooldown=%ss",
                args.db_path, args.check_interval, args.restart_cooldown)

    state           = load_state(args.state_file)
    last_seen_logged = None

    while running:
        try:
            depleted     = get_depleted_users(args.db_path, args.sqlite_timeout)
            now          = int(time.time())
            old          = sorted(state.get("last_depleted", []))
            last_restart = int(state.get("last_restart_ts", 0))

            if depleted != last_seen_logged:
                if depleted:
                    logger.warning("depleted users detected: %s", ", ".join(depleted))
                else:
                    logger.info("no depleted clients")
                last_seen_logged = list(depleted)

            changed     = sorted(depleted) != old
            cooldown_ok = (now - last_restart) >= args.restart_cooldown

            if depleted and changed and cooldown_ok:
                unit = restart_service(args.restart_targets, logger)
                state["last_restart_ts"] = now
                state["last_depleted"]   = sorted(depleted)
                state["last_unit"]       = unit
                save_state(args.state_file, state)
                logger.warning("restart trigger completed")
            elif not depleted and old:
                state["last_depleted"] = []
                save_state(args.state_file, state)

        except Exception as exc:
            logger.exception("loop error: %s", exc)

        for _ in range(args.check_interval):
            if not running:
                break
            time.sleep(1)

    logger.info("monitor stopped")

if __name__ == "__main__":
    main()
PYEOF

  chmod +x "$PY_FILE"
}

cmd_install() {
  require_root
  local db interval cooldown

  db="$(detect_db)"
  [[ -z "$db" ]] && { echo "[ERROR] x-ui database not found"; exit 1; }
  echo "[INFO]  database detected: $db"

  local py_bin
  py_bin="$(detect_python3 || true)"
  [[ -z "$py_bin" ]] && { echo "[ERROR] python3 not found"; exit 1; }
  echo "[INFO]  python3: $py_bin"

  local restart_targets
  restart_targets="$(detect_restart_targets)"
  echo "[INFO]  restart targets: $restart_targets"

  interval="${1:-$INTERVAL}"
  cooldown="${2:-$COOLDOWN}"

  write_monitor_py "$py_bin"

  local exec_start="$py_bin $PY_FILE --db-path $db --state-file $STATE_FILE --check-interval $interval --restart-cooldown $cooldown --sqlite-timeout 10"
  for unit in $restart_targets; do
    exec_start="$exec_start --restart-target $unit"
  done

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XUI Enforce Expiry
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$exec_start
Restart=always
RestartSec=5
WorkingDirectory=$BASE_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable  "${SERVICE_NAME}.service" >/dev/null 2>&1
  systemctl restart "${SERVICE_NAME}.service"
  echo "[INFO]  enforce expiry installed and started"
}

cmd_uninstall() {
  require_root
  systemctl stop    "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
  rm -f "$ENFORCE_SCRIPT_PATH"
  echo "[INFO]  enforce expiry uninstalled"
}

cmd_status() {
  systemctl status "${SERVICE_NAME}.service" --no-pager || true
  echo ""
  journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager || true
}

case "${1:-}" in
  install)   cmd_install "${2:-}" "${3:-}" ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *)
    echo "Usage: $0 {install [interval] [cooldown] | uninstall | status}"
    exit 1
    ;;
esac
