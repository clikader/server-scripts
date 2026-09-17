#!/usr/bin/env bash
# Install a complete immutable bundle; a single symlink switches all commands.
set -euo pipefail

INSTALL_ROOT="${CLIKADER_INSTALL_ROOT:-/usr/local/lib/clikader}"
BIN_DIR="${CLIKADER_BIN_DIR:-/usr/local/bin}"
mode=install
yes=0
local_source=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) echo 'Usage: install.sh [--update|--rollback] [--yes] [--from directory]'; exit 0 ;;
        --update) mode=update; shift ;;
        --rollback) mode=rollback; shift ;;
        --yes|-y) yes=1; shift ;;
        --from) [[ $# -ge 2 ]] || exit 2; local_source="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo 'This installer must be run as root' >&2; exit 1; }
mkdir -p "$INSTALL_ROOT/releases" "$BIN_DIR"
chown root:root "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
chmod 755 "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
exec 9>"$INSTALL_ROOT/install.lock"
flock -n 9 || { echo 'Another installation is running' >&2; exit 1; }
work="$(mktemp -d "$INSTALL_ROOT/.install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

switch_bundle() {
    local target="$1" old=""
    if [[ -L "$INSTALL_ROOT/current" ]]; then old="$(readlink "$INSTALL_ROOT/current")"; fi
    ln -s "$target" "$work/current"
    mv -Tf "$work/current" "$INSTALL_ROOT/current"
    if [[ -n "$old" && "$old" != "$target" ]]; then
        ln -s "$old" "$work/previous"
        mv -Tf "$work/previous" "$INSTALL_ROOT/previous"
    fi
}

if [[ "$mode" == rollback ]]; then
    [[ -L "$INSTALL_ROOT/previous" ]] || { echo 'No previous bundle available' >&2; exit 1; }
    previous="$(readlink "$INSTALL_ROOT/previous")"
    [[ -f "$INSTALL_ROOT/$previous/clikader.sh" ]] || { echo "Previous bundle ($previous) is incomplete; cannot roll back." >&2; exit 1; }
    switch_bundle "$previous"
    echo 'Restored previous CLiKader bundle.'
    exit 0
fi

if [[ -n "$local_source" ]]; then
    mkdir "$work/bundle"
    for entry in clikader.sh install.sh VERSION components lib; do
        cp -a "$local_source/$entry" "$work/bundle/"
    done
else
    # Resolve main once. Every byte below comes from this immutable commit.
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
        https://api.github.com/repos/clikader/server-scripts/git/ref/heads/main -o "$work/ref.json"; then
        echo 'Failed to download release information' >&2; exit 1
    fi
    revision="$(sed -n 's/.*"sha": "\([0-9a-f]\{40\}\)".*/\1/p' "$work/ref.json" | head -1)"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid release revision' >&2; exit 1; }
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 \
        "https://codeload.github.com/clikader/server-scripts/tar.gz/$revision" -o "$work/bundle.tar.gz"; then
        echo 'Failed to download bundle; installed version is intact' >&2; exit 1
    fi
    mkdir "$work/bundle"
    tar -xzf "$work/bundle.tar.gz" --strip-components=1 -C "$work/bundle"
fi

[[ -s "$work/bundle/lib/nft_rules.awk" ]] || { echo 'Incomplete bundle: lib/nft_rules.awk' >&2; exit 1; }
awk -f "$work/bundle/lib/nft_rules.awk" /dev/null
for file in clikader.sh install.sh lib/common.sh components/setup_vps.sh components/setup_dns.sh \
    components/nft_manager.sh components/optimize_tcp.sh components/configure_ipv6.sh \
    components/fix_hostname.sh components/reset_apt_source.sh components/maintenance.sh components/doctor.sh; do
    [[ -s "$work/bundle/$file" ]] || { echo "Incomplete bundle: $file" >&2; exit 1; }
    bash -n "$work/bundle/$file"
done
version="$(cat "$work/bundle/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid bundle version' >&2; exit 1; }
# Local installs also get a content identifier, including uncommitted edits.
if [[ -z "${revision:-}" ]]; then
    revision="$(find "$work/bundle" -type f -print0 | sort -z | xargs -0 cat | sha256sum | cut -d' ' -f1)"
fi
target="releases/$revision"
if [[ -L "$INSTALL_ROOT/current" && "$(readlink "$INSTALL_ROOT/current")" == "$target" ]]; then
    echo "CLiKader $version is up to date"; exit 0
fi
if [[ "$mode" == update && "$yes" != 1 ]]; then
    read -r -p "Install CLiKader $version ($revision)? [y/N]: " answer < /dev/tty
    case "$answer" in y|Y) ;; *) echo 'Update cancelled'; exit 0 ;; esac
fi
if [[ ! -d "$INSTALL_ROOT/$target" ]]; then
    chown -R root:root "$work/bundle"
    chmod -R go-w "$work/bundle"
    chmod 755 "$work/bundle/clikader.sh" "$work/bundle/install.sh"
    printf '%s\n' "$revision" > "$work/bundle/REVISION"
    mv "$work/bundle" "$INSTALL_ROOT/$target"
fi
if [[ -f "$BIN_DIR/clikader" && ! -L "$BIN_DIR/clikader" ]]; then
    cp -a "$BIN_DIR/clikader" "$BIN_DIR/clikader.backup"
fi
switch_bundle "$target"
ln -s "$INSTALL_ROOT/current/clikader.sh" "$work/command"
mv -Tf "$work/command" "$BIN_DIR/clikader"
echo "Installation Successful: CLiKader $version ($revision)"
echo "Complete bundle installed at $INSTALL_ROOT/current; components work offline."
