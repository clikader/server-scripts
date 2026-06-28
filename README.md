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

**Note:** All component scripts are downloaded automatically from GitHub when needed.

---

## 📜 Available Tools

### **clikader.sh** - Sub-command Entry Point
Master entrypoint with direct sub-commands for all server management tasks.

**Features:**
- Direct command execution with aliases
- Built-in update command with version checking
- Automatically downloads component scripts from GitHub if not found locally
- Color-coded interface

**Commands:**
- `clikader --help` / `clikader help` / `clikader`
- `clikader update` / `clikader upgrade`
- `clikader dns`
- `clikader apt-reset` / `clikader aptreset`
- `clikader hostname`
- `clikader ipv6` / `clikader 6`

---

## 🛠️ Component Scripts

All component scripts are in the `components/` folder and accessed through `clikader.sh`.

### 1. Reset APT Sources
Resets APT sources to official repositories for Debian and Ubuntu systems.

**Supported Systems:**
- Debian 13 (Trixie), 12 (Bookworm), 11 (Bullseye)
- Ubuntu 24.10, 24.04 LTS, 22.04 LTS, 20.04 LTS

**Features:**
- Automatic backup of existing sources
- Supports both traditional `.list` and modern DEB822 `.sources` formats
- Cleans all third-party sources (`.list`, `.sources`, `.gpg`, backups)
- Updates and verifies APT cache

**Files modified by this script:**
- `/etc/apt/sources.list`
- `/etc/apt/sources.list.d/ubuntu.sources` (Ubuntu 24.04/24.10 DEB822 mode)
- `/etc/apt/sources.list.d/*` (removes third-party `*.list`, `*.sources`, `*.list.save`, `*.distUpgrade`, `*.gpg`)
- `/etc/apt/sources.list.save` (removed when present)
- `/etc/apt/sources.list.backup_<timestamp>/` (created for backups)

---

### 2. Setup DNS
Configures DNS using systemd-resolved. Officially supports Debian 12/13, Ubuntu 22.04/24.04/26 (other OS versions may work but are user-tested).

**DNS Providers:** Cloudflare, Google, Quad9, OpenDNS, AdGuard, CleanBrowsing, Custom

**Features:**
- Defaults to plain direct-IP DNS
- Optional secure DNS with DNS-over-TLS (DoT) and DNSSEC validation
- IPv6 support (optional)
- All selected DNS providers are queried in order as primary servers
- Auto-orders selected providers by measured latency (fastest first) and drops unresponsive ones
- Static last-resort `FallbackDNS` for when all primaries are down
- Automatic conflict resolution

**Files modified by this script:**
- `/etc/systemd/resolved.conf`
- `/etc/resolv.conf` (re-created as symlink to systemd-resolved stub)
- `/etc/dhcp/dhclient.conf`
- `/etc/network/if-up.d/resolved` (removes execute permission when present)

---

### 3. Fix Hostname
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
- `/etc/hosts.backup_<timestamp>` (created before changes)

---

### 4. Configure IPv6
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
- `/etc/sysctl.d/99-disable-ipv6.conf` (created/removed depending on enable/disable action)
- `/etc/sysctl.conf` (removes `disable_ipv6` lines during enable action)
- `/etc/network/interfaces` (only when interface-based persistent config is selected)
- `/etc/network/interfaces.backup_<timestamp>` (created before editing `/etc/network/interfaces`)

**What it does:**
- **Enable:** Removes disable configuration, enables IPv6 on all interfaces, tests connectivity
- **Disable:** Creates `/etc/sysctl.d/99-disable-ipv6.conf` with persistent disable settings
- **Configure Address:** 
  - Checks for existing IPv6 addresses and warns user
  - Allows adding addresses from your allocated prefix (e.g., `2001:db8::/48`)
  - Supports CIDR notation like `2001:db8::1/64`
  - Keeps existing addresses (adds, doesn't replace)

**Supports multiple network configuration systems:**
- `/etc/network/interfaces` (Debian/Ubuntu)
- Netplan (Ubuntu 18.04+)
- NetworkManager
- Manual configuration


---

## 🔧 Requirements

- **OS**: Debian 11/12/13 or Ubuntu 20.04/22.04/24.04/24.10
- **Privileges**: Root access (sudo)
- **Network**: Internet connection (for downloading scripts from GitHub)
- **Shell runtime**: `bash` (scripts can be launched from `bash`, `zsh`, or `fish` as long as Bash is installed)

---

## 📥 Installation

See [Quick Start](#-quick-start) above for installation instructions.

**What the installer does:**
1. Downloads `clikader` from GitHub
2. Installs it to `/usr/local/bin/clikader`
3. Makes it executable
4. Verifies installation

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

**Automatic version detection** - only updates if a newer version is available.

---

##🛡️ Safety Features

**All scripts include:**
- Automatic backups before changes
- Configuration validation
- Clear status reporting
- Error handling

**Specific safeguards:**
- **APT Reset**: Timestamped backups in `/etc/apt/sources.list.backup_*/`
- **DNS Setup**: Health checks before modifications
- **Hostname**: Validates hostname format (RFC 1123)
- **IPv6**: Confirmation prompt before disabling

---

## 📝 License

Apache License 2.0. See [LICENSE](./LICENSE) for full terms.

## ⚠️ Disclaimer

These scripts modify system configuration. While they include safety features like backups, always:
- Test in a non-production environment first
- Ensure you have backups of critical data
- Review the scripts before running them
