#!/usr/bin/env bash

# Shared helpers for the CLiKader bats test suites.
#
# Key ideas:
#   * Scripts are `source`d (via load_component) so their functions can be
#     called directly. Component scripts run `set -euo pipefail` at the top,
#     so load_component relaxes errexit afterwards — but keeps nounset on so
#     tests still catch genuine "unset variable" bugs.
#   * System-mutating / network tools (apt-get, systemctl, nft, sysctl, curl,
#     sshd, ...) are mocked: each test gets a private mockbin prepended to
#     PATH. Mocks record every invocation into a call log for assertions.
#   * Interactive functions that read from /dev/tty are exercised through a
#     pty (script(1)) via run_pty, so `read ... < /dev/tty` actually works.

# Absolute repo root (tests/ is one level below the repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Mock command framework
# --------------------------------------------------------------------------
# setup_mocks must be called first (usually from setup()). make_mock creates a
# fake executable with canned stdout/stderr/status. Every invocation is logged
# to $MOCK_CFG_DIR/calls as "<name> <args...>".
setup_mocks() {
    MOCK_BIN="${BATS_TEST_TMPDIR}/mockbin"
    MOCK_CFG_DIR="${BATS_TEST_TMPDIR}/mockcfg"
    mkdir -p "$MOCK_BIN" "$MOCK_CFG_DIR"
    : > "$MOCK_CFG_DIR/calls"
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_BIN MOCK_CFG_DIR
}

# make_mock <name> [--out "text"] [--err "text"] [--status N]
# Creates (or reconfigures) a mock executable on PATH.
make_mock() {
    local name="$1"
    local out="" err="" status=0
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out)    out="$2";    shift 2 ;;
            --err)    err="$2";    shift 2 ;;
            --status) status="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s' "$out"   > "$MOCK_CFG_DIR/${name}.out"
    printf '%s' "$err"   > "$MOCK_CFG_DIR/${name}.err"
    printf '%s' "$status" > "$MOCK_CFG_DIR/${name}.status"

    if [[ ! -e "$MOCK_BIN/$name" ]]; then
        cat > "$MOCK_BIN/$name" <<'MOCK'
#!/usr/bin/env bash
me="$(basename "$0")"
printf '%s' "$me" >> "$MOCK_CFG_DIR/calls"
printf ' %s' "$@" >> "$MOCK_CFG_DIR/calls"
printf '\n' >> "$MOCK_CFG_DIR/calls"
[[ -f "$MOCK_CFG_DIR/$me.out" ]] && cat "$MOCK_CFG_DIR/$me.out"
[[ -f "$MOCK_CFG_DIR/$me.err" ]] && cat "$MOCK_CFG_DIR/$me.err" >&2
st=0
[[ -f "$MOCK_CFG_DIR/$me.status" ]] && st="$(cat "$MOCK_CFG_DIR/$me.status")"
exit "$st"
MOCK
        chmod +x "$MOCK_BIN/$name"
    fi
}

# mock_calls <name> -> number of recorded invocations
mock_calls() {
    local name="$1"
    grep -c "^${name} " "$MOCK_CFG_DIR/calls" 2>/dev/null || true
}

# mock_last_args <name> -> args of the last invocation (without the name)
mock_last_args() {
    local name="$1"
    grep "^${name} " "$MOCK_CFG_DIR/calls" 2>/dev/null | tail -1 | sed "s/^${name} //"
}

# assert_mock_called <name> [expected-count]
assert_mock_called() {
    local name="$1" exp="${2:-}"
    local got
    got="$(mock_calls "$name")"
    if [[ -n "$exp" ]]; then
        [[ "$got" == "$exp" ]] || {
            echo "expected $name to be called ${exp}x, got ${got}x" >&2
            return 1
        }
    else
        [[ "$got" -ge 1 ]] || {
            echo "expected $name to be called, but it was not" >&2
            return 1
        }
    fi
}

# --------------------------------------------------------------------------
# Script loading
# --------------------------------------------------------------------------
# load_component <relative-path> — source a repo script into the current shell.
#
# Component scripts run `set -euo pipefail` at the top, which stays active in
# the test shell. We deliberately DO NOT relax errexit: bats relies on errexit
# to detect failing assertions, and `run` already isolates any command that may
# legitimately return non-zero. Keep nounset on so genuine unset-variable bugs
# are caught.
load_component() {
    local script="$REPO_ROOT/$1"
    # Clear positional parameters so top-level arg parsers in the sourced
    # script do not treat the path we just sourced as "$1".
    set --
    source "$script"
}

# --------------------------------------------------------------------------
# Interactive (/dev/tty) helper
# --------------------------------------------------------------------------
# run_pty <inner-script> <answer1> [answer2 ...]
# Runs the inner script under a pty, feeding the answers as its stdin, so
# `read ... < /dev/tty` inside the script resolves. Sets:
#   PTY_RC    exit status of the script(1) wrapper (child's status with -e)
#   PTY_OUT   combined stdout+stderr captured from the script
run_pty() {
    local inner="$1"
    shift
    local input="$BATS_TEST_TMPDIR/pty.in"
    local out="$BATS_TEST_TMPDIR/pty.out"
    printf '%s\n' "$@" > "$input"
    chmod +x "$inner" 2>/dev/null || true
    # bats uses set -eET + an ERR trap; a failing command inside a helper
    # function aborts the test. Capture script(1)'s status via `||` so the
    # helper itself always returns 0; callers assert on $PTY_RC / $PTY_OUT.
    PTY_RC=0
    script -qec "bash '$inner'" /dev/null < "$input" > "$out" 2>&1 || PTY_RC=$?
    PTY_OUT="$(cat "$out" 2>/dev/null || true)"
    return 0
}

# Write an inner-script stub that sources a component and runs a function.
# make_inner <relative-component> '<function call line...>'
make_inner() {
    local component="$1" body="$2"
    local inner="$BATS_TEST_TMPDIR/inner.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'source %s\n' "$REPO_ROOT/$component"
        printf '%s\n' "$body"
    } > "$inner"
    chmod +x "$inner"
    printf '%s' "$inner"
}

# --------------------------------------------------------------------------
# Misc assertions
# --------------------------------------------------------------------------
assert_output_contains() {
    local needle="$1"
    [[ "$output" == *"$needle"* ]] || {
        echo "expected output to contain: $needle" >&2
        echo "actual output: $output" >&2
        return 1
    }
}

assert_file_contains() {
    local file="$1" needle="$2"
    [[ -f "$file" ]] || {
        echo "expected file to exist: $file" >&2
        return 1
    }
    grep -qF -- "$needle" "$file" || {
        echo "expected $file to contain: $needle" >&2
        return 1
    }
}
