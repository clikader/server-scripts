#!/bin/bash

# DNS Setup Script - Purifies and hardens DNS configuration
# Supports: Debian 11/12/13, Ubuntu 20.04/22.04/24.04

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# Secure resolved.conf configuration
SECURE_RESOLVED_CONFIG="[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=8.8.8.8 8.8.4.4 2001:4860:4860::8888 2001:4860:4860::8844
Domains=~.
DNSSEC=yes
DNSOverTLS=opportunistic
Cache=yes
CacheFromLocalhost=no
DNSStubListener=yes
DNSStubListenerExtra=127.0.0.53
ReadEtcHosts=yes
ResolveUnicastSingleLabel=no"

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
    
    # Remove resolvconf on Debian 11 if present
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null 2>&1; then
        log "Detected 'resolvconf' on Debian 11, uninstalling..."
        apt-get remove -y resolvconf > /dev/null 2>&1
        rm -f /etc/resolv.conf
        log "✅ 'resolvconf' successfully uninstalled"
    fi
    
    log "Enabling and starting systemd-resolved service..."
    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null
    systemctl start systemd-resolved 2>/dev/null
    
    log "Applying final DNS security configuration (DoT, DNSSEC...)"
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
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
        exit 0
    fi
    
    purify_dns
    verify_dns
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}DNS setup completed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Your system is now using:"
    echo "  • Primary DNS: Cloudflare (1.1.1.1, 1.0.0.1)"
    echo "  • Fallback DNS: Google (8.8.8.8, 8.8.4.4)"
    echo "  • Features: DNSSEC, DNS-over-TLS (opportunistic)"
    echo ""
}

main "$@"
