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
SCRIPT_PATH="/usr/local/bin/sync_xui_sqlite.py"
SERVICE_PATH="/etc/systemd/system/sync_xui.service"
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
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Please run as root: sudo bash install.sh"
        exit 1
    fi
}

get_service_status() {
    if systemctl is-active --quiet sync_xui.service 2>/dev/null; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        echo -e "${YELLOW}Inactive (Enabled)${NC}"
    elif [ -f "$SERVICE_PATH" ]; then
        echo -e "${RED}Stopped${NC}"
    else
        echo -e "${RED}Not Installed${NC}"
    fi
}

is_installed() {
    [ -f "$SCRIPT_PATH" ] && [ -f "$SERVICE_PATH" ]
}

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
    if systemctl is-active --quiet sync_xui.service 2>/dev/null; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        echo -e "${YELLOW}Inactive (Enabled)${NC}"
    elif [ -f "$SERVICE_PATH" ]; then
        echo -e "${RED}Stopped${NC}"
    else
        echo -e "${RED}Not Installed${NC}"
    fi
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
    echo -e "  Service Status: $(get_service_status)"
    echo ""
    echo "  ---------------------------------"
    echo ""
    echo -e "  ${GREEN}1)${NC} Enable Service"
    echo -e "  ${RED}2)${NC} Disable Service"
    echo -e "  ${BLUE}3)${NC} Update Script"
    echo -e "  ${YELLOW}4)${NC} Uninstall"
    echo -e "  ${CYAN}0)${NC} Exit"
    echo ""
    echo "  ---------------------------------"
    echo ""
}
enable_service() {
    echo ""
    echo -e "${BLUE}[i]${NC} Enabling service..."
    systemctl daemon-reload
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1
    if systemctl is-active --quiet sync_xui.service; then
        echo -e "${GREEN}[OK]${NC} Service enabled and started."
    else
        echo -e "${RED}[ERROR]${NC} Failed to start service."
        echo -e "${YELLOW}[!]${NC} Check logs: sudo journalctl -u sync_xui.service -f"
    fi
    echo ""
    read -p "Press Enter to continue..." _
}
disable_service() {
    echo ""
    echo -e "${BLUE}[i]${NC} Disabling service..."
    systemctl disable --now sync_xui.service > /dev/null 2>&1
    systemctl stop sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Service disabled."
    echo ""
    read -p "Press Enter to continue..." _
}
update_script() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating from GitHub..."
    systemctl stop sync_xui.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Main script updated."
    else
        echo -e "${RED}[ERROR]${NC} Failed to download script."
        read -p "Press Enter to continue..." _
        return
    fi
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Service file updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download service file."
    fi
    echo -e "${BLUE}[i]${NC} Updating dependencies..."
    "$VENV_PATH/bin/pip" install --upgrade requests > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Dependencies updated."
    systemctl daemon-reload
    systemctl start sync_xui.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Service restarted."
    echo ""
    echo -e "${GREEN}${BOLD}Update completed!${NC}"
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
    systemctl stop sync_xui.service > /dev/null 2>&1
    systemctl disable sync_xui.service > /dev/null 2>&1
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[OK]${NC} Service removed."
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Main script removed."
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
        1) enable_service ;;
        2) disable_service ;;
        3) update_script ;;
        4) uninstall ;;
        0) echo ""; echo -e "${CYAN}Bye!${NC}"; echo ""; exit 0 ;;
        *) echo -e "${RED}[ERROR]${NC} Invalid option!"; sleep 1 ;;
    esac
done
EOFCLI
    chmod +x "$CLI_CMD"
}

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

    print_info "Step 5/7: Downloading main script..."
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        print_status "Script saved to $SCRIPT_PATH"
    else
        print_error "Failed to download script! Check GitHub URL."
        exit 1
    fi

    print_info "Step 6/7: Downloading systemd service..."
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        print_status "Service file installed."
    else
        print_error "Failed to download service file!"
        exit 1
    fi

    print_info "Step 7/7: Running init..."
    if [ -f "$DB_PATH" ]; then
        /usr/bin/env python3 "$SCRIPT_PATH" --db "$DB_PATH" --init --debug
        print_status "Init completed."
    else
        print_warn "Database $DB_PATH not found!"
        print_warn "Make sure 3X-UI is installed, then run init manually:"
        echo "  sudo /usr/bin/env python3 $SCRIPT_PATH --db $DB_PATH --init --debug"
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
    print_info "To manage, run: ${CYAN}${BOLD}sudo winnet-xui${NC}"
    echo ""
}

check_root

if [ "$1" = "install-cli-only" ]; then
    install_cli
    exit 0
fi

install
