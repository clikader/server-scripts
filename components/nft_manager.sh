#!/usr/bin/env bash

# nft manager - add/delete/reset inbound ports in the clikader nftables allowlist
#
# Manages the clikader-managed inbound allow rules in /etc/nftables.conf:
#   tcp dport { ... } accept comment "ssh + extra tcp ports"
#   udp dport { ... } accept comment "extra udp ports"
#
# The SSH port (grabbed from the effective sshd config) is always kept in the
# TCP allow set and is protected from delete and reset, so the box can never
# be locked out by this tool.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NFT_MANAGER_REVISION="1.12.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}-->${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
NFT_RULE_PARSER="$(dirname "${BASH_SOURCE[0]}")/../lib/nft_rules.awk"
# The allowlist rules are identified by SHAPE — a braced dport set followed by
# accept at the start of a line — never by their trailing comment.
#
# Matching on the comment text meant that describing your own ports
# ("http + https + ssh + extra tcp ports") made the tool refuse to recognise
# its own rule; and because that grep ran under `set -e`, the refusal was
# SILENT and surfaced only as "Script encountered an error (exit code: 1)"
# (reported 2026-09-17). The comment is user-facing prose: it is preserved
# verbatim when present, and the default below is used when it is absent.
#
# Braces stay escaped (\{ \}) so the same regex works under GNU sed (Debian
# targets) and BSD sed (macOS dev/test). Group 1 is the line's indentation.
TCP_RULE_CMT='comment "ssh + extra tcp ports"'
UDP_RULE_CMT='comment "extra udp ports"'

# Current allow sets (space-separated ports), populated by read_allow_sets.
tcp_ports=""
udp_ports=""

# --- Validation helpers ---
valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [[ ${#p} -le 5 ]] || return 1
    (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
    return 0
}

# Normalize a user-supplied port list (single port, or comma/space separated
# with optional spaces around commas) into a clean, unique, space-separated
# string. Invalid tokens abort with an error.
normalize_ports() {
    local raw="$1"
    raw="${raw//,/ }"
    raw="$(printf '%s' "$raw" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
    if [[ -z "$raw" ]]; then
        error "No ports given."
        return 1
    fi
    local p result=""
    for p in $raw; do
        if ! valid_port "$p"; then
            error "Invalid port '${p}'"
            return 1
        fi
        p=$((10#$p))
        if [[ " $result " != *" $p "* ]]; then
            result+=" $p"
        fi
    done
    printf '%s' "${result# }"
}

# Render a space-separated set as the comma-space form used in nftables.conf.
render_set() {
    local out="" p
    for p in $1; do
        [[ -n "$out" ]] && out+=", "
        out+="$p"
    done
    printf '%s' "$out"
}

# Extract the ports inside a "dport { ... }" rule line, space-separated.
extract_set() {
    local line="${1:-}"
    [[ -n "$line" ]] || return 0
    # BRE (no -E) keeps { and } literal, so this is portable across sed flavors.
    printf '%s' "$line" | sed -n 's/.*{\([^}]*\)}.*/\1/p' \
        | tr ',' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# --- Effective SSH port ---
get_ssh_port() {
    local ports
    ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true)"
    # Include actual listeners (including ssh.socket) and this SSH session.
    ports+=" $(ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' || true)"
    if systemctl is-active --quiet ssh.socket; then
        ports+=" $(systemctl show ssh.socket -p Listen --value | grep -oE '[0-9]+ \(Stream\)' | cut -d' ' -f1 || true)"
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then ports+=" ${SSH_CONNECTION##* }"; fi
    ports="$(printf '%s\n' $ports | sort -nu | xargs)"
    [[ -n "$ports" ]] || { error 'Cannot determine SSH ports; refusing firewall changes.'; return 1; }
    normalize_ports "$ports"
}

# Trailing `comment "..."` of a rule line, or empty when the line has none.
rule_comment() {
    local line="${1:-}"
    [[ -n "$line" ]] || return 0
    printf '%s' "$line" | sed -n 's/.*[[:space:]]\(comment "[^"]*"\)[[:space:]]*$/\1/p'
}

# 1-based line number of the first line matching <re>, or empty.
rule_line_number() {
    local re="$1"
    awk -f "$NFT_RULE_PARSER" "$NFT_CONF" | cut -f3- | grep -nE "$re" >/dev/null || return 1
    awk -f "$NFT_RULE_PARSER" "$NFT_CONF" | while IFS=$'\t' read -r number _protocol line; do
        if [[ "$line" =~ $re ]]; then echo "$number"; break; fi
    done
}

# --- Read current allow sets from nftables.conf ---
# Every command substitution ends with `|| true`, and the function returns 0
# unconditionally: under `set -e` a failing assignment aborts the whole script,
# so a non-matching grep here used to kill the run silently before any caller
# could print an actionable error. Reading never needs to fail.
read_allow_sets() {
    tcp_ports=""
    udp_ports=""
    if [[ -f "$NFT_CONF" ]]; then
        local tcp_line="" udp_line=""
        tcp_line="$(awk -f "$NFT_RULE_PARSER" "$NFT_CONF" | awk -F'\t' '$2=="tcp" {sub(/^[^\t]*\t[^\t]*\t/,""); print; exit}')"
        udp_line="$(awk -f "$NFT_RULE_PARSER" "$NFT_CONF" | awk -F'\t' '$2=="udp" {sub(/^[^\t]*\t[^\t]*\t/,""); print; exit}')"
        if [[ -n "$tcp_line" ]]; then tcp_ports="$(extract_set "$tcp_line")"; fi
        if [[ -n "$udp_line" ]]; then udp_ports="$(extract_set "$udp_line")"; fi
    fi
    return 0
}

# --- Set helpers (operate on a global space-separated var) ---
set_add() {
    local varname="$1"; shift
    local current="${!varname}" p
    for p in "$@"; do
        if [[ " $current " != *" $p "* ]]; then
            current+=" $p"
            changed=1
        fi
    done
    printf -v "$varname" '%s' "${current# }"
}

set_remove() {
    local varname="$1"; shift
    local current="${!varname}" p q result="" remove=0
    for p in $current; do
        remove=0
        for q in "$@"; do
            if [[ "$p" == "$q" ]]; then remove=1; break; fi
        done
        if (( remove )); then
            changed=1
        else
            result+=" $p"
        fi
    done
    printf -v "$varname" '%s' "${result# }"
}

# In-place sed that works on GNU sed (Debian/Ubuntu) and BSD sed (macOS).
# GNU: `sed -i ''` treats the empty argument as a filename. BSD: `sed -i`
# without a suffix eats the next argument as a backup suffix.
sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# --- Edit /etc/nftables.conf + validate + reload ---
# Rewrites the TCP/UDP allow rules in place, preserving everything else in the
# file (forward/nat chains, comments, user additions). Backs up first, and on
# validation failure restores the backup and does not touch the firewall.
rewrite_allowlist() (
    local tcp_s="$1" udp_s="$2" matches tcp_ln udp_ln tcp_comment udp_comment
    local tcp_rendered udp_rendered candidate scoped
    matches="$(awk -f "$NFT_RULE_PARSER" "$NFT_CONF")" || exit 1
    if [[ "$(awk -F'\t' '$2=="tcp" {n++} END {print n+0}' <<< "$matches")" != 1 ]]; then
        error 'Cannot find the clikader TCP allow rule (require exactly one in inet clikader_filter/input).'
        error 'Refusing to edit an unrecognized nftables.conf.'
        exit 1
    fi
    if (( $(awk -F'\t' '$2=="udp" {n++} END {print n+0}' <<< "$matches") > 1 )); then
        error 'Ambiguous UDP allowlist in clikader_filter/input'; exit 1
    fi
    tcp_ln="$(awk -F'\t' '$2=="tcp" {print $1}' <<< "$matches")"
    udp_ln="$(awk -F'\t' '$2=="udp" {print $1}' <<< "$matches")"
    tcp_comment="$(rule_comment "$(sed -n "${tcp_ln}p" "$NFT_CONF")")"
    [[ -n "$tcp_comment" ]] || tcp_comment="$TCP_RULE_CMT"
    udp_comment="$UDP_RULE_CMT"
    [[ -z "$udp_ln" ]] || udp_comment="$(rule_comment "$(sed -n "${udp_ln}p" "$NFT_CONF")")"
    [[ -n "$udp_comment" ]] || udp_comment="$UDP_RULE_CMT"
    tx_begin nft || exit 1
    tx_save "$NFT_CONF" || exit 1
    candidate="$TX_DIR/candidate"
    scoped="$TX_DIR/filter.nft"
    tcp_rendered="$(render_set "$tcp_s")"
    udp_rendered="$(render_set "$udp_s")"
    TCP_TEXT="        tcp dport { $tcp_rendered } accept $tcp_comment" \
    UDP_TEXT="        udp dport { $udp_rendered } accept $udp_comment" \
    awk -v tcp="$tcp_ln" -v udp="${udp_ln:-0}" -v hasudp="$([[ -n "$udp_s" ]] && echo 1 || echo 0)" '
        NR==tcp { print ENVIRON["TCP_TEXT"]; if (!udp && hasudp) print ENVIRON["UDP_TEXT"]; next }
        NR==udp { if (hasudp) print ENVIRON["UDP_TEXT"]; next }
        {print}
    ' "$NFT_CONF" > "$candidate" || exit 1
    nft -c -f "$candidate" || { error 'nftables ruleset failed validation'; exit 1; }
    printf 'add table inet clikader_filter\ndelete table inet clikader_filter\n' > "$scoped"
    awk -v mode=table -f "$NFT_RULE_PARSER" "$candidate" >> "$scoped" || exit 1
    nft list table inet clikader_filter > "$TX_DIR/live.nft" 2>/dev/null || : > "$TX_DIR/live.nft"
    restore_filter() {
        if [[ -s "$TX_DIR/live.nft" ]]; then
            printf 'add table inet clikader_filter\ndelete table inet clikader_filter\n' > "$TX_DIR/restore.nft"
            cat "$TX_DIR/live.nft" >> "$TX_DIR/restore.nft"
            nft -f "$TX_DIR/restore.nft"
        fi
    }
    # shellcheck disable=SC2034 # Consumed by the common transaction EXIT trap.
    TX_ROLLBACK=restore_filter
    nft -c -f "$scoped" || exit 1
    nft -f "$scoped" || exit 1
    nft list table inet clikader_filter >/dev/null || exit 1
    install_config "$candidate" "$NFT_CONF" || exit 1
    systemctl enable nftables >/dev/null || exit 1
    record_managed nft "$NFT_CONF" || exit 1
    tx_commit
    log "nftables apply OK. TCP allow: ${tcp_rendered:-none}; UDP allow: ${udp_rendered:-none}"
)

# --- Actions ---
add_ports() {
    local raw="${1:-}" type="${2:-both}"
    if [[ -z "$raw" ]]; then
        subusage add
        return 1
    fi
    type="$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')"
    case "$type" in
        tcp|udp|both) ;;
        *) error "Invalid type '${type}' (use tcp, udp, or both)."; return 1 ;;
    esac

    local ports ssh_port changed=0
    ports="$(normalize_ports "$raw")" || return 1
    clikader_lock nft || return 1
    read_allow_sets
    ssh_port="$(get_ssh_port)" || return 1
    set_add tcp_ports $ssh_port

    if [[ "$type" == "both" || "$type" == "tcp" ]]; then
        set_add tcp_ports $ports
    fi
    if [[ "$type" == "both" || "$type" == "udp" ]]; then
        set_add udp_ports $ports
    fi

    if (( ! changed )); then
        log "Port(s) ${ports} already allowed (${type}); no changes."
        return 0
    fi
    rewrite_allowlist "$tcp_ports" "$udp_ports"
}

delete_ports() {
    local raw="${1:-}"
    if [[ -z "$raw" ]]; then
        subusage delete
        return 1
    fi
    local ports ssh_port changed=0 p deletable="" protected=""
    ports="$(normalize_ports "$raw")" || return 1
    clikader_lock nft || return 1
    read_allow_sets
    ssh_port="$(get_ssh_port)" || return 1
    set_add tcp_ports $ssh_port

    # Split requested ports into deletable vs the protected SSH port. The SSH
    # port is never removed; if it is mixed with other ports, the others are
    # still deleted and we report that the SSH port was left in place.
    for p in $ports; do
        if [[ " $ssh_port " == *" $p "* ]]; then
            protected+=" $p"
        else
            deletable+=" $p"
        fi
    done
    deletable="${deletable# }"

    if [[ -n "$protected" ]]; then
        error "SSH port ${ssh_port} is protected: deleting it would lock you out, so it was left in place."
    fi

    # Nothing to delete other than the protected SSH port -> refuse outright.
    if [[ -z "$deletable" ]]; then
        return 1
    fi

    set_remove tcp_ports $deletable
    set_remove udp_ports $deletable

    if (( changed )); then
        rewrite_allowlist "$tcp_ports" "$udp_ports" || return 1
        if [[ -n "$protected" ]]; then
            log "Deleted ${deletable// /, } from the allowlist; SSH port ${ssh_port} left intact."
        fi
    else
        log "None of the given port(s) are in the allowlist; no changes."
    fi
}

reset_allowlist() {
    local yes=""
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "-y" ]]; then
            yes="-y"
        else
            error "Unknown argument: $1"
            echo "Usage: clikader nft reset [-y]"
            return 1
        fi
    fi

    if [[ "$yes" != "-y" ]]; then
        read_allow_sets
        info "This removes ALL non-SSH inbound allow rules."
        echo -n "Continue? [y/N]: "
        local c
        read -r c < /dev/tty
        case "$c" in
            y|Y|yes) ;;
            *) info "Cancelled."; return 1 ;;
        esac
    fi

    clikader_lock nft || return 1
    read_allow_sets
    local ssh_port
    ssh_port="$(get_ssh_port)" || return 1
    tcp_ports="$ssh_port"
    udp_ports=""
    rewrite_allowlist "$tcp_ports" "$udp_ports" || return 1
    log "Allowlist reset; only SSH port ${ssh_port} is allowed (tcp)."
}

# --- Interactive menu ---
show_current() {
    read_allow_sets
    info "Current allowlist (${NFT_CONF}):"
    echo "  TCP: ${tcp_ports:-none}"
    echo "  UDP: ${udp_ports:-none}"
}

show_menu() {
    while true; do
        show_current
        echo ""
        echo -e "${BOLD}Choose an action:${NC}"
        echo "  1) Add ports"
        echo "  2) Delete ports"
        echo "  3) Reset allowlist"
        echo "  0) Exit"
        echo -n "Select [0-3]: "
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1|add|a)       add_prompt ;;
            2|delete|d|del) delete_prompt ;;
            3|reset|r)     reset_prompt ;;
            0|q|quit|exit|"") break ;;
            *) error "Invalid choice: ${choice}" ;;
        esac
    done
    echo ""
}

add_prompt() {
    local raw type
    echo -n "Port(s) to allow (comma/space separated): "
    read -r raw < /dev/tty
    echo -n "Type [tcp/udp/both] (default: both): "
    read -r type < /dev/tty
    if [[ -z "$type" ]]; then
        type="both"
    fi
    add_ports "$raw" "$type"
}

delete_prompt() {
    local raw
    echo -n "Port(s) to remove from allowlist (comma/space separated): "
    read -r raw < /dev/tty
    delete_ports "$raw"
}

reset_prompt() {
    reset_allowlist
}

# --- Help ---
usage() {
    cat <<EOF
Usage: clikader nft [options]
Component revision: $NFT_MANAGER_REVISION

Manage inbound ports in the clikader nftables allowlist (${NFT_CONF}).

Sub-commands:
  (none)              Interactive menu (add / delete / reset)
  add <ports> [type]  Allow inbound <ports> (comma/space separated).
                      [type] is tcp, udp or both (default: both).
  delete <ports>      Remove <ports> from the allowlist (tcp and udp).
  reset [-y]          Clear the allowlist except the SSH port; -y skips confirm.
  -h, --help          Show this help.

Examples:
  clikader nft                        Interactive menu
  clikader nft add 8080               Allow TCP+UDP inbound on 8080
  clikader nft add 8080, 8443 tcp     Allow TCP inbound on 8080 and 8443
  clikader nft delete 8080,8443       Remove 8080 and 8443 from allowlist
  clikader nft reset                  Remove all non-SSH allowed ports
  clikader nft reset -y               Same, without confirmation
EOF
}

subusage() {
    case "$1" in
        add)
            cat <<EOF
Usage: clikader nft add <ports> [type]

Add inbound ports to the nftables allowlist.
  <ports>  One or more ports, comma/space separated (e.g. "8080, 8443").
  [type]   tcp, udp or both (default: both).
EOF
            ;;
        delete)
            cat <<EOF
Usage: clikader nft delete <ports>

Remove inbound ports from the nftables allowlist (both tcp and udp).
  <ports>  One or more ports, comma/space separated (e.g. "8080, 8443").

The SSH port is protected and never deleted; if mixed with other ports, the
others are still removed and the SSH port is left in place.
EOF
            ;;
    esac
}

# --- Main ---
main() {
    local cmd="${1:-}"
    case "$cmd" in
        "")
            show_menu
            ;;
        add)
            shift
            local type=both raw="" token
            for token in "$@"; do
                case "$token" in tcp|udp|both) type="$token" ;; *) raw+=" $token" ;; esac
            done
            add_ports "$raw" "$type"
            ;;
        delete)
            shift
            delete_ports "$*"
            ;;
        reset)
            shift
            reset_allowlist "$@"
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            error "Unknown sub-command: ${cmd}"
            usage
            exit 1
            ;;
    esac
}

# Help must be reachable without root so any user can see usage.
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
    usage
    exit 0
fi

# Root check (after -h/--help so usage is visible to any user).
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Preflight: nftables tooling must be present.
if ! command -v nft &>/dev/null || ! command -v systemctl &>/dev/null; then
    error "nftables (nft) and systemd (systemctl) are required; aborting."
    exit 1
fi

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
