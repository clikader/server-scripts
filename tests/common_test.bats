#!/usr/bin/env bats
load test_helper
setup() { setup_mocks; source "$REPO_ROOT/lib/common.sh"; }

@test "configuration transaction restores files and absent paths after failure" {
    printf original > "$BATS_TEST_TMPDIR/config"
    inner="$(make_inner lib/common.sh 'tx_begin example; tx_save "$BATS_TEST_TMPDIR/config" "$BATS_TEST_TMPDIR/new"; printf changed > "$BATS_TEST_TMPDIR/config"; touch "$BATS_TEST_TMPDIR/new"; exit 9')"
    run bash "$inner"
    [ "$status" -eq 9 ]
    [ "$(cat "$BATS_TEST_TMPDIR/config")" = original ]
    [ ! -e "$BATS_TEST_TMPDIR/new" ]
}

@test "configuration transaction preserves symlinks on rollback" {
    printf data > "$BATS_TEST_TMPDIR/target"
    ln -s target "$BATS_TEST_TMPDIR/config"
    inner="$(make_inner lib/common.sh 'tx_begin example; tx_save "$BATS_TEST_TMPDIR/config"; rm "$BATS_TEST_TMPDIR/config"; printf other > "$BATS_TEST_TMPDIR/config"; exit 1')"
    run bash "$inner"
    [ "$status" -eq 1 ]
    [ -L "$BATS_TEST_TMPDIR/config" ]
    [ "$(readlink "$BATS_TEST_TMPDIR/config")" = target ]
}

@test "committed configuration retains changes and bounded snapshot history" {
    inner="$(make_inner lib/common.sh 'tx_begin example; tx_save "$BATS_TEST_TMPDIR/config"; printf changed > "$BATS_TEST_TMPDIR/config"; tx_commit')"
    local i
    for i in 1 2 3 4 5 6; do
        run bash "$inner"
        [ "$status" -eq 0 ]
    done
    [ "$(cat "$BATS_TEST_TMPDIR/config")" = changed ]
    [ "$(find "$CLIKADER_STATE_DIR/transactions/example" -name status | wc -l)" -eq 5 ]
}

@test "managed configuration manifest detects later file drift" {
    printf original > "$BATS_TEST_TMPDIR/config"
    record_managed example "$BATS_TEST_TMPDIR/config"
    run sha256sum --check "$CLIKADER_STATE_DIR/managed/example.sha256"
    [ "$status" -eq 0 ]
    printf changed > "$BATS_TEST_TMPDIR/config"
    run sha256sum --check "$CLIKADER_STATE_DIR/managed/example.sha256"
    [ "$status" -eq 1 ]
}
