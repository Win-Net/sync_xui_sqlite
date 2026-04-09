# راهنمای نصب دستی WinNet XUI Sync


## مرحله ۱ — دانلود پروژه از GitHub (روی سیستم شخصی)

به آدرس زیر برید و فایل ZIP پروژه رو دانلود کنید:

```bash
https://github.com/Win-Net/sync_xui_sqlite/archive/refs/heads/main.zip
```

یا با دستور:

```bash
wget https://github.com/Win-Net/sync_xui_sqlite/archive/refs/heads/main.zip
```

---

## مرحله ۲ — انتقال فایل به سرور

### روش ۱: با SCP (ترمینال)

```bash
scp main.zip root@IP_SERVER:/root/
```

### روش ۲: با نرم‌افزار WinSCP (ویندوز)

1. WinSCP رو باز کنید
2. با اطلاعات سرور وصل بشید
3. فایل `main.zip` رو به پوشه `/root/` بکشید

---

## مرحله ۳ — وارد سرور بشید

```bash
ssh root@IP_SERVER
```

---

## مرحله ۴ — خارج کردن از حالت فشرده

```bash
cd /root
unzip main.zip
cd sync_xui_sqlite-main
```

---

## مرحله ۵ — انتقال فایل‌ها به محل مورد نظر

```bash
mv sync_xui_sqlite.py /usr/local/bin/sync_xui_sqlite.py && mv sync_inbound_tunnel.py /usr/local/bin/sync_inbound_tunnel.py && mv sync_xui.service /etc/systemd/system/sync_xui.service && mv sync_inbound_tunnel.service /etc/systemd/system/sync_inbound_tunnel.service && chmod 755 /usr/local/bin/sync_xui_sqlite.py /usr/local/bin/sync_inbound_tunnel.py && chmod 644 /etc/systemd/system/sync_xui.service /etc/systemd/system/sync_inbound_tunnel.service
```

---

## مرحله ۶ — نصب Python (اختیاری — فقط اگه به اینترنت دسترسی دارید)

### روش الف: اتصال از طریق پروکسی

```bash
export http_proxy="http://PROXY_IP:PORT"
export https_proxy="http://PROXY_IP:PORT"

apt update
apt install -y python3 python3-venv python3-pip
python3 -m venv /opt/xui_sync_env
/opt/xui_sync_env/bin/pip install requests

unset http_proxy
unset https_proxy
```

### روش ب: دانلود wheel از سیستم شخصی و انتقال به سرور

روی سیستم شخصی:

```bash
pip download requests -d /tmp/requests_pkg
scp -r /tmp/requests_pkg root@IP_SERVER:/root/
```

روی سرور:

```bash
apt install -y python3 python3-venv
python3 -m venv /opt/xui_sync_env
/opt/xui_sync_env/bin/pip install --no-index --find-links=/root/requests_pkg requests
```

---

## مرحله ۷ — راه‌اندازی (Init)

```bash
python3 /usr/local/bin/sync_xui_sqlite.py --db /etc/x-ui/x-ui.db --init
python3 /usr/local/bin/sync_inbound_tunnel.py --db /etc/x-ui/x-ui.db --init
```

---

## مرحله ۸ — نصب منوی مدیریت

```bash
chmod +x /root/sync_xui_sqlite-main/install.sh
bash /root/sync_xui_sqlite-main/install.sh install-cli-only
```

---

## مرحله ۹ — مدیریت سرویس‌ها

```bash
winnet-xui
```

---

## بررسی وضعیت سرویس‌ها

```bash
systemctl status sync_xui.service
systemctl status sync_inbound_tunnel.service

journalctl -u sync_xui.service -f
journalctl -u sync_inbound_tunnel.service -f
```
