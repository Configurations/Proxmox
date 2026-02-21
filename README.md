# Proxmox LXC Container Installation Scripts

This repository contains automated installation and deployment scripts for various applications in Proxmox Virtual Environment (PVE) LXC containers. It provides a streamlined way to create and configure containerized applications with minimal manual intervention.

## 📋 Table of Contents

- [Overview](#overview)
- [Supported Applications](#supported-applications)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation Methods](#installation-methods)
- [Features](#features)
- [Directory Structure](#directory-structure)
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## 🎯 Overview

This project automates the deployment of containerized applications in Proxmox Virtual Environment. Instead of manually creating LXC containers and installing software, you can use these scripts to:

- Create new LXC containers with your chosen OS (Debian, Ubuntu, Alpine)
- Automatically install and configure applications
- Apply security best practices
- Customize resource allocation (CPU, RAM, disk)
- Configure networking (static IP, DHCP, DNS, VLAN)

## 📦 Supported Applications

The following applications can be automatically installed:

- **Docker** - Container runtime with optional Portainer management UI
- **Pi-hole** - DNS sinkhole and DHCP server with Unbound resolver support
- **Keycloak** - Identity and access management server
- **OpenClaw** - Web scraping and intelligent automation framework
- **Empty** - Minimal base container for custom installations

New applications can be easily added by creating new installation scripts in the `Installs/` directory.

## ⚙️ Prerequisites

Before running these scripts, ensure you have:

1. **Proxmox Virtual Environment** (version 8.1 or later)
2. **SSH access** to the Proxmox server or direct shell access
3. **Root privileges** on the Proxmox host
4. **Available storage** for templates and containers
5. **Network connectivity** to download templates and packages

### Minimum Hardware Requirements

- **CPU**: 2 cores minimum (4+ recommended)
- **RAM**: 4GB minimum (8GB+ recommended)
- **Storage**: 20GB minimum for templates and containers

## 🚀 Quick Start

### Option 1: Direct Installation (Recommended)

Run the main installation script directly from the Proxmox shell or SSH terminal:

```bash
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/start.sh)"
```

### Option 2: Local File Execution

If you prefer to download the scripts first:

```bash
# Download the main installer script
wget https://github.com/Configurations/Proxmox/raw/main/runs/start.sh

# Make it executable
chmod +x start.sh

# Run the installation
./start.sh
```

### Option 3: Manual Application Selection

For more control, you can manually select applications:

```bash
# Generate the applications list
pwsh ./generate_install.ps1

# Then run the installer
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/start.sh)"
```

## 📖 Installation Methods

### Default Settings Installation

The wizard will use default settings:
- **Distribution**: Debian 12 (Bookworm)
- **Container Type**: Unprivileged
- **Disk Size**: 4GB
- **CPU Cores**: 2
- **RAM**: 2048MB (2GB)
- **Network**: DHCP
- **Root Password**: Automatic login

### Advanced Settings Installation

When prompted, select "Advanced" to customize:
- Choose OS distribution and version (Debian 11/12, Ubuntu 20.04/22.04/24.04, Alpine)
- Set root password or enable automatic login
- Assign container ID manually
- Configure hostname
- Allocate CPU cores and RAM
- Set disk size
- Configure static IP address or gateway
- Enable IPv6 or DNS customization
- Add VLAN tags and MAC address customization
- Enable verbose mode for debugging

## ✨ Features

### Automated Setup
- Interactive wizard with sensible defaults
- Whiptail-based GUI for configuration
- Progress indicators and real-time feedback
- Automatic template download and caching

### Security
- Randomly generated admin passwords stored securely
- Validation of all user inputs
- Root privilege checks
- Architecture compatibility verification

### Error Handling
- Comprehensive error messages
- Graceful failure recovery
- Detailed logging for troubleshooting
- Automatic cleanup on interruption

### Flexibility
- Support for multiple Linux distributions
- Privileged and unprivileged container modes
- Hardware device passthrough support (VAAPI)
- Custom resource allocation

## 📁 Directory Structure

```
Proxmox/
├── README.md                    # This file
├── LICENSE                      # MIT License
├── applications.txt             # List of available applications
├── generate_install.ps1         # PowerShell script to generate app list
├── Installs/
│   ├── _Empty.sh               # Minimal base container
│   ├── docker.sh               # Docker + Portainer installation
│   ├── pi-hole.sh              # Pi-hole + Unbound installation
│   ├── keycloak.sh             # Keycloak installation
│   └── openclaw.sh             # OpenClaw web scraping framework
├── runs/
│   ├── start.sh                # Main installation wizard
│   └── docker.sh               # Docker composition script
└── scripts/
    ├── build.func              # Core build functions library
    ├── create_lxc.sh           # LXC container creation
    ├── alpine-install.func     # Alpine Linux functions
    ├── install.func            # Debian/Ubuntu functions
    └── post-pbs-install.sh     # Post-installation tasks
```

## 🔧 Advanced Configuration

### Creating Custom Application Installers

To add a new application:

1. Create `Installs/myapp.sh`:

```bash
#!/usr/bin/env bash

# Source the build functions
if [[ ! -v FUNCTIONS_FILE_PATH ]]; then
  source <(curl -s https://github.com/Configurations/Proxmox/raw/main/scripts/build.func)
else
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
fi

# Initialize environment
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Your installation commands here
msg_info "Installing MyApp"
apt-get update
apt-get install -y myapp
msg_ok "MyApp installed"

# Cleanup
msg_info "Cleaning up"
apt-get -y autoremove
apt-get -y autoclean
msg_ok "Cleaned"
```

2. The script will be automatically available in the application selection menu.

### Updating Applications List

After adding new installation scripts, regenerate the applications list:

**PowerShell (Windows/WSL):**
```powershell
.\generate_install.ps1
```

**Bash/Linux:**
```bash
ls -1 Installs/*.sh | sed 's|Installs/||g' | sed 's|.sh||g' | tr '\n' ';' > applications.txt
```

### Environment Variables

When creating containers, these variables are available in installation scripts:

- `$APPLICATION` - Application name
- `$app` - Lowercase application name
- `$CTID` - Container ID
- `$CTTYPE` - Container type (0=privileged, 1=unprivileged)
- `$PCT_OSTYPE` - OS type (debian, ubuntu, alpine)
- `$PCT_OSVERSION` - OS version
- `$PASSWORD` - Root password (if set)
- `$SSH_ROOT` - Enable root SSH access (yes/no)

## 🐛 Troubleshooting

### Issue: "Unable to detect a valid Container Storage location"

**Solution**: Ensure you have storage configured in Proxmox for container templates and container storage.

```bash
pvesm status -content rootdir   # Check container storage
pvesm status -content vztmpl    # Check template storage
```

### Issue: "This version of Proxmox Virtual Environment is not supported"

**Solution**: Update Proxmox to version 8.1 or later:

```bash
apt update && apt dist-upgrade
```

### Issue: Script fails with "Please run this script as root"

**Solution**: Execute the script with root privileges:

```bash
sudo bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/start.sh)"
```

### Issue: Container creation fails with "Not enough resources"

**Solution**: Check available storage and reduce container size:

```bash
pvesm status                    # Check available storage
free -h                         # Check available RAM
```

### Issue: Network connectivity problems in container

**Solution**: Verify bridge configuration and container network settings:

```bash
# On Proxmox host
ip addr show vmbr0              # Check bridge interface

# Inside container
ip addr show                    # Check IP configuration
ping -c 1 8.8.8.8             # Test connectivity
```

## 📝 Keycloak Default Credentials

After Keycloak installation, the admin password is displayed once in the console:

```
Keycloak Admin Password: <random-password>
```

**⚠️ Important**: Save this password immediately. It is not stored and cannot be retrieved later. If lost, you must reinstall Keycloak.

To reset the admin password after installation:

```bash
pct exec <container-id> -- systemctl stop keycloak.service
pct exec <container-id> -- /opt/keycloak/bin/kc.sh bootstrap-admin user \
  --bootstrap-admin-username admin --bootstrap-admin-password newpassword
pct exec <container-id> -- systemctl start keycloak.service
```

## 🔗 Docker & Portainer Access

After Docker installation:

- **Portainer UI**: https://`<container-ip>`:9443
- **Docker**: Access via `docker` command inside container
- **Portainer Agent**: Port 9001 (if installed during setup)

## �️ OpenClaw Usage

After OpenClaw installation, you can access and use the framework:

```bash
# SSH into the container
pct exec <container-id> -- /bin/bash

# Run OpenClaw commands
openclaw --help          # View available commands
openclaw --version       # Check installed version

# Create and run scraping tasks
cd /opt/openclaw/state
openclaw run <task-name> # Execute automation tasks
```

**Features:**
- Web scraping and HTML parsing
- Intelligent automation framework
- Headless browser automation with Playwright/Chromium
- Node.js 22 runtime included
- Full environment variables support

## �🛡️ Security Considerations

1. **Change default passwords** immediately after installation
2. **Configure firewalls** to restrict container access
3. **Keep Proxmox updated** with latest security patches
4. **Use SSH keys** instead of password authentication when possible
5. **Regular backups** of critical containers
6. **Monitor container logs** for suspicious activity

## 📚 Additional Resources

- [Proxmox VE Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [Docker Documentation](https://docs.docker.com/)
- [Pi-hole Documentation](https://docs.pi-hole.net/)
- [Keycloak Documentation](https://www.keycloak.org/documentation)

## 🤝 Contributing

Contributions are welcome! To add new applications or improve existing scripts:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/new-app`)
3. Add your installation script in `Installs/`
4. Test thoroughly in a Proxmox environment
5. Submit a pull request with detailed description

## 📄 License

This project is released under the MIT License. See [LICENSE](LICENSE) file for details.

---

**Last Updated**: February 2026

For issues, questions, or feature requests, please open an issue on the GitHub repository.
