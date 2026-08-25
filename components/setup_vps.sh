#!/usr/bin/env bash

# VPS Setup Script - One-shot setup for a fresh Debian server
#
# Brings a freshly installed Debian 11/12/13 box to the clikader baseline:
# upgrade to Debian 13, prefer IPv4, install base packages, chrony, SSH
# hardening, nftables, fail2ban, then run `clikader o` for the remaining onboarding.
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
  nftables, fail2ban, then \`clikader o\`.

Setup parameters (omit any to be prompted for it interactively):
  --ssh-port <port>            SSH port to configure (1-65535)
  --ssh-key <key>              Public key line for root (e.g. "ssh-ed25519 AAAA... me@h")
  --additional-ports <ports>   Extra ports to open in nftables, comma/space separated (e.g. "36158,443")

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
            echo -n "Additional ports to open in the firewall (space/comma separated, blank for none): "
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
    local pkgs=(nano curl wget unzip fail2ban sudo python3-systemd cron chrony dnsutils jq nftables fping)
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
#
# Provider images routinely defeat a plain "change Port in /etc/ssh/sshd_config":
#   * /etc/ssh/sshd_config.d/*.conf drop-ins: Debian's Include sits at the TOP
#     of sshd_config and sshd is first-value-wins, so a provider drop-in beats
#     anything appended at the bottom — and multiple Port lines make sshd
#     listen on ALL of them. cloud-init drop-ins commonly set
#     PasswordAuthentication yes; some providers even set PubkeyAuthentication
#     no, which combined with prohibit-password locks root out entirely.
#   * ssh.socket activation (Debian 12/13): systemd holds the listener on
#     ListenStream=22 and Port in sshd_config is ignored completely.
# So this step scrubs the drop-ins, puts a managed block at the very top of
# the main config, disables socket activation, then VERIFIES the effective
# config and the actual listener instead of trusting the sshd -t syntax check.
step_ssh_hardening() {
    step_banner 5 "SSH hardening + authorized key"

    local sshd_config="/etc/ssh/sshd_config"
    local sshd_conf_dir="/etc/ssh/sshd_config.d"
    local ts f
    ts="$(date +%Y%m%d_%H%M%S)"

    # Directives this step owns, wherever sshd reads them from.
    local managed_keywords='Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication'

    # --- Recon: what is effectively running right now? ---
    local current_ports
    current_ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | tr '\n' ' ' | sed 's/ $//')"
    info "Effective sshd port(s) before hardening: ${current_ports:-unknown}"
    if [[ -n "$current_ports" && " ${current_ports} " != *" ${ssh_port} "* ]]; then
        warning "Provider SSH port (${current_ports}) differs from the requested ${ssh_port}."
    fi
    local drop_ins=()
    while IFS= read -r f; do
        drop_ins+=("$f")
    done < <(compgen -G "${sshd_conf_dir}/*.conf" || true)
    if (( ${#drop_ins[@]} )); then
        info "sshd drop-ins present: ${drop_ins[*]}"
    fi

    cp "$sshd_config" "${sshd_config}.backup_${ts}"
    log "Backed up ${sshd_config} to ${sshd_config}.backup_${ts}"

    # --- Drop-ins: comment out our directives so they cannot override us. ---
    for f in "${drop_ins[@]}"; do
        if grep -qE "^[[:space:]]*(${managed_keywords})[[:space:]]" "$f"; then
            cp "$f" "${f}.backup_${ts}"
            sed -i -E "s@^([[:space:]]*)(${managed_keywords})([[:space:]].*)?@\1# [clikader setup] superseded: \2\3@" "$f"
            log "Neutralized provider directives in ${f} (backup: ${f}.backup_${ts})"
        fi
    done

    # --- Main config: replace previous managed block, then re-add at the top ---
    # (top placement wins under sshd's first-value-wins rule, ahead of the
    # Include line and anything a provider may add later)
    sed -i '/^# --- BEGIN clikader sshd settings ---$/,/^# --- END clikader sshd settings ---$/d' "$sshd_config"
    sed -i -E "/^[[:space:]]*(${managed_keywords})[[:space:]]/d" "$sshd_config"
    {
        echo "# --- BEGIN clikader sshd settings ---"
        echo "# Managed by clikader setup; supersedes the provider defaults below"
        echo "# and in sshd_config.d/*.conf (first obtained value wins in sshd)."
        echo "Port ${ssh_port}"
        echo "PermitRootLogin prohibit-password"
        echo "PasswordAuthentication no"
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo "# --- END clikader sshd settings ---"
    } | cat - "$sshd_config" > "${sshd_config}.new"
    chmod --reference="$sshd_config" "${sshd_config}.new"
    mv "${sshd_config}.new" "$sshd_config"

    # Validate config before restarting so a bad edit doesn't lock us out.
    local sshd_test
    if ! sshd_test="$(sshd -t 2>&1)"; then
        error "sshd config validation failed; NOT restarting sshd."
        [[ -n "$sshd_test" ]] && error "$sshd_test"
        error "Inspect ${sshd_config} and its .backup_${ts} before continuing."
        return 1
    fi

    # authorized_keys BEFORE any restart: password auth is about to be turned
    # off, so the key must already be in place or root gets locked out.
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

    # Socket activation: while ssh.socket holds the listener, Port in
    # sshd_config is ignored. Fall back to the classic always-running daemon.
    if systemctl is-active ssh.socket &>/dev/null || systemctl is-enabled ssh.socket &>/dev/null; then
        log "ssh.socket activation is in use; Port in sshd_config would be ignored."
        log "Disabling ssh.socket, enabling ssh.service so our Port takes effect."
        systemctl disable --now ssh.socket
        systemctl enable ssh.service >/dev/null 2>&1
    fi
    systemctl restart sshd

    # --- Verify: effective config AND real listener, not just exit codes. ---
    local effective eff_ports eff_pw eff_pk eff_prl fail=0
    effective="$(sshd -T 2>/dev/null)"
    eff_ports="$(awk '$1 == "port" {print $2}' <<<"$effective" | tr '\n' ' ' | sed 's/ $//')"
    eff_pw="$(awk '$1 == "passwordauthentication" {print $2}' <<<"$effective")"
    eff_pk="$(awk '$1 == "pubkeyauthentication" {print $2}' <<<"$effective")"
    eff_prl="$(awk '$1 == "permitrootlogin" {print $2}' <<<"$effective")"

    if [[ -z "$effective" ]]; then
        error "Cannot read effective sshd config (sshd -T failed); verify manually."
        fail=1
    fi
    if [[ "$eff_ports" != "$ssh_port" ]]; then
        error "Effective sshd port is '${eff_ports:-unset}', expected '${ssh_port}'."
        error "A drop-in or ssh.socket may still override sshd_config — check:"
        error "  grep -r 'Port' ${sshd_conf_dir}/ ; systemctl status ssh.socket"
        fail=1
    fi
    if [[ "$eff_pw" != "no" ]]; then
        error "Effective PasswordAuthentication is '${eff_pw}', expected 'no'."
        fail=1
    fi
    if [[ "$eff_pk" != "yes" ]]; then
        error "Effective PubkeyAuthentication is '${eff_pk}', expected 'yes'."
        fail=1
    fi
    if [[ "$eff_prl" != "prohibit-password" ]]; then
        error "Effective PermitRootLogin is '${eff_prl}', expected 'prohibit-password'."
        fail=1
    fi

    # Actual listener state (ss -tlnp): is anything really bound to our port?
    local sshd_listeners
    sshd_listeners="$(ss -tlnp 2>/dev/null | grep -i sshd || true)"
    if grep -qE ":${ssh_port}\b" <<<"$sshd_listeners"; then
        log "sshd is listening on port ${ssh_port}"
    else
        error "No sshd listener found on port ${ssh_port} (ss -tlnp)."
        fail=1
    fi
    local stray
    stray="$(grep -vE ":${ssh_port}\b" <<<"$sshd_listeners" || true)"
    if [[ -n "$stray" ]]; then
        warning "sshd also listening on another port (leftover provider config?):"
        echo "$stray"
    fi
    if (( fail )); then
        error "SSH hardening verification FAILED. Your current session stays alive,"
        error "but fix the above before disconnecting (backups: *.backup_${ts})."
        return 1
    fi
    log "sshd verified: port ${ssh_port}, key-only root (password auth disabled)"

    last_step=5
    save_state
}

# --- Step 6: nftables firewall ---
# Plain nftables (no ufw) so future port forwarding (DNAT + forward to another
# machine) is just a rule away instead of a firewall-stack migration. Only
# clikader-owned tables are managed — never 'flush ruleset', which would also
# wipe fail2ban's f2b-table while the service is running. fail2ban's nftables
# ban action hooks its own drop chain in ahead of this filter table.
step_configure_nftables() {
    step_banner 6 "Configure nftables firewall"

    # Migrate servers set up by older clikader versions that used ufw.
    if command -v ufw &>/dev/null; then
        warning "ufw is installed; migrating its rules to nftables."
        ufw --force disable 2>/dev/null || true
        apt-get purge -y ufw || true
        log "ufw disabled and removed"
    fi

    local nft_conf="/etc/nftables.conf"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    # Keep the distro-shipped file once; never back up our own generated one.
    if [[ -f "$nft_conf" ]] && ! grep -q 'Managed by clikader setup' "$nft_conf"; then
        cp "$nft_conf" "${nft_conf}.backup_${ts}"
        log "Backed up original ${nft_conf} to ${nft_conf}.backup_${ts}"
    fi

    # Port sets: SSH over tcp; extra ports get both tcp and udp (parity with
    # the old `ufw allow <port>` behavior).
    local tcp_list="${ssh_port}" udp_list="" p
    if [[ -n "$extra_ports" ]]; then
        for p in $extra_ports; do
            tcp_list+=", ${p}"
        done
        udp_list="${extra_ports// /, }"
    fi
    local udp_rule=""
    [[ -n "$udp_list" ]] && udp_rule="        udp dport { ${udp_list} } accept comment \"extra udp ports\""

    cat > "$nft_conf" <<EOF
#!/usr/sbin/nft -f
#
# Managed by clikader setup; regenerated by 'clikader setup --force'.
#
# clikader-owned tables only. The add+delete pairs make re-applying this file
# idempotent (and work on old nft versions that lack 'destroy table').
add table inet clikader_filter
delete table inet clikader_filter
add table inet clikader_nat
delete table inet clikader_nat

table inet clikader_filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state invalid drop
        ct state { established, related } accept
        ip protocol icmp accept
        meta l4proto ipv6-icmp accept
        udp sport bootps dport bootpc accept comment "DHCP client replies"

        tcp dport { ${tcp_list} } accept comment "ssh + extra tcp ports"
${udp_rule}

        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state { established, related } accept
        # Future port forwarding: permit DNAT'd traffic here, e.g.
        #   ip daddr 10.0.0.5 tcp dport 443 accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table inet clikader_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # Future port forwarding — send inbound traffic to another machine:
        #   ip daddr <this-server-ip> tcp dport 443 dnat to 10.0.0.5:443
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Future port forwarding — masquerade forwarded traffic back out:
        #   ip saddr 10.0.0.0/24 oifname "eth0" masquerade
    }
}
EOF
    log "Wrote ${nft_conf} (ssh ${ssh_port}/tcp, extra ports: ${extra_ports:-none})"

    # Validate before applying so a syntax error can't cut this session off.
    local nft_check
    if ! nft_check="$(nft -c -f "$nft_conf" 2>&1)"; then
        error "nftables ruleset failed validation; NOT applying."
        [[ -n "$nft_check" ]] && error "$nft_check"
        return 1
    fi
    log "nftables ruleset validated (nft -c)"

    systemctl enable nftables >/dev/null 2>&1
    if systemctl is-active nftables &>/dev/null; then
        systemctl restart nftables
    else
        systemctl start nftables
    fi

    # Verify the table actually loaded (service exit code alone is not proof).
    if ! nft list table inet clikader_filter &>/dev/null; then
        error "nftables service is running but clikader_filter is not loaded."
        error "Inspect: systemctl status nftables ; nft -c -f ${nft_conf}"
        return 1
    fi
    log "nftables enabled and clikader_filter loaded"
    nft list table inet clikader_filter
    last_step=6
    save_state
}

# --- Step 7: fail2ban (SSH protection) ---
# Pinned explicitly so the jail cannot silently fail:
#   * backend = systemd reads auth failures straight from the journal (no
#     logpath); journalmatch covers both unit names (Debian runs ssh.service,
#     not sshd.service — a mismatch is the classic "never bans" failure).
#   * banaction = nftables-native actions, matching the step-6 firewall;
#     fail2ban manages its own f2b-table independent of clikader_filter.
#   * port must match the custom sshd port; the default `port = ssh` token
#     resolves to 22 and would watch the wrong port.
# A test ban at the end proves the journal->jail->nftables path really works.
step_setup_fail2ban() {
    step_banner 7 "Configure fail2ban for SSH"
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Never ban localhost, even under a flood of failed attempts.
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
# Native nftables ban actions (keeps fail2ban aligned with the clikader
# firewall; it creates its own f2b-table, not clikader_filter).
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
# Debian's unit is ssh.service; sshd.service is the upstream name. The '+'
# ORs the two journal matches so either journal name is picked up.
journalmatch = _SYSTEMD_UNIT=sshd.service + _SYSTEMD_UNIT=ssh.service
EOF
    log "Wrote /etc/fail2ban/jail.local (sshd port ${ssh_port}, backend systemd, nftables bans)"

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
    fail2ban-client status sshd

    # End-to-end self-test: prove a ban actually lands in nftables.
    # 192.0.2.1 is TEST-NET-1 (RFC 5737 documentation range, never routable).
    local test_ip="192.0.2.1"
    if fail2ban-client set sshd banip "$test_ip" >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q "$test_ip"; then
            log "Self-test passed: test ban ${test_ip} appeared in the nftables ruleset"
        else
            warning "Self-test: ${test_ip} was banned but NOT found in 'nft list ruleset'."
            warning "The banaction is broken; bans would be invisible to the firewall."
        fi
        fail2ban-client set sshd unbanip "$test_ip" >/dev/null 2>&1 || true
    else
        warning "Self-test: 'fail2ban-client set sshd banip' failed; the sshd jail"
        warning "may not be running. Check: systemctl status fail2ban"
    fi
    info "Bans are logged to /var/log/fail2ban.log; live view: fail2ban-client get sshd banned"
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
        6) step_configure_nftables ;;
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
    echo "  • SSH port:     ${ssh_port} (key-only root, password auth disabled)"
    echo "  • Extra ports:  ${extra_ports:-none}"
    echo "  • fail2ban:     protecting sshd on port ${ssh_port} (nftables bans)"
    echo "  • Firewall:     nftables (input policy drop)"
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
