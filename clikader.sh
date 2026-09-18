#!/usr/bin/env bash

# Clikader - Server Management Toolkit
# Master entrypoint for server management tasks via sub-commands.

set -euo pipefail

# Version
CLIKADER_VERSION="1.14.0"

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
echo "  setup, vpssetup             Full fresh-server setup (upgrade, ssh, nftables, fail2ban, onboard)"
echo "  onboard, o                  One-shot setup: dns + tcp + apt + ipv6-off + hostname"
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
echo "  sudo clikader onboard"
echo "  sudo clikader onboard --recursive   (DNS via local unbound recursive resolver)"
echo "  sudo clikader dns --recursive       (switch an existing box to unbound)"
    echo "  sudo clikader dns"
    echo "  sudo clikader tcp"
    echo "  sudo clikader tcp --dry-run"
    echo "  sudo clikader tcp --initcwnd --swap 2G"
    echo "  sudo clikader tcp --revert"
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
    # Recognized options:
    #   --recursive / -r   run the DNS step with a local unbound recursive
    #                      resolver instead of forwarding to public DNS
    local dns_extra_args="" profile=proxy ipv6_policy=ask failed=0
    local arg
    for arg in "$@"; do
        case $arg in
            -r|--recursive) dns_extra_args="--recursive" ;;
            --profile=proxy) profile=proxy ;;
            --profile=general) profile=general ;;
            --keep-ipv6) ipv6_policy=keep ;;
            --disable-ipv6) ipv6_policy=disable ;;
            -h|--help) echo 'Usage: clikader onboard [--profile=proxy|general] [--recursive] [--keep-ipv6|--disable-ipv6]'; return 0 ;;
            *) error "Unknown onboard option: $arg"; return 2 ;;
        esac
    done
    if [[ "$profile" == general && -n "$dns_extra_args" ]]; then
        error '--recursive changes DNS; use the proxy profile or clikader dns --recursive explicitly.'
        return 2
    fi
    ipv6_policy="$(choose_ipv6 "$ipv6_policy")" || return 1
    clikader_lock onboard || return 1

    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       CLiKader Onboarding (5 steps)     ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    info "Runs all setup steps non-interactively with production defaults:"
    if [[ -n "$dns_extra_args" ]]; then
        info "  1. DNS   (local recursive unbound, no public DNS cache in path)"
    else
        info "  1. DNS   (direct-IP; Azure DNS on Azure VMs, else latency-ordered public pick)"
    fi
    info "  2. TCP   (network-stack optimization)"
    info "  3. APT   (reset to official sources)"
    info "  Profile: $profile; IPv6: $ipv6_policy"
    info "  5. Hostname (fix to 127.0.0.1 if not already)"
    echo ""

    ONBOARD_RESULTS=()

    # 1. DNS — --yes uses direct-IP mode + default providers + proceeds past rerun
    if [[ "$profile" == proxy ]]; then
        onboard_step 1 "setup_dns.sh" "Setup DNS" --yes $dns_extra_args || failed=1

    # 2. TCP — non-interactive, apply tuning
        onboard_step 2 "optimize_tcp.sh" "TCP/Network Optimization" || failed=1

    # 3. APT — already non-interactive
        onboard_step 3 "reset_apt_source.sh" "Reset APT Sources" || failed=1
    else
        ONBOARD_RESULTS+=("Provider DNS, APT repositories and network tuning preserved (general profile)")
    fi

    # 4. IPv6 — disable, skip confirm
    if [[ "$ipv6_policy" == disable ]]; then
        onboard_step 4 "configure_ipv6.sh" "Disable IPv6" --disable --yes || failed=1
    else
        ONBOARD_RESULTS+=("IPv6 kept enabled")
    fi

    # 5. Hostname — auto-fix if not pointing to localhost
    onboard_step 5 "fix_hostname.sh" "Fix Hostname" --fix || failed=1

    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       Onboarding Summary                ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    for r in "${ONBOARD_RESULTS[@]}"; do
        echo -e "  • $r"
    done
    echo ""
    if (( failed == 0 )); then
        mkdir -p "$CLIKADER_STATE_DIR"
        printf 'profile=%s\nipv6=%s\n' "$profile" "$ipv6_policy" > "$CLIKADER_STATE_DIR/onboard.conf"
    fi
    return "$failed"
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
            has_help_flag "$@" || require_root "$command"
            onboard_clikader "$@"
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
