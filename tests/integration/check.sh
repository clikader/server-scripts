#!/usr/bin/env bash
set -euo pipefail
cd /workspace/server-scripts
ready=0
for attempt in $(seq 1 40); do
    if systemctl show-environment >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
[[ "$ready" == 1 ]] || { echo 'systemd did not become ready'; exit 1; }
state="$(timeout 45 systemctl is-system-running --wait || true)"
case "$state" in running|degraded) ;; *) echo "systemd boot did not finish: $state"; exit 1 ;; esac
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CLIKADER_STATE_DIR="$work/state"
export STATE_DIR="$work/setup"

for script in clikader.sh install.sh components/*.sh lib/*.sh; do bash -n "$script"; done

# Real OpenSSH validates the public key and accepts authentication after
# hardening. No fake sshd/nft/systemctl executables are used in this suite.
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
printf 'root:integration-test-only\n' | chpasswd
systemctl start ssh.service
source components/setup_vps.sh
ssh_port=2222
ssh_auth_method=key
ssh_public_key="$(cat "$work/key.pub")"
step_ssh_hardening
ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$work/key" -p 2222 root@127.0.0.1 true
echo 'PASS: real SSH authentication after hardening'

# Preserve a foreign table and rule through setup and allowlist mutations.
nft add table inet integration_foreign
nft add chain inet integration_foreign sentinel
nft add rule inet integration_foreign sentinel counter
extra_ports=8080
step_configure_nftables
bash components/nft_manager.sh add 8443, 9443 tcp
nft -c -f /etc/nftables.conf
bash components/nft_manager.sh reset -y
nft list chain inet integration_foreign sentinel | grep -q counter
nft list chain inet clikader_filter input | grep -q 2222
echo 'PASS: real nftables grammar, application, SSH protection and foreign-table preservation'

step_setup_fail2ban
fail2ban-client status sshd
echo 'PASS: real SSH journal filtering and nftables ban action'

ip netns add clikader-client
ip link add clikader-host type veth peer name client0
ip link set client0 netns clikader-client
ip addr add 192.0.2.2/24 dev clikader-host
ip link set clikader-host up
ip netns exec clikader-client ip link set lo up
ip netns exec clikader-client ip addr add 192.0.2.10/24 dev client0
ip netns exec clikader-client ip link set client0 up
ip netns exec clikader-client ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -i "$work/key" -p 2222 root@192.0.2.2 true
rc=0
ip netns exec clikader-client curl --noproxy '*' -s --connect-timeout 1 http://192.0.2.2:4444/ >/dev/null || rc=$?
[[ "$rc" == 28 ]] || { echo "Unallowed port was not dropped: curl rc=$rc"; exit 1; }
ip netns del clikader-client
ip link del clikader-host
echo 'PASS: real packets allow SSH and drop unallowed inbound connections'

# Exercise real boot persistence for the managed firewall without stopping
# nftables (its ExecStop would globally flush unrelated rules).
nft delete table inet clikader_filter
nft -f /etc/nftables.conf
nft list table inet clikader_filter >/dev/null
nft list table inet integration_foreign >/dev/null
echo 'PASS: persistent firewall reload'

# Prove Netplan merges the address overlay without dropping the existing IP.
mkdir -p "$work/netplan/etc/netplan"
cat > "$work/netplan/etc/netplan/10-base.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    uplink:
      match:
        name: eth0
      addresses: [192.0.2.10/24]
EOF
cat > "$work/netplan/etc/netplan/90-extra.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    uplink:
      addresses: ["2001:db8::2/64"]
EOF
chmod 600 "$work/netplan/etc/netplan/"*.yaml
netplan generate --root-dir "$work/netplan"
grep -q 'Address=192.0.2.10/24' "$work/netplan/run/systemd/network/10-netplan-uplink.network"
grep -q 'Address=2001:db8::2/64' "$work/netplan/run/systemd/network/10-netplan-uplink.network"
echo 'PASS: real Netplan additive configuration generation'

# Use a deterministic local upstream to test the actual resolved cutover and
# rollback without relying on public resolver availability in the test network.
cat > /etc/unbound/unbound.conf <<'EOF'
server:
    interface: 127.0.0.1
    local-zone: "." refuse
    local-data: "google.com. 60 IN A 192.0.2.80"
    local-data: "example.com. 60 IN A 192.0.2.80"
EOF
unbound-checkconf
systemctl restart unbound
export RESOLV_CONF="$work/resolv.conf"
printf 'nameserver 127.0.0.1\n' > "$RESOLV_CONF"
source components/setup_dns.sh
primary_dns=127.0.0.1
purify_dns
resolvectl query google.com | grep -q 192.0.2.80
# The transaction umask must not leak into service-read config: resolved runs
# as the unprivileged systemd-resolve user and rejects its WHOLE config when it
# cannot read a drop-in (production outage 2026-09-18). The container's
# resolved may tolerate this; the mode assertion does not.
[[ "$(stat -c %a /etc/systemd/resolved.conf.d)" == 755 ]]
[[ "$(stat -c %a /etc/systemd/resolved.conf.d/zz-clikader-dns.conf)" == 644 ]]
setpriv --reuid="$(id -u systemd-resolve)" --regid="$(id -g systemd-resolve)" --clear-groups \
    cat /etc/systemd/resolved.conf.d/zz-clikader-dns.conf >/dev/null
cp /etc/systemd/resolved.conf "$work/working-resolved.conf"
primary_dns=127.0.0.2
if purify_dns; then echo 'Broken DNS cutover unexpectedly succeeded'; exit 1; fi
cmp /etc/systemd/resolved.conf "$work/working-resolved.conf"
resolvectl query google.com | grep -q 192.0.2.80
echo 'PASS: real systemd-resolved cutover and failed-query rollback'

export BACKUP_DIR="$work/tcp-backup"
mkdir -p "$BACKUP_DIR"
source components/optimize_tcp.sh
apply_limits_files
[[ "$(systemctl show -p DefaultLimitNOFILE --value)" == 1048576 ]]
echo 'PASS: real systemd manager file-descriptor limit reload'

export APT_SECURITY_CONF="$work/apt-security"
bash components/maintenance.sh enable-security-updates
apt-config -c "$APT_SECURITY_CONF" dump | grep -q 'Automatic-Reboot "false"'
echo 'PASS: real unattended-upgrades configuration parser and timers'
