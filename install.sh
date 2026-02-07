
# تنظیمات
GITHUB_RAW="https://raw.githubusercontent.com/Win-Net/sync_xui_sqlite/main"
SCRIPT_PATH="/usr/local/bin/sync_xui_sqlite.py"
SERVICE_PATH="/etc/systemd/system/sync_xui.service"
VENV_PATH="/opt/xui_sync_env"
DB_PATH="/etc/x-ui/x-ui.db"
CLI_CMD="/usr/local/bin/winnet-xui"

# ===== توابع کمکی =====

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║                                              ║"
    echo "║        WinNet XUI Sync Manager               ║"
    echo "║        Subscription Sync Tool                ║"
    echo "║                                              ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "این اسکریپت باید با دسترسی root اجرا بشه."
        print_info "لطفا با sudo اجرا کنید: sudo bash install.sh"
        exit 1
    fi
}

get_service_status() {
    if systemctl is-active --quiet sync_xui.service 2>/dev/null; then
        echo -e "${GREEN}● فعال (Active)${NC}"
    elif systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        echo -e "${YELLOW}● غیرفعال (Inactive - Enabled)${NC}"
    elif [[ -f "$SERVICE_PATH" ]]; then
        echo -e "${RED}● متوقف (Stopped)${NC}"
    else
        echo -e "${RED}● نصب نشده (Not Installed)${NC}"
    fi
}

is_installed() {
    [[ -f "$SCRIPT_PATH" ]] && [[ -f "$SERVICE_PATH" ]]
}

# ===== توابع اصلی =====

install() {
    print_banner
    echo -e "${MAGENTA}${BOLD}  ── نصب WinNet XUI Sync ──${NC}\n"

    # بررسی نصب قبلی
    if is_installed; then
        print_warn "اسکریپت قبلاً نصب شده. برای آپدیت از گزینه آپدیت استفاده کنید."
        read -p "آیا میخواهید ادامه دهید و مجدد نصب کنید؟ (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return
        fi
    fi

    # مرحله 1: آپدیت سیستم
    print_info "مرحله 1/7: آپدیت لیست پکیج‌ها..."
    apt update -qq > /dev/null 2>&1
    print_status "لیست پکیج‌ها آپدیت شد."

    # مرحله 2: نصب python3-venv
    print_info "مرحله 2/7: نصب python3-venv..."
    apt install -y python3-venv > /dev/null 2>&1
    print_status "python3-venv نصب شد."

    # مرحله 3: ساخت virtual environment
    print_info "مرحله 3/7: ساخت محیط مجازی پایتون..."
    python3 -m venv "$VENV_PATH"
    print_status "محیط مجازی در $VENV_PATH ساخته شد."

    # مرحله 4: نصب وابستگی‌ها
    print_info "مرحله 4/7: نصب کتابخانه requests..."
    "$VENV_PATH/bin/pip" install requests > /dev/null 2>&1
    print_status "کتابخانه requests نصب شد."

    # مرحله 5: دانلود اسکریپت اصلی
    print_info "مرحله 5/7: دانلود اسکریپت اصلی از گیت‌هاب..."
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        print_status "اسکریپت در $SCRIPT_PATH قرار گرفت."
    else
        print_error "خطا در دانلود اسکریپت اصلی! لینک گیت‌هاب رو بررسی کنید."
        exit 1
    fi

    # مرحله 6: دانلود و نصب سرویس systemd
    print_info "مرحله 6/7: دانلود و نصب سرویس systemd..."
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        print_status "سرویس systemd نصب شد."
    else
        print_error "خطا در دانلود فایل سرویس! لینک گیت‌هاب رو بررسی کنید."
        exit 1
    fi

    # مرحله 7: مقداردهی اولیه (init)
    print_info "مرحله 7/7: مقداردهی اولیه اسکریپت (init)..."
    if [[ -f "$DB_PATH" ]]; then
        /usr/bin/env python3 "$SCRIPT_PATH" --db "$DB_PATH" --init --debug
        print_status "مقداردهی اولیه انجام شد."
    else
        print_warn "فایل دیتابیس $DB_PATH پیدا نشد!"
        print_warn "مطمئن بشید 3X-UI نصب شده، بعد دستی init کنید:"
        echo -e "  ${CYAN}sudo /usr/bin/env python3 $SCRIPT_PATH --db $DB_PATH --init --debug${NC}"
    fi

    # فعال‌سازی سرویس
    systemctl daemon-reload
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1

    # نصب دستور CLI
    install_cli

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       ✓ نصب با موفقیت انجام شد!             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "برای مدیریت دستور زیر رو بزنید:"
    echo -e "  ${CYAN}${BOLD}winnet-xui${NC}"
    echo ""
}

install_cli() {
    # ساخت دستور winnet-xui
    cat > "$CLI_CMD" << 'CLIEOF'
#!/bin/bash

# ============================================
#  WinNet XUI Sync - CLI Manager
# ============================================

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
VENV_PATH="/opt/xui_sync_env"
DB_PATH="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/Win-Net/sync_xui_sqlite/main"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗]${NC} لطفاً با sudo اجرا کنید: sudo winnet-xui"
        exit 1
    fi
}

get_service_status() {
    if systemctl is-active --quiet sync_xui.service 2>/dev/null; then
        echo -e "${GREEN}● فعال (Active)${NC}"
    elif systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        echo -e "${YELLOW}● غیرفعال (Inactive)${NC}"
    elif [[ -f "$SERVICE_PATH" ]]; then
        echo -e "${RED}● متوقف (Stopped)${NC}"
    else
        echo -e "${RED}● نصب نشده (Not Installed)${NC}"
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║                                              ║"
    echo "║        WinNet XUI Sync Manager               ║"
    echo "║        Subscription Sync Tool                ║"
    echo "║                                              ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  وضعیت سرویس: $(get_service_status)"
    echo ""
    echo -e "${BOLD}  ─────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ✅  فعال کردن سرویس"
    echo -e "  ${RED}2)${NC} ⛔  غیرفعال کردن سرویس"
    echo -e "  ${BLUE}3)${NC} 🔄  آپدیت اسکریپت"
    echo -e "  ${YELLOW}4)${NC} 📋  مشاهده زنده لاگ"
    echo -e "  ${MAGENTA}5)${NC} 🗑️   حذف کامل"
    echo -e "  ${CYAN}0)${NC} 🚪  خروج"
    echo ""
    echo -e "${BOLD}  ─────────────────────────────────────${NC}"
    echo ""
}

enable_service() {
    echo -e "\n${BLUE}[i]${NC} فعال‌سازی سرویس..."
    systemctl daemon-reload
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1
    if systemctl is-active --quiet sync_xui.service; then
        echo -e "${GREEN}[✓]${NC} سرویس با موفقیت فعال شد."
    else
        echo -e "${RED}[✗]${NC} خطا در فعال‌سازی سرویس."
        echo -e "${YELLOW}[!]${NC} لاگ رو بررسی کنید: sudo journalctl -u sync_xui.service -f"
    fi
    echo ""
    read -p "برای بازگشت Enter بزنید..." _
}

disable_service() {
    echo -e "\n${BLUE}[i]${NC} غیرفعال‌سازی سرویس..."
    systemctl disable --now sync_xui.service > /dev/null 2>&1
    systemctl stop sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[✓]${NC} سرویس غیرفعال شد."
    echo ""
    read -p "برای بازگشت Enter بزنید..." _
}

update_script() {
    echo -e "\n${BLUE}[i]${NC} در حال آپدیت اسکریپت از گیت‌هاب..."

    # متوقف کردن سرویس
    systemctl stop sync_xui.service > /dev/null 2>&1

    # دانلود اسکریپت جدید
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        echo -e "${GREEN}[✓]${NC} اسکریپت اصلی آپدیت شد."
    else
        echo -e "${RED}[✗]${NC} خطا در دانلود اسکریپت."
        read -p "برای بازگشت Enter بزنید..." _
        return
    fi

    # دانلود سرویس جدید
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        echo -e "${GREEN}[✓]${NC} فایل سرویس آپدیت شد."
    else
        echo -e "${YELLOW}[!]${NC} خطا در دانلود فایل سرویس (ادامه با فایل قبلی)."
    fi

    # آپدیت CLI
    if curl -fsSL "$GITHUB_RAW/install.sh" -o /tmp/winnet_update.sh; then
        bash /tmp/winnet_update.sh install-cli-only > /dev/null 2>&1
        rm -f /tmp/winnet_update.sh
    fi

    # آپدیت pip packages
    echo -e "${BLUE}[i]${NC} آپدیت وابستگی‌ها..."
    "$VENV_PATH/bin/pip" install --upgrade requests > /dev/null 2>&1
    echo -e "${GREEN}[✓]${NC} وابستگی‌ها آپدیت شد."

    # ری‌استارت سرویس
    systemctl daemon-reload
    systemctl start sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[✓]${NC} سرویس ری‌استارت شد."

    echo -e "\n${GREEN}${BOLD}آپدیت با موفقیت انجام شد!${NC}"
    echo ""
    read -p "برای بازگشت Enter بزنید..." _
}

view_logs() {
    echo -e "\n${BLUE}[i]${NC} نمایش لاگ زنده (برای خروج Ctrl+C بزنید)..."
    echo -e "${YELLOW}─────────────────────────────────────${NC}\n"
    journalctl -u sync_xui.service -f
}

uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  ⚠️  هشدار: تمام فایل‌های مربوط به WinNet XUI Sync حذف خواهند شد!${NC}"
    echo ""
    read -p "  آیا مطمئن هستید؟ (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${BLUE}[i]${NC} عملیات لغو شد."
        read -p "برای بازگشت Enter بزنید..." _
        return
    fi

    echo -e "\n${BLUE}[i]${NC} در حال حذف..."

    # توقف و حذف سرویس
    systemctl stop sync_xui.service > /dev/null 2>&1
    systemctl disable sync_xui.service > /dev/null 2>&1
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[✓]${NC} سرویس systemd حذف شد."

    # حذف اسکریپت
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}[✓]${NC} اسکریپت اصلی حذف شد."

    # حذف محیط مجازی
    rm -rf "$VENV_PATH"
    echo -e "${GREEN}[✓]${NC} محیط مجازی پایتون حذف شد."

    # حذف CLI
    rm -f /usr/local/bin/winnet-xui
    echo -e "${GREEN}[✓]${NC} دستور winnet-xui حذف شد."

    echo ""
    echo -e "${GREEN}${BOLD}حذف کامل انجام شد.${NC}"
    echo ""
    exit 0
}

# === اجرا ===
check_root

while true; do
    show_menu
    read -p "  انتخاب شما: " choice
    case $choice in
        1) enable_service ;;
        2) disable_service ;;
        3) update_script ;;
        4) view_logs ;;
        5) uninstall ;;
        0) echo -e "\n${CYAN}خداحافظ! 👋${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}[✗]${NC} گزینه نامعتبر!"; sleep 1 ;;
    esac
done
CLIEOF

    chmod +x "$CLI_CMD"
}

# ===== نقطه ورود =====

check_root

# اگر با پارامتر install-cli-only صدا زده شد فقط CLI رو نصب کن
if [[ "$1" == "install-cli-only" ]]; then
    install_cli
    exit 0
fi

# اگر مستقیم اجرا شد (مثلا از curl | bash) مستقیم نصب کن
install
