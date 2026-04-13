#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WinNet - Inbound Tunnel Sync
Syncs traffic (up/down/total) and expiry_time across inbounds
that share the same remark and have protocol 'tunnel' or 'tun'.
"""
from __future__ import annotations
import sqlite3, json, argparse, os, time, shutil, subprocess, threading
from datetime import datetime

DB_DEFAULT = "/etc/x-ui/x-ui.db"
TUNNEL_PROTOCOLS = ("tunnel", "tun")

def jload(s):
    if isinstance(s, dict): return s
    try: return json.loads(s)
    except: return {}

def jdump(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))

def ensure_meta(conn):
    c = conn.cursor()
    c.execute("""
    CREATE TABLE IF NOT EXISTS sync_meta_inbound_tunnel(
      key TEXT PRIMARY KEY,
      remark TEXT,
      protocol TEXT,
      inbound_id INTEGER,
      up INTEGER DEFAULT 0,
      down INTEGER DEFAULT 0,
      total INTEGER DEFAULT 0,
      expiry_time INTEGER DEFAULT 0,
      last_change INTEGER DEFAULT 0
    )""")
    conn.commit()

def meta_key(remark, protocol, iid):
    return f"{remark}|{protocol}|{iid}"

def load_tunnel_inbounds(conn):
    """Load all inbounds with tunnel/tun protocol"""
    cur = conn.cursor()
    placeholders = ",".join("?" for _ in TUNNEL_PROTOCOLS)
    cur.execute(f"""
        SELECT id, remark, protocol, up, down, total, expiry_time
        FROM inbounds
        WHERE LOWER(protocol) IN ({placeholders})
    """, [p.lower() for p in TUNNEL_PROTOCOLS])
    rows = cur.fetchall()
    out = []
    for iid, remark, protocol, up, down, total, expiry_time in rows:
        out.append({
            "id": int(iid),
            "remark": (remark or "").strip(),
            "protocol": (protocol or "").strip().lower(),
            "up": int(up or 0),
            "down": int(down or 0),
            "total": int(total or 0),
            "expiry_time": int(expiry_time or 0),
        })
    return out

def load_meta_map(conn):
    """Load existing meta data"""
    cur = conn.cursor()
    cur.execute("SELECT key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change FROM sync_meta_inbound_tunnel")
    m = {}
    for key, remark, protocol, iid, up, down, total, expiry_time, lc in cur.fetchall():
        m[key] = {
            "remark": remark,
            "protocol": protocol,
            "inbound_id": int(iid),
            "up": int(up or 0),
            "down": int(down or 0),
            "total": int(total or 0),
            "expiry_time": int(expiry_time or 0),
            "last_change": int(lc or 0),
        }
    return m

def ensure_seed(conn, debug=False):
    """Initialize meta table with current inbound data"""
    ensure_meta(conn)
    now = int(time.time())
    inbounds = load_tunnel_inbounds(conn)
    cur = conn.cursor()
    n = 0
    for inb in inbounds:
        key = meta_key(inb["remark"], inb["protocol"], inb["id"])
        cur.execute("""
            INSERT OR REPLACE INTO sync_meta_inbound_tunnel
            (key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (key, inb["remark"], inb["protocol"], inb["id"],
              inb["up"], inb["down"], inb["total"], inb["expiry_time"], now))
        n += 1
        if debug:
            print(f"[SEED] id={inb['id']} remark={inb['remark']} proto={inb['protocol']} "
                  f"up={inb['up']} down={inb['down']} total={inb['total']} expiry={inb['expiry_time']}")
    conn.commit()
    if debug:
        print(f"[INFO] Seeded {n} tunnel inbound entries")

def sync_once(conn, apply=False, debug=False):
    """Run one sync cycle"""
    ensure_meta(conn)
    cur = conn.cursor()
    now = int(time.time())

    inbounds = load_tunnel_inbounds(conn)
    meta_map = load_meta_map(conn)

    if not inbounds:
        if debug:
            print("[INFO] No tunnel/tun inbounds found")
        return 0

    # Update meta for any changes detected
    meta_updates = []
    for inb in inbounds:
        key = meta_key(inb["remark"], inb["protocol"], inb["id"])
        old = meta_map.get(key)
        if old is None or (old["up"] != inb["up"] or old["down"] != inb["down"]
                           or old["total"] != inb["total"] or old["expiry_time"] != inb["expiry_time"]):
            meta_updates.append((key, inb["remark"], inb["protocol"], inb["id"],
                                 inb["up"], inb["down"], inb["total"], inb["expiry_time"], now))
            meta_map[key] = {
                "remark": inb["remark"],
                "protocol": inb["protocol"],
                "inbound_id": inb["id"],
                "up": inb["up"],
                "down": inb["down"],
                "total": inb["total"],
                "expiry_time": inb["expiry_time"],
                "last_change": now,
            }
            if debug:
                print(f"[META] change id={inb['id']} remark={inb['remark']} "
                      f"up={inb['up']} down={inb['down']} total={inb['total']} expiry={inb['expiry_time']}")

    if meta_updates:
        for row in meta_updates:
            cur.execute("""
                INSERT OR REPLACE INTO sync_meta_inbound_tunnel
                (key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row)
        conn.commit()
        if debug:
            print(f"[INFO] Meta updated: {len(meta_updates)} entries")

    # Group by (remark, protocol) - only groups with 2+ inbounds need sync
    groups = {}
    for inb in inbounds:
        gkey = (inb["remark"], inb["protocol"])
        groups.setdefault(gkey, []).append(inb)

    plans = []
    for (remark, protocol), items in groups.items():
        if len(items) < 2:
            continue  # no sync needed for single inbound

        # Find max up, down across group
        max_up = max(i["up"] for i in items)
        max_down = max(i["down"] for i in items)

        # Find the most recently changed inbound for total and expiry_time
        items_with_lc = []
        for inb in items:
            key = meta_key(inb["remark"], inb["protocol"], inb["id"])
            lc = meta_map.get(key, {}).get("last_change", 0)
            items_with_lc.append((lc, inb))
        items_with_lc.sort(key=lambda t: t[0], reverse=True)
        ref = items_with_lc[0][1]

        ref_total = ref["total"]
        ref_expiry = ref["expiry_time"]

        # Detect reset: if reference has lower traffic than max, it was reset
        ref_used = ref["up"] + ref["down"]
        max_used = max_up + max_down
        is_reset = ref_used < max_used

        if is_reset:
            # Reset scenario: use reference values for up/down
            target_up = ref["up"]
            target_down = ref["down"]
            if debug:
                print(f"[RESET] remark={remark} proto={protocol} "
                      f"ref_id={ref['id']} ref_up={target_up} ref_down={target_down}")
        else:
            # Normal: use max values
            target_up = max_up
            target_down = max_down

        for inb in items:
            changes = {}

            if inb["up"] != target_up:
                changes["up"] = (inb["up"], target_up)
            if inb["down"] != target_down:
                changes["down"] = (inb["down"], target_down)
            if inb["total"] != ref_total:
                changes["total"] = (inb["total"], ref_total)
            if inb["expiry_time"] != ref_expiry:
                changes["expiry_time"] = (inb["expiry_time"], ref_expiry)

            if changes:
                plans.append({
                    "id": inb["id"],
                    "remark": remark,
                    "protocol": protocol,
                    "changes": changes,
                    "target_up": target_up,
                    "target_down": target_down,
                    "target_total": ref_total,
                    "target_expiry": ref_expiry,
                })

    if not plans:
        print("[INFO] No changes required (all tunnel inbounds already in sync)")
        return 0

    if debug:
        for p in plans:
            print(f"[PLAN] id={p['id']} remark={p['remark']} changes={p['changes']}")

    if not apply:
        print(f"[DRY-RUN] {len(plans)} changes planned (use --apply to execute)")
        return len(plans)

    # Apply changes
    conn.execute("BEGIN")
    writes = 0
    for p in plans:
        cur.execute("""
            UPDATE inbounds
            SET up = ?, down = ?, total = ?, expiry_time = ?
            WHERE id = ?
        """, (p["target_up"], p["target_down"], p["target_total"], p["target_expiry"], p["id"]))
        writes += 1

        if debug:
            print(f"[APPLY] id={p['id']} remark={p['remark']} "
                  f"up={p['target_up']} down={p['target_down']} "
                  f"total={p['target_total']} expiry={p['target_expiry']}")

    # Update meta after apply
    for p in plans:
        key = meta_key(p["remark"], p["protocol"], p["id"])
        cur.execute("""
            INSERT OR REPLACE INTO sync_meta_inbound_tunnel
            (key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (key, p["remark"], p["protocol"], p["id"],
              p["target_up"], p["target_down"], p["target_total"], p["target_expiry"], now))

    conn.commit()
    print(f"[APPLIED] {writes} inbound(s) updated")
    return len(plans)


# ---------------------------------------------------------------------------
# قابلیت جدید: بررسی مستقل منقضی‌شدن tunnel inboundها هر 10 ثانیه
# ---------------------------------------------------------------------------

def restart_xui_core():
    """ریستارت هسته x-ui"""
    try:
        subprocess.run(["x-ui", "restart"], capture_output=True, timeout=30)
        print(f"[EXPIRE-WATCHER] Core restarted via 'x-ui restart'")
    except Exception:
        try:
            subprocess.run(["systemctl", "restart", "x-ui"], capture_output=True, timeout=30)
            print(f"[EXPIRE-WATCHER] Core restarted via 'systemctl restart x-ui'")
        except Exception as e:
            print(f"[EXPIRE-WATCHER] Failed to restart core: {e}")

def expire_watcher_loop(db_path, check_interval=10):
    """
    هر 10 ثانیه مستقل از لوپ اصلی چک می‌کنه:
    - tunnel inboundهایی که تاریخشان تموم شده یا ترافیکشان تموم شده
    - اگه هنوز enable=1 باشن، غیرفعالشون می‌کنه
    - بعد هسته رو ریستارت می‌کنه
    inboundهایی که تنها یک عدد هم هستند (بدون گروه) هم بررسی می‌شوند
    """
    print(f"[EXPIRE-WATCHER] Started (interval={check_interval}s)")
    while True:
        time.sleep(check_interval)
        try:
            conn = sqlite3.connect(db_path, timeout=30, check_same_thread=False)
            conn.execute("PRAGMA busy_timeout = 3000")
            try:
                _expire_watcher_tick(conn)
            finally:
                conn.close()
        except Exception as e:
            print(f"[EXPIRE-WATCHER] Error: {e}")

def _expire_watcher_tick(conn):
    """یک دور بررسی و غیرفعال‌کردن tunnel inboundهای منقضی‌شده"""
    now_ms = int(time.time() * 1000)
    now_s  = int(time.time())
    cur = conn.cursor()

    # لود همه tunnel inboundهایی که هنوز enable هستند - بدون هیچ محدودیت گروه‌بندی
    placeholders = ",".join("?" for _ in TUNNEL_PROTOCOLS)
    cur.execute(f"""
        SELECT id, remark, protocol, up, down, total, expiry_time, enable
        FROM inbounds
        WHERE LOWER(protocol) IN ({placeholders})
        AND enable = 1
    """, [p.lower() for p in TUNNEL_PROTOCOLS])
    rows = cur.fetchall()

    disabled_ids = []

    for iid, remark, protocol, up, down, total, expiry_time, enable in rows:
        up          = int(up or 0)
        down        = int(down or 0)
        total       = int(total or 0)
        expiry_time = int(expiry_time or 0)
        used        = up + down

        # expiry_time ممکنه میلی‌ثانیه یا ثانیه باشه - هر دو رو پوشش میدیم
        if expiry_time > 0:
            # اگه مقدار بزرگتر از سال 3000 میلادی در ثانیه باشه، یعنی میلی‌ثانیه‌ست
            if expiry_time > 32503680000:
                expired_by_date = expiry_time <= now_ms
            else:
                expired_by_date = expiry_time <= now_s
        else:
            expired_by_date = False

        expired_by_traffic = (total > 0 and used >= total)

        if expired_by_date or expired_by_traffic:
            reason = []
            if expired_by_date:
                reason.append("date")
            if expired_by_traffic:
                reason.append("traffic")
            print(f"[EXPIRE-WATCHER] Disabling inbound id={iid} remark={remark} reason={','.join(reason)}")
            disabled_ids.append(int(iid))

    if not disabled_ids:
        return

    # غیرفعال کردن همه inboundهای منقضی‌شده
    cur.execute(
        "UPDATE inbounds SET enable=0 WHERE id IN ({})".format(
            ",".join("?" for _ in disabled_ids)
        ),
        disabled_ids
    )

    conn.commit()
    print(f"[EXPIRE-WATCHER] Disabled {len(disabled_ids)} tunnel inbound(s), restarting core...")
    restart_xui_core()


def main():
    ap = argparse.ArgumentParser(description="WinNet - Inbound Tunnel Sync")
    ap.add_argument("--db", default=DB_DEFAULT, help="Path to x-ui database")
    ap.add_argument("--interval", type=int, default=30, help="Sync interval in seconds (0 = run once)")
    ap.add_argument("--apply", action="store_true", help="Apply changes (otherwise dry-run)")
    ap.add_argument("--backup", action="store_true", help="Create backup before changes")
    ap.add_argument("--init", action="store_true", help="Initialize meta table")
    ap.add_argument("--debug", action="store_true", help="Enable debug output")
    ap.add_argument("--expire-check-interval", type=int, default=10,
                    dest="expire_check_interval",
                    help="Interval in seconds for independent expire watcher (default: 10)")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print("[ERROR] Database not found:", args.db)
        return

    if args.apply and args.backup:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        bak = f"{args.db}.tunnel_bak_{ts}"
        shutil.copy2(args.db, bak)
        print(f"[INFO] Backup: {bak}")

    conn = sqlite3.connect(args.db, timeout=60, check_same_thread=False)
    conn.execute("PRAGMA busy_timeout = 3000")
    try:
        if args.init:
            ensure_seed(conn, debug=args.debug)
            return
        if args.interval <= 0:
            sync_once(conn, apply=args.apply, debug=args.debug)
        else:
            # اگه --apply باشه، thread مستقل expire watcher رو راه‌اندازی کن
            if args.apply:
                watcher_thread = threading.Thread(
                    target=expire_watcher_loop,
                    args=(args.db, args.expire_check_interval),
                    daemon=True
                )
                watcher_thread.start()

            print(f"[INFO] Loop interval={args.interval}s apply={args.apply}")
            while True:
                try:
                    sync_once(conn, apply=args.apply, debug=args.debug)
                except Exception as e:
                    print(f"[ERROR] iteration: {e}")
                time.sleep(args.interval)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
