#!/usr/bin/env bash
# Tests for install.sh (top-to-bottom installer; no functions to source)
load test_helper

setup() {
    setup_mocks
}

@test "install.sh: refuses to run as non-root" {
    run setpriv --reuid=65534 --regid=65534 --clear-groups -- \
        env PATH="$PATH" bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 1 ]
    assert_output_contains "must be run as root"
}

@test "install.sh: curl failure exits 1" {
    make_mock curl --status 1
    # Point INSTALL by running a patched copy that writes to tmp
    local copy="$BATS_TEST_TMPDIR/install.sh"
    sed 's|INSTALL_DIR="/usr/local/bin"|INSTALL_DIR="'"$BATS_TEST_TMPDIR/bin"'"|' \
        "$REPO_ROOT/install.sh" > "$copy"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    run bash "$copy"
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to download"
}

@test "install.sh: success writes executable clikader" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$MOCK_BIN/curl" <<MOCK
#!/usr/bin/env bash
out="\${@: -1}"
printf '#!/usr/bin/env bash\nCLIKADER_VERSION="9.9.9"\n' > "\$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    local copy="$BATS_TEST_TMPDIR/install.sh"
    sed 's|INSTALL_DIR="/usr/local/bin"|INSTALL_DIR="'"$BATS_TEST_TMPDIR/bin"'"|' \
        "$REPO_ROOT/install.sh" > "$copy"
    # Ensure command -v clikader succeeds by putting the install dir on PATH
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$copy"
    [ "$status" -eq 0 ]
    assert_output_contains "Installation Successful"
    assert_output_contains "9.9.9"
    [ -x "$BATS_TEST_TMPDIR/bin/clikader" ]
}

@test "install.sh (real file): downloads to /usr/local/bin" {
    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
out="${@: -1}"
printf '#!/usr/bin/env bash\nCLIKADER_VERSION="9.9.9"\n' > "$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    export PATH="/usr/local/bin:$PATH"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    assert_output_contains "Installation Successful"
    [ -x /usr/local/bin/clikader ]
}

@test "install.sh (real file): reinstall path prints current version" {
    mkdir -p /usr/local/bin
    printf '#!/usr/bin/env bash\nCLIKADER_VERSION="0.1.0"\n' > /usr/local/bin/clikader
    chmod +x /usr/local/bin/clikader
    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
out="${@: -1}"
printf '#!/usr/bin/env bash\nCLIKADER_VERSION="9.9.9"\n' > "$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    export PATH="/usr/local/bin:$PATH"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    assert_output_contains "already installed"
    assert_output_contains "Current version: 0.1.0"
}

@test "install.sh (real file): curl failure" {
    make_mock curl --status 1
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to download"
}

@test "install.sh (real file): installed but not on PATH" {
    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
out="${@: -1}"
printf '#!/usr/bin/env bash\nCLIKADER_VERSION="9.9.9"\n' > "$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    # Drop /usr/local/bin so command -v clikader fails after install
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    assert_output_contains "not found in PATH"
}

@test "install.sh: reinstalls when already present" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nCLIKADER_VERSION="0.0.1"\n' > "$BATS_TEST_TMPDIR/bin/clikader"
    chmod +x "$BATS_TEST_TMPDIR/bin/clikader"
    cat > "$MOCK_BIN/curl" <<MOCK
#!/usr/bin/env bash
out="\${@: -1}"
printf '#!/usr/bin/env bash\nCLIKADER_VERSION="9.9.9"\n' > "\$out"
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"
    local copy="$BATS_TEST_TMPDIR/install.sh"
    sed 's|INSTALL_DIR="/usr/local/bin"|INSTALL_DIR="'"$BATS_TEST_TMPDIR/bin"'"|' \
        "$REPO_ROOT/install.sh" > "$copy"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$copy"
    [ "$status" -eq 0 ]
    assert_output_contains "already installed"
    assert_output_contains "Current version: 0.0.1"
}
