#!/usr/bin/env bash
# Tests for components/setup_dns.sh
load ../test_helper

setup() {
    setup_mocks
    export RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
    export DHCLIENT_CONF="$BATS_TEST_TMPDIR/dhclient.conf"
    export IFUPD_RESOLVED="$BATS_TEST_TMPDIR/if-up.resolved"
    export CLOUD_CFG_DIR="$BATS_TEST_TMPDIR/cloud.cfg.d"
    export RESOLVED_CONF="$BATS_TEST_TMPDIR/resolved.conf"
    export STUB_RESOLV_CONF="$BATS_TEST_TMPDIR/stub-resolv.conf"
    mkdir -p "$CLOUD_CFG_DIR" "$(dirname "$IFUPD_RESOLVED")"
    printf 'nameserver 1.1.1.1\n' > "$RESOLV_CONF"
    printf '# dhclient\n' > "$DHCLIENT_CONF"
    printf 'nameserver 127.0.0.53\n' > "$STUB_RESOLV_CONF"

    make_mock systemctl
    make_mock resolvectl --out "DNS Servers: 1.1.1.1"
    make_mock apt-get
    make_mock dpkg --status 1
    make_mock lsattr --out "----i-------------"
    make_mock chattr
    make_mock sleep
    make_mock nslookup --status 0
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'dig' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
printf '93.184.216.34\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/dig"

    load_component components/setup_dns.sh
}

@test "provider_name / provider_ipv4 / provider_ipv6: catalogue accessors" {
    run provider_name 1
    [ "$output" = "Cloudflare" ]
    run provider_ipv4 1
    [[ "$output" == *"1.1.1.1"* ]]
    run provider_ipv6 1
    [[ "$output" == *"2606:4700"* ]]
}

@test "load_provider_table: fills associative arrays" {
    load_provider_table
    [ "${dns_names[1]}" = "Cloudflare" ]
    [ -n "${dns_ipv4[1]}" ]
    [ -n "${dns_ipv6[3]}" ]
}

@test "probe_server: dig success returns a millisecond integer" {
    run probe_server 1.1.1.1
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "probe_server: dig failure falls through to nslookup then fails" {
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/dig"
    cat > "$MOCK_BIN/nslookup" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/nslookup"
    run probe_server 203.0.113.1
    [ "$status" -eq 1 ]
}

@test "generate_resolved_config: insecure vs secure" {
    primary_dns="1.1.1.1 8.8.8.8"
    use_secure_dns=false
    has_dot_support=false
    generate_resolved_config
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSSEC=no"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSOverTLS=no"* ]]

    use_secure_dns=true
    has_dot_support=true
    generate_resolved_config
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSSEC=yes"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSOverTLS=opportunistic"* ]]
}

@test "ask_secure_dns: --yes disables secure DNS" {
    non_interactive=true
    run ask_secure_dns
    [ "$status" -eq 0 ]
    [ "$use_secure_dns" = false ]
    assert_output_contains "DISABLED"
}

@test "unlock_resolv_conf: unlocks immutable flag" {
    make_mock lsattr --out "----i------------- $RESOLV_CONF"
    run unlock_resolv_conf
    [ "$status" -eq 0 ]
    assert_output_contains "unlocked"
}

@test "health_check: fails when systemd-resolved is down" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 1
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run health_check
    [ "$status" -eq 1 ]
    assert_output_contains "One or more checks failed"
}

@test "health_check: all pass when resolved is up and dhclient configured" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    printf 'supersede domain-name-servers 127.0.0.53;\nprepend domain-name-servers 127.0.0.53;\n' > "$DHCLIENT_CONF"
    rm -f "$IFUPD_RESOLVED"
    run health_check
    [ "$status" -eq 0 ]
    assert_output_contains "All checks passed"
}

@test "purify_dns: writes resolved.conf, dhclient override, cloud-init drop-in" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock resolvectl --status 0
    primary_dns="1.1.1.1 8.8.8.8"
    use_secure_dns=false
    has_dot_support=false
    printf '#!/bin/sh\n' > "$IFUPD_RESOLVED"
    chmod +x "$IFUPD_RESOLVED"
    run purify_dns
    [ "$status" -eq 0 ]
    assert_file_contains "$DHCLIENT_CONF" "BEGIN setup_dns.sh DNS override"
    assert_file_contains "$CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg" "manage_resolv_conf: false"
    assert_file_contains "$RESOLVED_CONF" "DNS=1.1.1.1"
    [ ! -x "$IFUPD_RESOLVED" ]
}

@test "verify_dns: active resolved + resolvectl + nslookup" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run verify_dns
    [ "$status" -eq 0 ]
    assert_output_contains "systemd-resolved is active"
    assert_output_contains "DNS resolution is working"
}

@test "verify_dns: inactive resolved -> 1" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run verify_dns
    [ "$status" -eq 1 ]
    assert_output_contains "not running"
}

@test "select_dns_providers: --yes auto-picks after probing" {
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    select_dns_providers
    [ -n "$primary_dns" ]
}

@test "get_custom_dns via pty: ipv4 only" {
    ipv6_support=false
    use_secure_dns=false
    load_provider_table
    local inner
    inner="$(make_inner components/setup_dns.sh 'get_custom_dns')"
    run_pty "$inner" "9.9.9.9 149.112.112.112"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Custom DNS configured successfully"* ]]
}

@test "get_custom_dns via pty: empty ipv4 -> 1" {
    ipv6_support=false
    use_secure_dns=false
    local inner
    inner="$(make_inner components/setup_dns.sh 'get_custom_dns')"
    run_pty "$inner" ""
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"IPv4 DNS servers are required"* ]]
}

@test "order_by_latency: all probes fail keeps original order" {
    load_provider_table
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/dig"
    cat > "$MOCK_BIN/nslookup" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/nslookup"
    run order_by_latency 1 2 3
    [ "$status" -eq 0 ]
    assert_output_contains "All probes failed"
}

@test "ask_secure_dns via pty: yes enables DoT" {
    non_interactive=false
    local inner
    inner="$(make_inner components/setup_dns.sh 'ask_secure_dns')"
    run_pty "$inner" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"ENABLED"* ]]
}

@test "purify_dns: installs systemd-resolved when resolvectl missing" {
    rm -f "$MOCK_BIN/resolvectl"
    make_mock apt-get --status 0
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    primary_dns="1.1.1.1"
    use_secure_dns=false
    has_dot_support=false
    run purify_dns
    [ "$status" -eq 0 ]
    assert_output_contains "Installing systemd-resolved"
}

@test "main: --yes path reconfigures when health_check fails" {
    non_interactive=true
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
# is-active fails during health_check, succeeds afterwards
[[ "$1" == "is-active" && ! -f "$MOCK_CFG_DIR/resolved.up" ]] && exit 1
[[ "$1" == "is-active" ]] && exit 0
[[ "$1" == "restart" ]] && touch "$MOCK_CFG_DIR/resolved.up"
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "DNS setup completed successfully"
}
