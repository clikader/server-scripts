# Server Scripts

A collection of shell scripts for managing Debian and Ubuntu servers.

## 🚀 Quick Start

```bash
# Install CLiKader
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/install.sh | sudo bash

# Run from anywhere
sudo clikader
```

**That's it!** CLiKader is now installed and ready to use.

**Features:**
- ✅ Simple installation with one command
- ✅ Reliable stdin/input handling
- ✅ Easy updates with built-in update command
- ✅ Run from anywhere with `sudo clikader`
- ✅ Version tracking

**Note:** All component scripts are downloaded automatically from GitHub when needed.

---

---

## 📜 Available Tools

### **clikader.sh** - Interactive Menu System
Master entrypoint with simple numbered menu for all server management tasks.

**Features:**
- Simple numbered menu selection (1, 2, 3...)
- Built-in update command with version checking
- Automatically downloads component scripts from GitHub if not found locally
- Color-coded interface

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

---

### 2. Setup DNS
Configures DNS with DNS-over-TLS support using systemd-resolved.

**DNS Providers:** Cloudflare, Google, Quad9, OpenDNS, AdGuard, CleanBrowsing, Custom

**Features:**
- DNS-over-TLS (DoT) and DNSSEC validation
- IPv6 support (optional)
- Multiple DNS providers with fallback
- Automatic conflict resolution

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

---

## 📥 Installation

See [Quick Start](#-quick-start) above for installation instructions.

**What the installer does:**
1. Downloads `clikader` from GitHub
2. Installs it to `/usr/local/bin/clikader`
3. Makes it executable
4. Verifies installation

After installation, you can run `sudo clikader` from anywhere on your system.

---

## 🔄 Updating

CLiKader has a built-in update feature with version checking.

```bash
# Run CLiKader
sudo clikader

# Select "Update CLiKader" from the menu
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

MIT License - feel free to use these scripts for your own purposes.

## ⚠️ Disclaimer

These scripts modify system configuration. While they include safety features like backups, always:
- Test in a non-production environment first
- Ensure you have backups of critical data
- Review the scripts before running them
