#!/usr/bin/env bats
load test_helper

setup() {
    setup_mocks
    export CLIKADER_INSTALL_ROOT="$BATS_TEST_TMPDIR/install"
    export CLIKADER_BIN_DIR="$BATS_TEST_TMPDIR/bin"
}

@test "installer help is non-root and read-only" {
    run setpriv --reuid=65534 --regid=65534 --clear-groups bash "$REPO_ROOT/install.sh" --help
    [ "$status" -eq 0 ]
    [ ! -e "$CLIKADER_INSTALL_ROOT" ]
}

@test "installer refuses installation as non-root" {
    run setpriv --reuid=65534 --regid=65534 --clear-groups bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 1 ]
    assert_output_contains 'must be run as root'
}

@test "complete local bundle installs and commands run with networking unavailable" {
    make_mock curl --status 1
    run bash "$REPO_ROOT/install.sh" --from "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$CLIKADER_BIN_DIR/clikader" ]
    [ -f "$CLIKADER_INSTALL_ROOT/current/components/setup_dns.sh" ]
    [ "$(stat -c %u "$CLIKADER_INSTALL_ROOT/current/components/setup_dns.sh")" -eq 0 ]
    run "$CLIKADER_BIN_DIR/clikader" dns --help
    [ "$status" -eq 0 ]
    assert_output_contains 'Usage: clikader dns'
    [ ! -s "$MOCK_CFG_DIR/calls" ]
}

@test "failed download leaves the working bundle intact" {
    bash "$REPO_ROOT/install.sh" --from "$REPO_ROOT"
    original="$(readlink "$CLIKADER_INSTALL_ROOT/current")"
    make_mock curl --status 1
    run bash "$REPO_ROOT/install.sh" --update --yes
    [ "$status" -eq 1 ]
    [ "$(readlink "$CLIKADER_INSTALL_ROOT/current")" = "$original" ]
    run "$CLIKADER_BIN_DIR/clikader" --version
    [ "$status" -eq 0 ]
}

@test "invalid staged bundle cannot replace an installed release" {
    bash "$REPO_ROOT/install.sh" --from "$REPO_ROOT"
    original="$(readlink "$CLIKADER_INSTALL_ROOT/current")"
    mkdir "$BATS_TEST_TMPDIR/source"
    cp -a "$REPO_ROOT/clikader.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/components" "$REPO_ROOT/lib" "$BATS_TEST_TMPDIR/source/"
    printf 'if (\n' > "$BATS_TEST_TMPDIR/source/components/setup_dns.sh"
    run bash "$REPO_ROOT/install.sh" --from "$BATS_TEST_TMPDIR/source"
    [ "$status" -ne 0 ]
    [ "$(readlink "$CLIKADER_INSTALL_ROOT/current")" = "$original" ]
}

@test "update and rollback switch entire bundles atomically" {
    bash "$REPO_ROOT/install.sh" --from "$REPO_ROOT"
    original="$(readlink "$CLIKADER_INSTALL_ROOT/current")"
    mkdir "$BATS_TEST_TMPDIR/source"
    cp -a "$REPO_ROOT/clikader.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/components" "$REPO_ROOT/lib" "$BATS_TEST_TMPDIR/source/"
    printf '\n# new revision\n' >> "$BATS_TEST_TMPDIR/source/components/setup_dns.sh"
    run bash "$REPO_ROOT/install.sh" --update --yes --from "$BATS_TEST_TMPDIR/source"
    [ "$status" -eq 0 ]
    [ "$(readlink "$CLIKADER_INSTALL_ROOT/current")" != "$original" ]
    run "$CLIKADER_BIN_DIR/clikader" update --rollback
    [ "$status" -eq 0 ]
    [ "$(readlink "$CLIKADER_INSTALL_ROOT/current")" = "$original" ]
}

@test "installer rejects unknown arguments before changing files" {
    run bash "$REPO_ROOT/install.sh" --nope
    [ "$status" -eq 2 ]
    [ ! -e "$CLIKADER_INSTALL_ROOT" ]
}
