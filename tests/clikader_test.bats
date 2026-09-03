#!/usr/bin/env bash
# Tests for clikader.sh
load test_helper

setup() {
    setup_mocks
    make_mock curl --status 0
    load_component clikader.sh
    # Point SCRIPT_DIR at a temp tree so run_script never touches real components.
    SCRIPT_DIR="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$SCRIPT_DIR/components"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/setup_dns.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/optimize_tcp.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/reset_apt_source.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/configure_ipv6.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/fix_hostname.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/nft_manager.sh"
    printf '#!/usr/bin/env bash\necho dummy-ok\nexit 0\n' > "$SCRIPT_DIR/components/setup_vps.sh"
    chmod +x "$SCRIPT_DIR/components"/*.sh
}

@test "has_help_flag: true for -h/--help, false otherwise" {
    run has_help_flag -h
    [ "$status" -eq 0 ]
    run has_help_flag --help
    [ "$status" -eq 0 ]
    run has_help_flag add 80
    [ "$status" -eq 1 ]
}

@test "show_usage: prints version and commands" {
    run show_usage
    [ "$status" -eq 0 ]
    assert_output_contains "CLiKader v"
    assert_output_contains "dns"
    assert_output_contains "nft"
}

@test "require_root: succeeds as root" {
    run require_root dns
    [ "$status" -eq 0 ]
}

@test "dispatch_command: help / version / unknown" {
    run dispatch_command
    [ "$status" -eq 0 ]
    assert_output_contains "Usage"
    run dispatch_command -h
    [ "$status" -eq 0 ]
    run dispatch_command --help
    [ "$status" -eq 0 ]
    run dispatch_command help
    [ "$status" -eq 0 ]
    run dispatch_command --version
    [ "$status" -eq 0 ]
    [ "$output" = "$CLIKADER_VERSION" ]
    run dispatch_command -v
    [ "$output" = "$CLIKADER_VERSION" ]
    run dispatch_command version
    [ "$output" = "$CLIKADER_VERSION" ]
    run dispatch_command nosuch
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown command"
}

@test "run_script: local script success" {
    run run_script "setup_dns.sh" "Setup DNS"
    [ "$status" -eq 0 ]
    assert_output_contains "dummy-ok"
    assert_output_contains "completed successfully"
}

@test "run_script: local script failure returns its code" {
    printf '#!/usr/bin/env bash\nexit 7\n' > "$SCRIPT_DIR/components/setup_dns.sh"
    chmod +x "$SCRIPT_DIR/components/setup_dns.sh"
    run run_script "setup_dns.sh" "Setup DNS"
    [ "$status" -eq 7 ]
    assert_output_contains "exit code: 7"
}

@test "run_script: missing local downloads via curl" {
    rm -f "$SCRIPT_DIR/components/setup_dns.sh"
    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
# last arg is -o path
out="${@: -1}"
printf '#!/usr/bin/env bash\necho downloaded\n' > "$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    run run_script "setup_dns.sh" "Setup DNS"
    [ "$status" -eq 0 ]
    assert_output_contains "Downloaded successfully"
}

@test "run_script: curl failure returns 1" {
    rm -f "$SCRIPT_DIR/components/setup_dns.sh"
    make_mock curl --status 1
    run run_script "setup_dns.sh" "Setup DNS"
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to download"
}

@test "dispatch_command: dns / tcp / hostname / ipv6 / apt-reset use run_script" {
    run dispatch_command dns
    [ "$status" -eq 0 ]
    run dispatch_command tcp
    [ "$status" -eq 0 ]
    run dispatch_command hostname
    [ "$status" -eq 0 ]
    run dispatch_command ipv6
    [ "$status" -eq 0 ]
    run dispatch_command 6
    [ "$status" -eq 0 ]
    run dispatch_command apt-reset
    [ "$status" -eq 0 ]
    run dispatch_command aptreset
    [ "$status" -eq 0 ]
}

@test "dispatch_command: nft/setup help without extra work" {
    run dispatch_command nft --help
    [ "$status" -eq 0 ]
    run dispatch_command setup --help
    [ "$status" -eq 0 ]
}

@test "onboard_step: records OK and FAILED" {
    ONBOARD_RESULTS=()
    onboard_step 1 "setup_dns.sh" "Setup DNS" "--yes"
    [[ "${ONBOARD_RESULTS[0]}" == *"OK"* ]]

    printf '#!/usr/bin/env bash\nexit 1\n' > "$SCRIPT_DIR/components/setup_dns.sh"
    ONBOARD_RESULTS=()
    onboard_step 1 "setup_dns.sh" "Setup DNS" || true
    [[ "${ONBOARD_RESULTS[0]}" == *"FAILED"* ]]
}

@test "onboard_clikader: runs 5 steps" {
    run onboard_clikader
    [ "$status" -eq 0 ]
    assert_output_contains "Onboarding Summary"
}

@test "dispatch_command: onboard / o" {
    run dispatch_command onboard
    [ "$status" -eq 0 ]
    run dispatch_command o
    [ "$status" -eq 0 ]
}

@test "update_clikader: not installed -> 1" {
    run update_clikader
    [ "$status" -eq 1 ]
    assert_output_contains "not installed system-wide"
}

@test "update_clikader: up to date" {
    printf '#!/usr/bin/env bash\n' > "$MOCK_BIN/clikader"
    chmod +x "$MOCK_BIN/clikader"
    cat > "$MOCK_BIN/curl" <<MOCK
#!/usr/bin/env bash
out="\${@: -1}"
printf 'CLIKADER_VERSION="%s"\n' "$CLIKADER_VERSION" > "\$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    run update_clikader
    [ "$status" -eq 0 ]
    assert_output_contains "up to date"
}

@test "update_clikader: curl failure" {
    printf '#!/usr/bin/env bash\n' > "$MOCK_BIN/clikader"
    chmod +x "$MOCK_BIN/clikader"
    make_mock curl --status 1
    run update_clikader
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to check for updates"
}

@test "uninstall_clikader: not installed -> 1" {
    run uninstall_clikader
    [ "$status" -eq 1 ]
    assert_output_contains "not installed"
}

@test "uninstall_clikader via pty: cancelled" {
    printf '#!/usr/bin/env bash\n' > "$MOCK_BIN/clikader"
    chmod +x "$MOCK_BIN/clikader"
    local inner
    inner="$(make_inner clikader.sh 'uninstall_clikader')"
    run_pty "$inner" "n"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Uninstall cancelled"* ]]
}

@test "log / error / warning / info helpers" {
    run log "hello"
    assert_output_contains "hello"
    run error "boom"
    assert_output_contains "boom"
    run warning "careful"
    assert_output_contains "careful"
    run info "note"
    assert_output_contains "note"
}

@test "main: aliases to dispatch_command" {
    run main version
    [ "$status" -eq 0 ]
    [ "$output" = "$CLIKADER_VERSION" ]
}
