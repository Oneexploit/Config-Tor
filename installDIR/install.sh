#!/bin/bash

set -euo pipefail

clear

# Colors
RED='\e[38;5;196m'
ORANGE='\e[38;5;208m'
YELLOW='\e[38;5;226m'
GREEN='\e[38;5;82m'
CYAN='\e[38;5;45m'
BLUE='\e[38;5;27m'
PURPLE='\e[38;5;201m'
PINK='\e[38;5;213m'
WHITE='\e[38;5;15m'
GRAY='\e[38;5;240m'
NC='\e[0m'

colors=("$RED" "$GREEN" "$YELLOW" "$BLUE" "$CYAN" "$WHITE" "$ORANGE")
random_index=$((RANDOM % ${#colors[@]}))
random_color=${colors[$random_index]}

# Must run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Detect OS
if [ -f /etc/debian_version ]; then
    OS="debian"
    PM="apt-get"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
    PM="yum"
else
    echo -e "${RED}Unsupported OS. Debian/RedHat only.${NC}"
    exit 1
fi

# Fancy banner
echo -e "${random_color}  ╔═════════════════════════════════════════════════════╗"
echo -e "${random_color}  ║             Tor Server Management Tool              ║"
echo -e "${random_color}  ╚═════════════════════════════════════════════════════╝${NC}\n"

echo -e "    https://github.com/Oneexploit/config-tor-server    "
echo -e "         [!] This Tool Must Run As ROOT [!]            "
echo -e "               [!] Coded By Oneexploit [!]             \n"

echo -e "${CYAN}Select Best Options:${NC}\n"
echo -e "[1] Install Tor Server"
echo -e "[2] Uninstall Tor Server"
echo -e "[3] Check Tor Service Status"
echo -e "[4] Repair Tor Installation"
echo -e "[5] Run Tor Service"
echo -e "[6] Health Check"
echo -e "[7] Setup Hidden Service"
echo -e "[help] Show Help Menu"
echo -e "[99] Exit\n"



cmd_install_tor="install tor"
cmd_uninstall_tor="uninstall tor"
cmd_status_tor="status tor"
cmd_exit="exit"
cmd_help="help"
cmd_clear="clear"
cmd_Repair="onex repair"
cmd_run_tor="run Tor.Service"
cmd_health="health check"
cmd_hidden_service="setup hidden service"
cmd_list_files="ls"
# cmd_change_directory="cd"

# ================= CHECK PORTS IN FIREWALL =================
check_ports() {
    local ports=(9050 9051)
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            log "WARN" "Port $port is already in use. Tor may fail to start."
        else
            log "INFO" "Port $port is free."
        fi
    done
}


# ================= start Tor service =================

run_tor_with_journal() {
    # Start/enable tor
    check_ports
    echo -e "${CYAN}Starting Tor service...${NC}"
    systemctl start tor
    systemctl enable tor || true

    # create a temporary watcher script
    WATCHER="/tmp/tor_journal_watcher.$$"
    cat >"$WATCHER" <<'EOF'
#!/bin/bash
set -euo pipefail

# follow journal for the tor systemd unit and print lines
# exit when Bootstrapped 100% appears
journalctl -u tor -n0 -xe -f --no-pager | while IFS= read -r line; do
    echo "$line"
    # match Bootstrapped ... 100% (common message: "Bootstrapped 100%: Done")
    if echo "$line" | grep -q -E 'Bootstrapped[^0-9]*100%'; then
        echo "=== Tor Bootstrapped 100% detected, exiting watcher ==="
        exit 0
    fi
done
EOF

    chmod +x "$WATCHER"

    # try common graphical terminals (in order); if none found, fallback to running in background
    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -c "$WATCHER; sleep 1" &

    elif command -v konsole >/dev/null 2>&1; then
        konsole --noclose -e bash -c "$WATCHER; sleep 1" &

    elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --hold --command="bash -c '$WATCHER; sleep 1'" &

    elif command -v xterm >/dev/null 2>&1; then
        xterm -e "bash -c '$WATCHER; sleep 1'" &

    elif command -v lxterminal >/dev/null 2>&1; then
        lxterminal -e bash -c "$WATCHER; sleep 1" &

    elif command -v terminator >/dev/null 2>&1; then
        terminator -x bash -c "$WATCHER; sleep 1" &

    else
        # fallback: run watcher in background in same terminal (user will see it here)
        echo -e "${YELLOW}No graphical terminal found. Running watcher in background (this terminal).${NC}"
        bash -c "$WATCHER" &
    fi

    echo -e "${GREEN}Watcher started. A new terminal should show journalctl logs. It will close automatically when Bootstrapped 100% is seen.${NC}"
}


# ================= BACKUP FILES =================
secure_tor_files() {
    if [ -f /etc/tor/torrc ]; then
        BACKUP_FILE="/etc/tor/torrc.bak.$(date +%F_%T)"
        cp /etc/tor/torrc "$BACKUP_FILE"
        chmod 600 "$BACKUP_FILE"
        log "INFO" "torrc backup created at $BACKUP_FILE with secure permissions."
    fi

    TOR_DATA="/var/lib/tor"
    if [ -d "$TOR_DATA" ]; then
        chown -R debian-tor:debian-tor "$TOR_DATA" 2>/dev/null || chown -R tor:tor "$TOR_DATA" 2>/dev/null
        chmod 700 "$TOR_DATA"
        log "INFO" "DataDirectory permissions set correctly."
    fi
}


# ================= AUTO BRIDEGS =================
auto_bridges() {
    read -p "Do you want to fetch recommended bridges automatically? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        BRIDGES=$(curl -s https://bridges.torproject.org/bridges?transport=obfs4 | grep -o 'obfs4.*')
        if [[ -n "$BRIDGES" ]]; then
            echo -e "UseBridges 1\n$BRIDGES" | sudo tee -a /etc/tor/torrc
            systemctl restart tor
            log "INFO" "Automatic bridges added and Tor restarted."
        else
            log "WARN" "Failed to fetch bridges. You can add manually."
        fi
    fi
}


# ================= FUNCTIONS =================
repair_tor() {
    echo -e "${CYAN}Starting Tor repair process...${NC}"

    # 1️⃣ Sync time
    TIME_DIFF=$(($(date +%s) - $(date -u +%s)))
    if [ ${TIME_DIFF#-} -gt 5 ]; then
        echo -e "${YELLOW}[!] System time seems off by $TIME_DIFF seconds.${NC}"
        timedatectl set-ntp true
        sleep 2
        echo -e "${GREEN}System time synced.${NC}"
    fi

    # 2️⃣ Check torrc
    if ! tor --verify-config >/dev/null 2>&1; then
        echo -e "${RED}[!] torrc has errors.${NC}"
        if [ -f /etc/tor/torrc.bak ]; then
            cp /etc/tor/torrc.bak /etc/tor/torrc
            echo -e "${GREEN}Backup restored.${NC}"
        else
            echo -e "${RED}No backup found! Manual fix needed.${NC}"
        fi
    fi
    secure_tor_files
    # 3️⃣ Fix DataDirectory perms
    TOR_DATA="/var/lib/tor"
    if [ -d "$TOR_DATA" ]; then
        chown -R debian-tor:debian-tor "$TOR_DATA" 2>/dev/null || chown -R tor:tor "$TOR_DATA" 2>/dev/null
        chmod 700 "$TOR_DATA" || true
    fi

    # 4️⃣ Reinstall Tor if needed
    echo -e "${CYAN}Reinstalling Tor to fix broken packages...${NC}"
    if [ "$OS" == "debian" ]; then
        $PM install --reinstall -y tor || true
    elif [ "$OS" == "redhat" ]; then
        $PM reinstall -y tor || true
    fi

    # 5️⃣ Restart and monitor bootstrap
    systemctl restart tor
    sleep 2

    # progress bar live
    echo -e "${CYAN}Monitoring Tor bootstrap...${NC}"
    journalctl -u tor -n0 -f --no-pager | while IFS= read -r line; do
        if [[ $line =~ Bootstrapped[[:space:]]+([0-9]+)% ]]; then
            percent="${BASH_REMATCH[1]}"
            filled=$((percent / 2))
            empty=$((50 - filled))
            bar="$(printf '%0.s#' $(seq 1 $filled))$(printf '%0.s-' $(seq 1 $empty))"
            echo -ne "\rProgress: [${GREEN}${bar}${NC}] ${percent}%"
            if [[ "$percent" -eq 100 ]]; then
                echo -e "\n${GREEN}Tor has fully bootstrapped!${NC}"
                break
            fi
        fi
    done &

    sleep 5

    # 6️⃣ Check if Tor cannot reach network (possible censorship)
    BOOTSTRAP=$(journalctl -u tor -n50 | grep -oP 'Bootstrapped\s+\K[0-9]+(?=%)' | tail -1)
    if [[ "$BOOTSTRAP" -lt 50 ]]; then
        echo -e "\n${RED}[!] Tor seems unable to reach the network.${NC}"
        echo -e "${CYAN}You may need to add Bridges to bypass censorship.${NC}"
        read -p "Enter bridge addresses (comma-separated) or leave empty to skip: " BRIDGES
        if [[ -n "$BRIDGES" ]]; then
            echo -e "UseBridges 1\nBridge $BRIDGES" | sudo tee -a /etc/tor/torrc
            systemctl restart tor
            echo -e "${GREEN}Bridges added and Tor restarted.${NC}"
        fi
    fi

    echo -e "${GREEN}Repair process finished.${NC}"
}


# ================= MENU =================
while true; do
    echo -e "${RED}┌──(${WHITE}$USER${RED}㉿${WHITE}$HOSTNAME${RED})-[${WHITE}$(pwd)${RED}]${NC}"
    choice="${1:-}"
    if [[ ! $choice ]]; then
        read -p "└─$ " choice
    fi

    case $choice in
        1|"$cmd_install_tor")
            echo -e "${CYAN}Installing Tor...${NC}"
            if [ "$OS" == "debian" ]; then
                $PM update -y && $PM install -y tor
            elif [ "$OS" == "redhat" ]; then
                $PM install -y epel-release tor
                $PM install -y tor
            fi
            echo -e "${GREEN}Tor installed successfully.${NC}"
            systemctl enable --now tor
            echo -e "${GREEN}Tor service enabled and running.${NC}"
            ;;
            
        2|"$cmd_uninstall_tor")
            echo -e "${CYAN}Uninstalling Tor...${NC}"
            $PM remove -y tor
            echo -e "${GREEN}Tor uninstalled successfully.${NC}"
            ;;
            
        3|"$cmd_status_tor")
            echo -e "${CYAN}Checking Tor service status...${NC}"
            systemctl status tor --no-pager || true
            ;;
            
        4|"$cmd_Repair")
            repair_tor
            ;;
            
        5|"$cmd_run_tor")
            run_tor_with_journal
            ;;
            
        6|"$cmd_health")
            echo -e "${CYAN}Running Tor health check...${NC}"
            if command -v curl >/dev/null 2>&1; then
                response=$(curl --socks5 127.0.0.1:9050 -s https://check.torproject.org/api/ip 2>/dev/null || true)
                if [[ $response == *"IsTor\":true"* ]]; then
                    echo -e "${GREEN}[+] Tor is working correctly and your traffic is routed over Tor.${NC}"
                else
                    echo -e "${RED}[-] Tor is NOT routing traffic correctly. Please check logs!${NC}"
                fi
            else
                echo -e "${RED}curl is not installed. Please install curl to use health check.${NC}"
            fi
            ;;
            
        7|"$cmd_hidden_service")
            echo -e "${CYAN}Setting up a new Tor Hidden Service...${NC}"
            HS_DIR="/var/lib/tor/hidden_service"
            sudo mkdir -p $HS_DIR
            sudo chown -R debian-tor:debian-tor $HS_DIR
            sudo chmod 700 $HS_DIR

            if ! grep -q "HiddenServiceDir $HS_DIR" /etc/tor/torrc; then
                echo -e "\nHiddenServiceDir $HS_DIR" | sudo tee -a /etc/tor/torrc
                echo "HiddenServicePort 80 127.0.0.1:80" | sudo tee -a /etc/tor/torrc
            fi

            echo -e "${CYAN}Restarting Tor to apply hidden service config...${NC}"
            sudo systemctl restart tor
            sleep 3

            if [ -f "$HS_DIR/hostname" ]; then
                onion=$(sudo cat $HS_DIR/hostname)
                echo -e "${GREEN}[+] Hidden Service created successfully!${NC}"
                echo -e "    Your onion address is: ${YELLOW}$onion${NC}"
            else
                echo -e "${RED}[-] Hidden Service setup failed. Check Tor logs.${NC}"
            fi
            ;;
            
        99|"$cmd_exit")
            echo -e "${BLUE}Thank you for using our setup script!${NC}"
            echo -e "${BLUE}Visit our website for more tools and resources.${NC}ANGE}deactivate${NC}"
            echo -e "${YELLOW}Remember to run this script as root or with sudo privileges.${NC}"
            echo -e "${YELLOW}For any issues, please refer to the documentation or contact support.${NC}"
            echo -e "${YELLOW}Exiting the script. Goodbye!${NC}"
            exit 0
            ;;
            
        "$cmd_help")
            echo -e "${YELLOW}Available commands:${NC}"
            echo "1 / 'install tor'    : Install Tor server"
            echo "2 / 'uninstall tor'  : Uninstall Tor server"
            echo "3 / 'status tor'     : Check Tor service status"
            echo "4 / 'repair'         : Repair Tor installation"
            echo "99 / 'exit'          : Exit the script"
            ;;
        "$cmd_clear")
            clear
            ;;
            
        "$cmd_list_files")
            ls -la
            ;;

        cd\ *)
            target_dir="${choice#cd }"
            if [ -z "$target_dir" ]; then
                echo -e "${YELLOW}No directory specified.${NC}"
            elif [ -d "$target_dir" ]; then
                cd "$target_dir" || echo -e "${RED}Failed to change directory.${NC}"
                echo -e "${GREEN}Current directory: $(pwd)${NC}"
            else
                echo -e "${RED}Directory does not exist: $target_dir${NC}"
            fi
            ;;

        *)
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            ;;
    esac
    echo ""
done

