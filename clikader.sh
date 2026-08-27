#!/usr/bin/env bash

# Clikader - Server Management Toolkit
# Master entrypoint for server management tasks via sub-commands.

set -euo pipefail

# Version
CLIKADER_VERSION="1.8.3"

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
echo "  setup, vpssetup             Full fresh-server setup (upgrade, ssh, nftables, fail2ban, onboard)"
echo "  onboard, o                  One-shot setup: dns + tcp + apt + ipv6-off + hostname"
echo "  dns                         Run DNS setup tool"
echo "  tcp                         Run TCP/network optimization tool"
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
echo "  sudo clikader setup"
echo "  sudo clikader vpssetup --force"
echo "  sudo clikader onboard"
    echo "  sudo clikader dns"
    echo "  sudo clikader tcp"
    echo "  sudo clikader tcp --dry-run"
    echo "  sudo clikader tcp --revert"
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
        # Cache-bust: raw.githubusercontent.com is CDN-cached (max-age=300).
        # A query string keeps VPS downloads aligned with this clikader version.
        local download_url="${GITHUB_RAW_BASE}/${script_name}?v=${CLIKADER_VERSION}"
        info "URL: ${download_url}"
        echo ""

        if curl -fsSL \
            -H 'Cache-Control: no-cache' \
            -H 'Pragma: no-cache' \
            "$download_url" -o "$tmp_script"; then
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
    # Cache-bust so update checks are not stuck on a stale CDN object.
    if ! curl -fsSL \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        "${GITHUB_RAW_BASE%/components}/clikader.sh?v=$(date +%s)" \
        -o "$tmp_file" 2>/dev/null; then
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

# Run a single onboarding step. Wraps run_script with a pass/fail banner so the
# sequence continues even if one step fails (we just report it at the end).
# Args: step_number script title [extra args...]
onboard_step() {
    local num="$1"; shift
    local script="$1"; shift
    local title="$1"; shift

    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║ Step ${num}/5: ${title}                 ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""

    if run_script "$script" "$title" "$@"; then
        ONBOARD_RESULTS+=("Step $num ($title): ${GREEN}OK${NC}")
        return 0
    else
        ONBOARD_RESULTS+=("Step $num ($title): ${RED}FAILED${NC}")
        warning "Step $num ($title) failed; continuing with remaining steps."
        return 1
    fi
}

onboard_clikader() {
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       CLiKader Onboarding (5 steps)     ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    info "Runs all setup steps non-interactively with production defaults:"
    info "  1. DNS   (direct-IP, default providers, latency-ordered)"
    info "  2. TCP   (network-stack optimization)"
    info "  3. APT   (reset to official sources)"
    info "  4. IPv6  (disabled)"
    info "  5. Hostname (fix to 127.0.0.1 if not already)"
    echo ""

    ONBOARD_RESULTS=()

    # 1. DNS — --yes uses direct-IP mode + default providers + proceeds past rerun
    onboard_step 1 "setup_dns.sh"        "Setup DNS"            "--yes"

    # 2. TCP — non-interactive, apply tuning
    onboard_step 2 "optimize_tcp.sh"     "TCP/Network Optimization"

    # 3. APT — already non-interactive
    onboard_step 3 "reset_apt_source.sh" "Reset APT Sources"

    # 4. IPv6 — disable, skip confirm
    onboard_step 4 "configure_ipv6.sh"   "Disable IPv6"         "--disable" "--yes"

    # 5. Hostname — auto-fix if not pointing to localhost
    onboard_step 5 "fix_hostname.sh"     "Fix Hostname"         "--fix"

    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       Onboarding Summary                ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    for r in "${ONBOARD_RESULTS[@]}"; do
        echo -e "  • $r"
    done
    echo ""
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
        "setup" | "vpssetup")
            require_root "$command"
            run_script "setup_vps.sh" "VPS Setup" "$@"
            ;;
        "dns")
            require_root "$command"
            run_script "setup_dns.sh" "Setup DNS" "$@"
            ;;
        "tcp")
            require_root "$command"
            run_script "optimize_tcp.sh" "TCP/Network Optimization" "$@"
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
        "onboard" | "o")
            require_root "$command"
            onboard_clikader
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
