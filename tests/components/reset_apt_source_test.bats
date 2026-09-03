#!/usr/bin/env bash
# Tests for components/reset_apt_source.sh
load ../test_helper

setup() {
    setup_mocks
    make_mock apt-get
    export APT_SOURCES_LIST="$BATS_TEST_TMPDIR/sources.list"
    export APT_SOURCES_LIST_D="$BATS_TEST_TMPDIR/sources.list.d"
    mkdir -p "$APT_SOURCES_LIST_D"
    printf '# old\n' > "$APT_SOURCES_LIST"
    load_component components/reset_apt_source.sh
}

@test "backup_sources: copies sources.list and sources.list.d" {
    printf 'deb http://example\n' > "$APT_SOURCES_LIST"
    printf 'extra\n' > "$APT_SOURCES_LIST_D/extra.list"
    run backup_sources
    [ "$status" -eq 0 ]
    assert_output_contains "Backup location"
}

@test "generate_debian_sources_deb822: debian 13 and 12, rejects others" {
    run generate_debian_sources_deb822 13
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" "trixie"
    run generate_debian_sources_deb822 12
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" "bookworm"
    run generate_debian_sources_deb822 11
    [ "$status" -eq 1 ]
}

@test "generate_debian_sources: 13 / 12 / 11 / unsupported" {
    run generate_debian_sources 13
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "trixie"
    run generate_debian_sources 12
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "bookworm"
    run generate_debian_sources 11
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "bullseye"
    run generate_debian_sources 10
    [ "$status" -eq 1 ]
    assert_output_contains "Unsupported Debian version"
}

@test "generate_ubuntu_sources_deb822: 24.10 / 24.04 / other" {
    run generate_ubuntu_sources_deb822 24.10 oracular
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/ubuntu.sources" "oracular"
    run generate_ubuntu_sources_deb822 24.04 noble
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/ubuntu.sources" "noble"
    run generate_ubuntu_sources_deb822 22.04 jammy
    [ "$status" -eq 1 ]
}

@test "generate_ubuntu_sources: 24.10 / 24.04 / 22.04 / 20.04 / unsupported" {
    run generate_ubuntu_sources 24.10 oracular
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "oracular"
    run generate_ubuntu_sources 24.04 noble
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "noble"
    run generate_ubuntu_sources 22.04 jammy
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "jammy"
    run generate_ubuntu_sources 20.04 focal
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "focal"
    run generate_ubuntu_sources 18.04 bionic
    [ "$status" -eq 1 ]
}

@test "clean_sources_list_d: removes list/sources/save/distUpgrade/gpg files" {
    printf 'x\n' > "$APT_SOURCES_LIST_D/foo.list"
    printf 'x\n' > "$APT_SOURCES_LIST_D/foo.sources"
    printf 'x\n' > "$APT_SOURCES_LIST_D/foo.list.save"
    printf 'x\n' > "$APT_SOURCES_LIST_D/foo.distUpgrade"
    printf 'x\n' > "$APT_SOURCES_LIST_D/foo.gpg"
    printf 'x\n' > "${APT_SOURCES_LIST}.save"
    run clean_sources_list_d
    [ "$status" -eq 0 ]
    [ ! -e "$APT_SOURCES_LIST_D/foo.list" ]
    [ ! -e "$APT_SOURCES_LIST_D/foo.sources" ]
    [ ! -e "${APT_SOURCES_LIST}.save" ]
}

@test "clean_sources_list_d: empty dir is a no-op info" {
    run clean_sources_list_d
    [ "$status" -eq 0 ]
    assert_output_contains "No third-party sources found"
}

@test "update_apt_cache: success and fallback warning" {
    make_mock apt-get --status 0
    run update_apt_cache
    [ "$status" -eq 0 ]
    assert_output_contains "APT cache updated successfully"

    make_mock apt-get --status 1 --out "err"
    run update_apt_cache
    [ "$status" -eq 1 ]
    assert_output_contains "encountered some issues"
}

@test "verify_sources: finds traditional list, deb822, or neither" {
    printf 'deb http://deb.debian.org/debian trixie main\n' > "$APT_SOURCES_LIST"
    run verify_sources
    [ "$status" -eq 0 ]
    assert_output_contains "sources.list exists"

    printf '# comment only\n' > "$APT_SOURCES_LIST"
    printf 'Types: deb\n' > "$APT_SOURCES_LIST_D/debian.sources"
    run verify_sources
    [ "$status" -eq 0 ]
    assert_output_contains "debian.sources"

    printf '# comment\n' > "$APT_SOURCES_LIST"
    rm -f "$APT_SOURCES_LIST_D"/*.sources
    run verify_sources
    [ "$status" -eq 1 ]
    assert_output_contains "No APT sources found"
}

@test "main: debian 13 uses DEB822" {
    os_name="debian"
    os_version="13"
    run main
    [ "$status" -eq 0 ]
    assert_output_contains "APT sources reset successfully"
    assert_file_contains "$APT_SOURCES_LIST_D/debian.sources" "trixie"
}

@test "main: debian 11 uses legacy sources.list" {
    os_name="debian"
    os_version="11"
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "bullseye"
}

@test "main: ubuntu 24.04 uses DEB822" {
    os_name="ubuntu"
    os_version="24.04"
    os_codename="noble"
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST_D/ubuntu.sources" "noble"
}

@test "main: ubuntu 22.04 uses traditional sources.list" {
    os_name="ubuntu"
    os_version="22.04"
    os_codename="jammy"
    run main
    [ "$status" -eq 0 ]
    assert_file_contains "$APT_SOURCES_LIST" "jammy"
}

@test "main: unsupported OS exits 1" {
    os_name="fedora"
    os_version="40"
    run main
    [ "$status" -eq 1 ]
    assert_output_contains "Unsupported OS"
}
