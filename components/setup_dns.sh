#!/usr/bin/env bash

# DNS Setup Script - Configures DNS using systemd-resolved
# Defaults to plain direct-IP DNS; secure DNS (DNSSEC + DNS-over-TLS) is optional.
# Optional recursive mode (--recursive): a local unbound resolver queries the
# authoritative nameservers directly, removing every public resolver cache
# (and its stale negative answers) from the path — the real fix for ACME
# DNS-01 propagation hangs. See resolve_cache_setting for the background.
# On Azure VMs (auto-detected) the default resolver is Azure DNS 168.63.129.16:
# the only resolver that can answer VNET-internal names. See detect_azure_vm.
# Officially supported: Debian 12/13, Ubuntu 22.04/24.04/26
# Other OS versions may work but are user-tested, not officially supported.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Bump whenever this component's behavior changes so downloaded runs are
# identifiable in logs (clikader itself may be a different version).
SETUP_DNS_REVISION="1.15.2"

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
show_dns_config=false   # set by list/ls: print the current resolvers and exit

# System file paths (env-overridable so tests can target temp files; defaults unchanged)
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DHCLIENT_CONF="${DHCLIENT_CONF:-/etc/dhcp/dhclient.conf}"
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"
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

# --- Recursion capability probe (recursive mode only) ---
# A recursor must walk root -> TLD -> authoritative servers with plain
# iterative (non-RD) queries, so the probe performs that same walk. Probing
# only the root servers is NOT sufficient: on the host that motivated this
# check (2026-09-17) the roots answered while every gTLD server silently
# dropped queries, so a root-only probe reported "fine" while unbound still
# could not resolve a single name.
RECURSION_PROBE_NAME="example.com"
RECURSION_PROBE_ATTEMPTS=2   # every attempt must complete; a failure bails early
RECURSION_TRACE_TIMEOUT=15   # hard per-attempt bound, seconds
RECURSION_TRACE_EVIDENCE=""  # set on failure: servers that never replied
LAST_RESORT_DNS="208.67.222.2 208.67.220.2"  # OpenDNS Sandbox (Cisco): operator-independent, non-filtering FallbackDNS, contacted only when every primary is down

# How many providers "auto" mode keeps after probing the whole pool.
AUTO_PICK_TOP=3

# --- Provider catalogue (single source of truth) ---
# Ordered array of "name|ipv4-with-DoT|ipv6-with-DoT" records. The menu, the
# latency probe, and the auto-pick all read from this table, so adding or
# reordering a provider only changes one place. The index in the array + 1 is
# the menu number shown to the user (1-based, matching the original script).
#
# Curation policy (decided 2026-09): famous resolvers only, and always their
# non-filtering flavour. Servers run unattended ACME DNS-01 challenges and
# background jobs, so endpoints that filter or redirect answers are
# deliberately picked in the unfiltered form: OpenDNS is the Sandbox pair
# (208.67.222.2/.220.2, not the standard pair that rewrites NXDOMAIN) and
# AdGuard is the Unfiltered pair (94.140.14.140/.141, not the default pair
# that blocks ads/trackers). Alibaba and DNSPod (Tencent) are China-optimized
# anycast rather than anycast-everywhere, so they live in
# CHINA_DNS_PROVIDERS and are only offered when the host looks like it is in
# mainland China (see is_mainland_china); thin-coverage regional resolvers
# otherwise stay out (use Custom DNS).
#
# DoT hostname is embedded as "<ip>#<hostname>" per systemd-resolved syntax.
# Direct-IP mode strips the "#hostname" suffix before applying (see select_dns_providers).
#
# Verified 2026-07: Cloudflare/Google/Quad9 offer public DoT on port 853.
# Verified 2026-09 against provider docs: dns.alidns.com, dot.pub,
# sandbox.opendns.com and unfiltered.adguard-dns.com (port 853).
DNS_PROVIDERS=(
    "Cloudflare|1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com|2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com"
    "Google|8.8.8.8#dns.google 8.8.4.4#dns.google|2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    "Quad9|9.9.9.10#dns10.quad9.net 149.112.112.10#dns10.quad9.net|2620:fe::10#dns10.quad9.net 2620:fe::fe:10#dns10.quad9.net"
    "OpenDNS|208.67.222.2#sandbox.opendns.com 208.67.220.2#sandbox.opendns.com|2620:0:ccc::2#sandbox.opendns.com 2620:0:ccd::2#sandbox.opendns.com"
    "AdGuard|94.140.14.140#unfiltered.adguard-dns.com 94.140.14.141#unfiltered.adguard-dns.com|2a10:50c0::1:ff#unfiltered.adguard-dns.com 2a10:50c0::2:ff#unfiltered.adguard-dns.com"
)
# China-optimized anycast resolvers, appended at runtime on mainland-China
# networks only — see add_region_providers. Keeping them out of the universal
# catalogue everywhere else keeps the menu, latency probe and auto-pick free
# of resolvers whose POPs lose the latency race outside China.
CHINA_DNS_PROVIDERS=(
    "Alibaba|223.5.5.5#dns.alidns.com 223.6.6.6#dns.alidns.com|2400:3200::1#dns.alidns.com 2400:3200:baba::1#dns.alidns.com"
    "DNSPod|119.29.29.29#dot.pub 119.28.28.28#dot.pub|2402:4e00::#dot.pub"
)
# Index of the "Custom DNS" menu entry (always last, after the catalogue).
CUSTOM_DNS_INDEX=$(( ${#DNS_PROVIDERS[@]} + 1 ))

# --- Mainland-China detection ---
# Alibaba and DNSPod are China-optimized anycast: outside mainland China their
# POPs lose the latency race to the global resolvers, so they are only offered
# when this host looks like it is inside mainland China.
#
# The check is deliberately blunt and fast: google.com is blocked on mainland
# networks, so a TCP connection that succeeds within CHINA_PROBE_TIMEOUT means
# the host is NOT there. Bash's /dev/tcp needs no packages (curl/wget are not
# installed yet when setup reaches this step) and `timeout` bounds the whole
# probe — DNS resolution included — so a slow resolver cannot stall it.
CHINA_PROBE_TIMEOUT="${CHINA_PROBE_TIMEOUT:-2}"
region_providers_added=0

is_mainland_china() {
    ! timeout "$CHINA_PROBE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/google.com/443' 2>/dev/null
}

# Append the China-optimized resolvers on mainland networks; idempotent, so a
# second call (or a re-run in the same process) never duplicates entries.
add_region_providers() {
    if (( region_providers_added )); then return 0; fi
    region_providers_added=1
    if is_mainland_china; then
        log "google.com unreachable within ${CHINA_PROBE_TIMEOUT}s: mainland-China network detected"
        log "Adding China-optimized resolvers (Alibaba, DNSPod)"
        DNS_PROVIDERS+=("${CHINA_DNS_PROVIDERS[@]}")
    else
        log "google.com reachable: outside mainland China, skipping Alibaba and DNSPod"
    fi
    CUSTOM_DNS_INDEX=$(( ${#DNS_PROVIDERS[@]} + 1 ))
}

# --- Azure VM detection and fabric DNS ---
# Azure VMs must send their queries to the Azure DNS virtual IP 168.63.129.16
# (an address answered by the host fabric, not a real server) to resolve
# VNET-internal names: private endpoints / Private Link zones, internal load
# balancers and peered-VNET names exist only inside Azure's resolver, so every
# public resolver — and a local unbound recursor — answers NXDOMAIN for them.
# On an Azure VM the VIP is therefore the default (including --yes, i.e. the
# setup path); public resolvers stay a menu choice with a warning.
AZURE_DNS_VIP="168.63.129.16"
# Env-overridable probes so tests can point them at temp files (defaults unchanged).
AZURE_IMDS_URL="${AZURE_IMDS_URL:-http://169.254.169.254/metadata/instance?api-version=2021-02-01}"
AZURE_IMDS_TIMEOUT=3
DMI_SYS_VENDOR_FILE="${DMI_SYS_VENDOR_FILE:-/sys/class/dmi/id/sys_vendor}"
DMI_PRODUCT_FILE="${DMI_PRODUCT_FILE:-/sys/class/dmi/id/product_name}"
is_azure_vm=false
azure_detection_source=""
azure_dns_index=0   # menu index of the Azure entry once registered (1); 0 = absent

# Does the Azure fabric DNS VIP actually answer a query from this box?
# Outside Azure the address leads nowhere, so silence means "not Azure".
# Used to reject DMI false positives: Hyper-V guests from OTHER providers
# report the identical vendor/product strings but have no Azure fabric
# behind them, and the Azure DNS option must never appear on those boxes.
dns_vip_answers() {
    [[ -n "$(dig_query "$AZURE_DNS_VIP" "$PROBE_QUERY" "$PROBE_QTYPE")" ]]
}

# True when this box is an Azure VM (sets is_azure_vm / azure_detection_source).
#
# Primary probe: the Azure Instance Metadata Service. The /metadata/instance
# path with a Metadata:true header is served only by Azure's fabric — AWS/GCP
# metadata endpoints reject this exact request — so a reply containing
# "azEnvironment" is conclusive. Bounded by a short timeout; --noproxy keeps
# link-local traffic off any configured HTTP proxy.
#
# Fallback for networks that filter link-local 169.254.169.254: DMI vendor
# "Microsoft Corporation" + product "Virtual Machine". Those fingerprints
# alone are NOT trusted — Hyper-V VMs at other providers match them too —
# so the fallback additionally requires the fabric DNS VIP to answer one
# real query (it only answers on Azure). A non-Azure machine therefore
# never sees the Azure entry, as menu option or default, in any code path.
detect_azure_vm() {
    is_azure_vm=false
    azure_detection_source=""
    local out=""
    if command -v curl &> /dev/null; then
        out="$(curl -s -m "$AZURE_IMDS_TIMEOUT" --noproxy '*' \
            -H 'Metadata: true' "$AZURE_IMDS_URL" 2>/dev/null || true)"
    fi
    if grep -q '"azEnvironment"' <<< "$out" 2>/dev/null; then
        is_azure_vm=true
        azure_detection_source="instance metadata service"
        return 0
    fi
    local vendor product
    vendor="$(cat "$DMI_SYS_VENDOR_FILE" 2>/dev/null || true)"
    product="$(cat "$DMI_PRODUCT_FILE" 2>/dev/null || true)"
    if [[ "$vendor" == "Microsoft Corporation" && "$product" == "Virtual Machine" ]] \
       && dns_vip_answers; then
        is_azure_vm=true
        azure_detection_source="DMI fingerprints + fabric DNS answer"
        return 0
    fi
    return 1
}

# Prepend the Azure DNS entry to the catalogue as menu slot 1 (and the --yes /
# empty-input default) once an Azure VM is detected. Non-Azure boxes never see
# it: the VIP is unreachable outside Azure, so probing it would only cost every
# user a timeout. The entry carries no DoT hostname and no IPv6 — the fabric
# VIP speaks plain IPv4 DNS only.
register_azure_provider() {
    [[ "$is_azure_vm" == true ]] || return 0
    (( azure_dns_index == 0 )) || return 0
    DNS_PROVIDERS=("Azure|${AZURE_DNS_VIP}|" "${DNS_PROVIDERS[@]}")
    azure_dns_index=1
    # The Custom entry is always last: recompute for the grown catalogue.
    CUSTOM_DNS_INDEX=$(( ${#DNS_PROVIDERS[@]} + 1 ))
}

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
        list|ls)
            show_dns_config=true
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: clikader dns [list|ls] [--yes] [--recursive] [--ipv6]
  list, ls    Show the current DNS servers (read-only, no changes)
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
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
    local choices=("$@")
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
        error 'All probes failed. Refusing to replace the working resolver.'
        return 1
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
    echo "  forward   - systemd-resolved forwards to the selected resolver"
    echo "              (Azure DNS on Azure VMs, else a public provider:"
    echo "              Cloudflare/Google/Quad9/OpenDNS/AdGuard, plus Alibaba/DNSPod"
    echo "              on mainland-China networks; default behavior)"
    echo "  recursive - local unbound resolves via the authoritative nameservers"
    echo "              directly: no public DNS cache in the path, DNSSEC"
    echo "              validated, immune to stale-negative cert hangs"
    echo "              (recommended for servers running ACME DNS-01)"
    echo "              Requires unfiltered outbound port 53 to the root, TLD and"
    echo "              authoritative servers. Many hosting networks filter it; this"
    echo "              script refuses to continue rather than leave the box without DNS."
    echo ""

    if [[ "$is_azure_vm" == true ]]; then
        echo "  NOTE (Azure VM): only Azure DNS ${AZURE_DNS_VIP} resolves VNET-internal"
        echo "  names (private endpoints, internal load balancers, peered VNETs)."
        echo "  Recursive mode, like public resolvers, cannot see them — the default"
        echo "  on this box (forward + Azure DNS) is the recommended choice."
        echo ""
    fi

    if [[ "$non_interactive" == true ]]; then
        if [[ "$use_recursive" == true ]]; then
            log "Resolver: local recursive (unbound) [--recursive]"
        elif [[ "$is_azure_vm" == true ]]; then
            log "Resolver: forward to Azure DNS ${AZURE_DNS_VIP} (default; pass --recursive for unbound)"
        else
            log "Resolver: forward to public DNS (default; pass --recursive for unbound)"
        fi
        echo ""
    else
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
    fi

    if [[ "$is_azure_vm" == true && "$use_recursive" == true ]]; then
        warning "Recursive mode on an Azure VM cannot resolve VNET-internal names"
        warning "(private endpoints, internal load balancers, peered-VNET names -> NXDOMAIN)."
        warning "Re-run without --recursive to use Azure DNS ${AZURE_DNS_VIP} instead."
        echo ""
    fi
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

# --- List mode (read-only) ---
# Prints the configured resolvers plus what systemd-resolved is actually using
# right now, so nobody has to remember which file to cat. Read-only: no lock,
# no writes, safe to run as a normal user (`clikader dns list`).
show_dns_overview() {
    local candidate managed_file="" dns_line="" fallback_line="" dnssec="" dot="" mode unbound_state
    # The clikader drop-in overrides the main file for the settings it sets, so
    # prefer it; fall back to the main resolved.conf, then to "unmanaged".
    for candidate in "$RESOLVED_CONF_D/zz-clikader-dns.conf" "$RESOLVED_CONF"; do
        [[ -f "$candidate" ]] || continue
        managed_file="$candidate"
        dns_line="$(sed -n 's/^DNS=[[:space:]]*//p' "$candidate" | tail -1)"
        fallback_line="$(sed -n 's/^FallbackDNS=[[:space:]]*//p' "$candidate" | tail -1)"
        dnssec="$(sed -n 's/^DNSSEC=[[:space:]]*//p' "$candidate" | tail -1)"
        dot="$(sed -n 's/^DNSOverTLS=[[:space:]]*//p' "$candidate" | tail -1)"
        break
    done
    if [[ "$dns_line" == *127.0.0.1* ]] && systemctl is-active --quiet unbound 2>/dev/null; then
        mode="recursive (systemd-resolved -> unbound on 127.0.0.1:53)"
    elif [[ -n "$managed_file" ]]; then
        mode="forward (systemd-resolved -> upstream resolvers)"
    else
        mode="unmanaged (provider/systemd default)"
    fi

    echo ""
    echo "Current DNS configuration"
    echo "========================="
    printf 'Mode:            %s\n' "$mode"
    printf 'Managed file:    %s\n' "${managed_file:-none}"
    if [[ -n "$dns_line" ]]; then
        printf 'DNS servers:     %s\n' "$dns_line"
    elif [[ -n "$managed_file" ]]; then
        printf 'DNS servers:     (none set in %s)\n' "$managed_file"
    else
        printf 'DNS servers:     (provider/systemd default)\n'
    fi
    printf 'Fallback DNS:    %s\n' "${fallback_line:-none}"
    printf 'DNSSEC:          %s\n' "${dnssec:-no}"
    printf 'DNS-over-TLS:    %s\n' "${dot:-no}"
    if [[ "$mode" == recursive* ]]; then
        if systemctl is-active --quiet unbound 2>/dev/null; then unbound_state=active; else unbound_state=inactive; fi
        printf 'unbound service: %s\n' "$unbound_state"
    fi

    echo ""
    echo "Live state:"
    if command -v resolvectl >/dev/null 2>&1; then
        local live
        live="$(resolvectl dns 2>/dev/null || true)"
        if [[ -n "$live" ]]; then
            printf '%s\n' "$live" | sed 's/^/  /'
        else
            echo "  no live DNS data from resolvectl"
        fi
    else
        echo "  resolvectl not available"
    fi

    if [[ -e "$RESOLV_CONF" ]]; then
        echo ""
        if [[ -L "$RESOLV_CONF" ]]; then
            printf '%s -> %s\n' "$RESOLV_CONF" "$(readlink -f "$RESOLV_CONF" 2>/dev/null || echo '?')"
        else
            printf '%s (regular file)\n' "$RESOLV_CONF"
        fi
        grep '^nameserver' "$RESOLV_CONF" 2>/dev/null | sed 's/^/  /' || true
    fi
    echo ""
}

# `dns list` is deliberately handled before the root check so any user can
# inspect the current resolvers without sudo.
if [[ "$show_dns_config" == true ]]; then
    show_dns_overview
    exit 0
fi

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
    if (( azure_dns_index )); then
        echo "  auto) Test ALL providers (including Azure DNS) and keep the ${AUTO_PICK_TOP} fastest"
    else
        echo "  auto) Automatically test ALL providers and pick the ${AUTO_PICK_TOP} fastest (recommended)"
    fi

    # Generate the numbered list from the catalogue so the menu and the data
    # can never drift apart. Show every IPv4 (both anycast IPs of a provider
    # are always written to DNS=; the DoT hostname only in secure-DNS mode).
    local i name ipv4_display first_ip recommended
    for (( i = 1; i <= ${#DNS_PROVIDERS[@]}; i++ )); do
        name="$(provider_name "$i")"
        ipv4_display="$(provider_ipv4 "$i" | sed 's/#[^ ]*//g')"
        ipv4_display="${ipv4_display// /, }"
        recommended=""
        if [[ "$i" -eq "$azure_dns_index" ]]; then
            recommended=" [recommended: required for VNET-internal names]"
        fi
        if [[ "$use_secure_dns" == true ]]; then
            first_ip="$(provider_ipv4 "$i" | awk '{print $1}')"
            if [[ "$first_ip" == *'#'* ]]; then
                printf '  %2d) %s (%s) - DoT: %s%s\n' "$i" "$name" "$ipv4_display" "${first_ip#*#}" "$recommended"
            else
                printf '  %2d) %s (%s) - DoT: none (plain DNS only)%s\n' "$i" "$name" "$ipv4_display" "$recommended"
            fi
        else
            printf '  %2d) %s (%s)%s\n' "$i" "$name" "$ipv4_display" "$recommended"
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
    local azure_default=false
    if [[ "$non_interactive" == true ]]; then
        if (( azure_dns_index )); then
            # Azure VM + --yes (setup path): Azure DNS only. Public
            # resolvers remain available by re-running interactively.
            selections="$azure_dns_index"
            azure_default=true
            echo "Selection (default: Azure DNS): ${AZURE_DNS_VIP}  [--yes]"
            log "Azure VM default: Azure DNS ${AZURE_DNS_VIP} (rerun 'clikader dns' interactively for public resolvers)"
        else
            selections="auto"
            echo "Selection (default: auto): auto  [--yes]"
            log "Using default selection: auto-pick fastest ${AUTO_PICK_TOP}"
        fi
    else
        if (( azure_dns_index )); then
            echo -n "Selection (default: ${azure_dns_index} = Azure DNS, 'auto' probes all): "
        else
            echo -n "Selection (default: auto): "
        fi
        read -r selections < /dev/tty
        if [[ -z "$selections" ]]; then
            if (( azure_dns_index )); then
                selections="$azure_dns_index"
                azure_default=true
                log "Using default selection: Azure DNS ${AZURE_DNS_VIP}"
            else
                selections="auto"
                log "Using default selection: auto-pick fastest ${AUTO_PICK_TOP}"
            fi
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
        if ! order_by_latency "${probeable_selections[@]}"; then
            if [[ "$azure_default" != true ]]; then
                return 1
            fi
            # The Azure VIP did not answer — the fabric resolver is blocked
            # or transiently down (DMI false positives can no longer reach
            # here: detect_azure_vm rejects them before registration). Do
            # not abort a --yes run over it — fall back to the public
            # auto-pick so the box keeps working DNS, with a loud warning
            # that VNET-internal names will not resolve.
            warning "Azure DNS ${AZURE_DNS_VIP} did not answer the probe."
            warning "Falling back to auto-pick public resolvers; Azure VNET-internal"
            warning "names will NOT resolve on this box."
            is_auto=true
            probeable_selections=()
            for (( i = 1; i <= ${#DNS_PROVIDERS[@]}; i++ )); do
                if [[ "$i" -eq "$azure_dns_index" ]]; then
                    continue
                fi
                probeable_selections+=("$i")
            done
            if [[ ${#probeable_selections[@]} -eq 0 ]] || ! order_by_latency "${probeable_selections[@]}"; then
                return 1
            fi
        fi
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

    # On an Azure VM, warn when the selection contains no Azure DNS: the box
    # loses VNET-internal name resolution. Not fatal — the operator may know
    # the box never talks to VNET-internal names.
    if [[ "$is_azure_vm" == true ]] \
       && ! grep -qw "$azure_dns_index" <<< "$final_order"; then
        echo ""
        warning "No Azure DNS in this selection: Azure VNET-internal names (private"
        warning "endpoints, internal load balancers, peered-VNET names) will NOT resolve."
        warning "Select ${azure_dns_index} (Azure DNS ${AZURE_DNS_VIP}) to keep VNET resolution."
    fi

    # The Azure fabric VIP does not offer DoT; a secure-mode selection that
    # includes it downgrades this run to plain DNS (mirrors the
    # custom-DNS-without-DoT handling in get_custom_dns).
    if [[ "$use_secure_dns" == true ]] \
       && grep -qw "$azure_dns_index" <<< "$final_order"; then
        has_dot_support=false
        warning "Azure DNS does not offer DNS-over-TLS; DoT disabled for this selection."
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
        error 'No valid DNS provider selected; leaving the current resolver intact.'
        return 1
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
            dot_setting="yes"
        fi
    fi

    CACHE_SETTING="$(resolve_cache_setting)"

    # DNSStubListenerExtra is deliberately NOT set: DNSStubListener=yes already
    # binds the 127.0.0.53 stub, and an Extra assignment for the same address
    # just logs "Failed to store ... File exists" on every restart (2026-09-18).
    SECURE_RESOLVED_CONFIG="[Resolve]
DNS=$primary_dns
FallbackDNS=$LAST_RESORT_DNS
Domains=~.
DNSSEC=$dnssec_setting
DNSOverTLS=$dot_setting
Cache=$CACHE_SETTING
CacheFromLocalhost=no
DNSStubListener=yes
ReadEtcHosts=yes
ResolveUnicastSingleLabel=no"
}

# Per-link DNS servers (installed by systemd-networkd or NetworkManager DHCP)
# take precedence over the global DNS= line for traffic on that link — leaving
# them in place means the provider's resolver keeps serving that link's queries
# after cutover. Clear them so the managed global resolver really serves every
# query. Live-only: a provider's DHCP re-adds per-link servers on renew and at
# boot, which `clikader doctor` reports as per-link-dns drift.
clear_per_link_dns() {
    local link servers
    [[ -d "$SYSFS_NET" ]] || return 0
    while IFS= read -r link; do
        [[ "$link" == lo ]] && continue
        servers="$(resolvectl dns "$link" 2>/dev/null || true)"
        if grep -qE 'DNS Servers:.*[0-9A-Fa-f.]' <<< "$servers"; then
            log "Clearing per-link DNS on ${link} (resolvectl revert)"
            resolvectl revert "$link" 2>/dev/null \
                || warning "resolvectl revert ${link} failed; its per-link servers remain"
        fi
    done < <(ls "$SYSFS_NET" 2>/dev/null)
    return 0
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
    if [[ ! -f $DHCLIENT_CONF ]]; then
        # dhclient absent (netplan/systemd-networkd images): nothing to guard.
        echo -e "${GREEN}✓ dhclient not present; nothing to guard${NC}"
    elif grep -q "^supersede domain-name-servers" $DHCLIENT_CONF && \
       grep -q "^prepend domain-name-servers" $DHCLIENT_CONF; then
        echo -e "${GREEN}✓ Properly configured${NC}"
    else
        echo -e "${YELLOW}DNS override markers not found${NC}"
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

# Query <server> for <name>/<type> and echo the short answer; echo nothing when
# the server stays silent. Never fails the caller — a non-answering or
# unreachable server is an expected result here, not an error.
dig_query() {
    local server="$1" name="$2" qtype="$3"
    if command -v dig &> /dev/null; then
        dig +short +time=${PROBE_TIMEOUT} +tries=1 "@${server}" "$name" "$qtype" 2> /dev/null || true
    elif command -v nslookup &> /dev/null; then
        nslookup -timeout=${PROBE_TIMEOUT} -type="$qtype" "$name" "$server" 2> /dev/null \
            | awk '/^Address: / {print $2; exit}' || true
    fi
}

# One bounded iterative DNS walk, stdout+stderr combined.
iterative_walk() {
    timeout "$RECURSION_TRACE_TIMEOUT" dig +trace +short \
        +time=${PROBE_TIMEOUT} +tries=1 "$RECURSION_PROBE_NAME" "$PROBE_QTYPE" 2>&1 || true
}

# Can this host complete a real recursive resolution?
#
# `dig +trace` performs the exact operation a recursor performs — an iterative
# root -> TLD -> authoritative walk using non-RD queries — so it finds a
# filtered port 53 wherever the filter sits, not just at the roots. A completed
# walk prints the final A record as a bare address; a blocked walk prints only
# intermediate records plus "communications error ... timed out" lines.
#
# Both an unbound-checkconf pass and `systemctl is-active unbound` were true on
# the box that motivated this check, yet every lookup still timed out, because
# recursive mode points systemd-resolved at 127.0.0.1 and unbound could not
# reach the authoritative servers (production outage 2026-09-17). Probe with
# real queries BEFORE writing any config.
#
# EVERY attempt must complete. A partially-working path is worse than an
# obviously broken one: recursion would appear healthy and then fail later,
# which is exactly how the box went down.
recursion_is_possible() {
    RECURSION_TRACE_EVIDENCE=""

    if ! command -v dig &> /dev/null; then
        error 'dig is required to verify recursion support'
        return 1
    fi

    local attempt out
    for (( attempt = 1; attempt <= RECURSION_PROBE_ATTEMPTS; attempt++ )); do
        out="$(iterative_walk)"

        if printf '%s\n' "$out" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            continue
        fi

        # Failed: record which servers stayed silent so the cause is obvious.
        RECURSION_TRACE_EVIDENCE="$(printf '%s\n' "$out" \
            | grep -oE 'communications error to [0-9.]+#53' \
            | awk '{print $4}' | sed 's/#53$//' | sort -u | head -3 | tr '\n' ' ' || true)"
        return 1
    done

    return 0
}

# Does the freshly started unbound actually answer real queries?
#
# This is the belt to recursion_is_possible's braces: an iterative walk can
# succeed and the resolver still answer nothing (a broken trust anchor, an
# expired anchor, a mid-flight block that started after the walk). unbound's
# cache is empty immediately after a restart, so a successful lookup here
# proves upstream resolution genuinely works rather than being served from
# cache.
unbound_resolves() {
    local name
    for name in example.com cloudflare.com; do
        if dig_query 127.0.0.1 "$name" A | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            return 0
        fi
    done
    return 1
}

# Install and configure a local recursive resolver (unbound). Called by
# purify_dns BEFORE systemd-resolved is switched to DNS=127.0.0.1, so a
# failure here (DNS port 53 filtered somewhere along the authoritative path,
# port taken, bad config, package broken) aborts with the old resolver config
# still active — the box never loses DNS.
configure_recursive_resolver() {
    echo "--- Configuring local recursive resolver (unbound) ---"

    if ! command -v unbound &> /dev/null; then
        log "Installing unbound..."
        if ! apt-get update -qq; then
            error "apt-get update failed while installing unbound"
            return 1
        fi
        if ! apt-get install -y unbound dns-root-data; then
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
        error 'DNSSEC trust anchor not available. Install dns-root-data and repair the unbound trust anchor before continuing.'
        return 1
    fi

    # Refuse to install a recursive resolver on a network that cannot recurse.
    # Checked BEFORE the config is written, so a blocked network leaves both the
    # running resolver and unbound.conf exactly as they were. Without this the
    # script "succeeded" on a box whose every lookup then timed out.
    if ! recursion_is_possible; then
        echo ""
        error "This network blocks outbound DNS, so a local recursive resolver cannot work."
        error "A full iterative lookup (root -> TLD -> authoritative) did not complete here."
        if [[ -n "$RECURSION_TRACE_EVIDENCE" ]]; then
            error "No reply from: $RECURSION_TRACE_EVIDENCE"
        fi
        error "unbound would start, report 'active', and then answer nothing — taking"
        error "every name lookup on this box down with it, while still exiting successfully."
        warning "Re-run WITHOUT --recursive to use systemd-resolved with public"
        warning "resolvers (Cloudflare/Google/Quad9/OpenDNS/AdGuard) instead."
        warning "Leaving the current resolver configuration untouched — DNS still works."
        echo ""
        return 1
    fi
    log "✅ Iterative lookups complete — recursion is possible on this network"

    log "Staging managed $UNBOUND_CONF..."
    local candidate
    candidate="$(mktemp "${UNBOUND_CONF}.XXXXXX")" || return 1
    cat > "$candidate" << EOF
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
    aggressive-nsec: no
    edns-buffer-size: 1232

    # Caches sized for a single VPS
    msg-cache-size: 32m
    rrset-cache-size: 64m

remote-control:
    control-enable: no
EOF

    if [[ $? -ne 0 ]]; then rm -f "$candidate"; return 1; fi

    # Validate before restarting anything; skip with a warning only when the
    # tool is absent (e.g. stripped images) so real config errors still abort.
    if command -v unbound-checkconf &> /dev/null; then
        if ! unbound-checkconf "$candidate" &> /dev/null; then
            error "unbound-checkconf rejected $UNBOUND_CONF — keeping the old resolver config"
            unbound-checkconf "$candidate" || true
            rm -f "$candidate"
            return 1
        fi
        log "✅ unbound-checkconf passed"
    else
        error 'unbound-checkconf is required'; rm -f "$candidate"; return 1
    fi
    chmod 644 "$candidate" || { rm -f "$candidate"; return 1; }
    mv -f "$candidate" "$UNBOUND_CONF" || return 1

    # unbound-resolvconf.service (shipped by the Debian/Ubuntu package) tries
    # to register unbound with resolvconf and meddle with resolv.conf. Both
    # are unwanted here: resolv.conf is a managed stub symlink.
    systemctl disable --now unbound-resolvconf.service &> /dev/null || true

    systemctl unmask unbound &> /dev/null || true
    systemctl enable unbound &> /dev/null || return 1
    if ! systemctl restart unbound; then
        error "Failed to restart unbound — keeping the old resolver config"
        return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet unbound; then
        error "unbound is not running after restart — keeping the old resolver config"
        return 1
    fi

    # Up is not the same as working. Prove the resolver answers a real query
    # before systemd-resolved is pointed at it, so "started cleanly" can never
    # again mean "blackholes every lookup".
    if ! unbound_resolves; then
        error "unbound started but cannot resolve names — not switching systemd-resolved over to it"
        warning "Outbound port 53 to the root or authoritative servers is likely filtered."
        warning "Re-run WITHOUT --recursive to use public resolvers instead."
        echo ""
        return 1
    fi
    log "✅ unbound answers real queries (verified through 127.0.0.1)"
    log "✅ unbound active on 127.0.0.1:53 (recursive, DNSSEC-validating)"
    echo ""
    return 0
}

# Main purification function
purify_dns() (
    clikader_lock dns || exit 1
    local resolved_was_active=0 unbound_was_active=0 resolved_was_enabled=0 unbound_was_enabled=0
    systemctl is-active --quiet systemd-resolved && resolved_was_active=1
    systemctl is-active --quiet unbound && unbound_was_active=1
    systemctl is-enabled --quiet systemd-resolved && resolved_was_enabled=1
    systemctl is-enabled --quiet unbound && unbound_was_enabled=1
    restore_dns_runtime() {
        if (( unbound_was_active )); then systemctl restart unbound; else systemctl stop unbound; fi
        if (( resolved_was_active )); then systemctl restart systemd-resolved; else systemctl stop systemd-resolved; fi
        (( unbound_was_enabled )) || systemctl disable unbound
        (( resolved_was_enabled )) || systemctl disable systemd-resolved
        return 0
    }
    tx_begin dns restore_dns_runtime || exit 1
    tx_save "$RESOLV_CONF" "$RESOLVED_CONF" "$RESOLVED_CONF_D" "$DHCLIENT_CONF" "$IFUPD_RESOLVED" || exit 1
    if [[ -L "$RESOLV_CONF" ]]; then
        local resolver_target
        resolver_target="$(readlink -f "$RESOLV_CONF")" || exit 1
        tx_save "$resolver_target" || exit 1
    fi
    if [[ -d "$CLOUD_CFG_DIR" ]]; then tx_save "$CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg" || exit 1; fi
    if [[ "$use_recursive" == true ]]; then
        tx_save "$UNBOUND_CONF" || exit 1
        recursion_is_possible || exit 1
        configure_recursive_resolver || exit 1
    fi
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
        sed -i '/^# BEGIN setup_dns.sh DNS override$/,/^# END setup_dns.sh DNS override$/d' "$DHCLIENT_CONF" || exit 1
        sed -i '/^# DNS override configuration - added by setup_dns.sh$/,/^prepend domain-name-servers 127\.0\.0\.53;$/d' "$DHCLIENT_CONF" || exit 1
        sed -i '/^supersede domain-name-servers/d' "$DHCLIENT_CONF" || exit 1
        sed -i '/^prepend domain-name-servers/d' "$DHCLIENT_CONF" || exit 1

        # Add our configuration (marked so future runs can remove it cleanly)
        cat >> "$DHCLIENT_CONF" << 'EOF' || exit 1

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
        chmod a-x "$IFUPD_RESOLVED" || exit 1
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
        cat > "$CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg" << 'EOF' || exit 1
# Managed by setup_dns.sh -- prevents cloud-init from overwriting DNS on boot.
# This is what keeps the clikader DNS config from being rolled back after reboot.
manage_resolv_conf: false
EOF
        chmod 644 "$CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg" || exit 1
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
    
    log "Enabling and starting systemd-resolved service..."
    # systemctl returns non-zero in several non-fatal cases (already enabled,
    # masked edge cases, etc.). Never let that kill the script under set -e.
    systemctl unmask systemd-resolved 2> /dev/null || true
    systemctl enable systemd-resolved || exit 1
    systemctl start systemd-resolved || exit 1

    log "Applying final DNS security configuration (DoT, DNSSEC...)"
    generate_resolved_config
    printf '%s\n' "$SECURE_RESOLVED_CONFIG" > "$TX_DIR/resolved.conf" || exit 1
    install_config "$TX_DIR/resolved.conf" "$RESOLVED_CONF" || exit 1
    # tx_begin's umask 077 would create this directory 0700 and the drop-ins
    # below 0600 — unreadable by systemd-resolved, which runs as the
    # unprivileged systemd-resolve user. resolved then rejects the WHOLE
    # configuration and starts with no DNS servers at all (production outage
    # 2026-09-18: "Failed to open zz-clikader-dns.conf: Permission denied").
    # Service-read configuration must be world-readable.
    mkdir -p "$RESOLVED_CONF_D" || exit 1
    chmod 755 "$RESOLVED_CONF_D"
    {
        printf '[Resolve]\nDNS=\nFallbackDNS=\nDomains=\n'
        printf '%s\n' "$SECURE_RESOLVED_CONFIG"
    } > "$RESOLVED_CONF_D/zz-clikader-dns.conf" || exit 1
    chmod 644 "$RESOLVED_CONF_D/zz-clikader-dns.conf" || exit 1

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
        chmod 644 "${RESOLVED_CONF_D}/10-setup-dns-cache.conf" || exit 1
    fi

    unlock_resolv_conf
    rm -f "$RESOLV_CONF" || exit 1
    ln -sf "$STUB_RESOLV_CONF" "$RESOLV_CONF" || exit 1
    systemctl restart systemd-resolved || {
        error "Failed to restart systemd-resolved"
        return 1
    }
    sleep 2
    clear_per_link_dns
    resolvectl flush-caches >/dev/null || exit 1
    verify_dns || exit 1
    record_managed dns "$RESOLVED_CONF" "$RESOLVED_CONF_D/10-setup-dns-cache.conf" "$RESOLVED_CONF_D/zz-clikader-dns.conf" || exit 1
    if [[ "$use_recursive" == true ]]; then record_managed unbound "$UNBOUND_CONF" || exit 1; fi
    tx_commit
    
    log "✅ DNS purification and hardening complete!"
    echo ""
)

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
    if ! timeout 10 resolvectl query google.com >/dev/null 2>&1; then
        error 'systemd-resolved query failed'
        return 1
    fi
    if nslookup google.com >/dev/null 2>&1; then
        log "✅ DNS resolution is working"
    else
        error "DNS resolution test failed"
        return 1
    fi
    
    echo ""
    log "Current $RESOLV_CONF:"
    cat "$RESOLV_CONF" || return 1
    echo ""
}

# Main execution
main() {
    if ! command -v dig >/dev/null || ! command -v nslookup >/dev/null; then
        apt_refresh || exit 1
        apt-get install -y dnsutils || exit 1
    fi
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

    # Detect Azure before any prompt: it changes the recommended resolver mode
    # and the provider default (Azure DNS — required for VNET-internal names).
    if detect_azure_vm; then
        register_azure_provider
        log "Azure VM detected (via ${azure_detection_source})"
        log "Azure DNS ${AZURE_DNS_VIP} is the default resolver here (required for VNET-internal names)"
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
        add_region_providers
        select_dns_providers || exit 1
    fi

    # Fail loudly rather than relying on `set -e` to propagate the status: bats'
    # `run` disables errexit, and a component sourced by a caller may too. A bare
    # failing call would otherwise fall straight through and print "completed
    # successfully" over a box whose DNS setup just failed.
    if ! purify_dns; then
        echo ""
        error 'DNS setup FAILED. Previous configuration was restored; review the rollback output above.'
        exit 1
    fi

    if ! verify_dns; then
        error "DNS setup verification FAILED — see the checks above."
        exit 1
    fi
    
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
            echo "  • DNS-over-TLS: Required, certificate-validated"
        else
            echo "  • DNS-over-TLS: Disabled (selection contains a plain-DNS-only server)"
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
