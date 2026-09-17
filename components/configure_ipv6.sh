#!/usr/bin/env bash
# IPv6 policy and persistent address configuration for Debian-family servers.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SYSCTL_CONFIG="${SYSCTL_CONFIG:-/etc/sysctl.d/zz-clikader-ipv6.conf}"
SYSCTL_LEGACY="${SYSCTL_LEGACY:-/etc/sysctl.conf}"
IFACES_FILE="${IFACES_FILE:-/etc/network/interfaces}"
NETPLAN_DIR="${NETPLAN_DIR:-/etc/netplan}"
NETWORKD_DIR="${NETWORKD_DIR:-/etc/systemd/network}"
IPV6_MODE=""
IPV6_ASSUME_YES=false
ADDRESS=""; INTERFACE=""; GATEWAY=""; NETPLAN_ID=""
log() { echo "--> $*"; }
info() { echo "$*"; }
warning() { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
usage() {
    cat <<'EOF'
Usage: clikader ipv6 [--enable|--disable|--status] [--yes]
       clikader ipv6 --address ADDRESS/PREFIX --interface IFACE [--gateway IPv6]
                     [--netplan-id ID]
Without options, show the interactive IPv6 Configuration Tool.
Addresses and optional default routes are persisted through Netplan,
systemd-networkd, NetworkManager or ifupdown, preserving existing addresses.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable) IPV6_MODE=enable; shift ;;
        --disable) IPV6_MODE=disable; shift ;;
        --status) IPV6_MODE=status; shift ;;
        --yes|-y) IPV6_ASSUME_YES=true; shift ;;
        --address|--interface|--gateway|--netplan-id)
            [[ $# -ge 2 ]] || { error "$1 requires a value"; exit 2; }
            case "$1" in
                --address) ADDRESS="$2"; IPV6_MODE=address ;;
                --interface) INTERFACE="$2" ;;
                --gateway) GATEWAY="$2" ;;
                --netplan-id) NETPLAN_ID="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown option: $1"; exit 2 ;;
    esac
done
[[ $EUID -eq 0 || "$IPV6_MODE" == status ]] || { error 'This script must be run as root'; exit 1; }

valid_ipv6_address() {
    local address="$1" piece count=0 compressed=0 rest
    [[ "$address" == *:* && "$address" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    if [[ "$address" == *::* ]]; then
        compressed=1
        rest="${address#*::}"
        [[ "$rest" != *::* && "$address" != *:::* ]] || return 1
    else
        [[ "$address" != :* && "$address" != *: ]] || return 1
    fi
    local pieces=()
    IFS=: read -r -a pieces <<< "$address"
    for piece in "${pieces[@]}"; do
        [[ -n "$piece" ]] || continue
        [[ ${#piece} -le 4 ]] || return 1
        count=$((count + 1))
    done
    if (( compressed )); then (( count < 8 )); else (( count == 8 )); fi
}

check_ipv6_status() {
    local disabled
    disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" || { error 'IPv6 sysctls unavailable'; return 1; }
    if [[ "$disabled" == 1 ]]; then log 'IPv6 DISABLED'; return 1; fi
    log 'IPv6 ENABLED'
    ip -6 addr show scope global
}

set_ipv6_policy() (
    local value="$1" key old
    clikader_lock ipv6 || exit 1
    tx_begin ipv6 restore_ipv6 || exit 1
    tx_save "$SYSCTL_CONFIG" "$SYSCTL_LEGACY" || exit 1
    restore_ipv6() {
        while read -r key old; do sysctl -w "$key=$old" >/dev/null || return 1; done < "$TX_DIR/live"
    }
    # Preserve each interface value, not only the all/default pseudo-interfaces.
    sysctl -a 2>/dev/null | awk '/^net.ipv6.conf\.[^.]+\.disable_ipv6 =/ {print $1,$3}' > "$TX_DIR/live"
    for key in all default lo; do
        printf 'net.ipv6.conf.%s.disable_ipv6 = %s\n' "$key" "$value"
    done > "$SYSCTL_CONFIG" || exit 1
    chmod 644 "$SYSCTL_CONFIG"
    if [[ -f "$SYSCTL_LEGACY" ]]; then
        sed -i -E 's/^([[:space:]]*net\.ipv6\.conf\.[^.]+\.disable_ipv6[[:space:]]*=)/# [clikader ipv6] \1/' "$SYSCTL_LEGACY" || exit 1
    fi
    sysctl -p "$SYSCTL_CONFIG" || exit 1
    [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "$value" ]] || { error 'IPv6 policy did not take effect'; exit 1; }
    record_managed ipv6 "$SYSCTL_CONFIG" || exit 1
    tx_commit
    if [[ "$value" == 1 ]]; then log 'IPv6 is now disabled'; else log 'IPv6 is now enabled'; fi
)
enable_ipv6() { set_ipv6_policy 0; }
disable_ipv6() {
    if [[ "$IPV6_ASSUME_YES" != true ]]; then
        local answer
        read -r -p 'Disable IPv6 on all interfaces? [y/N]: ' answer < /dev/tty || return 1
        case "$answer" in y|Y) ;; *) warning 'IPv6 disable cancelled'; return 1 ;; esac
    fi
    set_ipv6_policy 1
}

# Infer a Netplan ID from its generated backend, not necessarily the NIC name
# (match/set-name configurations often use a completely different YAML ID).
netplan_target() {
    local iface="$1" network_file="$2" connection="$3" id kind candidate
    id="$NETPLAN_ID"
    if [[ -z "$id" && "$network_file" == */10-netplan-*.network ]]; then
        id="${network_file##*/10-netplan-}"; id="${id%.network}"
    fi
    if [[ -z "$id" && "$connection" == netplan-* ]]; then id="${connection#netplan-}"; fi
    [[ -n "$id" ]] || id="$iface"
    [[ "$id" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 1
    for kind in ethernets bridges bonds vlans tunnels wifis; do
        candidate="$(netplan get "network.$kind.$id" 2>/dev/null || true)"
        if [[ -n "$candidate" && "$candidate" != null && "$candidate" != '{}' ]]; then
            printf '%s %s' "$kind" "$id"; return 0
        fi
    done
    error 'Cannot identify the existing Netplan device; supply --netplan-id.'; return 1
}

# Follow ifupdown include directives so provider stanzas in interfaces.d are
# extended in their actual file, rather than adding a duplicate inet6 stanza.
ifupdown_ipv6_file() {
    local iface="$1" file line directive pattern match index=0 seen=""
    local files=("$IFACES_FILE") words=()
    while (( index < ${#files[@]} && index < 100 )); do
        file="${files[$index]}"; index=$((index + 1))
        [[ -f "$file" && "$seen" != *"|$file|"* ]] || continue
        seen+="|$file|"
        if awk -v iface="$iface" '$1=="iface" && $2==iface && $3=="inet6" {found=1} END {exit !found}' "$file"; then
            printf '%s' "$file"; return
        fi
        while IFS= read -r line; do
            line="${line%%#*}"
            read -r -a words <<< "$line"
            directive="${words[0]:-}"
            case "$directive" in source|source-directory) ;; *) continue ;; esac
            for pattern in "${words[@]:1}"; do
                [[ "$pattern" == /* ]] || pattern="$(dirname "$file")/$pattern"
                [[ "$directive" != source-directory ]] || pattern+='/*'
                while IFS= read -r match; do
                    if [[ "$directive" == source-directory && ! "${match##*/}" =~ ^[a-zA-Z0-9_-]+$ ]]; then continue; fi
                    files+=("$match")
                done < <(compgen -G "$pattern" || true)
            done
        done < "$file"
    done
    printf '%s' "$IFACES_FILE"
}

persist_ipv6_address() (
    local iface="$1" address="$2" gateway="${3:-}" host prefix network_file connection uuid file key
    local old_addresses="" old_gateway="" old_method=""
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { error 'Invalid interface name'; exit 1; }
    host="${address%/*}"; prefix="${address##*/}"
    valid_ipv6_address "$host" || { error 'Invalid IPv6 address format'; exit 1; }
    [[ "$address" == */* && "$prefix" =~ ^[0-9]{1,3}$ ]] && (( 10#$prefix >= 1 && 10#$prefix <= 128 )) || { error 'Invalid IPv6 prefix length'; exit 1; }
    [[ -z "$gateway" ]] || valid_ipv6_address "$gateway" || { error 'Invalid IPv6 gateway'; exit 1; }
    ip link show dev "$iface" >/dev/null || exit 1
    [[ "$(sysctl -n "net.ipv6.conf.$iface.disable_ipv6")" == 0 ]] || { error 'Enable IPv6 before adding an address'; exit 1; }
    clikader_lock ipv6 || exit 1
    network_file="$(LC_ALL=C networkctl status "$iface" --no-pager 2>/dev/null | sed -n 's/^[[:space:]]*Network File: //p' || true)"
    connection="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
    uuid="$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null || true)"
    key="$(printf '%s' "$iface/$address" | sha256sum | cut -c1-16)"
    local existed=0 route_before backend
    ip -o -6 addr show dev "$iface" | grep -qF " $address " && existed=1
    route_before="$(ip -6 route show default dev "$iface")"
    restore_address() {
        (( existed )) || ip -6 addr del "$address" dev "$iface" 2>/dev/null || true
        if [[ -n "$gateway" ]]; then
            ip -6 route del default via "$gateway" dev "$iface" 2>/dev/null || true
            local route words
            while IFS= read -r route; do
                [[ -n "$route" ]] || continue
                read -r -a words <<< "$route"
                ip -6 route replace "${words[@]}" || return 1
            done <<< "$route_before"
        fi
        case "${backend:-}" in
            netplan) netplan generate ;;
            networkd) networkctl reload ;;
            nm) nmcli connection modify "$uuid" ipv6.addresses "$old_addresses" ipv6.gateway "$old_gateway" ipv6.method "$old_method" ;;
        esac
    }
    tx_begin ipv6-address restore_address || exit 1
    if [[ -d "$NETPLAN_DIR" ]] && compgen -G "$NETPLAN_DIR/*.yaml" >/dev/null; then
        backend=netplan
        local target kind id
        target="$(netplan_target "$iface" "$network_file" "$connection")" || exit 1
        read -r kind id <<< "$target"
        file="$NETPLAN_DIR/90-clikader-$key.yaml"
        tx_save "$file" || exit 1
        printf 'network:\n  version: 2\n  %s:\n    %s:\n      addresses: ["%s"]\n' "$kind" "$id" "$address" > "$file" || exit 1
        if [[ -n "$gateway" ]]; then
            printf '      routes:\n        - to: "::/0"\n          via: "%s"\n          on-link: true\n' "$gateway" >> "$file"
        fi
        chmod 600 "$file"
        netplan generate || exit 1
    elif [[ -n "$uuid" && "$uuid" != -- ]]; then
        old_addresses="$(nmcli -g ipv6.addresses connection show "$uuid")" || exit 1
        old_gateway="$(nmcli -g ipv6.gateway connection show "$uuid")" || exit 1
        old_method="$(nmcli -g ipv6.method connection show "$uuid")" || exit 1
        backend="nm"
        nmcli connection modify "$uuid" +ipv6.addresses "$address" || exit 1
        case "$old_method" in disabled|ignore) nmcli connection modify "$uuid" ipv6.method manual || exit 1 ;; esac
        [[ -z "$gateway" ]] || nmcli connection modify "$uuid" ipv6.gateway "$gateway" || exit 1
        file="$CLIKADER_STATE_DIR/nm-ipv6-$key.conf"
        tx_save "$file" || exit 1
        printf 'uuid=%s\naddress=%s\ngateway=%s\n' "$uuid" "$address" "$gateway" > "$file"
    elif [[ "$network_file" == /*.network ]]; then
        backend=networkd
        file="$NETWORKD_DIR/$(basename "$network_file").d/90-clikader-$key.conf"
        tx_save "$file" || exit 1
        mkdir -p "$(dirname "$file")" || exit 1
        printf '[Address]\nAddress=%s\n' "$address" > "$file"
        if [[ -n "$gateway" ]]; then printf '\n[Route]\nDestination=::/0\nGateway=%s\nGatewayOnLink=yes\n' "$gateway" >> "$file"; fi
        chmod 644 "$file"
        networkctl reload || exit 1
    elif [[ -f "$IFACES_FILE" ]]; then
        backend=interfaces
        file="$(ifupdown_ipv6_file "$iface")" || exit 1
        tx_save "$file" || exit 1
        # ifupdown permits multiple iface stanzas. Use the existing IPv6
        # method when present and append only owned up/down hooks.
        if ! grep -qF "# clikader IPv6 $key" "$file"; then
            printf '    # clikader IPv6 %s\n    up ip -6 addr replace %s dev %s\n    down ip -6 addr del %s dev %s || true\n' \
                "$key" "$address" "$iface" "$address" "$iface" > "$TX_DIR/hooks"
            if [[ -n "$gateway" ]]; then printf '    up ip -6 route replace default via %s dev %s onlink\n' "$gateway" "$iface" >> "$TX_DIR/hooks"; fi
            awk -v dev="$iface" -v hooks="$TX_DIR/hooks" '
                {print}
                !added && $1=="iface" && $2==dev && $3=="inet6" {while ((getline line < hooks)>0) print line; close(hooks); added=1}
                END {if (!added) {print "\nauto " dev "\niface " dev " inet6 manual"; while ((getline line < hooks)>0) print line}}
            ' "$file" > "$TX_DIR/interfaces" || exit 1
            cat "$TX_DIR/interfaces" > "$file" || exit 1
        fi
    else
        error 'No supported network manager found; no temporary-only configuration was applied.'; exit 1
    fi
    # Apply only the IPv6 addition live; avoid restarting the NIC or touching
    # its IPv4 settings. The native configuration supplies reboot persistence.
    ip -6 addr replace "$address" dev "$iface" || exit 1
    [[ -z "$gateway" ]] || ip -6 route replace default via "$gateway" dev "$iface" onlink || exit 1
    local _attempt healthy=0
    for _attempt in 1 2 3 4 5; do
        if ip -o -6 addr show dev "$iface" | grep -F " $address " | grep -qvE 'tentative|dadfailed'; then healthy=1; break; fi
        sleep 1
    done
    (( healthy )) || { error 'IPv6 address failed duplicate-address detection/verification'; exit 1; }
    record_managed "ipv6-address-$key" "$file" || exit 1
    tx_commit
    log "IPv6 address added successfully and persisted ($backend): $address on $iface"
)

configure_ipv6_address() {
    local interfaces=() iface choice address gateway=""
    while IFS= read -r iface; do interfaces+=("$iface"); done < <(ip -o link show | awk -F': ' '$2!="lo" {sub(/@.*/,"",$2); print $2}')
    (( ${#interfaces[@]} )) || { error 'No network interfaces found'; return 1; }
    local i
    for i in "${!interfaces[@]}"; do echo "$((i+1))) ${interfaces[$i]}"; done
    read -r -p 'Interface number: ' choice < /dev/tty || return 1
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#interfaces[@]} )) || { error 'Invalid interface selection'; return 1; }
    iface="${interfaces[$((choice-1))]}"
    read -r -p 'IPv6 address/prefix: ' address < /dev/tty || return 1
    [[ -n "$address" ]] || { error 'IPv6 address cannot be empty'; return 1; }
    [[ "$address" == */* ]] || address+='/64'
    read -r -p 'Default IPv6 gateway (blank to preserve routing): ' gateway < /dev/tty || return 1
    persist_ipv6_address "$iface" "$address" "$gateway"
}

show_menu() {
    echo 'IPv6 Configuration Tool'
    check_ipv6_status || true
    printf '1) Enable IPv6\n2) Disable IPv6\n3) Configure IPv6 address\n4) Check status\n0) Exit\n'
}
main() {
    case "$IPV6_MODE" in
        enable) enable_ipv6 ;;
        disable) disable_ipv6 ;;
        status) check_ipv6_status ;;
        address)
            [[ -n "$INTERFACE" ]] || { error '--interface is required'; return 2; }
            persist_ipv6_address "$INTERFACE" "$ADDRESS" "$GATEWAY" ;;
        *)
            show_menu
            local choice
            read -r -p 'Choice: ' choice < /dev/tty || return 1
            case "$choice" in 1) enable_ipv6 ;; 2) disable_ipv6 ;; 3) configure_ipv6_address ;; 4) check_ipv6_status ;; 0) log 'Exiting...' ;; *) error 'Invalid choice'; return 1 ;; esac
            ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
