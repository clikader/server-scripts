# Server Scripts

A collection of shell scripts for managing Debian and Ubuntu servers.

## 🚀 Quick Start

```bash
# Install CLiKader
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash

# Show available tools
clikader --help
```

**That's it!** CLiKader is now installed and ready to use.

**Features:**
- ✅ Simple installation with one command
- ✅ Direct sub-command usage (`clikader dns`, `clikader hostname`, etc.)
- ✅ Easy updates with built-in update command
- ✅ Run from anywhere with `clikader`
- ✅ Version tracking

The installer resolves a Git commit once and installs the complete toolbox under
`/usr/local/lib/clikader/releases/`. The command points at the active bundle;
component commands work without contacting GitHub. A failed update keeps the
previous bundle usable. `clikader update --rollback` switches back offline.

Existing single-file installations should run the Quick Start installer once to
migrate to the bundled layout. After migration, use `clikader update` normally.

---

## 📜 Available Tools

### **clikader.sh** - Sub-command Entry Point
Master entrypoint with direct sub-commands for all server management tasks.

**Features:**
- Direct command execution with aliases
- Built-in update command with version checking
- Complete, revision-pinned installation with atomic bundle updates
- Color-coded interface

**Commands:**
- `clikader --help` / `clikader help` / `clikader`
- `clikader update` / `clikader upgrade`
- `clikader setup` / `clikader vpssetup`
- `clikader onboard` / `clikader o`
- `clikader dns`
- `clikader tcp`
- `clikader nft` / `clikader nftables`
- `clikader apt-reset` / `clikader aptreset`
- `clikader hostname`
- `clikader ipv6` / `clikader 6`
- `clikader doctor` / `clikader status` (also `--json`)
- `clikader maintenance --help`

---

## 🛠️ Component Scripts

All component scripts are in the `components/` folder and accessed through `clikader.sh`.

### 1. VPS Setup (`setup` / `vpssetup`)
One-shot setup for a freshly installed Debian server. Runs the full baseline:

1. Upgrade to Debian 13 (Trixie) — one release hop at a time, with a reboot in between
2. Prefer IPv4 (`/etc/gai.conf`)
3. Install base packages (`nano curl wget unzip fail2ban sudo python3-systemd cron chrony dnsutils jq nftables`)
4. Enable chrony for NTP time sync
5. SSH hardening — custom port, and either key-only auth (default: `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, your public key) or password login (`--password`: `PermitRootLogin yes`, `PasswordAuthentication yes`, `KbdInteractiveAuthentication yes`, root password set); neutralizes provider overrides in `sshd_config.d/*.conf` and `ssh.socket`, then verifies the effective config and the real listener
6. Configure nftables — **inbound-only**: allow the SSH port + custom ports, drop everything else *addressed to this host*. Forwarded traffic (containers) is never filtered — a `forward` drop policy silently breaks every container, since container traffic never traverses the input chain — and output is never filtered
7. Configure fail2ban to protect sshd (systemd journal backend, nftables bans, verified with a test ban)
8. Run onboarding (profile-dependent DNS, TCP and APT; IPv6 policy; hostname)
9. Enable unattended **security-only** updates, with automatic reboots disabled

The default `--profile=proxy` retains public DNS, relay-oriented TCP tuning and
official APT sources. `--profile=general` preserves provider DNS, repository
configuration and existing TCP/routing settings. Both profiles configure SSH,
the host firewall, fail2ban, time synchronization and security updates.

Before networking changes, setup asks whether to **keep IPv6** only when a usable
global IPv6 address is present. The default answer is **no**. Without a global
address it disables IPv6 without asking. Use `--keep-ipv6` or `--disable-ipv6` for
automation; the choice is saved across upgrade reboots. Link-local, tentative,
deprecated and duplicate-address-failed addresses do not trigger the question.

Prompts for the SSH port, the login method (SSH key or password), and any extra ports
to open — or pass them as flags for a fully non-interactive run. Survives the
release-upgrade reboot: answers and progress are saved to `/etc/clikader/setup.state`,
so re-running `clikader setup` after the reboot resumes from where it stopped.

**Parameters** (omit any to be prompted for it interactively):
- `--ssh-port <port>` — SSH port to configure (1-65535)
- `--ssh-key <key>` — public key line for root (e.g. `"ssh-ed25519 AAAA... me@host"`) — key-only login
- `--password <password>` — root SSH password; enables password login instead of a key (mutually exclusive with `--ssh-key`)
- `--additional-ports <ports>` — extra ports to open in nftables, comma/space separated (e.g. `36158,443`)
- `--profile=proxy|general` — select the onboarding policy (default: proxy)
- `--keep-ipv6` / `--disable-ipv6` — explicitly choose the IPv6 policy
- `--finish-upgrade` — acknowledge an interrupted release upgrade after repairing
  packages with `dpkg --configure -a` and `apt-get full-upgrade`

Release upgrades use one codename hop per reboot. The saved boot ID prevents
continuing in the same boot; interrupted upgrades require explicit repair.
Third-party or floating-suite APT sources must be resolved before a major upgrade.
Changing SSH parameters during resume invalidates the dependent SSH/firewall steps.
On Debian 13, setup refreshes package indexes and applies package updates too.

**Idempotency:** once finished, the server is marked set up and a plain `clikader setup`
will refuse to run again. Use `--force` to re-run the whole flow or `--reset` to wipe
state and start over. On a re-run with different parameters, the firewall step adds the
new SSH/extra ports and **prunes ports the previous setup run opened but this one no
longer requests** (e.g. the old SSH port after changing `--ssh-port`). Ports you added
yourself with `clikader nft add` are never pruned; after `--reset` the previous values
are unknown, so nothing is pruned.

```bash
# Interactive (prompts for everything)
sudo clikader setup

# Fully non-interactive — key login
sudo clikader setup --ssh-port 14419 --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" --additional-ports 36158,443 --disable-ipv6

# Fully non-interactive — password login (sets the root password, enables password auth)
sudo clikader setup --ssh-port 14419 --password "S3curePassw0rd!" --additional-ports 36158,443 --disable-ipv6

# After the upgrade reboot (auto-resumes from where it stopped)
sudo clikader setup

sudo clikader setup --force    # re-run on an already-configured server
sudo clikader setup --reset    # wipe state and start fresh
```

**Files modified by this script:**
- `/etc/apt/sources.list` and `/etc/apt/sources.list.d/*` (codename rewrite during upgrade)
- `/etc/gai.conf` (IPv4 preference)
- `/etc/ssh/sshd_config` (Port, PermitRootLogin, PasswordAuthentication, PubkeyAuthentication, KbdInteractiveAuthentication) + `.backup_<timestamp>`
- `/etc/ssh/sshd_config.d/*.conf` (provider overrides commented out, each with its own backup)
- `/root/.ssh/authorized_keys` (your public key in key mode; untouched in password mode)
- root account password (set via `chpasswd` in password mode)
- `/etc/nftables.conf` (clikader-owned `clikader_filter`/`clikader_nat` tables) + `.backup_<timestamp>`
- `/etc/fail2ban/jail.d/99-clikader.local` (existing jails are preserved)
- `/etc/apt/apt.conf.d/99-clikader-security`
- `/etc/clikader/setup.state` (saved answers + progress)

---

### 2. Reset APT Sources
Resets APT sources to official repositories for Debian and Ubuntu systems.

**Supported Systems:**
- Debian 13 (Trixie), 12 (Bookworm), 11 (Bullseye)
- Ubuntu 26.04 LTS, 24.04 LTS, 22.04 LTS, 20.04 LTS
- Ubuntu ARM64 and other ports architectures use `ports.ubuntu.com`

**Features:**
- Automatic backup of existing sources
- Supports both traditional `.list` and modern DEB822 `.sources` formats
- Replaces active third-party `.list` / `.sources` files; preserves inactive backups, keys and official Ubuntu Pro/ESM feeds
- Removes third-party APT pins in `/etc/apt/preferences.d` (a pin referencing a removed repo silently holds packages — including security updates — at stale versions); official-origin, current-suite and version pins are kept
- Rejects unsupported releases/architectures before cleanup
- Authenticates repository metadata and restores previous sources on update failure
- `--help` is read-only; unknown arguments are rejected

**Files modified by this script:**
- `/etc/apt/sources.list`
- `/etc/apt/sources.list.d/ubuntu.sources` (supported Ubuntu LTS releases)
- `/etc/apt/sources.list.d/*` (replaces active `*.list` and `*.sources`)
- `/etc/apt/preferences.d/*` (removes third-party pin files)
- `/var/lib/clikader/transactions/apt/` (configuration snapshots)

---

### 3. Setup DNS
Configures DNS using systemd-resolved. Officially supports Debian 12/13, Ubuntu 22.04/24.04/26 (other OS versions may work but are user-tested).

**Two resolver modes:**

- **Forward (default)** — systemd-resolved forwards to the selected resolvers. **Providers:** Cloudflare, Google, Quad9, Alibaba (223.5.5.5/223.6.6.6, DoT `dns.alidns.com`), DNSPod (119.29.29.29/119.28.28.28, DoT `dot.pub`), Custom — famous, non-filtering resolvers only (filtering resolvers like AdGuard/OpenDNS are deliberately excluded; the two China-optimized anycast providers were added 2026-09-18 for CN-adjacent boxes where their POPs win the latency race; use Custom DNS for anything else)
- **Recursive (`--recursive`)** — a local **unbound** resolver queries the authoritative nameservers directly (root → TLD → zone). No public resolver cache exists in the path, so a stale negative answer at one public resolver cannot block anything — this is the structural fix for ACME DNS-01 (1Panel/lego, certbot, acme.sh) propagation hangs. unbound also performs full DNSSEC validation and runs with `cache-max-negative-ttl: 0`. **Requires an unfiltered authoritative DNS path:** many hosting networks filter outbound port 53 to the root, TLD or authoritative servers, which makes recursion impossible. unbound still starts and reports `active` while answering nothing, so the script performs a real iterative lookup (root → TLD → authoritative) first and **refuses to continue** if it cannot complete one, rather than leave the box without DNS. Note that `FallbackDNS` does *not* rescue recursive mode: systemd-resolved consults it only when no DNS server is configured at all, and recursive mode sets `DNS=127.0.0.1`. Onboarding support: `clikader onboard --recursive`; switch an existing box with `clikader dns --yes --recursive`

**Azure VMs — Azure DNS is the default (168.63.129.16):**
- Azure VMs are auto-detected via the Azure Instance Metadata Service (`169.254.169.254`, requires the `Metadata: true` request only Azure's fabric serves), with a DMI fallback (vendor `Microsoft Corporation` + product `Virtual Machine`) for networks that filter link-local; because Hyper-V guests at *other* providers report identical DMI strings, a DMI-only match additionally requires the fabric VIP to answer one real DNS query — so the Azure option is never shown, recommended, or defaulted on a non-Azure machine, in any code path
- The Azure DNS virtual IP is the **only** resolver that answers VNET-internal names — private endpoints / Private Link zones, internal load balancers, peered-VNET names. Every public resolver (and a local unbound recursor) returns NXDOMAIN for them, which is why the VIP becomes the default on Azure
- Applies to `clikader setup` / `clikader onboard` (`--yes`) and to the interactive default; the entry appears as menu slot 1, marked *recommended*. To use public resolvers instead, re-run `clikader dns` and pick them — the script warns that VNET-internal names will stop resolving. `--recursive` on an Azure VM warns for the same reason
- If the VIP does not answer its probe on a confirmed Azure VM (blocked or transiently down fabric resolver), a `--yes` run falls back to the public auto-pick with a loud warning instead of aborting
- The fabric VIP offers no DoT and no IPv6; a secure-DNS selection that includes it downgrades that run to plain DNS

**Features:**
- Defaults to plain direct-IP DNS
- Optional strict, certificate-validated DNS-over-TLS (DoT) and DNSSEC validation (forward mode)
- IPv6 support (optional)
- **Auto mode (default off Azure):** probes all providers in parallel, orders by latency, and drops unresponsive ones — ideal when regional latency varies. On Azure VMs the default is Azure DNS instead (see above); explicit `auto` still probes everything, including the Azure entry
- Manually select specific providers if preferred
- Both anycast IPs of each selected provider are configured (e.g. `1.1.1.1` + `1.0.0.1`), queried in order as primary servers; servers that time out are rotated away from automatically (note: a server that *answers* wrongly — stale empty answer — is trusted by systemd-resolved; no negative cross-checking exists upstream of a local recursive resolver)
- Static `FallbackDNS` is used only when no DNS server is configured; it does **not** rescue unreachable configured servers
- **Negative caching disabled** (`Cache=no-negative`, or `Cache=no` on systemd < 250): a cached stale NODATA answer pins ACME DNS-01 challenges (1Panel/lego, certbot, acme.sh) for the zone's SOA minimum — 30 minutes on Cloudflare zones — and hangs certificate issuance. The setting is also pinned in a drop-in so hand-edits of `resolved.conf` can't revert it
- Clears per-link DNS servers (installed by systemd-networkd/NetworkManager DHCP), which would otherwise override the managed global `DNS=` for that link's traffic; `clikader doctor` reports them as drift if DHCP re-adds them later. On images without dhclient the health check treats the missing `dhclient.conf` as nothing-to-guard instead of "unhealthy"
- Automatic conflict resolution
- Refuses forward-mode cutover if all provider probes fail
- Restores configuration and service state after failed cutover or resolution verification
- Recursive mode requires a DNSSEC trust anchor and disables aggressive NSEC synthesis

**Files modified by this script:**
- `/etc/systemd/resolved.conf`
- `/etc/systemd/resolved.conf.d/10-setup-dns-cache.conf` (pins the `Cache=` setting)
- `/etc/systemd/resolved.conf.d/zz-clikader-dns.conf` (authoritative managed settings)
- `/etc/resolv.conf` (re-created as symlink to systemd-resolved stub)
- `/etc/dhcp/dhclient.conf`
- `/etc/network/if-up.d/resolved` (removes execute permission when present)
- `/etc/unbound/unbound.conf` (recursive mode only; full managed overwrite)

---

### 4. Fix Hostname
Fixes hostname resolution issues and allows changing the system hostname.

**Common VPS Issue:**
```
sudo: unable to resolve host your-hostname
```

**Features:**
- Detects hostname resolution issues
- Fix hostname resolution (add to `/etc/hosts`)
- Change system hostname with RFC 1123 validation
- Automatic backup of `/etc/hosts`

**Files modified by this script:**
- System hostname configuration (via `hostnamectl`; fallback writes `/etc/hostname`)
- `/etc/hosts`
- `/var/lib/clikader/transactions/hostname/` (configuration snapshots)

Hosts-file edits preserve `localhost` and unrelated aliases. Failed hostname
verification restores the previous files and runtime hostname.

---

### 5. Configure IPv6
Enable or disable IPv6 on Debian/Ubuntu systems, or manually configure IPv6 addresses.

**Features:**
- Check current IPv6 status
- Enable/disable IPv6 system-wide
- **Configure IPv6 address manually** (for VPS providers that require it)
- **Safety check**: Detects existing IPv6 configuration before changes
- **Add multiple addresses**: Support for adding additional addresses from allocated prefix
- Persistent configuration across reboots
- Automatic verification and connectivity testing

**Files modified by this script:**
- `/etc/sysctl.d/zz-clikader-ipv6.conf` (persistent enable/disable policy)
- `/etc/sysctl.conf` (conflicting IPv6 policy entries are tagged and commented)
- `/etc/network/interfaces` (only when interface-based persistent config is selected)
- Native network configuration: Netplan overlays, networkd drop-ins, or the active NetworkManager connection
- `/var/lib/clikader/transactions/ipv6*/` (configuration snapshots)

**What it does:**
- **Enable:** Persists an enabled policy without restarting IPv4 networking
- **Disable:** Creates `/etc/sysctl.d/zz-clikader-ipv6.conf` with persistent disable settings
- **Configure Address:** 
  - Preserves existing IPv6 addresses
  - Allows adding addresses from your allocated prefix (e.g., `2001:db8::/48`)
  - Supports CIDR notation like `2001:db8::1/64`
  - Keeps existing addresses (adds, doesn't replace)

**Supports multiple network configuration systems:**
- `/etc/network/interfaces` (Debian/Ubuntu)
- Netplan (Ubuntu 18.04+)
- NetworkManager
- systemd-networkd, including provider-generated network files

```bash
sudo clikader ipv6 --address 2001:db8::2/64 --interface eth0 --gateway fe80::1
```

The gateway is optional; omit it to preserve routing. Netplan IDs are inferred
from the active backend; `--netplan-id` handles custom IDs. Unsupported network
managers are rejected before applying temporary-only addresses. Address additions
are verified after duplicate-address detection and persisted for reboot.

---

### 6. NFTables Port Manager (`nft` / `nftables`)
Manage the inbound TCP/UDP allowlist in the clikader-managed `/etc/nftables.conf`
without hand-editing the ruleset. Only the unambiguous allow rules inside
`table inet clikader_filter` → `chain input` are touched
(`tcp dport { ... } accept comment "ssh + extra tcp ports"` and its UDP
counterpart); forward/nat chains and any user additions are left intact. Every
change is validated with `nft -c` before reloading, and a configuration snapshot
is kept. Only the managed filter table is applied with `nft -f` — never
`systemctl restart nftables`, because Debian's unit declares
`ExecStop=/usr/sbin/nft flush ruleset`, making a restart a **global** flush that
also deletes Docker's `ip filter`/`ip nat` rules (killing all container
networking) and fail2ban's `inet f2b-table` (dropping every active ban).

The firewall itself is **inbound-only** — the same mental model as `ufw allow
<port>`: the `input` hook drops anything not explicitly allowed, while
`forward` and `output` are left accepting. Filtering forwarding would break
Docker containers, whose traffic is routed rather than addressed to the host;
Docker's own `DOCKER-USER`/`DOCKER-FORWARD` chains handle container isolation.
Note that this also means a container's *published* ports are reachable
directly, exactly as `docker run -p` implies — bind a published port to
`127.0.0.1` if you want to keep it behind the host firewall.

**Sub-commands:**
- `clikader nft` — interactive numbered menu (add / delete / reset)
- `clikader nft list` / `clikader nft ls` — show the currently allowed inbound ports (tcp/udp), without the full ruleset detail of `nft list ruleset`
- `clikader nft add <ports> [type]` — allow inbound `<ports>` (comma/space separated, spaces around commas are trimmed); `[type]` is `tcp`, `udp` or `both` (default: both)
- `clikader nft delete <ports>` — remove `<ports>` from the allowlist (both tcp and udp); the SSH port is protected and skipped (if mixed with other ports, the others are still deleted and a warning is shown)
- `clikader nft reset [-y]` — clear the allowlist except the SSH port (grabbed from the effective sshd config); `-y` skips the confirmation prompt

All effective SSH ports, live sshd listeners, ssh.socket listeners and the current
SSH connection port are protected. The manager refuses to guess if it cannot
identify SSH ports. Host firewall checks cannot verify a provider's external
firewall or security-group rules.

```bash
sudo clikader nft                          # interactive menu
sudo clikader nft list                     # show currently allowed inbound ports
sudo clikader nft add 8080                 # allow TCP+UDP inbound on 8080
sudo clikader nft add 8080, 8443 tcp       # allow TCP inbound on 8080 and 8443
sudo clikader nft delete 8080,8443         # remove 8080 and 8443
sudo clikader nft reset                    # remove all non-SSH allowed ports
sudo clikader nft reset -y                 # same, without confirmation
```

**Files modified by this script:**
- `/etc/nftables.conf` (managed input allow rules only)
- `/var/lib/clikader/transactions/nft/` (persistent and live-table snapshots)

### 7. TCP / relay tuning

`clikader tcp` applies the proxy workload profile. `--dry-run` is read-only;
`--status` displays current settings. Unsupported kernel keys are skipped, but a
supported setting that fails verification makes the operation fail and roll back.
`--revert` removes owned settings while preserving later unrelated administrator
edits, and continues its cleanup even if one step (e.g. a busy swapoff) fails,
reporting the incomplete revert in its exit status. `--initcwnd` discovers current
routes when applying its persistent hooks. `--swap 2G` is optional; a failed
`swapoff` preserves the swapfile and fstab entry. When conntrack is in use, the
tuned hash size is applied live **and** persisted to
`/etc/modprobe.d/clikader-tcp-conntrack.conf` so a reboot does not restore the
default; `--revert` removes the file.

### 8. Health and maintenance

```bash
sudo clikader doctor
sudo clikader doctor --json
sudo clikader maintenance enable-security-updates
sudo clikader maintenance disable-security-updates
sudo clikader maintenance upgrade
sudo clikader maintenance upgrade --without-new-pkgs
sudo clikader maintenance backups
sudo clikader maintenance prune
```

Doctor is read-only. It checks failed services, real SSH listeners, DNS, managed
firewall policy, fail2ban, configuration hashes, live TCP settings, disk/inode and
memory pressure, pending package upgrades and reboots, and security-update policy.
It also cross-checks the three port sources against each other: every effective
sshd port must have a listener, be in the persisted firewall allowlist (ranges
in hand-edited rules count), and be watched by the fail2ban jail — a hand-edited
sshd port with a stale firewall or jail entry is exactly the drift it catches.
Per-link DNS servers shadowing the managed resolver are reported as drift.
Exit codes: `0` healthy, `1` warnings/failures, `2` usage/dependency error. Package
availability uses existing APT indexes; doctor does not refresh or install packages.

Security updates are automatic after setup, but reboots are always manual. The
manual `maintenance upgrade` command refreshes indexes and upgrades packages
without initiating a distribution upgrade; by default it also installs new
packages an upgrade requires (`--with-new-pkgs`), because fresh kernels are new
packages and would otherwise be held back forever while doctor keeps asking for
a reboot. Pass `--without-new-pkgs` for plain `apt-get upgrade` semantics.

Configuration transactions live in `/var/lib/clikader/transactions/`; ownership
hashes live in `/var/lib/clikader/managed/`. Failed configuration changes restore
their files and supported runtime state. The newest five committed snapshots per
component are retained; `maintenance prune` removes snapshots older than 30 days.
These are configuration snapshots, not application-data or full-server backups.
OS/package upgrades cannot be undone by a configuration snapshot.

---

## 🔧 Requirements

- **OS**: Debian 11/12/13 or Ubuntu 20.04/22.04/24.04/26.04 (full VPS setup is Debian-only)
- **Privileges**: Root access (sudo)
- **Network**: Internet for installation, updates and package operations; installed components run offline
- **Shell runtime**: `bash` (scripts can be launched from `bash`, `zsh`, or `fish` as long as Bash is installed)

---

## 📥 Installation

See [Quick Start](#-quick-start) above for installation instructions.

**What the installer does:**
1. Resolves `main` to one immutable Git commit and downloads that bundle
2. Validates required components and Bash syntax
3. Installs the complete bundle under `/usr/local/lib/clikader/releases/`
4. Atomically switches the active bundle and `/usr/local/bin/clikader` symlink

To install a local checkout: `sudo bash install.sh --from "$PWD"`.

After installation, you can run `clikader` from anywhere on your system.

---

## 🔄 Updating

CLiKader has a built-in update feature with version checking.

```bash
# Run update command directly
sudo clikader update

# It will:
#   - Check your current version
#   - Check the latest version on GitHub
#   - Offer to update if a new version is available
#   - Create a backup before updating
```

Updates compare bundle revisions. `sudo clikader update --yes` is non-interactive;
`sudo clikader update --rollback` restores the previous installed bundle offline.

---

##🛡️ Safety Features

**All scripts include:**
- Automatic backups before changes
- Configuration validation
- Clear status reporting
- Error handling

**Specific safeguards:**
- **APT Reset**: Timestamped snapshots in `/var/lib/clikader/transactions/apt/`
- **DNS Setup**: Health checks before modifications
- **Hostname**: Validates hostname format (RFC 1123)
- **IPv6**: Confirmation prompt before disabling

---

## 🧑‍💻 Development

```bash
just test         # Hermetic unit tests and real CLI failure-path regressions
just coverage     # kcov line coverage, 80% gate
just integration  # Disposable Linux/systemd container with real services
```

Integration checks exercise actual OpenSSH authentication, nftables application,
fail2ban's journal/filter/ban path, Netplan generation and unattended-update
configuration. The integration container is privileged and is removed on exit.

### Git hooks (keeping `clikader.sh` executable)

`clikader.sh` is the entrypoint and must keep its executable bit (`0755`). Some editors/tools reset it to `0644` on save, which would silently land in commits. A `pre-commit` hook in `.githooks/` auto-restores `+x` when a staged `clikader.sh` is detected as non-executable.

After cloning, enable it once:

```bash
git config core.hooksPath .githooks
```

---

## 📝 License

Apache License 2.0. See [LICENSE](./LICENSE) for full terms.

## ⚠️ Disclaimer

These scripts modify system configuration. While they include safety features like backups, always:
- Test in a non-production environment first
- Ensure you have backups of critical data
- Review the scripts before running them
