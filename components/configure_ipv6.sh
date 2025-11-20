#!/bin/bash

# IPv6 Configuration Script - Enable or disable IPv6 on Debian/Ubuntu systems
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

# Configuration file path
SYSCTL_CONFIG="/etc/sysctl.d/99-disable-ipv6.conf"

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

# Detect OS version
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="$ID"
    os_version="$VERSION_ID"
else
    error "Cannot detect OS version"
    exit 1
fi

log "Detected: $ID $VERSION_ID"

# Check current IPv6 status
check_ipv6_status() {
    local ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    
    echo ""
    log "Current IPv6 Status:"
    
    if [[ "$ipv6_disabled" == "1" ]]; then
        echo -e "  Status: ${RED}DISABLED${NC}"
        
        if [[ -f "$SYSCTL_CONFIG" ]]; then
            info "Configuration file exists: $SYSCTL_CONFIG"
        fi
        
        return 1
    else
        echo -e "  Status: ${GREEN}ENABLED${NC}"
        
        # Show IPv6 addresses if enabled
        local ipv6_addrs=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+' | head -n 3)
        if [[ -n "$ipv6_addrs" ]]; then
            echo ""
            info "IPv6 addresses detected:"
            echo "$ipv6_addrs" | while read -r addr; do
                echo "    $addr"
            done
        fi
        
        return 0
    fi
}

# Enable IPv6
enable_ipv6() {
    echo ""
    echo "=========================================="
    echo "  Enable IPv6"
    echo "=========================================="
    echo ""
    
    # Remove sysctl configuration file if it exists
    if [[ -f "$SYSCTL_CONFIG" ]]; then
        log "Removing IPv6 disable configuration..."
        rm -f "$SYSCTL_CONFIG"
        log "✅ Removed $SYSCTL_CONFIG"
    else
        info "IPv6 disable configuration not found (already removed or never created)"
    fi
    
    # Enable IPv6 immediately
    log "Enabling IPv6 on all interfaces..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
    
    log "✅ IPv6 enabled on all interfaces"
    
    # Also remove any conflicting legacy configurations
    if [[ -f /etc/sysctl.conf ]]; then
        if grep -q "disable_ipv6" /etc/sysctl.conf; then
            log "Removing IPv6 disable entries from /etc/sysctl.conf..."
            sed -i '/disable_ipv6/d' /etc/sysctl.conf
            log "✅ Cleaned /etc/sysctl.conf"
        fi
    fi
    
    # Reload networking to get IPv6 addresses (non-blocking)
    log "Reloading network configuration..."
    if systemctl is-active --quiet networking 2>/dev/null; then
        systemctl restart networking >/dev/null 2>&1 || true
    fi
    
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl restart NetworkManager >/dev/null 2>&1 || true
    fi
    
    # Wait a moment for IPv6 addresses to be assigned
    sleep 2
    
    echo ""
    log "Verifying IPv6 status..."
    
    local ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
    
    if [[ "$ipv6_disabled" == "0" ]]; then
        log "✅ IPv6 is now enabled"
        
        echo ""
        log "Testing IPv6 connectivity..."
        
        # Try to get IPv6 addresses
        local ipv6_addrs=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+' | head -n 3)
        
        if [[ -n "$ipv6_addrs" ]]; then
            log "✅ IPv6 addresses detected:"
            echo "$ipv6_addrs" | while read -r addr; do
                echo "    $addr"
            done
        else
            warning "No global IPv6 addresses detected yet"
            info "This is normal if your network doesn't provide IPv6"
            info "Or addresses may take a few moments to be assigned via SLAAC/DHCPv6"
        fi
        
        # Test IPv6 DNS resolution
        if ping6 -c 1 -W 2 google.com >/dev/null 2>&1; then
            log "✅ IPv6 internet connectivity working"
        else
            info "IPv6 internet connectivity test failed (may not have IPv6 upstream)"
        fi
        
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}IPv6 enabled successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        info "Configuration is persistent across reboots"
        
    else
        error "Failed to enable IPv6"
        return 1
    fi
}

# Configure IPv6 address manually
configure_ipv6_address() {
    echo ""
    echo "=========================================="
    echo "  Configure IPv6 Address"
    echo "=========================================="
    echo ""
    
    # List available network interfaces
    log "Available network interfaces:"
    echo ""
    
    # Get list of interfaces (excluding loopback)
    local interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '@')
    local iface_array=()
    
    if [[ -z "$interfaces" ]]; then
        error "No network interfaces found"
        return 1
    fi
    
    # Display interfaces with current IPv6 addresses
    local index=1
    while IFS= read -r iface; do
        iface_array+=("$iface")
        local ipv6_addrs=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+/\d+' || echo "none")
        echo "  $index) $iface"
        if [[ "$ipv6_addrs" != "none" ]]; then
            echo "     Current IPv6: $ipv6_addrs"
        else
            echo "     Current IPv6: No global IPv6 address"
        fi
        ((index++))
    done <<< "$interfaces"
    
    echo ""
    echo -n "Select interface number (1-${#iface_array[@]}): "
    read -r iface_choice < /dev/tty
    
    # Validate interface choice
    if ! [[ "$iface_choice" =~ ^[0-9]+$ ]] || [[ "$iface_choice" -lt 1 ]] || [[ "$iface_choice" -gt "${#iface_array[@]}" ]]; then
        error "Invalid interface selection"
        return 1
    fi
    
    local selected_iface="${iface_array[$((iface_choice-1))]}"
    
    echo ""
    log "Selected interface: ${BOLD}${selected_iface}${NC}"
    
    # Check if interface already has IPv6 addresses
    local existing_ipv6=$(ip -6 addr show dev "$selected_iface" scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+/\d+')
    
    if [[ -n "$existing_ipv6" ]]; then
        echo ""
        warning "This interface already has IPv6 address(es) configured:"
        echo ""
        echo "$existing_ipv6" | while read -r addr; do
            echo "  • $addr"
        done
        echo ""
        info "You can add additional addresses from your allocated prefix"
        echo ""
        echo -n "Do you want to continue and ADD another IPv6 address? (y/N): "
        read -r continue_confirm < /dev/tty
        
        if [[ ! "$continue_confirm" =~ ^[Yy]$ ]]; then
            warning "Configuration cancelled"
            return 0
        fi
    fi
    
    echo ""
    
    # Get IPv6 address from user
    echo "Enter the IPv6 address to ADD (with or without CIDR prefix):"
    echo ""
    echo "  Examples:"
    echo "    - 2001:db8::1/64"
    echo "    - 2001:db8::1 (will default to /64)"
    echo ""
    echo "  Common VPS scenarios:"
    echo "    - Provider gives you a single address: 2001:db8:a1b2::1/64"
    echo "    - Provider gives you a prefix: 2001:db8:a1b2::/48 or /56"
    echo "      → You can add any address from that prefix"
    echo ""
    echo -n "IPv6 address to add: "
    read -r ipv6_input < /dev/tty
    
    if [[ -z "$ipv6_input" ]]; then
        error "IPv6 address cannot be empty"
        return 1
    fi
    
    # Parse IPv6 address and prefix
    local ipv6_addr=""
    local ipv6_prefix="64"
    
    if [[ "$ipv6_input" =~ / ]]; then
        # Contains CIDR notation
        ipv6_addr="${ipv6_input%/*}"
        ipv6_prefix="${ipv6_input##*/}"
    else
        # No CIDR notation, use default /64
        ipv6_addr="$ipv6_input"
    fi
    
    # Basic IPv6 validation (simplified)
    if ! [[ "$ipv6_addr" =~ ^[0-9a-fA-F:]+$ ]]; then
        error "Invalid IPv6 address format"
        return 1
    fi
    
    # Validate prefix length
    if ! [[ "$ipv6_prefix" =~ ^[0-9]+$ ]] || [[ "$ipv6_prefix" -lt 1 ]] || [[ "$ipv6_prefix" -gt 128 ]]; then
        error "Invalid IPv6 prefix length (must be 1-128)"
        return 1
    fi
    
    local full_ipv6="${ipv6_addr}/${ipv6_prefix}"
    
    echo ""
    log "Will ADD address: ${BOLD}${full_ipv6}${NC} to ${BOLD}${selected_iface}${NC}"
    
    if [[ -n "$existing_ipv6" ]]; then
        info "Existing addresses will be kept (not replaced)"
    fi
    
    echo ""
    echo -n "Proceed with adding this address? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "Configuration cancelled"
        return 1
    fi
    
    echo ""
    log "Adding IPv6 address to interface..."
    
    # Add the IPv6 address temporarily
    if ip -6 addr add "$full_ipv6" dev "$selected_iface" 2>/dev/null; then
        log "✅ IPv6 address added to $selected_iface"
    else
        # Check if address already exists
        if ip -6 addr show dev "$selected_iface" | grep -q "$ipv6_addr"; then
            warning "This exact IPv6 address already exists on this interface"
            info "No changes were made"
        else
            error "Failed to add IPv6 address"
            info "This could be due to invalid address or network configuration issues"
            return 1
        fi
    fi
    
    # Make configuration persistent
    log "Making configuration persistent..."
    
    # Detect the network configuration system
    local config_method=""
    
    if [[ -d /etc/netplan ]] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        config_method="netplan"
    elif [[ -f /etc/network/interfaces ]]; then
        config_method="interfaces"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        config_method="networkmanager"
    else
        warning "Could not detect network configuration method"
        config_method="manual"
    fi
    
    echo ""
    info "Detected network configuration: $config_method"
    
    case "$config_method" in
        netplan)
            warning "Netplan detected. You need to manually edit your netplan configuration."
            echo ""
            echo "Add the following to your netplan config (e.g., /etc/netplan/01-netcfg.yaml):"
            echo ""
            echo "network:"
            echo "  version: 2"
            echo "  ethernets:"
            echo "    ${selected_iface}:"
            echo "      addresses:"
            echo "        - ${full_ipv6}"
            echo ""
            echo "Then run: sudo netplan apply"
            ;;
        interfaces)
            local iface_config="/etc/network/interfaces"
            log "Adding configuration to $iface_config..."
            
            # Check if interface section exists
            if grep -q "^iface $selected_iface inet6" "$iface_config"; then
                warning "IPv6 configuration for $selected_iface already exists in $iface_config"
                info "Please manually edit $iface_config to add: up ip -6 addr add ${full_ipv6} dev ${selected_iface}"
            else
                # Backup the file
                cp "$iface_config" "${iface_config}.backup_$(date +%Y%m%d_%H%M%S)"
                
                # Add IPv6 configuration
                cat >> "$iface_config" << EOF

# IPv6 configuration for ${selected_iface} - added by configure_ipv6.sh
iface ${selected_iface} inet6 static
    address ${full_ipv6}
EOF
                log "✅ Configuration added to $iface_config"
            fi
            ;;
        networkmanager)
            warning "NetworkManager detected. Configuration may not persist."
            info "To make it persistent with NetworkManager, use:"
            echo "  nmcli con modify <connection-name> +ipv6.addresses ${full_ipv6}"
            ;;
        manual)
            warning "Manual configuration required for persistence."
            info "Current configuration is active but may not survive reboot."
            echo ""
            echo "To make it persistent, add this command to /etc/rc.local or create a systemd service:"
            echo "  ip -6 addr add ${full_ipv6} dev ${selected_iface}"
            ;;
    esac
    
    echo ""
    log "Verifying configuration..."
    
    # Verify the address is configured
    if ip -6 addr show dev "$selected_iface" | grep -q "$ipv6_addr"; then
        log "✅ IPv6 address is configured on $selected_iface"
        
        echo ""
        log "All IPv6 addresses on $selected_iface:"
        ip -6 addr show dev "$selected_iface" scope global | grep inet6 | awk '{print "  " $2}'
        
        # Highlight the newly added address
        if [[ -n "$existing_ipv6" ]]; then
            echo ""
            info "The address ${full_ipv6} has been added to your existing addresses"
        fi
        
        echo ""
        log "Testing IPv6 connectivity..."
        if ping6 -c 1 -W 2 -I "$selected_iface" ff02::1 >/dev/null 2>&1; then
            log "✅ IPv6 link-local connectivity working"
        fi
        
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}IPv6 address added successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        
        if [[ "$config_method" != "interfaces" ]]; then
            warning "Remember to make the configuration persistent as shown above"
        fi
        
    else
        error "Failed to verify IPv6 address configuration"
        return 1
    fi
}

# Disable IPv6
disable_ipv6() {
    echo ""
    echo "=========================================="
    echo "  Disable IPv6"
    echo "=========================================="
    echo ""
    
    warning "Disabling IPv6 may affect some applications"
    echo ""
    echo "Services that may be affected:"
    echo "  • SSH (if listening on IPv6)"
    echo "  • Web servers (if configured for IPv6)"
    echo "  • Some VPN clients"
    echo ""
    echo -n "Are you sure you want to disable IPv6? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "IPv6 disable cancelled"
        return 1
    fi
    
    echo ""
    log "Creating IPv6 disable configuration..."
    
    # Create sysctl configuration
    cat > "$SYSCTL_CONFIG" << 'EOF'
# Disable IPv6 on all interfaces
# Created by configure_ipv6.sh

net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
    
    log "✅ Created $SYSCTL_CONFIG"
    
    # Apply configuration immediately
    log "Applying IPv6 disable configuration..."
    sysctl -p "$SYSCTL_CONFIG" >/dev/null 2>&1
    
    log "✅ IPv6 disabled on all interfaces"
    
    echo ""
    log "Verifying IPv6 status..."
    
    local ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
    
    if [[ "$ipv6_disabled" == "1" ]]; then
        log "✅ IPv6 is now disabled"
        
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}IPv6 disabled successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        info "Configuration is persistent across reboots"
        info "To re-enable IPv6, run this script again and choose 'Enable'"
        
    else
        error "Failed to disable IPv6"
        return 1
    fi
}

# Display interactive menu
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      IPv6 Configuration Tool          ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    
    check_ipv6_status
    
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Enable IPv6"
    echo "  2) Disable IPv6"
    echo "  3) Configure IPv6 address"
    echo "  4) Check status only"
    echo "  0) Exit"
    echo ""
}

# Main menu loop
main() {
    while true; do
        show_menu
        
        echo -n "Enter your choice [0-4]: "
        read -r choice < /dev/tty
        
        case "$choice" in
            1)
                enable_ipv6
                echo ""
                echo "Press any key to continue..."
                read -rsn1 < /dev/tty
                ;;
            2)
                disable_ipv6
                echo ""
                echo "Press any key to continue..."
                read -rsn1 < /dev/tty
                ;;
            3)
                configure_ipv6_address
                echo ""
                echo "Press any key to continue..."
                read -rsn1 < /dev/tty
                ;;
            4)
                echo ""
                log "Detailed IPv6 status:"
                echo ""
                sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6
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
                error "Invalid choice. Please enter 0-4."
                sleep 2
                ;;
        esac
    done
}

main "$@"
