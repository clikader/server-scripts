#!/bin/bash

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
    local backup_dir="/etc/apt/sources.list.backup_${timestamp}"
    
    log "Creating backup of existing APT sources..."
    
    mkdir -p "$backup_dir"
    
    if [[ -f /etc/apt/sources.list ]]; then
        cp /etc/apt/sources.list "$backup_dir/sources.list"
        log "✅ Backed up /etc/apt/sources.list to $backup_dir/"
    fi
    
    if [[ -d /etc/apt/sources.list.d ]] && [[ -n "$(ls -A /etc/apt/sources.list.d/ 2>/dev/null)" ]]; then
        cp -r /etc/apt/sources.list.d/* "$backup_dir/" 2>/dev/null || true
        log "✅ Backed up /etc/apt/sources.list.d/ to $backup_dir/"
    fi
    
    echo ""
    info "Backup location: $backup_dir"
    echo ""
}

# Generate Debian sources
generate_debian_sources() {
    local version="$1"
    
    case "$version" in
        13)
            cat > /etc/apt/sources.list << 'EOF'
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
            cat > /etc/apt/sources.list << 'EOF'
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
            cat > /etc/apt/sources.list << 'EOF'
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
            cat > /etc/apt/sources.list.d/ubuntu.sources << 'EOF'
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
            echo "# This system uses /etc/apt/sources.list.d/ubuntu.sources" > /etc/apt/sources.list
            log "✅ Generated Ubuntu 24.10 (Oracular Oriole) sources (DEB822 format)"
            ;;
        24.04)
            cat > /etc/apt/sources.list.d/ubuntu.sources << 'EOF'
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
            echo "# This system uses /etc/apt/sources.list.d/ubuntu.sources" > /etc/apt/sources.list
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
            cat > /etc/apt/sources.list << EOF
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
            cat > /etc/apt/sources.list << EOF
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
            cat > /etc/apt/sources.list << EOF
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
            cat > /etc/apt/sources.list << EOF
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
    log "Cleaning /etc/apt/sources.list.d/ directory and related files..."
    
    if [[ -d /etc/apt/sources.list.d ]]; then
        local list_count=0
        local sources_count=0
        local save_count=0
        local other_count=0
        
        # Count and remove .list files (traditional format)
        list_count=$(find /etc/apt/sources.list.d/ -type f -name "*.list" 2>/dev/null | wc -l)
        if [[ $list_count -gt 0 ]]; then
            find /etc/apt/sources.list.d/ -type f -name "*.list" -delete 2>/dev/null || true
            log "✅ Removed $list_count .list file(s)"
        fi
        
        # Count and remove .sources files (DEB822 format, used in Ubuntu 24.04+)
        sources_count=$(find /etc/apt/sources.list.d/ -type f -name "*.sources" 2>/dev/null | wc -l)
        if [[ $sources_count -gt 0 ]]; then
            find /etc/apt/sources.list.d/ -type f -name "*.sources" -delete 2>/dev/null || true
            log "✅ Removed $sources_count .sources file(s) (DEB822 format)"
        fi
        
        # Count and remove .list.save backup files
        save_count=$(find /etc/apt/sources.list.d/ -type f -name "*.list.save" 2>/dev/null | wc -l)
        if [[ $save_count -gt 0 ]]; then
            find /etc/apt/sources.list.d/ -type f -name "*.list.save" -delete 2>/dev/null || true
            log "✅ Removed $save_count .list.save backup file(s)"
        fi
        
        # Count and remove .distUpgrade files
        other_count=$(find /etc/apt/sources.list.d/ -type f -name "*.distUpgrade" 2>/dev/null | wc -l)
        if [[ $other_count -gt 0 ]]; then
            find /etc/apt/sources.list.d/ -type f -name "*.distUpgrade" -delete 2>/dev/null || true
            log "✅ Removed $other_count .distUpgrade file(s)"
        fi
        
        # Remove .gpg files (repository keys in sources.list.d)
        local gpg_count=$(find /etc/apt/sources.list.d/ -type f -name "*.gpg" 2>/dev/null | wc -l)
        if [[ $gpg_count -gt 0 ]]; then
            find /etc/apt/sources.list.d/ -type f -name "*.gpg" -delete 2>/dev/null || true
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
    if [[ -f /etc/apt/sources.list.save ]]; then
        rm -f /etc/apt/sources.list.save
        log "✅ Removed /etc/apt/sources.list.save"
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
    if [[ -f /etc/apt/sources.list ]] && [[ -s /etc/apt/sources.list ]]; then
        local content=$(grep -v '^#' /etc/apt/sources.list | grep -v '^$' || true)
        if [[ -n "$content" ]]; then
            log "✅ /etc/apt/sources.list exists and contains entries"
            sources_found=true
            
            echo ""
            log "Current /etc/apt/sources.list content:"
            echo ""
            echo "$content"
            echo ""
        fi
    fi
    
    # Check for DEB822 format sources in sources.list.d
    if [[ -d /etc/apt/sources.list.d ]]; then
        local sources_files=$(find /etc/apt/sources.list.d/ -type f -name "*.sources" 2>/dev/null)
        if [[ -n "$sources_files" ]]; then
            log "✅ Found .sources files (DEB822 format):"
            for file in $sources_files; do
                echo "  • $(basename "$file")"
                sources_found=true
            done
            
            echo ""
            log "Content of ubuntu.sources (if exists):"
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                echo ""
                grep -v '^#' /etc/apt/sources.list.d/ubuntu.sources | grep -v '^$' || true
            fi
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
    
    # Generate appropriate sources based on OS
    if [[ "$os_name" == "debian" ]]; then
        log "Resetting APT sources for Debian $os_version..."
        generate_debian_sources "$os_version"
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
    
    clean_sources_list_d
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

main "$@"
