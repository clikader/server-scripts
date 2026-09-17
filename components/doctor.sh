#!/usr/bin/env bash
# Read-only host health and desired-state checks. JSON needs jq, never installs it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

json=0
for arg in "$@"; do
    case "$arg" in
        --json) json=1 ;;
        --help|-h) echo 'Usage: clikader doctor [--json]. Exit 0: healthy; 1: warning/failure; 2: usage/dependency error.'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
if ! command -v jq >/dev/null; then echo 'doctor requires jq (installed by clikader setup)' >&2; exit 2; fi

results=()
overall=0
check_result() {
    local name="$1" state="$2" detail="$3"
    results+=("$(jq -cn --arg name "$name" --arg status "$state" --arg detail "$detail" '{name:$name,status:$status,detail:$detail}')")
    [[ "$state" == ok || "$state" == info ]] || overall=1
}

main() {
    local output service record path count available used
    if [[ $EUID -ne 0 ]]; then check_result privileges warning 'Run as root for SSH, firewall, and journal checks'; fi
    if output="$(systemctl --failed --no-legend --plain 2>&1)"; then
        if [[ -z "$output" ]]; then check_result services ok 'No failed systemd units'; else check_result services fail "$output"; fi
    else check_result services fail "$output"; fi
    for service in ssh chrony; do
        if systemctl is-active --quiet "$service"; then check_result "$service" ok active
        else check_result "$service" warning inactive; fi
    done
    if output="$(timeout 10 getent ahostsv4 example.com 2>&1)" && [[ -n "$output" ]]; then
        check_result dns ok 'System resolver answered example.com'
    else check_result dns fail 'System name resolution failed'; fi
    if [[ -f "$CLIKADER_STATE_DIR/managed/dns.sha256" ]]; then
        if resolvectl query example.com >/dev/null 2>&1; then check_result resolved ok 'Managed resolver answers'
        else check_result resolved fail 'Managed resolver cannot answer'; fi
    fi
    if [[ -f "$CLIKADER_STATE_DIR/managed/unbound.sha256" ]]; then
        output="$(timeout 10 dig +short +tries=1 +time=3 @127.0.0.1 example.com A 2>/dev/null)"
        if grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$output"; then check_result unbound ok 'Local recursive resolver answers'
        else check_result unbound fail 'Local recursive resolver cannot answer'; fi
    fi
    if output="$(sshd -T 2>&1)"; then
        local port listeners
        listeners="$(ss -H -ltnp 2>/dev/null)"
        while read -r port; do
            if awk -v p="$port" '/sshd|"systemd"/ {n=split($4,a,":"); if(a[n]==p) found=1} END {exit !found}' <<< "$listeners"; then
                check_result "ssh:$port" ok listening
            else check_result "ssh:$port" fail 'Configured SSH port is not listening'; fi
        done < <(awk '$1=="port" {print $2}' <<< "$output")
    else check_result ssh-config fail "$output"; fi
    if [[ -f "$CLIKADER_STATE_DIR/managed/nft.sha256" ]]; then
        if output="$(nft -j list table inet clikader_filter 2>&1)"; then
            if jq -e '.nftables[] | .chain? | select(.name=="input" and .policy=="drop")' <<< "$output" >/dev/null; then
                check_result firewall ok 'Managed input policy is drop'
            else check_result firewall fail 'Managed input drop policy missing'; fi
            local protocol ports live_port live_ports expected_line
            for protocol in tcp udp; do
                expected_line="$(awk -f "$(dirname "${BASH_SOURCE[0]}")/../lib/nft_rules.awk" "${NFT_CONF:-/etc/nftables.conf}" 2>/dev/null | awk -F'\t' -v p="$protocol" '$2==p {print $3; exit}')"
                ports="$(sed -n 's/.*{\([^}]*\)}.*/\1/p' <<< "$expected_line" | tr ',' ' ')"
                live_ports="$(jq -r --arg p "$protocol" '
                    .nftables[] | .rule? | select(.chain=="input") |
                    select(any(.expr[]; has("accept"))) | .expr[] | .match? |
                    select(.left.payload.protocol==$p and .left.payload.field=="dport") |
                    .right | if type=="number" then . elif type=="object" and has("set") then .set[] else empty end
                ' <<< "$output" 2>/dev/null)"
                for live_port in $ports; do
                    [[ "$live_port" =~ ^[0-9]+$ ]] || continue
                    if ! grep -qxF "$live_port" <<< "$live_ports"; then
                        check_result "firewall:$protocol:$live_port" fail 'Persisted allow port is absent from the running firewall'
                    fi
                done
            done
        else check_result firewall fail "$output"; fi
    fi
    if [[ -f "$CLIKADER_STATE_DIR/managed/fail2ban.sha256" ]]; then
        if output="$(fail2ban-client status sshd 2>&1)"; then check_result fail2ban ok "$output"
        else check_result fail2ban fail "$output"; fi
    fi
    for record in "$CLIKADER_STATE_DIR/managed/"*.sha256; do
        [[ -f "$record" ]] || continue
        if output="$(sha256sum --check "$record" 2>&1)"; then check_result "config:$(basename "$record" .sha256)" ok unchanged
        else check_result "config:$(basename "$record" .sha256)" warning "$output"; fi
    done
    path="${IPV6_POLICY_FILE:-/etc/sysctl.d/zz-clikader-ipv6.conf}"
    if [[ -f "$path" ]]; then
        local ipv6_expected ipv6_actual
        ipv6_expected="$(awk -F= '/^net.ipv6.conf.all.disable_ipv6/ {gsub(/ /,"",$2); print $2}' "$path")"
        ipv6_actual="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
        if [[ "$ipv6_expected" != "$ipv6_actual" ]]; then
            check_result ipv6 warning "expected disable_ipv6=$ipv6_expected; actual=$ipv6_actual"
        else check_result ipv6 ok "disable_ipv6=$ipv6_actual"; fi
    fi
    # Compare live sysctls to the persisted desired values, not freshly
    # recalculated floors that could incorrectly describe drift as healthy.
    path="${TCP_DROPIN:-/etc/sysctl.d/zz-clikader-tcp.conf}"
    if [[ -f "$path" ]]; then
        local key desired actual
        while IFS='=' read -r key desired; do
            key="$(xargs <<< "$key")"; desired="$(xargs <<< "$desired")"
            [[ -n "$key" && "$key" != \#* ]] || continue
            actual="$(sysctl -n "$key" 2>/dev/null | xargs)"
            if [[ "$actual" != "$desired" ]]; then check_result "sysctl:$key" warning "expected=$desired actual=$actual"; fi
        done < "$path"
    fi
    while read -r used path; do
        [[ "$used" =~ ^[0-9]+$ ]] || continue
        if (( used >= 90 )); then check_result "disk:$path" warning "$used% used"
        else check_result "disk:$path" ok "$used% used"; fi
    done < <(df -P -x tmpfs -x devtmpfs | awk 'NR>1 {gsub(/%/,"",$5); print $5,$6}')
    used="$(df -Pi / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    if [[ "$used" =~ ^[0-9]+$ ]] && (( used >= 90 )); then check_result inodes warning "$used% used on /"; fi
    available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    if [[ "$available" =~ ^[0-9]+$ ]] && (( available < 65536 )); then check_result memory warning "${available}KiB available"; fi
    if [[ -f "${REBOOT_REQUIRED_FILE:-/var/run/reboot-required}" ]]; then check_result reboot warning 'Reboot pending; automatic reboots are disabled'
    else check_result reboot ok 'No reboot marker'; fi
    # Debian does not consistently write Ubuntu's reboot-required marker.
    local image newest="" running
    running="$(uname -r)"
    for image in "${BOOT_DIR:-/boot}/"vmlinuz-*; do
        [[ -f "$image" ]] || continue
        newest+="${image##*/vmlinuz-}"$'\n'
    done
    newest="$(printf '%s' "$newest" | sort -V | tail -1)"
    if [[ -n "$newest" && "$newest" != "$running" && "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -1)" == "$newest" ]]; then
        check_result kernel warning "Installed kernel $newest is newer than running $running; verify bootloader and schedule a reboot"
    fi
    if output="$(apt-get -s upgrade 2>&1)"; then
        count="$(grep -c '^Inst ' <<< "$output" || true)"
        if (( count > 0 )); then check_result updates warning "$count pending packages (cached indexes)"
        else check_result updates ok 'No pending package upgrades in cached indexes'; fi
    else check_result updates warning "$output"; fi
    output="$(apt-config dump 2>/dev/null)"
    if grep -q 'Unattended-Upgrade::Automatic-Reboot "true"' <<< "$output"; then check_result automatic-reboot fail enabled; fi
    if grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<< "$output" && systemctl is-active --quiet apt-daily-upgrade.timer; then
        check_result security-updates ok 'Unattended security updates enabled'
    else check_result security-updates warning 'Unattended security updates are not active'; fi
    if (( json )); then
        printf '%s\n' "${results[@]}" | jq -s --argjson healthy "$([[ "$overall" == 0 ]] && echo true || echo false)" '{healthy:$healthy,checks:.}'
    else
        printf '%s\n' "${results[@]}" | jq -r '. | "[\(.status)] \(.name): \(.detail)"'
    fi
    return "$overall"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
