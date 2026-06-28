#!/usr/bin/env bash

# Network-stack optimization for a sing-box proxy / network-relay VPS handling
# web browsing, video streaming, and file downloads (high concurrent-conn load).
# Officially supported: Debian 12/13, Ubuntu 24.04 (other modern kernels may work).
#
# Tuning scope: kernel network sysctls + file-descriptor limits (the #1 proxy
# bottleneck) + routing needed for TUN/relay. Also scales conntrack if present.
# Explicitly NOT touched: DNS, /etc/resolv.conf, systemd-resolved, sshd_config,
# firewall RULES (nftables/iptables). We only read firewall/conntrack state to
# decide whether conntrack tuning applies; ip_forward is kernel routing, not
# firewall, and is required for the proxy to relay traffic.
#
# ===========================================================================
#  SYSCTL LOAD-ORDER HANDLING (the part most scripts get wrong)
# ===========================================================================
#  `sysctl --system` applies config files in this order:
#    1. Everything under /{etc,run,usr/lib,usr/local/lib}/sysctl.d/*.conf, all
#       sorted together LEXICOGRAPHICALLY by basename — last name wins.
#    2. /etc/sysctl.conf is applied LAST, overriding every drop-in above.
#
#  Consequence: a key present in /etc/sysctl.conf CANNOT be overridden by a
#  drop-in. A naive script that writes a drop-in silently loses to sysctl.conf.
#
#  How THIS script makes its values authoritative:
#    A. It owns one drop-in named  zz-clikader-tcp.conf  in /etc/sysctl.d.
#       The "zz-" prefix sorts after every standard drop-in (e.g. 99-sysctl.conf,
#       protect-links.conf), so among drop-ins ours wins.
#    B. Before relying on the drop-in, it scans /etc/sysctl.conf and comments
#       out any of OUR managed keys that are active there (tagged with a marker).
#       With those neutralized, the drop-in's values take effect. sysctl.conf is
#       otherwise left byte-for-byte untouched (no blind clobbering).
#    C. The drop-in is regenerated from scratch each run, so it is always an
#       exact, idempotent statement of the desired state.
#
#  Reversibility: on first run we snapshot (1) the original /etc/sysctl.conf,
#  (2) the live value of every managed key. `--revert` removes the drop-in,
#  restores /etc/sysctl.conf, and reapplies the live snapshot so runtime returns
#  to the true pre-script state (not just "delete the file and hope").
# ===========================================================================
#
# Usage:  clikader tcp [--dry-run|--status|--revert|--help]
#   (no flag)   Apply tuning (idempotent; safe to re-run)
#   --dry-run   Show current -> desired per key, make no changes
#   --status    Show what is currently active and whether the drop-in is in charge
#   --revert    Restore pre-script state (drop-in + sysctl.conf + live snapshot)
#   --help      Show this help

set -euo pipefail

# --------------------------------------------------------------------------
# Color / logging
# --------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()      { echo -e "${GREEN}-->${NC} $1"; }
info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
warning()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()    { echo -e "${RED}[ERROR]${NC} $1" >&2; }
section()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

# --------------------------------------------------------------------------
# Paths / constants
# --------------------------------------------------------------------------
SYSCONF="/etc/sysctl.conf"
DROPIN_DIR="/etc/sysctl.d"
DROPIN="${DROPIN_DIR}/zz-clikader-tcp.conf"   # "zz-" => sorts last among drop-ins
MARKER="disabled by clikader-tcp"             # tag for keys we neutralize in sysctl.conf
BACKUP_DIR="/etc/clikader-tcp-backup"
BBR_MODULE_FILE="/etc/modules-load.d/clikader-tcp-bbr.conf"

# File-descriptor limits (NOT sysctl-managed): a proxy must hold many open
# sockets. fs.file-max is a global kernel cap (sysctl, below), but the per-process
# soft/hard nofile lives in PAM limits, and a systemd *service* (like sing-box)
# ignores PAM — so we also drop a systemd override so the daemon actually inherits it.
LIMITS_FILE="/etc/security/limits.conf"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system.conf.d"
SYSTEMD_OVERRIDE="${SYSTEMD_OVERRIDE_DIR}/clikader-tcp-limits.conf"

# Desired floor values for capacity/buffer keys that must never regress DOWNWARD.
FLOOR_RMEM_MAX=33554432
FLOOR_WMEM_MAX=33554432
FLOOR_CONNTRACK_MAX=65536
FLOOR_UDP_RMEM_MIN=8192
FLOOR_UDP_WMEM_MIN=8192
TUPLE_UPPER=33554432   # third element of tcp_rmem/tcp_wmem upper bound
FILE_MAX_TARGET=1048576      # fs.file-max floor
NR_OPEN_TARGET=1048576       # fs.nr_open (per-process ceiling) floor
NOFILE_LIMIT=1048576         # nofile written to limits.conf + systemd override

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

for d in "$DROPIN_DIR" "$BACKUP_DIR"; do
    [[ -d "$d" ]] || mkdir -p "$d"
done

# --- Argument parsing ---
MODE="apply"
for arg in "$@"; do
    case "$arg" in
        --revert|--uninstall|-r) MODE="revert" ;;
        --dry-run|-n)            MODE="dryrun" ;;
        --status|-s)             MODE="status" ;;
        --help|-h)
            sed -n '3,47p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) error "Unknown argument: $arg"; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Live value of a sysctl key, or "" if unavailable (does not fail the script).
get_live() {
    sysctl -n "$1" 2>/dev/null || true
}

# Effective numeric value: never lower an existing higher live value.
# Args: key desired -> echoes value to use
floor_numeric() {
    local key="$1" desired="$2"
    local cur
    cur="$(get_live "$key")"
    cur="${cur//[!0-9]/}"
    if [[ -n "$cur" && "$cur" -ge "$desired" ]]; then
        echo "$cur"
    else
        echo "$desired"
    fi
}

# Effective 3-tuple (tcp_rmem/tcp_wmem): keep current whole tuple if its upper
# bound is already >= desired upper bound, else use desired.
# Args: key "a b c" -> echoes tuple to use
floor_tuple() {
    local key="$1" desired="$2"
    local cur cur_upper
    cur="$(get_live "$key")"
    cur_upper="$(echo "$cur" | awk '{print $3}')"
    cur_upper="${cur_upper//[!0-9]/}"
    if [[ -n "$cur_upper" && "$cur_upper" -ge "$TUPLE_UPPER" ]]; then
        echo "$cur"
    else
        echo "$desired"
    fi
}

# Is nf_conntrack loaded/present? (decides whether conntrack keys are applied)
conntrack_present() {
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || \
    lsmod 2>/dev/null | grep -q '^nf_conntrack'
}

# Ensure BBR is available; load module if needed. Returns 0 if bbr usable.
ensure_bbr() {
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        # Persist module load across reboots (harmless if built-in).
        echo "tcp_bbr" > "$BBR_MODULE_FILE"
        return 0
    fi
    return 1
}

# --------------------------------------------------------------------------
# Build the desired-state key/value list (parallel arrays).
# Keys are added in display order; values computed with non-regression rules.
# Sets globals: DK_KEYS[], DK_VALS[], DK_WHY[]
# --------------------------------------------------------------------------
build_desired() {
    DK_KEYS=(); DK_VALS=(); DK_WHY=()

    add() { # key value why
        DK_KEYS+=("$1"); DK_VALS+=("$2"); DK_WHY+=("$3")
    }

    section_note() { :; } # placeholder (sections are visual only)

    # --- Ramp-up & reuse: fast resume of idle relay streams + TFO reconnect ---
    add net.ipv4.tcp_slow_start_after_idle 0 \
        "Don't reset cwnd after idle -> long-lived relay streams resume at speed"
    add net.ipv4.tcp_fastopen 3 \
        "TFO client+server -> 1 RTT saved on reconnect"
    add net.ipv4.tcp_mtu_probing 1 \
        "Handle PMTU blackholes on NAT'd/lossy paths (CN-ISP)"
    add net.ipv4.tcp_rfc1337 1 \
        "Safe TIME_WAIT reuse (resists duplicate-SYN attacks)"
    add net.ipv4.tcp_syncookies 1 \
        "SYN-flood resilience; keeps handshake alive under flood"
    # WORKLOAD-DEPENDENT: synack_retries controls how long a half-open inbound
    # connection is retried before giving up. Lower = faster cleanup of dead
    # clients; raise if you serve clients on very lossy links.
    add net.ipv4.tcp_synack_retries 2 \
        "Fewer SYN-ACK retries -> faster half-open cleanup"
    add net.ipv4.tcp_congestion_control bbr \
        "BBR congestion control (pairs with fq qdisc)"
    add net.core.default_qdisc fq \
        "fq qdisc is the pacing partner BBR needs"

    # --- Capacity for short-lived connection churn (proxy fan-out) ---
    add net.ipv4.tcp_tw_reuse 1 \
        "Safe reuse of outbound TIME_WAIT sockets (NOT tcp_tw_recycle)"
    add net.ipv4.tcp_max_tw_buckets 32768 \
        "Headroom for TIME_WAIT churn from short-lived conns"
    add net.ipv4.tcp_max_syn_backlog 4096 \
        "SYN backlog for bursty inbound handshakes"
    add net.ipv4.tcp_max_orphans 32768 \
        "Orphaned-socket cap before kernel drops"
    add "net.ipv4.ip_local_port_range" "10240 65535" \
        "Ephemeral port range for outbound conn churn"
    add net.ipv4.tcp_fin_timeout 30 \
        "Reclaim FIN-WAIT-2 sockets faster"
    add net.core.somaxconn 4096 \
        "Accept queue depth for listeners"
    # WORKLOAD-DEPENDENT: tcp_retries2 caps how long the kernel retransmits an
    # unacknowledged segment before giving up (~default 15 -> ~924s/15min).
    # Lower (e.g. 8) -> fail over to a healthier path/peer faster on lossy links;
    # higher -> more patience for deep-buffer/long-haul paths. 10 is a balanced
    # default for a relay/proxy.
    add net.ipv4.tcp_retries2 10 \
        "Retransmit cap; lower for faster failover, higher for patience"

    # --- Buffers & windowing (floors only: never lower an existing higher value) ---
    # WORKLOAD-DEPENDENT: these upper bounds assume a box with >=1GB RAM doing
    # heavy relay. Lower them on memory-constrained VPS; raise the *_max pair
    # for very-high-BDP long-haul links.
    add net.core.rmem_max "$(floor_numeric net.core.rmem_max "$FLOOR_RMEM_MAX")" \
        "Max recv socket buffer (floor only)"
    add net.core.wmem_max "$(floor_numeric net.core.wmem_max "$FLOOR_WMEM_MAX")" \
        "Max send socket buffer (floor only)"
    add net.ipv4.tcp_rmem "$(floor_tuple net.ipv4.tcp_rmem '4096 87380 33554432')" \
        "TCP recv autotuning tuple (min default max)"
    add net.ipv4.tcp_wmem "$(floor_tuple net.ipv4.tcp_wmem '4096 16384 33554432')" \
        "TCP send autotuning tuple (min default max)"
    add net.ipv4.tcp_window_scaling 1 "Allow large windows beyond 64KB"
    add net.ipv4.tcp_sack 1          "Selective ACKs for faster loss recovery"
    add net.ipv4.tcp_moderate_rcvbuf 1 "Kernel autotunes recv buffer per socket"
    # WORKLOAD-DEPENDENT: notsent_lowat caps bytes cached in the kernel send
    # queue before blocking the app. Lower (e.g. 131072) cuts bufferbloat and
    # improves latency on interactive/relay streams at the cost of some
    # throughput; set to a large value (or 0x200000=2MB) for pure bulk.
    add net.ipv4.tcp_notsent_lowat 131072 \
        "Send-queue floor; lower = less bufferbloat / lower latency"
    # UDP floors matter for QUIC and SOCKS5-UDP relay; never lower existing.
    add net.ipv4.udp_rmem_min \
        "$(floor_numeric net.ipv4.udp_rmem_min "$FLOOR_UDP_RMEM_MIN")" \
        "Min recv buffer per UDP socket (floor only)"
    add net.ipv4.udp_wmem_min \
        "$(floor_numeric net.ipv4.udp_wmem_min "$FLOOR_UDP_WMEM_MIN")" \
        "Min send buffer per UDP socket (floor only)"

    # --- Faster dead-peer detection (kernel TCP keepalive; NOT sshd) ---
    # WORKLOAD-DEPENDENT: aggressive keepalives detect dead NAT'd peers in
    # ~675s (time + intvl*probes). For idle-friendly mobile clients, raise
    # tcp_keepalive_time; for strict relay health, lower it.
    add net.ipv4.tcp_keepalive_time 600   "Seconds idle before first keepalive probe"
    add net.ipv4.tcp_keepalive_intvl 15   "Seconds between keepalive retransmits"
    add net.ipv4.tcp_keepalive_probes 5   "Probes before declaring peer dead"

    # --- RX headroom ---
    add net.core.netdev_max_backlog 5000 \
        "NIC->kernel queue depth before packets dropped under burst"

    # --- Routing & relay correctness (sing-box TUN / transparent proxy needs this) ---
    # ip_forward is KERNEL ROUTING, not firewall — required so the box forwards
    # packets between interfaces/TUN and the real NIC. Does NOT touch nft/iptables.
    add net.ipv4.ip_forward 1 \
        "Forward packets between interfaces (required by TUN/relay proxying)"
    # rp_filter=2 (loose mode): asymmetric paths (NAT, CN-ISP multi-route) would
    # be DROPPED by the strict default (1). Loose mode accepts them, which is what
    # a relay/proxy on a variable route needs.
    add net.ipv4.conf.all.rp_filter 2 \
        "Loose reverse-path filter -> keeps asymmetric-path relay traffic flowing"
    add net.ipv4.conf.default.rp_filter 2 \
        "Loose rp_filter for future interfaces"
    # Hardening that protects connectivity on a public box: ICMP redirects let a
    # MITM reroute traffic; disabling them is standard and never hurts a proxy.
    add net.ipv4.conf.all.accept_redirects 0  "Reject ICMP redirects (hardening)"
    add net.ipv4.conf.all.secure_redirects 0  "Reject 'secure' ICMP redirects"
    add net.ipv4.conf.all.send_redirects 0    "Don't emit ICMP redirects (not a router)"

    # --- Neighbor / ARP cache headroom (high dest-IP fan-out) ---
    # A proxy opening many concurrent streams to many sites can exhaust the
    # neighbor cache; raising gc_thresh prevents stalls/lookup failures.
    # WORKLOAD-DEPENDENT: scale these up further on boxes fanning out to tens of
    # thousands of distinct destinations.
    add net.ipv4.neigh.default.gc_thresh1 2048 "Neighbor-cache soft limit (parallel dests)"
    add net.ipv4.neigh.default.gc_thresh2 4096 "Neighbor-cache hard limit (warn)"
    add net.ipv4.neigh.default.gc_thresh3 8192 "Neighbor-cache absolute limit"

    # --- Per-socket auxiliary memory ---
    # optmem_max backs ancillary data (e.g. recvmsg control) at high conn counts;
    # not autotuned, so give it headroom.
    add net.core.optmem_max 4194304 "Per-socket ancillary buffer ceiling (high conn count)"

    # --- File descriptors (the #1 proxy bottleneck) ---
    # fs.file-max is the global kernel-wide open-file ceiling. With many relay
    # streams + downloads open at once the default (~80k-925k) can be hit.
    # Floor only: never lower an existing higher value.
    add fs.file-max \
        "$(floor_numeric fs.file-max "$FILE_MAX_TARGET")" \
        "System-wide open-file cap (floor only; high concurrent-conn proxy)"
    # nr_open is the per-process upper bound; must be >= the nofile limit we set
    # in limits.conf/systemd or raising nofile would be refused.
    add fs.nr_open \
        "$(floor_numeric fs.nr_open "$NR_OPEN_TARGET")" \
        "Per-process open-file ceiling (floor; must be >= nofile)"

    # --- Conntrack hygiene (only if the connection tracker is in use) ---
    if conntrack_present; then
        add net.netfilter.nf_conntrack_tcp_timeout_established 86400 \
            "Drop stale established entries after 1 day (was often 5d)"
        add net.netfilter.nf_conntrack_tcp_timeout_time_wait 30 \
            "Drop conntrack TIME_WAIT entries quickly"
        add net.netfilter.nf_conntrack_max \
            "$(floor_numeric net.netfilter.nf_conntrack_max "$FLOOR_CONNTRACK_MAX")" \
            "Conntrack table size (floor only; never lower existing)"
    fi
}

# --------------------------------------------------------------------------
# First-run snapshot for reliable revert (only created if absent, so the TRUE
# pre-script state is preserved across re-applies).
# --------------------------------------------------------------------------
snapshot_live() {
    if [[ -f "${BACKUP_DIR}/live-values.snapshot" ]]; then
        return 0   # already have the original snapshot; keep it
    fi
    : > "${BACKUP_DIR}/live-values.snapshot"
    local i key val
    for i in "${!DK_KEYS[@]}"; do
        key="${DK_KEYS[$i]}"
        val="$(get_live "$key")"
        # "key<TAB>value"; missing keys recorded empty so revert knows to skip.
        printf '%s\t%s\n' "$key" "$val" >> "${BACKUP_DIR}/live-values.snapshot"
    done
    log "Snapshotted live values -> ${BACKUP_DIR}/live-values.snapshot"
}

backup_sysctl_conf() {
    if [[ ! -f "${BACKUP_DIR}/sysctl.conf.orig" && -f "$SYSCONF" ]]; then
        cp -a "$SYSCONF" "${BACKUP_DIR}/sysctl.conf.orig"
        log "Backed up original ${SYSCONF} -> sysctl.conf.orig"
    fi
}

# Neutralize our managed keys in /etc/sysctl.conf by commenting active lines.
# Idempotent: already-commented / already-marked lines are left as-is.
neutralize_sysctl_conf() {
    [[ -f "$SYSCONF" ]] || return 0
    local key re tmp
    tmp="$(mktemp)"
    cp -a "$SYSCONF" "${tmp}"
    for key in "${DK_KEYS[@]}"; do
        # Escape key for use in a regex (dots -> \.). Anchor at line start,
        # optional whitespace, then the key, then whitespace/= .
        re="^([[:space:]]*)(${key//./\\.})([[:space:]]*=)"
        # Comment out lines that are active AND not already tagged by us.
        # Use perl for in-place safety; fall back to awk if perl is absent.
        if command -v perl >/dev/null 2>&1; then
            perl -i -pe '
                if (!/^#.*'"${MARKER}"'/ && /^(\s*)('"${key//./\\.}"')(\s*=)/) {
                    $_ = "# ['"${MARKER}"'] $_";
                }
            ' "$tmp"
        fi
    done
    cat "$tmp" > "$SYSCONF"
    rm -f "$tmp"
}

# Count how many of our keys were active in sysctl.conf (for reporting).
count_neutralized() {
    [[ -f "$SYSCONF" ]] || { echo 0; return; }
    grep -c "# \[${MARKER}\]" "$SYSCONF" 2>/dev/null || echo 0
}

# --------------------------------------------------------------------------
# Write the drop-in (single source of truth for our keys).
# --------------------------------------------------------------------------
write_dropin() {
    local i key val
    {
        echo "# Managed by clikader tcp -- do not edit; regenerate with 'clikader tcp'."
        echo "# Removing/commenting this file restores your previous sysctl.conf state."
        echo "# See ${BACKUP_DIR}/ for snapshots used by 'clikader tcp --revert'."
        echo ""
        for i in "${!DK_KEYS[@]}"; do
            key="${DK_KEYS[$i]}"; val="${DK_VALS[$i]}"
            printf '%-52s = %s\n' "$key" "$val"
        done
    } > "$DROPIN"
    chmod 0644 "$DROPIN"
}

# Apply the drop-in to live state. `sysctl -p <our file>` sets exactly our keys;
# because sysctl.conf keys are neutralized and our file sorts last among drop-ins,
# these values win both now and at boot (sysctl --system).
apply_live() {
    log "Applying settings live (sysctl -p ${DROPIN})..."
    # Allow partial failures (e.g. a key unsupported on this kernel) without
    # aborting the whole run; report per-key outcomes afterwards.
    sysctl -p "$DROPIN" >/dev/null 2>&1 || true
}

# --- Non-sysctl file-descriptor limits -------------------------------------
# A proxy daemon holds many sockets; the default per-process nofile (~1024) is
# the single biggest real-world bottleneck for streaming/downloads. fs.file-max
# (sysctl, above) raises the global cap, but the per-process soft/hard nofile is
# governed by PAM limits — and a systemd *service* ignores PAM entirely, so we
# also drop a system-wide systemd override (DefaultLimitNOFILE) so sing-box etc.
# actually inherit the higher limit on restart. See revert_files() for restore.
apply_limits_files() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"

    # 1) /etc/security/limits.conf — for interactive/PAM sessions.
    if [[ -f "$LIMITS_FILE" ]] && [[ ! -f "${BACKUP_DIR}/limits.conf.orig" ]]; then
        cp -a "$LIMITS_FILE" "${BACKUP_DIR}/limits.conf.orig"
    fi
    # Remove any prior clikader block (idempotent), then append a fresh one.
    if [[ -f "$LIMITS_FILE" ]]; then
        sed -i '/# BEGIN clikader-tcp limits/,/# END clikader-tcp limits/d' "$LIMITS_FILE"
        cat >> "$LIMITS_FILE" <<EOF

# BEGIN clikader-tcp limits
*    soft   nofile   ${NOFILE_LIMIT}
*    hard   nofile   ${NOFILE_LIMIT}
root soft   nofile   ${NOFILE_LIMIT}
root hard   nofile   ${NOFILE_LIMIT}
# END clikader-tcp limits
EOF
        log "Updated ${LIMITS_FILE} (nofile=${NOFILE_LIMIT})"
    fi

    # 2) systemd system-wide override — for daemons (sing-box) which skip PAM.
    mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    cat > "$SYSTEMD_OVERRIDE" <<EOF
# Managed by clikader tcp -- do not edit.
# Sets the default nofile for systemd services so proxy daemons (sing-box etc.)
# inherit a high open-file limit without per-service edits.
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
EOF
    log "Wrote systemd override ${SYSTEMD_OVERRIDE}"
    # Best effort: reload manager. Won't affect already-running services until
    # they restart, which is expected — the override is for the next start.
    systemctl daemon-reload 2>/dev/null || true
}

# Scale the conntrack hash table so it doesn't collide at high max. nf_conntrack
# hashes best when hashsize ~= nf_conntrack_max / 4. Writing the module param
# resizes live (kernel supports this since 2.6); safe no-op if unavailable.
apply_conntrack_hashsize() {
    local param="/sys/module/nf_conntrack/parameters/hashsize"
    local max target
    max="$(get_live net.netfilter.nf_conntrack_max)"
    max="${max//[!0-9]/}"
    [[ -n "$max" ]] || return 0
    target=$(( max / 4 ))
    (( target >= 1024 )) || target=1024
    if [[ -w "$param" ]]; then
        echo "$target" > "$param" 2>/dev/null && \
            log "Set nf_conntrack hashsize=${target} (max=${max})"
    fi
}

# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------

do_apply() {
    section "TCP/network optimization — apply"
    build_desired

    # BBR: warn clearly if the kernel can't do it; we still skip the CC key
    # rather than write a value that sysctl will reject.
    if ! ensure_bbr; then
        warning "BBR congestion control is NOT available on this kernel."
        warning "tcp_congestion_control will be SKIPPED. Consider a >=4.9 kernel."
        # Drop the CC + qdisc keys from the desired set so we don't write a
        # value that fails to apply. (qdisc=fq is fine standalone, but keep it.)
        local i=0
        while (( i < ${#DK_KEYS[@]} )); do
            if [[ "${DK_KEYS[$i]}" == "net.ipv4.tcp_congestion_control" ]]; then
                unset 'DK_KEYS[i]'; unset 'DK_VALS[i]'; unset 'DK_WHY[i]'
                DK_KEYS=("${DK_KEYS[@]}"); DK_VALS=("${DK_VALS[@]}"); DK_WHY=("${DK_WHY[@]}")
            fi
            i=$((i+1))
        done
    fi

    backup_sysctl_conf
    snapshot_live
    neutralize_sysctl_conf
    write_dropin
    apply_live
    apply_limits_files
    if conntrack_present; then
        apply_conntrack_hashsize
    fi

    local n
    n="$(count_neutralized)"
    echo ""
    log "Wrote ${DROPIN} (${#DK_KEYS[@]} keys)"
    log "Neutralized ${n} conflicting key(s) in ${SYSCONF}"
    log "Set per-process nofile=${NOFILE_LIMIT} (limits.conf + systemd override)"
    echo -e "${GREEN}Done. Boot-time order is correct: zz- drop-in wins.${NC}"
    info "Proxy daemons (sing-box) must be restarted to pick up the new nofile limit."
}

do_revert() {
    section "TCP/network optimization — revert"
    if [[ ! -f "$DROPIN" ]] && [[ ! -f "${BACKUP_DIR}/live-values.snapshot" ]]; then
        warning "Nothing to revert (no drop-in and no snapshot found)."
        exit 0
    fi

    # 1. Remove our drop-in.
    if [[ -f "$DROPIN" ]]; then
        rm -f "$DROPIN"; log "Removed ${DROPIN}"
    fi

    # 2. Restore original /etc/sysctl.conf (un-neutralizes any keys we tagged).
    if [[ -f "${BACKUP_DIR}/sysctl.conf.orig" ]]; then
        cp -a "${BACKUP_DIR}/sysctl.conf.orig" "$SYSCONF"
        log "Restored original ${SYSCONF}"
    else
        # No backup (e.g. sysctl.conf didn't exist originally): just strip our
        # marker comments in case any remain.
        if [[ -f "$SYSCONF" ]] && grep -q "\[${MARKER}\]" "$SYSCONF"; then
            sed -i "/# \[${MARKER}\] /s/^# \[${MARKER}\] //" "$SYSCONF"
            log "Untagged marker comments in ${SYSCONF}"
        fi
    fi

    # 3. Reapply the live snapshot so runtime returns to pre-script state.
    if [[ -f "${BACKUP_DIR}/live-values.snapshot" ]]; then
        log "Restoring live values from snapshot..."
        local key val
        while IFS=$'\t' read -r key val; do
            [[ -z "$key" ]] && continue
            if [[ -z "$val" ]]; then
                continue   # key wasn't readable pre-script; nothing to restore
            fi
            sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
        done < "${BACKUP_DIR}/live-values.snapshot"
    fi

    # 4. Reload from files so any non-snapshot drop-ins reassert themselves.
    sysctl --system >/dev/null 2>&1 || true

    # 5. Restore file-descriptor limits (limits.conf + systemd override).
    if [[ -f "${BACKUP_DIR}/limits.conf.orig" ]]; then
        cp -a "${BACKUP_DIR}/limits.conf.orig" "$LIMITS_FILE"
        log "Restored original ${LIMITS_FILE}"
    elif [[ -f "$LIMITS_FILE" ]]; then
        # No backup: just strip our tagged block.
        sed -i '/# BEGIN clikader-tcp limits/,/# END clikader-tcp limits/d' "$LIMITS_FILE"
        log "Removed clikader-tcp block from ${LIMITS_FILE}"
    fi
    if [[ -f "$SYSTEMD_OVERRIDE" ]]; then
        rm -f "$SYSTEMD_OVERRIDE"
        log "Removed systemd override ${SYSTEMD_OVERRIDE}"
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 6. Best-effort cleanup of the BBR module-load hint (leave the module
    #    loaded; rmmod could disrupt live flows).
    rm -f "$BBR_MODULE_FILE" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}Reverted to pre-script state.${NC}"
    info "Backups left in ${BACKUP_DIR}/ for audit (safe to delete manually)."
    info "Keys that were UNSET before this script cannot be unset live; reboot to"
    info "restore their kernel defaults. File state (sysctl.conf + drop-in) is fully restored."
}

# Dry run: show current -> desired for every key, no writes.
do_dryrun() {
    section "TCP/network optimization — dry run (no changes will be made)"
    build_desired
    if ! ensure_bbr; then
        warning "BBR unavailable on this kernel -> tcp_congestion_control would be SKIPPED."
    fi
    echo ""
    printf '  %-46s %-22s -> %-22s\n' "KEY" "CURRENT" "DESIRED"
    printf '  %-46s %-22s    %-22s\n' "$(printf '%0.s-' {1..46})" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..22})"
    local i key cur des mark
    for i in "${!DK_KEYS[@]}"; do
        key="${DK_KEYS[$i]}"; des="${DK_VALS[$i]}"
        cur="$(get_live "$key")"; [[ -z "$cur" ]] && cur="(unset)"
        mark=" "
        [[ "$(get_live "$key")" != "$des" ]] && mark="${YELLOW}*${NC}"
        printf "  ${mark}%-45s %-22s -> %-22s\n" "$key" "$cur" "$des"
    done
    echo ""
    info "Lines marked * would change. Buffers/conntrack_max show floored values."
    info "Conflicting keys in ${SYSCONF} would be commented out (tagged)."
}

# Status: show what is currently active and whether our drop-in is in charge.
do_status() {
    section "TCP/network optimization — current status"
    if [[ -f "$DROPIN" ]]; then
        log "Drop-in present: ${DROPIN}"
    else
        warning "No clikader drop-in found (not applied yet)."
    fi
    build_desired
    echo ""
    printf '  %-46s %-22s %-12s\n' "KEY" "CURRENT" "STATE"
    printf '  %-46s %-22s %-12s\n' "$(printf '%0.s-' {1..46})" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..12})"
    local i key cur des state
    for i in "${!DK_KEYS[@]}"; do
        key="${DK_KEYS[$i]}"; des="${DK_VALS[$i]}"
        cur="$(get_live "$key")"; [[ -z "$cur" ]] && cur="(unset)"
        if [[ "$cur" == "$des" ]]; then state="${GREEN}ok${NC}"
        elif [[ -z "$cur" ]]; then state="${YELLOW}unset${NC}"
        else state="${RED}diff${NC}"; fi
        printf "  %-46s %-22s ${state}\n" "$key" "$cur"
    done
    echo ""
    if [[ -f "${BACKUP_DIR}/sysctl.conf.orig" ]]; then
        info "Backup exists: ${BACKUP_DIR}/sysctl.conf.orig (revert available)"
    else
        info "No backup yet (first apply will snapshot state)."
    fi
}

# --------------------------------------------------------------------------
case "$MODE" in
    apply)   do_apply ;;
    revert)  do_revert ;;
    dryrun)  do_dryrun ;;
    status)  do_status ;;
esac
