#!/usr/bin/env bash

# VPS Setup Script - One-shot setup for a fresh Debian server
#
# Brings a freshly installed Debian 11/12/13 box to the clikader baseline:
# upgrade to Debian 13, prefer IPv4, install base packages, chrony, SSH
# hardening, UFW, fail2ban, then run `clikader o` for the remaining onboarding.
#
# Survives the reboot a major-version upgrade requires: answers and progress
# are persisted to /etc/clikader/setup.state, so re-running `clikader setup`
# after the reboot resumes from where it stopped without re-prompting.
#
# Idempotent: once finished, the state file marks the server as set up and a
# plain `clikader setup` will refuse to touch it. Use --force to re-run the
# whole flow or --reset to wipe state and start over.

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

# --- Paths and constants ---
STATE_DIR="/etc/clikader"
STATE_FILE="${STATE_DIR}/setup.state"
TARGET_DEBIAN_VERSION=13
TARGET_CODENAME="trixie"
TOTAL_STEPS=8

# Runtime state (defaults; overwritten by load_state when resuming)
ssh_port=""
ssh_public_key=""
extra_ports=""
last_step=0
clikader_setup_completed=0
completed_at=""
# Run-mode flags (from argv)
force=0
reset=0
# CLI-provided inputs (from argv). When set, the interactive prompts are skipped.
cli_ssh_port=""
cli_ssh_key=""
cli_extra_ports=""

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)            force=1;  shift ;;
        --reset)            reset=1;  shift ;;
        --ssh-port)
            [[ $# -ge 2 ]] || { error "--ssh-port requires a value"; exit 1; }
            cli_ssh_port="$2"; shift 2 ;;
        --ssh-port=*)       cli_ssh_port="${1#*=}"; shift ;;
        --ssh-key)
            [[ $# -ge 2 ]] || { error "--ssh-key requires a value"; exit 1; }
            cli_ssh_key="$2"; shift 2 ;;
        --ssh-key=*)        cli_ssh_key="${1#*=}"; shift ;;
        --additional-ports|--extra-ports)
            [[ $# -ge 2 ]] || { error "--additional-ports requires a value"; exit 1; }
            cli_extra_ports="$2"; shift 2 ;;
        --additional-ports=*) cli_extra_ports="${1#*=}"; shift ;;
        --extra-ports=*)    cli_extra_ports="${1#*=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage: clikader setup [options]

Full fresh-server setup for Debian 11/12/13:
  upgrade to Debian 13, prefer IPv4, base packages, chrony, SSH hardening,
  UFW, fail2ban, then \`clikader o\`.

Setup parameters (omit any to be prompted for it interactively):
  --ssh-port <port>            SSH port to configure (1-65535)
  --ssh-key <key>              Public key line for root (e.g. "ssh-ed25519 AAAA... me@h")
  --additional-ports <ports>   Extra UFW ports, comma/space separated (e.g. "36158,443")

Run modes:
  --force   Re-run the entire flow even if already completed.
  --reset   Wipe saved state and start over from scratch.

When --ssh-port and --ssh-key are both provided, the run is fully
non-interactive. State is kept in ${STATE_FILE}; after a release-upgrade
reboot, just re-run \`clikader setup\` and it resumes from where it stopped.
EOF
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            echo "Run 'clikader setup --help' for usage."
            exit 1
            ;;
    esac
done

# --- OS detection ---
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS: /etc/os-release missing"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        error "This setup targets Debian only (detected: ${ID:-unknown})."
        error "Run it on a fresh Debian 11/12/13 server."
        exit 1
    fi
    # VERSION_ID may carry a trailing qualifier on some images; strip to the major.
    debian_major="${VERSION_ID%%.*}"
    debian_codename="${VERSION_CODENAME:-}"
    if [[ -z "$debian_codename" ]]; then
        case "$debian_major" in
            13) debian_codename="trixie" ;;
            12) debian_codename="bookworm" ;;
            11) debian_codename="bullseye" ;;
        esac
    fi
}

# --- State persistence ---
# Regenerates the whole file on each write to avoid in-place corruption.
# Values are quoted/escaped so the file stays shell-sourceable.

# Escape single quotes in a string for safe embedding in a single-quoted shell
# value: each ' becomes '\''. Round-trips even for keys containing apostrophes.
escape_single_quotes() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

save_state() {
    mkdir -p "$STATE_DIR"
    local escaped_key
    escaped_key="$(escape_single_quotes "$ssh_public_key")"
    cat > "$STATE_FILE" <<EOF
# Managed by clikader setup. Do not edit by hand; use 'clikader setup --reset'.
ssh_port='${ssh_port}'
ssh_public_key='${escaped_key}'
extra_ports='${extra_ports}'
last_step=${last_step}
clikader_setup_completed=${clikader_setup_completed}
completed_at='${completed_at}'
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # last_step / completed flags become shell vars here; copy into our globals.
    : "${ssh_port:=}"
    : "${ssh_public_key:=}"
    : "${extra_ports:=}"
    : "${last_step:=0}"
    : "${clikader_setup_completed:=0}"
    : "${completed_at:=}"
}

# --- Validation helpers ---
valid_port() {
    # Accepts a single token; returns 0 if it is an integer in 1..65535.
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

valid_ssh_pubkey() {
    # Accepts a single OpenSSH public-key line. Allows the common key types.
    # The key-type token may include a curve (ecdsa-sha2-nistp256) and/or a
    # host suffix (sk-ssh-ed25519@openssh.com), so we anchor on the prefix
    # followed by its non-space tail and then the required whitespace separator.
    local key="$1"
    [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[a-z0-9]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh\.com)[[:space:]] ]]
}

# Normalize a port list that may be comma or space separated into a clean
# space-separated string. Invalid tokens abort with an error (fail fast when
# supplied via CLI, rather than silently dropping one).
normalize_port_list() {
    local raw="$1"
    # Allow "none" / empty as a sentinel for "no extra ports".
    raw="${raw//,/ }"
    raw="$(echo "$raw" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
    if [[ -z "$raw" || "$raw" == "none" ]]; then
        printf ''
        return 0
    fi
    local p
    for p in $raw; do
        if ! valid_port "$p"; then
            error "Invalid port '${p}' in port list"
            return 1
        fi
    done
    printf '%s' "$raw"
}

# Apply CLI-provided inputs, validating each. On any error, abort (these are
# explicit user flags, so we fail loud rather than fall through to prompting).
apply_cli_inputs() {
    if [[ -n "$cli_ssh_port" ]]; then
        if ! valid_port "$cli_ssh_port"; then
            error "--ssh-port '${cli_ssh_port}' is not a valid port (1-65535)"
            exit 1
        fi
        ssh_port="$cli_ssh_port"
    fi
    if [[ -n "$cli_ssh_key" ]]; then
        # Trim surrounding whitespace before validating.
        cli_ssh_key="${cli_ssh_key#"${cli_ssh_key%%[![:space:]]*}"}"
        cli_ssh_key="${cli_ssh_key%"${cli_ssh_key##*[![:space:]]}"}"
        if ! valid_ssh_pubkey "$cli_ssh_key"; then
            error "--ssh-key does not look like a valid OpenSSH public key line."
            echo "It should start with one of: ssh-rsa, ssh-ed25519, ecdsa-sha2-..., etc."
            exit 1
        fi
        ssh_public_key="$cli_ssh_key"
    fi
    if [[ -n "$cli_extra_ports" ]]; then
        extra_ports="$(normalize_port_list "$cli_extra_ports")" || exit 1
    fi
}

# --- Input collection (interactive, only when no saved answers) ---
# Each prompt is guarded so a value already supplied (via CLI flag or saved
# state) is reused instead of re-asked. This lets the user provide partial
# input on the command line and fill in the rest interactively.
collect_inputs() {
    echo -e "${CYAN}${BOLD}Step 0: Collect setup parameters${NC}"
    echo ""

    # SSH port
    if [[ -n "$ssh_port" ]]; then
        log "SSH port already set: ${ssh_port}"
    else
        while true; do
            echo -n "SSH port to use (1-65535): "
            read -r ssh_port < /dev/tty
            ssh_port="${ssh_port//[$'\t\r\n ']/}"
            if valid_port "$ssh_port"; then
                break
            fi
            error "'${ssh_port}' is not a valid port (must be 1-65535)"
        done
        if [[ "$ssh_port" == "22" ]]; then
            warning "Port 22 is the default and gets heavy brute-force attention."
            warning "Consider a non-standard port; fail2ban will still protect it."
        fi
    fi

    echo ""

    # Public key
    if [[ -n "$ssh_public_key" ]]; then
        log "Public key already set: ${ssh_public_key%% *}"
    else
        while true; do
            echo -n "Public SSH key for root (paste full 'ssh-... user@host' line): "
            read -r ssh_public_key < /dev/tty
            ssh_public_key="${ssh_public_key#"${ssh_public_key%%[![:space:]]*}"}"  # ltrim
            ssh_public_key="${ssh_public_key%"${ssh_public_key##*[![:space:]]}"}"  # rtrim
            if valid_ssh_pubkey "$ssh_public_key"; then
                break
            fi
            error "That does not look like a valid OpenSSH public key line."
            echo "It should start with one of: ssh-rsa, ssh-ed25519, ecdsa-sha2-..., etc."
        done
    fi

    echo ""

    # Extra ports (optional) — only prompt if not already set via CLI/state.
    # (Empty extra_ports is a valid "none" value, so we can't distinguish
    # "unset" from "explicitly none" here; CLI/state wins by being applied first.)
    if [[ -n "$cli_extra_ports" ]]; then
        log "Additional ports already set: ${extra_ports:-none}"
    else
        while true; do
            echo -n "Additional ports to open in UFW (space/comma separated, blank for none): "
            read -r raw_extra < /dev/tty
            if extra_ports="$(normalize_port_list "$raw_extra")"; then
                break
            fi
            # normalize_port_list already printed an error; loop to re-prompt.
        done
    fi

    echo ""
    # Persist answers immediately so a later reboot/resume never re-prompts.
    save_state
    log "Saved parameters to ${STATE_FILE}"
}

# --- Step banner ---
step_banner() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║ Step ${num}/${TOTAL_STEPS}: ${title}${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Step 1: Upgrade to Debian 13 (trixie) ---
# Advances one codename hop per invocation, then asks the user to reboot and
# re-run. Progress is tracked by the OS codename itself, so on the next run the
# advanced codename means the hop is already done.
step_upgrade_debian() {
    step_banner 1 "Upgrade to Debian 13 (Trixie)"

    if [[ "$debian_codename" == "$TARGET_CODENAME" ]]; then
        log "Already on Debian ${TARGET_DEBIAN_VERSION} (${TARGET_CODENAME}). Nothing to upgrade."
        last_step=1
        save_state
        return 0
    fi

    local from="$debian_codename" to=""
    case "$debian_codename" in
        bullseye) to="bookworm" ;;
        bookworm) to="trixie"   ;;
        *)
            error "Unsupported starting codename '${debian_codename}' (need bullseye/bookworm/trixie)."
            return 1
            ;;
    esac

    info "Upgrading one release: ${from} -> ${to} (target: ${TARGET_CODENAME})"
    info "Note: a multi-hop upgrade (e.g. bullseye -> trixie) is done one release"
    info "at a time, with a reboot between each hop."
    echo ""

    # First bring the current release fully up to date.
    log "Updating current system (apt update/upgrade/full-upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get full-upgrade -y
    apt-get --purge autoremove -y

    # Backup sources before rewriting codenames.
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local backup_dir="/etc/apt/sources.backup_${ts}"
    mkdir -p "$backup_dir"
    [[ -f /etc/apt/sources.list ]] && cp /etc/apt/sources.list "$backup_dir/" || true
    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -r /etc/apt/sources.list.d/. "$backup_dir/" 2>/dev/null || true
    fi
    log "Backed up APT sources to ${backup_dir}"

    # Rewrite codename everywhere apt reads sources (sources.list + .list/.sources).
    log "Rewriting codename '${from}' -> '${to}' in APT sources..."
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i "s/${from}/${to}/g" /etc/apt/sources.list
    fi
    if [[ -d /etc/apt/sources.list.d ]]; then
        # Quote the glob; zsh users sourcing paths are not a concern here (run under bash).
        sed -i "s/${from}/${to}/g" /etc/apt/sources.list.d/*.list 2>/dev/null || true
        sed -i "s/${from}/${to}/g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    fi

    log "Running apt update against new sources..."
    apt-get update

    log "Upgrading without pulling new packages first (safer for the first pass)..."
    apt-get upgrade --without-new-pkgs -y

    log "Full-upgrade to ${to}..."
    apt-get full-upgrade -y
    apt-get --purge autoremove -y

    # Record that step 1 ran, so a re-run after reboot continues from step 2.
    last_step=1
    save_state

    echo ""
    if [[ "$to" == "$TARGET_CODENAME" ]]; then
        echo -e "${GREEN}Release upgrade to Debian ${TARGET_DEBIAN_VERSION} (${TARGET_CODENAME}) complete.${NC}"
    else
        warning "Reached ${to}. Another hop to ${TARGET_CODENAME} is still needed."
    fi
    echo ""
    echo -e "${BOLD}A reboot is required before continuing.${NC}"
    echo "Reboot now, then re-run:  sudo clikader setup"
    echo "It will pick up automatically from step 2 (no re-prompting)."
    echo ""
    info "Aborting here so you can reboot cleanly. Re-run after reboot to resume."
    # Intentionally exit the whole script: a reboot is unavoidable.
    exit 0
}

# --- Step 2: Prefer IPv4 ---
step_prefer_ipv4() {
    step_banner 2 "Prefer IPv4"
    if grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
        log "IPv4 preference already set in /etc/gai.conf"
    else
        echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
        log "Added IPv4 preference to /etc/gai.conf"
    fi
    last_step=2
    save_state
}

# --- Step 3: Install base packages ---
step_install_packages() {
    step_banner 3 "Install base packages"
    local pkgs=(nano curl wget unzip fail2ban sudo python3-systemd cron chrony dnsutils jq ufw)
    log "Installing: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "${pkgs[@]}"
    log "Base packages installed"
    last_step=3
    save_state
}

# --- Step 4: Enable chrony for time sync ---
step_enable_chrony() {
    step_banner 4 "Enable chrony (NTP time sync)"
    systemctl enable --now chrony
    log "chrony enabled and started"
    last_step=4
    save_state
}

# --- Step 5: SSH hardening + authorized_keys ---
step_ssh_hardening() {
    step_banner 5 "SSH hardening + authorized key"

    local sshd_config="/etc/ssh/sshd_config"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp "$sshd_config" "${sshd_config}.backup_${ts}"
    log "Backed up ${sshd_config} to ${sshd_config}.backup_${ts}"

    # Remove any existing Port directives, then append our single Port line.
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$sshd_config"
    echo "Port ${ssh_port}" >> "$sshd_config"

    # Force PermitRootLogin to prohibit-password (key-only root login).
    if grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' "$sshd_config"; then
        sed -i -E "s|^[[:space:]]*PermitRootLogin.*|PermitRootLogin prohibit-password|" "$sshd_config"
    else
        echo "PermitRootLogin prohibit-password" >> "$sshd_config"
    fi

    # Validate config before restarting so a bad edit doesn't lock us out.
    if ! sshd -t 2>/dev/null; then
        error "sshd config validation failed; NOT restarting sshd."
        error "Inspect ${sshd_config} and its .backup_${ts} before continuing."
        return 1
    fi
    systemctl restart sshd
    log "sshd restarted on port ${ssh_port} (root login: prohibit-password)"

    # authorized_keys: create with correct perms, add key only if missing.
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if [[ -n "$ssh_public_key" ]] && ! grep -qF "$ssh_public_key" /root/.ssh/authorized_keys; then
        echo "$ssh_public_key" >> /root/.ssh/authorized_keys
        log "Added public key to /root/.ssh/authorized_keys"
    else
        log "Public key already present in /root/.ssh/authorized_keys"
    fi

    last_step=5
    save_state
}

# --- Step 6: UFW firewall ---
step_configure_ufw() {
    step_banner 6 "Configure UFW firewall"
    ufw allow "${ssh_port}/tcp"
    log "Allowed SSH port ${ssh_port}/tcp"
    if [[ -n "$extra_ports" ]]; then
        for p in $extra_ports; do
            ufw allow "${p}"
            log "Allowed port ${p}"
        done
    fi
    ufw --force enable
    log "UFW enabled"
    ufw status
    last_step=6
    save_state
}

# --- Step 7: fail2ban (SSH protection) ---
# Config targets Debian 13's fail2ban 1.1.0 defaults: systemd journal backend
# (so no logpath needed) and nftables ban action. On the [sshd] jail the
# systemd backend auto-detects the ssh.service journal match, so we only pin
# the port (must match the custom sshd port; the default `port = ssh` token
# resolves to 22 and would watch the wrong port).
step_setup_fail2ban() {
    step_banner 7 "Configure fail2ban for SSH"
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Never ban localhost, even under a flood of failed attempts.
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
EOF
    log "Wrote /etc/fail2ban/jail.local (sshd port ${ssh_port}, backend systemd)"

    # Validate config before touching the running service.
    if ! fail2ban-client -t >/dev/null 2>&1; then
        error "fail2ban config test failed; NOT restarting the service."
        error "Inspect /etc/fail2ban/jail.local before continuing."
        return 1
    fi
    log "fail2ban config test passed"

    systemctl enable --now fail2ban
    sleep 2
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
    sleep 2
    fail2ban-client status
    last_step=7
    save_state
}

# --- Step 8: Run `clikader o` for the rest of onboarding ---
step_run_onboard() {
    step_banner 8 "Run clikader onboarding (clikader o)"
    if ! command -v clikader &>/dev/null; then
        warning "'clikader' is not installed on PATH; skipping onboard step."
        info "Install it with:"
        echo "  curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash"
        echo "Then run 'sudo clikader o' manually."
    else
        clikader o
    fi
    last_step=8
    save_state
}

# --- Run a step by number, if not already completed ---
run_step_if_needed() {
    local num="$1"
    if (( last_step >= num )); then
        info "Step ${num} already completed; skipping."
        return 0
    fi
    case "$num" in
        1) step_upgrade_debian ;;
        2) step_prefer_ipv4 ;;
        3) step_install_packages ;;
        4) step_enable_chrony ;;
        5) step_ssh_hardening ;;
        6) step_configure_ufw ;;
        7) step_setup_fail2ban ;;
        8) step_run_onboard ;;
        *) error "Unknown step ${num}"; return 1 ;;
    esac
}

# --- Main ---
main() {
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       CLiKader VPS Setup                ${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""

    detect_os
    log "Detected: Debian ${debian_major} (${debian_codename})"

    # --reset wipes state and starts completely fresh.
    if (( reset )); then
        if [[ -f "$STATE_FILE" ]]; then
            rm -f "$STATE_FILE"
            log "Removed existing state file (--reset)."
        fi
        last_step=0
        clikader_setup_completed=0
        completed_at=""
    fi

    load_state || true

    # Refuse to re-run on an already-configured server unless forced.
    if (( clikader_setup_completed )) && (( ! force )); then
        echo ""
        echo -e "${GREEN}This server is already set up${NC} (completed: ${completed_at:-unknown})."
        echo "Re-running setup could change ports/keys/firewall on a live server."
        echo ""
        echo "To re-run the full flow anyway:  sudo clikader setup --force"
        echo "To wipe state and start over:    sudo clikader setup --reset"
        echo ""
        exit 0
    fi
    if (( force )); then
        warning "--force: re-running the full setup; state will be overwritten at the end."
        # Restart progress so every step applies again.
        last_step=0
        clikader_setup_completed=0
        completed_at=""
    fi

    # Resolve setup parameters. Precedence: CLI flags > saved state > prompt.
    # CLI flags win so an explicit `--ssh-port`/`--ssh-key` always applies.
    local had_cli=0
    if [[ -n "$cli_ssh_port" || -n "$cli_ssh_key" || -n "$cli_extra_ports" ]]; then
        apply_cli_inputs
        had_cli=1
    fi

    # After applying CLI inputs, prompt for anything still missing.
    if [[ -z "$ssh_port" || -z "$ssh_public_key" ]]; then
        if (( had_cli )); then
            info "Some parameters not provided via flags; prompting for the rest."
        elif (( last_step > 0 )); then
            warning "Saved parameters are incomplete; re-prompting for inputs."
        fi
        collect_inputs
    else
        info "Using parameters: ssh_port=${ssh_port}, extra_ports='${extra_ports:-none}'."
        # Persist CLI-provided inputs so a later reboot/resume never re-prompts.
        (( had_cli )) && save_state
    fi

    # Run steps 1..8, skipping any already completed. Step 1 may exit for a reboot.
    local step
    for step in $(seq 1 $TOTAL_STEPS); do
        run_step_if_needed "$step"
    done

    # All done: mark complete.
    clikader_setup_completed=1
    completed_at="$(date -Iseconds 2>/dev/null || date)"
    save_state

    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   VPS setup complete!                   ${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    info "Summary:"
    echo "  • OS:           Debian ${debian_major} (${debian_codename})"
    echo "  • SSH port:     ${ssh_port} (root login: prohibit-password)"
    echo "  • Extra ports:  ${extra_ports:-none}"
    echo "  • fail2ban:     protecting sshd on port ${ssh_port}"
    echo "  • UFW:          enabled"
    echo "  • chrony:       time sync active"
    echo ""
    if [[ "$ssh_port" != "22" ]]; then
        warning "SSH now listens on port ${ssh_port}. Connect with:"
        echo "  ssh -p ${ssh_port} root@<server>"
    fi
    echo ""
    info "State saved to ${STATE_FILE}. Re-running 'clikader setup' will refuse"
    info "until you pass --force (re-run) or --reset (start over)."
    echo ""
}

main "$@"
