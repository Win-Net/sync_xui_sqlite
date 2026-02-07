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
    echo -e "  Client Sync:  $(get_service_status sync_xui.service)"
    echo -e "  Tunnel Sync:  $(get_service_status sync_inbound_tunnel.service)"
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
    echo "  ------------------------------------"
    echo ""
    echo -e "  ${BLUE}7)${NC} Update All"
    echo -e "  ${YELLOW}8)${NC} Uninstall Everything"
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
    # Run init
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

update_all() {
    echo ""
    echo -e "${BLUE}[i]${NC} Updating all scripts from GitHub..."
    echo ""

    # Update client sync
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

    # Update tunnel sync
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

    # Update dependencies
    "$VENV_PATH/bin/pip" install --upgrade requests > /dev/null 2>&1
    echo -e "${GREEN}[OK]${NC} Dependencies updated."

    # Update CLI
    if curl -fsSL "$GITHUB_RAW/install.sh" -o /tmp/winnet_install_tmp.sh; then
        bash /tmp/winnet_install_tmp.sh install-cli-only
        rm -f /tmp/winnet_install_tmp.sh
        echo -e "${GREEN}[OK]${NC} CLI command updated."
    fi

    systemctl daemon-reload

    # Restart only active services
    if systemctl is-enabled --quiet sync_xui.service 2>/dev/null; then
        systemctl start sync_xui.service > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Client sync service restarted."
    fi
    if systemctl is-enabled --quiet sync_inbound_tunnel.service 2>/dev/null; then
        systemctl start sync_inbound_tunnel.service > /dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Tunnel sync service restarted."
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

    # Stop and remove client sync
    systemctl stop sync_xui.service > /dev/null 2>&1
    systemctl disable sync_xui.service > /dev/null 2>&1
    rm -f "$SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Client sync service removed."

    # Stop and remove tunnel sync
    systemctl stop sync_inbound_tunnel.service > /dev/null 2>&1
    systemctl disable sync_inbound_tunnel.service > /dev/null 2>&1
    rm -f "$TUNNEL_SERVICE_PATH"
    echo -e "${GREEN}[OK]${NC} Tunnel sync service removed."

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
        7) update_all ;;
        8) uninstall ;;
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

    print_info "Step 7/8: Downloading systemd services..."
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

    print_info "Step 8/8: Running init..."
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

    # Enable only client sync by default
    systemctl enable --now sync_xui.service > /dev/null 2>&1
    systemctl start sync_xui.service > /dev/null 2>&1

    install_cli

    echo ""
    echo -e "${GREEN}${BOLD}========================================"
    echo "  Installation completed successfully!"
    echo "========================================${NC}"
    echo ""
    print_info "Client sync: ${GREEN}Enabled${NC}"
    print_info "Tunnel sync: ${YELLOW}Disabled${NC} (enable via menu)"
    print_info "To manage, run: ${CYAN}${BOLD}sudo winnet-xui${NC}"
    echo ""
}

check_root

if [ "$1" = "install-cli-only" ]; then
    install_cli
    exit 0
fi

install
