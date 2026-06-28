#!/usr/bin/env bash

# DNS Setup Script - Configures DNS using systemd-resolved
# Defaults to plain direct-IP DNS; secure DNS (DNSSEC + DNS-over-TLS) is optional.
# Officially supported: Debian 12/13, Ubuntu 22.04/24.04/26
# Other OS versions may work but are user-tested, not officially supported.

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global variables for DNS configuration
primary_dns=""
selected_names=()
ipv6_support=false
has_dot_support=false
use_secure_dns=false
non_interactive=false   # set by --yes: accept all defaults with no prompts

# --- Auto-ordering / reachability probe tunables (production defaults) ---
# Probe each candidate server with one real DNS query; sort reachable ones by
# measured RTT ascending and drop non-responders so a dead server never lands
# on the DNS= line (would otherwise cost a full timeout on every resolution).
PROBE_TIMEOUT=2          # seconds; per-server query timeout for the probe
PROBE_QUERY="www.google.com"
PROBE_QTYPE="A"
LAST_RESORT_DNS="9.9.9.9 149.112.112.112"  # FallbackDNS: contacted only when every primary is down

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -6|--ipv6)
            ipv6_support=true
            shift
            ;;
        -y|--yes)
            non_interactive=true
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

# Measure latency (ms) to a single DNS server IP by sending one real query.
# Uses plaintext DNS (port 53) for the probe regardless of secure-DNS mode:
# we are measuring network route quality, not the TLS overhead. The chosen
# servers are then applied with whatever transport the user selected.
# Args: <ip>
# Echoes "<ms>" on success, empty string on failure/timeout.
probe_server() {
    local ip="$1"
    local ms=""
    local t_start t_end
    local out

    if command -v dig &> /dev/null; then
        t_start=$(date +%s%N)
        if out=$(dig +short +time=${PROBE_TIMEOUT} +tries=1 @"$ip" "$PROBE_QUERY" "$PROBE_QTYPE" 2>/dev/null) \
           && [[ -n "$out" ]]; then
            t_end=$(date +%s%N)
            ms=$(( (t_end - t_start) / 1000000 ))
            echo "$ms"
            return 0
        fi
    elif command -v nslookup &> /dev/null; then
        t_start=$(date +%s%N)
        if out=$(nslookup -timeout=$PROBE_TIMEOUT -type="$PROBE_QTYPE" "$PROBE_QUERY" "$ip" 2>/dev/null) \
           && echo "$out" | grep -qi 'name:'; then
            t_end=$(date +%s%N)
            ms=$(( (t_end - t_start) / 1000000 ))
            echo "$ms"
            return 0
        fi
    fi

    return 1
}

# Probe each selected provider and reorder by measured latency (fastest first).
# Non-responding providers are dropped. If every probe fails, the original
# selection order is kept so the user's choices still apply (likely a captive
# portal or no outbound DNS — the loud warning is intentional).
# Reads dns_ipv4/dns_names via bash dynamic scoping from select_dns_providers.
# Result is written to global SORTED_SELECTIONS.
# Args: <space-separated choices>
order_by_latency() {
    local choices=($@)
    local choice probe_ip ms name
    local results=""
    SORTED_SELECTIONS=""

    echo ""
    log "Probing selected providers (timeout ${PROBE_TIMEOUT}s each)..."

    for choice in "${choices[@]}"; do
        # Skip choices that have no entry (invalid index or already-handled).
        [[ -z "${dns_ipv4[$choice]:-}" ]] && continue

        # Probe the provider's first IPv4 (DoT suffix stripped) as a
        # representative target; both IPs of a provider usually share routing.
        probe_ip="$(echo "${dns_ipv4[$choice]}" | awk '{print $1}' | sed 's/#.*//')"

        echo -n "  ${dns_names[$choice]} ($probe_ip)... "
        if ms=$(probe_server "$probe_ip"); then
            echo -e "${GREEN}${ms}ms${NC}"
            results+="${ms}|${choice}|${dns_names[$choice]}"$'\n'
        else
            echo -e "${RED}no response${NC} -> dropped"
        fi
    done

    if [[ -z "$results" ]]; then
        warning "All probes failed. Keeping your selected order (network may block DNS)."
        for choice in "${choices[@]}"; do
            [[ -z "${dns_ipv4[$choice]:-}" ]] && continue
            SORTED_SELECTIONS+="$choice "
        done
        return 0
    fi

    while IFS='|' read -r ms choice name; do
        [[ -z "$choice" ]] && continue
        SORTED_SELECTIONS+="$choice "
    done < <(printf '%s' "$results" | sort -t'|' -k1,1n)
}

ask_secure_dns() {
    echo ""
    echo "=========================================="
    echo "  Secure DNS Configuration"
    echo "=========================================="
    echo ""
    echo "Secure DNS includes DNSSEC validation and DNS-over-TLS (DoT)."
    echo "Some networks block these features or they may slow down resolution."
    echo ""

    if [[ "$non_interactive" == true ]]; then
        use_secure_dns=false
        has_dot_support=false
        log "Secure DNS: DISABLED (--yes: direct IP, fastest mode)"
        echo ""
        return
    fi

    echo -n "Enable secure DNS (DNSSEC + DNS-over-TLS)? (y/N): "
    read -r secure_answer < /dev/tty

    if [[ "$secure_answer" =~ ^[Yy]$ ]]; then
        use_secure_dns=true
        has_dot_support=true
        log "Secure DNS: ENABLED"
    else
        use_secure_dns=false
        has_dot_support=false
        log "Secure DNS: DISABLED (using direct IP DNS)"
    fi
    echo ""
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

# Officially supported OS list. Others may work but are user-tested only, so we
# warn (not block) and continue. Restricting to modern releases lets us assume
# bash 4+, modern systemd-resolved, and current apt behaviour.
supported=false
case "$os_name/$os_version" in
    debian/12|debian/13)            supported=true ;;
    ubuntu/22.04|ubuntu/24.04|ubuntu/26|ubuntu/26.04) supported=true ;;
esac

if [[ "$supported" != true ]]; then
    warning "OS '$os_name $os_version' is NOT officially supported."
    warning "Officially supported: Debian 12/13, Ubuntu 22.04/24.04/26."
    warning "Proceeding anyway — this is user-tested, not guaranteed to work."
    echo ""
fi

log "Detected: $ID $VERSION_ID"

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

    # Get DoT hostname only when secure DNS is enabled
    if [[ "$use_secure_dns" == true ]]; then
        echo -n "DNS-over-TLS hostname (e.g., 'dns.example.com', leave empty if not supported): "
        read -r custom_dot < /dev/tty
    fi

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
    if [[ "$use_secure_dns" == true ]]; then
        echo "  Select DNS Providers (DNS-over-TLS)"
    else
        echo "  Select DNS Providers (Direct IP)"
    fi
    echo "=========================================="
    echo ""
    echo "Available DNS providers:"
    if [[ "$use_secure_dns" == true ]]; then
        echo "  1) Cloudflare (1.1.1.1, 1.0.0.1) - DoT: cloudflare-dns.com"
        echo "  2) Google (8.8.8.8, 8.8.4.4) - DoT: dns.google"
        echo "  3) Quad9 (9.9.9.9, 149.112.112.112) - DoT: dns.quad9.net"
        echo "  4) OpenDNS (208.67.222.222, 208.67.220.220) - DoT: dns.opendns.com"
        echo "  5) AdGuard (94.140.14.14, 94.140.15.15) - DoT: dns.adguard.com"
        echo "  6) CleanBrowsing (185.228.168.9, 185.228.169.9) - DoT: family-filter-dns.cleanbrowsing.org"
    else
        echo "  1) Cloudflare (1.1.1.1, 1.0.0.1)"
        echo "  2) Google (8.8.8.8, 8.8.4.4)"
        echo "  3) Quad9 (9.9.9.9, 149.112.112.112)"
        echo "  4) OpenDNS (208.67.222.222, 208.67.220.220)"
        echo "  5) AdGuard (94.140.14.14, 94.140.15.15)"
        echo "  6) CleanBrowsing (185.228.168.9, 185.228.169.9)"
    fi
    echo "  7) Custom DNS (define your own)"
    echo ""
    echo "Enter your choices separated by spaces (e.g., '1 2 3')"
    echo "All selected providers are queried in order as primary DNS servers."

    if [[ "$non_interactive" == true ]]; then
        selections="1 2 5"
        echo "Selection (default: 1 2 5): $selections  [--yes]"
        log "Using default selection: Cloudflare, Google, AdGuard"
    else
        echo -n "Selection (default: 1 2 5): "
        read -r selections < /dev/tty

        if [[ -z "$selections" ]]; then
            selections="1 2 5"
            log "Using default selection: Cloudflare, Google, AdGuard"
        fi
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

    # Probe each selected provider and reorder by measured latency (fastest
    # first), dropping any that don't respond. Custom DNS (option 7) skips the
    # probe — the user supplied the targets intentionally.
    local probeable_selections=()
    local has_custom=false
    for c in $selections; do
        if [[ "$c" == "7" ]]; then
            has_custom=true
        elif [[ -n "${dns_ipv4[$c]:-}" ]]; then
            probeable_selections+=("$c")
        fi
    done

    if [[ ${#probeable_selections[@]} -gt 0 ]]; then
        order_by_latency "${probeable_selections[@]}"
    else
        SORTED_SELECTIONS=""
    fi

    # Final iteration order: latency-sorted providers, then custom (if any).
    local final_order="$SORTED_SELECTIONS"
    $has_custom && final_order+=" 7"

    primary_dns=""
    selected_names=()

    for choice in $final_order; do
        if [[ -n "${dns_ipv4[$choice]:-}" ]]; then
            local chosen_ipv4="${dns_ipv4[$choice]}"
            local chosen_ipv6="${dns_ipv6[$choice]:-}"

            # Strip DoT hostname when secure DNS is disabled
            if [[ "$use_secure_dns" != true ]]; then
                chosen_ipv4="$(echo "$chosen_ipv4" | sed 's/#[^ ]*//g')"
                chosen_ipv6="$(echo "$chosen_ipv6" | sed 's/#[^ ]*//g')"
            fi

            primary_dns+=" $chosen_ipv4"
            if [[ "$ipv6_support" == true ]]; then
                primary_dns+=" $chosen_ipv6"
            fi
            selected_names+=("${dns_names[$choice]}")
        fi
    done

    if [[ -z "$primary_dns" ]]; then
        if [[ "$use_secure_dns" == true ]]; then
            warning "No valid selection made. Using default: Cloudflare, Google, AdGuard."
            primary_dns="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
            primary_dns+=" 8.8.8.8#dns.google 8.8.4.4#dns.google"
            primary_dns+=" 94.140.14.14#dns.adguard.com 94.140.15.15#dns.adguard.com"

            if [[ "$ipv6_support" == true ]]; then
                primary_dns+=" 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
                primary_dns+=" 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
                primary_dns+=" 2a10:50c0::ad1:ff#dns.adguard.com 2a10:50c0::ad2:ff#dns.adguard.com"
            fi
        else
            warning "No valid selection made. Using default: Cloudflare, Google, AdGuard (direct IP)."
            primary_dns="1.1.1.1 1.0.0.1"
            primary_dns+=" 8.8.8.8 8.8.4.4"
            primary_dns+=" 94.140.14.14 94.140.15.15"

            if [[ "$ipv6_support" == true ]]; then
                primary_dns+=" 2606:4700:4700::1111 2606:4700:4700::1001"
                primary_dns+=" 2001:4860:4860::8888 2001:4860:4860::8844"
                primary_dns+=" 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff"
            fi
        fi

        selected_names=("Cloudflare" "Google" "AdGuard")
    fi

    primary_dns=$(echo "$primary_dns" | xargs)

    echo ""
    log "Final primary DNS order (fastest first): ${selected_names[*]}"
    if [[ "$has_custom" == true ]]; then
        log "Custom DNS appended last (skipped latency probe)"
    fi
    echo ""
}

generate_resolved_config() {
    local dnssec_setting="no"
    local dot_setting="no"

    if [[ "$use_secure_dns" == true ]]; then
        dnssec_setting="yes"
        if [[ "$has_dot_support" == true ]]; then
            dot_setting="opportunistic"
        fi
    fi

    SECURE_RESOLVED_CONFIG="[Resolve]
DNS=$primary_dns
FallbackDNS=$LAST_RESORT_DNS
Domains=~.
DNSSEC=$dnssec_setting
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
        # Remove any previously-added override block (idempotent re-runs). We
        # strip everything between our markers, including the markers and the
        # legacy unmarked supersede/prepend lines from older script versions.
        sed -i '/^# BEGIN setup_dns.sh DNS override$/,/^# END setup_dns.sh DNS override$/d' /etc/dhcp/dhclient.conf
        sed -i '/^# DNS override configuration - added by setup_dns.sh$/,/^prepend domain-name-servers 127\.0\.0\.53;$/d' /etc/dhcp/dhclient.conf
        sed -i '/^supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
        sed -i '/^prepend domain-name-servers/d' /etc/dhcp/dhclient.conf

        # Add our configuration (marked so future runs can remove it cleanly)
        cat >> /etc/dhcp/dhclient.conf << 'EOF'

# BEGIN setup_dns.sh DNS override
supersede domain-name-servers 127.0.0.53;
prepend domain-name-servers 127.0.0.53;
# END setup_dns.sh DNS override
EOF
        log "✅ Updated 'ignore' directives in /etc/dhcp/dhclient.conf"
    fi
    
    # Disable the if-up.d resolved script
    log "Disabling conflicting if-up.d script..."
    if [[ -f /etc/network/if-up.d/resolved ]]; then
        chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
        log "✅ Removed execute permission from /etc/network/if-up.d/resolved"
    fi

    # Disable cloud-init DNS management. cloud-init (present on virtually every
    # cloud VPS image: AWS/GCP/Azure/Oracle/DigitalOcean) rewrites /etc/resolv.conf
    # on boot per manage_resolv_conf, which silently rolls back this script's DNS
    # setup after a reboot or provider maintenance. This is the #1 cause of "DNS
    # works until reboot" reports. We scope the change narrowly: only stop the
    # resolver overwrite, NOT cloud-init's NIC bring-up (some providers rely on it
    # to configure the primary interface, so disabling network config entirely
    # could leave the box offline after reboot).
    log "Disabling cloud-init DNS management (prevents reboot rollback)..."
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        cat > /etc/cloud/cloud.cfg.d/99-disable-dns-mgmt.cfg << 'EOF'
# Managed by setup_dns.sh -- prevents cloud-init from overwriting DNS on boot.
# This is what keeps the clikader DNS config from being rolled back after reboot.
manage_resolv_conf: false
EOF
        log "✅ Disabled cloud-init resolver management"
    else
        log "cloud-init not present (non-cloud image); skipping"
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
        echo "Existing DNS configuration detected and healthy."
        echo "Re-running will probe providers by latency and overwrite the current config."
        echo ""

        if [[ "$non_interactive" == true ]]; then
            log "Proceeding with reconfiguration (--yes)."
        else
            echo -n "Proceed with reconfiguration? (Y/n): "
            read -r force_rerun < /dev/tty
            if [[ "$force_rerun" =~ ^[Nn]$ ]]; then
                echo "Exiting without changes."
                exit 0
            fi
        fi

        echo ""
        log "Starting DNS reconfiguration..."
    fi
    
    ask_secure_dns
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
        if [[ "$use_secure_dns" == true ]]; then
            echo "  • $name DNS (DNS-over-TLS)"
        else
            echo "  • $name DNS (direct IP)"
        fi
    done
    echo ""
    echo "Security features enabled:"
    if [[ "$use_secure_dns" == true ]]; then
        echo "  • DNSSEC: Yes"
        if [[ "$has_dot_support" == true ]]; then
            echo "  • DNS-over-TLS: Opportunistic"
        else
            echo "  • DNS-over-TLS: Disabled (custom DNS without DoT support)"
        fi
    else
        echo "  • DNSSEC: No"
        echo "  • DNS-over-TLS: No"
    fi
    if [[ "$ipv6_support" == true ]]; then
        echo "  • IPv6 support: Enabled"
    else
        echo "  • IPv6 support: Disabled (use -6 flag to enable)"
    fi
    echo ""
}

main "$@"
