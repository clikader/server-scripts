#!/usr/bin/env bash
# Ongoing package maintenance. Configuration backups are retained by common.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

APT_SECURITY_CONF="${APT_SECURITY_CONF:-/etc/apt/apt.conf.d/99-clikader-security}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

usage() {
    cat <<'EOF'
Usage: clikader maintenance <command>
  enable-security-updates   Enable unattended security updates; automatic reboot OFF
  disable-security-updates  Disable unattended package installation
  upgrade                   Refresh indexes and install package upgrades (no release upgrade)
  backups                   List configuration snapshots
  prune                     Remove configuration snapshots older than 30 days
  --help                    Show help
Reboots are always manual. Use clikader doctor to check pending updates/reboots.
EOF
}

configure_security_updates() (
    local enabled="$1"
    # shellcheck source=/dev/null
    source "$OS_RELEASE"
    case "$ID/${VERSION_ID:-}" in
        debian/11|debian/12|debian/13|ubuntu/20.04|ubuntu/22.04|ubuntu/24.04|ubuntu/26.04) ;;
        *) echo "Unsupported OS for unattended updates: $ID ${VERSION_ID:-}" >&2; exit 1 ;;
    esac
    clikader_lock apt || exit 1
    if [[ "$enabled" == 1 ]]; then
        apt_refresh || exit 1
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y unattended-upgrades || exit 1
    fi
    tx_begin security-updates || exit 1
    tx_save "$APT_SECURITY_CONF" || exit 1
    mkdir -p "$(dirname "$APT_SECURITY_CONF")" || exit 1
    cat > "$APT_SECURITY_CONF" <<EOF
// Managed by clikader maintenance. Security-only; never automatically reboot.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "$enabled";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
EOF
    if [[ "$ID" == debian ]]; then
        printf 'Unattended-Upgrade::Origins-Pattern { "origin=Debian,label=Debian-Security,codename=%s-security"; };\n' "$VERSION_CODENAME" >> "$APT_SECURITY_CONF"
    else
        printf 'Unattended-Upgrade::Origins-Pattern { "origin=Ubuntu,archive=%s-security"; "origin=UbuntuESMApps,archive=%s-apps-security"; "origin=UbuntuESM,archive=%s-infra-security"; };\n' \
            "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" >> "$APT_SECURITY_CONF"
    fi
    chmod 644 "$APT_SECURITY_CONF" || exit 1
    apt-config dump >/dev/null || exit 1
    if [[ "$enabled" == 1 ]]; then
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || exit 1
    fi
    record_managed security-updates "$APT_SECURITY_CONF" || exit 1
    tx_commit
    echo "Unattended security updates: $enabled. Automatic reboots: disabled."
)

main() {
    local command="${1:---help}"
    [[ $# -le 1 ]] || { echo 'Unexpected arguments' >&2; return 2; }
    case "$command" in --help|-h|help) usage; return ;; esac
    [[ $EUID -eq 0 ]] || { echo 'This command must be run as root' >&2; return 1; }
    case "$command" in
        enable-security-updates) configure_security_updates 1 ;;
        disable-security-updates) configure_security_updates 0 ;;
        upgrade)
            clikader_lock apt || return 1
            apt_refresh || return 1
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
                -o Dpkg::Options::=--force-confold upgrade -y || return 1
            if [[ -f /var/run/reboot-required ]]; then echo 'Reboot required; schedule it manually.'; fi
            ;;
        backups)
            [[ -d "$CLIKADER_STATE_DIR/transactions" ]] || { echo 'No configuration snapshots'; return; }
            find "$CLIKADER_STATE_DIR/transactions" -mindepth 2 -maxdepth 2 -type d -print | sort
            ;;
        prune)
            [[ -d "$CLIKADER_STATE_DIR/transactions" ]] || return 0
            local dir
            while IFS= read -r dir; do
                [[ "$dir" == "$CLIKADER_STATE_DIR/transactions/"* ]] || return 1
                rm -rf -- "$dir" || return 1
            done < <(find "$CLIKADER_STATE_DIR/transactions" -mindepth 2 -maxdepth 2 -type d -mtime +30 -print)
            ;;
        *) echo "Unknown maintenance command: $command" >&2; return 2 ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
