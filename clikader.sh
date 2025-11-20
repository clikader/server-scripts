#!/bin/bash

# Clikader - Interactive Server Management Script
# Master entrypoint for various server management tasks

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# GitHub raw URL base
GITHUB_RAW_BASE="https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/components"

# Script definitions
declare -A SCRIPTS
SCRIPTS["Reset APT Sources"]="reset_apt_source.sh"
SCRIPTS["Setup DNS"]="setup_dns.sh"
SCRIPTS["Fix Hostname"]="fix_hostname.sh"
SCRIPTS["Configure IPv6"]="configure_ipv6.sh"

# Order of menu items
MENU_ITEMS=(
    "Reset APT Sources"
    "Setup DNS"
    "Fix Hostname"
    "Configure IPv6"
)

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root" >&2
    exit 1
fi

# Function to clear screen and show header
show_header() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      CLIKADER - Server Manager        ║${NC}"
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo ""
}

# Function to display menu with arrow key navigation
display_menu() {
    local selected=$1
    
    show_header
    
    echo "Use ↑/↓ arrow keys to navigate, Enter to select, Q to quit"
    echo ""
    
    for i in "${!MENU_ITEMS[@]}"; do
        if [[ $i -eq $selected ]]; then
            echo -e "  ${GREEN}▶ ${MENU_ITEMS[$i]}${NC}"
        else
            echo -e "    ${MENU_ITEMS[$i]}"
        fi
    done
    
    echo ""
}

# Function to get user selection with arrow keys
get_selection() {
    local selected=0
    local menu_size=${#MENU_ITEMS[@]}
    
    # Hide cursor
    tput civis
    
    while true; do
        display_menu $selected
        
        # Read a key from the terminal
        # Use read with -d to read until a delimiter, but with timeout
        local key
        IFS= read -rsn1 key < /dev/tty
        
        # Handle different key inputs
        if [[ $key == $'\x1b' ]]; then
            # This is an escape sequence (arrow keys, etc.)
            # Read the next character
            IFS= read -rsn1 -t 0.01 key2 < /dev/tty
            if [[ $key2 == '[' ]]; then
                # Read the third character
                IFS= read -rsn1 -t 0.01 key3 < /dev/tty
                case "$key3" in
                    'A') # Up arrow
                        ((selected--))
                        if [[ $selected -lt 0 ]]; then
                            selected=$((menu_size - 1))
                        fi
                        ;;
                    'B') # Down arrow
                        ((selected++))
                        if [[ $selected -ge $menu_size ]]; then
                            selected=0
                        fi
                        ;;
                esac
            fi
        elif [[ $key == '' ]]; then
            # Enter key
            tput cnorm
            return $selected
        elif [[ $key == 'q' ]] || [[ $key == 'Q' ]]; then
            # Quit
            tput cnorm
            show_header
            echo "Exiting..."
            echo ""
            exit 0
        fi
    done
}


# Function to download and execute script
run_script() {
    local script_name="$1"
    local script_title="$2"
    local tmp_script="/tmp/${script_name}"
    
    show_header
    echo -e "${BLUE}Selected:${NC} ${BOLD}${script_title}${NC}"
    echo ""
    
    # Check if script exists locally first (in components folder)
    local script_dir="$(dirname "$(readlink -f "$0")")"
    local local_script="${script_dir}/components/${script_name}"
    
    if [[ -f "$local_script" ]]; then
        echo -e "${GREEN}→${NC} Found local script: ${local_script}"
        echo ""
        
        # Make it executable
        chmod +x "$local_script"
        
        # Execute the script
        if bash "$local_script"; then
            echo ""
            echo -e "${GREEN}✅ Script completed successfully${NC}"
        else
            echo ""
            echo -e "${RED}❌ Script encountered an error${NC}"
        fi
    else
        # Download from GitHub
        echo -e "${YELLOW}→${NC} Local script not found, downloading from GitHub..."
        echo -e "${BLUE}→${NC} URL: ${GITHUB_RAW_BASE}/${script_name}"
        echo ""
        
        if curl -fsSL "${GITHUB_RAW_BASE}/${script_name}" -o "$tmp_script"; then
            echo -e "${GREEN}✅ Downloaded successfully${NC}"
            echo ""
            
            # Make it executable
            chmod +x "$tmp_script"
            
            # Execute the script
            if bash "$tmp_script"; then
                echo ""
                echo -e "${GREEN}✅ Script completed successfully${NC}"
            else
                echo ""
                echo -e "${RED}❌ Script encountered an error${NC}"
            fi
            
            # Clean up
            rm -f "$tmp_script"
        else
            echo ""
            echo -e "${RED}❌ Failed to download script from GitHub${NC}"
            echo -e "${YELLOW}Please check your internet connection and try again${NC}"
        fi
    fi
    
    echo ""
    echo "Press any key to return to menu..."
    read -rsn1
}

# Main menu loop
main() {
    while true; do
        get_selection
        local selected=$?
        
        local selected_title="${MENU_ITEMS[$selected]}"
        local selected_script="${SCRIPTS[$selected_title]}"
        
        run_script "$selected_script" "$selected_title"
    done
}

main "$@"
