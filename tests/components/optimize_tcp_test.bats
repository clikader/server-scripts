#!/usr/bin/env bash
# Tests for components/optimize_tcp.sh
load ../test_helper

setup() {
    setup_mocks
    export SYSCONF="$BATS_TEST_TMPDIR/sysctl.conf"
    export DROPIN_DIR="$BATS_TEST_TMPDIR/sysctl.d"
    export BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export BBR_MODULE_FILE="$BATS_TEST_TMPDIR/bbr.conf"
    export LIMITS_FILE="$BATS_TEST_TMPDIR/limits.conf"
    export SYSTEMD_OVERRIDE_DIR="$BATS_TEST_TMPDIR/systemd.conf.d"
    mkdir -p "$DROPIN_DIR" "$BACKUP_DIR" "$SYSTEMD_OVERRIDE_DIR"
    printf '* soft nofile 1024\n' > "$LIMITS_FILE"
    : > "$SYSCONF"

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
    printf '%s' "$val" > "$MOCK_CFG_DIR/sysctl.$(enc "$key")"
    exit 0
elif [[ "$1" == "-p" || "$1" == "--system" ]]; then
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/sysctl"
    make_mock systemctl
    make_mock lsmod --out ""
    make_mock modprobe --status 1
    make_mock sleep
    load_component components/optimize_tcp.sh
}

set_sysctl() {
    local key="$1" val="$2"
    printf '%s' "$val" > "$MOCK_CFG_DIR/sysctl.$(printf '%s' "$key" | tr '.' '_')"
}

@test "get_live: returns sysctl -n output" {
    set_sysctl net.core.rmem_max 4096
    run get_live net.core.rmem_max
    [ "$output" = "4096" ]
}

@test "floor_numeric: keeps higher live value, else desired" {
    set_sysctl net.core.rmem_max 99999999
    run floor_numeric net.core.rmem_max 100
    [ "$output" = "99999999" ]
    set_sysctl net.core.rmem_max 1
    run floor_numeric net.core.rmem_max 100
    [ "$output" = "100" ]
}

@test "floor_tuple: keeps live tuple when upper bound already high" {
    set_sysctl net.ipv4.tcp_rmem "4096 87380 33554432"
    run floor_tuple net.ipv4.tcp_rmem "4096 87380 1000"
    [ "$output" = "4096 87380 33554432" ]
    set_sysctl net.ipv4.tcp_rmem "4096 87380 1000"
    run floor_tuple net.ipv4.tcp_rmem "4096 87380 33554432"
    [ "$output" = "4096 87380 33554432" ]
}

@test "conntrack_present: returns 0 or 1 depending on the kernel" {
    run conntrack_present
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "ensure_bbr: available via sysctl list" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run ensure_bbr
    [ "$status" -eq 0 ]
}

@test "ensure_bbr: missing even after modprobe -> 1" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic"
    make_mock modprobe --status 1
    run ensure_bbr
    [ "$status" -eq 1 ]
}

@test "build_desired: populates DK_KEYS" {
    set_sysctl net.core.rmem_max 1
    set_sysctl net.core.wmem_max 1
    set_sysctl net.ipv4.tcp_rmem "4096 87380 1000"
    set_sysctl net.ipv4.tcp_wmem "4096 16384 1000"
    set_sysctl fs.file-max 1
    set_sysctl fs.nr_open 1
    build_desired
    [ "${#DK_KEYS[@]}" -gt 10 ]
}

@test "write_dropin / snapshot_live / backup_sysctl_conf / count_neutralized" {
    set_sysctl net.core.rmem_max 1
    build_desired
    run snapshot_live
    [ "$status" -eq 0 ]
    [ -f "$BACKUP_DIR/live-values.snapshot" ]
    # second snapshot is a no-op
    run snapshot_live
    [ "$status" -eq 0 ]

    printf 'net.ipv4.ip_forward=0\n' > "$SYSCONF"
    run backup_sysctl_conf
    [ -f "$BACKUP_DIR/sysctl.conf.orig" ]

    run write_dropin
    [ -f "$DROPIN" ]
    grep -q "Managed by clikader tcp" "$DROPIN"

    run count_neutralized
    [[ "$output" == *"0"* ]]
}

@test "neutralize_sysctl_conf: comments managed keys with perl" {
    build_desired
    key="${DK_KEYS[0]}"
    printf '%s = 0\n' "$key" > "$SYSCONF"
    run neutralize_sysctl_conf
    [ "$status" -eq 0 ]
    grep -q "$MARKER" "$SYSCONF"
}

@test "apply_limits_files: writes limits.conf block and systemd override" {
    run apply_limits_files
    [ "$status" -eq 0 ]
    assert_file_contains "$LIMITS_FILE" "BEGIN clikader-tcp limits"
    assert_file_contains "$SYSTEMD_OVERRIDE" "DefaultLimitNOFILE"
}

@test "do_dryrun: prints CURRENT -> DESIRED table" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run do_dryrun
    [ "$status" -eq 0 ]
    assert_output_contains "dry run"
    assert_output_contains "KEY"
}

@test "do_status: reports missing drop-in" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run do_status
    [ "$status" -eq 0 ]
    assert_output_contains "No clikader drop-in found"
}

@test "do_apply: writes drop-in and limits" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    set_sysctl net.core.rmem_max 1
    set_sysctl net.core.wmem_max 1
    set_sysctl net.ipv4.tcp_rmem "4096 87380 1000"
    set_sysctl net.ipv4.tcp_wmem "4096 16384 1000"
    set_sysctl fs.file-max 1
    set_sysctl fs.nr_open 1
    run do_apply
    [ "$status" -eq 0 ]
    [ -f "$DROPIN" ]
    assert_output_contains "Done. Boot-time order is correct"
}

@test "do_apply: skips congestion_control when BBR unavailable" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic"
    make_mock modprobe --status 1
    run do_apply
    [ "$status" -eq 0 ]
    assert_output_contains "BBR congestion control is NOT available"
}

@test "do_revert: nothing to revert" {
    run do_revert
    [ "$status" -eq 0 ]
    assert_output_contains "Nothing to revert"
}

@test "do_revert: restores sysctl.conf, drop-in, limits, override" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run do_apply
    [ -f "$DROPIN" ]
    run do_revert
    [ "$status" -eq 0 ]
    [ ! -f "$DROPIN" ]
    assert_output_contains "Reverted to pre-script state"
}

@test "do_status: drop-in present after apply" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run do_apply
    run do_status
    [ "$status" -eq 0 ]
    assert_output_contains "Drop-in present"
}
