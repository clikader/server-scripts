#!/usr/bin/env bash
# Tests for components/configure_ipv6.sh
load ../test_helper

# helper: set a mocked live sysctl value
set_sysctl() {
    local key="$1" val="$2"
    printf '%s' "$val" > "$MOCK_CFG_DIR/sysctl.$(printf '%s' "$key" | tr '.' '_')"
}

# helper: write mocked `ip -o link show` output (real ip format so awk works)
set_ifaces() {
    local n=2
    : > "$MOCK_CFG_DIR/ip.links"
    for i in "$@"; do
        printf '%d: %s: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000\n' "$n" "$i" >> "$MOCK_CFG_DIR/ip.links"
        n=$((n + 1))
    done
}

setup() {
    setup_mocks

    # --- sysctl: maintains a live key/value store, honours writes ---
    cat > "$MOCK_BIN/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf 'sysctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
enc() { printf '%s' "$1" | tr '.' '_'; }
if [[ "$1" == "-n" ]]; then
    f="$MOCK_CFG_DIR/sysctl.$(enc "$2")"
    [[ -f "$f" ]] && cat "$f" || printf '0\n'
    exit 0
elif [[ "$1" == "-w" ]]; then
    kv="$2"; key="${kv%%=*}"; val="${kv#*=}"
    if [[ ! -f "$MOCK_CFG_DIR/sysctl.nowrite" ]]; then
        printf '%s' "$val" > "$MOCK_CFG_DIR/sysctl.$(enc "$key")"
    fi
    exit 0
elif [[ "$1" == "-p" ]]; then
    exit 0
else
    for k in "$@"; do
        f="$MOCK_CFG_DIR/sysctl.$(enc "$k")"
        v=0; [[ -f "$f" ]] && v="$(cat "$f")"
        printf '%s = %s\n' "$k" "$v"
    done
    exit 0
fi
MOCK
    chmod +x "$MOCK_BIN/sysctl"

    # --- ip: -o link show / -6 addr show / addr add ---
    cat > "$MOCK_BIN/ip" <<'MOCK'
#!/usr/bin/env bash
printf 'ip' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
args="$*"
if [[ "$1" == "-6" && "$2" == "addr" && "$3" == "add" ]]; then
    st=0
    [[ -f "$MOCK_CFG_DIR/ip.add.status" ]] && st="$(cat "$MOCK_CFG_DIR/ip.add.status")"
    if [[ "$st" == "0" ]]; then
        printf 'inet6 %s scope global\n' "$4" >> "$MOCK_CFG_DIR/ip.added"
    fi
    exit "$st"
fi
if [[ "$args" == *"-o link show"* ]]; then
    cat "$MOCK_CFG_DIR/ip.links" 2>/dev/null || true
    exit 0
fi
if [[ "$args" == *"-6 addr show"* ]]; then
    cat "$MOCK_CFG_DIR/ip.6addr" 2>/dev/null || true
    cat "$MOCK_CFG_DIR/ip.added" 2>/dev/null || true
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/ip"

    # --- systemctl: is-active reads a per-service flag file ---
    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl' >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
if [[ "$1" == "is-active" && "$2" == "--quiet" ]]; then
    [[ -f "$MOCK_CFG_DIR/systemctl.active.$3" ]] && exit 0 || exit 1
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/systemctl"

    make_mock sleep
    make_mock clear

    export SYSCTL_CONFIG="$BATS_TEST_TMPDIR/99-disable-ipv6.conf"
    export SYSCTL_LEGACY="$BATS_TEST_TMPDIR/sysctl.conf"
    export IFACES_FILE="$BATS_TEST_TMPDIR/interfaces"

    load_component components/configure_ipv6.sh
}

@test "check_ipv6_status: reports DISABLED when sysctl says 1" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 1
    printf 'x' > "$SYSCTL_CONFIG"
    run check_ipv6_status
    [ "$status" -eq 1 ]
    assert_output_contains "DISABLED"
    assert_output_contains "$SYSCTL_CONFIG"
}

@test "check_ipv6_status: reports ENABLED with detected addresses" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    printf 'inet6 2001:db8::1/64 scope global\n' > "$MOCK_CFG_DIR/ip.6addr"
    run check_ipv6_status
    [ "$status" -eq 0 ]
    assert_output_contains "ENABLED"
    assert_output_contains "IPv6 addresses detected"
    assert_output_contains "2001:db8::1"
}

@test "check_ipv6_status: ENABLED with no addresses" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    run check_ipv6_status
    [ "$status" -eq 0 ]
    assert_output_contains "ENABLED"
}

@test "enable_ipv6: success path removes config, cleans legacy, restarts networking" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    printf 'inet6 2001:db8::1/64 scope global\n' > "$MOCK_CFG_DIR/ip.6addr"
    make_mock ping6 --out '64 bytes' --status 0
    printf 'x' > "$SYSCTL_CONFIG"
    printf 'net.ipv6.conf.all.disable_ipv6=1\n' > "$SYSCTL_LEGACY"
    touch "$MOCK_CFG_DIR/systemctl.active.networking"

    run enable_ipv6
    [ "$status" -eq 0 ]
    [[ ! -e "$SYSCTL_CONFIG" ]]
    assert_output_contains "IPv6 is now enabled"
    assert_output_contains "IPv6 internet connectivity working"
    assert_output_contains "Cleaned $SYSCTL_LEGACY"
    assert_mock_called systemctl 3   # is-active networking, restart networking, is-active NetworkManager
    [[ ! -s "$SYSCTL_LEGACY" ]]
}

@test "enable_ipv6: warns when no global addresses and ping6 fails" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    make_mock ping6 --status 1
    run enable_ipv6
    [ "$status" -eq 0 ]
    assert_output_contains "No global IPv6 addresses detected yet"
    assert_output_contains "IPv6 internet connectivity test failed"
}

@test "enable_ipv6: fails when sysctl write does not take effect" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 1
    touch "$MOCK_CFG_DIR/sysctl.nowrite"
    run enable_ipv6
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to enable IPv6"
}

@test "disable_ipv6: --yes applies without prompting" {
    IPV6_ASSUME_YES=true
    set_sysctl net.ipv6.conf.all.disable_ipv6 1
    run disable_ipv6
    [ "$status" -eq 0 ]
    assert_output_contains "IPv6 is now disabled"
    assert_file_contains "$SYSCTL_CONFIG" "net.ipv6.conf.all.disable_ipv6=1"
}

@test "disable_ipv6 via pty: interactive confirm yes" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 1
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'disable_ipv6')"
    run_pty "$inner" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"IPv6 is now disabled"* ]]
    assert_file_contains "$SYSCTL_CONFIG" "net.ipv6.conf.all.disable_ipv6=1"
}

@test "disable_ipv6 via pty: declined -> 1" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'disable_ipv6')"
    run_pty "$inner" "n"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"cancelled"* ]]
}

@test "disable_ipv6: fails when verification stays enabled" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    touch "$MOCK_CFG_DIR/sysctl.nowrite"
    IPV6_ASSUME_YES=true
    run disable_ipv6
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to disable IPv6"
}

@test "configure_ipv6_address via pty: adds address and persists via interfaces file" {
    set_ifaces eth0
    printf 'inet6 2001:db8::1/64 scope global\n' > "$MOCK_CFG_DIR/ip.6addr"
    printf 'auto lo\n' > "$IFACES_FILE"
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "y" "2001:db8::2/64" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"IPv6 address added successfully"* ]]
    assert_file_contains "$IFACES_FILE" "2001:db8::2/64"
}

@test "configure_ipv6_address via pty: manual persistence when no config system" {
    set_ifaces eth0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "2001:db8::2/64" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Manual configuration required"* ]]
    [[ "$PTY_OUT" == *"IPv6 address added successfully"* ]]
}

@test "configure_ipv6_address via pty: no interfaces -> 1" {
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"No network interfaces found"* ]]
}

@test "configure_ipv6_address via pty: invalid interface selection -> 1" {
    set_ifaces eth0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "99"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Invalid interface selection"* ]]
}

@test "configure_ipv6_address via pty: empty input -> 1" {
    set_ifaces eth0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" ""
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"IPv6 address cannot be empty"* ]]
}

@test "configure_ipv6_address via pty: invalid IPv6 format -> 1" {
    set_ifaces eth0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "not-an-ip" "y"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Invalid IPv6 address format"* ]]
}

@test "configure_ipv6_address via pty: invalid prefix -> 1" {
    set_ifaces eth0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "2001:db8::1/999" "y"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Invalid IPv6 prefix length"* ]]
}

@test "configure_ipv6_address via pty: add fails and address absent -> 1" {
    set_ifaces eth0
    printf '1' > "$MOCK_CFG_DIR/ip.add.status"
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "2001:db8::2/64" "y"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Failed to add IPv6 address"* ]]
}

@test "configure_ipv6_address via pty: add fails but address exists -> warning" {
    set_ifaces eth0
    printf 'inet6 2001:db8::2/64 scope global\n' > "$MOCK_CFG_DIR/ip.6addr"
    printf '1' > "$MOCK_CFG_DIR/ip.add.status"
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'configure_ipv6_address')"
    run_pty "$inner" "1" "y" "2001:db8::2/64" "y"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"already exists"* ]]
    [[ "$PTY_OUT" == *"No changes were made"* ]]
}

@test "show_menu: lists menu and status" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    run show_menu
    [ "$status" -eq 0 ]
    assert_output_contains "IPv6 Configuration Tool"
    assert_output_contains "1) Enable IPv6"
}

@test "main: enable mode" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    IPV6_MODE="enable"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "IPv6 is now enabled"
}

@test "main: status mode prints detailed sysctl" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 1
    set_sysctl net.ipv6.conf.default.disable_ipv6 1
    set_sysctl net.ipv6.conf.lo.disable_ipv6 1
    IPV6_MODE="status"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "Detailed IPv6 status"
    assert_output_contains "net.ipv6.conf.lo.disable_ipv6 = 1"
}

@test "main via pty: interactive menu exit (0)" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'main')"
    run_pty "$inner" "0"
    [ "$PTY_RC" -eq 0 ]
    [[ "$PTY_OUT" == *"Exiting"* ]]
}

@test "main via pty: interactive menu invalid -> 1" {
    set_sysctl net.ipv6.conf.all.disable_ipv6 0
    local inner
    inner="$(make_inner components/configure_ipv6.sh 'main')"
    run_pty "$inner" "9"
    [ "$PTY_RC" -eq 1 ]
    [[ "$PTY_OUT" == *"Invalid choice"* ]]
}
