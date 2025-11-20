# Server Scripts

A collection of shell scripts for managing Debian and Ubuntu servers.

## 🚀 Quick Start

### Using the Interactive Menu (Recommended)

```bash
# Download and run the master script
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/clikader.sh | sudo bash
```

Or if you've cloned the repository:

```bash
sudo bash clikader.sh
```

### Running Individual Scripts

You can also run individual scripts directly:

```bash
# Reset APT sources
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/reset_apt_source.sh | sudo bash

# Setup DNS
curl -fsSL https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/setup_dns.sh | sudo bash
```

## 📜 Available Scripts

### 1. **clikader.sh** - Interactive Menu System
Master entrypoint with arrow key navigation for all server management tasks.

**Features:**
- Arrow key navigation (↑/↓)
- Press Enter to select
- Press Q to quit
- Automatically downloads scripts from GitHub if not found locally
- Color-coded interface

**Usage:**
```bash
sudo bash clikader.sh
```

---

### 2. **reset_apt_source.sh** - APT Source Reset
Resets APT sources to official repositories for Debian and Ubuntu systems.

**Supported Systems:**
- Debian 13 (Trixie)
- Debian 12 (Bookworm)
- Debian 11 (Bullseye)
- Ubuntu 24.10 (Oracular Oriole)
- Ubuntu 24.04 LTS (Noble Numbat)
- Ubuntu 22.04 LTS (Jammy Jellyfish)
- Ubuntu 20.04 LTS (Focal Fossa)

**Features:**
- Automatic backup of existing sources
- Resets to official mirrors
- Cleans third-party sources
- Updates APT cache
- Verifies configuration

**Usage:**
```bash
sudo bash reset_apt_source.sh
```

**What it does:**
1. Creates timestamped backup in `/etc/apt/sources.list.backup_YYYYMMDD_HHMMSS/`
2. Generates appropriate sources for your OS version
3. Removes third-party sources from `/etc/apt/sources.list.d/`
4. Updates APT cache
5. Verifies the new configuration

---

### 3. **setup_dns.sh** - DNS Configuration
Configures DNS with DNS-over-TLS support using systemd-resolved.

**Supported DNS Providers:**
1. Cloudflare
2. Google
3. Quad9
4. OpenDNS
5. AdGuard
6. CleanBrowsing
7. Custom DNS (define your own)

**Features:**
- DNS-over-TLS (DoT) support
- DNSSEC validation
- IPv6 support (optional with `-6` flag)
- Multiple DNS providers
- Automatic conflict resolution
- Health checks

**Usage:**
```bash
# IPv4 only
sudo bash setup_dns.sh

# With IPv6 support
sudo bash setup_dns.sh -6
```

**Interactive Options:**
- Select multiple DNS providers
- First selection becomes primary
- Others become fallbacks
- Custom DNS configuration support

## 🔧 Requirements

- **OS**: Debian 11/12/13 or Ubuntu 20.04/22.04/24.04/24.10
- **Privileges**: Root access (sudo)
- **Network**: Internet connection (for downloading scripts)

## 📥 Installation

### Clone the Repository
```bash
git clone https://github.com/clikader/server-scripts.git
cd server-scripts
chmod +x *.sh
```

### Or Download Individual Scripts
```bash
# Download clikader.sh
curl -O https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/clikader.sh
chmod +x clikader.sh

# Download reset_apt_source.sh
curl -O https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/reset_apt_source.sh
chmod +x reset_apt_source.sh

# Download setup_dns.sh
curl -O https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/setup_dns.sh
chmod +x setup_dns.sh
```

## 🛡️ Safety Features

### APT Source Reset
- **Automatic Backups**: All existing sources are backed up before changes
- **Backup Location**: `/etc/apt/sources.list.backup_YYYYMMDD_HHMMSS/`
- **Official Sources Only**: Uses only official Debian/Ubuntu mirrors
- **Verification**: Validates configuration after changes

### DNS Setup
- **Health Checks**: Verifies DNS configuration before making changes
- **Conflict Resolution**: Automatically resolves common DNS conflicts
- **Service Validation**: Ensures systemd-resolved is working correctly
- **Rollback Support**: Can revert to previous configuration if needed

## 💡 Examples

### Example 1: Reset APT Sources
```bash
$ sudo bash reset_apt_source.sh

==========================================
  APT Source Reset Script
==========================================

--> Detected: ubuntu 24.04 (noble)
--> Creating backup of existing APT sources...
✅ Backed up /etc/apt/sources.list to /etc/apt/sources.list.backup_20251120_141209/

--> Resetting APT sources for Ubuntu 24.04...
✅ Generated Ubuntu 24.04 LTS (Noble Numbat) sources
--> Cleaning /etc/apt/sources.list.d/ directory...
✅ Removed 5 third-party source file(s)

--> Updating APT cache...
✅ APT cache updated successfully
```

### Example 2: Interactive Menu
```bash
$ sudo bash clikader.sh

╔════════════════════════════════════════╗
║      CLIKADER - Server Manager        ║
╔════════════════════════════════════════╗

Use ↑/↓ arrow keys to navigate, Enter to select, Q to quit

  ▶ Reset APT Sources
    Setup DNS
```

### Example 3: Setup DNS with Custom Provider
```bash
$ sudo bash setup_dns.sh

==========================================
  Select DNS Providers (DNS-over-TLS)
==========================================

Available DNS providers:
  1) Cloudflare (1.1.1.1, 1.0.0.1) - DoT: cloudflare-dns.com
  2) Google (8.8.8.8, 8.8.4.4) - DoT: dns.google
  ...
  7) Custom DNS (define your own)

Selection: 7

IPv4 DNS servers: 192.168.1.1 1.1.1.1
DNS-over-TLS hostname: dns.example.com
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📝 License

MIT License - feel free to use these scripts for your own purposes.

## ⚠️ Disclaimer

These scripts modify system configuration. While they include safety features like backups, always:
- Test in a non-production environment first
- Ensure you have backups of critical data
- Review the scripts before running them

## 📞 Support

For issues or questions, please open an issue on GitHub.
