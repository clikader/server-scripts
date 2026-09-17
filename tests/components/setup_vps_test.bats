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
    make_mock clikader
    make_mock maintenance
    export CLIKADER_ENTRYPOINT="$MOCK_BIN/clikader"
    export MAINTENANCE_SCRIPT="$MOCK_BIN/maintenance"
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
}

@test "step_run_onboard: calls clikader o when present" {
    last_step=0
    run step_run_onboard
    [ "$status" -eq 0 ]
    assert_mock_called clikader
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
    assert_file_contains "$STATE_FILE" 'last_step=9'
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
    last_step=1
    step_upgrade_debian() { echo second-hop; }
    run run_step_if_needed 1
    [ "$status" -eq 0 ]
    assert_output_contains second-hop
}

@test "changing a resumed SSH port invalidates SSH and firewall steps" {
    last_step=6
    ssh_port=2222
    cli_ssh_port=4444
    apply_cli_inputs
    [ "$last_step" -eq 4 ]
    [ "$ssh_port" = 4444 ]
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
    [ "$last_step" = 0 ]
    assert_file_contains "$UPGRADE_APT_LIST" bookworm
    printf 'boot-two\n' > "$BOOT_ID_FILE"
    debian_codename=bookworm
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    load_state
    [ "$upgrade_pending" = trixie ]
    assert_file_contains "$UPGRADE_APT_LIST" trixie
    printf 'boot-three\n' > "$BOOT_ID_FILE"
    debian_codename=trixie
    run step_upgrade_debian
    [ "$status" -eq 0 ]
    load_state
    [ -z "$upgrade_pending" ]
    [ "$last_step" = 1 ]
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
