#!/usr/bin/env bash
# Tests for components/fix_hostname.sh
load ../test_helper

setup() {
    setup_mocks

    # hostname -> "oldhost" (stable)
    cat > "$MOCK_BIN/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'oldhost\n'
MOCK
    chmod +x "$MOCK_BIN/hostname"

    # getent hosts <name>: returns $MOCK_CFG_DIR/getent.hosts if present, else 2
    cat > "$MOCK_BIN/getent" <<'MOCK'
#!/usr/bin/env bash
printf '%s' "getent" >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "hosts" && -f "$MOCK_CFG_DIR/getent.hosts" ]]; then
    cat "$MOCK_CFG_DIR/getent.hosts"
    exit 0
fi
exit 2
MOCK
    chmod +x "$MOCK_BIN/getent"

    export HOSTS_FILE="$BATS_TEST_TMPDIR/hosts"
    export HOSTNAME_FILE="$BATS_TEST_TMPDIR/hostname"
    printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
    printf 'oldhost\n' > "$HOSTNAME_FILE"

    load_component components/fix_hostname.sh
}

@test "get_current_hostname returns the mocked hostname" {
    run get_current_hostname
    [ "$status" -eq 0 ]
    [ "$output" = "oldhost" ]
}

@test "check_hostname_resolution: resolves to localhost -> 0" {
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    run check_hostname_resolution
    [ "$status" -eq 0 ]
    assert_output_contains "Hostname correctly resolves to localhost"
}

@test "check_hostname_resolution: resolves to external ip -> 1" {
    printf '203.0.113.5 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    run check_hostname_resolution
    [ "$status" -eq 1 ]
    assert_output_contains "not localhost"
}

@test "check_hostname_resolution: does not resolve -> 1" {
    run check_hostname_resolution
    [ "$status" -eq 1 ]
    assert_output_contains "does NOT resolve"
}

@test "fix_hostname_resolution: adds a new 127.0.1.1 entry after 127.0.0.1" {
    printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
    printf '127.0.1.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    run fix_hostname_resolution
    [ "$status" -eq 0 ]
    assert_output_contains "Added new entry"
    assert_file_contains "$HOSTS_FILE" "127.0.1.1	oldhost"
}

@test "fix_hostname_resolution: updates an existing 127.0.1.1 line" {
    printf '127.0.0.1 localhost\n127.0.1.1 otherhost\n' > "$HOSTS_FILE"
    printf '127.0.1.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    run fix_hostname_resolution
    [ "$status" -eq 0 ]
    assert_output_contains "Updated 127.0.1.1 entry"
    assert_file_contains "$HOSTS_FILE" "127.0.1.1	oldhost"
    [[ "$(grep -c otherhost "$HOSTS_FILE")" -eq 0 ]]
}

@test "fix_hostname_resolution: removes duplicate hostname lines" {
    printf '127.0.0.1 localhost\n127.0.1.1 oldhost\n10.0.0.5 oldhost\n' > "$HOSTS_FILE"
    printf '127.0.1.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    run fix_hostname_resolution
    [ "$status" -eq 0 ]
    [[ "$(grep -c oldhost "$HOSTS_FILE")" -eq 1 ]]
}

@test "fix_hostname_resolution: verification failure -> 1" {
    printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
    # no getent.hosts -> getent fails after the fix
    run fix_hostname_resolution
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to fix hostname resolution"
}

@test "change_hostname via pty: applies a valid hostname" {
    make_mock hostnamectl
    printf '127.0.1.1 newhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'change_hostname')"
    run_pty "$inner" "newhost" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Hostname changed successfully"* ]]
    assert_file_contains "$HOSTS_FILE" "127.0.1.1	newhost"
    assert_mock_called hostnamectl
}

@test "change_hostname via pty: cancelled when confirm is no -> 1" {
    make_mock hostnamectl
    local inner
    inner="$(make_inner components/fix_hostname.sh 'change_hostname')"
    run_pty "$inner" "newhost" "n"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Hostname change cancelled"* ]]
}

@test "change_hostname via pty: rejects empty and invalid hostnames" {
    make_mock hostnamectl
    printf '127.0.1.1 newhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'change_hostname')"
    run_pty "$inner" "" "bad host!" "newhost" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Hostname cannot be empty"* ]]
    [[ "$PTY_OUT" == *"Invalid hostname format"* ]]
}

@test "change_hostname via pty: falls back to /etc/hostname without hostnamectl" {
    printf '127.0.1.1 newhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'change_hostname')"
    run_pty "$inner" "newhost" "y"
    [ "$PTY_RC" -eq 0 ]
    assert_file_contains "$HOSTNAME_FILE" "newhost"
}

@test "main: check mode reports and returns 0" {
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    HOSTNAME_MODE="check"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "Current hostname"
}

@test "main: fix mode when already localhost does nothing" {
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    HOSTNAME_MODE="fix"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "No fix needed"
}

@test "main: fix mode auto-fixes a bad resolution" {
    printf '203.0.113.9 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    HOSTNAME_MODE="fix"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "Auto-fixing"
}

@test "main via pty: interactive menu exit (0)" {
    make_mock clear
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'main')"
    run_pty "$inner" "0"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Exiting"* ]]
}

@test "main via pty: interactive menu fix (1)" {
    make_mock clear
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'main')"
    run_pty "$inner" "1"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Hostname resolution fixed successfully"* ]]
}

@test "main via pty: invalid menu choice -> 1" {
    make_mock clear
    printf '127.0.0.1 oldhost\n' > "$MOCK_CFG_DIR/getent.hosts"
    local inner
    inner="$(make_inner components/fix_hostname.sh 'main')"
    run_pty "$inner" "9"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Invalid choice"* ]]
}
