#!/usr/bin/env bats
load ../test_helper
setup() {
    setup_mocks
    make_mock apt-get
    make_mock apt-config
    make_mock systemctl
    export APT_SECURITY_CONF="$BATS_TEST_TMPDIR/99-security"
    export OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
    printf 'ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n' > "$OS_RELEASE"
    load_component components/maintenance.sh
}

@test "security updates are security-only and never reboot automatically" {
    run main enable-security-updates
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SECURITY_CONF" 'Automatic-Reboot "false"'
    assert_file_contains "$APT_SECURITY_CONF" 'label=Debian-Security,codename=trixie-security'
    assert_file_contains "$APT_SECURITY_CONF" '#clear Unattended-Upgrade::Allowed-Origins'
    grep -q 'enable --now apt-daily.timer apt-daily-upgrade.timer' "$MOCK_CFG_DIR/calls"
}

@test "Ubuntu security origins include entitled ESM security feeds" {
    printf 'ID=ubuntu\nVERSION_ID=24.04\nVERSION_CODENAME=noble\n' > "$OS_RELEASE"
    run main enable-security-updates
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SECURITY_CONF" 'origin=Ubuntu,archive=noble-security'
    assert_file_contains "$APT_SECURITY_CONF" 'noble-infra-security'
}

@test "bad apt configuration rolls back previous automatic update policy" {
    printf previous > "$APT_SECURITY_CONF"
    make_mock apt-config --status 1
    run main enable-security-updates
    [ "$status" -eq 1 ]
    [ "$(cat "$APT_SECURITY_CONF")" = previous ]
}

@test "maintenance upgrade propagates refresh failure without upgrading" {
    make_mock apt-get --status 100
    run main upgrade
    [ "$status" -ne 0 ]
    ! grep -q ' upgrade ' "$MOCK_CFG_DIR/calls"
}

@test "maintenance upgrade installs new packages by default so kernels are not held back" {
    run main upgrade
    [ "$status" -eq 0 ]
    grep -q 'upgrade --with-new-pkgs -y' "$MOCK_CFG_DIR/calls"
}

@test "maintenance upgrade --without-new-pkgs keeps plain upgrade semantics" {
    run main upgrade --without-new-pkgs
    [ "$status" -eq 0 ]
    grep -qE ' upgrade -y' "$MOCK_CFG_DIR/calls"
    ! grep -q -- '--with-new-pkgs' "$MOCK_CFG_DIR/calls"
}

@test "maintenance upgrade rejects unknown options" {
    run main upgrade --verbose
    [ "$status" -eq 2 ]
    ! grep -q ' upgrade ' "$MOCK_CFG_DIR/calls"
}

@test "disable security updates explicitly disables unattended installation" {
    run main disable-security-updates
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SECURITY_CONF" 'Unattended-Upgrade "0"'
}

@test "unsupported release fails before installation and configuration" {
    printf 'ID=ubuntu\nVERSION_ID=24.10\nVERSION_CODENAME=oracular\n' > "$OS_RELEASE"
    run main enable-security-updates
    [ "$status" -eq 1 ]
    [ ! -e "$APT_SECURITY_CONF" ]
    [ ! -s "$MOCK_CFG_DIR/calls" ]
}
