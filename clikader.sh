#!/bin/bash

# Clikader - Interactive Server Management Script
# Master entrypoint for various server management tasks

set -euo pipefail

# Version
CLIKADER_VERSION="1.0.8"

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
    "Update CLiKader"
    "Uninstall CLiKader"
)

# Logging functions
log() {
    echo -e "${GREEN}→${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root" >&2
    exit 1
fi

# Function to show header
show_header() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      CLIKADER - Server Manager        ║${NC}"
    echo -e "${CYAN}${BOLD}║             v${CLIKADER_VERSION}                      ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to display menu
display_menu() {
    show_header >&2
    
    for i in "${!MENU_ITEMS[@]}"; do
        echo "  $((i+1))) ${MENU_ITEMS[$i]}" >&2
    done
    
    echo "  0) Exit" >&2
    echo "" >&2
}

# Function to get user selection
get_selection() {
    while true; do
        display_menu
        
        echo -n "Enter your choice [0-${#MENU_ITEMS[@]}]: " >&2
        read -r choice < /dev/tty
        
        # Trim whitespace
        choice=$(echo "$choice" | xargs)
        
        # Check for empty input
        if [[ -z "$choice" ]]; then
            echo "Invalid input. Please enter a number." >&2
            sleep 2
            continue
        fi
        
        # Validate input is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo "Invalid input. Please enter a number." >&2
            sleep 2
            continue
        fi
        
        # Check if exit
        if [[ "$choice" == "0" ]]; then
            echo "" >&2
            echo "Exiting..." >&2
            exit 0
        fi
        
        # Check if valid menu option
        if [[ $choice -ge 1 ]] && [[ $choice -le ${#MENU_ITEMS[@]} ]]; then
            echo $((choice - 1))
            return 0
        else
            echo "Invalid choice. Please try again." >&2
            sleep 2
        fi
    done
}

# Update CLiKader function
update_clikader() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      Update CLiKader                  ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}Current version:${NC} ${BOLD}${CLIKADER_VERSION}${NC}"
    echo ""
    
    # Check if installed or running from local file
    local install_path=""
    if command -v clikader &> /dev/null; then
        install_path=$(command -v clikader)
        echo -e "${GREEN}→${NC} CLiKader is installed at: ${install_path}"
    else
        echo -e "${YELLOW}→${NC} CLiKader is not installed (running from local file)"
        echo ""
        echo "To install CLiKader system-wide, run:"
        echo -e "  ${BLUE}curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash${NC}"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo ""
    echo -e "${BLUE}→${NC} Checking for updates..."
    
    # Download latest version to temp file
    local tmp_file="/tmp/clikader_latest.sh"
    if ! curl -fsSL "${GITHUB_RAW_BASE%/components}/clikader.sh" -o "$tmp_file" 2>/dev/null; then
        echo -e "${RED}❌ Failed to check for updates${NC}"
        echo "Please check your internet connection"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    # Extract version from downloaded file
    local remote_version=$(grep '^CLIKADER_VERSION=' "$tmp_file" | head -n1 | cut -d'"' -f2)
    
    if [[ -z "$remote_version" ]]; then
        echo -e "${RED}❌ Could not determine remote version${NC}"
        rm -f "$tmp_file"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo -e "${BLUE}Latest version:${NC} ${BOLD}${remote_version}${NC}"
    echo ""
    
    # Compare versions
    if [[ "$CLIKADER_VERSION" == "$remote_version" ]]; then
        echo -e "${GREEN}✅ CLiKader is up to date!${NC}"
        rm -f "$tmp_file"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    # Update available
    echo -e "${YELLOW}→${NC} Update available: ${CLIKADER_VERSION} → ${remote_version}"
    echo ""
    echo -n "Do you want to update CLiKader? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Update cancelled"
        rm -f "$tmp_file"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo ""
    echo -e "${BLUE}→${NC} Installing update..."
    
    # Backup current version
    cp "$install_path" "${install_path}.backup"
    
    # Install new version
    if mv "$tmp_file" "$install_path" && chmod +x "$install_path"; then
        echo -e "${GREEN}✅ CLiKader updated successfully!${NC}"
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Updated to version ${remote_version}           ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo "Backup saved to: ${install_path}.backup"
        echo ""
        echo "Please restart CLiKader to use the new version"
        echo ""
        echo -n "Exit now? (Y/n): "
        read -r exit_confirm < /dev/tty
        
        if [[ ! "$exit_confirm" =~ ^[Nn]$ ]]; then
            echo ""
            echo "Exiting... Please run 'sudo clikader' again"
            exit 0
        fi
    else
        echo -e "${RED}❌ Update failed${NC}"
        echo "Restoring backup..."
        mv "${install_path}.backup" "$install_path"
        rm -f "$tmp_file"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo ""
    echo "Press any key to return to menu..."
    read -rsn1 < /dev/tty
}

# Uninstall CLiKader function
uninstall_clikader() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      Uninstall CLiKader               ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check if installed
    local install_path=""
    if command -v clikader &> /dev/null; then
        install_path=$(command -v clikader)
        echo -e "${BLUE}→${NC} CLiKader is installed at: ${install_path}"
    else
        echo -e "${YELLOW}→${NC} CLiKader is not installed"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo ""
    warning "This will remove CLiKader from your system"
    echo ""
    echo "The following will be removed:"
    echo "  • $install_path"
    if [[ -f "${install_path}.backup" ]]; then
        echo "  • ${install_path}.backup"
    fi
    echo ""
    echo -n "Are you sure you want to uninstall CLiKader? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Uninstall cancelled"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    echo ""
    echo -e "${BLUE}→${NC} Uninstalling CLiKader..."
    
    # Remove main file
    if rm -f "$install_path"; then
        echo -e "${GREEN}✅${NC} Removed $install_path"
    else
        error "Failed to remove $install_path"
        echo ""
        echo "Press any key to return to menu..."
        read -rsn1 < /dev/tty
        return
    fi
    
    # Remove backup if exists
    if [[ -f "${install_path}.backup" ]]; then
        rm -f "${install_path}.backup"
        echo -e "${GREEN}✅${NC} Removed backup file"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   CLiKader uninstalled successfully!  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "CLiKader has been removed from your system."
    echo ""
    info "To clear the command from your shell cache, run:"
    echo -e "  ${BLUE}hash -d clikader${NC}"
    echo ""
    echo "Or simply start a new shell session."
    echo ""
    echo "To reinstall, run:"
    echo -e "  ${BLUE}curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash${NC}"
    echo ""
    echo -n "Press any key to exit..."
    read -rsn1 < /dev/tty
    
    echo ""
    echo "Goodbye!"
    exit 0
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
    read -rsn1 < /dev/tty
}

# Main menu loop
main() {
    while true; do
        local selected=$(get_selection)
        local selected_title="${MENU_ITEMS[$selected]}"
        
        # Handle special menu items
        if [[ "$selected_title" == "Update CLiKader" ]]; then
            update_clikader
        elif [[ "$selected_title" == "Uninstall CLiKader" ]]; then
            uninstall_clikader
        else
            local selected_script="${SCRIPTS[$selected_title]}"
            run_script "$selected_script" "$selected_title"
        fi
    done
}

main "$@"
