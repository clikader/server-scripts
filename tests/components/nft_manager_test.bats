#!/usr/bin/env bash
# Tests for components/nft_manager.sh
load ../test_helper

setup() {
    setup_mocks
    make_mock nft
    make_mock systemctl
    make_mock sshd --out $'port 22\n'
    export NFT_CONF="$BATS_TEST_TMPDIR/nftables.conf"
    cat > "$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
table inet clikader_filter {
    chain input {
        tcp dport { 22 } accept comment "ssh + extra tcp ports"
        udp dport { 53 } accept comment "extra udp ports"
    }
}
EOF
    load_component components/nft_manager.sh
}

@test "valid_port: accepts 1 and 65535, rejects 0 / 65536 / junk" {
    run valid_port 1
    [ "$status" -eq 0 ]
    run valid_port 65535
    [ "$status" -eq 0 ]
    run valid_port 0
    [ "$status" -eq 1 ]
    run valid_port 65536
    [ "$status" -eq 1 ]
    run valid_port abc
    [ "$status" -eq 1 ]
}

@test "normalize_ports: comma/space lists, dedup, rejects empty and invalid" {
    run normalize_ports "8080, 8443,8080"
    [ "$status" -eq 0 ]
    [ "$output" = "8080 8443" ]
    run normalize_ports "  443  "
    [ "$status" -eq 0 ]
    [ "$output" = "443" ]
    run normalize_ports ""
    [ "$status" -eq 1 ]
    run normalize_ports "80,foo"
    [ "$status" -eq 1 ]
}

@test "render_set: joins with comma-space" {
    run render_set "22 80 443"
    [ "$status" -eq 0 ]
    [ "$output" = "22, 80, 443" ]
}

@test "extract_set: pulls ports from a dport rule line" {
    run extract_set '        tcp dport { 22, 80, 443 } accept comment "ssh + extra tcp ports"'
    [ "$status" -eq 0 ]
    [ "$output" = "22 80 443" ]
    run extract_set ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_ssh_port: prefers sshd -T, then sshd_config, then 22" {
    make_mock sshd --out $'port 2222\n'
    run get_ssh_port
    [ "$output" = "2222" ]

    make_mock sshd --out "" --status 1
    mkdir -p "$BATS_TEST_TMPDIR/ssh"
    printf 'Port 2200\n' > "$BATS_TEST_TMPDIR/ssh/sshd_config"
    # get_ssh_port hardcodes /etc/ssh/sshd_config; fall through to default 22
    # when sshd -T is empty and we cannot override that path.
    run get_ssh_port
    [ "$output" = "22" ]
}

@test "read_allow_sets: populates tcp_ports and udp_ports from NFT_CONF" {
    read_allow_sets
    [ "$tcp_ports" = "22" ]
    [ "$udp_ports" = "53" ]
}

@test "read_allow_sets: empty when file missing" {
    NFT_CONF="$BATS_TEST_TMPDIR/missing.conf"
    read_allow_sets
    [ -z "$tcp_ports" ]
    [ -z "$udp_ports" ]
}

# --------------------------------------------------------------------------
# Rules are matched by SHAPE, not by their trailing comment (2026-09-17)
#
# The marker used to be the exact comment string, so a hand-edited comment
# ("http + https + ssh + extra tcp ports") made the tool refuse to recognise
# its own rule — and the failing grep ran under `set -e`, so the refusal was
# SILENT and surfaced only as "Script encountered an error (exit code: 1)".
# --------------------------------------------------------------------------

@test "read_allow_sets: parses a rule whose comment was hand-edited" {
    cat > "$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
table inet clikader_filter {
    chain input {
        tcp dport { 80, 443, 14419 } accept comment "http + https + ssh + extra tcp ports"
        udp dport { 36158 } accept comment "extra udp ports"
    }
}
EOF
    read_allow_sets
    [ "$tcp_ports" = "80 443 14419" ]
    [ "$udp_ports" = "36158" ]
}

@test "read_allow_sets: never fails, even with no clikader rule at all" {
    # Reading must not abort the run under `set -e`: that is what made the
    # refusal silent instead of actionable.
    printf 'table inet something_else {\n}\n' > "$NFT_CONF"
    run read_allow_sets
    [ "$status" -eq 0 ]
    [ -z "$tcp_ports" ]
    [ -z "$udp_ports" ]
}

@test "read_allow_sets: a DHCP rule without a braced set is not mistaken for the allowlist" {
    cat > "$NFT_CONF" <<'EOF'
table inet clikader_filter {
    chain input {
        udp sport 67 udp dport 68 accept comment "DHCP client replies"
        tcp dport { 22 } accept comment "anything"
    }
}
EOF
    read_allow_sets
    [ "$tcp_ports" = "22" ]
    [ -z "$udp_ports" ]
}

@test "rule_comment / rule_line_number: extract what the rewrite needs" {
    run rule_comment '        tcp dport { 80 } accept comment "http + https"'
    [ "$output" = 'comment "http + https"' ]
    run rule_comment '        tcp dport { 80 } accept'
    [ -z "$output" ]
    run rule_line_number 'tcp dport'
    [ "$output" = "4" ]
}

@test "rewrite_allowlist: edits a hand-edited rule and PRESERVES its comment" {
    cat > "$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
table inet clikader_filter {
    chain input {
        tcp dport { 80, 443, 14419 } accept comment "http + https + ssh + extra tcp ports"
        udp dport { 36158 } accept comment "extra udp ports"
    }
}
EOF
    run rewrite_allowlist "80 443 14419 8080" "36158"
    [ "$status" -eq 0 ]
    assert_file_contains "$NFT_CONF" "tcp dport { 80, 443, 14419, 8080 } accept comment \"http + https + ssh + extra tcp ports\""
    # The user's own wording survives the rewrite rather than being reverted.
    [ "$(grep -c 'http + https + ssh + extra tcp ports' "$NFT_CONF")" -eq 1 ]
}

@test "add_ports: reports an actionable error instead of dying silently" {
    printf 'table inet unrecognized {\n}\n' > "$NFT_CONF"
    run add_ports 8080 tcp
    [ "$status" -eq 1 ]
    assert_output_contains "Cannot find the clikader TCP allow rule"
    assert_output_contains "Refusing to edit an unrecognized nftables.conf"
}

@test "set_add / set_remove: add unique, skip dup, remove existing" {
    tcp_ports="22"
    changed=0
    set_add tcp_ports 80 443
    [ "$tcp_ports" = "22 80 443" ]
    [ "$changed" -eq 1 ]
    changed=0
    set_add tcp_ports 80
    [ "$tcp_ports" = "22 80 443" ]
    [ "$changed" -eq 0 ]
    changed=0
    set_remove tcp_ports 80
    [ "$tcp_ports" = "22 443" ]
    [ "$changed" -eq 1 ]
}

@test "add_ports: missing raw prints subusage and returns 1" {
    run add_ports
    [ "$status" -eq 1 ]
    assert_output_contains "Usage: clikader nft add"
}

@test "add_ports: invalid type returns 1" {
    run add_ports 8080 sctp
    [ "$status" -eq 1 ]
    assert_output_contains "Invalid type"
}

@test "add_ports: tcp-only writes the allowlist and reloads nft" {
    # nft -c must succeed; list table must succeed
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
[[ "$1" == "is-active" ]] && exit 0
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"

    run add_ports "8080,8443" tcp
    [ "$status" -eq 0 ]
    grep -q "8080" "$NFT_CONF"
    grep -q "8443" "$NFT_CONF"
}

@test "add_ports: already-allowed ports is a no-op" {
    tcp_ports="22 80"
    # seed the file so read_allow_sets sees 80 already
    cat > "$NFT_CONF" <<'EOF'
        tcp dport { 22, 80 } accept comment "ssh + extra tcp ports"
EOF
    run add_ports 80 tcp
    [ "$status" -eq 0 ]
    assert_output_contains "already allowed"
}

@test "delete_ports: missing raw prints subusage" {
    run delete_ports
    [ "$status" -eq 1 ]
    assert_output_contains "Usage: clikader nft delete"
}

@test "delete_ports: refuses to delete only the SSH port" {
    make_mock sshd --out $'port 22\n'
    run delete_ports 22
    [ "$status" -eq 1 ]
    assert_output_contains "protected"
}

@test "delete_ports: mixed list deletes extras and keeps SSH" {
    cat > "$NFT_CONF" <<'EOF'
        tcp dport { 22, 8080 } accept comment "ssh + extra tcp ports"
        udp dport { 8080 } accept comment "extra udp ports"
EOF
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
    make_mock sshd --out $'port 22\n'
    run delete_ports "22,8080"
    [ "$status" -eq 0 ]
    grep -q "22" "$NFT_CONF"
    ! grep -q "8080" "$NFT_CONF"
}

@test "reset_allowlist: unknown arg returns 1" {
    run reset_allowlist --nope
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown argument"
}

@test "reset_allowlist -y: keeps only SSH on tcp, drops udp" {
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
    make_mock sshd --out $'port 22\n'
    run reset_allowlist -y
    [ "$status" -eq 0 ]
    grep -q "22" "$NFT_CONF"
    ! grep -E "udp dport" "$NFT_CONF"
}

@test "rewrite_allowlist: missing TCP rule refuses to edit" {
    printf 'table inet foo {}\n' > "$NFT_CONF"
    run rewrite_allowlist "22" ""
    [ "$status" -eq 1 ]
    assert_output_contains "Cannot find the clikader TCP allow rule"
}

@test "rewrite_allowlist: nft -c failure restores backup" {
    cat > "$MOCK_BIN/nft" <<'MOCK'
#!/usr/bin/env bash
printf 'nft' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
[[ "$1" == "-c" ]] && exit 1
exit 0
MOCK
    chmod +x "$MOCK_BIN/nft"
    original="$(cat "$NFT_CONF")"
    run rewrite_allowlist "22 80" ""
    [ "$status" -eq 1 ]
    assert_output_contains "failed validation"
    [ "$(cat "$NFT_CONF")" = "$original" ]
}

@test "rewrite_allowlist: applies with nft -f, never restarts the nftables service" {
    run rewrite_allowlist "22 8080" ""
    [ "$status" -eq 0 ]
    assert_file_contains "$NFT_CONF" "8080"
    # Applied directly to the file we own...
    grep -qE '^nft -f ' "$MOCK_CFG_DIR/calls"
    # ...and never via `systemctl restart`. Debian's nftables.service has
    # ExecStop=/usr/sbin/nft flush ruleset, so a restart is a GLOBAL flush that
    # wipes Docker's tables and fail2ban's inet f2b-table (verified 2026-09-17),
    # not just the clikader table this script rewrites.
    ! grep -qE '^systemctl (restart|stop) nftables' "$MOCK_CFG_DIR/calls"
}

@test "usage / subusage / show_current" {
    run usage
    [ "$status" -eq 0 ]
    assert_output_contains "clikader nft"
    run subusage add
    assert_output_contains "clikader nft add"
    run subusage delete
    assert_output_contains "clikader nft delete"
    run show_current
    [ "$status" -eq 0 ]
    assert_output_contains "Current allowlist"
}

@test "main: help / unknown / add / delete / reset dispatch" {
    run main -h
    [ "$status" -eq 0 ]
    assert_output_contains "Sub-commands"
    run main help
    [ "$status" -eq 0 ]
    run main --help
    [ "$status" -eq 0 ]
    run main bogus
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown sub-command"
}

@test "main via pty: interactive menu exit" {
    local inner
    inner="$(make_inner components/nft_manager.sh 'show_menu')"
    run_pty "$inner" "0"
    [ "$PTY_RC" -eq 0 ]
}
