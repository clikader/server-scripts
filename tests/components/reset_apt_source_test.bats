#!/usr/bin/env bats
load ../test_helper

setup() {
    setup_mocks
    make_mock apt-get
    export APT_ARCH=amd64
    export APT_SOURCES_LIST="$BATS_TEST_TMPDIR/sources.list"
    export APT_SOURCES_LIST_D="$BATS_TEST_TMPDIR/sources.list.d"
    mkdir -p "$APT_SOURCES_LIST_D"
    printf 'deb https://provider.example/ stable main\n' > "$APT_SOURCES_LIST"
    printf 'provider config\n' > "$APT_SOURCES_LIST_D/provider.sources"
    load_component components/reset_apt_source.sh
}

@test "APT help and unknown flags never modify sources" {
    run bash "$REPO_ROOT/components/reset_apt_source.sh" --help
    [ "$status" -eq 0 ]
    run bash "$REPO_ROOT/components/reset_apt_source.sh" --nope
    [ "$status" -eq 2 ]
    assert_file_contains "$APT_SOURCES_LIST_D/provider.sources" 'provider config'
    [ ! -s "$MOCK_CFG_DIR/calls" ]
}

@test "unsupported OS is rejected before cleanup" {
    os_name=fedora; os_version=40
    run main
    [ "$status" -eq 1 ]
    assert_file_contains "$APT_SOURCES_LIST_D/provider.sources" 'provider config'
}

@test "EOL Ubuntu release is rejected before cleanup" {
    os_name=ubuntu; os_version=24.10
    run main
    [ "$status" -eq 1 ]
    assert_file_contains "$APT_SOURCES_LIST_D/provider.sources" 'provider config'
}

@test "Debian 11 12 13 emit signed official sources with correct firmware components" {
    local version
    for version in 11 12 13; do
        run generate_debian_sources_deb822 "$version"
        [ "$status" -eq 0 ]
        assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg'
    done
    run generate_debian_sources_deb822 11
    ! grep -q non-free-firmware "$APT_SOURCES_LIST_D/debian.sources"
    run generate_debian_sources_deb822 13
    assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" 'non-free-firmware'
}

@test "Ubuntu LTS releases use correct suites" {
    local pair version codename
    for pair in '20.04 focal' '22.04 jammy' '24.04 noble' '26.04 resolute'; do
        read -r version codename <<< "$pair"
        run generate_ubuntu_sources_deb822 "$version"
        [ "$status" -eq 0 ]
        assert_file_contains "$APT_SOURCES_LIST_D/ubuntu.sources" "Suites: $codename $codename-updates"
    done
}

@test "Ubuntu arm64 uses ports archive for both updates and security" {
    APT_ARCH=arm64
    run generate_ubuntu_sources_deb822 24.04
    [ "$status" -eq 0 ]
    [ "$(grep -c '^URIs: https://ports.ubuntu.com/ubuntu-ports' "$APT_SOURCES_LIST_D/ubuntu.sources")" -eq 2 ]
    ! grep -q archive.ubuntu.com "$APT_SOURCES_LIST_D/ubuntu.sources"
}

@test "unsupported architecture leaves existing sources intact" {
    APT_ARCH=unknown
    run main
    [ "$status" -eq 1 ]
    assert_file_contains "$APT_SOURCES_LIST_D/provider.sources" 'provider config'
}

@test "failed authenticated apt refresh restores all source files" {
    make_mock apt-get --status 100
    run main
    [ "$status" -eq 1 ]
    assert_file_contains "$APT_SOURCES_LIST" 'provider.example'
    assert_file_contains "$APT_SOURCES_LIST_D/provider.sources" 'provider config'
    [ ! -f "$APT_SOURCES_LIST_D/debian.sources" ]
}

@test "successful reset verifies apt and records configuration ownership" {
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" trixie
    [ ! -f "$APT_SOURCES_LIST_D/provider.sources" ]
    [ -f "$CLIKADER_STATE_DIR/managed/apt.sha256" ]
    grep -q 'APT::Update::Error-Mode=any' "$MOCK_CFG_DIR/calls"
}

@test "reset is idempotent and preserves inactive backups and keys" {
    printf 'key material\n' > "$APT_SOURCES_LIST_D/provider.gpg"
    printf 'old backup\n' > "$APT_SOURCES_LIST_D/provider.list.save"
    run main
    [ "$status" -eq 0 ]
    first="$(cat "$APT_SOURCES_LIST_D/debian.sources")"
    run main
    [ "$status" -eq 0 ]
    [ "$(cat "$APT_SOURCES_LIST_D/debian.sources")" = "$first" ]
    assert_file_contains "$APT_SOURCES_LIST_D/provider.gpg" 'key material'
    assert_file_contains "$APT_SOURCES_LIST_D/provider.list.save" 'old backup'
}

@test "Ubuntu reset preserves official entitlement-managed ESM security sources" {
    os_name=ubuntu; os_version=20.04
    printf 'Types: deb\nURIs: https://esm.ubuntu.com/infra/ubuntu\nSuites: focal-infra-security\n' > "$APT_SOURCES_LIST_D/ubuntu-esm-infra.sources"
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/ubuntu-esm-infra.sources" 'focal-infra-security'
    [ ! -f "$APT_SOURCES_LIST_D/provider.sources" ]
}
