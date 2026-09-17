#!/usr/bin/env bash
# Reset APT to official repositories, with preflight and automatic rollback.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_LIST_D="${APT_SOURCES_LIST_D:-/etc/apt/sources.list.d}"
APT_PREFERENCES_D="${APT_PREFERENCES_D:-/etc/apt/preferences.d}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
log() { echo "--> $*"; }
info() { echo "$*"; }
warning() { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }

for arg in "$@"; do
    case "$arg" in
        --help|-h) echo 'Usage: clikader apt-reset (replaces all configured repositories with official sources)'; exit 0 ;;
        *) error "Unknown option: $arg"; exit 2 ;;
    esac
done
[[ $EUID -eq 0 ]] || { error 'This script must be run as root'; exit 1; }
# shellcheck source=/dev/null
source "$OS_RELEASE"
os_name="$ID"
os_version="$VERSION_ID"

apt_target() {
    local os="$1" version="$2"
    case "$os/$version" in
        debian/11) suite=bullseye ;;
        debian/12) suite=bookworm ;;
        debian/13) suite=trixie ;;
        ubuntu/20.04) suite=focal ;;
        ubuntu/22.04) suite=jammy ;;
        ubuntu/24.04) suite=noble ;;
        ubuntu/26.04) suite=resolute ;;
        *) error "Unsupported OS/release: $os $version. Existing repositories are preserved."; return 1 ;;
    esac
    arch="${APT_ARCH:-$(dpkg --print-architecture)}"
    case "$arch" in amd64|i386|arm64|armhf|ppc64el|riscv64|s390x) ;; *) error "Unsupported architecture: $arch"; return 1 ;; esac
    if [[ "$os" == debian ]]; then
        mirror=https://deb.debian.org/debian
        security=https://deb.debian.org/debian-security
        components='main contrib non-free'
        [[ "$version" == 11 ]] || components+=' non-free-firmware'
        keyring=/usr/share/keyrings/debian-archive-keyring.gpg
    else
        components='main restricted universe multiverse'
        keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
        case "$arch" in
            amd64|i386) mirror=https://archive.ubuntu.com/ubuntu; security=https://security.ubuntu.com/ubuntu ;;
            *) mirror=https://ports.ubuntu.com/ubuntu-ports; security="$mirror" ;;
        esac
    fi
}

generate_sources() {
    local os="$1" version="$2"
    apt_target "$os" "$version" || return 1
    mkdir -p "$APT_SOURCES_LIST_D" || return 1
    cat > "$APT_SOURCES_LIST_D/$os.sources" <<EOF
# Managed by reset_apt_source.sh
Types: deb deb-src
URIs: $mirror
Suites: $suite $suite-updates
Components: $components
Signed-By: $keyring

Types: deb deb-src
URIs: $security
Suites: $suite-security
Components: $components
Signed-By: $keyring
EOF
    [[ $? -eq 0 ]] || return 1
    printf '# Official sources: %s/%s.sources\n' "$APT_SOURCES_LIST_D" "$os" > "$APT_SOURCES_LIST" || return 1
    log "Generated $os $version sources (DEB822, $arch)"
}

generate_debian_sources_deb822() { generate_sources debian "$1"; }
generate_ubuntu_sources_deb822() { generate_sources ubuntu "$1"; }

clean_sources_list_d() {
    local file
    for file in "$APT_SOURCES_LIST_D/"*.list "$APT_SOURCES_LIST_D/"*.sources; do
        # Ubuntu Pro security feeds are official repositories. Preserve their
        # entitlement-managed configuration, particularly on older LTS hosts.
        if [[ "$os_name" == ubuntu && "${file##*/}" == ubuntu-esm-* ]] && \
            grep -qE 'https://esm\.ubuntu\.com/(apps|infra)/ubuntu' "$file" 2>/dev/null; then
            continue
        fi
        [[ ! -e "$file" && ! -L "$file" ]] || rm -f -- "$file" || return 1
    done
}

# True (exit 0) when every Pin: line in a preferences file scopes to official
# Debian/Ubuntu repositories. A pin referencing a third-party origin is dead
# weight the moment this reset removes that repo — worse, it silently holds
# packages (including security updates) at pinned versions. Version pins
# ("Pin: version ...") are deliberately treated as official: they usually
# freeze an official package on purpose (e.g. a known-good kernel) and apt
# ignores them once their version is no longer candidate.
# Requires $suite (set by apt_target).
pin_file_is_official() {
    awk -v suite="$suite" '
        /^Pin:[[:space:]]*release/ {
            if ($0 ~ /o=(Debian|Ubuntu)/) next
            if ($0 ~ ("n=" suite "(-updates|-security|-backports)?$")) next
            if ($0 ~ /a=(stable|oldstable|oldoldstable|testing|unstable|experimental)(-(updates|security|backports))?([[:space:]]|$)/) next
            bad = 1; exit
        }
        /^Pin:[[:space:]]*origin/ {
            if ($0 ~ /^Pin:[[:space:]]*origin[[:space:]]*""[[:space:]]*$/) next
            if ($0 ~ /^Pin:[[:space:]]*origin[[:space:]]*"?((deb|security)\.debian\.org|ftp\.[A-Za-z0-9.]*debian\.org|(archive|security|ports)\.ubuntu\.com)"?(\/|$)/) next
            bad = 1; exit
        }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

clean_preferences_d() {
    local file removed=""
    [[ -d "$APT_PREFERENCES_D" ]] || return 0
    for file in "$APT_PREFERENCES_D"/*; do
        [[ -f "$file" || -L "$file" ]] || continue
        if ! pin_file_is_official "$file"; then
            rm -f -- "$file" || return 1
            removed+=" ${file##*/}"
        fi
    done
    [[ -z "$removed" ]] || log "Removed third-party APT pin(s):${removed}"
    return 0
}

update_apt_cache() { apt_refresh; }
verify_sources() {
    if grep -qE '^deb ' "$APT_SOURCES_LIST" 2>/dev/null || \
        grep -q '^URIs:' "$APT_SOURCES_LIST_D/"*.sources 2>/dev/null; then return 0; fi
    error 'No APT sources found!'; return 1
}

restore_apt_runtime() { apt_refresh || warning 'Sources restored; refresh package indexes when connectivity returns.'; }

main() (
    # Reject unsupported releases before even making a backup directory.
    apt_target "$os_name" "$os_version" || exit 1
    clikader_lock apt || exit 1
    tx_begin apt restore_apt_runtime || exit 1
    tx_save "$APT_SOURCES_LIST" "$APT_SOURCES_LIST_D" "$APT_PREFERENCES_D" || exit 1
    clean_sources_list_d || exit 1
    generate_sources "$os_name" "$os_version" || exit 1
    clean_preferences_d || exit 1
    # APT authenticates Release files and all configured suites. Any failure
    # restores the old files; stale indexes are never treated as a successful reset.
    update_apt_cache || exit 1
    verify_sources || exit 1
    record_managed apt "$APT_SOURCES_LIST" "$APT_SOURCES_LIST_D/$os_name.sources" || exit 1
    tx_commit
    log 'APT sources reset successfully!'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
