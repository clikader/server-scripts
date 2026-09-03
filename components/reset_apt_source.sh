#!/usr/bin/env bash

# APT Source Reset Script - Resets APT sources to official mirrors
# Supports: Debian 12/13, Ubuntu 22.04/24.04/24.10
# May work on: Debian 11, Ubuntu 20.04 (with limited testing)

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# APT paths (env-overridable so tests can target temp files; defaults unchanged)
APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_LIST_D="${APT_SOURCES_LIST_D:-/etc/apt/sources.list.d}"

# Logging functions
log() {
    echo -e "${GREEN}-->${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Detect OS version
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="$ID"
    os_version="$VERSION_ID"
    os_codename="${VERSION_CODENAME:-}"
else
    error "Cannot detect OS version"
    exit 1
fi

log "Detected: $ID $VERSION_ID ($os_codename)"

# Backup existing sources
backup_sources() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$APT_SOURCES_LIST.backup_${timestamp}"
    
    log "Creating backup of existing APT sources..."
    
    mkdir -p "$backup_dir"
    
    if [[ -f $APT_SOURCES_LIST ]]; then
        cp $APT_SOURCES_LIST "$backup_dir/sources.list"
        log "✅ Backed up $APT_SOURCES_LIST to $backup_dir/"
    fi
    
    if [[ -d ${APT_SOURCES_LIST_D} ]] && [[ -n "$(ls -A ${APT_SOURCES_LIST_D}/ 2>/dev/null)" ]]; then
        cp -r ${APT_SOURCES_LIST_D}/* "$backup_dir/" 2>/dev/null || true
        log "✅ Backed up ${APT_SOURCES_LIST_D}/ to $backup_dir/"
    fi
    
    echo ""
    info "Backup location: $backup_dir"
    echo ""
}

# Generate Debian sources in DEB822 format (.sources) — the Trixie default.
# Includes Signed-By (required by modern apt), backports, and deb-src, giving
# the full official mirror set (the "5-6 URLs" a provider image ships, vs. the
# minimal 3 a hand-written sources.list shows).
generate_debian_sources_deb822() {
    local version="$1"
    local suite

    case "$version" in
        13) suite="trixie" ;;
        12) suite="bookworm" ;;
        *) error "Unsupported Debian version for DEB822: $version"; return 1 ;;
    esac

    cat > ${APT_SOURCES_LIST_D}/debian.sources << EOF
# Debian ${version} - Official Sources (DEB822 format)
# Managed by reset_apt_source.sh

Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${suite} ${suite}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${suite}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://deb.debian.org/debian-security
Suites: ${suite}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    # The old sources.list is deprecated on Trixie; neutralize it so apt doesn't
    # warn about duplicate sources. A pointer comment is the Debian/Ubuntu norm.
    cat > $APT_SOURCES_LIST << 'EOF'
# Debian sources have moved to /etc/apt/sources.list.d/debian.sources (DEB822).
# Managed by reset_apt_source.sh.
EOF
    log "✅ Generated Debian ${version} sources (DEB822 format, full mirror set)"
}

# Legacy one-line sources.list format (fallback for Debian 11 or if DEB822
# generation is refused). Kept for completeness; Debian 12/13 use DEB822 above.
generate_debian_sources() {
    local version="$1"

    case "$version" in
        13)
            cat > $APT_SOURCES_LIST << 'EOF'
# Debian 13 (Trixie) - Official Sources

# Main repository
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware

# Security updates
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware

# Updates repository
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
EOF
            log "✅ Generated Debian 13 (Trixie) sources"
            ;;
        12)
            cat > $APT_SOURCES_LIST << 'EOF'
# Debian 12 (Bookworm) - Official Sources

# Main repository
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

# Security updates
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

# Updates repository
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
            log "✅ Generated Debian 12 (Bookworm) sources"
            ;;
        11)
            cat > $APT_SOURCES_LIST << 'EOF'
# Debian 11 (Bullseye) - Official Sources

# Main repository
deb http://deb.debian.org/debian/ bullseye main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye main contrib non-free

# Security updates
deb http://deb.debian.org/debian-security bullseye-security main contrib non-free
deb-src http://deb.debian.org/debian-security bullseye-security main contrib non-free

# Updates repository
deb http://deb.debian.org/debian/ bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye-updates main contrib non-free
EOF
            log "✅ Generated Debian 11 (Bullseye) sources"
            ;;
        *)
            error "Unsupported Debian version: $version"
            return 1
            ;;
    esac
}

# Generate Ubuntu sources in DEB822 format (.sources files)
generate_ubuntu_sources_deb822() {
    local version="$1"
    local codename="$2"
    
    case "$version" in
        24.10)
            cat > ${APT_SOURCES_LIST_D}/ubuntu.sources << 'EOF'
# Ubuntu 24.10 (Oracular Oriole) - Official Sources
# DEB822 format

Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: oracular oracular-updates oracular-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.ubuntu.com/ubuntu/
Suites: oracular-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            # Clear the old sources.list
            echo "# This system uses ${APT_SOURCES_LIST_D}/ubuntu.sources" > $APT_SOURCES_LIST
            log "✅ Generated Ubuntu 24.10 (Oracular Oriole) sources (DEB822 format)"
            ;;
        24.04)
            cat > ${APT_SOURCES_LIST_D}/ubuntu.sources << 'EOF'
# Ubuntu 24.04 LTS (Noble Numbat) - Official Sources
# DEB822 format

Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            # Clear the old sources.list
            echo "# This system uses ${APT_SOURCES_LIST_D}/ubuntu.sources" > $APT_SOURCES_LIST
            log "✅ Generated Ubuntu 24.04 LTS (Noble Numbat) sources (DEB822 format)"
            ;;
        *)
            return 1
            ;;
    esac
}

# Generate Ubuntu sources in traditional format
generate_ubuntu_sources() {
    local version="$1"
    local codename="$2"
    
    case "$version" in
        24.10)
            cat > $APT_SOURCES_LIST << EOF
# Ubuntu 24.10 (Oracular Oriole) - Official Sources

# Main repositories
deb http://archive.ubuntu.com/ubuntu/ oracular main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ oracular main restricted universe multiverse

# Security updates
deb http://security.ubuntu.com/ubuntu/ oracular-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ oracular-security main restricted universe multiverse

# Updates
deb http://archive.ubuntu.com/ubuntu/ oracular-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ oracular-updates main restricted universe multiverse

# Backports
deb http://archive.ubuntu.com/ubuntu/ oracular-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ oracular-backports main restricted universe multiverse
EOF
            log "✅ Generated Ubuntu 24.10 (Oracular Oriole) sources"
            ;;
        24.04)
            cat > $APT_SOURCES_LIST << EOF
# Ubuntu 24.04 LTS (Noble Numbat) - Official Sources

# Main repositories
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse

# Security updates
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse

# Updates
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse

# Backports
deb http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse
EOF
            log "✅ Generated Ubuntu 24.04 LTS (Noble Numbat) sources"
            ;;
        22.04)
            cat > $APT_SOURCES_LIST << EOF
# Ubuntu 22.04 LTS (Jammy Jellyfish) - Official Sources

# Main repositories
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse

# Security updates
deb http://security.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse

# Updates
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse

# Backports
deb http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse
EOF
            log "✅ Generated Ubuntu 22.04 LTS (Jammy Jellyfish) sources"
            ;;
        20.04)
            cat > $APT_SOURCES_LIST << EOF
# Ubuntu 20.04 LTS (Focal Fossa) - Official Sources

# Main repositories
deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse

# Security updates
deb http://security.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse

# Updates
deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse

# Backports
deb http://archive.ubuntu.com/ubuntu/ focal-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ focal-backports main restricted universe multiverse
EOF
            log "✅ Generated Ubuntu 20.04 LTS (Focal Fossa) sources"
            ;;
        *)
            error "Unsupported Ubuntu version: $version"
            return 1
            ;;
    esac
}

# Clean sources.list.d directory and all APT source configurations
clean_sources_list_d() {
    log "Cleaning ${APT_SOURCES_LIST_D}/ directory and related files..."
    
    if [[ -d ${APT_SOURCES_LIST_D} ]]; then
        local list_count=0
        local sources_count=0
        local save_count=0
        local other_count=0
        
        # Count and remove .list files (traditional format)
        list_count=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.list" 2>/dev/null | wc -l)
        if [[ $list_count -gt 0 ]]; then
            find ${APT_SOURCES_LIST_D}/ -type f -name "*.list" -delete 2>/dev/null || true
            log "✅ Removed $list_count .list file(s)"
        fi
        
        # Count and remove .sources files (DEB822 format, used in Ubuntu 24.04+)
        sources_count=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.sources" 2>/dev/null | wc -l)
        if [[ $sources_count -gt 0 ]]; then
            find ${APT_SOURCES_LIST_D}/ -type f -name "*.sources" -delete 2>/dev/null || true
            log "✅ Removed $sources_count .sources file(s) (DEB822 format)"
        fi
        
        # Count and remove .list.save backup files
        save_count=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.list.save" 2>/dev/null | wc -l)
        if [[ $save_count -gt 0 ]]; then
            find ${APT_SOURCES_LIST_D}/ -type f -name "*.list.save" -delete 2>/dev/null || true
            log "✅ Removed $save_count .list.save backup file(s)"
        fi
        
        # Count and remove .distUpgrade files
        other_count=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.distUpgrade" 2>/dev/null | wc -l)
        if [[ $other_count -gt 0 ]]; then
            find ${APT_SOURCES_LIST_D}/ -type f -name "*.distUpgrade" -delete 2>/dev/null || true
            log "✅ Removed $other_count .distUpgrade file(s)"
        fi
        
        # Remove .gpg files (repository keys in sources.list.d)
        local gpg_count=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.gpg" 2>/dev/null | wc -l)
        if [[ $gpg_count -gt 0 ]]; then
            find ${APT_SOURCES_LIST_D}/ -type f -name "*.gpg" -delete 2>/dev/null || true
            log "✅ Removed $gpg_count .gpg key file(s)"
        fi
        
        local total=$((list_count + sources_count + save_count + other_count + gpg_count))
        
        if [[ $total -eq 0 ]]; then
            info "No third-party sources found in sources.list.d/"
        else
            log "✅ Total files removed from sources.list.d/: $total"
        fi
    fi
    
    # Also clean up sources.list.save if it exists
    if [[ -f ${APT_SOURCES_LIST}.save ]]; then
        rm -f ${APT_SOURCES_LIST}.save
        log "✅ Removed ${APT_SOURCES_LIST}.save"
    fi
}

# Update APT cache
update_apt_cache() {
    echo ""
    log "Updating APT cache..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if apt-get update > /dev/null 2>&1; then
        log "✅ APT cache updated successfully"
    else
        warning "APT update encountered some issues, but this may be normal"
        apt-get update
    fi
}

# Verify sources
verify_sources() {
    echo ""
    log "Verifying APT sources..."
    
    local sources_found=false
    
    # Check traditional sources.list
    if [[ -f $APT_SOURCES_LIST ]] && [[ -s $APT_SOURCES_LIST ]]; then
        local content=$(grep -v '^#' $APT_SOURCES_LIST | grep -v '^$' || true)
        if [[ -n "$content" ]]; then
            log "✅ $APT_SOURCES_LIST exists and contains entries"
            sources_found=true
            
            echo ""
            log "Current $APT_SOURCES_LIST content:"
            echo ""
            echo "$content"
            echo ""
        fi
    fi
    
    # Check for DEB822 format sources in sources.list.d
    if [[ -d ${APT_SOURCES_LIST_D} ]]; then
        local sources_files=$(find ${APT_SOURCES_LIST_D}/ -type f -name "*.sources" 2>/dev/null)
        if [[ -n "$sources_files" ]]; then
            log "✅ Found .sources files (DEB822 format):"
            for file in $sources_files; do
                echo "  • $(basename "$file")"
                sources_found=true
            done
            
            echo ""
            log "Content of the main .sources file (if exists):"
            for sf in ${APT_SOURCES_LIST_D}/ubuntu.sources ${APT_SOURCES_LIST_D}/debian.sources; do
                if [[ -f "$sf" ]]; then
                    echo ""
                    log "$(basename "$sf"):"
                    grep -v '^#' "$sf" | grep -v '^$' || true
                fi
            done
            echo ""
        fi
    fi
    
    if [[ "$sources_found" == false ]]; then
        error "No APT sources found!"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    echo "=========================================="
    echo "  APT Source Reset Script"
    echo "=========================================="
    echo ""
    
    backup_sources

    # Sweep the slate clean BEFORE generating: remove stale third-party .list /
    # .sources / .save / .gpg files so only our official config remains.
    # (Must run before generation, otherwise it deletes the file we just wrote.)
    clean_sources_list_d

    # Generate appropriate sources based on OS
    if [[ "$os_name" == "debian" ]]; then
        log "Resetting APT sources for Debian $os_version..."
        # Debian 12/13: use the modern DEB822 format (Trixie default; Bookworm
        # also supports it). Falls back to legacy sources.list on older releases.
        case "$os_version" in
            13|12)
                if generate_debian_sources_deb822 "$os_version"; then
                    info "Using modern DEB822 format (debian.sources)"
                else
                    warning "DEB822 generation failed, falling back to legacy format"
                    generate_debian_sources "$os_version"
                fi
                ;;
            *)
                generate_debian_sources "$os_version"
                ;;
        esac
    elif [[ "$os_name" == "ubuntu" ]]; then
        log "Resetting APT sources for Ubuntu $os_version..."

        # Ubuntu 24.04+ uses DEB822 format by default
        if [[ "$os_version" == "24.04" ]] || [[ "$os_version" == "24.10" ]]; then
            if generate_ubuntu_sources_deb822 "$os_version" "$os_codename"; then
                info "Using modern DEB822 format (.sources file)"
            else
                warning "DEB822 format not available, falling back to traditional format"
                generate_ubuntu_sources "$os_version" "$os_codename"
            fi
        else
            # Older Ubuntu versions use traditional sources.list
            generate_ubuntu_sources "$os_version" "$os_codename"
        fi
    else
        error "Unsupported OS: $os_name"
        exit 1
    fi

    update_apt_cache
    verify_sources
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}APT sources reset successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "✅ Your system is now using official $ID $VERSION_ID repositories"
    echo ""
}

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
