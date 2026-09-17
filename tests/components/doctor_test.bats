#!/usr/bin/env bats
load ../test_helper
setup() {
    setup_mocks
    make_mock systemctl
    make_mock getent --out '192.0.2.1 STREAM example.com'
    make_mock sshd --out 'port 2222'
    make_mock ss --out 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
    make_mock apt-get
    make_mock apt-config --out $'APT::Periodic::Unattended-Upgrade "1";\nUnattended-Upgrade::Automatic-Reboot "false";'
    make_mock df --out $'Filesystem blocks Used Available Capacity Mounted\n/dev/root 100 10 90 10% /'
    export TCP_DROPIN="$BATS_TEST_TMPDIR/tcp.conf"
    export REBOOT_REQUIRED_FILE="$BATS_TEST_TMPDIR/reboot-required"
    export BOOT_DIR="$BATS_TEST_TMPDIR/boot"
    export IPV6_POLICY_FILE="$BATS_TEST_TMPDIR/ipv6.conf"
}

@test "doctor JSON is machine readable and does not mutate managed configuration" {
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 0 ]
    jq -e '.healthy == true and (.checks|length > 4)' <<< "$output"
    [ ! -e "$CLIKADER_STATE_DIR" ]
    ! grep -qE 'apt-get.* update|sysctl -w|systemctl restart' "$MOCK_CFG_DIR/calls"
}

@test "doctor returns nonzero for DNS failure" {
    make_mock getent --status 2
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="dns" and .status=="fail")' <<< "$output"
}

@test "doctor reports drift and pending reboots" {
    source "$REPO_ROOT/lib/common.sh"
    printf original > "$BATS_TEST_TMPDIR/config"
    record_managed example "$BATS_TEST_TMPDIR/config"
    printf changed > "$BATS_TEST_TMPDIR/config"
    touch "$REBOOT_REQUIRED_FILE"
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="config:example" and .status=="warning")' <<< "$output"
    jq -e '.checks[] | select(.name=="reboot" and .status=="warning")' <<< "$output"
}

@test "doctor checks actual SSH listeners rather than config alone" {
    make_mock ss
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="ssh:2222" and .status=="fail")' <<< "$output"
}

@test "doctor detects a missing live allow rule despite an unchanged configuration file" {
    source "$REPO_ROOT/lib/common.sh"
    export NFT_CONF="$BATS_TEST_TMPDIR/nftables.conf"
    printf 'table inet clikader_filter {\n chain input {\n tcp dport { 2222, 443 } accept\n }\n}\n' > "$NFT_CONF"
    record_managed nft "$NFT_CONF"
    make_mock nft --out '{"nftables":[{"chain":{"name":"input","policy":"drop"}},{"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":2222}},{"accept":null}]}}]}'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="firewall:tcp:443" and .status=="fail")' <<< "$output"
    jq -e '.checks[] | select(.name=="config:nft" and .status=="ok")' <<< "$output"
}

@test "doctor reports recursive DNS errors instead of accepting diagnostic text as an answer" {
    source "$REPO_ROOT/lib/common.sh"
    printf config > "$BATS_TEST_TMPDIR/unbound.conf"
    record_managed unbound "$BATS_TEST_TMPDIR/unbound.conf"
    make_mock dig --out ';; communications error: timed out' --status 9
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="unbound" and .status=="fail")' <<< "$output"
}

@test "doctor detects IPv6 policy drift and a newer installed Debian kernel" {
    mkdir "$BOOT_DIR"
    touch "$BOOT_DIR/vmlinuz-6.2.1"
    make_mock uname --out 6.1.1
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$IPV6_POLICY_FILE"
    make_mock sysctl --out 0
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="ipv6" and .status=="warning")' <<< "$output"
    jq -e '.checks[] | select(.name=="kernel" and .status=="warning")' <<< "$output"
}

@test "doctor reports pending packages without refreshing indexes" {
    make_mock apt-get --out 'Inst example-package [1] (2 Debian:13/stable)'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="updates" and .status=="warning")' <<< "$output"
    ! grep -q 'apt-get.* update' "$MOCK_CFG_DIR/calls"
}

@test "doctor detects an sshd port the persisted firewall allowlist does not cover" {
    source "$REPO_ROOT/lib/common.sh"
    export NFT_CONF="$BATS_TEST_TMPDIR/nftables.conf"
    printf 'table inet clikader_filter {\n chain input {\n tcp dport { 2222 } accept\n }\n}\n' > "$NFT_CONF"
    record_managed nft "$NFT_CONF"
    make_mock nft --out '{"nftables":[{"chain":{"name":"input","policy":"drop"}},{"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":2222}},{"accept":null}]}}]}'
    make_mock sshd --out $'port 2222\nport 14419'
    make_mock ss --out $'LISTEN 0 128 0.0.0.0:2222 users:(("sshd",pid=1,fd=3))\nLISTEN 0 128 0.0.0.0:14419 users:(("sshd",pid=1,fd=4))'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="firewall:ssh:14419" and .status=="fail")' <<< "$output"
}

@test "doctor accepts allow ports covered by a live range rule" {
    source "$REPO_ROOT/lib/common.sh"
    export NFT_CONF="$BATS_TEST_TMPDIR/nftables.conf"
    printf 'table inet clikader_filter {\n chain input {\n tcp dport { 2222, 443 } accept\n }\n}\n' > "$NFT_CONF"
    record_managed nft "$NFT_CONF"
    make_mock nft --out '{"nftables":[{"chain":{"name":"input","policy":"drop"}},{"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[{"range":[100,500]},2222]}}},{"accept":null}]}}]}'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    jq -e '([.checks[] | select(.name=="firewall:tcp:443")] | length) == 0' <<< "$output"
}

@test "doctor warns when the fail2ban sshd jail watches a port sshd no longer uses" {
    source "$REPO_ROOT/lib/common.sh"
    export FAIL2BAN_JAIL="$BATS_TEST_TMPDIR/jail.local"
    printf '[sshd]\nport = 22\n' > "$FAIL2BAN_JAIL"
    record_managed fail2ban "$FAIL2BAN_JAIL"
    make_mock fail2ban-client --out 'Status for the jail: sshd'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="fail2ban-port" and .status=="warning")' <<< "$output"
}

@test "doctor warns when per-link DNS servers shadow the managed resolver" {
    source "$REPO_ROOT/lib/common.sh"
    printf config > "$BATS_TEST_TMPDIR/resolved.conf"
    record_managed dns "$BATS_TEST_TMPDIR/resolved.conf"
    make_mock resolvectl --out $'Global\n\tProtocols: -LLMNR -mDNS\n\nLink 2 (eth0)\n\tDNS Servers: 8.8.8.8'
    run bash "$REPO_ROOT/components/doctor.sh" --json
    [ "$status" -eq 1 ]
    jq -e '.checks[] | select(.name=="per-link-dns" and .status=="warning")' <<< "$output"
}
