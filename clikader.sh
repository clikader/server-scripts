#!/usr/bin/env bash

# Clikader - Server Management Toolkit
# Master entrypoint for server management tasks via sub-commands.

set -euo pipefail

# Version
CLIKADER_VERSION="1.15.1"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script directory (works in bash and zsh)
SCRIPT_PATH="$0"
if [[ -n "${BASH_SOURCE:-}" ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
if [[ -L "$SCRIPT_PATH" ]]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
    echo 'This installation needs the complete CLiKader bundle. Migrate once with:' >&2
    echo 'curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash' >&2
    exit 1
fi
source "$SCRIPT_DIR/lib/common.sh"

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

# Returns 0 if any argument is a help flag (-h/--help), so usage can be shown
# without requiring root (e.g. 'clikader vpssetup --help' as a normal user).
has_help_flag() {
    local a
    for a in "$@"; do
        if [[ "$a" == "-h" || "$a" == "--help" ]]; then
            return 0
        fi
    done
    return 1
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
echo "  setup, vpssetup             Full fresh-server setup (network baseline, upgrade, ssh, nftables, fail2ban)"
echo "  dns                         Run DNS setup tool"
echo "  tcp                         Run TCP/network optimization tool"
echo "  nft, nftables               Manage inbound ports in the nftables allowlist"
echo "  doctor, status              Read-only health and configuration drift checks (--json)"
echo "  maintenance                 Security updates, package upgrades and backup retention"
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
    echo "  sudo clikader dns --recursive       (switch an existing box to unbound)"
    echo "  sudo clikader dns"
    echo "  sudo clikader tcp"
    echo "  sudo clikader tcp --dry-run"
    echo "  sudo clikader tcp --initcwnd --swap 2G"
    echo "  sudo clikader tcp --revert"
    echo "  sudo clikader nft list"
    echo "  sudo clikader nft add 8080, 8443 tcp"
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
    local script_to_run=""

    echo -e "${BLUE}Selected:${NC} ${BOLD}${script_title}${NC}"
    echo ""

    if [[ -f "$local_script" ]]; then
        log "Found local script: ${local_script}"
        script_to_run="$local_script"
    else
        error "Installed bundle is incomplete: missing $local_script. Reinstall CLiKader."
        return 1
    fi
    echo ""

    if bash "$script_to_run" "$@"; then
        echo ""
        echo -e "${GREEN}Script completed successfully${NC}"
    else
        local exit_code=$?
        echo ""
        error "Script encountered an error (exit code: ${exit_code})"
        return "$exit_code"
    fi

}

update_clikader() {
    bash "$SCRIPT_DIR/install.sh" --update "$@"
}

uninstall_clikader() {
    if has_help_flag "$@"; then echo 'Usage: clikader uninstall (prompts before removing installed code)'; return 0; fi
    [[ $# -eq 0 ]] || { error "Unknown uninstall option: $1"; return 2; }
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
    local bundle_root="${CLIKADER_INSTALL_ROOT:-/usr/local/lib/clikader}"
    if [[ "$SCRIPT_DIR" == "$bundle_root/releases/"* ]]; then
        echo "  - ${bundle_root} (installed code bundles)"
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
    if [[ "$SCRIPT_DIR" == "$bundle_root/releases/"* ]]; then
        rm -rf -- "$bundle_root/releases" "$bundle_root/current" "$bundle_root/previous" "$bundle_root/install.lock"
        rmdir "$bundle_root" 2>/dev/null || true
        log 'Removed installed CLiKader bundles'
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
            has_help_flag "$@" || require_root "$command"
            update_clikader "$@"
            ;;
        "setup" | "vpssetup")
            # Help must be reachable without root so any user can see usage.
            if ! has_help_flag "$@"; then
                require_root "$command"
            fi
            run_script "setup_vps.sh" "VPS Setup" "$@"
            ;;
        "dns")
            has_help_flag "$@" || require_root "$command"
            run_script "setup_dns.sh" "Setup DNS" "$@"
            ;;
        "tcp")
            has_help_flag "$@" || require_root "$command"
            run_script "optimize_tcp.sh" "TCP/Network Optimization" "$@"
            ;;
        "nft" | "nftables")
            # Help must be reachable without root so any user can see usage.
            if ! has_help_flag "$@"; then
                require_root "$command"
            fi
            run_script "nft_manager.sh" "NFTables Port Manager" "$@"
            ;;
        "apt-reset" | "aptreset")
            has_help_flag "$@" || require_root "$command"
            run_script "reset_apt_source.sh" "Reset APT Sources" "$@"
            ;;
        "hostname")
            has_help_flag "$@" || require_root "$command"
            run_script "fix_hostname.sh" "Fix Hostname" "$@"
            ;;
        "ipv6" | "6")
            has_help_flag "$@" || require_root "$command"
            run_script "configure_ipv6.sh" "Configure IPv6" "$@"
            ;;
        "onboard" | "o")
            # Removed: `clikader setup` absorbed the DNS/TCP/APT/IPv6/hostname
            # steps (and runs them in the right order). Keep a pointer instead
            # of a bare "Unknown command" for anyone with the old habit.
            error "'clikader onboard' has been removed and no longer performs any steps."
            echo "Use 'clikader setup' on a fresh server; on an existing one, run the"
            echo "individual steps: clikader dns, clikader tcp, clikader apt-reset,"
            echo "clikader ipv6, clikader hostname."
            return 1
            ;;
        "doctor" | "status")
            bash "$SCRIPT_DIR/components/doctor.sh" "$@"
            ;;
        "maintenance" | "maintain")
            has_help_flag "$@" || require_root "$command"
            run_script "maintenance.sh" "Server maintenance" "$@"
            ;;
        "uninstall" | "remove")
            has_help_flag "$@" || require_root "$command"
            uninstall_clikader "$@"
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

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
