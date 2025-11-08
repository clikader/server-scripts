#!/usr/bin/env bash
set -euo pipefail

readonly TARGET_DNS="1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google"
readonly SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}
LLMNR=no
MulticastDNS=no
DNSSEC=allow-downgrade
DNSOverTLS=yes
"

readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m"

log() { echo -e "${GREEN}--> $1${NC}"; }
log_warn() { echo -e "${YELLOW}--> $1${NC}"; }
log_error() { echo -e "${RED}--> $1${NC}" >&2; }

purify_and_harden_dns() {
    echo -e "\n--- Starting DNS purification and hardening process ---"
    
    local debian_version
    debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "unknown")
    
    log "Phase 1: Removing all potential DNS conflict sources..."
    
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf" || ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            log "Configuring DHCP client (dhclient)..."
            echo "" >> "$dhclient_conf"
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            echo "ignore domain-search;" >> "$dhclient_conf"
            log "✅ Added 'ignore' directives to ${dhclient_conf}"
        fi
    fi
    
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -f "$ifup_script" ]] && [[ -x "$ifup_script" ]]; then
        log "Disabling conflicting if-up.d script..."
        chmod -x "$ifup_script"
        log "✅ Removed execute permission from ${ifup_script}"
    fi
    
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]] && grep -qE '^[[:space:]]*(dns-(nameservers|search|domain))' "$interfaces_file"; then
        log "Purifying /etc/network/interfaces DNS configuration..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "✅ Legacy DNS configuration commented out"
    fi
    
    log "Phase 2: Configuring systemd-resolved..."
    
    if ! command -v resolvectl &> /dev/null; then
        log "Installing systemd-resolved..."
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
    fi
    
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null; then
        log "Detected 'resolvconf' on Debian 11, uninstalling..."
        apt-get remove -y resolvconf > /dev/null
        rm -f /etc/resolv.conf
        log "✅ 'resolvconf' successfully uninstalled"
    fi
    
    log "Enabling and starting systemd-resolved service..."
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    
    log "Applying final DNS security configuration (DoT, DNSSEC...)"
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    
    log "Phase 3: Safely restarting network services..."
    if systemctl is-enabled --quiet networking.service; then
        systemctl restart networking.service
        log "✅ networking.service safely restarted"
    fi
    
    echo -e "\n${GREEN}✅ All operations completed! Final DNS configuration status:${NC}"
    echo "===================================================="
    resolvectl status
    echo "===================================================="
    echo -e "\n${GREEN}DNS purification script completed${NC}"
}

main() {
    if [[ $EUID -ne 0 ]]; then
       log_error "Error: This script must be run as root. Please use 'sudo'."
       exit 1
    fi
    
    echo "--- Starting comprehensive system DNS health check ---"
    local is_perfect=true
    
    echo -n "1. Checking systemd-resolved status... "
    if ! command -v resolvectl &> /dev/null || ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}Service not running or unresponsive${NC}"
        is_perfect=false
    else
        local status_output
        status_output=$(resolvectl status)
        
        local current_dns
        current_dns=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/{/DNS Servers:/s/.*DNS Servers:[[:space:]]*//p}' | tr -d '\r\n' | xargs)
        
        if [[ "${current_dns}" != "${TARGET_DNS}" ]] || ! echo "${status_output}" | grep -q -- "-LLMNR" || ! echo "${status_output}" | grep -q -- "-mDNS" || ! echo "${status_output}" | grep -q -- "+DNSOverTLS" || ! echo "${status_output}" | grep -q "DNSSEC=allow-downgrade"; then
            echo -e "${YELLOW}Configuration does not match security target${NC}"
            is_perfect=false
        else
            echo -e "${GREEN}Correct configuration${NC}"
        fi
    fi
    
    echo -n "2. Checking dhclient.conf configuration... "
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if grep -q "ignore domain-name-servers;" "$dhclient_conf" && grep -q "ignore domain-search;" "$dhclient_conf"; then
            echo -e "${GREEN}Purified${NC}"
        else
            echo -e "${YELLOW}'ignore' parameters not found${NC}"
            is_perfect=false
        fi
    else
        echo -e "${GREEN}File does not exist, no purification needed${NC}"
    fi
    
    echo -n "3. Checking if-up.d conflict script... "
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ ! -f "$ifup_script" ]] || [[ ! -x "$ifup_script" ]]; then
        echo -e "${GREEN}Disabled or does not exist${NC}"
    else
        echo -e "${YELLOW}Script exists and is executable${NC}"
        is_perfect=false
    fi
    
    if [[ "$is_perfect" == true ]]; then
        echo -e "\n${GREEN}✅ Comprehensive check passed! System DNS configuration is stable and secure. No action needed.${NC}"
        exit 0
    else
        echo -e "\n${YELLOW}--> One or more checks failed. Running full purification and hardening process...${NC}"
        purify_and_harden_dns
    fi
}

main "$@"
