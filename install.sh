#!/bin/bash

# ============================================
#  WinNet XUI Sync - Installer & Manager
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

GITHUB_RAW="https://raw.githubusercontent.com/Win-Net/sync_xui_sqlite/main"

# Client Sync
SCRIPT_PATH="/usr/local/bin/sync_xui_sqlite.py"
SERVICE_PATH="/etc/systemd/system/sync_xui.service"

# Tunnel Sync
TUNNEL_SCRIPT_PATH="/usr/local/bin/sync_inbound_tunnel.py"
TUNNEL_SERVICE_PATH="/etc/systemd/system/sync_inbound_tunnel.service"

# Enforce Expiry
ENFORCE_APP="winnet-enforce-expiry"
ENFORCE_BASE_DIR="/opt/${ENFORCE_APP}"
ENFORCE_PY_FILE="${ENFORCE_BASE_DIR}/winnet-monitoring.py"
ENFORCE_STATE_FILE="${ENFORCE_BASE_DIR}/state.json"
ENFORCE_SERVICE_FILE="/etc/systemd/system/${ENFORCE_APP}.service"
ENFORCE_LOG_FILE="/var/log/${ENFORCE_APP}.log"

VENV_PATH="/opt/xui_sync_env"
DB_PATH="/etc/x-ui/x-ui.db"
CLI_CMD="/usr/local/bin/winnet-xui"

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "========================================"
    echo "    WinNet XUI Sync Manager"
    echo "    Subscription Sync Tool"
    echo "https://github.com/Win-Net/sync_xui_sqlite"
    echo "========================================"
    echo -e "${NC}"
}

print_status() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()  { echo -e "${RED}[ERROR]${NC} $1"; }
print_info()   { echo -e "${BLUE}[i]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Please run as root: sudo bash install.sh"
        exit 1
    fi
}

get_service_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo -e "${YELLOW}Inactive (Enabled)${NC}"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        echo -e "${RED}Stopped${NC}"
    else
        echo -e "${RED}Not Installed${NC}"
    fi
}

is_installed() {
    [ -f "$SCRIPT_PATH" ] && [ -f "$SERVICE_PATH" ]
}

# ─── Enforce Expiry helpers ──────────────────────────────────────────────────

enforce_detect_python3() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    for p in /usr/bin/python3 /usr/local/bin/python3; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

enforce_detect_db() {
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
        if [[ -f "$p" ]]; then echo "$p"; return 0; fi
    done

    local services=(x-ui.service 3x-ui.service x-ui 3x-ui)
    local svc
    for svc in "${services[@]}"; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            local content
            content="$(systemctl cat "$svc" 2>/dev/null || true)"
            local direct_db
            direct_db="$(printf '%s\n' "$content" | grep -Eo '/[^"[:space:]]+/(x-ui|xui)\.db' | head -n 1 || true)"
            if [[ -n "$direct_db" && -f "$direct_db" ]]; then
                echo "$direct_db"; return 0
            fi
            local workdir
            workdir="$(printf '%s\n' "$content" | sed -n 's/^WorkingDirectory=//p' | head -n 1 || true)"
            if [[ -n "$workdir" ]]; then
                local maybe
                for maybe in "$workdir/x-ui.db" "$workdir/xui.db" "$workdir/db/x-ui.db" "$workdir/db/xui.db"; do
                    if [[ -f "$maybe" ]]; then echo "$maybe"; return 0; fi
                done
            fi
        fi
    done

    local found
    found="$(find /etc /usr/local /opt /var/lib /root /home \
        -xdev -type f \( -name 'x-ui.db' -o -name 'xui.db' \) \
        2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" && -f "$found" ]]; then
        echo "$found"; return 0
    fi
    return 1
}

enforce_detect_restart_targets() {
    local targets=()
    if systemctl cat xray.service >/dev/null 2>&1; then targets+=("xray.service"); fi
    if systemctl cat x-ui.service >/dev/null 2>&1; then targets+=("x-ui.service"); fi
    if systemctl cat 3x-ui.service >/dev/null 2>&1; then targets+=("3x-ui.service"); fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "xray.service x-ui.service 3x-ui.service"
    else
        printf '%s ' "${targets[@]}" | sed 's/[[:space:]]*$//'
    fi
}

enforce_write_py() {
    cat > "$ENFORCE_PY_FILE" <<'PYEOF'
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
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--check-interval", type=int, default=10)
    parser.add_argument("--restart-cooldown", type=int, default=120)
    parser.add_argument("--sqlite-timeout", type=int, default=10)
    parser.add_argument("--restart-target", action="append", dest="restart_targets", default=[])
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()

def setup_logger():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )
    return logging.getLogger("winnet_enforce_expiry")

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
    db_uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(db_uri, uri=True, timeout=sqlite_timeout)
    conn.row_factory = sqlite3.Row
    try:
        cols = {row["name"] for row in conn.execute("PRAGMA table_info(client_traffics)").fetchall()}
        required = {"email", "up", "down", "total"}
        missing = required - cols
        if missing:
            raise RuntimeError(f"Missing required columns in client_traffics: {sorted(missing)}")
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

def restart_service(restart_targets, dry_run, logger):
    if dry_run:
        logger.warning("DRY_RUN enabled, restart skipped")
        return "dry-run"
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
            logger.warning("Restart executed: %s", unit)
            return unit
    raise RuntimeError("No service could be restarted")

def main():
    args = parse_args()
    logger = setup_logger()

    logger.info("Service started")
    logger.info("Database path: %s", args.db_path)
    logger.info("Restart targets: %s", " ".join(args.restart_targets))
    logger.info("Check interval: %s seconds", args.check_interval)
    logger.info("Restart cooldown: %s seconds", args.restart_cooldown)

    state = load_state(args.state_file)
    last_seen_logged = None

    while running:
        try:
            depleted = get_depleted_users(args.db_path, args.sqlite_timeout)
            now = int(time.time())
            old = sorted(state.get("last_depleted", []))
            last_restart = int(state.get("last_restart_ts", 0))

            if depleted != last_seen_logged:
                if depleted:
                    logger.warning("Depleted users changed: %s", ", ".join(depleted))
                else:
                    logger.info("No depleted users detected")
                last_seen_logged = list(depleted)

            changed = depleted != old
            cooldown_ok = (now - last_restart) >= args.restart_cooldown

            if depleted and changed and cooldown_ok:
                unit = restart_service(args.restart_targets, args.dry_run, logger)
                state["last_restart_ts"] = now
                state["last_depleted"] = depleted
                state["last_unit"] = unit
                save_state(args.state_file, state)
                logger.warning("Restart trigger completed")
            elif not depleted and old:
                state["last_depleted"] = []
                save_state(args.state_file, state)

        except Exception as exc:
            logger.exception("Loop error: %s", exc)

        for _ in range(args.check_interval):
            if not running:
                break
            time.sleep(1)

    logger.info("Service stopped")

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$ENFORCE_PY_FILE"
}

install_enforce_expiry() {
    local interval="$1"
    local cooldown="$2"

    local PYTHON3_BIN
    PYTHON3_BIN="$(enforce_detect_python3 || true)"
    if [[ -z "$PYTHON3_BIN" ]]; then
        print_error "python3 not found"
        return 1
    fi
    print_info "python3: $PYTHON3_BIN"

    local DETECTED_DB
    DETECTED_DB="$(enforce_detect_db || true)"
    if [[ -z "$DETECTED_DB" ]]; then
        print_error "x-ui database not found"
        return 1
    fi
    print_info "database: $DETECTED_DB"

    local RESTART_TARGETS
    RESTART_TARGETS="$(enforce_detect_restart_targets)"
    print_info "restart targets: $RESTART_TARGETS"

    mkdir -p "$ENFORCE_BASE_DIR"
    touch "$ENFORCE_LOG_FILE"
    chmod 600 "$ENFORCE_LOG_FILE"

    enforce_write_py
    print_status "winnet-monitoring.py created: $ENFORCE_PY_FILE"

    local EXEC_START="$PYTHON3_BIN $ENFORCE_PY_FILE --db-path $DETECTED_DB --state-file $ENFORCE_STATE_FILE --check-interval $interval --restart-cooldown $cooldown --sqlite-timeout 10"
    for unit in $RESTART_TARGETS; do
        EXEC_START="$EXEC_START --restart-target $unit"
    done

    cat > "$ENFORCE_SERVICE_FILE" <<EOF
[Unit]
Description=WinNet Enforce Expiry
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$EXEC_START
Restart=always
RestartSec=5
WorkingDirectory=$ENFORCE_BASE_DIR
StandardOutput=append:$ENFORCE_LOG_FILE
StandardError=append:$ENFORCE_LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    print_status "service file created: $ENFORCE_SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "${ENFORCE_APP}.service" > /dev/null 2>&1
    systemctl restart "${ENFORCE_APP}.service"

    if systemctl is-active --quiet "${ENFORCE_APP}.service"; then
        print_status "Enforce expiry service started."
        print_info "Logs: tail -f $ENFORCE_LOG_FILE"
    else
        print_error "Failed to start enforce expiry service."
        print_warn "Check logs: tail -f $ENFORCE_LOG_FILE"
    fi
}

uninstall_enforce_expiry() {
    systemctl stop    "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    systemctl disable "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    rm -f "$ENFORCE_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$ENFORCE_BASE_DIR"
    rm -f "$ENFORCE_LOG_FILE"
    print_status "Enforce expiry removed."
}

# ─── CLI ─────────────────────────────────────────────────────────────────────

install_cli() {
    cat > "$CLI_CMD" << 'EOFCLI'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_PATH="/usr/local/bin/sync_xui_sqlite.py"
SERVICE_PATH="/etc/systemd/system/sync_xui.service"
TUNNEL_SCRIPT_PATH="/usr/local/bin/sync_inbound_tunnel.py"
TUNNEL_SERVICE_PATH="/etc/systemd/system/sync_inbound_tunnel.service"
ENFORCE_APP="winnet-enforce-expiry"
ENFORCE_BASE_DIR="/opt/${ENFORCE_APP}"
ENFORCE_PY_FILE="${ENFORCE_BASE_DIR}/winnet-monitoring.py"
ENFORCE_STATE_FILE="${ENFORCE_BASE_DIR}/state.json"
ENFORCE_SERVICE_FILE="/etc/systemd/system/${ENFORCE_APP}.service"
ENFORCE_LOG_FILE="/var/log/${ENFORCE_APP}.log"
VENV_PATH="/opt/xui_sync_env"
DB_PATH="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/Win-Net/sync_xui_sqlite/main"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Please run as root: sudo winnet-xui"
        exit 1
    fi
}

get_service_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo -e "${YELLOW}Inactive (Enabled)${NC}"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        echo -e "${RED}Stopped${NC}"
    else
        echo -e "${RED}Not Installed${NC}"
    fi
}

enforce_detect_python3() {
    if command -v python3 >/dev/null 2>&1; then command -v python3; return 0; fi
    for p in /usr/bin/python3 /usr/local/bin/python3; do
        if [[ -x "$p" ]]; then echo "$p"; return 0; fi
    done
    return 1
}

enforce_detect_db() {
    local paths=(
        /etc/x-ui/x-ui.db /etc/3x-ui/x-ui.db
        /usr/local/x-ui/x-ui.db /usr/local/3x-ui/x-ui.db
        /opt/x-ui/x-ui.db /opt/3x-ui/x-ui.db
        /var/lib/x-ui/x-ui.db /var/lib/3x-ui/x-ui.db
        /etc/x-ui/xui.db /etc/3x-ui/xui.db
    )
    local p
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then echo "$p"; return 0; fi
    done
    local services=(x-ui.service 3x-ui.service x-ui 3x-ui)
    local svc
    for svc in "${services[@]}"; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            local content direct_db workdir maybe
            content="$(systemctl cat "$svc" 2>/dev/null || true)"
            direct_db="$(printf '%s\n' "$content" | grep -Eo '/[^"[:space:]]+/(x-ui|xui)\.db' | head -n 1 || true)"
            if [[ -n "$direct_db" && -f "$direct_db" ]]; then echo "$direct_db"; return 0; fi
            workdir="$(printf '%s\n' "$content" | sed -n 's/^WorkingDirectory=//p' | head -n 1 || true)"
            if [[ -n "$workdir" ]]; then
                for maybe in "$workdir/x-ui.db" "$workdir/xui.db" "$workdir/db/x-ui.db" "$workdir/db/xui.db"; do
                    if [[ -f "$maybe" ]]; then echo "$maybe"; return 0; fi
                done
            fi
        fi
    done
    local found
    found="$(find /etc /usr/local /opt /var/lib /root /home -xdev -type f \
        \( -name 'x-ui.db' -o -name 'xui.db' \) 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" && -f "$found" ]]; then echo "$found"; return 0; fi
    return 1
}

enforce_detect_restart_targets() {
    local targets=()
    if systemctl cat xray.service >/dev/null 2>&1; then targets+=("xray.service"); fi
    if systemctl cat x-ui.service >/dev/null 2>&1; then targets+=("x-ui.service"); fi
    if systemctl cat 3x-ui.service >/dev/null 2>&1; then targets+=("3x-ui.service"); fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "xray.service x-ui.service 3x-ui.service"
    else
        printf '%s ' "${targets[@]}" | sed 's/[[:space:]]*$//'
    fi
}

enforce_write_py() {
    cat > "$ENFORCE_PY_FILE" <<'PYEOF'
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
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--check-interval", type=int, default=10)
    parser.add_argument("--restart-cooldown", type=int, default=120)
    parser.add_argument("--sqlite-timeout", type=int, default=10)
    parser.add_argument("--restart-target", action="append", dest="restart_targets", default=[])
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()

def setup_logger():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )
    return logging.getLogger("winnet_enforce_expiry")

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
    db_uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(db_uri, uri=True, timeout=sqlite_timeout)
    conn.row_factory = sqlite3.Row
    try:
        cols = {row["name"] for row in conn.execute("PRAGMA table_info(client_traffics)").fetchall()}
        required = {"email", "up", "down", "total"}
        missing = required - cols
        if missing:
            raise RuntimeError(f"Missing required columns in client_traffics: {sorted(missing)}")
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

def restart_service(restart_targets, dry_run, logger):
    if dry_run:
        logger.warning("DRY_RUN enabled, restart skipped")
        return "dry-run"
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
            logger.warning("Restart executed: %s", unit)
            return unit
    raise RuntimeError("No service could be restarted")

def main():
    args = parse_args()
    logger = setup_logger()

    logger.info("Service started")
    logger.info("Database path: %s", args.db_path)
    logger.info("Restart targets: %s", " ".join(args.restart_targets))
    logger.info("Check interval: %s seconds", args.check_interval)
    logger.info("Restart cooldown: %s seconds", args.restart_cooldown)

    state = load_state(args.state_file)
    last_seen_logged = None

    while running:
        try:
            depleted = get_depleted_users(args.db_path, args.sqlite_timeout)
            now = int(time.time())
            old = sorted(state.get("last_depleted", []))
            last_restart = int(state.get("last_restart_ts", 0))

            if depleted != last_seen_logged:
                if depleted:
                    logger.warning("Depleted users changed: %s", ", ".join(depleted))
                else:
                    logger.info("No depleted users detected")
                last_seen_logged = list(depleted)

            changed = depleted != old
            cooldown_ok = (now - last_restart) >= args.restart_cooldown

            if depleted and changed and cooldown_ok:
                unit = restart_service(args.restart_targets, args.dry_run, logger)
                state["last_restart_ts"] = now
                state["last_depleted"] = depleted
                state["last_unit"] = unit
                save_state(args.state_file, state)
                logger.warning("Restart trigger completed")
            elif not depleted and old:
                state["last_depleted"] = []
                save_state(args.state_file, state)

        except Exception as exc:
            logger.exception("Loop error: %s", exc)

        for _ in range(args.check_interval):
            if not running:
                break
            time.sleep(1)

    logger.info("Service stopped")

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$ENFORCE_PY_FILE"
}

show_menu() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "========================================"
    echo "    WinNet XUI Sync Manager"
    echo "    Subscription Sync Tool"
    echo "https://github.com/Win-Net/sync_xui_sqlite"
    echo "========================================"
    echo -e "${NC}"
    echo -e "  Client Sync:     $(get_service_status sync_xui.service)"
    echo -e "  Tunnel Sync:     $(get_service_status sync_inbound_tunnel.service)"
    echo -e "  Enforce Expiry:  $(get_service_status ${ENFORCE_APP}.service)"
    echo ""
    echo "  ----- Client Subscription Sync -----"
    echo ""
    echo -e "  ${GREEN}1)${NC} Enable Client Sync"
    echo -e "  ${RED}2)${NC} Disable Client Sync"
    echo -e "  ${BLUE}3)${NC} Update Client Sync Script"
    echo ""
    echo "  ----- Tunnel Inbound Sync ----------"
    echo ""
    echo -e "  ${GREEN}4)${NC} Enable Tunnel Sync"
    echo -e "  ${RED}5)${NC} Disable Tunnel Sync"
    echo -e "  ${BLUE}6)${NC} Update Tunnel Sync Script"
    echo ""
    echo "  ----- Enforce Expiry ---------------"
    echo ""
    echo -e "  ${GREEN}7)${NC} Enable Enforce Expiry"
    echo -e "  ${RED}8)${NC} Disable Enforce Expiry"
    echo ""
    echo "  ------------------------------------"
    echo ""
    echo -e "  ${BLUE}9)${NC} Update All"
    echo -e "  ${YELLOW}10)${NC} Uninstall Everything"
    echo -e "  ${CYAN}0)${NC} Exit"
    echo ""
    echo "  ------------------------------------"
    echo ""
}

enable_client_sync() {
    echo ""
    echo -e "${BLUE}[i]${NC} Enabling client sync service..."
    systemctl daemon-reload
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1
    if systemctl is-active --quiet sync_xui.service; then
        echo -e "${GREEN}[OK]${NC} Client sync service enabled and started."
    else
        echo -e "${RED}[ERROR]${NC} Failed to start client sync service."
        echo -e "${YELLOW}[!]${NC} Check logs: sudo journalctl -u sync_xui.service -f"
    fi
    echo ""
    read -p "Press Enter to continue..." _
}

disable_client_sync() {
    echo ""
    echo -e "${BLUE}[i]${NC} Disabling client sync service..."
    systemctl disable --now sync_xui.service > /dev/null 2>&1
    systemctl stop sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Client sync service disabled."
    echo ""
    read -p "Press Enter to continue..." _
}

update_client_sync() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating client sync from GitHub..."
    systemctl stop sync_xui.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Client sync script updated."
    else
        echo -e "${RED}[ERROR]${NC} Failed to download client sync script."
        read -p "Press Enter to continue..." _
        return
    fi
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Client sync service file updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download client sync service file."
    fi
    "$VENV_PATH/bin/pip" install --upgrade requests > /dev/null 2>&1
    systemctl daemon-reload
    systemctl start sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Client sync service restarted."
    echo ""
    echo -e "${GREEN}${BOLD}Client sync update completed!${NC}"
    echo ""
    read -p "Press Enter to continue..." _
}

enable_tunnel_sync() {
    echo ""
    if [ ! -f "$TUNNEL_SCRIPT_PATH" ]; then
        echo -e "${BLUE}[i]${NC} Tunnel sync not installed. Downloading..."
        if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
            chmod 755 "$TUNNEL_SCRIPT_PATH"
            echo -e "${GREEN}[OK]${NC} Tunnel sync script downloaded."
        else
            echo -e "${RED}[ERROR]${NC} Failed to download tunnel sync script."
            read -p "Press Enter to continue..." _
            return
        fi
    fi
    if [ ! -f "$TUNNEL_SERVICE_PATH" ]; then
        if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.service" -o "$TUNNEL_SERVICE_PATH"; then
            echo -e "${GREEN}[OK]${NC} Tunnel sync service file downloaded."
        else
            echo -e "${RED}[ERROR]${NC} Failed to download tunnel sync service file."
            read -p "Press Enter to continue..." _
            return
        fi
    fi
    if [ -f "$DB_PATH" ]; then
        echo -e "${BLUE}[i]${NC} Initializing tunnel sync..."
        /usr/bin/env python3 "$TUNNEL_SCRIPT_PATH" --db "$DB_PATH" --init --debug
        echo -e "${GREEN}[OK]${NC} Tunnel sync initialized."
    fi
    systemctl daemon-reload
    systemctl enable --now sync_inbound_tunnel.service > /dev/null 2>&1
    systemctl start sync_inbound_tunnel.service > /dev/null 2>&1
    if systemctl is-active --quiet sync_inbound_tunnel.service; then
        echo -e "${GREEN}[OK]${NC} Tunnel sync service enabled and started."
    else
        echo -e "${RED}[ERROR]${NC} Failed to start tunnel sync service."
        echo -e "${YELLOW}[!]${NC} Check logs: sudo journalctl -u sync_inbound_tunnel.service -f"
    fi
    echo ""
    read -p "Press Enter to continue..." _
}

disable_tunnel_sync() {
    echo ""
    echo -e "${BLUE}[i]${NC} Disabling tunnel sync service..."
    systemctl disable --now sync_inbound_tunnel.service > /dev/null 2>&1
    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Tunnel sync service disabled."
    echo ""
    read -p "Press Enter to continue..." _
}

update_tunnel_sync() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating tunnel sync from GitHub..."
    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
        chmod 755 "$TUNNEL_SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Tunnel sync script updated."
    else
        echo -e "${RED}[ERROR]${NC} Failed to download tunnel sync script."
        read -p "Press Enter to continue..." _
        return
    fi
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.service" -o "$TUNNEL_SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Tunnel sync service file updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download tunnel sync service file."
    fi
    systemctl daemon-reload
    systemctl start sync_inbound_tunnel.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Tunnel sync service restarted."
    echo ""
    echo -e "${GREEN}${BOLD}Tunnel sync update completed!${NC}"
    echo ""
    read -p "Press Enter to continue..." _
}

enable_enforce_expiry() {
    echo ""
    echo -e "${CYAN}  Check interval (how often to check for expired users):${NC}"
    echo -e "  ${GREEN}1)${NC} Every 10 seconds  (recommended)"
    echo -e "  ${GREEN}2)${NC} Every 30 seconds"
    echo -e "  ${GREEN}3)${NC} Every 60 seconds"
    echo ""
    read -p "  Select [1]: " ichoice
    case "${ichoice:-1}" in
        2) interval=30 ;;
        3) interval=60 ;;
        *) interval=10 ;;
    esac

    echo ""
    echo -e "${CYAN}  Cooldown between restarts:${NC}"
    echo -e "  ${GREEN}1)${NC} 60 seconds"
    echo -e "  ${GREEN}2)${NC} 120 seconds  (recommended)"
    echo -e "  ${GREEN}3)${NC} 300 seconds"
    echo ""
    read -p "  Select [2]: " cchoice
    case "${cchoice:-2}" in
        1) cooldown=60  ;;
        3) cooldown=300 ;;
        *) cooldown=120 ;;
    esac

    echo ""
    install_enforce_expiry "$interval" "$cooldown"
    echo ""
    read -p "Press Enter to continue..." _
}

disable_enforce_expiry() {
    echo ""
    echo -e "${BLUE}[i]${NC} Disabling enforce expiry service..."
    systemctl disable --now "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    systemctl stop "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    echo -e "${GREEN}[OK]${NC} Enforce expiry service disabled."
    echo ""
    read -p "Press Enter to continue..." _
}

update_all() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating all scripts from GitHub..."
    echo ""

    systemctl stop sync_xui.service > /dev/null 2>&1 || true
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Client sync script updated."
    else
        echo -e "${RED}[ERROR]${NC} Failed to download client sync script."
    fi
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Client sync service file updated."
    fi

    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1 || true
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
        chmod 755 "$TUNNEL_SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Tunnel sync script updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download tunnel sync script."
    fi
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.service" -o "$TUNNEL_SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Tunnel sync service file updated."
    fi

    if systemctl is-enabled --quiet "${ENFORCE_APP}.service" 2>/dev/null; then
        echo -e "${BLUE}[i]${NC} Updating enforce expiry monitor..."
        systemctl stop "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
        enforce_write_py
        echo -e "${GREEN}[OK]${NC} Enforce expiry monitor updated."
    fi

    "$VENV_PATH/bin/pip" install --upgrade requests > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Dependencies updated."

    if curl -fsSL "$GITHUB_RAW/install.sh" -o /tmp/winnet_install_tmp.sh; then
        bash /tmp/winnet_install_tmp.sh install-cli-only
        rm -f /tmp/winnet_install_tmp.sh
        echo -e "${GREEN}[OK]${NC} CLI command updated."
    fi

    systemctl daemon-reload

    if systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        systemctl start sync_xui.service > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Client sync service restarted."
    fi
    if systemctl is-enabled --quiet sync_inbound_tunnel.service 2>/dev/null; then
        systemctl start sync_inbound_tunnel.service > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Tunnel sync service restarted."
    fi
    if systemctl is-enabled --quiet "${ENFORCE_APP}.service" 2>/dev/null; then
        systemctl start "${ENFORCE_APP}.service" > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Enforce expiry service restarted."
    fi

    echo ""
    echo -e "${GREEN}${BOLD}All updates completed!${NC}"
    echo ""
    read -p "Press Enter to continue..." _
}

uninstall() {
    echo ""
    echo -e "${RED}${BOLD}WARNING: All WinNet XUI Sync files will be removed!${NC}"
    echo ""
    read -p "Are you sure? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${BLUE}[i]${NC} Cancelled."
        read -p "Press Enter to continue..." _
        return
    fi
    echo ""
    echo -e "${BLUE}[i]${NC} Removing..."

    systemctl stop sync_xui.service > /dev/null 2>&1 || true
    systemctl disable sync_xui.service > /dev/null 2>&1 || true
    rm -f "$SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Client sync service removed."

    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1 || true
    systemctl disable sync_inbound_tunnel.service > /dev/null 2>&1 || true
    rm -f "$TUNNEL_SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Tunnel sync service removed."

    systemctl stop "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    systemctl disable "${ENFORCE_APP}.service" > /dev/null 2>&1 || true
    rm -f "$ENFORCE_SERVICE_FILE"
    rm -rf "$ENFORCE_BASE_DIR"
    rm -f "$ENFORCE_LOG_FILE"
    echo -e "${GREEN}[OK]${NC} Enforce expiry removed."

    systemctl daemon-reload

    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Client sync script removed."

    rm -f "$TUNNEL_SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Tunnel sync script removed."

    rm -rf "$VENV_PATH"
    echo -e "${GREEN}[OK]${NC} Python venv removed."

    rm -f /usr/local/bin/winnet-xui
    echo -e "${GREEN}[OK]${NC} CLI command removed."

    echo ""
    echo -e "${GREEN}${BOLD}Uninstall completed.${NC}"
    echo ""
    exit 0
}

check_root

while true; do
    show_menu
    read -p "  Select: " choice
    case $choice in
        1) enable_client_sync ;;
        2) disable_client_sync ;;
        3) update_client_sync ;;
        4) enable_tunnel_sync ;;
        5) disable_tunnel_sync ;;
        6) update_tunnel_sync ;;
        7) enable_enforce_expiry ;;
        8) disable_enforce_expiry ;;
        9) update_all ;;
        10) uninstall ;;
        0) echo ""; echo -e "${CYAN}Bye!${NC}"; echo ""; exit 0 ;;
        *) echo -e "${RED}[ERROR]${NC} Invalid option!"; sleep 1 ;;
    esac
done
EOFCLI
    chmod +x "$CLI_CMD"
}

# ─── Main Install ─────────────────────────────────────────────────────────────

install() {
    print_banner
    echo -e "${MAGENTA}${BOLD}  Installing WinNet XUI Sync${NC}"
    echo ""

    if is_installed; then
        print_warn "Already installed. Reinstall?"
        read -p "Continue? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            return
        fi
    fi

    print_info "Step 1/7: Updating package list..."
    apt update -qq > /dev/null 2>&1
    print_status "Package list updated."

    print_info "Step 2/7: Installing python3-venv..."
    apt install -y python3-venv > /dev/null 2>&1
    print_status "python3-venv installed."

    print_info "Step 3/7: Creating Python virtual environment..."
    python3 -m venv "$VENV_PATH"
    print_status "Venv created at $VENV_PATH"

    print_info "Step 4/7: Installing requests library..."
    "$VENV_PATH/bin/pip" install requests > /dev/null 2>&1
    print_status "requests installed."

    print_info "Step 5/7: Downloading client sync script..."
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        print_status "Client sync script saved to $SCRIPT_PATH"
    else
        print_error "Failed to download client sync script!"
        exit 1
    fi

    print_info "Step 6/7: Downloading tunnel sync script..."
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
        chmod 755 "$TUNNEL_SCRIPT_PATH"
        print_status "Tunnel sync script saved to $TUNNEL_SCRIPT_PATH"
    else
        print_warn "Failed to download tunnel sync script (optional)."
    fi

    print_info "Step 7/7: Downloading systemd services..."
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        print_status "Client sync service file installed."
    else
        print_error "Failed to download client sync service file!"
        exit 1
    fi
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.service" -o "$TUNNEL_SERVICE_PATH"; then
        print_status "Tunnel sync service file installed."
    else
        print_warn "Failed to download tunnel sync service file (optional)."
    fi

    print_info "Running init..."
    if [ -f "$DB_PATH" ]; then
        /usr/bin/env python3 "$SCRIPT_PATH" --db "$DB_PATH" --init --debug
        print_status "Client sync init completed."
        if [ -f "$TUNNEL_SCRIPT_PATH" ]; then
            /usr/bin/env python3 "$TUNNEL_SCRIPT_PATH" --db "$DB_PATH" --init --debug
            print_status "Tunnel sync init completed."
        fi
    else
        print_warn "Database $DB_PATH not found!"
        print_warn "Make sure 3X-UI is installed, then run init manually."
    fi

    systemctl daemon-reload
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1

    install_cli

    echo ""
    echo -e "${GREEN}${BOLD}========================================"
    echo "  Installation completed successfully!"
    echo "========================================${NC}"
    echo ""
    print_info "Client sync:     $(get_service_status sync_xui.service)"
    print_info "Tunnel sync:     ${YELLOW}Disabled${NC} (enable via menu option 4)"
    print_info "Enforce Expiry:  ${YELLOW}Disabled${NC} (enable via menu option 7)"
    print_info "To manage, run: ${CYAN}${BOLD}sudo winnet-xui${NC}"
    echo ""
}

check_root

if [ "$1" = "install-cli-only" ]; then
    install_cli
    exit 0
fi

install
