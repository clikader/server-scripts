#!/usr/bin/env bash
# Tests for components/setup_vps.sh
load ../test_helper

setup() {
    setup_mocks
    export STATE_DIR="$BATS_TEST_TMPDIR/clikader"
    export STATE_FILE="$STATE_DIR/setup.state"
    export GAI_CONF="$BATS_TEST_TMPDIR/gai.conf"
    export SSHD_CONFIG="$BATS_TEST_TMPDIR/sshd_config"
    export SSHD_CONF_DIR="$BATS_TEST_TMPDIR/sshd_config.d"
    export SSH_DIR="$BATS_TEST_TMPDIR/ssh"
    export AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
    export NFT_CONF="$BATS_TEST_TMPDIR/nftables.conf"
    export FAIL2BAN_JAIL="$BATS_TEST_TMPDIR/jail.local"
    export UPGRADE_APT_LIST="$BATS_TEST_TMPDIR/sources.list"
    export UPGRADE_APT_DIR="$BATS_TEST_TMPDIR/sources.list.d"
    export BOOT_ID_FILE="$BATS_TEST_TMPDIR/boot-id"
    mkdir -p "$UPGRADE_APT_DIR"
    printf 'boot-one\n' > "$BOOT_ID_FILE"
    printf 'deb https://deb.debian.org/debian bullseye main\n' > "$UPGRADE_APT_LIST"
    mkdir -p "$STATE_DIR" "$SSHD_CONF_DIR" "$SSH_DIR"
    : > "$GAI_CONF"
    printf '# sshd\nPort 22\n' > "$SSHD_CONFIG"
    : > "$AUTHORIZED_KEYS"

    make_mock apt-get
    make_mock systemctl
    make_mock sshd --out $'port 2222\npasswordauthentication no\npubkeyauthentication yes\npermitrootlogin prohibit-password\nkbdinteractiveauthentication no\n'
    make_mock nft
    make_mock fail2ban-client
    make_mock chpasswd
    make_mock ssh-keygen
    make_mock ss --out "LISTEN 0 128 0.0.0.0:2222 sshd"
    make_mock maintenance
    make_mock apt-reset
    make_mock setup_dns
    make_mock configure_ipv6
    make_mock optimize_tcp
    make_mock fix_hostname
    export MAINTENANCE_SCRIPT="$MOCK_BIN/maintenance"
    export APT_RESET_SCRIPT="$MOCK_BIN/apt-reset"
    export DNS_SCRIPT="$MOCK_BIN/setup_dns"
    export IPV6_SCRIPT="$MOCK_BIN/configure_ipv6"
    export TCP_SCRIPT="$MOCK_BIN/optimize_tcp"
    export HOSTNAME_SCRIPT="$MOCK_BIN/fix_hostname"
    make_mock sleep
    load_component components/setup_vps.sh
    verify_ssh_journal() { return 0; }
}

@test "escape_single_quotes: round-trips apostrophes" {
    run escape_single_quotes "it's"
    [ "$output" = "it'\\''s" ]
}

@test "valid_port / valid_ssh_pubkey / normalize_port_list" {
    run valid_port 22
    [ "$status" -eq 0 ]
    run valid_port 0
    [ "$status" -eq 1 ]
    run valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    [ "$status" -eq 0 ]
    run valid_ssh_pubkey "not-a-key"
    [ "$status" -eq 1 ]
    run normalize_port_list "8080, 443"
    [ "$output" = "8080 443" ]
    run normalize_port_list "none"
    [ -z "$output" ]
    run normalize_port_list "80,bad"
    [ "$status" -eq 1 ]
}

@test "save_state / load_state round-trip" {
    ssh_port=2222
    ssh_auth_method=key
    ssh_public_key="ssh-ed25519 AAAA me@h"
    ssh_password=""
    extra_ports="8080 443"
    last_step=3
    clikader_setup_completed=0
    completed_at=""
    run save_state
    [ "$status" -eq 0 ]
    [ -f "$STATE_FILE" ]
    ssh_port=""
    extra_ports=""
    last_step=0
    load_state
    [ "$ssh_port" = "2222" ]
    [ "$extra_ports" = "8080 443" ]
    [ "$last_step" = "3" ]
}

@test "load_state: missing file returns 1" {
    rm -f "$STATE_FILE"
    run load_state
    [ "$status" -eq 1 ]
}

@test "load_state: older step layout restarts progress but keeps saved answers" {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<'EOF'
ssh_port='2222'
ssh_auth_method='key'
ssh_public_key='ssh-ed25519 AAAA me@h'
ssh_password=''
extra_ports='8080'
last_step=8
clikader_setup_completed=0
completed_at=''
upgrade_pending='bookworm'
upgrade_boot_id='boot-x'
upgrade_finished=1
ipv6_policy='disable'
profile='proxy'
EOF
    load_state
    [ "$last_step" = "0" ]
    [ "$ssh_port" = "2222" ]
    [ "$extra_ports" = "8080" ]
    [ "$upgrade_pending" = "bookworm" ]
    [ "$upgrade_finished" = "1" ]
}

@test "load_state: current layout keeps progress" {
    ssh_port=2222
    ssh_auth_method=key
    ssh_public_key="ssh-ed25519 AAAA me@h"
    extra_ports=""
    last_step=9
    save_state
    last_step=0
    load_state
    [ "$last_step" = "9" ]
}

@test "apply_cli_inputs: ssh-port + key" {
    cli_ssh_port=2222
    cli_ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    cli_password=""
    cli_extra_ports="80,443"
    apply_cli_inputs
    [ "$ssh_port" = "2222" ]
    [ "$ssh_auth_method" = "key" ]
    [ "$extra_ports" = "80 443" ]
}

@test "apply_cli_inputs: invalid port / mutually exclusive / short password" {
    cli_ssh_port=99999
    run apply_cli_inputs
    [ "$status" -eq 1 ]
}

@test "apply_cli_inputs: key and password exclusive" {
    cli_ssh_port=22
    cli_ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    cli_password="secretsecret"
    run apply_cli_inputs
    [ "$status" -eq 1 ]
    assert_output_contains "mutually exclusive"
}

@test "apply_cli_inputs: password method" {
    cli_ssh_port=22
    cli_password="secretsecret"
    apply_cli_inputs
    [ "$ssh_auth_method" = "password" ]
}

@test "apply_cli_inputs: invalid pubkey" {
    cli_ssh_port=22
    cli_ssh_key="bogus"
    run apply_cli_inputs
    [ "$status" -eq 1 ]
    assert_output_contains "does not look like a valid OpenSSH"
}

@test "detect_os: debian container is accepted" {
    detect_os
    [ "$debian_major" = "13" ]
}

@test "step_prefer_ipv4: appends gai.conf when missing" {
    last_step=0
    run step_prefer_ipv4
    [ "$status" -eq 0 ]
    assert_file_contains "$GAI_CONF" "precedence ::ffff:0:0/96  100"
    # second run is idempotent
    run step_prefer_ipv4
    [ "$status" -eq 0 ]
    [ "$(grep -c 'precedence' "$GAI_CONF")" -eq 1 ]
}

@test "step_configure_ipv6: disable policy runs the component, keep leaves it alone" {
    ipv6_policy=disable
    last_step=0
    run step_configure_ipv6
    [ "$status" -eq 0 ]
    [ "$(mock_last_args configure_ipv6)" = "--disable --yes" ]
    [ "$(mock_calls configure_ipv6)" -eq 1 ]

    ipv6_policy=keep
    run step_configure_ipv6
    [ "$status" -eq 0 ]
    [ "$(mock_calls configure_ipv6)" -eq 1 ]
}

@test "step_reset_apt_sources: proxy runs the component, general preserves provider sources" {
    profile=proxy
    last_step=0
    run step_reset_apt_sources
    [ "$status" -eq 0 ]
    [ "$(mock_calls apt-reset)" -eq 1 ]

    profile=general
    run step_reset_apt_sources
    [ "$status" -eq 0 ]
    [ "$(mock_calls apt-reset)" -eq 1 ]
}

@test "step_reset_apt_sources: component failure fails the step" {
    profile=proxy
    last_step=0
    make_mock apt-reset --status 1
    run step_reset_apt_sources
    [ "$status" -eq 1 ]
}

@test "step_setup_dns: proxy runs the component with --yes, general preserves provider DNS" {
    profile=proxy
    last_step=0
    run step_setup_dns
    [ "$status" -eq 0 ]
    [ "$(mock_last_args setup_dns)" = "--yes" ]
    [ "$(mock_calls setup_dns)" -eq 1 ]

    profile=general
    run step_setup_dns
    [ "$status" -eq 0 ]
    [ "$(mock_calls setup_dns)" -eq 1 ]
}

@test "step_tcp_and_hostname: proxy tunes TCP, general keeps tuning, hostname always fixed" {
    profile=proxy
    last_step=0
    run step_tcp_and_hostname
    [ "$status" -eq 0 ]
    [ "$(mock_calls optimize_tcp)" -eq 1 ]
    [ "$(mock_last_args fix_hostname)" = "--fix" ]

    profile=general
    run step_tcp_and_hostname
    [ "$status" -eq 0 ]
    [ "$(mock_calls optimize_tcp)" -eq 1 ]
    [ "$(mock_calls fix_hostname)" -eq 2 ]
}

@test "step_install_packages: apt-get install" {
    last_step=0
    run step_install_packages
    [ "$status" -eq 0 ]
    assert_mock_called apt-get
}

@test "step_enable_chrony: enables chrony" {
    last_step=0
    run step_enable_chrony
    [ "$status" -eq 0 ]
    assert_mock_called systemctl
}

@test "step_configure_nftables: writes nft_conf and validates" {
    ssh_port=2222
    extra_ports="8080 443"
    last_step=0
    cat > "$MOCK_BIN/nft" <<'MOCK'
#!/usr/bin/env bash
printf 'nft' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/nft"
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run step_configure_nftables
    [ "$status" -eq 0 ]
    assert_file_contains "$NFT_CONF" "Managed by clikader setup"
    assert_file_contains "$NFT_CONF" "2222"
    [ "$(stat -c %a "$NFT_CONF")" = 644 ]
}

@test "step_configure_nftables: applies with nft -f, never restarts the nftables service" {
    ssh_port=2222
    extra_ports=""
    last_step=0
    cat > "$MOCK_BIN/nft" <<'MOCK'
#!/usr/bin/env bash
printf 'nft' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/nft"
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run step_configure_nftables
    [ "$status" -eq 0 ]

    # The ruleset is applied with `nft -f` (scoped to our own tables), never
    # with `systemctl restart nftables`: Debian's unit declares
    # ExecStop=/usr/sbin/nft flush ruleset, so a restart deletes EVERY table —
    # Docker's ip filter/ip nat rules (killing all container networking) and
    # fail2ban's inet f2b-table (dropping every active ban). Verified 2026-09-17.
    grep -qE '^nft -f ' "$MOCK_CFG_DIR/calls"
    ! grep -qE '^systemctl (restart|stop) nftables' "$MOCK_CFG_DIR/calls"
}

@test "step_configure_nftables: firewall is inbound-only, never drops forwarding" {
    ssh_port=2222
    extra_ports=""
    last_step=0
    cat > "$MOCK_BIN/nft" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/nft"
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    run step_configure_nftables
    [ "$status" -eq 0 ]

    # The input hook is the entire firewall: drop anything not explicitly allowed.
    assert_file_contains "$NFT_CONF" "type filter hook input priority filter; policy drop;"
    # Forwarding must stay accepting. Dropping here is invisible to the host's
    # own traffic but silently breaks every container, whose packets are
    # forwarded and never traverse the input chain (watchtower outage
    # 2026-09-17: its per-bridge counters stayed at zero while host DNS worked).
    assert_file_contains "$NFT_CONF" "type filter hook forward priority filter; policy accept;"
    # Exactly one drop policy in the whole file, and it belongs to the input hook.
    [ "$(grep -c 'policy drop' "$NFT_CONF")" -eq 1 ]
    grep 'policy drop' "$NFT_CONF" | grep -q 'hook input'
    # Output is never filtered.
    assert_file_contains "$NFT_CONF" "type filter hook output priority filter; policy accept;"
}

# A managed-style nftables.conf for the re-run (early-path) tests: exactly one
# TCP allow rule, as the port manager requires.
write_managed_nft_conf() {
    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
add table inet clikader_filter
delete table inet clikader_filter
table inet clikader_filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state { established, related } accept
        tcp dport { $1 } accept comment "ssh + extra tcp ports"
        counter drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

mock_firewall_tools() {
    make_mock nft
    make_mock systemctl
    make_mock sshd --out "port $1"
    make_mock ss --out "LISTEN 0 128 0.0.0.0:$1 sshd"
}

@test "prune_stale_setup_ports: closes the old SSH port and dropped extras, keeps user-added ports" {
    write_managed_nft_conf "22, 14419, 8080, 9090"
    mock_firewall_tools 14419
    ssh_port=14419
    extra_ports=""
    previous_setup_ports="22 8080"
    run prune_stale_setup_ports
    [ "$status" -eq 0 ]
    # Only the previous run's own ports (22, 8080) are pruned; 9090 was added
    # later with `clikader nft add` and must survive the re-run.
    assert_file_contains "$NFT_CONF" 'tcp dport { 14419, 9090 } accept'
    ! grep -q '22' "$NFT_CONF"
    ! grep -q '8080' "$NFT_CONF"
}

@test "prune_stale_setup_ports: no-op when the same ports are requested again" {
    write_managed_nft_conf "14419, 443"
    mock_firewall_tools 14419
    ssh_port=14419
    extra_ports="443"
    previous_setup_ports="14419 443"
    run prune_stale_setup_ports
    [ "$status" -eq 0 ]
    ! grep -q '^nft ' "$MOCK_CFG_DIR/calls"
    assert_file_contains "$NFT_CONF" 'tcp dport { 14419, 443 } accept'
}

@test "step_configure_nftables: re-run updates an existing managed conf and prunes the old SSH port" {
    write_managed_nft_conf "22, 8080"
    mock_firewall_tools 14419
    ssh_port=14419
    extra_ports=""
    previous_setup_ports="22 8080"
    run step_configure_nftables
    [ "$status" -eq 0 ]
    assert_file_contains "$NFT_CONF" 'tcp dport { 14419 } accept'
    ! grep -q '22' "$NFT_CONF"
    ! grep -q '8080' "$NFT_CONF"
}

@test "step_setup_fail2ban: writes jail.local" {
    ssh_port=2222
    last_step=0
    cat > "$MOCK_BIN/fail2ban-client" <<'MOCK'
#!/usr/bin/env bash
printf 'fail2ban-client' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
exit 0
MOCK
    chmod +x "$MOCK_BIN/fail2ban-client"
    cat > "$MOCK_BIN/nft" <<'MOCK'
#!/usr/bin/env bash
printf 'nft' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
printf '192.0.2.1\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/nft"
    run step_setup_fail2ban
    [ "$status" -eq 0 ]
    assert_file_contains "$FAIL2BAN_JAIL" "port = 2222"
    [ "$(stat -c %a "$FAIL2BAN_JAIL")" = 644 ]
}

@test "run_step_if_needed: maps the network baseline steps to their components" {
    ipv6_policy=disable
    last_step=0
    debian_codename=trixie
    run run_step_if_needed 1
    [ "$status" -eq 0 ]
    run run_step_if_needed 2
    [ "$status" -eq 0 ]
    run run_step_if_needed 3
    [ "$status" -eq 0 ]
    run run_step_if_needed 4
    [ "$status" -eq 0 ]
    [ "$(mock_calls apt-reset)" -eq 1 ]
    [ "$(mock_calls setup_dns)" -eq 1 ]
    [ "$(mock_calls configure_ipv6)" -eq 1 ]
}

@test "run_step_if_needed: skips completed steps" {
    last_step=4
    run run_step_if_needed 2
    [ "$status" -eq 0 ]
    assert_output_contains "already completed"
}

@test "run_step_if_needed: unknown step -> 1" {
    last_step=0
    run run_step_if_needed 99
    [ "$status" -eq 1 ]
}

@test "script --help (top-level parser)" {
    run bash "$REPO_ROOT/components/setup_vps.sh" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: clikader setup"
}

@test "script unknown argument" {
    run bash "$REPO_ROOT/components/setup_vps.sh" --nope
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown argument"
}

@test "main: already completed refuses without --force" {
    ssh_port=22
    ssh_auth_method=key
    ssh_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    extra_ports=""
    last_step=8
    clikader_setup_completed=1
    completed_at="2026-01-01"
    save_state
    force=0
    reset=0
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "already set up"
}

@test "main: reset replaces partial state and completes the mocked setup" {
    mkdir -p "$STATE_DIR"
    printf "last_step=3\n" > "$STATE_FILE"
    reset=1
    force=0
    # will then try to collect inputs / run steps; provide CLI so it's non-interactive
    cli_ssh_port=2222
    cli_ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    cli_extra_ports="none"
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$STATE_FILE" 'clikader_setup_completed=1'
    assert_file_contains "$STATE_FILE" 'last_step=12'

    # The network baseline (APT reset + DNS) runs before the first apt-get,
    # which is the whole point of the ordering fix.
    local reset_line dns_line apt_line
    reset_line="$(grep -n '^apt-reset' "$MOCK_CFG_DIR/calls" | head -1 | cut -d: -f1)"
    dns_line="$(grep -n '^setup_dns' "$MOCK_CFG_DIR/calls" | head -1 | cut -d: -f1)"
    apt_line="$(grep -n '^apt-get' "$MOCK_CFG_DIR/calls" | head -1 | cut -d: -f1)"
    [ -n "$reset_line" ] && [ -n "$dns_line" ] && [ -n "$apt_line" ]
    [ "$reset_line" -lt "$apt_line" ]
    [ "$dns_line" -lt "$apt_line" ]
    # On an already-trixie box the same-run normalization is not repeated.
    [ "$(mock_calls apt-reset)" -eq 1 ]
}

@test "step_ssh_hardening: key-only writes managed block and authorized_keys" {
    ssh_port=2222
    ssh_auth_method=key
    ssh_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
    last_step=0
    cat > "$MOCK_BIN/sshd" <<'MOCK'
#!/usr/bin/env bash
printf 'sshd' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "-t" ]]; then exit 0; fi
if [[ "$1" == "-T" ]]; then
    cat <<'OUT'
port 2222
passwordauthentication no
pubkeyauthentication yes
permitrootlogin prohibit-password
kbdinteractiveauthentication no
OUT
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/sshd"
    cat > "$MOCK_BIN/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:((sshd))\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/ss"
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
# ssh.socket not active/enabled
[[ "$1" == "is-active" || "$1" == "is-enabled" ]] && exit 1
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' > "$SSHD_CONFIG"
    run step_ssh_hardening
    [ "$status" -eq 0 ]
    assert_file_contains "$SSHD_CONFIG" "BEGIN clikader sshd settings"
    assert_file_contains "$AUTHORIZED_KEYS" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h"
}

@test "step_ssh_hardening: password method sets PermitRootLogin yes" {
    ssh_port=2222
    ssh_auth_method=password
    ssh_password="secretsecret"
    last_step=0
    cat > "$MOCK_BIN/sshd" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-t" ]]; then exit 0; fi
if [[ "$1" == "-T" ]]; then
    cat <<'OUT'
port 2222
passwordauthentication yes
pubkeyauthentication yes
permitrootlogin yes
kbdinteractiveauthentication yes
OUT
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/sshd"
    cat > "$MOCK_BIN/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:((sshd))\n'
exit 0
MOCK
    chmod +x "$MOCK_BIN/ss"
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "is-active" || "$1" == "is-enabled" ]] && exit 1
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"
    make_mock chpasswd
    run step_ssh_hardening
    [ "$status" -eq 0 ]
    assert_file_contains "$SSHD_CONFIG" "PasswordAuthentication yes"
    assert_mock_called chpasswd
}

@test "collect_inputs via pty: key method" {
    ssh_port=""
    ssh_auth_method=""
    ssh_public_key=""
    extra_ports=""
    cli_extra_ports=""
    local inner
    inner="$(make_inner components/setup_vps.sh 'collect_inputs')"
    run_pty "$inner" "2222" "key" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@h" ""
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Saved parameters"* ]]
}

@test "step_banner / step_upgrade_debian already on trixie" {
    debian_codename="trixie"
    last_step=0
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    assert_output_contains "Already on Debian"
}

@test "step_upgrade_debian: re-normalizes sources when the reset targeted another release" {
    debian_codename=trixie
    apt_sources_reset_for=bookworm
    profile=proxy
    last_step=0
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    [ "$(mock_calls apt-reset)" -eq 1 ]
}

@test "step_upgrade_debian: skips the duplicate reset when step 3 already normalized this release" {
    debian_codename=trixie
    apt_sources_reset_for=trixie
    profile=proxy
    last_step=0
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    [ "$(mock_calls apt-reset)" -eq 0 ]
}

@test "public key validation rejects malformed key material using real OpenSSH" {
    rm "$MOCK_BIN/ssh-keygen"
    run valid_ssh_pubkey 'ssh-ed25519 '
    [ "$status" -eq 1 ]
    run valid_ssh_pubkey 'ssh-ed25519 definitely-not-a-key'
    [ "$status" -eq 1 ]
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/key"
    run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/key.pub")"
    [ "$status" -eq 0 ]
}

@test "bookworm resume after the bullseye hop schedules the second upgrade" {
    debian_codename=bookworm
    last_step=4
    step_upgrade_debian() { echo second-hop; }
    run run_step_if_needed 5
    [ "$status" -eq 0 ]
    assert_output_contains second-hop
}

@test "changing a resumed SSH port invalidates SSH and firewall steps" {
    last_step=9
    ssh_port=2222
    cli_ssh_port=4444
    apply_cli_inputs
    [ "$last_step" -eq 7 ]
    [ "$ssh_port" = 4444 ]
}

@test "changing extra ports invalidates the firewall step" {
    last_step=12
    ssh_port=2222
    extra_ports=""
    cli_extra_ports="8080"
    apply_cli_inputs
    [ "$last_step" -eq 8 ]
    [ "$extra_ports" = "8080" ]
}

@test "release upgrade refuses to resume in the same boot" {
    debian_codename=bookworm
    upgrade_pending=bookworm
    upgrade_finished=1
    upgrade_boot_id="$(cat "$BOOT_ID_FILE")"
    run step_upgrade_debian
    [ "$status" -eq 1 ]
    assert_output_contains 'Reboot before continuing'
    ! grep -q apt-get "$MOCK_CFG_DIR/calls"
}

@test "state containing credentials is created private and atomically replaced" {
    ssh_auth_method=password
    ssh_password="credential with ' quote"
    save_state
    [ "$(stat -c %a "$STATE_FILE")" = 600 ]
    [ "$(stat -c %a "$STATE_DIR")" = 700 ]
    ssh_password=''
    load_state
    [ "$ssh_password" = "credential with ' quote" ]
}

@test "failed fail2ban ban verification cannot mark the step complete" {
    ssh_port=2222
    last_step=6
    make_mock fail2ban-client --status 0
    make_mock nft --out ''
    run step_setup_fail2ban
    [ "$status" -eq 1 ]
    [ ! -f "$STATE_FILE" ]
}

@test "two release hops rewrite sources and require separate reboots" {
    debian_codename=bullseye
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    load_state
    [ "$upgrade_pending" = bookworm ]
    [ "$upgrade_finished" = 1 ]
    [ "$last_step" = 4 ]
    assert_file_contains "$UPGRADE_APT_LIST" bookworm
    printf 'boot-two\n' > "$BOOT_ID_FILE"
    debian_codename=bookworm
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    load_state
    [ "$upgrade_pending" = trixie ]
    [ "$last_step" = 4 ]
    assert_file_contains "$UPGRADE_APT_LIST" trixie
    printf 'boot-three\n' > "$BOOT_ID_FILE"
    debian_codename=trixie
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    load_state
    [ -z "$upgrade_pending" ]
    [ "$last_step" = 5 ]
    # Resuming onto trixie re-normalizes the sources for the new release.
    assert_mock_called apt-reset
}

@test "release preflight rejects vendor and floating repositories before package changes" {
    debian_codename=bullseye
    printf 'deb https://vendor.example/debian bullseye main\n' > "$UPGRADE_APT_LIST"
    run step_upgrade_debian
    [ "$status" -eq 1 ]
    ! grep -q apt-get "$MOCK_CFG_DIR/calls"
    printf 'deb https://deb.debian.org/debian oldoldstable main\n' > "$UPGRADE_APT_LIST"
    run step_upgrade_debian
    [ "$status" -eq 1 ]
    ! grep -q apt-get "$MOCK_CFG_DIR/calls"
}

@test "interrupted release upgrade is not mistaken for a completed hop" {
    debian_codename=trixie
    upgrade_pending=trixie
    upgrade_finished=0
    run step_upgrade_debian
    [ "$status" -eq 1 ]
    assert_output_contains 'was interrupted'
}
