#!/usr/bin/env bash

# Clikader - Server Management Toolkit
# Master entrypoint for server management tasks via sub-commands.

set -euo pipefail

# Version
CLIKADER_VERSION="1.2.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# GitHub raw URL base
GITHUB_RAW_BASE="https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/components"

# Script directory (works in bash and zsh)
SCRIPT_PATH="$0"
if [[ -n "${BASH_SOURCE:-}" ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Logging functions
log() {
    echo -e "${GREEN}->${NC} $1"
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

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This command must be run as root"
        echo "Please run with sudo, for example: sudo clikader $*"
        exit 1
    fi
}

show_usage() {
    echo -e "${CYAN}${BOLD}CLiKader v${CLIKADER_VERSION}${NC}"
    echo ""
    echo "Usage:"
    echo "  clikader [command]"
    echo ""
    echo "Commands:"
    echo "  --help, -h, help            Show this help message"
    echo "  update, upgrade             Update CLiKader"
    echo "  dns                         Run DNS setup tool"
    echo "  apt-reset, aptreset         Run APT source reset tool"
    echo "  hostname                    Run hostname fix tool"
    echo "  ipv6, 6                     Run IPv6 configuration tool"
    echo "  uninstall, remove           Uninstall CLiKader"
    echo "  --version, -v, version      Show CLiKader version"
    echo ""
    echo "Aliases:"
    echo "  clikader                    Alias of 'clikader --help'"
    echo "  clikader help               Alias of 'clikader --help'"
    echo ""
    echo "Examples:"
    echo "  clikader --help"
    echo "  clikader help"
    echo "  sudo clikader update"
    echo "  sudo clikader dns"
    echo "  sudo clikader apt-reset"
    echo "  sudo clikader aptreset"
    echo "  sudo clikader hostname"
    echo "  sudo clikader ipv6"
    echo "  sudo clikader 6"
}

run_script() {
    local script_name="$1"
    local script_title="$2"
    shift 2 || true

    local local_script="${SCRIPT_DIR}/components/${script_name}"
    local tmp_script="/tmp/${script_name}.clikader.$$"
    local script_to_run=""
    local downloaded=0

    echo -e "${BLUE}Selected:${NC} ${BOLD}${script_title}${NC}"
    echo ""

    if [[ -f "$local_script" ]]; then
        log "Found local script: ${local_script}"
        script_to_run="$local_script"
    else
        warning "Local script not found, downloading from GitHub..."
        info "URL: ${GITHUB_RAW_BASE}/${script_name}"
        echo ""

        if curl -fsSL "${GITHUB_RAW_BASE}/${script_name}" -o "$tmp_script"; then
            log "Downloaded successfully"
            script_to_run="$tmp_script"
            downloaded=1
        else
            error "Failed to download script from GitHub"
            warning "Please check your internet connection and try again"
            return 1
        fi
    fi

    chmod +x "$script_to_run"
    echo ""

    if bash "$script_to_run" "$@"; then
        echo ""
        echo -e "${GREEN}Script completed successfully${NC}"
    else
        local exit_code=$?
        echo ""
        error "Script encountered an error (exit code: ${exit_code})"
        if (( downloaded )); then
            rm -f "$tmp_script"
        fi
        return "$exit_code"
    fi

    if (( downloaded )); then
        rm -f "$tmp_script"
    fi
}

update_clikader() {
    echo -e "${CYAN}${BOLD}Update CLiKader${NC}"
    echo ""
    echo -e "${BLUE}Current version:${NC} ${BOLD}${CLIKADER_VERSION}${NC}"
    echo ""

    local install_path=""
    if command -v clikader &>/dev/null; then
        install_path="$(command -v clikader)"
        log "CLiKader is installed at: ${install_path}"
    else
        warning "CLiKader is not installed system-wide (running from local file)"
        echo ""
        echo "To install CLiKader system-wide, run:"
        echo -e "  ${BLUE}curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash${NC}"
        return 1
    fi

    echo ""
    info "Checking for updates..."

    local tmp_file="/tmp/clikader_latest.sh"
    if ! curl -fsSL "${GITHUB_RAW_BASE%/components}/clikader.sh" -o "$tmp_file" 2>/dev/null; then
        error "Failed to check for updates"
        echo "Please check your internet connection"
        return 1
    fi

    local remote_version
    remote_version="$(grep '^CLIKADER_VERSION=' "$tmp_file" | head -n1 | cut -d'"' -f2)"

    if [[ -z "$remote_version" ]]; then
        error "Could not determine remote version"
        rm -f "$tmp_file"
        return 1
    fi

    echo -e "${BLUE}Latest version:${NC} ${BOLD}${remote_version}${NC}"
    echo ""

    if [[ "$CLIKADER_VERSION" == "$remote_version" ]]; then
        echo -e "${GREEN}CLiKader is up to date${NC}"
        rm -f "$tmp_file"
        return 0
    fi

    echo -e "${YELLOW}Update available:${NC} ${CLIKADER_VERSION} -> ${remote_version}"
    echo ""
    read -r -p "Do you want to update CLiKader? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Update cancelled"
        rm -f "$tmp_file"
        return 0
    fi

    echo ""
    info "Installing update..."

    cp "$install_path" "${install_path}.backup"

    if mv "$tmp_file" "$install_path" && chmod +x "$install_path"; then
        echo -e "${GREEN}CLiKader updated successfully${NC}"
        echo "Updated to version: ${remote_version}"
        echo "Backup saved to: ${install_path}.backup"
        echo "Run 'clikader --version' to verify."
    else
        error "Update failed"
        echo "Restoring backup..."
        mv "${install_path}.backup" "$install_path"
        rm -f "$tmp_file"
        return 1
    fi
}

uninstall_clikader() {
    echo -e "${CYAN}${BOLD}Uninstall CLiKader${NC}"
    echo ""

    local install_path=""
    if command -v clikader &>/dev/null; then
        install_path="$(command -v clikader)"
        info "CLiKader is installed at: ${install_path}"
    else
        warning "CLiKader is not installed"
        return 1
    fi

    echo ""
    warning "This will remove CLiKader from your system"
    echo ""
    echo "The following will be removed:"
    echo "  - ${install_path}"
    if [[ -f "${install_path}.backup" ]]; then
        echo "  - ${install_path}.backup"
    fi
    echo ""
    read -r -p "Are you sure you want to uninstall CLiKader? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled"
        return 0
    fi

    echo ""
    info "Uninstalling CLiKader..."

    if rm -f "$install_path"; then
        log "Removed ${install_path}"
    else
        error "Failed to remove ${install_path}"
        return 1
    fi

    if [[ -f "${install_path}.backup" ]]; then
        rm -f "${install_path}.backup"
        log "Removed backup file"
    fi

    echo ""
    echo -e "${GREEN}CLiKader uninstalled successfully${NC}"
    echo "To clear the command from your shell cache, run:"
    echo -e "  ${BLUE}hash -d clikader${NC}"
    echo "Or simply start a new shell session."
}

dispatch_command() {
    local command="${1:-}"
    shift || true

    case "$command" in
        "" | "-h" | "--help" | "help")
            show_usage
            ;;
        "-v" | "--version" | "version")
            echo "$CLIKADER_VERSION"
            ;;
        "update" | "upgrade")
            require_root "$command"
            update_clikader
            ;;
        "dns")
            require_root "$command"
            run_script "setup_dns.sh" "Setup DNS" "$@"
            ;;
        "apt-reset" | "aptreset")
            require_root "$command"
            run_script "reset_apt_source.sh" "Reset APT Sources" "$@"
            ;;
        "hostname")
            require_root "$command"
            run_script "fix_hostname.sh" "Fix Hostname" "$@"
            ;;
        "ipv6" | "6")
            require_root "$command"
            run_script "configure_ipv6.sh" "Configure IPv6" "$@"
            ;;
        "uninstall" | "remove")
            require_root "$command"
            uninstall_clikader
            ;;
        *)
            error "Unknown command: ${command}"
            echo ""
            show_usage
            return 1
            ;;
    esac
}

main() {
    dispatch_command "$@"
}

main "$@"
