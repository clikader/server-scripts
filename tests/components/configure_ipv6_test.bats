#!/usr/bin/env bats
load ../test_helper

setup() {
    setup_mocks
    export SYSCTL_CONFIG="$BATS_TEST_TMPDIR/ipv6.conf"
    export SYSCTL_LEGACY="$BATS_TEST_TMPDIR/sysctl.conf"
    export IFACES_FILE="$BATS_TEST_TMPDIR/interfaces"
    export NETPLAN_DIR="$BATS_TEST_TMPDIR/netplan"
    export NETWORKD_DIR="$BATS_TEST_TMPDIR/networkd"
    printf 'auto eth0\niface eth0 inet dhcp\n' > "$IFACES_FILE"
    printf '0\n' > "$MOCK_CFG_DIR/disabled"
    make_mock sleep
    make_mock nmcli --status 1
    make_mock networkctl --status 1
    cat > "$MOCK_BIN/sysctl" <<'MOCK'
#!/bin/bash
printf 'sysctl %s\n' "$*" >> "$MOCK_CFG_DIR/calls"
case "$1" in
    -n) cat "$MOCK_CFG_DIR/disabled" ;;
    -a) printf 'net.ipv6.conf.all.disable_ipv6 = %s\n' "$(cat "$MOCK_CFG_DIR/disabled")" ;;
    -p) [[ -f "$MOCK_CFG_DIR/nowrite" ]] || awk -F'=' '/conf.all.disable_ipv6/ {gsub(/ /,"",$2); print $2}' "$2" > "$MOCK_CFG_DIR/disabled" ;;
    -w) printf '%s\n' "${2#*=}" > "$MOCK_CFG_DIR/disabled" ;;
esac
exit 0
MOCK
    cat > "$MOCK_BIN/ip" <<'MOCK'
#!/bin/bash
printf 'ip %s\n' "$*" >> "$MOCK_CFG_DIR/calls"
case "$*" in
    '-o link show') echo '2: eth0: <UP> mtu 1500' ;;
    *'addr show'*) cat "$MOCK_CFG_DIR/addresses" 2>/dev/null || true ;;
    '-6 addr replace '*)
        [[ ! -f "$MOCK_CFG_DIR/ip-fail" ]] || exit 1
        printf '2: eth0 inet6 %s scope global\n' "$4" > "$MOCK_CFG_DIR/addresses" ;;
    '-6 addr del '*) rm -f "$MOCK_CFG_DIR/addresses" ;;
esac
MOCK
    chmod +x "$MOCK_BIN/sysctl" "$MOCK_BIN/ip"
    load_component components/configure_ipv6.sh
}

@test "IPv6 parser accepts compressed addresses and rejects malformed values" {
    local address
    for address in ::1 2001:db8::2 fe80::1 2001:db8:1:2:3:4:5:6; do
        run valid_ipv6_address "$address"
        [ "$status" -eq 0 ]
    done
    for address in 1234 2001:::1 2001::2::3 2001:db8:1 12345::1 :1:2:3:4:5:6:7 1:2:3:4:5:6:7:; do
        run valid_ipv6_address "$address"
        [ "$status" -ne 0 ]
    done
}

@test "help is non-root and unknown flags are rejected without changes" {
    run setpriv --reuid=65534 --regid=65534 --clear-groups bash "$REPO_ROOT/components/configure_ipv6.sh" --help
    [ "$status" -eq 0 ]
    run bash "$REPO_ROOT/components/configure_ipv6.sh" --nope
    [ "$status" -eq 2 ]
    [ ! -f "$SYSCTL_CONFIG" ]
}

@test "enable persists policy without restarting IPv4 networking" {
    printf 'net.ipv6.conf.all.disable_ipv6=1\nother.setting=7\n' > "$SYSCTL_LEGACY"
    run enable_ipv6
    [ "$status" -eq 0 ]
    assert_file_contains "$SYSCTL_CONFIG" 'disable_ipv6 = 0'
    assert_file_contains "$SYSCTL_LEGACY" 'other.setting=7'
    ! grep -q 'restart' "$MOCK_CFG_DIR/calls"
}

@test "disable applies and persists the requested policy" {
    IPV6_ASSUME_YES=true
    run disable_ipv6
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_CFG_DIR/disabled")" = 1 ]
    assert_file_contains "$SYSCTL_CONFIG" 'disable_ipv6 = 1'
}

@test "failed sysctl verification restores previous files" {
    printf 'previous config\n' > "$SYSCTL_CONFIG"
    touch "$MOCK_CFG_DIR/nowrite"
    IPV6_ASSUME_YES=true
    run disable_ipv6
    [ "$status" -eq 1 ]
    assert_file_contains "$SYSCTL_CONFIG" 'previous config'
}

@test "interactive disable defaults to cancelling" {
    inner="$(make_inner components/configure_ipv6.sh disable_ipv6)"
    run_pty "$inner" ''
    [ "$PTY_RC" -eq 1 ]
    [ ! -e "$SYSCTL_CONFIG" ]
}

@test "ifupdown persists another address inside the existing static stanza" {
    printf 'auto eth0\niface eth0 inet6 static\n    address 2001:db8::1/64\n' > "$IFACES_FILE"
    run persist_ipv6_address eth0 2001:db8::2/64 fe80::1
    [ "$status" -eq 0 ]
    [ "$(grep -c '^iface eth0 inet6' "$IFACES_FILE")" -eq 1 ]
    assert_file_contains "$IFACES_FILE" 'address 2001:db8::1/64'
    assert_file_contains "$IFACES_FILE" 'up ip -6 addr replace 2001:db8::2/64'
    assert_file_contains "$IFACES_FILE" 'route replace default via fe80::1'
}

@test "persistent address application is idempotent" {
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 0 ]
    before="$(cat "$IFACES_FILE")"
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 0 ]
    [ "$(cat "$IFACES_FILE")" = "$before" ]
}

@test "ifupdown follows provider include files without creating a duplicate stanza" {
    mkdir "$BATS_TEST_TMPDIR/interfaces.d"
    printf 'source interfaces.d/*\n' > "$IFACES_FILE"
    printf 'auto eth0\niface eth0 inet6 static\n    address 2001:db8::1/64\n' > "$BATS_TEST_TMPDIR/interfaces.d/provider"
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 0 ]
    ! grep -q 'iface eth0' "$IFACES_FILE"
    assert_file_contains "$BATS_TEST_TMPDIR/interfaces.d/provider" 'up ip -6 addr replace 2001:db8::2/64'
}

@test "unsupported backend refuses before applying a temporary address" {
    rm "$IFACES_FILE"
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 1 ]
    ! grep -q 'addr replace' "$MOCK_CFG_DIR/calls"
}

@test "address application failure restores persistent configuration" {
    original="$(cat "$IFACES_FILE")"
    touch "$MOCK_CFG_DIR/ip-fail"
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 1 ]
    [ "$(cat "$IFACES_FILE")" = "$original" ]
}

@test "networkd adds a persistent drop-in to the actual selected network file" {
    make_mock networkctl --out 'Network File: /run/systemd/network/20-uplink.network'
    run persist_ipv6_address eth0 2001:db8::2/64 fe80::1
    [ "$status" -eq 0 ]
    grep -q 'Address=2001:db8::2/64' "$NETWORKD_DIR/20-uplink.network.d/"*.conf
    grep -q 'Gateway=fe80::1' "$NETWORKD_DIR/20-uplink.network.d/"*.conf
}

@test "Netplan uses the backend ID and validates an additive overlay" {
    mkdir "$NETPLAN_DIR"
    printf 'network:\n  version: 2\n' > "$NETPLAN_DIR/50-cloud-init.yaml"
    make_mock networkctl --out 'Network File: /run/systemd/network/10-netplan-uplink.network'
    make_mock netplan --out 'dhcp4: true'
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 0 ]
    grep -q 'uplink:' "$NETPLAN_DIR/90-clikader-"*.yaml
    grep -q 'netplan generate' "$MOCK_CFG_DIR/calls"
    assert_file_contains "$NETPLAN_DIR/50-cloud-init.yaml" 'version: 2'
}

@test "NetworkManager modifies the active persistent connection" {
    cat > "$MOCK_BIN/nmcli" <<'MOCK'
#!/bin/bash
printf 'nmcli %s\n' "$*" >> "$MOCK_CFG_DIR/calls"
case "$*" in
    '-g GENERAL.CONNECTION device show eth0') echo uplink ;;
    '-g GENERAL.CON-UUID device show eth0') echo 12345678-abcd ;;
    '-g ipv6.method connection show 12345678-abcd') echo auto ;;
esac
MOCK
    run persist_ipv6_address eth0 2001:db8::2/64
    [ "$status" -eq 0 ]
    grep -q 'connection modify 12345678-abcd +ipv6.addresses 2001:db8::2/64' "$MOCK_CFG_DIR/calls"
}

@test "invalid address or prefix does not modify native configuration" {
    original="$(cat "$IFACES_FILE")"
    run persist_ipv6_address eth0 2001:::1/64
    [ "$status" -eq 1 ]
    run persist_ipv6_address eth0 2001:db8::1/999
    [ "$status" -eq 1 ]
    [ "$(cat "$IFACES_FILE")" = "$original" ]
}

@test "IPv6 decision does not prompt without a valid global address" {
    printf '2: eth0 inet6 fe80::1/64 scope link\n' > "$MOCK_CFG_DIR/addresses"
    run choose_ipv6 ask
    [ "$status" -eq 0 ]
    [ "$output" = disable ]
}

@test "IPv6 decision prompts on a global address and defaults to no" {
    printf '2: eth0 inet6 2001:db8::1/64 scope global\n' > "$MOCK_CFG_DIR/addresses"
    inner="$(make_inner lib/common.sh 'choose_ipv6 ask')"
    run_pty "$inner" ''
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *'Keep IPv6 enabled?'* && "$PTY_OUT" == *disable* ]]
}

@test "IPv6 decision preserves IPv6 when user answers yes" {
    printf '2: eth0 inet6 2001:db8::1/64 scope global\n' > "$MOCK_CFG_DIR/addresses"
    inner="$(make_inner lib/common.sh 'choose_ipv6 ask')"
    run_pty "$inner" y
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *keep* ]]
}

@test "tentative and failed duplicate-address checks do not trigger the IPv6 prompt" {
    printf '2: eth0 inet6 2001:db8::1/64 scope global tentative dadfailed \n' > "$MOCK_CFG_DIR/addresses"
    run choose_ipv6 ask
    [ "$status" -eq 0 ]
    [ "$output" = disable ]
}
