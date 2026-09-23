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
    export RESOLVED_CONF_D="$BATS_TEST_TMPDIR/resolved.conf.d"
    export UNBOUND_CONF="$BATS_TEST_TMPDIR/unbound.conf"
    export UNBOUND_TRUST_ANCHOR="$BATS_TEST_TMPDIR/root.key"
    export UNBOUND_ROOT_KEY_SRC="$BATS_TEST_TMPDIR/static-root.key"
    export STUB_RESOLV_CONF="$BATS_TEST_TMPDIR/stub-resolv.conf"
    mkdir -p "$CLOUD_CFG_DIR" "$(dirname "$IFUPD_RESOLVED")"
    printf 'nameserver 1.1.1.1\n' > "$RESOLV_CONF"
    printf '# dhclient\n' > "$DHCLIENT_CONF"
    printf 'nameserver 127.0.0.53\n' > "$STUB_RESOLV_CONF"
    printf '. IN DNSKEY 257 3 8 test-anchor\n' > "$UNBOUND_TRUST_ANCHOR"

    # Hermetic Azure detection: a dead IMDS endpoint (instant refusal, and the
    # test image has no real curl anyway) plus temp DMI files — the defaults
    # point at 169.254.169.254 and the host's real DMI tables.
    export AZURE_IMDS_URL="http://127.0.0.1:9/metadata/instance?api-version=2021-02-01"
    export DMI_SYS_VENDOR_FILE="$BATS_TEST_TMPDIR/dmi-vendor"
    export DMI_PRODUCT_FILE="$BATS_TEST_TMPDIR/dmi-product"
    printf 'QEMU\n' > "$DMI_SYS_VENDOR_FILE"
    printf 'Standard PC (Q35 + ICH9, ICH9-LPC)\n' > "$DMI_PRODUCT_FILE"

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
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSOverTLS=yes"* ]]
}

@test "resolve_cache_setting: systemd >= 250 -> no-negative, older/unknown -> no" {
    # Default mock systemctl prints nothing for --version: undeterminable -> "no".
    run resolve_cache_setting
    [ "$status" -eq 0 ]
    [ "$output" = "no" ]

    make_mock systemctl --out "systemd 249 (249.11-0ubuntu3)"
    run resolve_cache_setting
    [ "$output" = "no" ]

    make_mock systemctl --out "systemd 250 (250.3-1)"
    run resolve_cache_setting
    [ "$output" = "no-negative" ]

    make_mock systemctl --out "systemd 255 (255.4-1ubuntu8)"
    run resolve_cache_setting
    [ "$output" = "no-negative" ]
}

@test "generate_resolved_config: never emits Cache=yes" {
    primary_dns="1.1.1.1 8.8.8.8"
    use_secure_dns=false
    has_dot_support=false

    # Undeterminable version (default silent mock) -> full caching off.
    generate_resolved_config
    [[ "$SECURE_RESOLVED_CONFIG" == *"Cache=no"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" != *"Cache=yes"* ]]

    # Modern systemd -> negative caching only disabled.
    make_mock systemctl --out "systemd 255 (255.4-1ubuntu8)"
    generate_resolved_config
    [[ "$SECURE_RESOLVED_CONFIG" == *"Cache=no-negative"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" != *"Cache=yes"* ]]
}

@test "catalogue: five universal providers (non-filtering flavours), Custom last" {
    [ "${#DNS_PROVIDERS[@]}" -eq 5 ]
    [ "$(provider_name 1)" = "Cloudflare" ]
    [ "$(provider_name 2)" = "Google" ]
    [ "$(provider_name 3)" = "Quad9" ]
    [ "$(provider_name 4)" = "OpenDNS" ]
    [ "$(provider_name 5)" = "AdGuard" ]
    [ "$CUSTOM_DNS_INDEX" -eq 6 ]
    # OpenDNS is the non-filtering Sandbox pair, not the standard pair that
    # rewrites NXDOMAIN answers (ACME DNS-01 polling must see real NXDOMAIN).
    [ "$(provider_ipv4 4)" = "208.67.222.2#sandbox.opendns.com 208.67.220.2#sandbox.opendns.com" ]
    [ "$(provider_ipv6 4)" = "2620:0:ccc::2#sandbox.opendns.com 2620:0:ccd::2#sandbox.opendns.com" ]
    # AdGuard is the Unfiltered pair, not the ad/tracker-blocking Default pair.
    [ "$(provider_ipv4 5)" = "94.140.14.140#unfiltered.adguard-dns.com 94.140.14.141#unfiltered.adguard-dns.com" ]
    [ "$(provider_ipv6 5)" = "2a10:50c0::1:ff#unfiltered.adguard-dns.com 2a10:50c0::2:ff#unfiltered.adguard-dns.com" ]
    # China-optimized resolvers live in their own array, appended only on a
    # mainland-China network (add_region_providers).
    [ "${#CHINA_DNS_PROVIDERS[@]}" -eq 2 ]
    local joined="${DNS_PROVIDERS[*]}"
    [[ "$joined" != *"Alibaba"* && "$joined" != *"DNSPod"* ]]
    [[ "$joined" != *"208.67.222.222"* && "$joined" != *"94.140.14.14#"* ]]
    [[ "$joined" != *"dns.adguard-dns.com"* ]]
}

@test "add_region_providers: skips Alibaba/DNSPod outside mainland China" {
    is_mainland_china() { return 1; }
    add_region_providers > "$BATS_TEST_TMPDIR/out"
    [ "${#DNS_PROVIDERS[@]}" -eq 5 ]
    [ "$CUSTOM_DNS_INDEX" -eq 6 ]
    grep -q "outside mainland China" "$BATS_TEST_TMPDIR/out"
    # Idempotent: a second call does not duplicate entries.
    add_region_providers
    [ "${#DNS_PROVIDERS[@]}" -eq 5 ]
    [ "$(provider_name 5)" = "AdGuard" ]
}

@test "add_region_providers: appends Alibaba/DNSPod on a mainland-China network" {
    is_mainland_china() { return 0; }
    add_region_providers > "$BATS_TEST_TMPDIR/out"
    [ "${#DNS_PROVIDERS[@]}" -eq 7 ]
    [ "$(provider_name 6)" = "Alibaba" ]
    [ "$(provider_name 7)" = "DNSPod" ]
    [ "$CUSTOM_DNS_INDEX" -eq 8 ]
    grep -q "mainland-China network detected" "$BATS_TEST_TMPDIR/out"
    [[ "$(provider_ipv4 6)" == *"223.5.5.5"* && "$(provider_ipv4 6)" == *"223.6.6.6"* ]]
    [[ "$(provider_ipv4 7)" == *"119.29.29.29"* && "$(provider_ipv4 7)" == *"119.28.28.28"* ]]
    [[ "$(provider_ipv4 6)" == *"#dns.alidns.com"* ]]
    [[ "$(provider_ipv4 7)" == *"#dot.pub"* ]]
    add_region_providers
    [ "${#DNS_PROVIDERS[@]}" -eq 7 ]
}

@test "is_mainland_china: false when TCP to the resolved google.com IP connects" {
    # Resolve step stubbed to a google.com address; the probe must connect BY
    # IP (never through the local resolver) inside the timeout.
    china_probe_ip() { printf '142.250.190.78'; }
    make_mock timeout --status 0
    run is_mainland_china
    [ "$status" -eq 1 ]
    [[ "$(mock_last_args timeout)" == "3 bash -c "* ]]
    [[ "$(mock_last_args timeout)" == *"/dev/tcp/142.250.190.78/443"* ]]
    [[ "$(mock_last_args timeout)" != *"/dev/tcp/google.com/443"* ]]
}

@test "is_mainland_china: true when the TCP probe times out or is refused" {
    china_probe_ip() { printf '142.250.190.78'; }
    make_mock timeout --status 124
    run is_mainland_china
    [ "$status" -eq 0 ]
    make_mock timeout --status 1
    run is_mainland_china
    [ "$status" -eq 0 ]
}

@test "is_mainland_china: undeterminable region (no resolver answers) is NOT mainland China" {
    # Fail closed: a box that cannot even resolve google.com (broken/slow DNS,
    # filtered port 53) must not get the China-only resolvers.
    china_probe_ip() { return 1; }
    make_mock timeout --status 124
    run is_mainland_china
    [ "$status" -eq 1 ]
    [[ "$(mock_calls timeout)" -eq 0 ]]
}

@test "list: shows managed config, live state and resolv.conf" {
    mkdir -p "$RESOLVED_CONF_D"
    printf '[Resolve]\nDNS=9.9.9.9 149.112.112.112\nFallbackDNS=208.67.222.2\nDNSSEC=yes\nDNSOverTLS=yes\n' \
        > "$RESOLVED_CONF_D/zz-clikader-dns.conf"
    printf 'nameserver 127.0.0.53\n' > "$STUB_RESOLV_CONF"
    ln -sf "$STUB_RESOLV_CONF" "$RESOLV_CONF"
    cat > "$MOCK_BIN/resolvectl" <<'MOCK'
#!/usr/bin/env bash
printf 'Global: 9.9.9.9 149.112.112.112\nLink 2 (eth0): 10.0.0.1\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/resolvectl"
    run show_dns_overview
    [ "$status" -eq 0 ]
    assert_output_contains "Current DNS configuration"
    assert_output_contains "forward (systemd-resolved"
    assert_output_contains "Managed file:    $RESOLVED_CONF_D/zz-clikader-dns.conf"
    assert_output_contains "DNS servers:     9.9.9.9 149.112.112.112"
    assert_output_contains "Fallback DNS:    208.67.222.2"
    assert_output_contains "DNSSEC:          yes"
    assert_output_contains "DNS-over-TLS:    yes"
    assert_output_contains "Global: 9.9.9.9 149.112.112.112"
    assert_output_contains "Link 2 (eth0): 10.0.0.1"
    assert_output_contains "$RESOLV_CONF -> $STUB_RESOLV_CONF"
    assert_output_contains "nameserver 127.0.0.53"
}

@test "list: recursive mode when DNS=127.0.0.1 and unbound is active" {
    mkdir -p "$RESOLVED_CONF_D"
    printf '[Resolve]\nDNS=127.0.0.1\nFallbackDNS=\nDNSSEC=no\nDNSOverTLS=no\n' > "$RESOLVED_CONF_D/zz-clikader-dns.conf"
    run show_dns_overview
    [ "$status" -eq 0 ]
    assert_output_contains "recursive (systemd-resolved -> unbound on 127.0.0.1:53)"
    assert_output_contains "DNS servers:     127.0.0.1"
    assert_output_contains "unbound service: active"
}

@test "list: unmanaged when no clikader DNS config exists" {
    rm -f "$RESOLVED_CONF"
    run show_dns_overview
    [ "$status" -eq 0 ]
    assert_output_contains "unmanaged (provider/systemd default)"
    assert_output_contains "Managed file:    none"
    assert_output_contains "DNS servers:     (provider/systemd default)"
}

@test "list: the script lists resolvers as a normal user (no root check)" {
    run setpriv --reuid=65534 --regid=65534 --clear-groups bash "$REPO_ROOT/components/setup_dns.sh" list
    [ "$status" -eq 0 ]
    assert_output_contains "Current DNS configuration"
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

@test "health_check: passes without dhclient installed (netplan/networkd image)" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    rm -f "$DHCLIENT_CONF" "$IFUPD_RESOLVED"
    run health_check
    [ "$status" -eq 0 ]
    assert_output_contains "All checks passed"
    assert_output_contains "dhclient not present"
}

@test "purify_dns: clears per-link DNS that would shadow the managed resolver" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "--version" ]]; then printf 'systemd 255 (255.4-1)\n'; fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    mkdir "$BATS_TEST_TMPDIR/net"
    : > "$BATS_TEST_TMPDIR/net/eth0"
    export SYSFS_NET="$BATS_TEST_TMPDIR/net"
    make_mock resolvectl --status 0 --out $'Link 2 (eth0)\n\tDNS Servers: 8.8.8.8'
    primary_dns="1.1.1.1"
    use_secure_dns=false
    has_dot_support=false
    run purify_dns
    [ "$status" -eq 0 ]
    grep -q 'resolvectl revert eth0' "$MOCK_CFG_DIR/calls"
}

@test "purify_dns: writes resolved.conf, dhclient override, cloud-init drop-in, cache drop-in" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "--version" ]]; then printf 'systemd 255 (255.4-1)\n'; fi
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
    assert_file_contains "$RESOLVED_CONF" "Cache=no-negative"
    assert_file_contains "$RESOLVED_CONF_D/10-setup-dns-cache.conf" "Cache=no-negative"
    [ ! -x "$IFUPD_RESOLVED" ]
}

@test "purify_dns: service-read config is world-readable (resolved runs unprivileged)" {
    # tx_begin's umask 077 used to create these 0600/0700; systemd-resolved
    # (user systemd-resolve) then rejected the whole config and started with
    # NO DNS servers (production outage 2026-09-18). Modes are load-bearing.
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "--version" ]]; then printf 'systemd 255 (255.4-1)\n'; fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock resolvectl --status 0
    primary_dns="1.1.1.1"
    use_secure_dns=false
    has_dot_support=false
    rm -rf "$RESOLVED_CONF_D"   # exercise the fresh-directory path
    run purify_dns
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$RESOLVED_CONF_D")" = 755 ]
    [ "$(stat -c %a "$RESOLVED_CONF_D/zz-clikader-dns.conf")" = 644 ]
    [ "$(stat -c %a "$RESOLVED_CONF_D/10-setup-dns-cache.conf")" = 644 ]
    [ "$(stat -c %a "$CLOUD_CFG_DIR/99-disable-dns-mgmt.cfg")" = 644 ]
    # The unprivileged resolver user can actually read them (best-effort:
    # minimal test images may lack the user or setpriv; the mode assertions
    # above are the hard gate, the integration suite does this for real).
    if id systemd-resolve >/dev/null 2>&1 && command -v setpriv >/dev/null; then
        setpriv --reuid="$(id -u systemd-resolve)" --regid="$(id -g systemd-resolve)" --clear-groups \
            cat "$RESOLVED_CONF_D/zz-clikader-dns.conf" >/dev/null
    fi
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

@test "verify_dns: no DNS servers at all -> refuse instead of leaving the box resolverless" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    # resolved runs but the inventory lists no server (config rejected).
    make_mock resolvectl --out 'Global:'
    run verify_dns
    [ "$status" -eq 1 ]
    assert_output_contains "NO DNS servers after cutover"
}

@test "select_dns_providers: --yes auto-picks after probing" {
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    select_dns_providers
    [ -n "$primary_dns" ]
}

@test "provider menu shows both anycast IPs for the universal providers" {
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    run select_dns_providers
    [ "$status" -eq 0 ]
    assert_output_contains "Cloudflare (1.1.1.1, 1.0.0.1)"
    assert_output_contains "Google (8.8.8.8, 8.8.4.4)"
    assert_output_contains "Quad9 (9.9.9.10, 149.112.112.10)"
    assert_output_contains "OpenDNS (208.67.222.2, 208.67.220.2)"
    assert_output_contains "AdGuard (94.140.14.140, 94.140.14.141)"
    # China-optimized entries only appear after mainland-China detection.
    [[ "$output" != *"Alibaba"* && "$output" != *"DNSPod"* ]]
}

@test "provider menu includes Alibaba/DNSPod after mainland-China detection" {
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    is_mainland_china() { return 0; }
    add_region_providers
    run select_dns_providers
    [ "$status" -eq 0 ]
    assert_output_contains "Alibaba (223.5.5.5, 223.6.6.6)"
    assert_output_contains "DNSPod (119.29.29.29, 119.28.28.28)"
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

@test "order_by_latency: all probes fail without replacing the resolver" {
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
    [ "$status" -eq 1 ]
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

@test "ask_resolver_mode via pty: y selects recursive" {
    non_interactive=false
    local inner
    inner="$(make_inner components/setup_dns.sh 'ask_resolver_mode')"
    run_pty "$inner" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"local recursive (unbound)"* ]]
}

@test "ask_resolver_mode via pty: empty/other keeps forward" {
    non_interactive=false
    local inner
    inner="$(make_inner components/setup_dns.sh 'ask_resolver_mode')"
    run_pty "$inner" ""
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"forward to public DNS"* ]]
}

@test "ask_resolver_mode: --yes keeps flag decision without prompting" {
    non_interactive=true
    use_recursive=false
    run ask_resolver_mode
    [ "$status" -eq 0 ]
    assert_output_contains "forward to public DNS"
    use_recursive=true
    run ask_resolver_mode
    [ "$status" -eq 0 ]
    assert_output_contains "local recursive (unbound) [--recursive]"
}

@test "purify_dns: recursive installs unbound, writes config, resolves via 127.0.0.1" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=false
    primary_dns="127.0.0.1"
    run purify_dns
    [ "$status" -eq 0 ]
    assert_output_contains "unbound-checkconf passed"
    assert_file_contains "$UNBOUND_CONF" "cache-max-negative-ttl: 0"
    assert_file_contains "$UNBOUND_CONF" "interface: 127.0.0.1"
    assert_file_contains "$UNBOUND_CONF" "do-ip6: no"
    assert_file_contains "$RESOLVED_CONF" "DNS=127.0.0.1"
    assert_mock_called unbound-checkconf 1
}

@test "purify_dns: recursive with ipv6 adds ::1 interface and do-ip6" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=true
    primary_dns="127.0.0.1 ::1"
    run purify_dns
    [ "$status" -eq 0 ]
    assert_file_contains "$UNBOUND_CONF" "do-ip6: yes"
    assert_file_contains "$UNBOUND_CONF" "interface: ::1"
    assert_file_contains "$RESOLVED_CONF" "DNS=127.0.0.1 ::1"
}

@test "purify_dns: recursive installs unbound when missing" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound-checkconf --status 0
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=false
    run purify_dns
    [ "$status" -eq 0 ]
    assert_output_contains "Installing unbound"
    assert_file_contains "$UNBOUND_CONF" "cache-max-negative-ttl: 0"
}

@test "purify_dns: recursive seeds DNSSEC anchor and includes it in config" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    printf '. IN DNSKEY 257 3 8 test-anchor\n' > "$UNBOUND_ROOT_KEY_SRC"
    rm -f "$UNBOUND_TRUST_ANCHOR"
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=false
    primary_dns="127.0.0.1"
    run purify_dns
    [ "$status" -eq 0 ]
    [ -f "$UNBOUND_TRUST_ANCHOR" ]
    assert_file_contains "$UNBOUND_CONF" "auto-trust-anchor-file: \"$UNBOUND_TRUST_ANCHOR\""
}

@test "purify_dns: recursive without a trust anchor refuses instead of disabling validation" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    rm -f "$UNBOUND_TRUST_ANCHOR" "$UNBOUND_ROOT_KEY_SRC"
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=false
    primary_dns="127.0.0.1"
    run purify_dns
    [ "$status" -eq 1 ]
    assert_output_contains "trust anchor not available"
    [ ! -f "$UNBOUND_CONF" ]
}

@test "purify_dns: invalid unbound config aborts before resolved.conf is touched" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 1
    use_recursive=true
    use_secure_dns=false
    has_dot_support=false
    ipv6_support=false
    run purify_dns
    [ "$status" -eq 1 ]
    assert_output_contains "unbound-checkconf rejected"
    # The old resolver config must still be in place.
    [ ! -f "$RESOLVED_CONF" ]
}

# --------------------------------------------------------------------------
# Port 53 reachability gate (production outage 2026-09-17)
#
# A network that filters outbound port 53 to the root servers cannot recurse.
# unbound still starts cleanly and reports "active", so recursive mode used to
# "succeed" and then blackhole every lookup on the box. These tests pin the
# detection that must stop it.
# --------------------------------------------------------------------------

@test "dig_query: echoes nothing when the server stays silent" {
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/dig"
    run dig_query 198.41.0.4 . NS
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "iterative_walk: performs an iterative (+trace) lookup" {
    run iterative_walk
    [ "$status" -eq 0 ]
    grep -q '+trace' "$MOCK_CFG_DIR/calls"
}

@test "recursion_is_possible: true when the iterative walk completes" {
    run recursion_is_possible
    [ "$status" -eq 0 ]
}

@test "recursion_is_possible: false when the roots answer but the walk cannot finish" {
    # The real-world trap: the roots reply (so a root-only probe looks healthy)
    # while every TLD/authoritative server silently drops queries. The gate must
    # judge the completed walk, not root reachability.
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'NS a.root-servers.net. from server 127.0.0.53 in 0 ms.\n'
printf 'NS b.root-servers.net. from server 127.0.0.53 in 0 ms.\n'
printf ';; communications error to 192.5.6.30#53: timed out\n'
printf ';; communications error to 192.33.14.30#53: timed out\n'
exit 9
MOCK
    chmod +x "$MOCK_BIN/dig"
    run recursion_is_possible
    [ "$status" -eq 1 ]
}

@test "recursion_is_possible: false when the walk never completes at all" {
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 9
MOCK
    chmod +x "$MOCK_BIN/dig"
    run recursion_is_possible
    [ "$status" -eq 1 ]
}

@test "recursion_is_possible: bails out on the first failed attempt" {
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'dig' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 9
MOCK
    chmod +x "$MOCK_BIN/dig"
    run recursion_is_possible
    [ "$status" -eq 1 ]
    # One attempt is enough to conclude the network cannot recurse.
    assert_mock_called dig 1
}

@test "recursion_is_possible: records which servers never replied" {
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf ';; communications error to 192.5.6.30#53: timed out\n'
printf ';; communications error to 192.33.14.30#53: timed out\n'
exit 9
MOCK
    chmod +x "$MOCK_BIN/dig"
    # Called directly (not via run) so the global survives for inspection.
    recursion_is_possible || true
    [[ "$RECURSION_TRACE_EVIDENCE" == *"192.5.6.30"* ]]
    [[ "$RECURSION_TRACE_EVIDENCE" == *"192.33.14.30"* ]]
}

@test "configure_recursive_resolver: refuses to install when the DNS walk is blocked" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    # Every iterative walk dies at the TLD servers: the exact production failure.
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'NS a.root-servers.net. from server 127.0.0.53 in 0 ms.\n'
printf ';; communications error to 192.5.6.30#53: timed out\n'
exit 9
MOCK
    chmod +x "$MOCK_BIN/dig"

    use_recursive=true
    run configure_recursive_resolver
    [ "$status" -eq 1 ]
    assert_output_contains "blocks outbound DNS"
    assert_output_contains "No reply from: 192.5.6.30"
    assert_output_contains "Re-run WITHOUT --recursive"
    # Bail out before writing a config or touching the running resolver, so a
    # blocked network cannot leave the box worse off than it found it.
    [ ! -f "$UNBOUND_CONF" ]
    assert_mock_called unbound-checkconf 0
    assert_mock_called unbound 0
}

@test "configure_recursive_resolver: aborts when unbound starts but cannot resolve" {
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    # Roots answer (so the pre-check passes) but anything queried through
    # unbound itself stays silent — started clean, blackholes every lookup.
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'dig' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
for a in "$@"; do
    [[ "$a" == "@127.0.0.1" ]] && exit 1
done
printf '93.184.216.34\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/dig"

    use_recursive=true
    run configure_recursive_resolver
    [ "$status" -eq 1 ]
    assert_output_contains "started but cannot resolve names"
    assert_output_contains "Re-run WITHOUT --recursive"
    # Resolution is verified through the resolver itself, not just its socket.
    grep -q '@127.0.0.1' "$MOCK_CFG_DIR/calls"
}

@test "main: --yes --recursive on a blocked network fails instead of completing" {
    non_interactive=true
    use_recursive=true
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/dig"

    run main
    [ "$status" -ne 0 ]
    [[ "$output" != *"DNS setup completed successfully"* ]]
    # systemd-resolved must never be pointed at a resolver that cannot resolve.
    [ ! -f "$RESOLVED_CONF" ]
}

@test "main: --yes recursive end-to-end" {
    non_interactive=true
    use_recursive=true
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock apt-get --status 0
    make_mock unbound
    make_mock unbound-checkconf --status 0
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "DNS setup completed successfully"
    assert_output_contains "unbound (local recursive resolver) is active"
    assert_file_contains "$UNBOUND_CONF" "cache-max-negative-ttl: 0"
    assert_file_contains "$RESOLVED_CONF" "DNS=127.0.0.1"
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
    [ "$status" -eq 1 ]
    assert_output_contains "Installing systemd-resolved"
}

@test "main: --yes path reconfigures when health_check fails" {
    non_interactive=true
    # Hermetic region detection: outside mainland China, no network probe.
    is_mainland_china() { return 1; }
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

@test "DNS verification fails when the system resolver lookup fails" {
    make_mock nslookup --status 1
    run verify_dns
    [ "$status" -eq 1 ]
    assert_output_contains 'DNS resolution test failed'
}

@test "failed forward cutover restores the old resolver and configuration" {
    printf 'old resolved settings\n' > "$RESOLVED_CONF"
    original="$(cat "$RESOLV_CONF")"
    primary_dns=192.0.2.53
    make_mock nslookup --status 1
    run purify_dns
    [ "$status" -eq 1 ]
    [ "$(cat "$RESOLV_CONF")" = "$original" ]
    [ ! -L "$RESOLV_CONF" ]
    assert_file_contains "$RESOLVED_CONF" 'old resolved settings'
    [ ! -e "$RESOLVED_CONF_D/zz-clikader-dns.conf" ]
}

@test "failed recursive resolver restart restores an already-recursive server config" {
    make_mock unbound
    make_mock unbound-checkconf
    printf 'previous recursive config\n' > "$UNBOUND_CONF"
    use_recursive=true
    recursion_is_possible() { return 0; }
    unbound_resolves() { return 1; }
    run purify_dns
    [ "$status" -eq 1 ]
    assert_file_contains "$UNBOUND_CONF" 'previous recursive config'
    assert_file_contains "$RESOLV_CONF" 'nameserver 1.1.1.1'
}

@test "unbound health check rejects dig error text" {
    rm "$MOCK_BIN/dig"
    make_mock dig --out ';; communications error: timed out' --status 9
    run unbound_resolves
    [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# Azure VM detection and the Azure DNS default (168.63.129.16)
#
# Only Azure DNS (the fabric VIP) can resolve VNET-internal names — private
# endpoints, internal load balancers, peered-VNET names — so on an Azure VM
# it must become the default (especially the --yes path used by clikader setup)
# while public resolvers stay an explicit, warned choice.
# --------------------------------------------------------------------------

@test "detect_azure_vm: true when IMDS answers Azure metadata" {
    make_mock curl --out '{"azEnvironment":"AzurePublicCloud","location":"eastasia"}'
    detect_azure_vm
    [ "$is_azure_vm" = true ]
    [ "$azure_detection_source" = "instance metadata service" ]
    # IMDS is conclusive: the fabric VIP is not probed on this path.
    assert_mock_called dig 0
}

@test "detect_azure_vm: DMI match counts only with a fabric DNS answer" {
    make_mock curl --status 1
    printf 'Microsoft Corporation\n' > "$DMI_SYS_VENDOR_FILE"
    printf 'Virtual Machine\n' > "$DMI_PRODUCT_FILE"
    detect_azure_vm
    [ "$is_azure_vm" = true ]
    [ "$azure_detection_source" = "DMI fingerprints + fabric DNS answer" ]
    assert_mock_called dig 1
}

@test "detect_azure_vm: DMI match with a silent VIP is rejected (Hyper-V elsewhere)" {
    # Hyper-V guests from other providers report the identical DMI strings but
    # have no Azure fabric: 168.63.129.16 stays silent, so the Azure entry
    # must not be shown or defaulted anywhere on such boxes.
    make_mock curl --status 1
    printf 'Microsoft Corporation\n' > "$DMI_SYS_VENDOR_FILE"
    printf 'Virtual Machine\n' > "$DMI_PRODUCT_FILE"
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$MOCK_BIN/dig"
    if detect_azure_vm; then
        echo "expected Hyper-V DMI match without fabric answer to be rejected" >&2
        false
    fi
    [ "$is_azure_vm" = false ]
    [ -z "$azure_detection_source" ]
    # Nothing was registered, so the catalogue is unchanged.
    register_azure_provider
    [ "${#DNS_PROVIDERS[@]}" -eq 5 ]
    [ "$azure_dns_index" -eq 0 ]
}

@test "detect_azure_vm: false on a non-Azure box" {
    # No curl mock: the test image ships no curl, so the IMDS probe is skipped
    # entirely and only the (QEMU) DMI files are consulted.
    if detect_azure_vm; then
        echo "expected no Azure detection on QEMU DMI" >&2
        false
    fi
    [ "$is_azure_vm" = false ]
    [ -z "$azure_detection_source" ]
}

@test "register_azure_provider: prepends Azure entry, keeps Custom last, idempotent" {
    is_azure_vm=true
    register_azure_provider
    [ "${#DNS_PROVIDERS[@]}" -eq 6 ]
    [ "$azure_dns_index" -eq 1 ]
    [ "$(provider_name 1)" = "Azure" ]
    [ "$(provider_ipv4 1)" = "168.63.129.16" ]
    [ -z "$(provider_ipv6 1)" ]
    [ "$CUSTOM_DNS_INDEX" -eq 7 ]
    # A second registration must not duplicate the entry.
    register_azure_provider
    [ "${#DNS_PROVIDERS[@]}" -eq 6 ]
}

@test "register_azure_provider: no-op on non-Azure boxes" {
    is_azure_vm=false
    register_azure_provider
    [ "${#DNS_PROVIDERS[@]}" -eq 5 ]
    [ "$azure_dns_index" -eq 0 ]
    [ "$CUSTOM_DNS_INDEX" -eq 6 ]
}

@test "select_dns_providers: --yes on an Azure VM defaults to Azure DNS only" {
    is_azure_vm=true
    register_azure_provider
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    select_dns_providers
    [ "$primary_dns" = "168.63.129.16" ]
    [ "${selected_names[0]}" = "Azure" ]
}

@test "select_dns_providers: --yes on Azure falls back to public auto when the VIP is silent" {
    is_azure_vm=true
    register_azure_provider
    non_interactive=true
    use_secure_dns=false
    ipv6_support=false
    cat > "$MOCK_BIN/dig" <<'MOCK'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "@168.63.129.16" ]] && exit 1
done
printf '93.184.216.34\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/dig"
    run select_dns_providers
    [ "$status" -eq 0 ]
    assert_output_contains "did not answer the probe"
    assert_output_contains "Falling back to auto-pick public resolvers"
    assert_output_contains "will NOT resolve"
}

@test "select_dns_providers via pty: empty input on an Azure VM takes the Azure default" {
    local inner
    inner="$(make_inner components/setup_dns.sh 'is_azure_vm=true; register_azure_provider; non_interactive=false; use_secure_dns=false; ipv6_support=false; select_dns_providers; printf "PRIMARY=%s\n" "$primary_dns"')"
    run_pty "$inner" ""
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"PRIMARY=168.63.129.16"* ]]
}

@test "select_dns_providers via pty: a public choice on Azure warns about VNET names" {
    local inner
    inner="$(make_inner components/setup_dns.sh 'is_azure_vm=true; register_azure_provider; non_interactive=false; use_secure_dns=false; ipv6_support=false; select_dns_providers')"
    run_pty "$inner" "2"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"will NOT resolve"* ]]
    [[ "$PTY_OUT" == *"Select 1 (Azure DNS 168.63.129.16)"* ]]
}

@test "secure DNS selection including Azure downgrades DoT (no DoT on the fabric VIP)" {
    is_azure_vm=true
    register_azure_provider
    non_interactive=true
    use_secure_dns=true
    has_dot_support=true
    ipv6_support=false
    select_dns_providers
    [ "$has_dot_support" = false ]
    generate_resolved_config
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNS=168.63.129.16"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSOverTLS=no"* ]]
    [[ "$SECURE_RESOLVED_CONFIG" == *"DNSSEC=yes"* ]]
}

@test "ask_resolver_mode: --yes on an Azure VM announces the Azure DNS default" {
    is_azure_vm=true
    non_interactive=true
    use_recursive=false
    run ask_resolver_mode
    [ "$status" -eq 0 ]
    assert_output_contains "forward to Azure DNS 168.63.129.16"
}

@test "ask_resolver_mode: recursive on an Azure VM warns about VNET-internal names" {
    is_azure_vm=true
    non_interactive=true
    use_recursive=true
    run ask_resolver_mode
    [ "$status" -eq 0 ]
    assert_output_contains "cannot resolve VNET-internal names"
}

@test "main: --yes on an Azure VM configures Azure DNS end-to-end" {
    printf 'Microsoft Corporation\n' > "$DMI_SYS_VENDOR_FILE"
    printf 'Virtual Machine\n' > "$DMI_PRODUCT_FILE"
    non_interactive=true
    # Hermetic region detection: outside mainland China, no network probe.
    is_mainland_china() { return 1; }
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "--version" ]]; then printf 'systemd 255 (255.4-1)\n'; fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "Azure VM detected (via DMI fingerprints + fabric DNS answer)"
    assert_output_contains "DNS setup completed successfully"
    assert_file_contains "$RESOLVED_CONF" "DNS=168.63.129.16"
}
