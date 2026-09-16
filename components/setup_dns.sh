#!/usr/bin/env bash

# DNS Setup Script - Configures DNS using systemd-resolved
# Defaults to plain direct-IP DNS; secure DNS (DNSSEC + DNS-over-TLS) is optional.
# Optional recursive mode (--recursive): a local unbound resolver queries the
# authoritative nameservers directly, removing every public resolver cache
# (and its stale negative answers) from the path — the real fix for ACME
# DNS-01 propagation hangs. See resolve_cache_setting for the background.
# Officially supported: Debian 12/13, Ubuntu 22.04/24.04/26
# Other OS versions may work but are user-tested, not officially supported.

set -euo pipefail

# Bump whenever this component's behavior changes so downloaded runs are
# identifiable in logs (clikader itself may be a different version).
SETUP_DNS_REVISION="1.11.0"

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
use_recursive=false     # set by --recursive: local unbound resolver instead of forwarding
non_interactive=false   # set by --yes: accept all defaults with no prompts

# System file paths (env-overridable so tests can target temp files; defaults unchanged)
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DHCLIENT_CONF="${DHCLIENT_CONF:-/etc/dhcp/dhclient.conf}"
IFUPD_RESOLVED="${IFUPD_RESOLVED:-/etc/network/if-up.d/resolved}"
CLOUD_CFG_DIR="${CLOUD_CFG_DIR:-/etc/cloud/cloud.cfg.d}"
RESOLVED_CONF="${RESOLVED_CONF:-/etc/systemd/resolved.conf}"
RESOLVED_CONF_D="${RESOLVED_CONF_D:-/etc/systemd/resolved.conf.d}"
UNBOUND_CONF="${UNBOUND_CONF:-/etc/unbound/unbound.conf}"
UNBOUND_TRUST_ANCHOR="${UNBOUND_TRUST_ANCHOR:-/var/lib/unbound/root.key}"
UNBOUND_ROOT_KEY_SRC="${UNBOUND_ROOT_KEY_SRC:-/usr/share/dns/root.key}"
STUB_RESOLV_CONF="${STUB_RESOLV_CONF:-/run/systemd/resolve/stub-resolv.conf}"

# Provider data arrays (associative, keyed by 1-based menu index). Populated by
# load_provider_table from DNS_PROVIDERS; the Custom entry (CUSTOM_DNS_INDEX) is
# filled on demand by get_custom_dns. Declared at global scope so the latency
# probe (order_by_latency) and selection code can read them.
declare -A dns_ipv4
declare -A dns_ipv6
declare -A dns_names

# --- Auto-ordering / reachability probe tunables (production defaults) ---
# Probe each candidate server with one real DNS query; sort reachable ones by
# measured RTT ascending and drop non-responders so a dead server never lands
# on the DNS= line (would otherwise cost a full timeout on every resolution).
PROBE_TIMEOUT=2          # seconds; per-server query timeout for the probe
PROBE_QUERY="www.google.com"
PROBE_QTYPE="A"
LAST_RESORT_DNS="208.67.222.222 208.67.220.220"  # OpenDNS (Cisco): operator-independent FallbackDNS, contacted only when every primary is down

# How many providers "auto" mode keeps after probing the whole pool.
AUTO_PICK_TOP=3

# --- Provider catalogue (single source of truth) ---
# Ordered array of "name|ipv4-with-DoT|ipv6-with-DoT" records. The menu, the
# latency probe, and the auto-pick all read from this table, so adding or
# reordering a provider only changes one place. The index in the array + 1 is
# the menu number shown to the user (1-based, matching the original script).
#
# Curation policy (decided 2026-09): only globally famous, non-filtering,
# anycast-everywhere resolvers. Servers run unattended ACME DNS-01 challenges
# and background jobs, so resolvers that filter/redirect (AdGuard, OpenDNS)
# or have thin regional coverage (DNS.SB, Control D, CleanBrowsing) are
# deliberately excluded — "Custom DNS" covers anything not listed here.
#
# DoT hostname is embedded as "<ip>#<hostname>" per systemd-resolved syntax.
# Direct-IP mode strips the "#hostname" suffix before applying (see select_dns_providers).
#
# Verified 2026-07: each provider offers public DoT on port 853.
DNS_PROVIDERS=(
    "Cloudflare|1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com|2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
    "Google|8.8.8.8#dns.google 8.8.4.4#dns.google|2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    "Quad9|9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net|2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"
)
# Index of the "Custom DNS" menu entry (always last, after the catalogue).
CUSTOM_DNS_INDEX=$(( ${#DNS_PROVIDERS[@]} + 1 ))

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -6|--ipv6)
            ipv6_support=true
            shift
            ;;
        -r|--recursive)
            use_recursive=true
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

# --- Provider catalogue accessors ---
# All take a 1-based index (1 = first provider in DNS_PROVIDERS).

# Echo the human-readable provider name at index <n>.
provider_name() {
    local idx="$1"
    printf '%s' "${DNS_PROVIDERS[$(( idx - 1 ))]%%|*}"
}

# Echo the raw IPv4 field (with DoT suffixes) at index <n>.
provider_ipv4() {
    local idx="$1"
    local rec="${DNS_PROVIDERS[$(( idx - 1 ))]}"
    rec="${rec#*|}"          # drop name
    printf '%s' "${rec%%|*}" # drop ipv6
}

# Echo the raw IPv6 field (with DoT suffixes) at index <n>.
provider_ipv6() {
    local idx="$1"
    local rec="${DNS_PROVIDERS[$(( idx - 1 ))]}"
    rec="${rec#*|}"          # drop name
    printf '%s' "${rec#*|}"  # drop ipv4
}

# Populate the legacy dns_ipv4/dns_ipv6/dns_names associative arrays from the
# catalogue so the existing probe and selection code reads one source of truth.
# Indexing is 1-based and matches the menu numbers.
load_provider_table() {
    dns_ipv4=()
    dns_ipv6=()
    dns_names=()
    local i
    for (( i = 1; i <= ${#DNS_PROVIDERS[@]}; i++ )); do
        dns_ipv4[$i]="$(provider_ipv4 "$i")"
        dns_ipv6[$i]="$(provider_ipv6 "$i")"
        dns_names[$i]="$(provider_name "$i")"
    done
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
#
# Probes run in PARALLEL (one background subshell per provider) so wall time
# stays ~PROBE_TIMEOUT regardless of how many providers are tested — important
# because "auto" mode probes the whole pool.
# Args: <space-separated choices>
order_by_latency() {
    local choices=($@)
    local choice probe_ip ms name
    local results=""
    SORTED_SELECTIONS=""

    echo ""
    log "Probing ${#choices[@]} provider(s) in parallel (timeout ${PROBE_TIMEOUT}s each)..."

    # One temp file per choice so background subshells can write concurrently.
    local tmpdir
    tmpdir="$(mktemp -d)"
    local pids=()

    for choice in "${choices[@]}"; do
        # Skip choices that have no entry (invalid index or already-handled).
        [[ -z "${dns_ipv4[$choice]:-}" ]] && continue

        # Probe the provider's first IPv4 (DoT suffix stripped) as a
        # representative target; both IPs of a provider usually share routing.
        probe_ip="$(echo "${dns_ipv4[$choice]}" | awk '{print $1}' | sed 's/#.*//')"

        # Background probe: write the measured ms to the temp file on success,
        # leave it empty on failure. probe_server is inherited via subshell.
        (
            if ms=$(probe_server "$probe_ip"); then
                printf '%s' "$ms" > "${tmpdir}/${choice}.ms"
            else
                : > "${tmpdir}/${choice}.ms"
            fi
        ) &
        pids+=("$!")
    done

    # Wait for every probe to finish before collecting.
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results in the original (input) order for readable output.
    for choice in "${choices[@]}"; do
        [[ -z "${dns_ipv4[$choice]:-}" ]] && continue
        probe_ip="$(echo "${dns_ipv4[$choice]}" | awk '{print $1}' | sed 's/#.*//')"
        ms="$(cat "${tmpdir}/${choice}.ms" 2>/dev/null || true)"

        printf '  %-16s (%s)... ' "${dns_names[$choice]}" "$probe_ip"
        if [[ -n "$ms" ]]; then
            echo -e "${GREEN}${ms}ms${NC}"
            results+="${ms}|${choice}|${dns_names[$choice]}"$'\n'
        else
            echo -e "${RED}no response${NC} -> dropped"
        fi
    done

    rm -rf "$tmpdir"

    if [[ -z "$results" ]]; then
        warning "All probes failed. Keeping your selected order (network may block DNS)."
        for choice in "${choices[@]}"; do
            [[ -z "${dns_ipv4[$choice]:-}" ]] && continue
            SORTED_SELECTIONS+="$choice "
        done
        return 0
    fi

    # Explicit return 0 so a `while read` that ends on EOF cannot leak a
    # non-zero status into the caller under `set -e`.
    while IFS='|' read -r ms choice name; do
        if [[ -z "${choice:-}" ]]; then
            continue
        fi
        SORTED_SELECTIONS+="$choice "
    done < <(printf '%s' "$results" | sort -t'|' -k1,1n)

    return 0
}

# Ask which resolver architecture to use. Recursive mode (unbound) removes
# every public resolver cache from the path — the structural fix for the
# stale-negative-answer hangs that blocked ACME DNS-01 issuance on 2026-09-16.
ask_resolver_mode() {
    echo ""
    echo "=========================================="
    echo "  Resolver Mode"
    echo "=========================================="
    echo ""
    echo "  forward   - systemd-resolved forwards to Cloudflare/Google/Quad9"
    echo "              (default, current behavior)"
    echo "  recursive - local unbound resolves via the authoritative nameservers"
    echo "              directly: no public DNS cache in the path, DNSSEC"
    echo "              validated, immune to stale-negative cert hangs"
    echo "              (recommended for servers running ACME DNS-01)"
    echo ""

    if [[ "$non_interactive" == true ]]; then
        if [[ "$use_recursive" == true ]]; then
            log "Resolver: local recursive (unbound) [--recursive]"
        else
            log "Resolver: forward to public DNS (default; pass --recursive for unbound)"
        fi
        echo ""
        return
    fi

    echo -n "Use the local recursive resolver (unbound)? (y/N): "
    read -r recursive_answer < /dev/tty

    if [[ "$recursive_answer" =~ ^[Yy]$ ]]; then
        use_recursive=true
        log "Resolver: local recursive (unbound)"
    else
        use_recursive=false
        log "Resolver: forward to public DNS"
    fi
    echo ""
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
    if [[ -f $RESOLV_CONF ]]; then
        if lsattr $RESOLV_CONF 2>/dev/null | grep -q '^....i'; then
            log "Detected locked $RESOLV_CONF, unlocking..."
            chattr -i $RESOLV_CONF 2>/dev/null || true
            log "✅ $RESOLV_CONF unlocked"
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

log "setup_dns revision ${SETUP_DNS_REVISION}"
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

    # Return the configuration via global variables.
    # CUSTOM_DNS_INDEX is the catalogue length + 1 (4 with the current 3-provider pool).
    dns_ipv4[$CUSTOM_DNS_INDEX]="$dns_config_ipv4"
    dns_ipv6[$CUSTOM_DNS_INDEX]="$dns_config_ipv6"
    dns_names[$CUSTOM_DNS_INDEX]="Custom"

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
    echo "  auto) Automatically test ALL providers and pick the ${AUTO_PICK_TOP} fastest (recommended)"

    # Generate the numbered list from the catalogue so the menu and the data
    # can never drift apart. Show every IPv4 (both anycast IPs of a provider
    # are always written to DNS=; the DoT hostname only in secure-DNS mode).
    local i name ipv4_display dot
    for (( i = 1; i <= ${#DNS_PROVIDERS[@]}; i++ )); do
        name="$(provider_name "$i")"
        ipv4_display="$(provider_ipv4 "$i" | sed 's/#[^ ]*//g')"
        ipv4_display="${ipv4_display// /, }"
        if [[ "$use_secure_dns" == true ]]; then
            dot="$(provider_ipv4 "$i" | awk '{print $1}' | sed 's/.*#//')"
            printf '  %2d) %s (%s) - DoT: %s\n' "$i" "$name" "$ipv4_display" "$dot"
        else
            printf '  %2d) %s (%s)\n' "$i" "$name" "$ipv4_display"
        fi
    done
    echo "  ${CUSTOM_DNS_INDEX}) Custom DNS (define your own)"
    echo ""
    echo "Enter 'auto' to auto-pick the fastest ${AUTO_PICK_TOP}, or your choices"
    echo "separated by spaces (e.g., '1 2 3'). Selected providers are queried in order."

    # Load the catalogue into the legacy associative arrays the probe/selection
    # code reads. Custom (index CUSTOM_DNS_INDEX) is filled on demand below.
    load_provider_table

    local selections=""
    if [[ "$non_interactive" == true ]]; then
        selections="auto"
        echo "Selection (default: auto): auto  [--yes]"
        log "Using default selection: auto-pick fastest ${AUTO_PICK_TOP}"
    else
        echo -n "Selection (default: auto): "
        read -r selections < /dev/tty
        if [[ -z "$selections" ]]; then
            selections="auto"
            log "Using default selection: auto-pick fastest ${AUTO_PICK_TOP}"
        fi
    fi

    # Normalize the selection: lowercase the first token to detect 'auto'.
    local is_auto=false
    local first_token="${selections%% *}"
    if [[ "${first_token,,}" == "auto" || "${first_token,,}" == "a" ]]; then
        is_auto=true
        # In auto mode, probe the entire pool and keep the fastest N.
        selections=""
        for (( i = 1; i <= ${#DNS_PROVIDERS[@]}; i++ )); do
            selections+="$i "
        done
    fi

    # Check if custom DNS is selected; if so, collect its details.
    local has_custom=false
    if echo "$selections" | grep -qw "$CUSTOM_DNS_INDEX"; then
        if ! get_custom_dns; then
            error "Failed to configure custom DNS. Aborting."
            exit 1
        fi
        has_custom=true
    fi

    # Probe each selected provider and reorder by measured latency (fastest
    # first), dropping any that don't respond. Custom DNS skips the probe — the
    # user supplied the targets intentionally.
    local probeable_selections=()
    for c in $selections; do
        if [[ "$c" == "$CUSTOM_DNS_INDEX" ]]; then
            continue
        elif [[ -n "${dns_ipv4[$c]:-}" ]]; then
            probeable_selections+=("$c")
        fi
    done

    if [[ ${#probeable_selections[@]} -gt 0 ]]; then
        order_by_latency "${probeable_selections[@]}"
    else
        SORTED_SELECTIONS=""
    fi

    # In auto mode, keep only the fastest AUTO_PICK_TOP providers.
    # Note: do not use bare `(( kept++ ))` under `set -e` — post-increment from
    # 0 evaluates to 0 and returns exit status 1, aborting the script right
    # after a successful probe run (exactly when auto mode should keep going).
    if [[ "$is_auto" == true ]]; then
        local trimmed=""
        local kept=0
        for c in $SORTED_SELECTIONS; do
            if (( kept >= AUTO_PICK_TOP )); then
                break
            fi
            trimmed+="$c "
            kept=$((kept + 1))
        done
        if (( kept < AUTO_PICK_TOP )); then
            warning "Only ${kept} of ${AUTO_PICK_TOP} providers responded; using those."
        fi
        SORTED_SELECTIONS="$trimmed"
    fi

    # Final iteration order: latency-sorted providers, then custom (if any).
    local final_order="$SORTED_SELECTIONS"
    if [[ "$has_custom" == true ]]; then
        final_order+=" $CUSTOM_DNS_INDEX"
    fi

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
            warning "No valid selection made. Using default: Cloudflare, Google, Quad9."
            primary_dns="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
            primary_dns+=" 8.8.8.8#dns.google 8.8.4.4#dns.google"
            primary_dns+=" 9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net"

            if [[ "$ipv6_support" == true ]]; then
                primary_dns+=" 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
                primary_dns+=" 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
                primary_dns+=" 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"
            fi
        else
            warning "No valid selection made. Using default: Cloudflare, Google, Quad9 (direct IP)."
            primary_dns="1.1.1.1 1.0.0.1"
            primary_dns+=" 8.8.8.8 8.8.4.4"
            primary_dns+=" 9.9.9.9 149.112.112.112"

            if [[ "$ipv6_support" == true ]]; then
                primary_dns+=" 2606:4700:4700::1111 2606:4700:4700::1001"
                primary_dns+=" 2001:4860:4860::8888 2001:4860:4860::8844"
                primary_dns+=" 2620:fe::fe 2620:fe::9"
            fi
        fi

        selected_names=("Cloudflare" "Google" "Quad9")
    fi

    primary_dns=$(echo "$primary_dns" | xargs)

    echo ""
    log "Final primary DNS order (fastest first): ${selected_names[*]}"
    if [[ "$has_custom" == true ]]; then
        log "Custom DNS appended last (skipped latency probe)"
    fi
    echo ""
}

# systemd major version as an integer (e.g. 255), or 0 when undeterminable.
systemd_major_version() {
    local ver
    ver="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2; exit}')"
    if [[ "$ver" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ver"
    else
        printf '0'
    fi
}

# Cache= setting for the generated resolved.conf.
#
# Never "yes" (the upstream default): systemd-resolved caches NXDOMAIN/NODATA
# for the zone's SOA minimum — 1800s on Cloudflare-hosted zones — which is
# exactly the 30-minute DNS-01 propagation timeout of 1Panel/lego (and any
# other ACME client polling through the system resolver). One lookup of
# _acme-challenge.<domain> made before the TXT record exists pins a stale
# negative for the entire challenge window and certificate issuance hangs.
# Observed twice in production 2026-09-16; disabling negative caching fixed
# both within seconds.
#
# "no-negative" (keep positive caching, drop negative caching) needs
# systemd >= 250; Ubuntu 22.04 ships 249, so fall back to plain "no" there
# (an unknown value would only log a warning and silently re-enable "yes").
resolve_cache_setting() {
    local ver
    ver="$(systemd_major_version)"
    if (( ver >= 250 )); then
        printf 'no-negative'
    else
        printf 'no'
    fi
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

    CACHE_SETTING="$(resolve_cache_setting)"

    SECURE_RESOLVED_CONFIG="[Resolve]
DNS=$primary_dns
FallbackDNS=$LAST_RESORT_DNS
Domains=~.
DNSSEC=$dnssec_setting
DNSOverTLS=$dot_setting
Cache=$CACHE_SETTING
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
    if [[ -f $DHCLIENT_CONF ]] && \
       grep -q "^supersede domain-name-servers" $DHCLIENT_CONF && \
       grep -q "^prepend domain-name-servers" $DHCLIENT_CONF; then
        echo -e "${GREEN}✓ Properly configured${NC}"
    else
        echo -e "${YELLOW}'ignore' parameters not found${NC}"
        all_passed=false
    fi
    
    # Check 3: if-up.d conflict script
    echo -n "3. Checking if-up.d conflict script... "
    if [[ -x $IFUPD_RESOLVED ]]; then
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

# Install and configure a local recursive resolver (unbound). Called by
# purify_dns BEFORE systemd-resolved is switched to DNS=127.0.0.1, so a
# failure here (port taken, bad config, package broken) aborts with the old
# resolver config still active — the box never loses DNS.
configure_recursive_resolver() {
    echo "--- Configuring local recursive resolver (unbound) ---"

    if ! command -v unbound &> /dev/null; then
        log "Installing unbound..."
        if ! apt-get update -qq; then
            error "apt-get update failed while installing unbound"
            return 1
        fi
        if ! apt-get install -y unbound; then
            error "Failed to install unbound"
            return 1
        fi
    fi

    local do_ip6="no"
    local ipv6_lines=""
    if [[ "$ipv6_support" == true ]]; then
        do_ip6="yes"
        ipv6_lines=$'    interface: ::1\n    access-control: ::1/128 allow'
    fi

    # Ensure the DNSSEC trust anchor exists. The package normally creates
    # /var/lib/unbound/root.key at install/start, but minimal images and
    # offline installs can miss it (verified on a Debian 13 container), and
    # unbound refuses to load a config pointing at a missing anchor. Seed it
    # from the static anchor shipped by dns-root-data (an unbound dependency);
    # if even that is unavailable, generate the config without validation
    # rather than shipping one unbound rejects.
    local trust_anchor="$UNBOUND_TRUST_ANCHOR"
    if [[ ! -f "$trust_anchor" && -f "$UNBOUND_ROOT_KEY_SRC" ]]; then
        # chown to the unbound user for RFC5011 rollover updates; plain cp
        # fallback covers systems without the user (read-only validation).
        install -o unbound -g unbound -m 0644 "$UNBOUND_ROOT_KEY_SRC" "$trust_anchor" 2> /dev/null \
            || cp "$UNBOUND_ROOT_KEY_SRC" "$trust_anchor" \
            || true
    fi
    local trust_anchor_line="    auto-trust-anchor-file: \"$trust_anchor\""
    if [[ ! -f "$trust_anchor" ]]; then
        warning "DNSSEC trust anchor not available; unbound will run without DNSSEC validation"
        trust_anchor_line="    # DNSSEC validation disabled: no trust anchor available"
    fi

    log "Writing managed $UNBOUND_CONF..."
    cat > "$UNBOUND_CONF" << EOF
# Managed by setup_dns.sh (full overwrite on every run) — local recursive
# resolver. Resolves via the authoritative nameservers directly, so no public
# resolver cache (and its stale negative answers) sits in the path.
#
# cache-max-negative-ttl: 0 is load-bearing: a cached stale NODATA lives for
# the zone's SOA minimum (1800s on Cloudflare zones) — exactly the 30-minute
# DNS-01 propagation timeout of 1Panel/lego — and hangs certificate issuance
# (observed twice in production, 2026-09-16).
server:
    interface: 127.0.0.1
    port: 53
${ipv6_lines}
    do-ip4: yes
    do-ip6: $do_ip6
    do-udp: yes
    do-tcp: yes

    # Loopback clients only; unbound refuses everything else by default.
    access-control: 127.0.0.0/8 allow

    # Never serve a cached negative answer (see comment above).
    cache-max-negative-ttl: 0

    # DNSSEC validation against the trust anchor created at install time.
${trust_anchor_line}
    harden-dnssec-stripped: yes
    val-permissive-mode: no

    # Privacy / hardening
    qname-minimisation: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-below-nxdomain: yes
    aggressive-nsec: yes
    edns-buffer-size: 1232

    # Caches sized for a single VPS
    msg-cache-size: 32m
    rrset-cache-size: 64m

remote-control:
    control-enable: no
EOF

    # Validate before restarting anything; skip with a warning only when the
    # tool is absent (e.g. stripped images) so real config errors still abort.
    if command -v unbound-checkconf &> /dev/null; then
        if ! unbound-checkconf "$UNBOUND_CONF" &> /dev/null; then
            error "unbound-checkconf rejected $UNBOUND_CONF — keeping the old resolver config"
            unbound-checkconf "$UNBOUND_CONF" || true
            return 1
        fi
        log "✅ unbound-checkconf passed"
    else
        warning "unbound-checkconf not found; skipping config validation"
    fi

    # unbound-resolvconf.service (shipped by the Debian/Ubuntu package) tries
    # to register unbound with resolvconf and meddle with resolv.conf. Both
    # are unwanted here: resolv.conf is a managed stub symlink.
    systemctl disable --now unbound-resolvconf.service &> /dev/null || true

    systemctl unmask unbound &> /dev/null || true
    systemctl enable unbound &> /dev/null || true
    if ! systemctl restart unbound; then
        error "Failed to restart unbound — keeping the old resolver config"
        return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet unbound; then
        error "unbound is not running after restart — keeping the old resolver config"
        return 1
    fi
    log "✅ unbound active on 127.0.0.1:53 (recursive, DNSSEC-validating)"
    echo ""
    return 0
}

# Main purification function
purify_dns() {
    echo "--- Starting DNS purification and hardening process ---"
    
    unlock_resolv_conf
    
    # Phase 1: Remove all conflict sources
    log "Phase 1: Removing all potential DNS conflict sources..."
    
    # Configure dhclient to ignore DHCP DNS
    log "Configuring DHCP client (dhclient)..."
    if [[ -f $DHCLIENT_CONF ]]; then
        # Remove any previously-added override block (idempotent re-runs). We
        # strip everything between our markers, including the markers and the
        # legacy unmarked supersede/prepend lines from older script versions.
        sed -i '/^# BEGIN setup_dns.sh DNS override$/,/^# END setup_dns.sh DNS override$/d' $DHCLIENT_CONF
        sed -i '/^# DNS override configuration - added by setup_dns.sh$/,/^prepend domain-name-servers 127\.0\.0\.53;$/d' $DHCLIENT_CONF
        sed -i '/^supersede domain-name-servers/d' $DHCLIENT_CONF
        sed -i '/^prepend domain-name-servers/d' $DHCLIENT_CONF

        # Add our configuration (marked so future runs can remove it cleanly)
        cat >> $DHCLIENT_CONF << 'EOF'

# BEGIN setup_dns.sh DNS override
supersede domain-name-servers 127.0.0.53;
prepend domain-name-servers 127.0.0.53;
# END setup_dns.sh DNS override
EOF
        log "✅ Updated 'ignore' directives in $DHCLIENT_CONF"
    fi
    
    # Disable the if-up.d resolved script
    log "Disabling conflicting if-up.d script..."
    if [[ -f $IFUPD_RESOLVED ]]; then
        chmod -x $IFUPD_RESOLVED 2>/dev/null || true
        log "✅ Removed execute permission from $IFUPD_RESOLVED"
    fi

    # Disable cloud-init DNS management. cloud-init (present on virtually every
    # cloud VPS image: AWS/GCP/Azure/Oracle/DigitalOcean) rewrites $RESOLV_CONF
    # on boot per manage_resolv_conf, which silently rolls back this script's DNS
    # setup after a reboot or provider maintenance. This is the #1 cause of "DNS
    # works until reboot" reports. We scope the change narrowly: only stop the
    # resolver overwrite, NOT cloud-init's NIC bring-up (some providers rely on it
    # to configure the primary interface, so disabling network config entirely
    # could leave the box offline after reboot).
    log "Disabling cloud-init DNS management (prevents reboot rollback)..."
    if [[ -d $CLOUD_CFG_DIR ]]; then
        cat > $CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg << 'EOF'
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
        # Keep apt output on failure visible; never let a quiet non-zero exit
        # abort the script with no explanation under `set -e`.
        if ! apt-get update -qq; then
            error "apt-get update failed while installing systemd-resolved"
            return 1
        fi
        if ! apt-get install -y systemd-resolved; then
            error "Failed to install systemd-resolved"
            return 1
        fi
    fi
    
    # Remove resolvconf if present (common on older Debian/Ubuntu)
    if dpkg -s resolvconf &> /dev/null 2>&1; then
        log "Detected 'resolvconf' package, uninstalling..."
        apt-get remove -y resolvconf || true
        rm -f $RESOLV_CONF
        log "✅ 'resolvconf' successfully uninstalled"
    fi
    
    log "Enabling and starting systemd-resolved service..."
    # systemctl returns non-zero in several non-fatal cases (already enabled,
    # masked edge cases, etc.). Never let that kill the script under set -e.
    systemctl unmask systemd-resolved 2> /dev/null || true
    systemctl enable systemd-resolved 2> /dev/null || true
    systemctl start systemd-resolved 2> /dev/null || true

    # Recursive mode: bring unbound up BEFORE resolved is pointed at it, so
    # any failure here aborts with the previous resolver still in place.
    if [[ "$use_recursive" == true ]]; then
        if ! configure_recursive_resolver; then
            return 1
        fi
    fi

    log "Applying final DNS security configuration (DoT, DNSSEC...)"
    generate_resolved_config
    echo -e "${SECURE_RESOLVED_CONFIG}" > $RESOLVED_CONF

    # Also pin the Cache= setting in a drop-in so a later hand-edit of the main
    # resolved.conf (e.g. someone changing DNS= and rewriting the file) cannot
    # silently re-enable negative caching — the exact regression that pinned a
    # 30-minute stale NODATA on 2026-09-16 and hung two cert issuances.
    if mkdir -p "$RESOLVED_CONF_D" 2> /dev/null; then
        cat > "${RESOLVED_CONF_D}/10-setup-dns-cache.conf" << EOF
# Managed by setup_dns.sh. Prevents negative-answer caching, which pins stale
# NXDOMAIN/NODATA answers for the zone's SOA minimum (1800s on Cloudflare
# zones) and hangs ACME DNS-01 challenges that poll via the system resolver.
[Resolve]
Cache=$CACHE_SETTING
EOF
    fi

    unlock_resolv_conf
    rm -f $RESOLV_CONF 2>/dev/null || true
    ln -sf $STUB_RESOLV_CONF $RESOLV_CONF
    systemctl restart systemd-resolved || {
        error "Failed to restart systemd-resolved"
        return 1
    }
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

    if [[ "$use_recursive" == true ]]; then
        if systemctl is-active --quiet unbound; then
            log "✅ unbound (local recursive resolver) is active"
        else
            error "unbound is not running"
            return 1
        fi
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
    log "Current $RESOLV_CONF:"
    cat $RESOLV_CONF
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
    
    ask_resolver_mode

    if [[ "$use_recursive" == true ]]; then
        # No upstream providers to pick, and unbound does its own DNSSEC
        # validation, so DoT-to-upstream secure mode does not apply.
        use_secure_dns=false
        has_dot_support=false
        primary_dns="127.0.0.1"
        if [[ "$ipv6_support" == true ]]; then
            primary_dns="127.0.0.1 ::1"
        fi
        selected_names=("unbound (local recursive)")
        log "Recursive mode: systemd-resolved will forward to unbound on 127.0.0.1:53"
        echo ""
    else
        ask_secure_dns
        select_dns_providers
    fi

    purify_dns
    verify_dns
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}DNS setup completed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Your system is now using:"
    if [[ "$use_recursive" == true ]]; then
        echo "  • Local recursive resolver (unbound) on 127.0.0.1:53, reached via the systemd-resolved stub"
        echo "  • No public DNS cache in the path — immune to stale-negative cert-renewal hangs"
    else
        for name in "${selected_names[@]}"; do
            if [[ "$use_secure_dns" == true ]]; then
                echo "  • $name DNS (DNS-over-TLS)"
            else
                echo "  • $name DNS (direct IP)"
            fi
        done
    fi
    echo ""
    echo "Security features enabled:"
    if [[ "$use_recursive" == true ]]; then
        echo "  • DNSSEC: Validated by unbound (full authoritative chain)"
        echo "  • DNS-over-TLS: N/A (loopback hop to unbound)"
        echo "  • Negative caching: Disabled on both layers (resolved + unbound)"
    elif [[ "$use_secure_dns" == true ]]; then
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

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
