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
    export LOCK_FILE="$BATS_TEST_TMPDIR/tcp.lock"
    export INITCWND_HOOK_DIR="$BATS_TEST_TMPDIR/networkd-dispatcher"
    export INITCWND_SERVICE="$BATS_TEST_TMPDIR/systemd/clikader-tcp-initcwnd.service"
    export SWAPFILE_PATH="$BATS_TEST_TMPDIR/swapfile"
    export FSTAB="$BATS_TEST_TMPDIR/fstab"
    export MEM_TOTAL_KB=1048576     # 1GB
    export BANDWIDTH_MBPS=1000
    mkdir -p "$DROPIN_DIR" "$BACKUP_DIR" "$SYSTEMD_OVERRIDE_DIR"
    printf '* soft nofile 1024\n' > "$LIMITS_FILE"
    printf '# fstab\n' > "$FSTAB"
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
    # fallocate must actually create the target file (chmod/mkswap follow it).
    cat > "$MOCK_BIN/fallocate" <<'MOCK'
#!/usr/bin/env bash
me="$(basename "$0")"
printf '%s' "$me" >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
: > "${@: -1}"
MOCK
    chmod +x "$MOCK_BIN/fallocate"
    make_mock systemctl
    make_mock lsmod --out ""
    make_mock modprobe --status 1
    make_mock sleep
    make_mock ip --out "default via 10.0.0.1 dev eth0 proto dhcp metric 100"
    make_mock mkswap
    make_mock swapon
    make_mock swapoff
    load_component components/optimize_tcp.sh
}

# Value of a key in the DK_* desired-state arrays (fails if key absent).
dk_val() {
    local i
    for i in "${!DK_KEYS[@]}"; do
        if [[ "${DK_KEYS[$i]}" == "$1" ]]; then
            echo "${DK_VALS[$i]}"
            return 0
        fi
    done
    return 1
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

@test "calc_buf_max: BDP-derived with RAM cap, ceiling and floor" {
    # 1Gbps + 1GB RAM -> 2*BDP+2MiB = 39.6MB, capped at RAM/32 = 32MiB
    run calc_buf_max 1000 1048576
    [ "$output" = "33554432" ]
    # 1Gbps + 512MB RAM -> capped at 16MiB
    run calc_buf_max 1000 524288
    [ "$output" = "16777216" ]
    # 100Gbps + 64GB RAM -> 256MiB ceiling
    run calc_buf_max 100000 67108864
    [ "$output" = "268435456" ]
    # 10Mbps -> 4MiB floor
    run calc_buf_max 10 1048576
    [ "$output" = "4194304" ]
}

@test "calc_tcp_mem: RAM-derived page triple with floors" {
    # 1GB / 4KiB = 262144 pages -> /16 /8 /4
    run calc_tcp_mem 1048576
    [ "$output" = "16384 32768 65536" ]
    # 128MB -> 32768 pages -> all floors kick in
    run calc_tcp_mem 131072
    [ "$output" = "4096 8192 16384" ]
}

@test "mem_total_kb / detect_bandwidth_mbps: env overrides win" {
    run mem_total_kb
    [ "$output" = "1048576" ]
    run detect_bandwidth_mbps
    [ "$output" = "1000" ]
}

@test "detect_bandwidth_mbps: falls back to 1000 when undetectable" {
    unset BANDWIDTH_MBPS
    make_mock ip --out ""   # no default route visible
    run detect_bandwidth_mbps
    [ "$output" = "1000" ]
}

@test "build_desired: includes BDP/RAM-derived and new keys" {
    build_desired
    run dk_val net.core.rmem_max
    [ "$output" = "33554432" ]
    run dk_val net.ipv4.tcp_mem
    [ "$output" = "16384 32768 65536" ]
    run dk_val net.ipv4.tcp_rmem
    [ "$output" = "4096 1048576 33554432" ]
    run dk_val net.core.rmem_default
    [ "$output" = "1048576" ]
    run dk_val net.ipv4.tcp_dsack
    [ "$output" = "1" ]
    run dk_val net.ipv4.tcp_adv_win_scale
    [ "$output" = "1" ]
    run dk_val vm.min_free_kbytes
    [ "$output" = "32768" ]
}

@test "build_desired: bumped queue keys keep higher live values" {
    set_sysctl net.core.somaxconn 65535
    set_sysctl net.core.netdev_max_backlog 99999
    set_sysctl net.ipv4.tcp_max_syn_backlog 16384
    build_desired
    run dk_val net.core.somaxconn
    [ "$output" = "65535" ]
    run dk_val net.core.netdev_max_backlog
    [ "$output" = "99999" ]
    run dk_val net.ipv4.tcp_max_syn_backlog
    [ "$output" = "16384" ]
}

@test "build_desired: vm.swappiness only when swap marker exists" {
    build_desired
    run dk_val vm.swappiness
    [ "$status" -eq 1 ]
    : > "$BACKUP_DIR/swapfile.owned"
    build_desired
    run dk_val vm.swappiness
    [ "$output" = "10" ]
}

@test "verify_applied: warns when live values do not match desired" {
    build_desired
    run verify_applied
    [ "$status" -eq 0 ]
    assert_output_contains "Verify:"
}

@test "take_lock: fails when another instance holds the lock" {
    command -v flock >/dev/null 2>&1 || skip "flock not available"
    exec 9>"$LOCK_FILE"
    flock -n 9
    run take_lock
    [ "$status" -eq 1 ]
    assert_output_contains "Another clikader tcp instance"
    exec 9>&-
}

@test "apply_initcwnd: rewrites default route and persists via systemd unit" {
    run apply_initcwnd
    [ "$status" -eq 0 ]
    [ -f "$BACKUP_DIR/default-route.snapshot" ]
    [ -f "$BACKUP_DIR/initcwnd.owned" ]
    [ -f "$INITCWND_SERVICE" ]
    mock_last_args ip | grep -q "route replace"
    mock_last_args ip | grep -q "initcwnd 32"
    grep -q "proto dhcp metric 100" "$INITCWND_SERVICE"
}

@test "apply_initcwnd: uses networkd-dispatcher hook when available" {
    mkdir -p "$INITCWND_HOOK_DIR"
    run apply_initcwnd
    [ "$status" -eq 0 ]
    [ -f "$INITCWND_HOOK_DIR/50-clikader-initcwnd" ]
    [ ! -f "$INITCWND_SERVICE" ]
}

@test "apply_initcwnd: skips links <=100Mbps" {
    BANDWIDTH_MBPS=100 run apply_initcwnd
    [ "$status" -eq 0 ]
    assert_output_contains "skipping initcwnd"
    [ ! -f "$BACKUP_DIR/initcwnd.owned" ]
}

@test "revert_initcwnd: restores route and removes artifacts" {
    run apply_initcwnd
    [ -f "$INITCWND_SERVICE" ]
    run revert_initcwnd
    [ "$status" -eq 0 ]
    [ ! -f "$INITCWND_SERVICE" ]
    [ ! -f "$BACKUP_DIR/initcwnd.owned" ]
    [ ! -f "$BACKUP_DIR/default-route.snapshot" ]
    assert_output_contains "Restored original default route"
}

@test "apply_swap: refuses to overwrite a non-owned swapfile" {
    : > "$SWAPFILE_PATH"
    run apply_swap 2G
    [ "$status" -eq 1 ]
    assert_output_contains "refusing to overwrite"
}

@test "apply_swap: rejects an invalid size" {
    run apply_swap bogus
    [ "$status" -eq 2 ]
}

@test "apply_swap: creates swapfile, fstab block and marker" {
    run apply_swap 2G
    [ "$status" -eq 0 ]
    [ -f "$BACKUP_DIR/swapfile.owned" ]
    assert_file_contains "$FSTAB" "BEGIN clikader-tcp swap"
    assert_file_contains "$FSTAB" "$SWAPFILE_PATH none swap sw 0 0"
    assert_mock_called mkswap
    assert_mock_called swapon
}

@test "revert_swap: swapoff, fstab cleanup, file removal" {
    run apply_swap 2G
    [ -f "$SWAPFILE_PATH" ]
    run revert_swap
    [ "$status" -eq 0 ]
    [ ! -f "$SWAPFILE_PATH" ]
    [ ! -f "$BACKUP_DIR/swapfile.owned" ]
    ! grep -q "clikader-tcp swap" "$FSTAB"
    assert_mock_called swapoff
}

@test "do_apply: drop-in includes vm.swappiness when swap was requested" {
    set_sysctl net.ipv4.tcp_available_congestion_control "cubic bbr"
    run apply_swap 2G
    run do_apply
    [ "$status" -eq 0 ]
    grep -q "vm.swappiness" "$DROPIN"
}
