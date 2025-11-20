#!/bin/bash

# Hostname Fix Script - Fixes hostname resolution and allows hostname changes
# Supports: Debian 11/12/13, Ubuntu 20.04/22.04/24.04/24.10

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}-->${NC} $1"
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
    error "This script must be run as root"
    exit 1
fi

# Get current hostname
get_current_hostname() {
    hostname
}

# Check if hostname resolves
check_hostname_resolution() {
    local current_hostname=$(get_current_hostname)
    
    echo ""
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    echo ""
    
    # Check if hostname resolves
    if getent hosts "$current_hostname" > /dev/null 2>&1; then
        local resolved_ip=$(getent hosts "$current_hostname" | awk '{print $1}')
        log "✅ Hostname resolves to: $resolved_ip"
        
        if [[ "$resolved_ip" == "127.0.0.1" ]] || [[ "$resolved_ip" == "127.0.1.1" ]] || [[ "$resolved_ip" == "::1" ]]; then
            log "✅ Hostname correctly resolves to localhost"
            return 0
        else
            warning "Hostname resolves to $resolved_ip (not localhost)"
            return 1
        fi
    else
        warning "❌ Hostname does NOT resolve"
        return 1
    fi
}

# Fix hostname resolution
fix_hostname_resolution() {
    local current_hostname=$(get_current_hostname)
    
    echo ""
    echo "=========================================="
    echo "  Fix Hostname Resolution"
    echo "=========================================="
    echo ""
    
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    
    # Backup /etc/hosts
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp /etc/hosts "/etc/hosts.backup_${timestamp}"
    log "✅ Backed up /etc/hosts to /etc/hosts.backup_${timestamp}"
    
    # Check if hostname is already in /etc/hosts
    if grep -qE "^127\.0\.(0\.1|1\.1)[[:space:]]+.*${current_hostname}" /etc/hosts; then
        log "Hostname entry already exists in /etc/hosts, updating..."
        # Remove existing entries
        sed -i "/[[:space:]]${current_hostname}[[:space:]]*$/d" /etc/hosts
        sed -i "/[[:space:]]${current_hostname}\$/d" /etc/hosts
    fi
    
    # Add hostname to /etc/hosts
    # Check if 127.0.1.1 line exists
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        # Update existing 127.0.1.1 line
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${current_hostname}/" /etc/hosts
        log "✅ Updated 127.0.1.1 entry with hostname: ${current_hostname}"
    else
        # Add new 127.0.1.1 line after 127.0.0.1
        sed -i "/^127\.0\.0\.1/a 127.0.1.1\t${current_hostname}" /etc/hosts
        log "✅ Added new entry: 127.0.1.1 ${current_hostname}"
    fi
    
    echo ""
    log "Current /etc/hosts content:"
    echo ""
    cat /etc/hosts
    echo ""
    
    # Verify resolution
    if getent hosts "$current_hostname" > /dev/null 2>&1; then
        local resolved_ip=$(getent hosts "$current_hostname" | awk '{print $1}')
        log "✅ Hostname now resolves to: $resolved_ip"
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Hostname resolution fixed successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        return 0
    else
        error "Failed to fix hostname resolution"
        return 1
    fi
}

# Change hostname
change_hostname() {
    local current_hostname=$(get_current_hostname)
    local new_hostname=""
    
    echo ""
    echo "=========================================="
    echo "  Change Hostname"
    echo "=========================================="
    echo ""
    
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    echo ""
    
    # Hostname validation regex (RFC 1123)
    local hostname_regex='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
    
    while true; do
        echo -n "Enter new hostname (lowercase, alphanumeric, hyphens allowed): "
        read -r new_hostname < /dev/tty
        
        # Convert to lowercase
        new_hostname=$(echo "$new_hostname" | tr '[:upper:]' '[:lower:]')
        
        # Validate hostname
        if [[ -z "$new_hostname" ]]; then
            error "Hostname cannot be empty"
            continue
        fi
        
        if [[ ! "$new_hostname" =~ $hostname_regex ]]; then
            error "Invalid hostname format"
            echo "Hostname must:"
            echo "  - Start and end with alphanumeric character"
            echo "  - Contain only lowercase letters, numbers, and hyphens"
            echo "  - Not start or end with a hyphen"
            continue
        fi
        
        if [[ ${#new_hostname} -gt 63 ]]; then
            error "Hostname too long (max 63 characters)"
            continue
        fi
        
        # Valid hostname
        break
    done
    
    echo ""
    log "New hostname will be: ${BOLD}${new_hostname}${NC}"
    echo ""
    echo -n "Confirm hostname change? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "Hostname change cancelled"
        return 1
    fi
    
    echo ""
    log "Changing hostname..."
    
    # Set hostname using hostnamectl (systemd)
    if command -v hostnamectl &> /dev/null; then
        hostnamectl set-hostname "$new_hostname"
        log "✅ Set hostname using hostnamectl"
    else
        # Fallback for systems without systemd
        echo "$new_hostname" > /etc/hostname
        hostname "$new_hostname"
        log "✅ Updated /etc/hostname and current hostname"
    fi
    
    # Update /etc/hosts
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp /etc/hosts "/etc/hosts.backup_${timestamp}"
    log "✅ Backed up /etc/hosts"
    
    # Remove old hostname entries
    sed -i "/[[:space:]]${current_hostname}[[:space:]]*$/d" /etc/hosts
    sed -i "/[[:space:]]${current_hostname}\$/d" /etc/hosts
    
    # Add new hostname to /etc/hosts
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new_hostname}/" /etc/hosts
    else
        sed -i "/^127\.0\.0\.1/a 127.0.1.1\t${new_hostname}" /etc/hosts
    fi
    
    log "✅ Updated /etc/hosts with new hostname"
    
    echo ""
    log "Verifying hostname change..."
    
    local verify_hostname=$(get_current_hostname)
    if [[ "$verify_hostname" == "$new_hostname" ]]; then
        log "✅ Hostname verified: $verify_hostname"
    else
        warning "Hostname verification mismatch (this may require a reboot)"
    fi
    
    # Check resolution
    if getent hosts "$new_hostname" > /dev/null 2>&1; then
        local resolved_ip=$(getent hosts "$new_hostname" | awk '{print $1}')
        log "✅ New hostname resolves to: $resolved_ip"
    fi
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Hostname changed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Old hostname: $current_hostname"
    echo "New hostname: $new_hostname"
    echo ""
    info "Note: Some services may require restart to recognize the new hostname"
    info "You may need to reconnect your SSH session"
    echo ""
}

# Display interactive menu
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      Hostname Management Tool         ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    check_hostname_resolution || true
    
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Fix hostname resolution (add to /etc/hosts)"
    echo "  2) Change hostname"
    echo "  0) Exit"
    echo ""
}

# Main menu loop
main() {
    while true; do
        show_menu
        
        echo -n "Enter your choice [0-2]: "
        read -r choice < /dev/tty
        
        case "$choice" in
            1)
                fix_hostname_resolution
                echo ""
                echo "Press any key to continue..."
                read -rsn1 < /dev/tty
                ;;
            2)
                change_hostname
                echo ""
                echo "Press any key to continue..."
                read -rsn1 < /dev/tty
                ;;
            0)
                echo ""
                log "Exiting..."
                echo ""
                exit 0
                ;;
            *)
                error "Invalid choice. Please enter 0, 1, or 2."
                sleep 2
                ;;
        esac
    done
}

main "$@"
