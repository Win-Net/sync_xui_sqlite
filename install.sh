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
ENFORCE_SCRIPT_PATH="/usr/local/bin/enforce_expiry.sh"
ENFORCE_SERVICE_PATH="/etc/systemd/system/enforce_expiry.service"

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
ENFORCE_SCRIPT_PATH="/usr/local/bin/enforce_expiry.sh"
ENFORCE_SERVICE_PATH="/etc/systemd/system/enforce_expiry.service"
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
    echo -e "  Enforce Expiry:  $(get_service_status enforce_expiry.service)"
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

    # اگر اسکریپت نصب نشده، دانلود کن
    if [ ! -f "$ENFORCE_SCRIPT_PATH" ]; then
        echo -e "${BLUE}[i]${NC} Enforce expiry not installed. Downloading..."
        if curl -fsSL "$GITHUB_RAW/enforce_expiry.sh" -o "$ENFORCE_SCRIPT_PATH"; then
            chmod 755 "$ENFORCE_SCRIPT_PATH"
            echo -e "${GREEN}[OK]${NC} Enforce expiry script downloaded."
        else
            echo -e "${RED}[ERROR]${NC} Failed to download enforce expiry script."
            read -p "Press Enter to continue..." _
            return
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Check interval (how often to check for expired clients):${NC}"
    echo -e "  ${GREEN}1)${NC} Every 30 seconds  ${YELLOW}(recommended)${NC}"
    echo -e "  ${GREEN}2)${NC} Every 60 seconds"
    echo -e "  ${GREEN}3)${NC} Every 2 minutes"
    echo -e "  ${GREEN}4)${NC} Every 5 minutes"
    echo ""
    read -p "  Select [1]: " ichoice
    case "${ichoice:-1}" in
        2) INTERVAL=60 ;;
        3) INTERVAL=120 ;;
        4) INTERVAL=300 ;;
        *) INTERVAL=30 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Cooldown between restarts:${NC}"
    echo -e "  ${GREEN}1)${NC} 60 seconds"
    echo -e "  ${GREEN}2)${NC} 2 minutes  ${YELLOW}(recommended)${NC}"
    echo -e "  ${GREEN}3)${NC} 5 minutes"
    echo -e "  ${GREEN}4)${NC} 10 minutes"
    echo ""
    read -p "  Select [2]: " cchoice
    case "${cchoice:-2}" in
        1) COOLDOWN=60 ;;
        3) COOLDOWN=300 ;;
        4) COOLDOWN=600 ;;
        *) COOLDOWN=120 ;;
    esac

    echo ""
    echo -e "${BLUE}[i]${NC} Installing enforce expiry (interval=${INTERVAL}s cooldown=${COOLDOWN}s)..."

    bash "$ENFORCE_SCRIPT_PATH" install "$INTERVAL" "$COOLDOWN"

    echo ""
    if systemctl is-active --quiet enforce_expiry.service; then
        echo -e "${GREEN}[OK]${NC} Enforce expiry service enabled and started."
    else
        echo -e "${RED}[ERROR]${NC} Failed to start enforce expiry service."
        echo -e "${YELLOW}[!]${NC} Check logs: sudo journalctl -u enforce_expiry.service -f"
    fi
    echo ""
    read -p "Press Enter to continue..." _
}

disable_enforce_expiry() {
    echo ""
    echo -e "${BLUE}[i]${NC} Disabling enforce expiry service..."
    systemctl disable --now enforce_expiry.service > /dev/null 2>&1
    systemctl stop enforce_expiry.service > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Enforce expiry service disabled."
    echo ""
    read -p "Press Enter to continue..." _
}

update_all() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating all scripts from GitHub..."
    echo ""

    systemctl stop sync_xui.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Client sync script updated."
    else
        echo -e "${RED}[ERROR]${NC} Failed to download client sync script."
    fi
    if curl -fsSL "$GITHUB_RAW/sync_xui.service" -o "$SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Client sync service file updated."
    fi

    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
        chmod 755 "$TUNNEL_SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Tunnel sync script updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download tunnel sync script (may not exist yet)."
    fi
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.service" -o "$TUNNEL_SERVICE_PATH"; then
        echo -e "${GREEN}[OK]${NC} Tunnel sync service file updated."
    fi

    # فقط اسکریپت enforce expiry آپدیت میشه — service file دست نمیخوره
    systemctl stop enforce_expiry.service > /dev/null 2>&1
    if curl -fsSL "$GITHUB_RAW/enforce_expiry.sh" -o "$ENFORCE_SCRIPT_PATH"; then
        chmod 755 "$ENFORCE_SCRIPT_PATH"
        echo -e "${GREEN}[OK]${NC} Enforce expiry script updated."
    else
        echo -e "${YELLOW}[!]${NC} Failed to download enforce expiry script."
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
    if systemctl is-enabled --quiet enforce_expiry.service 2>/dev/null; then
        systemctl start enforce_expiry.service > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Enforce expiry service restarted."
    fi

    echo ""
    echo -e "${GREEN}${BOLD}All updates completed!${NC}"
    echo -e "${BLUE}[i]${NC} To enable Enforce Expiry: select option 7 from menu."
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
    echo -e "${GREEN}[OK]${NC} Client sync service removed."

    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1
    systemctl disable sync_inbound_tunnel.service > /dev/null 2>&1
    rm -f "$TUNNEL_SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Tunnel sync service removed."

    systemctl stop enforce_expiry.service > /dev/null 2>&1
    systemctl disable enforce_expiry.service > /dev/null 2>&1
    rm -f "$ENFORCE_SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Enforce expiry service removed."

    systemctl daemon-reload

    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Client sync script removed."

    rm -f "$TUNNEL_SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Tunnel sync script removed."

    rm -f "$ENFORCE_SCRIPT_PATH"
    echo -e "${GREEN}[OK]${NC} Enforce expiry script removed."

    rm -rf "$VENV_PATH"
    echo -e "${GREEN}[OK]${NC} Python venv removed."

    rm -rf /opt/xui-enforce-expiry
    echo -e "${GREEN}[OK]${NC} Enforce expiry data removed."

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
        1)  enable_client_sync ;;
        2)  disable_client_sync ;;
        3)  update_client_sync ;;
        4)  enable_tunnel_sync ;;
        5)  disable_tunnel_sync ;;
        6)  update_tunnel_sync ;;
        7)  enable_enforce_expiry ;;
        8)  disable_enforce_expiry ;;
        9)  update_all ;;
        10) uninstall ;;
        0)  echo ""; echo -e "${CYAN}Bye!${NC}"; echo ""; exit 0 ;;
        *)  echo -e "${RED}[ERROR]${NC} Invalid option!"; sleep 1 ;;
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

    print_info "Step 1/8: Updating package list..."
    apt update -qq > /dev/null 2>&1
    print_status "Package list updated."

    print_info "Step 2/8: Installing python3-venv..."
    apt install -y python3-venv > /dev/null 2>&1
    print_status "python3-venv installed."

    print_info "Step 3/8: Creating Python virtual environment..."
    python3 -m venv "$VENV_PATH"
    print_status "Venv created at $VENV_PATH"

    print_info "Step 4/8: Installing requests library..."
    "$VENV_PATH/bin/pip" install requests > /dev/null 2>&1
    print_status "requests installed."

    print_info "Step 5/8: Downloading client sync script..."
    if curl -fsSL "$GITHUB_RAW/sync_xui_sqlite.py" -o "$SCRIPT_PATH"; then
        chmod 755 "$SCRIPT_PATH"
        print_status "Client sync script saved to $SCRIPT_PATH"
    else
        print_error "Failed to download client sync script!"
        exit 1
    fi

    print_info "Step 6/8: Downloading tunnel sync script..."
    if curl -fsSL "$GITHUB_RAW/sync_inbound_tunnel.py" -o "$TUNNEL_SCRIPT_PATH"; then
        chmod 755 "$TUNNEL_SCRIPT_PATH"
        print_status "Tunnel sync script saved to $TUNNEL_SCRIPT_PATH"
    else
        print_warn "Failed to download tunnel sync script (optional)."
    fi

    print_info "Step 7/8: Downloading enforce expiry script..."
    if curl -fsSL "$GITHUB_RAW/enforce_expiry.sh" -o "$ENFORCE_SCRIPT_PATH"; then
        chmod 755 "$ENFORCE_SCRIPT_PATH"
        print_status "Enforce expiry script saved to $ENFORCE_SCRIPT_PATH"
    else
        print_warn "Failed to download enforce expiry script (optional)."
    fi

    print_info "Step 8/8: Downloading systemd services..."
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
    print_info "Client sync:     ${GREEN}Enabled${NC}"
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
