#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
import sqlite3, json, argparse, os, time, shutil, subprocess
from datetime import datetime

DB_DEFAULT = "/etc/x-ui/x-ui.db"

def jload(s):
    if isinstance(s, dict): return s
    try: return json.loads(s)
    except: return {}

def jdump(o): return json.dumps(o, ensure_ascii=False, separators=(",", ":"))

def ensure_meta(conn):
    c=conn.cursor()
    c.execute("""
    CREATE TABLE IF NOT EXISTS sync_meta_client(
      key TEXT PRIMARY KEY,
      subId TEXT,
      inbound_id INTEGER,
      email TEXT,
      client_id TEXT,
      signature TEXT,
      last_change INTEGER
    )""")
    conn.commit()

def key_for(sub,iid,email,cid):
    k_id = (cid or "").strip()
    k_em = (email or "").strip()
    ident = k_id if k_id else k_em
    return f"{sub}|{iid}|{ident}"

def load_inbounds(conn):
    cur=conn.cursor()
    cur.execute("SELECT id, settings FROM inbounds")
    rows=cur.fetchall()
    out=[]
    for iid, s in rows:
        out.append((int(iid), jload(s)))
    return out

def load_ct_map(conn):
    cur=conn.cursor()
    cur.execute("SELECT id,inbound_id,email,up,down,total,expiry_time,enable,reset FROM client_traffics")
    m={}
    for rid,iid,email,up,down,total,expiry,enable,reset in cur.fetchall():
        m[(int(iid),(email or ""))]={
            "row_id":int(rid),
            "inbound_id":int(iid),
            "email":(email or ""),
            "up":int(up or 0),
            "down":int(down or 0),
            "quota_db":int(total or 0),
            "expiry":int(expiry or 0),
            "enable":int(0 if enable in (0,"0",False) else 1),
            "reset":int(reset or 0)
        }
    return m

def used_from_ct(ct):
    if not ct: return 0
    return int(ct.get("up") or 0) + int(ct.get("down") or 0)

def is_expired_by_date(expiry_val):
    """Check if client is expired by date"""
    if not expiry_val or expiry_val <= 0:
        return False
    now_ms = int(time.time() * 1000)
    return expiry_val <= now_ms

def is_expired_by_traffic(quota_gb, used_bytes):
    """Check if client is expired by traffic quota"""
    if not quota_gb or quota_gb <= 0:
        return False
    quota_bytes = quota_gb * 1024 * 1024 * 1024
    return used_bytes >= quota_bytes

def should_be_enabled(client, ct):
    """Determine if client should be enabled based on current state"""
    # Get quota in GB
    quota_gb = client.get("totalGB", 0)
    try:
        quota_gb = int(quota_gb) if quota_gb else 0
    except:
        quota_gb = 0
    
    # Get expiry time
    expiry = client.get("expiryTime", 0)
    try:
        expiry = int(expiry) if expiry else 0
    except:
        expiry = 0
    
    # Get used traffic
    used = used_from_ct(ct)
    
    # Check expiration conditions
    expired_by_date = is_expired_by_date(expiry)
    expired_by_traffic = is_expired_by_traffic(quota_gb, used)
    
    # Client should be disabled if expired by either condition
    # Client should be enabled if not expired
    return not (expired_by_date or expired_by_traffic)

def signature(client, ct):
    q = client.get("totalGB", None)
    try: quota = int(q) if q is not None else None
    except: quota = None
    try: exp = int(client.get("expiryTime") or 0)
    except: exp = 0
    comment = client.get("comment") or ""
    lim = client.get("limitIp", None)
    try: limitIp = int(lim) if lim is not None else None
    except: limitIp = None
    used = used_from_ct(ct)
    quota_db = int(ct.get("quota_db") if ct else 0)
    enable = int(ct.get("enable") if ct else 1)
    up_val = int(ct.get("up") if ct else 0)
    down_val = int(ct.get("down") if ct else 0)
    return {"quota": quota, "expiry": int(exp), "comment": comment,
            "limitIp": limitIp, "used": int(used), "quota_db": int(quota_db),
            "reset": int(ct.get("reset") if ct else 0), "enable": enable,
            "updated_at": int(client.get("updated_at") or 0),
            "up": up_val, "down": down_val}

def ensure_seed(conn, debug=False):
    ensure_meta(conn)
    now=int(time.time())
    ct=load_ct_map(conn)
    inbs=load_inbounds(conn)
    cur=conn.cursor()
    n=0
    for iid,settings in inbs:
        for cl in settings.get("clients", []):
            sub = cl.get("subId") or cl.get("subscription")
            if not sub: continue
            email = cl.get("email") or ""
            cid = cl.get("id") or ""
            sig = signature(cl, ct.get((iid, email)))
            cur.execute("INSERT OR REPLACE INTO sync_meta_client(key,subId,inbound_id,email,client_id,signature,last_change) VALUES(?,?,?,?,?,?,?)",
                        (key_for(sub,iid,email,cid), sub, iid, email, cid, jdump(sig), now))
            n+=1
            if debug: print("[SEED]", sub, iid, email, jdump(sig))
    conn.commit()
    if debug: print(f"[INFO] seeded {n} entries")

def sync_once(conn, apply=False, debug=False):
    ensure_meta(conn)
    cur=conn.cursor()
    ct=load_ct_map(conn)
    inbs=load_inbounds(conn)

    cur.execute("SELECT key,signature,last_change FROM sync_meta_client")
    meta_map={k:(json.loads(sig) if sig else {}, int(lc or 0)) for k,sig,lc in cur.fetchall()}
    now=int(time.time())
    upserts=[]

    entries=[]
    for iid,settings in inbs:
        for cl in settings.get("clients", []):
            sub = cl.get("subId") or cl.get("subscription")
            if not sub: continue
            email = cl.get("email") or ""
            cid = cl.get("id") or ""
            k = key_for(sub, iid, email, cid)
            ct_row = ct.get((iid, email))
            sig = signature(cl, ct_row)
            old = meta_map.get(k)
            if (old and old[0] != sig) or (k not in meta_map):
                upserts.append((k, sub, iid, email, cid, jdump(sig), now))
                meta_map[k]=(sig, now)
                if debug:
                    print("[META] change", k, "->", sig)
            entries.append({"sub":sub,"iid":iid,"email":email,"cid":cid,"client":cl,"ct":ct_row,"sig":sig})

    if upserts:
        for row in upserts:
            cur.execute("INSERT OR REPLACE INTO sync_meta_client(key,subId,inbound_id,email,client_id,signature,last_change) VALUES(?,?,?,?,?,?,?)", row)
        conn.commit()
        if debug: print(f"[INFO] meta updated {len(upserts)}")

    groups={}
    for e in entries:
        groups.setdefault(e["sub"], []).append(e)

    plans=[]
    for sub, items in groups.items():
        with_lc=[]
        for e in items:
            k=key_for(sub, e["iid"], e["email"], e["cid"])
            lc = meta_map.get(k,(None,0))[1]
            with_lc.append((lc,e))
        if not with_lc: continue
        with_lc.sort(key=lambda t:t[0], reverse=True)
        ref = with_lc[0][1]
        ref_sig = ref["sig"]
        ref_client = ref["client"]
        # determine reference updated_at (ms) from the reference inbound client settings
        ref_updated = int(ref_client.get("updated_at") or 0)
        if not ref_updated:
            # try to get updated_at from the inbounds table for the reference inbound
            try:
                cur.execute("SELECT settings FROM inbounds WHERE id=?", (ref["iid"],))
                rr = cur.fetchone()
                if rr and rr[0]:
                    ss = jload(rr[0])
                    for cc in ss.get("clients", []):
                        if (cc.get("subId") or cc.get("subscription")) == (ref_client.get("subId") or ref_client.get("subscription")) and ((cc.get("email") or "") == (ref_client.get("email") or "")):
                            ref_updated = int(cc.get("updated_at") or 0)
                            break
            except Exception:
                ref_updated = 0
        if not ref_updated:
            ref_updated = int(time.time() * 1000)

        # پیدا کردن بیشترین up و down به صورت جداگانه از همه inboundها
        max_up_across = 0
        max_down_across = 0
        for _, e in with_lc:
            ct_data = e.get("ct") or {}
            up_val = int(ct_data.get("up") or 0)
            down_val = int(ct_data.get("down") or 0)
            max_up_across = max(max_up_across, up_val)
            max_down_across = max(max_down_across, down_val)
        
        max_used_across = max_up_across + max_down_across

        # چک کردن reset flag
        group_reset_flag = any(int(x[1]["sig"].get("reset") or 0)==1 for x in with_lc) \
                           or int(ref_sig.get("reset") or 0)==1 \
                           or (int(ref_sig.get("used") or 0) < max_used_across)

        # Determine if reference client should be enabled
        ref_should_enable = should_be_enabled(ref_client, ref["ct"])

        for _, e in with_lc:
            ch={}
            ref_quota = ref_sig.get("quota")
            cur_q = e["client"].get("totalGB", None)
            try: cur_q = int(cur_q) if cur_q is not None else None
            except: cur_q = None
            if ref_quota is not None:
                if cur_q != int(ref_quota):
                    ch["quota"]= (cur_q, int(ref_quota))

            if ref_sig.get("limitIp") is not None:
                cur_lim = e["client"].get("limitIp", None)
                try: cur_lim = int(cur_lim) if cur_lim is not None else None
                except: cur_lim = None
                if cur_lim != int(ref_sig["limitIp"]):
                    ch["limitIp"]= (cur_lim, int(ref_sig["limitIp"]))

            cur_exp = int(e["sig"].get("expiry") or 0)
            ref_exp = int(ref_sig.get("expiry") or 0)
            if cur_exp != ref_exp:
                ch["expiry"]=(cur_exp, ref_exp)

            cur_com = e["sig"].get("comment") or ""
            ref_com = ref_sig.get("comment") or ""
            if cur_com != ref_com:
                ch["comment"]=(cur_com, ref_com)

            # بررسی تغییرات up و down - فقط اگر مقدار فعلی کمتر از max باشد
            cur_up = int(e["sig"].get("up") or 0)
            cur_down = int(e["sig"].get("down") or 0)
            
            # اگر reset flag فعال باشد، از مقادیر reference استفاده کن
            # در غیر این صورت فقط اگر کمتر از max باشد، به max تغییر بده
            if group_reset_flag:
                target_up = int(ref_sig.get("up") or 0)
                target_down = int(ref_sig.get("down") or 0)
                if cur_up != target_up or cur_down != target_down:
                    ch["up_down"] = ((cur_up, cur_down), (target_up, target_down))
            else:
                # فقط اگر مقدار فعلی کمتر از max باشد، تغییر بده
                target_up = max_up_across if cur_up < max_up_across else cur_up
                target_down = max_down_across if cur_down < max_down_across else cur_down
                if cur_up < max_up_across or cur_down < max_down_across:
                    ch["up_down"] = ((cur_up, cur_down), (target_up, target_down))

            cur_used = int(e["sig"].get("used") or 0)
            if group_reset_flag:
                target_used = int(ref_sig.get("used") or 0)
            else:
                target_used = max_used_across

            if cur_used != target_used:
                ch["used"]=(cur_used, target_used)

            if ref_quota is not None:
                cur_quota_db = int(e["sig"].get("quota_db") or 0)
                q_target = int(ref_quota)
                if q_target > 0 and target_used > q_target:
                    q_target = target_used
                if cur_quota_db != q_target:
                    ch["quota_db"]=(cur_quota_db, q_target)

            # Check enable status
            cur_enable = int(e["sig"].get("enable", 1))
            target_enable = 1 if ref_should_enable else 0
            if cur_enable != target_enable:
                ch["enable"] = (cur_enable, target_enable)

            if ch:
                # برای حالت غیر reset، target_up و target_down رو به درستی ست کن
                if not group_reset_flag:
                    target_up = max_up_across if "up_down" in ch else cur_up
                    target_down = max_down_across if "up_down" in ch else cur_down
                else:
                    target_up = int(ref_sig.get("up") or 0)
                    target_down = int(ref_sig.get("down") or 0)
                    
                plans.append({"sub":sub, "iid":e["iid"], "email":e["email"], "cid":e["cid"], 
                            "changes":ch, "ref_sig":ref_sig, "ref_client":ref_client,
                            "reset_flag": group_reset_flag, "ref_updated": ref_updated,
                            "target_up": target_up, "target_down": target_down})

    if not plans:
        print("[INFO] No changes required (all subscriptions already in sync).")
        return 0

    # --- APPLY ---
    conn.execute("BEGIN")
    cur=conn.cursor()
    settings_cache={}
    def get_settings(iid):
        if iid in settings_cache: return settings_cache[iid]
        cur.execute("SELECT settings FROM inbounds WHERE id=?", (iid,))
        r=cur.fetchone()
        s=jload(r[0] if r else "{}")
        settings_cache[iid]=s
        return s
    def put_settings(iid, s):
        settings_cache[iid]=s
        cur.execute("UPDATE inbounds SET settings=? WHERE id=?", (jdump(s), iid))

    ct_writes=0; set_writes=0
    for p in plans:
        iid=p["iid"]; email=p["email"]; ch=p["changes"]; ref=p["ref_sig"]; reset_flag=p.get("reset_flag", False)

        if any(k in ch for k in ("quota","limitIp","expiry","comment")):
            s=get_settings(iid)
            changed=False
            for c in s.get("clients", []):
                if (c.get("email") or "")==email and (c.get("subId") or c.get("subscription"))==p["sub"]:
                    if "quota" in ch and "totalGB" in c:
                        c["totalGB"]=int(ch["quota"][1])
                        changed=True
                    if "limitIp" in ch:
                        c["limitIp"]=int(ch["limitIp"][1])
                        changed=True
                    if "expiry" in ch:
                        c["expiryTime"]=int(ch["expiry"][1])
                        changed=True
                    if "comment" in ch:
                        c["comment"]=ch["comment"][1]
                        changed=True
                        c["updated_at"] = int(p.get("ref_updated") or int(time.time() * 1000))
                    break
            if changed:
                # ensure updated_at is set to reference timestamp for this client
                try:
                    for cc in s.get("clients", []):
                        if (cc.get("subId") or cc.get("subscription"))==p["sub"] and ((cc.get("email") or "")==p["email"]):
                            cc["updated_at"] = int(p.get("ref_updated") or int(time.time() * 1000))
                            break
                except Exception:
                    pass
                put_settings(iid, s)
                set_writes+=1

        need_ct = any(k in ch for k in ("used","expiry","quota_db","enable","up_down"))
        if need_ct:
            cur.execute("SELECT id,up,down,total,expiry_time,enable,reset FROM client_traffics WHERE inbound_id=? AND email=?",
                        (iid, email))
            row=cur.fetchone()
            rid=None; up0=0; down0=0; tot0=0; exp0=0; en0=1; reset0=0
            if row:
                rid, up0, down0, tot0, exp0, en0, reset0 = row
                up0=int(up0 or 0); down0=int(down0 or 0); tot0=int(tot0 or 0); exp0=int(exp0 or 0)
                en0=int(0 if en0 in (0,"0",False) else 1); reset0=int(reset0 or 0)

            # استفاده از target_up و target_down
            if "up_down" in ch:
                new_up = p.get("target_up", up0)
                new_down = p.get("target_down", down0)
            else:
                new_up = up0
                new_down = down0

            new_quota_db = tot0
            if "quota_db" in ch:
                new_quota_db = int(ch["quota_db"][1])
            
            # اطمینان از اینکه quota_db از مجموع up+down کمتر نباشد
            total_used = new_up + new_down
            if new_quota_db > 0 and new_quota_db < total_used:
                new_quota_db = total_used

            new_expiry = exp0
            if "expiry" in ch:
                new_expiry = int(ch["expiry"][1])

            new_enable = en0
            if "enable" in ch:
                new_enable = int(ch["enable"][1])

            if rid:
                cur.execute("UPDATE client_traffics SET up=?,down=?,total=?,expiry_time=?,enable=?,reset=0 WHERE id=?",
                            (new_up, new_down, new_quota_db, new_expiry, new_enable, rid))
            else:
                cur.execute("INSERT INTO client_traffics(inbound_id,enable,email,up,down,expiry_time,total,reset) VALUES(?,?,?,?,?,?,?,0)",
                            (iid, new_enable, email, new_up, new_down, new_expiry, new_quota_db))

            ct_writes+=1

            # After writing traffic row, ensure inbound settings client.updated_at matches reference timestamp
            try:
                s = get_settings(iid)
                changed2 = False
                for cc in s.get("clients", []):
                    if (cc.get("subId") or cc.get("subscription"))==p["sub"] and ((cc.get("email") or "")==p["email"]):
                        if int(cc.get("updated_at") or 0) != int(p.get("ref_updated") or 0):
                            cc["updated_at"] = int(p.get("ref_updated") or int(time.time() * 1000))
                            changed2 = True
                            break
                if changed2:
                    put_settings(iid, s)
                    set_writes += 1
            except Exception:
                pass

    # --- RECOMPUTE and store actual signature for each changed client ---
    now=int(time.time())
    for p in plans:
        iid = p["iid"]; sub = p["sub"]; email = p["email"]; cid = p["cid"]
        cur.execute("SELECT settings FROM inbounds WHERE id=?", (iid,))
        r = cur.fetchone()
        s = jload(r[0] if r else "{}")
        client_obj = {}
        for c in s.get("clients", []):
            if (c.get("subId") or c.get("subscription")) == sub and ((c.get("email") or "") == email or (not c.get("email") and email=="")):
                client_obj = c
                break
        if not client_obj:
            ref_sig = p["ref_sig"]
            client_obj = {
                "totalGB": ref_sig.get("quota"),
                "expiryTime": ref_sig.get("expiry"),
                "comment": ref_sig.get("comment"),
                "limitIp": ref_sig.get("limitIp")
            }
        cur.execute("SELECT up,down,total,expiry_time,enable,reset FROM client_traffics WHERE inbound_id=? AND email=?", (iid, email))
        row = cur.fetchone()
        ct_row = {}
        if row:
            up,down,total,expiry_time,enable,reset = row
            ct_row = {
                "up": int(up or 0),
                "down": int(down or 0),
                "quota_db": int(total or 0),
                "expiry": int(expiry_time or 0),
                "enable": int(0 if enable in (0,"0",False) else 1),
                "reset": int(reset or 0)
            }
        else:
            ct_row = {"up":0,"down":0,"quota_db":0,"expiry":0,"enable":1,"reset":0}

        new_sig = signature(client_obj, ct_row)
        k = key_for(sub, iid, email, cid)
        cur.execute("UPDATE sync_meta_client SET signature=?, last_change=? WHERE key=?", (jdump(new_sig), now, k))

    conn.commit()
    print(f"[APPLIED] settings_updated={set_writes}, traffic_rows_written={ct_writes}")

    return len(plans)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--db", default=DB_DEFAULT)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--backup", action="store_true")
    ap.add_argument("--init", action="store_true")
    ap.add_argument("--debug", action="store_true")
    args=ap.parse_args()

    if not os.path.exists(args.db):
        print("[ERROR] DB not found:", args.db); return

    if args.apply and args.backup:
        ts=datetime.now().strftime("%Y%m%d_%H%M%S")
        shutil.copy2(args.db, f"{args.db}.bak_{ts}")
        print("[INFO] Backup:", f"{args.db}.bak_{ts}")

    conn=sqlite3.connect(args.db, timeout=60, check_same_thread=False)
    conn.execute("PRAGMA busy_timeout = 3000")  # تنظیم زمان انتظار برای دیتابیس
    try:
        if args.init:
            ensure_seed(conn, debug=args.debug); return
        if args.interval<=0:
            sync_once(conn, apply=args.apply, debug=args.debug)
        else:
            print(f"[INFO] loop interval={args.interval}s apply={args.apply}")
            while True:
                try:
                    sync_once(conn, apply=args.apply, debug=args.debug)
                except Exception as e:
                    print("[ERROR] iteration:", e)
                time.sleep(args.interval)
    finally:
        conn.close()

if __name__=="__main__":
    main()