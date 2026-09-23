#!/usr/bin/env bash
# Shared configuration transactions, ownership records and host checks.

CLIKADER_STATE_DIR="${CLIKADER_STATE_DIR:-/var/lib/clikader}"
CLIKADER_LOCK_DIR="${CLIKADER_LOCK_DIR:-/run/lock}"
declare -gA CLIKADER_LOCK_FDS

clikader_lock() {
    local name="$1" lock_fd
    if [[ -n "${CLIKADER_LOCK_FDS[$name]:-}" ]]; then return 0; fi
    mkdir -p "$CLIKADER_LOCK_DIR" || return 1
    exec {lock_fd}>"$CLIKADER_LOCK_DIR/clikader-$name.lock" || return 1
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        echo "Another clikader $name operation is running" >&2; return 1
    fi
    CLIKADER_LOCK_FDS[$name]="$lock_fd"
}

clikader_unlock() {
    local name="$1" lock_fd="${CLIKADER_LOCK_FDS[$1]:-}"
    [[ -n "$lock_fd" ]] || return 0
    flock -u "$lock_fd" || return 1
    exec {lock_fd}>&-
    unset "CLIKADER_LOCK_FDS[$name]"
}

# Call in a subshell. The EXIT trap restores files on any uncommitted exit,
# including SIGTERM; callbacks restore runtime state after the files are back.
tx_begin() {
    TX_NAME="$1"
    TX_ROLLBACK="${2:-:}"
    TX_COMMITTED=0
    umask 077
    mkdir -p "$CLIKADER_STATE_DIR/transactions/$TX_NAME" || return 1
    TX_DIR="$(mktemp -d "$CLIKADER_STATE_DIR/transactions/$TX_NAME/$(date +%Y%m%dT%H%M%S%N).XXXXXX")" || return 1
    : > "$TX_DIR/paths"
    trap 'tx_finish $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}

tx_save() {
    local path index
    for path in "$@"; do
        [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 1
        grep -qxF -- "$path" "$TX_DIR/paths" && continue
        index="$(wc -l < "$TX_DIR/paths")"
        if [[ -e "$path" || -L "$path" ]]; then
            cp -a -- "$path" "$TX_DIR/$index" || return 1
        fi
        printf '%s\n' "$path" >> "$TX_DIR/paths" || return 1
    done
}

tx_restore() {
    local path index=0 failed=0
    while IFS= read -r path; do
        rm -rf -- "$path" || failed=1
        if [[ -e "$TX_DIR/$index" || -L "$TX_DIR/$index" ]]; then
            mkdir -p "$(dirname "$path")" || failed=1
            cp -a -- "$TX_DIR/$index" "$path" || failed=1
        fi
        index=$((index + 1))
    done < "$TX_DIR/paths"
    return "$failed"
}

tx_finish() {
    local rc="$1"
    trap - EXIT INT TERM HUP
    if [[ "$TX_COMMITTED" != 1 ]]; then
        echo "Restoring $TX_NAME configuration (snapshot: $TX_DIR)" >&2
        tx_restore || echo "File restoration failed; inspect $TX_DIR" >&2
        "$TX_ROLLBACK" || echo "Runtime restoration failed; inspect $TX_DIR" >&2
        [[ "$rc" != 0 ]] || rc=1
    fi
    exit "$rc"
}

record_managed() {
    local name="$1" path tmp
    shift
    mkdir -p "$CLIKADER_STATE_DIR/managed" || return 1
    if [[ -n "${TX_DIR:-}" && "${TX_COMMITTED:-1}" == 0 ]]; then
        tx_save "$CLIKADER_STATE_DIR/managed/$name.sha256" || return 1
    fi
    tmp="$(mktemp "$CLIKADER_STATE_DIR/managed/.record.XXXXXX")" || return 1
    for path in "$@"; do
        if [[ -f "$path" ]]; then
            sha256sum -- "$path" >> "$tmp" || { rm -f "$tmp"; return 1; }
        fi
    done
    chmod 600 "$tmp"
    mv -f "$tmp" "$CLIKADER_STATE_DIR/managed/$name.sha256"
}

tx_commit() {
    printf 'committed\n' > "$TX_DIR/status" || return 1
    TX_COMMITTED=1
    # Keep the newest five committed snapshots. Failed snapshots are retained
    # for diagnosis and can be removed explicitly with maintenance prune.
    local dir count=0
    while IFS= read -r dir; do
        [[ -f "$dir/status" ]] || continue
        count=$((count + 1))
        (( count <= 5 )) || rm -rf -- "$dir"
    done < <(printf '%s\n' "$CLIKADER_STATE_DIR/transactions/$TX_NAME/"* | sort -r)
}

valid_global_ipv6() {
    ip -o -6 addr show scope global 2>/dev/null | awk '
        / tentative | dadfailed | deprecated / { next }
        { for (i=1; i<=NF; i++) if ($i == "inet6" && $(i+1) ~ /^([23][[:xdigit:]]*|[fF][cCdD][[:xdigit:]]*):/) found=1 }
        END { exit !found }'
}

# Called before setup's network mutations. An explicit flag also makes remote
# automation deterministic. No global address means no question is needed.
choose_ipv6() {
    local choice="${1:-ask}" answer
    case "$choice" in
        keep|disable) printf '%s' "$choice"; return ;;
        ask) ;;
        *) echo "Invalid IPv6 policy: $choice" >&2; return 1 ;;
    esac
    if ! valid_global_ipv6; then printf disable; return; fi
    printf 'This server has a global IPv6 address. Keep IPv6 enabled? [y/N]: ' >&2
    if ! read -r answer < /dev/tty; then
        echo "Specify --keep-ipv6 or --disable-ipv6 for a non-interactive run." >&2
        return 1
    fi
    case "$answer" in y|Y|yes|YES) printf keep ;; *) printf disable ;; esac
}

apt_refresh() {
    apt-get -o APT::Update::Error-Mode=any -o DPkg::Lock::Timeout=120 update
}

# Validate staged content before calling this; rename on the destination's
# filesystem so interruption cannot leave a truncated persistent configuration.
install_config() (
    local staged="$1" destination="$2" temporary
    temporary="$(mktemp "$(dirname "$destination")/.clikader.XXXXXX")" || exit 1
    trap 'rm -f "$temporary"' EXIT
    cat "$staged" > "$temporary" || exit 1
    if [[ -e "$destination" ]]; then
        chmod --reference="$destination" "$temporary" || exit 1
        chown --reference="$destination" "$temporary" || exit 1
    else
        chmod 644 "$temporary" || exit 1
    fi
    mv -fT -- "$temporary" "$destination" || exit 1
)
