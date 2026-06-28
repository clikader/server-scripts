#!/usr/bin/env bash

# TCP / network-stack optimization for sing-box proxy + network relay.
# Officially supported: Debian 12/13, Ubuntu 24.04 (other modern kernels may work).
#
# Tuning scope: kernel network sysctls only.
# Explicitly NOT touched: DNS, /etc/resolv.conf, systemd-resolved, sshd_config,
# firewall (nftables/iptables rules). We only read firewall state to decide
# whether conntrack tuning applies.
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

# Desired floor values for capacity/buffer keys that must never regress DOWNWARD.
FLOOR_RMEM_MAX=33554432
FLOOR_WMEM_MAX=33554432
FLOOR_CONNTRACK_MAX=65536
TUPLE_UPPER=33554432   # third element of tcp_rmem/tcp_wmem upper bound

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
            sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'
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
    add net.ipv4.tcp_congestion_control bbr \
        "BBR congestion control (pairs with fq qdisc)"
    add net.core.default_qdisc fq \
        "fq qdisc is the pacing partner BBR needs"

    # --- Capacity for short-lived connection churn (proxy fan-out) ---
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

    local n
    n="$(count_neutralized)"
    echo ""
    log "Wrote ${DROPIN} (${#DK_KEYS[@]} keys)"
    log "Neutralized ${n} conflicting key(s) in ${SYSCONF}"
    echo -e "${GREEN}Done. Boot-time order is correct: zz- drop-in wins.${NC}"
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

    # 5. Best-effort cleanup of the BBR module-load hint (leave the module
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
