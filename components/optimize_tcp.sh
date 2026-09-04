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
# Buffer sizing is BDP-derived (bandwidth-delay product), not copied constants:
# BDP = link_bandwidth * assumed_RTT(150ms); buf_max = 2*BDP + 2MiB, clamped to
# [4MiB, RAM/32] with a 256MiB ceiling, so small VPS don't OOM and high-BDP
# boxes still get the headroom they need. tcp_mem is derived from total RAM.
#
# Usage:  clikader tcp [--dry-run|--status|--revert|--help] [options]
#   (no flag)         Apply tuning (idempotent; safe to re-run)
#   --dry-run         Show current -> desired per key, make no changes
#   --status          Show what is currently active and whether the drop-in is in charge
#   --revert          Restore pre-script state (drop-in + sysctl.conf + live snapshot)
#   --initcwnd        Also set initcwnd/initrwnd 32 on the default route and persist
#                     it (skipped on links <=100Mbps; revert restores the route)
#   --swap SIZE       Also create a swapfile (e.g. 2G, clamped 1-20G) and set
#                     vm.swappiness=10; for small-RAM boxes where grown TCP
#                     buffers risk OOM-killing the proxy
#   --bandwidth MBPS  Override link-speed detection for BDP buffer sizing
#   --help            Show this help

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
SYSCONF="${SYSCONF:-/etc/sysctl.conf}"
DROPIN_DIR="${DROPIN_DIR:-/etc/sysctl.d}"
DROPIN="${DROPIN_DIR}/zz-clikader-tcp.conf"   # "zz-" => sorts last among drop-ins
MARKER="disabled by clikader-tcp"             # tag for keys we neutralize in sysctl.conf
BACKUP_DIR="${BACKUP_DIR:-/etc/clikader-tcp-backup}"
BBR_MODULE_FILE="${BBR_MODULE_FILE:-/etc/modules-load.d/clikader-tcp-bbr.conf}"

# File-descriptor limits (NOT sysctl-managed): a proxy must hold many open
# sockets. fs.file-max is a global kernel cap (sysctl, below), but the per-process
# soft/hard nofile lives in PAM limits, and a systemd *service* (like sing-box)
# ignores PAM — so we also drop a systemd override so the daemon actually inherits it.
LIMITS_FILE="${LIMITS_FILE:-/etc/security/limits.conf}"
SYSTEMD_OVERRIDE_DIR="${SYSTEMD_OVERRIDE_DIR:-/etc/systemd/system.conf.d}"
SYSTEMD_OVERRIDE="${SYSTEMD_OVERRIDE_DIR}/clikader-tcp-limits.conf"

# Desired floor values for capacity/buffer keys that must never regress DOWNWARD.
FLOOR_CONNTRACK_MAX=65536
FLOOR_UDP_RMEM_MIN=8192
FLOOR_UDP_WMEM_MIN=8192
TUPLE_UPPER=33554432   # tcp_rmem/tcp_wmem upper-bound threshold; build_desired
                       # recomputes it from the BDP-derived buf_max

# BDP-derived buffer sizing (bandwidth-delay product). BDP = bandwidth * RTT;
# buf_max = 2*BDP + 2MiB, clamped to [BUF_MAX_FLOOR, min(RAM/32, CEILING)] so
# tiny VPS don't OOM and long-fat links get real headroom.
ASSUMED_RTT_MS="${ASSUMED_RTT_MS:-150}"   # typical international relay path
BUF_MAX_FLOOR=4194304        # 4 MiB
BUF_MAX_CEILING=268435456    # 256 MiB
BUF_DEF=1048576              # per-socket default rmem/wmem (proxy role)
FILE_MAX_TARGET=1048576      # fs.file-max floor
NR_OPEN_TARGET=1048576       # fs.nr_open (per-process ceiling) floor
NOFILE_LIMIT=1048576         # nofile written to limits.conf + systemd override

# Concurrency guard + opt-in feature paths.
LOCK_FILE="${LOCK_FILE:-/var/lock/clikader-tcp.lock}"
INITCWND_HOOK_DIR="${INITCWND_HOOK_DIR:-/etc/networkd-dispatcher/routable.d}"
INITCWND_SERVICE="${INITCWND_SERVICE:-/etc/systemd/system/clikader-tcp-initcwnd.service}"
INITCWND_VALUE=32
SWAPFILE_PATH="${SWAPFILE_PATH:-/swapfile}"
FSTAB="${FSTAB:-/etc/fstab}"

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
OPT_INITCWND=0
OPT_SWAP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --revert|--uninstall|-r) MODE="revert" ;;
        --dry-run|-n)            MODE="dryrun" ;;
        --status|-s)             MODE="status" ;;
        --initcwnd)              OPT_INITCWND=1 ;;
        --swap=*)
            OPT_SWAP="${1#*=}" ;;
        --swap)
            # `--swap 2G` takes the value; bare `--swap` defaults to 2G.
            if [[ $# -ge 2 && "$2" != -* ]]; then OPT_SWAP="$2"; shift; else OPT_SWAP="2G"; fi ;;
        --bandwidth=*)
            BANDWIDTH_MBPS="${1#*=}" ;;
        --bandwidth)
            if [[ $# -ge 2 && "$2" != -* ]]; then BANDWIDTH_MBPS="$2"; shift
            else error "--bandwidth requires a value (Mbps)"; exit 2; fi ;;
        --help|-h)
            sed -n '3,58p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) error "Unknown argument: $1"; exit 2 ;;
    esac
    shift
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

# --- Machine profiling: derive values from specs instead of fixed constants ---

# Total RAM in kB (env MEM_TOTAL_KB overrides for tests).
mem_total_kb() {
    if [[ -n "${MEM_TOTAL_KB:-}" ]]; then echo "$MEM_TOTAL_KB"; return; fi
    awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true
}

# Link bandwidth in Mbps (env/flag BANDWIDTH_MBPS overrides). Virtual NICs
# often report -1 or nothing in /sys/class/net/*/speed; fall back to 1000.
detect_bandwidth_mbps() {
    if [[ -n "${BANDWIDTH_MBPS:-}" ]]; then echo "$BANDWIDTH_MBPS"; return; fi
    local iface speed
    iface="$(ip route show default 2>/dev/null | head -1 | \
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -n "$iface" ]]; then
        speed="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
        speed="${speed//[!0-9]/}"
        if [[ -n "$speed" && "$speed" -gt 0 ]]; then echo "$speed"; return; fi
    fi
    echo 1000
}

# BDP-derived max socket buffer: 2*BDP + 2MiB, clamped to
# [4MiB, min(RAM/32, 256MiB)].
# Args: bandwidth_mbps ram_kb -> echoes bytes
calc_buf_max() {
    local bw="$1" ram_kb="$2"
    local bdp=$(( bw * 1000000 / 8 * ASSUMED_RTT_MS / 1000 ))
    local v=$(( 2*bdp + 2097152 ))
    local cap=$(( ram_kb*1024/32 ))
    (( cap > BUF_MAX_CEILING )) && cap=$BUF_MAX_CEILING
    (( v > cap )) && v=$cap
    (( v < BUF_MAX_FLOOR )) && v=$BUF_MAX_FLOOR
    echo "$v"
}

# RAM-derived tcp_mem triple (low pressure max), in pages. Setting max near RAM
# is the classic small-VPS OOM cause, so cap at RAM/4.
# Args: ram_kb -> echoes "low pressure max"
calc_tcp_mem() {
    local ram_kb="$1" pagesize total low pressure max
    pagesize="$(getconf PAGE_SIZE 2>/dev/null || true)"
    pagesize="${pagesize//[!0-9]/}"
    [[ -n "$pagesize" && "$pagesize" -gt 0 ]] || pagesize=4096
    total=$(( ram_kb*1024/pagesize ))
    low=$(( total/16 ));     (( low < 4096 )) && low=4096
    pressure=$(( total/8 )); (( pressure < 8192 )) && pressure=8192
    max=$(( total/4 ));      (( max < 16384 )) && max=16384
    echo "$low $pressure $max"
}

# Concurrency guard: two concurrent runs would race on the drop-in, snapshots
# and routes. Non-interactive CLI, so just fail with a clear message.
take_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || return 0
    # NB: no `2>/dev/null` on this exec — it would become a permanent redirect
    # and swallow the script's stderr (all warnings/errors) for the whole run.
    exec 9>"$LOCK_FILE" || return 0
    if ! flock -n 9; then
        error "Another clikader tcp instance is running (lock: $LOCK_FILE)"
        exit 1
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

    # --- Machine-derived sizing (BDP for buffers, RAM for tcp_mem) ---
    local ram_kb bw buf_max
    ram_kb="$(mem_total_kb)"; ram_kb="${ram_kb//[!0-9]/}"
    [[ -n "$ram_kb" && "$ram_kb" -gt 0 ]] || ram_kb=1048576   # assume 1GB
    bw="$(detect_bandwidth_mbps)"; bw="${bw//[!0-9]/}"
    [[ -n "$bw" && "$bw" -gt 0 ]] || bw=1000
    buf_max="$(calc_buf_max "$bw" "$ram_kb")"
    TUPLE_UPPER="$buf_max"   # floor_tuple compares live upper bounds against this

    # --- Ramp-up & reuse: fast resume of idle relay streams + TFO reconnect ---
    add net.ipv4.tcp_slow_start_after_idle 0 \
        "Don't reset cwnd after idle -> long-lived relay streams resume at speed"
    add net.ipv4.tcp_no_metrics_save 1 \
        "Don't cache dst metrics -> lossy conns can't poison next conn's slow start"
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
    add net.ipv4.tcp_max_syn_backlog \
        "$(floor_numeric net.ipv4.tcp_max_syn_backlog 8192)" \
        "SYN backlog for bursty inbound handshakes (floor only)"
    add net.ipv4.tcp_max_orphans 32768 \
        "Orphaned-socket cap before kernel drops"
    add "net.ipv4.ip_local_port_range" "10240 65535" \
        "Ephemeral port range for outbound conn churn"
    add net.ipv4.tcp_fin_timeout 15 \
        "Reclaim FIN-WAIT-2 sockets faster"
    add net.core.somaxconn "$(floor_numeric net.core.somaxconn 8192)" \
        "Accept queue depth for listeners (floor only)"
    # WORKLOAD-DEPENDENT: tcp_retries2 caps how long the kernel retransmits an
    # unacknowledged segment before giving up (~default 15 -> ~924s/15min).
    # Lower (e.g. 8) -> fail over to a healthier path/peer faster on lossy links;
    # higher -> more patience for deep-buffer/long-haul paths. 10 is a balanced
    # default for a relay/proxy.
    add net.ipv4.tcp_retries2 10 \
        "Retransmit cap; lower for faster failover, higher for patience"

    # --- Buffers & windowing (floors only: never lower an existing higher value) ---
    # WORKLOAD-DEPENDENT: buf_max is BDP-derived (2*BDP + 2MiB, clamped to
    # [4MiB, RAM/32, 256MiB ceiling]). Override the bandwidth input with
    # --bandwidth on virtual NICs whose link speed can't be detected.
    add net.core.rmem_max "$(floor_numeric net.core.rmem_max "$buf_max")" \
        "Max recv socket buffer (BDP-derived, floor only)"
    add net.core.wmem_max "$(floor_numeric net.core.wmem_max "$buf_max")" \
        "Max send socket buffer (BDP-derived, floor only)"
    add net.core.rmem_default "$(floor_numeric net.core.rmem_default "$BUF_DEF")" \
        "Default recv buffer per socket (proxy role, floor only)"
    add net.core.wmem_default "$(floor_numeric net.core.wmem_default "$BUF_DEF")" \
        "Default send buffer per socket (proxy role, floor only)"
    add net.ipv4.tcp_rmem "$(floor_tuple net.ipv4.tcp_rmem "4096 $BUF_DEF $buf_max")" \
        "TCP recv autotuning tuple (min default max)"
    add net.ipv4.tcp_wmem "$(floor_tuple net.ipv4.tcp_wmem "4096 $BUF_DEF $buf_max")" \
        "TCP send autotuning tuple (min default max)"
    # tcp_mem is RAM-derived (pages: RAM/16, RAM/8, RAM/4). Capping the max at
    # RAM/4 avoids the classic small-VPS OOM where TCP buffers eat all memory.
    add net.ipv4.tcp_mem "$(calc_tcp_mem "$ram_kb")" \
        "Global TCP memory limits in pages (RAM-derived: /16 /8 /4)"
    add net.ipv4.tcp_window_scaling 1 "Allow large windows beyond 64KB"
    add net.ipv4.tcp_adv_win_scale 1 "1/2 of recv buffer for app, 1/2 for window"
    add net.ipv4.tcp_sack 1          "Selective ACKs for faster loss recovery"
    add net.ipv4.tcp_dsack 1         "Duplicate SACK: detect spurious retransmits"
    add net.ipv4.tcp_moderate_rcvbuf 1 "Kernel autotunes recv buffer per socket"
    # WORKLOAD-DEPENDENT: notsent_lowat caps bytes cached in the kernel send
    # queue before blocking the app. Lower (e.g. 131072) cuts bufferbloat and
    # improves latency on interactive/relay streams at the cost of some
    # throughput (it can measurably hurt throughput on low-core machines);
    # set to a large value (or 0x200000=2MB) for pure bulk.
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
    add net.core.netdev_max_backlog \
        "$(floor_numeric net.core.netdev_max_backlog 16384)" \
        "NIC->kernel queue depth before packets dropped under burst (floor only)"

    # --- VM hygiene: keep a reserve so heavy buffer growth can't stall the box ---
    add vm.min_free_kbytes "$(floor_numeric vm.min_free_kbytes 32768)" \
        "Keep 32MB free reserve (floor only; avoids allocation stalls)"

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

    # --- Swap policy (only when --swap created our swapfile) ---
    if [[ -f "${BACKUP_DIR}/swapfile.owned" ]]; then
        add vm.swappiness 10 \
            "Prefer RAM over swap, but let buffers overflow instead of OOM-killing"
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
# Read-back verification (non-fatal): sysctl -p silently skips keys the kernel
# rejects, so compare live state against the desired set and report mismatches.
# --------------------------------------------------------------------------
verify_applied() {
    local i key des cur fails=0
    for i in "${!DK_KEYS[@]}"; do
        key="${DK_KEYS[$i]}"; des="${DK_VALS[$i]}"
        cur="$(get_live "$key")"
        # Unquoted echo collapses tabs/multiple spaces so sysctl's tuple
        # formatting ("a\tb\tc") compares equal to our "a b c".
        if [[ "$(echo $cur)" != "$(echo $des)" ]]; then
            warning "Verify: ${key} is '${cur:-(unset)}', expected '${des}'"
            fails=$((fails+1))
        fi
    done
    if (( fails == 0 )); then
        log "Verified: all ${#DK_KEYS[@]} keys match live state"
    else
        warning "${fails} key(s) did not take effect (see above)."
    fi
}

# --------------------------------------------------------------------------
# Opt-in: initcwnd/initrwnd on the default route.
# A larger initial congestion window (32 segments) removes several RTTs of
# slow-start ramp-up per connection — a real win on high-BDP links. Skipped on
# links <=100Mbps, where the 32-segment first burst would punch through small
# policer token buckets. Route attributes are wiped when the route is recreated
# (DHCP renew, link flap), so we persist via a networkd-dispatcher hook when
# available, else a systemd oneshot unit. Ownership marker ensures revert only
# touches what we created.
# --------------------------------------------------------------------------
apply_initcwnd() {
    local route cleaned speed
    route="$(ip route show default 2>/dev/null | head -1)"
    if [[ -z "$route" ]]; then
        warning "No default IPv4 route found; skipping initcwnd"
        return 0
    fi
    speed="$(detect_bandwidth_mbps)"; speed="${speed//[!0-9]/}"
    if [[ -n "$speed" && "$speed" -le 100 ]]; then
        info "Link speed ${speed}Mbps <= 100Mbps; skipping initcwnd (would burst through small policers)"
        return 0
    fi
    # Snapshot the pristine route once so revert restores the true original.
    if [[ ! -f "${BACKUP_DIR}/default-route.snapshot" ]]; then
        echo "$route" > "${BACKUP_DIR}/default-route.snapshot"
    fi
    # Strip any existing initcwnd/initrwnd tokens, then add ours; all other
    # tokens (via/dev/metric/proto/src/onlink) are preserved verbatim.
    cleaned="$(echo "$route" | sed -E 's/[[:space:]]+initcwnd [0-9]+//g; s/[[:space:]]+initrwnd [0-9]+//g')"
    # Intentional word-splitting: $cleaned is an ip-route token list.
    if ip route replace $cleaned initcwnd "$INITCWND_VALUE" initrwnd "$INITCWND_VALUE"; then
        log "Set initcwnd/initrwnd ${INITCWND_VALUE} on the default route"
        : > "${BACKUP_DIR}/initcwnd.owned"
        persist_initcwnd "$cleaned"
    else
        warning "Failed to set initcwnd on the default route"
    fi
}

persist_initcwnd() {
    local route="$1"
    if [[ -d "$INITCWND_HOOK_DIR" ]]; then
        cat > "${INITCWND_HOOK_DIR}/50-clikader-initcwnd" <<EOF
#!/bin/sh
# Managed by clikader tcp -- re-applies initcwnd when the route is recreated.
ip route replace $route initcwnd $INITCWND_VALUE initrwnd $INITCWND_VALUE 2>/dev/null || true
EOF
        chmod 0755 "${INITCWND_HOOK_DIR}/50-clikader-initcwnd"
        log "Wrote networkd-dispatcher hook ${INITCWND_HOOK_DIR}/50-clikader-initcwnd"
    else
        mkdir -p "$(dirname "$INITCWND_SERVICE")"
        cat > "$INITCWND_SERVICE" <<EOF
# Managed by clikader tcp -- re-applies initcwnd after network-online at boot.
[Unit]
Description=clikader tcp initcwnd
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip route replace $route initcwnd $INITCWND_VALUE initrwnd $INITCWND_VALUE || true'

[Install]
WantedBy=multi-user.target
EOF
        log "Wrote systemd unit ${INITCWND_SERVICE}"
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now "$(basename "$INITCWND_SERVICE")" 2>/dev/null || true
    fi
}

revert_initcwnd() {
    [[ -f "${BACKUP_DIR}/initcwnd.owned" ]] || return 0
    local route=""
    if [[ -f "${BACKUP_DIR}/default-route.snapshot" ]]; then
        route="$(cat "${BACKUP_DIR}/default-route.snapshot")"
    fi
    # Intentional word-splitting: $route is an ip-route token list.
    if [[ -n "$route" ]] && ip route replace $route 2>/dev/null; then
        log "Restored original default route (initcwnd removed)"
    fi
    rm -f "${INITCWND_HOOK_DIR}/50-clikader-initcwnd"
    if [[ -f "$INITCWND_SERVICE" ]]; then
        systemctl disable --now "$(basename "$INITCWND_SERVICE")" 2>/dev/null || true
        rm -f "$INITCWND_SERVICE"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "${BACKUP_DIR}/initcwnd.owned" "${BACKUP_DIR}/default-route.snapshot"
}

# --------------------------------------------------------------------------
# Opt-in: swap hardening. On <=1GB boxes without swap, grown TCP buffers can
# trigger the OOM-killer against the proxy process mid-transfer. A modest
# swapfile + swappiness=10 gives the kernel somewhere to put idle pages.
# --------------------------------------------------------------------------
apply_swap() {
    local size="$1" gb
    gb="${size%[Gg]}"; gb="${gb//[!0-9]/}"
    if [[ -z "$gb" ]]; then
        error "Invalid --swap size: '$size' (use e.g. 2G)"
        exit 2
    fi
    (( gb < 1 )) && gb=1
    (( gb > 20 )) && gb=20
    if [[ -e "$SWAPFILE_PATH" && ! -f "${BACKUP_DIR}/swapfile.owned" ]]; then
        error "$SWAPFILE_PATH exists and is not managed by clikader tcp; refusing to overwrite"
        exit 1
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE_PATH"; then
        info "Swapfile $SWAPFILE_PATH already active"
        : > "${BACKUP_DIR}/swapfile.owned"
        return 0
    fi
    log "Creating ${gb}G swapfile at $SWAPFILE_PATH..."
    if ! fallocate -l "${gb}G" "$SWAPFILE_PATH" 2>/dev/null; then
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count=$((gb*1024)) status=none
    fi
    chmod 600 "$SWAPFILE_PATH"
    mkswap "$SWAPFILE_PATH" >/dev/null
    swapon "$SWAPFILE_PATH"
    if [[ -f "$FSTAB" ]]; then
        sed -i '/# BEGIN clikader-tcp swap/,/# END clikader-tcp swap/d' "$FSTAB"
    fi
    cat >> "$FSTAB" <<EOF

# BEGIN clikader-tcp swap
$SWAPFILE_PATH none swap sw 0 0
# END clikader-tcp swap
EOF
    : > "${BACKUP_DIR}/swapfile.owned"
    log "Swap ${gb}G active (vm.swappiness=10 included in this run's drop-in)"
}

revert_swap() {
    [[ -f "${BACKUP_DIR}/swapfile.owned" ]] || return 0
    if ! swapoff "$SWAPFILE_PATH" 2>/dev/null; then
        warning "swapoff $SWAPFILE_PATH failed (was it active?)"
    fi
    if [[ -f "$FSTAB" ]]; then
        sed -i '/# BEGIN clikader-tcp swap/,/# END clikader-tcp swap/d' "$FSTAB"
        log "Removed clikader-tcp block from $FSTAB"
    fi
    rm -f "$SWAPFILE_PATH" "${BACKUP_DIR}/swapfile.owned"
    log "Removed swapfile $SWAPFILE_PATH"
}

# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------

do_apply() {
    section "TCP/network optimization — apply"
    take_lock

    # Swap first: build_desired() includes vm.swappiness only when our swap
    # marker exists, so the drop-in written below picks it up on the same run.
    if [[ -n "$OPT_SWAP" ]]; then
        apply_swap "$OPT_SWAP"
    fi

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
    verify_applied
    apply_limits_files
    if conntrack_present; then
        apply_conntrack_hashsize
    fi
    if [[ "$OPT_INITCWND" == 1 ]]; then
        apply_initcwnd
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
    take_lock
    if [[ ! -f "$DROPIN" ]] && [[ ! -f "${BACKUP_DIR}/live-values.snapshot" ]] \
        && [[ ! -f "${BACKUP_DIR}/initcwnd.owned" ]] \
        && [[ ! -f "${BACKUP_DIR}/swapfile.owned" ]]; then
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

    # 7. Revert opt-in features (each is a no-op unless its marker exists).
    revert_initcwnd
    revert_swap

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
# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        apply)   do_apply ;;
        revert)  do_revert ;;
        dryrun)  do_dryrun ;;
        status)  do_status ;;
    esac
fi
