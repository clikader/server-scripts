#!/bin/bash

# DNS Setup Script - Purifies and hardens DNS configuration with DNS-over-TLS
# Primarily supports: Debian 12/13, Ubuntu 22.04/24.04
# May work on: Debian 11, Ubuntu 20.04 (with limited testing)

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global variables for DNS configuration
primary_dns=""
fallback_dns=""
selected_names=()
ipv6_support=false
has_dot_support=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -6|--ipv6)
            ipv6_support=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Logging function
log() {
    echo -e "${GREEN}-->${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

unlock_resolv_conf() {
    if [[ -f /etc/resolv.conf ]]; then
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q '^....i'; then
            log "Detected locked /etc/resolv.conf, unlocking..."
            chattr -i /etc/resolv.conf 2>/dev/null || true
            log "✅ /etc/resolv.conf unlocked"
        fi
    fi
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

# Determine Debian version for compatibility
debian_version=""
if [[ "$os_name" == "debian" ]]; then
    debian_version="$os_version"
elif [[ "$os_name" == "ubuntu" ]]; then
    case "$os_version" in
        20.04) debian_version="10" ;;
        22.04) debian_version="11" ;;
        24.04) debian_version="12" ;;
        *) debian_version="12" ;;
    esac
fi

log "Detected: $ID $VERSION_ID (Debian compatibility: $debian_version)"

if [[ "$ipv6_support" == true ]]; then
    log "IPv6 support: ENABLED"
else
    log "IPv6 support: DISABLED (use -6 flag to enable)"
fi

get_custom_dns() {
    local custom_ipv4=""
    local custom_ipv6=""
    local custom_dot=""
    
    echo ""
    echo "=========================================="
    echo "  Custom DNS Configuration"
    echo "=========================================="
    echo ""
    echo "Enter your custom DNS server details:"
    echo ""
    
    # Get IPv4 DNS servers
    echo -n "IPv4 DNS servers (space-separated, e.g., '1.1.1.1 1.0.0.1'): "
    read -r custom_ipv4 < /dev/tty
    
    if [[ -z "$custom_ipv4" ]]; then
        error "IPv4 DNS servers are required for custom DNS"
        return 1
    fi
    
    # Get IPv6 DNS servers if IPv6 support is enabled
    if [[ "$ipv6_support" == true ]]; then
        echo -n "IPv6 DNS servers (space-separated, optional): "
        read -r custom_ipv6 < /dev/tty
    fi
    
    # Get DoT hostname
    echo -n "DNS-over-TLS hostname (e.g., 'dns.example.com', leave empty if not supported): "
    read -r custom_dot < /dev/tty
    
    # Build the DNS configuration
    local dns_config_ipv4=""
    local dns_config_ipv6=""

    for ip in $custom_ipv4; do
        if [[ -n "$custom_dot" ]]; then
            dns_config_ipv4+="$ip#$custom_dot "
        else
            dns_config_ipv4+="$ip "
        fi
    done

    for ip in $custom_ipv6; do
        if [[ -n "$custom_dot" ]]; then
            dns_config_ipv6+="$ip#$custom_dot "
        else
            dns_config_ipv6+="$ip "
        fi
    done

    # Set global flag for DoT support
    if [[ -z "$custom_dot" ]]; then
        has_dot_support=false
        log "Custom DNS configured without DNS-over-TLS support"
    else
        has_dot_support=true
    fi

    # Return the configuration via global variables
    dns_ipv4[7]="$dns_config_ipv4"
    dns_ipv6[7]="$dns_config_ipv6"
    dns_names[7]="Custom"

    log "Custom DNS configured successfully"
    echo ""
    return 0
}

select_dns_providers() {
    echo ""
    echo "=========================================="
    echo "  Select DNS Providers (DNS-over-TLS)"
    echo "=========================================="
    echo ""
    echo "Available DNS providers:"
    echo "  1) Cloudflare (1.1.1.1, 1.0.0.1) - DoT: cloudflare-dns.com"
    echo "  2) Google (8.8.8.8, 8.8.4.4) - DoT: dns.google"
    echo "  3) Quad9 (9.9.9.9, 149.112.112.112) - DoT: dns.quad9.net"
    echo "  4) OpenDNS (208.67.222.222, 208.67.220.220) - DoT: dns.opendns.com"
    echo "  5) AdGuard (94.140.14.14, 94.140.15.15) - DoT: dns.adguard.com"
    echo "  6) CleanBrowsing (185.228.168.9, 185.228.169.9) - DoT: family-filter-dns.cleanbrowsing.org"
    echo "  7) Custom DNS (define your own)"
    echo ""
    echo "Enter your choices separated by spaces (e.g., '1 2 3')"
    echo "The first choice will be your primary DNS provider."
    echo -n "Selection (default: 1 2 5): "
    
    read -r selections < /dev/tty
    
    if [[ -z "$selections" ]]; then
        selections="1 2 5"
        log "Using default selection: Cloudflare, Google, AdGuard"
    fi
    
    declare -A dns_ipv4
    declare -A dns_ipv6
    declare -A dns_names
    
    dns_ipv4[1]="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
    dns_ipv6[1]="2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
    dns_names[1]="Cloudflare"
    
    dns_ipv4[2]="8.8.8.8#dns.google 8.8.4.4#dns.google"
    dns_ipv6[2]="2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    dns_names[2]="Google"
    
    dns_ipv4[3]="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net"
    dns_ipv6[3]="2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"
    dns_names[3]="Quad9"
    
    dns_ipv4[4]="208.67.222.222#dns.opendns.com 208.67.220.220#dns.opendns.com"
    dns_ipv6[4]="2620:119:35::35#dns.opendns.com 2620:119:53::53#dns.opendns.com"
    dns_names[4]="OpenDNS"
    
    dns_ipv4[5]="94.140.14.14#dns.adguard.com 94.140.15.15#dns.adguard.com"
    dns_ipv6[5]="2a10:50c0::ad1:ff#dns.adguard.com 2a10:50c0::ad2:ff#dns.adguard.com"
    dns_names[5]="AdGuard"
    
    dns_ipv4[6]="185.228.168.9#family-filter-dns.cleanbrowsing.org 185.228.169.9#family-filter-dns.cleanbrowsing.org"
    dns_ipv6[6]="2a0d:2a00:1::#family-filter-dns.cleanbrowsing.org 2a0d:2a00:2::#family-filter-dns.cleanbrowsing.org"
    dns_names[6]="CleanBrowsing"
    
    # Check if custom DNS (option 7) is selected
    if echo "$selections" | grep -qw "7"; then
        if ! get_custom_dns; then
            error "Failed to configure custom DNS. Aborting."
            exit 1
        fi
    fi
    
    primary_dns=""
    fallback_dns=""
    selected_names=()
    
    local first=true
    for choice in $selections; do
        if [[ -n "${dns_ipv4[$choice]:-}" ]]; then
            if $first; then
                primary_dns="${dns_ipv4[$choice]}"
                if [[ "$ipv6_support" == true ]]; then
                    primary_dns+=" ${dns_ipv6[$choice]}"
                fi
                selected_names+=("${dns_names[$choice]}")
                first=false
            else
                fallback_dns+=" ${dns_ipv4[$choice]}"
                if [[ "$ipv6_support" == true ]]; then
                    fallback_dns+=" ${dns_ipv6[$choice]}"
                fi
                selected_names+=("${dns_names[$choice]}")
            fi
        fi
    done
    
    if [[ -z "$primary_dns" ]]; then
        warning "No valid selection made. Using default: Cloudflare, Google, AdGuard."
        primary_dns="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
        fallback_dns="8.8.8.8#dns.google 8.8.4.4#dns.google 94.140.14.14#dns.adguard.com 94.140.15.15#dns.adguard.com"
        
        if [[ "$ipv6_support" == true ]]; then
            primary_dns+=" 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
            fallback_dns+=" 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google 2a10:50c0::ad1:ff#dns.adguard.com 2a10:50c0::ad2:ff#dns.adguard.com"
        fi
        
        selected_names=("Cloudflare" "Google" "AdGuard")
    fi
    
    fallback_dns=$(echo "$fallback_dns" | xargs)
    
    echo ""
    log "Selected providers: ${selected_names[*]}"
    echo ""
}

generate_resolved_config() {
    local dot_setting="opportunistic"
    if [[ "$has_dot_support" == false ]]; then
        dot_setting="no"
    fi

    SECURE_RESOLVED_CONFIG="[Resolve]
DNS=$primary_dns
FallbackDNS=$fallback_dns
Domains=~.
DNSSEC=yes
DNSOverTLS=$dot_setting
Cache=yes
CacheFromLocalhost=no
DNSStubListener=yes
DNSStubListenerExtra=127.0.0.53
ReadEtcHosts=yes
ResolveUnicastSingleLabel=no"
}

# Health check function
health_check() {
    local all_passed=true
    
    echo ""
    echo "--- Starting comprehensive system DNS health check ---"
    
    # Check 1: systemd-resolved service
    echo -n "1. Checking systemd-resolved status... "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo -e "${GREEN}✓ Running${NC}"
    else
        echo -e "${RED}Service not running or unresponsive${NC}"
        all_passed=false
    fi
    
    # Check 2: dhclient.conf configuration
    echo -n "2. Checking dhclient.conf configuration... "
    if [[ -f /etc/dhcp/dhclient.conf ]] && \
       grep -q "^supersede domain-name-servers" /etc/dhcp/dhclient.conf && \
       grep -q "^prepend domain-name-servers" /etc/dhcp/dhclient.conf; then
        echo -e "${GREEN}✓ Properly configured${NC}"
    else
        echo -e "${YELLOW}'ignore' parameters not found${NC}"
        all_passed=false
    fi
    
    # Check 3: if-up.d conflict script
    echo -n "3. Checking if-up.d conflict script... "
    if [[ -x /etc/network/if-up.d/resolved ]]; then
        echo -e "${YELLOW}Script exists and is executable${NC}"
        all_passed=false
    else
        echo -e "${GREEN}✓ No conflicts${NC}"
    fi
    
    echo ""
    if [[ "$all_passed" == true ]]; then
        echo -e "${GREEN}==> All checks passed! DNS configuration is healthy.${NC}"
        return 0
    else
        echo -e "${YELLOW}--> One or more checks failed. Running full purification and hardening process...${NC}"
        echo ""
        return 1
    fi
}

# Main purification function
purify_dns() {
    echo "--- Starting DNS purification and hardening process ---"
    
    unlock_resolv_conf
    
    # Phase 1: Remove all conflict sources
    log "Phase 1: Removing all potential DNS conflict sources..."
    
    # Configure dhclient to ignore DHCP DNS
    log "Configuring DHCP client (dhclient)..."
    if [[ -f /etc/dhcp/dhclient.conf ]]; then
        # Remove any existing supersede/prepend lines
        sed -i '/^supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
        sed -i '/^prepend domain-name-servers/d' /etc/dhcp/dhclient.conf
        
        # Add our configuration
        cat >> /etc/dhcp/dhclient.conf << 'EOF'

# DNS override configuration - added by setup_dns.sh
supersede domain-name-servers 127.0.0.53;
prepend domain-name-servers 127.0.0.53;
EOF
        log "✅ Added 'ignore' directives to /etc/dhcp/dhclient.conf"
    fi
    
    # Disable the if-up.d resolved script
    log "Disabling conflicting if-up.d script..."
    if [[ -f /etc/network/if-up.d/resolved ]]; then
        chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
        log "✅ Removed execute permission from /etc/network/if-up.d/resolved"
    fi
    
    # Phase 2: Configure systemd-resolved
    log "Phase 2: Configuring systemd-resolved..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if ! command -v resolvectl &> /dev/null; then
        log "Installing systemd-resolved..."
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y systemd-resolved > /dev/null 2>&1
    fi
    
    # Remove resolvconf if present (common on older Debian/Ubuntu)
    if dpkg -s resolvconf &> /dev/null 2>&1; then
        log "Detected 'resolvconf' package, uninstalling..."
        apt-get remove -y resolvconf > /dev/null 2>&1
        rm -f /etc/resolv.conf
        log "✅ 'resolvconf' successfully uninstalled"
    fi
    
    log "Enabling and starting systemd-resolved service..."
    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null
    systemctl start systemd-resolved 2>/dev/null
    
    log "Applying final DNS security configuration (DoT, DNSSEC...)"
    generate_resolved_config
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    unlock_resolv_conf
    rm -f /etc/resolv.conf 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 2
    
    log "✅ DNS purification and hardening complete!"
    echo ""
}

# Verification function
verify_dns() {
    echo "--- Verifying DNS configuration ---"
    
    if systemctl is-active --quiet systemd-resolved; then
        log "✅ systemd-resolved is active"
    else
        error "systemd-resolved is not running"
        return 1
    fi
    
    if resolvectl status >/dev/null 2>&1; then
        log "✅ resolvectl is working"
        echo ""
        resolvectl status | grep -A 5 "DNS Servers"
    else
        warning "resolvectl status check failed"
    fi
    
    echo ""
    log "Testing DNS resolution..."
    if nslookup google.com >/dev/null 2>&1; then
        log "✅ DNS resolution is working"
    else
        warning "DNS resolution test failed"
    fi
    
    echo ""
    log "Current /etc/resolv.conf:"
    cat /etc/resolv.conf
    echo ""
}

# Main execution
main() {
    if health_check; then
        echo "No action needed. System is already properly configured."
        echo ""
        echo -n "Do you want to force rerun the DNS configuration anyway? (Y/n): "
        read -r force_rerun < /dev/tty
        
        if [[ "$force_rerun" =~ ^[Nn]$ ]]; then
            echo "Exiting without changes."
            exit 0
        fi
        
        echo ""
        log "Forcing DNS reconfiguration as requested..."
    fi
    
    select_dns_providers
    purify_dns
    verify_dns
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}DNS setup completed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Your system is now using:"
    for name in "${selected_names[@]}"; do
        if [[ "$has_dot_support" == true ]]; then
            echo "  • $name DNS (DNS-over-TLS)"
        else
            echo "  • $name DNS"
        fi
    done
    echo ""
    echo "Security features enabled:"
    echo "  • DNSSEC: Yes"
    if [[ "$has_dot_support" == true ]]; then
        echo "  • DNS-over-TLS: Opportunistic"
    else
        echo "  • DNS-over-TLS: Disabled (custom DNS without DoT support)"
    fi
    if [[ "$ipv6_support" == true ]]; then
        echo "  • IPv6 support: Enabled"
    else
        echo "  • IPv6 support: Disabled (use -6 flag to enable)"
    fi
    echo ""
}

main "$@"
