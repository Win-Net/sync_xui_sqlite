#!/usr/bin/env bash
set -uo pipefail

DB_DEFAULT="/etc/x-ui/x-ui.db"
INTERVAL_DEFAULT=30
COOLDOWN_DEFAULT=120
SERVICE_NAME="enforce_expiry"
ENFORCE_SCRIPT_PATH="/usr/local/bin/enforce_expiry.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

now_ms() { date +%s%3N; }
now_s()  { date +%s; }

info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || { error "must be run as root"; exit 1; }
}

# ─── db ─────────────────────────────────────────────────────────────────────

q() { sqlite3 -separator '|' "$DB_PATH" "$1" 2>/dev/null || true; }

get_expired_clients() {
    local now
    now="$(now_ms)"
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
         WHERE inbound_id=${iid} AND email='${email}';" 2>/dev/null || true
}

disable_client_inbound() {
    local iid="$1" email="$2"
    command -v python3 &>/dev/null || return 0
    python3 - "$DB_PATH" "$iid" "$email" <<'PYEOF' || true
import sys, sqlite3, json
db, iid, email = sys.argv[1], int(sys.argv[2]), sys.argv[3]
conn = sqlite3.connect(db, timeout=10)
cur  = conn.cursor()
cur.execute("SELECT id, settings FROM inbounds WHERE id=?", (iid,))
row = cur.fetchone()
if not row:
    conn.close(); sys.exit(0)
rid, raw = row
try:    s = json.loads(raw)
except: conn.close(); sys.exit(0)
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
    if x-ui restart &>/dev/null 2>&1; then
        info "x-ui restart executed"
        return 0
    fi
    if systemctl restart x-ui &>/dev/null 2>&1; then
        info "systemctl restart x-ui executed"
        return 0
    fi
    if systemctl restart 3x-ui &>/dev/null 2>&1; then
        info "systemctl restart 3x-ui executed"
        return 0
    fi
    error "restart failed — no working restart method found"
    return 0
}

# ─── monitor loop ────────────────────────────────────────────────────────────

run_monitor() {
    DB_PATH="${1:-${DB_DEFAULT}}"
    INTERVAL="${2:-${INTERVAL_DEFAULT}}"
    COOLDOWN="${3:-${COOLDOWN_DEFAULT}}"

    [[ -f "$DB_PATH" ]] || { error "DB not found: $DB_PATH"; exit 1; }

    info "monitor started | db=${DB_PATH} interval=${INTERVAL}s cooldown=${COOLDOWN}s"

    local last_restart=0
    local last_disabled=""

    while true; do
        local expired=""
        expired="$(get_expired_clients)" || true

        if [[ -n "$expired" ]]; then
            local now=0 elapsed=0
            now="$(now_s)"
            elapsed=$(( now - last_restart ))

            if [[ "$expired" != "$last_disabled" ]] && (( elapsed >= COOLDOWN )); then
                local iid="" email="" changed=0
                while IFS='|' read -r iid email; do
                    [[ -z "$email" ]] && continue
                    warn "disabling → inbound_id=${iid} email=${email}"
                    disable_client_traffic "$iid" "$email" || true
                    disable_client_inbound "$iid" "$email" || true
                    changed=$(( changed + 1 ))
                done <<< "$expired"

                if (( changed > 0 )); then
                    info "disabled ${changed} client(s) → triggering restart"
                    do_restart || true
                    last_restart="$(now_s)"
                fi

                last_disabled="$expired"

            elif [[ "$expired" == "$last_disabled" ]]; then
                :
            else
                info "cooldown active — $(( COOLDOWN - elapsed ))s remaining"
            fi
        else
            if [[ -n "$last_disabled" ]]; then
                info "all clients within limits"
                last_disabled=""
            fi
        fi

        sleep "$INTERVAL" || true
    done
}

# ─── entrypoint ─────────────────────────────────────────────────────────────

case "${1:-}" in
    monitor)
        run_monitor "${2:-}" "${3:-}" "${4:-}"
        ;;
    *)
        echo "Usage: $0 monitor [db_path] [interval_seconds] [cooldown_seconds]"
        exit 1
        ;;
esac
