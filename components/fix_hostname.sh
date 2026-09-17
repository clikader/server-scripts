#!/usr/bin/env bash

# Hostname Fix Script - Fixes hostname resolution and allows hostname changes
# Supports: Debian 11/12/13, Ubuntu 20.04/22.04/24.04/24.10

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# File paths (env-overridable so tests can target temp files; defaults unchanged)
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
HOSTNAME_FILE="${HOSTNAME_FILE:-/etc/hostname}"
for arg in "$@"; do
    case "$arg" in
        -h|--help) echo 'Usage: clikader hostname [--fix|--check]'; exit 0 ;;
        --fix|--check) ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

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

# --- Argument parsing (enables non-interactive use, e.g. from `clikader onboard`) ---
# Flags: --fix checks hostname resolution and auto-fixes it if it does NOT point
# to 127.0.0.1/127.0.1.1; --check only reports; --change is interactive only.
HOSTNAME_MODE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)    HOSTNAME_MODE="fix";    shift ;;
        --check)  HOSTNAME_MODE="check";  shift ;;
        -h|--help) HOSTNAME_MODE="help";  shift ;;
        *) shift ;;
    esac
done

# Get current hostname
get_current_hostname() {
    hostname
}

# Check if hostname resolves
check_hostname_resolution() {
    local current_hostname
    current_hostname="$(get_current_hostname)" || return 1
    
    echo ""
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    echo ""
    
    # Check if hostname resolves
    if getent hosts "$current_hostname" > /dev/null 2>&1; then
        local resolved_ip
        resolved_ip="$(getent hosts "$current_hostname" | awk '{print $1}')" || return 1
        log "✅ Hostname resolves to: $resolved_ip"
        
        if [[ "$resolved_ip" == "127.0.0.1" ]] || [[ "$resolved_ip" == "127.0.1.1" ]] || [[ "$resolved_ip" == "::1" ]]; then
            log "✅ Hostname correctly resolves to localhost"
            return 0
        else
            warning "Hostname resolves to $resolved_ip (not localhost)"
            return 1
        fi
    else
        warning "❌ Hostname does NOT resolve"
        return 1
    fi
}

# Fix hostname resolution
fix_hostname_resolution() (
    local current_hostname
    current_hostname="$(get_current_hostname)" || exit 1
    
    echo ""
    echo "=========================================="
    echo "  Fix Hostname Resolution"
    echo "=========================================="
    echo ""
    
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    
    clikader_lock hostname || exit 1
    tx_begin hostname || exit 1
    tx_save "$HOSTS_FILE" || exit 1
    rewrite_hosts "$current_hostname" "$current_hostname" || exit 1
    
    echo ""
    log "Current $HOSTS_FILE content:"
    echo ""
    cat "$HOSTS_FILE"
    echo ""
    
    # Verify resolution
    if check_hostname_resolution; then
        local resolved_ip
        resolved_ip="$(getent hosts "$current_hostname" | awk '{print $1}')" || exit 1
        log "✅ Hostname now resolves to: $resolved_ip"
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Hostname resolution fixed successfully!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        record_managed hostname "$HOSTS_FILE" || exit 1
        tx_commit
        return 0
    else
        error "Failed to fix hostname resolution"
        return 1
    fi
)

# Parse aliases as tokens, never as a regex and never discard unrelated names.
rewrite_hosts() {
    local old="$1" new="$2" tmp
    tmp="$(mktemp "${HOSTS_FILE}.XXXXXX")" || return 1
    if ! awk -v old="$old" -v new="$new" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        {
            line=$0; sub(/#.*/, "", line); n=split(line, fields, /[[:space:]]+/)
            out=""; aliases=0
            for (i=1; i<=n; i++) {
                if (fields[i] == "") continue
                if (out == "") { out=fields[i]; continue }
                if (fields[i] != old && fields[i] != new) { out=out "\t" fields[i]; aliases++ }
            }
            if (aliases) { if (index($0,"#")) out=out " " substr($0,index($0,"#")); print out }
        }
        END { print "127.0.1.1\t" new }
    ' "$HOSTS_FILE" > "$tmp"; then rm -f "$tmp"; return 1; fi
    chmod --reference="$HOSTS_FILE" "$tmp" || return 1
    mv -f "$tmp" "$HOSTS_FILE"
}

# Change hostname
change_hostname() (
    local current_hostname
    current_hostname="$(get_current_hostname)" || exit 1
    local new_hostname=""
    
    echo ""
    echo "=========================================="
    echo "  Change Hostname"
    echo "=========================================="
    echo ""
    
    log "Current hostname: ${BOLD}${current_hostname}${NC}"
    echo ""
    
    # Hostname validation regex (RFC 1123)
    local hostname_regex='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
    
    while true; do
        echo -n "Enter new hostname (lowercase, alphanumeric, hyphens allowed): "
        read -r new_hostname < /dev/tty
        
        # Convert to lowercase
        new_hostname=$(echo "$new_hostname" | tr '[:upper:]' '[:lower:]')
        
        # Validate hostname
        if [[ -z "$new_hostname" ]]; then
            error "Hostname cannot be empty"
            continue
        fi
        
        if [[ ! "$new_hostname" =~ $hostname_regex ]]; then
            error "Invalid hostname format"
            echo "Hostname must:"
            echo "  - Start and end with alphanumeric character"
            echo "  - Contain only lowercase letters, numbers, and hyphens"
            echo "  - Not start or end with a hyphen"
            continue
        fi
        
        if [[ ${#new_hostname} -gt 63 ]]; then
            error "Hostname too long (max 63 characters)"
            continue
        fi
        
        # Valid hostname
        break
    done
    
    echo ""
    log "New hostname will be: ${BOLD}${new_hostname}${NC}"
    echo ""
    echo -n "Confirm hostname change? (y/N): "
    read -r confirm < /dev/tty
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "Hostname change cancelled"
        return 1
    fi
    
    echo ""
    log "Changing hostname..."
    clikader_lock hostname || exit 1
    restore_hostname() { hostname "$current_hostname"; }
    tx_begin hostname restore_hostname || exit 1
    tx_save "$HOSTS_FILE" "$HOSTNAME_FILE" || exit 1
    
    # Set hostname using hostnamectl (systemd)
    if command -v hostnamectl &> /dev/null; then
        hostnamectl set-hostname "$new_hostname" || exit 1
        log "✅ Set hostname using hostnamectl"
    else
        # Fallback for systems without systemd
        echo "$new_hostname" > "$HOSTNAME_FILE" || exit 1
        hostname "$new_hostname" || exit 1
        log "✅ Updated $HOSTNAME_FILE and current hostname"
    fi
    
    rewrite_hosts "$current_hostname" "$new_hostname" || exit 1
    
    log "✅ Updated $HOSTS_FILE with new hostname"
    
    echo ""
    log "Verifying hostname change..."
    
    local verify_hostname
    verify_hostname="$(get_current_hostname)" || exit 1
    if [[ "$verify_hostname" == "$new_hostname" ]]; then
        log "✅ Hostname verified: $verify_hostname"
    else
        error "Hostname verification mismatch"; exit 1
    fi
    
    # Check resolution
    if getent hosts "$new_hostname" > /dev/null 2>&1; then
        local resolved_ip
        resolved_ip="$(getent hosts "$new_hostname" | awk '{print $1}')" || exit 1
        log "✅ New hostname resolves to: $resolved_ip"
    else
        error 'New hostname does not resolve'; exit 1
    fi
    record_managed hostname "$HOSTS_FILE" "$HOSTNAME_FILE" || exit 1
    tx_commit
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Hostname changed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Old hostname: $current_hostname"
    echo "New hostname: $new_hostname"
    echo ""
    info "Note: Some services may require restart to recognize the new hostname"
    info "You may need to reconnect your SSH session"
    echo ""
)

# Display interactive menu
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      Hostname Management Tool         ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    check_hostname_resolution || true
    
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Fix hostname resolution (add to /etc/hosts)"
    echo "  2) Change hostname"
    echo "  0) Exit"
    echo ""
}

# Main entrypoint
main() {
    # Non-interactive modes (skip the menu).
    case "$HOSTNAME_MODE" in
        check)
            check_hostname_resolution
            return $?
            ;;
        fix)
            echo ""
            if check_hostname_resolution; then
                log "Hostname already resolves to localhost. No fix needed."
            else
                log "Hostname does not resolve to 127.0.0.1. Auto-fixing (--fix)..."
                fix_hostname_resolution
            fi
            return $?
            ;;
        help|"")
            ;; # fall through to interactive menu below
    esac

    show_menu

    echo -n "Enter your choice [0-2]: "
    read -r choice < /dev/tty

    case "$choice" in
        1)
            fix_hostname_resolution
            ;;
        2)
            change_hostname
            ;;
        0)
            echo ""
            log "Exiting..."
            echo ""
            ;;
        *)
            error "Invalid choice. Please enter 0, 1, or 2."
            exit 1
            ;;
    esac
}

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
