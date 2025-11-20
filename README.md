# Server Scripts

A collection of shell scripts for managing Debian and Ubuntu servers.

## 🚀 Quick Start

```bash
# Download and run the interactive menu
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/clikader.sh | sudo bash
```

Or if you've cloned the repository:

```bash
git clone https://github.com/clikader/server-scripts.git
cd server-scripts
chmod +x clikader.sh
sudo bash clikader.sh
```

**Note:** All component scripts are located in the `components/` folder and should be run through the interactive menu (`clikader.sh`).

---

## 📜 Available Tools

### **clikader.sh** - Interactive Menu System
Master entrypoint with arrow key navigation for all server management tasks.

**Features:**
- Arrow key navigation (↑/↓)
- Press Enter to select, Q to Quit
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

### Quick Install (One-liner)
```bash
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/clikader.sh | sudo bash
```

### Manual Install
```bash
git clone https://github.com/clikader/server-scripts.git
cd server-scripts
chmod +x clikader.sh
sudo bash clikader.sh
```

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
