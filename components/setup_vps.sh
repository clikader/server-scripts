#!/usr/bin/env bash

# VPS Setup Script - One-shot setup for a fresh Debian server
#
# Brings a freshly installed Debian 11/12/13 box to the clikader baseline:
# upgrade to Debian 13, prefer IPv4, install base packages, chrony, SSH
# hardening (key-only or password login), nftables, fail2ban, then run `clikader o`
# for the remaining onboarding.
#
# Survives the reboot a major-version upgrade requires: answers and progress
# are persisted to /etc/clikader/setup.state, so re-running `clikader setup`
# after the reboot resumes from where it stopped without re-prompting.
#
# Idempotent: once finished, the state file marks the server as set up and a
# plain `clikader setup` will refuse to touch it. Use --force to re-run the
# whole flow or --reset to wipe state and start over.

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

# --- Paths and constants ---
STATE_DIR="${STATE_DIR:-/etc/clikader}"
STATE_FILE="${STATE_DIR}/setup.state"
# System file paths (env-overridable so tests can target temp files; defaults unchanged)
GAI_CONF="${GAI_CONF:-/etc/gai.conf}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_CONF_DIR="${SSHD_CONF_DIR:-/etc/ssh/sshd_config.d}"
SSH_DIR="${SSH_DIR:-/root/.ssh}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-${SSH_DIR}/authorized_keys}"
NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-/etc/fail2ban/jail.d/99-clikader.local}"
BOOT_ID_FILE="${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
CLIKADER_ENTRYPOINT="${CLIKADER_ENTRYPOINT:-$(dirname "${BASH_SOURCE[0]}")/../clikader.sh}"
MAINTENANCE_SCRIPT="${MAINTENANCE_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/maintenance.sh}"
UPGRADE_APT_LIST="${UPGRADE_APT_LIST:-/etc/apt/sources.list}"
UPGRADE_APT_DIR="${UPGRADE_APT_DIR:-/etc/apt/sources.list.d}"
TARGET_DEBIAN_VERSION=13
TARGET_CODENAME="trixie"
TOTAL_STEPS=9

# Runtime state (defaults; overwritten by load_state when resuming)
ssh_port=""
ssh_auth_method=""   # "key" or "password" (how root logs in over SSH)
ssh_public_key=""
ssh_password=""
extra_ports=""
last_step=0
clikader_setup_completed=0
completed_at=""
upgrade_pending=""
upgrade_boot_id=""
upgrade_finished=0
ipv6_policy=ask
profile=proxy
# Run-mode flags (from argv)
force=0
reset=0
finish_upgrade=0
profile_explicit=0
# Ports the PREVIOUS run's state named (ssh + extra), captured in main()
# before CLI flags and prompts overwrite them. Re-runs prune exactly these
# when no longer requested; ports added later via `clikader nft add` are the
# user's and always survive a setup re-run. Empty on a first run or after
# --reset (previous values are unknowable there, so nothing is pruned).
previous_setup_ports=""
# CLI-provided inputs (from argv). When set, the interactive prompts are skipped.
cli_ssh_port=""
cli_ssh_key=""
cli_password=""
cli_extra_ports=""

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)            force=1;  shift ;;
        --keep-ipv6)         ipv6_policy=keep; shift ;;
        --disable-ipv6)      ipv6_policy=disable; shift ;;
        --profile=proxy)    profile=proxy; profile_explicit=1; shift ;;
        --profile=general)  profile=general; profile_explicit=1; shift ;;
        --finish-upgrade)   finish_upgrade=1; shift ;;
        --reset)            reset=1;  shift ;;
        --ssh-port)
            [[ $# -ge 2 ]] || { error "--ssh-port requires a value"; exit 1; }
            cli_ssh_port="$2"; shift 2 ;;
        --ssh-port=*)       cli_ssh_port="${1#*=}"; shift ;;
        --ssh-key)
            [[ $# -ge 2 ]] || { error "--ssh-key requires a value"; exit 1; }
            cli_ssh_key="$2"; shift 2 ;;
        --ssh-key=*)        cli_ssh_key="${1#*=}"; shift ;;
        --password)
            [[ $# -ge 2 ]] || { error "--password requires a value"; exit 1; }
            cli_password="$2"; shift 2 ;;
        --password=*)       cli_password="${1#*=}"; shift ;;
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
  --password <password>        Root SSH password; enables password login instead of a key
                               (mutually exclusive with --ssh-key)
  --additional-ports <ports>   Extra ports to open in nftables, comma/space separated (e.g. "36158,443")

Run modes:
  --force   Re-run the entire flow even if already completed.
  --reset   Wipe saved state and start over from scratch.
  --profile=proxy|general   Proxy defaults, or preserve DNS/APT/TCP settings.
  --keep-ipv6 / --disable-ipv6   Skip the IPv6 question with an explicit choice.
  --finish-upgrade   Acknowledge a manually repaired interrupted release upgrade.

When --ssh-port plus either --ssh-key or --password are provided, the run is
fully non-interactive. State is kept in ${STATE_FILE}; after a release-upgrade
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

# Check if running as root (after --help/-h so usage is visible to any user).
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

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
    case "$debian_major" in 11|12|13) ;; *) error "Unsupported Debian release: $debian_major"; exit 1 ;; esac
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
    chmod 700 "$STATE_DIR"
    local escaped_key escaped_password
    escaped_key="$(escape_single_quotes "$ssh_public_key")"
    escaped_password="$(escape_single_quotes "$ssh_password")"
    local temporary
    temporary="$(mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
    chmod 600 "$temporary"
    cat > "$temporary" <<EOF
# Managed by clikader setup. Do not edit by hand; use 'clikader setup --reset'.
ssh_port='${ssh_port}'
ssh_auth_method='${ssh_auth_method}'
ssh_public_key='${escaped_key}'
ssh_password='${escaped_password}'
extra_ports='${extra_ports}'
last_step=${last_step}
clikader_setup_completed=${clikader_setup_completed}
completed_at='${completed_at}'
upgrade_pending='${upgrade_pending}'
upgrade_boot_id='${upgrade_boot_id}'
upgrade_finished=${upgrade_finished}
ipv6_policy='${ipv6_policy}'
profile='${profile}'
EOF
    mv -f "$temporary" "$STATE_FILE"
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # last_step / completed flags become shell vars here; copy into our globals.
    : "${ssh_port:=}"
    : "${ssh_auth_method:=}"
    : "${ssh_public_key:=}"
    : "${ssh_password:=}"
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
    [[ ${#p} -le 5 ]] || return 1
    (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
    return 0
}

valid_ssh_pubkey() {
    # Accepts a single OpenSSH public-key line. Allows the common key types.
    # The key-type token may include a curve (ecdsa-sha2-nistp256) and/or a
    # host suffix (sk-ssh-ed25519@openssh.com), so we anchor on the prefix
    # followed by its non-space tail and then the required whitespace separator.
    local key="$1" temporary
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
    [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh\.com)[[:space:]] ]] || return 1
    temporary="$(mktemp)" || return 1
    printf '%s\n' "$key" > "$temporary"
    local rc=0
    ssh-keygen -l -f "$temporary" >/dev/null 2>&1 || rc=1
    rm -f "$temporary"
    return "$rc"
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
    local p normalized=""
    for p in $raw; do
        if ! valid_port "$p"; then
            error "Invalid port '${p}' in port list"
            return 1
        fi
        p=$((10#$p))
        [[ " $normalized " == *" $p "* ]] || normalized+=" $p"
    done
    printf '%s' "${normalized# }"
}

# Apply CLI-provided inputs, validating each. On any error, abort (these are
# explicit user flags, so we fail loud rather than fall through to prompting).
apply_cli_inputs() {
    local previous_port="$ssh_port" previous_auth="$ssh_auth_method" previous_key="$ssh_public_key" previous_extra="$extra_ports"
    if [[ -n "$cli_ssh_port" ]]; then
        if ! valid_port "$cli_ssh_port"; then
            error "--ssh-port '${cli_ssh_port}' is not a valid port (1-65535)"
            exit 1
        fi
        ssh_port=$((10#$cli_ssh_port))
    fi
    # Auth method: --ssh-key and --password are mutually exclusive.
    if [[ -n "$cli_ssh_key" && -n "$cli_password" ]]; then
        error "--ssh-key and --password are mutually exclusive; provide only one."
        exit 1
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
        ssh_auth_method="key"
        ssh_public_key="$cli_ssh_key"
        ssh_password=""
    fi
    if [[ -n "$cli_password" ]]; then
        [[ "$cli_password" != *$'\n'* && "$cli_password" != *$'\r'* ]] || { error 'Password cannot contain line breaks'; exit 1; }
        if [[ "${#cli_password}" -lt 8 ]]; then
            warning "--password is shorter than 8 characters; use a strong password."
        fi
        ssh_auth_method="password"
        ssh_password="$cli_password"
        ssh_public_key=""
    fi
    if [[ -n "$cli_extra_ports" ]]; then
        extra_ports="$(normalize_port_list "$cli_extra_ports")" || exit 1
    fi
    if [[ "$previous_port" != "$ssh_port" || "$previous_auth" != "$ssh_auth_method" || "$previous_key" != "$ssh_public_key" || -n "$cli_password" ]]; then
        (( last_step < 5 )) || last_step=4
    elif [[ "$previous_extra" != "$extra_ports" ]]; then
        (( last_step < 6 )) || last_step=5
    fi
    return 0
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

    # Authentication method: SSH key (default) or password login.
    if [[ -n "$ssh_auth_method" ]]; then
        log "SSH auth method already set: ${ssh_auth_method}"
    else
        while true; do
            echo -n "SSH login method [key/password] (default: key): "
            read -r method_choice < /dev/tty
            # Lowercase for a case-insensitive match (portable; bash 3.2 lacks ${var,,}).
            method_choice="$(printf '%s' "$method_choice" | tr '[:upper:]' '[:lower:]')"
            case "$method_choice" in
                ""|key|k)   ssh_auth_method="key"; break ;;
                password|pass|pw|p) ssh_auth_method="password"; break ;;
                *)
                    error "Please choose 'key' or 'password'."
                    ;;
            esac
        done
    fi

    echo ""

    if [[ "$ssh_auth_method" == "password" ]]; then
        # Root password — silently prompted, then confirmed.
        if [[ -n "$ssh_password" ]]; then
            log "Root password already set (hidden)."
        else
            while true; do
                echo -n "Root password for SSH login: "
                read -rs ssh_password < /dev/tty
                echo ""
                echo -n "Confirm root password: "
                read -rs confirm_password < /dev/tty
                echo ""
                if [[ -n "$ssh_password" && "$ssh_password" == "$confirm_password" ]]; then
                    if [[ "${#ssh_password}" -lt 8 ]]; then
                        warning "Password is shorter than 8 characters."
                    fi
                    break
                fi
                error "Passwords are empty or do not match; try again."
            done
        fi
    else
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
upgrade_preflight() {
    local audit source_file free
    audit="$(dpkg --audit)" || return 1
    [[ -z "$audit" ]] || { error "Repair incomplete packages first: $audit"; return 1; }
    free="$(df -Pk / | awk 'NR==2 {print $4}')" || return 1
    [[ "$free" =~ ^[0-9]+$ ]] && (( free >= 1048576 )) || { error 'At least 1GiB of free root filesystem space is required'; return 1; }
    for source_file in "$UPGRADE_APT_LIST" "$UPGRADE_APT_DIR/"*.list "$UPGRADE_APT_DIR/"*.sources; do
        [[ -f "$source_file" ]] || continue
        if grep -E '^(deb |deb-src |URIs:)' "$source_file" | grep -qvE '(deb\.debian\.org|security\.debian\.org|ftp\.[a-z.]*debian\.org)'; then
            error "Non-official source in $source_file; run clikader apt-reset or disable it before upgrading."
            return 1
        fi
        if grep -E '^(deb |deb-src |Suites:)' "$source_file" | grep -qwE 'stable|oldstable|oldoldstable|testing|unstable|sid'; then
            error "Use explicit release codenames in $source_file before upgrading."; return 1
        fi
    done
}

step_upgrade_debian() {
    step_banner 1 "Upgrade to Debian 13 (Trixie)"

    if [[ -n "$upgrade_pending" ]]; then
        if [[ "$upgrade_finished" != 1 ]]; then
            error "The upgrade to $upgrade_pending was interrupted. Run dpkg --configure -a and apt-get full-upgrade, then rerun setup with --finish-upgrade."
            return 1
        fi
        if [[ "$upgrade_boot_id" == "$(cat "$BOOT_ID_FILE")" ]]; then
            error "Reboot before continuing the upgrade to $upgrade_pending."; return 1
        fi
        [[ "$debian_codename" == "$upgrade_pending" ]] || { error "Expected $upgrade_pending after upgrade, detected $debian_codename"; return 1; }
        dpkg --audit | grep . && { error 'Incomplete package configuration; repair dpkg before continuing.'; return 1; }
        upgrade_pending=""
        upgrade_boot_id=""
    fi
    if [[ "$debian_codename" == "$TARGET_CODENAME" ]]; then
        log "Already on Debian ${TARGET_DEBIAN_VERSION} (${TARGET_CODENAME}); refreshing and applying updates."
        clikader_lock apt || return 1
        apt_refresh || return 1
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold upgrade -y || return 1
        clikader_unlock apt || return 1
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
    upgrade_preflight || return 1
    clikader_lock apt || return 1

    # First bring the current release fully up to date.
    log "Updating current system (apt update/upgrade/full-upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    apt_refresh || return 1
    apt-get -o Dpkg::Options::=--force-confold upgrade -y || return 1
    apt-get -o Dpkg::Options::=--force-confold full-upgrade -y || return 1
    apt-get --purge autoremove -y || return 1

    # Backup sources before rewriting codenames.
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local backup_dir
    backup_dir="$(dirname "$UPGRADE_APT_LIST")/sources.backup_${ts}"
    mkdir -p "$backup_dir" || return 1
    if [[ -f "$UPGRADE_APT_LIST" ]]; then cp "$UPGRADE_APT_LIST" "$backup_dir/" || return 1; fi
    if [[ -d "$UPGRADE_APT_DIR" ]]; then
        cp -r "$UPGRADE_APT_DIR/." "$backup_dir/" || return 1
    fi
    log "Backed up APT sources to ${backup_dir}"

    # Persist the in-progress hop before base-files can change os-release.
    upgrade_pending="$to"
    upgrade_boot_id="$(cat "$BOOT_ID_FILE")"
    upgrade_finished=0
    save_state
    # Rewrite codename in the validated official sources.
    log "Rewriting codename '${from}' -> '${to}' in APT sources..."
    local source_file
    for source_file in "$UPGRADE_APT_LIST" "$UPGRADE_APT_DIR/"*.list "$UPGRADE_APT_DIR/"*.sources; do
        [[ -f "$source_file" ]] || continue
        sed -i "s/${from}/${to}/g" "$source_file" || return 1
    done

    log "Running apt update against new sources..."
    apt_refresh || return 1

    log "Upgrading without pulling new packages first (safer for the first pass)..."
    apt-get -o Dpkg::Options::=--force-confold upgrade --without-new-pkgs -y || return 1

    log "Full-upgrade to ${to}..."
    apt-get -o Dpkg::Options::=--force-confold full-upgrade -y || return 1
    apt-get --purge autoremove -y || return 1

    # Record that step 1 ran, so a re-run after reboot continues from step 2.
    last_step=0
    upgrade_finished=1
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
    if grep -q '^precedence ::ffff:0:0/96  100' "$GAI_CONF" 2>/dev/null; then
        log "IPv4 preference already set in $GAI_CONF"
    else
        echo 'precedence ::ffff:0:0/96  100' >> "$GAI_CONF"
        log "Added IPv4 preference to $GAI_CONF"
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
    apt_refresh
    # Same lock patience as every other apt call, so a concurrent
    # unattended-upgrades run cannot make this step fail instantly.
    apt-get -o DPkg::Lock::Timeout=120 install -y "${pkgs[@]}"
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
step_ssh_hardening() (
    step_banner 5 "SSH hardening + authorized key"

    local sshd_config="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
    local sshd_conf_dir="${SSHD_CONF_DIR:-/etc/ssh/sshd_config.d}"
    local ts f
    ts="$(date +%Y%m%d_%H%M%S)"
    local socket_active=0 socket_enabled=0 service_enabled=0
    systemctl is-active --quiet ssh.socket && socket_active=1
    systemctl is-enabled --quiet ssh.socket && socket_enabled=1
    systemctl is-enabled --quiet ssh.service && service_enabled=1
    if [[ "$ssh_auth_method" == key ]]; then
        local key_path
        key_path="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 | awk '$1=="authorizedkeysfile" {print $2; exit}')" || exit 1
        if [[ -n "$key_path" ]]; then
            [[ "$key_path" != none ]] || { error 'AuthorizedKeysFile is disabled for root'; exit 1; }
            key_path="${key_path//%h//root}"
            key_path="${key_path//%u/root}"
            key_path="${key_path//%U/0}"
            [[ "$key_path" != *%* ]] || { error 'Unsupported AuthorizedKeysFile expansion for root'; exit 1; }
            [[ "$key_path" == /* ]] || key_path="/root/$key_path"
            AUTHORIZED_KEYS="$key_path"
        fi
    fi
    restore_ssh() {
        if (( socket_enabled )); then systemctl enable ssh.socket; fi
        if (( socket_active )); then
            systemctl stop ssh.service
            systemctl start ssh.socket || systemctl restart ssh.service
        else
            systemctl restart ssh.service
        fi
        (( service_enabled )) || systemctl disable ssh.service
        if [[ -f "$TX_DIR/root-password" ]]; then chpasswd -e < "$TX_DIR/root-password"; fi
    }
    if [[ "$ssh_auth_method" == key ]]; then
        valid_ssh_pubkey "$ssh_public_key" || { error 'Invalid SSH public key'; exit 1; }
    fi
    tx_begin ssh restore_ssh || exit 1
    tx_save "$sshd_config" "$sshd_conf_dir" "$AUTHORIZED_KEYS" || exit 1

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
    # Directives depend on the chosen auth method: key-only (default) keeps
    # PasswordAuthentication/KbdInteractiveAuthentication off and root
    # key-only; --password turns password login on for root and never
    # disables it.
    local prl pw_auth kbd
    if [[ "$ssh_auth_method" == "password" ]]; then
        prl="yes"
        pw_auth="yes"
        kbd="yes"
        log "Password login enabled for root (PermitRootLogin yes, PasswordAuthentication yes)"
    else
        prl="prohibit-password"
        pw_auth="no"
        kbd="no"
        log "Key-only login: PasswordAuthentication off, root key-only"
    fi
    sed -i '/^# --- BEGIN clikader sshd settings ---$/,/^# --- END clikader sshd settings ---$/d' "$sshd_config"
    sed -i -E "/^[[:space:]]*(${managed_keywords})[[:space:]]/d" "$sshd_config"
    {
        echo "# --- BEGIN clikader sshd settings ---"
        echo "# Managed by clikader setup; supersedes the provider defaults below"
        echo "# and in sshd_config.d/*.conf (first obtained value wins in sshd)."
        echo "Port ${ssh_port}"
        echo "PermitRootLogin ${prl}"
        echo "PasswordAuthentication ${pw_auth}"
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication ${kbd}"
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

    if [[ "$ssh_auth_method" == "password" ]]; then
        # Set the root password BEFORE enabling password auth and restarting
        # sshd, so login works the moment the listener comes up.
        getent shadow root | cut -d: -f1,2 > "$TX_DIR/root-password" || exit 1
        if ! printf 'root:%s\n' "$ssh_password" | chpasswd; then
            error "Failed to set root password (chpasswd)."
            return 1
        fi
        log "Set root password for password login"
    else
        # authorized_keys BEFORE any restart: password auth is about to be
        # turned off, so the key must already be in place or root gets locked
        # out.
        mkdir -p "$SSH_DIR"
        mkdir -p "$(dirname "$AUTHORIZED_KEYS")"
        chmod 700 "$SSH_DIR"
        touch "$AUTHORIZED_KEYS"
        chmod 600 "$AUTHORIZED_KEYS"
        chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS" || exit 1
        if [[ -n "$ssh_public_key" ]] && ! grep -qxF "$ssh_public_key" "$AUTHORIZED_KEYS"; then
            echo "$ssh_public_key" >> "$AUTHORIZED_KEYS"
            log "Added public key to $AUTHORIZED_KEYS"
        else
            log "Public key already present in $AUTHORIZED_KEYS"
        fi
    fi
    # Allow the new port in the running firewall before moving the listener.
    # The port manager preserves old listeners until the subsequent firewall step.
    if nft list table inet clikader_filter >/dev/null 2>&1 && [[ -f "$NFT_CONF" ]]; then
        bash "$(dirname "${BASH_SOURCE[0]}")/nft_manager.sh" add "$ssh_port" tcp || exit 1
    fi

    # Socket activation: while ssh.socket holds the listener, Port in
    # sshd_config is ignored. Fall back to the classic always-running daemon.
    if systemctl is-active ssh.socket &>/dev/null || systemctl is-enabled ssh.socket &>/dev/null; then
        log "ssh.socket activation is in use; Port in sshd_config would be ignored."
        log "Disabling ssh.socket, enabling ssh.service so our Port takes effect."
        systemctl disable --now ssh.socket
        systemctl enable ssh.service >/dev/null 2>&1
    fi
    systemctl restart ssh.service || exit 1

    # --- Verify: effective config AND real listener, not just exit codes. ---
    local effective eff_ports eff_pw eff_pk eff_prl eff_kbd fail=0
    local expected_pw expected_prl expected_kbd
    if [[ "$ssh_auth_method" == "password" ]]; then
        expected_pw="yes"
        expected_prl="yes"
        expected_kbd="yes"
    else
        expected_pw="no"
        expected_prl="prohibit-password"
        expected_kbd="no"
    fi
    local remote_address="${SSH_CONNECTION:-127.0.0.1}"
    effective="$(sshd -T -C "user=root,host=localhost,addr=${remote_address%% *}" 2>/dev/null)"
    eff_ports="$(awk '$1 == "port" {print $2}' <<<"$effective" | tr '\n' ' ' | sed 's/ $//')"
    eff_pw="$(awk '$1 == "passwordauthentication" {print $2}' <<<"$effective")"
    eff_pk="$(awk '$1 == "pubkeyauthentication" {print $2}' <<<"$effective")"
    eff_prl="$(awk '$1 == "permitrootlogin" {print $2}' <<<"$effective")"
    eff_kbd="$(awk '$1 == "kbdinteractiveauthentication" {print $2}' <<<"$effective")"

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
    if [[ "$eff_pw" != "$expected_pw" ]]; then
        error "Effective PasswordAuthentication is '${eff_pw}', expected '${expected_pw}'."
        fail=1
    fi
    if [[ "$eff_pk" != "yes" ]]; then
        error "Effective PubkeyAuthentication is '${eff_pk}', expected 'yes'."
        fail=1
    fi
    if [[ "$eff_kbd" != "$expected_kbd" ]]; then
        error "Effective KbdInteractiveAuthentication is '${eff_kbd:-unset}', expected '${expected_kbd}'."
        fail=1
    fi
    # sshd -T dumps PermitRootLogin spelling differs by OpenSSH version:
    # some print 'prohibit-password', older ones print 'without-password'.
    # Both are the same value — key-only root login, passwords rejected.
    # In password mode the expected value is plain 'yes' (root may use a
    # password), so no spelling-synonym dance is needed there.
    if [[ "$expected_prl" == "prohibit-password" ]]; then
        if [[ "$eff_prl" != "prohibit-password" && "$eff_prl" != "without-password" ]]; then
            error "Effective PermitRootLogin is '${eff_prl:-unset}', expected 'prohibit-password' (or 'without-password', its synonym)."
            fail=1
        fi
    elif [[ "$eff_prl" != "$expected_prl" ]]; then
        error "Effective PermitRootLogin is '${eff_prl:-unset}', expected '${expected_prl}'."
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
    if [[ "$ssh_auth_method" == "password" ]]; then
        log "sshd verified: port ${ssh_port}, root password login enabled"
    else
        log "sshd verified: port ${ssh_port}, key-only root (password auth disabled)"
    fi

    last_step=5
    save_state
    record_managed ssh "$sshd_config" "$AUTHORIZED_KEYS" || exit 1
    tx_commit
)

# Remove ports an earlier setup run opened that this run no longer requests
# (e.g. the old SSH port after --force --ssh-port <new>). Only the previous
# run's own ssh/extra ports are candidates — ports added afterwards with
# `clikader nft add` are deliberate user state and are left alone. Failures
# are loud but non-fatal: the new configuration is already applied, and the
# port manager refuses to remove an SSH port someone is still connected on.
prune_stale_setup_ports() {
    [[ -n "$previous_setup_ports" ]] || return 0
    local desired="$ssh_port${extra_ports:+ $extra_ports}"
    local p stale=""
    for p in $previous_setup_ports; do
        [[ " $desired " == *" $p "* ]] || stale+=" $p"
    done
    stale="${stale# }"
    [[ -n "$stale" ]] || return 0
    log "Pruning ports the previous setup opened but this run does not request: ${stale// /, }"
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/nft_manager.sh" delete "$stale"; then
        warning "Could not prune stale port(s) ${stale// /, } (the port manager protects"
        warning "active SSH listeners). Once disconnected from them, remove with:"
        warning "  clikader nft delete ${stale// /, }"
    fi
    return 0
}

# --- Step 6: nftables firewall ---
# INBOUND-ONLY firewall: exactly the ufw mental model — allow the ports you
# asked for, drop everything else *addressed to this host*, and never interfere
# with traffic passing through it. Plain nftables (no ufw) so future port
# forwarding (DNAT + forward to another machine) is just a rule away instead of
# a firewall-stack migration. Only clikader-owned tables are managed — never
# 'flush ruleset' (and never `systemctl restart nftables`, whose ExecStop *is*
# `nft flush ruleset`), which would also wipe fail2ban's f2b-table and Docker's
# tables while those services are running. fail2ban's nftables ban action hooks
# its own drop chain in ahead of this filter table.
step_configure_nftables() (
    step_banner 6 "Configure nftables firewall"
    if grep -qE 'table inet clikader_filter' "$NFT_CONF" 2>/dev/null; then
        bash "$(dirname "${BASH_SOURCE[0]}")/nft_manager.sh" add "$ssh_port" tcp || exit 1
        if [[ -n "$extra_ports" ]]; then
            bash "$(dirname "${BASH_SOURCE[0]}")/nft_manager.sh" add "$extra_ports" both || exit 1
        fi
        # Keep the allowlist in step with the requested parameters: ports the
        # previous run opened but this one no longer names are closed again.
        # Without this, --force with a new SSH port left the old port allowed
        # forever (nothing else ever removes it).
        prune_stale_setup_ports || exit 1
        last_step=6
        save_state
        return 0
    fi
    clikader_lock nft || exit 1
    tx_begin nft || exit 1
    tx_save "$NFT_CONF" || exit 1
    nft list table inet clikader_filter > "$TX_DIR/filter.nft" 2>/dev/null || : > "$TX_DIR/filter.nft"
    restore_firewall() {
        if [[ -s "$TX_DIR/filter.nft" ]]; then
            printf 'add table inet clikader_filter\ndelete table inet clikader_filter\n' > "$TX_DIR/restore.nft"
            cat "$TX_DIR/filter.nft" >> "$TX_DIR/restore.nft"
            nft -f "$TX_DIR/restore.nft"
        else
            nft delete table inet clikader_filter 2>/dev/null || true
        fi
    }
    # shellcheck disable=SC2034 # Consumed by the common transaction EXIT trap.
    TX_ROLLBACK=restore_firewall

    # Migrate servers set up by older clikader versions that used ufw.
    if command -v ufw &>/dev/null && ufw status | grep -q '^Status: active'; then
        warning "ufw is installed; migrating its rules to nftables."
        error 'UFW is installed. Preserve/export its rules and remove it explicitly before switching firewall ownership.'
        exit 1
    fi

    local nft_conf="${NFT_CONF:-/etc/nftables.conf}"
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
# Managed by clikader setup. A re-run (setup --force) does not regenerate
# this file: it adds the current SSH/extra ports via 'clikader nft' and
# prunes ports an earlier setup run opened but no longer requests. Ports you
# added yourself with 'clikader nft add' are never touched by a re-run.
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
        # nft grammar: every header field needs its own protocol prefix —
        # 'udp sport 67 dport 68' fails 'nft -c' with "No symbol type
        # information" at the bare second 'dport' (ports 67=bootps, 68=bootpc).
        udp sport 67 udp dport 68 accept comment "DHCP client replies"
        udp sport 547 udp dport 546 accept comment "DHCPv6 client replies"

        tcp dport { ${tcp_list} } accept comment "ssh + extra tcp ports"
${udp_rule}

        counter drop
    }

    # Forwarding is deliberately NOT filtered here. A container's outbound
    # traffic — and inbound traffic to one of its published ports — is
    # *forwarded*, so it never traverses the input chain. A drop policy on this
    # hook therefore silently breaks every container on the box while looking
    # like a hardening win (observed 2026-09-17: a watchtower container could
    # not reach its registry, and its per-bridge counters stayed at zero while
    # the host's own DNS kept working). Docker already installs its own
    # filtering for container traffic in the ip filter table (DOCKER-USER,
    # DOCKER-FORWARD, per-bridge anti-spoofing), so leaving container isolation
    # to the layer that understands it is both simpler and safer.
    chain forward {
        type filter hook forward priority filter; policy accept;
        # Add explicit drop rules here if you ever want to filter forwarded
        # traffic — but note that anything dropped here also stops containers,
        # including their replies.
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
    chmod 644 "$nft_conf"
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

    # Apply with `nft -f`, NEVER `systemctl restart nftables`. Debian's
    # nftables.service declares `ExecStop=/usr/sbin/nft flush ruleset`, so a
    # restart is a GLOBAL flush: it deletes every table in every family, not
    # just ours. Verified 2026-09-17 — one restart silently wiped Docker's
    # ip filter/ip nat rules (all container networking died, including
    # published ports) and fail2ban's inet f2b-table (every active ban gone).
    # `nft -f` is scoped to the tables this file declares.
    if ! nft -f "$nft_conf"; then
        error "Failed to apply $nft_conf"
        return 1
    fi

    # Keep the unit enabled and in sync for boot. `start` runs ExecStart
    # (`nft -f`), which is idempotent and never flushes.
    if ! systemctl is-active nftables &>/dev/null; then
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
    record_managed nft "$NFT_CONF" || exit 1
    tx_commit
)

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
step_setup_fail2ban() (
    step_banner 7 "Configure fail2ban for SSH"
    tx_begin fail2ban restore_fail2ban || exit 1
    restore_fail2ban() { systemctl restart fail2ban; }
    tx_save "$FAIL2BAN_JAIL" || exit 1
    mkdir -p "$(dirname "$FAIL2BAN_JAIL")" || exit 1
    cat > "$FAIL2BAN_JAIL" <<EOF
[sshd]
# Never ban localhost, even under a flood of failed attempts.
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
# Native nftables ban actions (keeps fail2ban aligned with the clikader
# firewall; it creates its own f2b-table, not clikader_filter).
banaction = nftables-multiport
banaction_allports = nftables-allports

enabled = true
port = ${ssh_port}
backend = systemd
# Debian's unit is ssh.service; sshd.service is the upstream name. The '+'
# ORs the two journal matches so either journal name is picked up.
journalmatch = _SYSTEMD_UNIT=sshd.service + _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF
    chmod 644 "$FAIL2BAN_JAIL"
    log "Wrote $FAIL2BAN_JAIL (sshd port ${ssh_port}, backend systemd, nftables bans)"

    # Validate config before touching the running service.
    if ! fail2ban-client -t >/dev/null 2>&1; then
        error "fail2ban config test failed; NOT restarting the service."
        error "Inspect $FAIL2BAN_JAIL before continuing."
        return 1
    fi
    log "fail2ban config test passed"

    systemctl enable --now fail2ban
    sleep 2
    # Restart just this jail when its action changes. A plain reload on
    # fail2ban 1.1 can remove both the old and new action, leaving a running
    # jail that records bans but has "No actions" (caught by integration).
    fail2ban-client reload --restart sshd || return 1
    sleep 2
    fail2ban-client status sshd

    # End-to-end self-test: prove a ban actually lands in nftables.
    # 192.0.2.1 is TEST-NET-1 (RFC 5737 documentation range, never routable).
    local test_ip="192.0.2.1"
    if fail2ban-client set sshd banip "$test_ip" >/dev/null 2>&1; then
        local _attempt ban_visible=0
        for _attempt in 1 2 3 4 5 6 7 8 9 10; do
            if nft list table inet f2b-table 2>/dev/null | grep -qF "$test_ip"; then ban_visible=1; break; fi
            sleep 0.2
        done
        if (( ban_visible )); then
            log "Self-test passed: test ban ${test_ip} appeared in the nftables ruleset"
        else
            fail2ban-client set sshd unbanip "$test_ip" >/dev/null 2>&1 || true
            nft list ruleset >&2 || true
            fail2ban-client get sshd actions >&2 || true
            tail -20 /var/log/fail2ban.log >&2 || true
            error "Test ban ${test_ip} is missing from nftables"; exit 1
        fi
        fail2ban-client set sshd unbanip "$test_ip" >/dev/null 2>&1 || true
    else
        error 'fail2ban test ban failed'; exit 1
    fi
    verify_ssh_journal || exit 1
    info "Bans are logged to /var/log/fail2ban.log; live view: fail2ban-client get sshd banned"
    last_step=7
    save_state
    record_managed fail2ban "$FAIL2BAN_JAIL" || exit 1
    tx_commit
)

verify_ssh_journal() {
    local since probe log_file
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    probe="clikader-probe-$$"
    log_file="$(mktemp)" || return 1
    # Trigger a genuine SSH failure from localhost, which ignoreip prevents
    # from banning the management connection. Inspect the same journal scope
    # as the jail and prove the shipped filter recognizes the actual event.
    ssh -F /dev/null -o BatchMode=yes -o PreferredAuthentications=none \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        -p "$ssh_port" "$probe@127.0.0.1" true >/dev/null 2>&1 || true
    sleep 2
    journalctl --since "$since" -o short-iso --no-pager \
        _SYSTEMD_UNIT=sshd.service + _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session \
        | grep -F "$probe" > "$log_file" || { rm -f "$log_file"; error 'SSH failures did not appear in the jail journal scope'; return 1; }
    local report
    report="$(fail2ban-regex "$log_file" /etc/fail2ban/filter.d/sshd.conf 2>&1)" || { rm -f "$log_file"; return 1; }
    rm -f "$log_file"
    grep -qE '[1-9][0-9]* matched' <<< "$report" || { error 'SSH journal messages did not match the fail2ban filter'; printf '%s\n' "$report" >&2; return 1; }
}

# --- Step 8: Run `clikader o` for the rest of onboarding ---
step_run_onboard() {
    step_banner 8 "Run clikader onboarding (clikader o)"
    bash "$CLIKADER_ENTRYPOINT" o "--profile=$profile" "--${ipv6_policy}-ipv6" || return 1
    last_step=8
    save_state
}

step_security_updates() {
    step_banner 9 'Enable unattended security updates (manual reboot)'
    bash "$MAINTENANCE_SCRIPT" enable-security-updates || return 1
    last_step=9
    save_state
}

# --- Run a step by number, if not already completed ---
run_step_if_needed() {
    local num="$1"
    if [[ "$num" == 1 && ( "$debian_codename" != "$TARGET_CODENAME" || -n "$upgrade_pending" ) ]]; then
        step_upgrade_debian
        return $?
    fi
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
        9) step_security_updates ;;
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
    # Refuse conflicting firewall ownership before moving the SSH listener.
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        error 'UFW is active. Migrate or disable it explicitly before running setup.'
        exit 1
    fi
    clikader_lock setup || exit 1
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

    local requested_ipv6="$ipv6_policy" requested_profile="$profile"
    load_state || true
    previous_setup_ports="$ssh_port${extra_ports:+ $extra_ports}"
    [[ "$requested_ipv6" == ask ]] || ipv6_policy="$requested_ipv6"
    # Profile flags override state; absent flags preserve the saved profile.
    if (( profile_explicit )); then profile="$requested_profile"; fi
    if (( finish_upgrade )); then
        [[ -n "$upgrade_pending" && "$debian_codename" == "$upgrade_pending" ]] || { error 'OS does not match the pending upgrade'; exit 1; }
        [[ -z "$(dpkg --audit)" ]] || { error 'dpkg still reports incomplete packages'; exit 1; }
        apt-get check || exit 1
        upgrade_finished=1
        save_state
    fi

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
    ipv6_policy="$(choose_ipv6 "$ipv6_policy")" || exit 1

    # Resolve setup parameters. Precedence: CLI flags > saved state > prompt.
    # CLI flags win so an explicit `--ssh-port`/`--ssh-key` always applies.
    local had_cli=0
    if [[ -n "$cli_ssh_port" || -n "$cli_ssh_key" || -n "$cli_password" || -n "$cli_extra_ports" ]]; then
        apply_cli_inputs
        had_cli=1
    fi

    # After applying CLI inputs, prompt for anything still missing. For the
    # auth method we also need the matching credential: a key for key mode,
    # a password for password mode.
    local needs_prompt=0
    [[ -z "$ssh_port" ]] && needs_prompt=1
    [[ -z "$ssh_auth_method" ]] && needs_prompt=1
    if [[ "$ssh_auth_method" == "password" && -z "$ssh_password" ]]; then
        needs_prompt=1
    fi
    if [[ "$ssh_auth_method" == "key" && -z "$ssh_public_key" ]]; then
        needs_prompt=1
    fi

    if (( needs_prompt )); then
        if (( had_cli )); then
            info "Some parameters not provided via flags; prompting for the rest."
        elif (( last_step > 0 )); then
            warning "Saved parameters are incomplete; re-prompting for inputs."
        fi
        collect_inputs
    else
        info "Using parameters: ssh_port=${ssh_port}, auth=${ssh_auth_method}, extra_ports='${extra_ports:-none}'."
        # Persist CLI-provided inputs so a later reboot/resume never re-prompts.
        (( had_cli )) && save_state
    fi

    # Run steps 1..8, skipping any already completed. Step 1 may exit for a reboot.
    local step
    for step in $(seq 1 $TOTAL_STEPS); do
        run_step_if_needed "$step"
        load_state || true
    done

    # All done: mark complete.
    clikader_setup_completed=1
    last_step=9
    ssh_password=""
    completed_at="$(date -Iseconds 2>/dev/null || date)"
    save_state

    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   VPS setup complete!                   ${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    info "Summary:"
    echo "  • OS:           Debian ${debian_major} (${debian_codename})"
    if [[ "$ssh_auth_method" == "password" ]]; then
        echo "  • SSH port:     ${ssh_port} (root password login enabled)"
    else
        echo "  • SSH port:     ${ssh_port} (key-only root, password auth disabled)"
    fi
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

# Run only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
