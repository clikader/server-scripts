#!/usr/bin/env bash
# Reset APT to official repositories, with preflight and automatic rollback.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_LIST_D="${APT_SOURCES_LIST_D:-/etc/apt/sources.list.d}"
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

generate_legacy_sources() {
    apt_target "$1" "$2" || return 1
    printf 'deb %s %s %s\ndeb %s %s-updates %s\ndeb %s %s-security %s\n' \
        "$mirror" "$suite" "$components" "$mirror" "$suite" "$components" "$security" "$suite" "$components" > "$APT_SOURCES_LIST"
}
generate_debian_sources() { generate_legacy_sources debian "$1"; }
generate_ubuntu_sources() { generate_legacy_sources ubuntu "$1"; }

backup_sources() {
    local backup
    backup="$APT_SOURCES_LIST.backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup" || return 1
    [[ ! -f "$APT_SOURCES_LIST" ]] || cp -a "$APT_SOURCES_LIST" "$backup/sources.list" || return 1
    [[ ! -d "$APT_SOURCES_LIST_D" ]] || cp -a "$APT_SOURCES_LIST_D/." "$backup/" || return 1
}

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
    tx_save "$APT_SOURCES_LIST" "$APT_SOURCES_LIST_D" || exit 1
    clean_sources_list_d || exit 1
    generate_sources "$os_name" "$os_version" || exit 1
    # APT authenticates Release files and all configured suites. Any failure
    # restores the old files; stale indexes are never treated as a successful reset.
    update_apt_cache || exit 1
    verify_sources || exit 1
    record_managed apt "$APT_SOURCES_LIST" "$APT_SOURCES_LIST_D/$os_name.sources" || exit 1
    tx_commit
    log 'APT sources reset successfully!'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
