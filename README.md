# Proxmox LXC Installation Scripts

Automated installation and deployment scripts for containerized applications in Proxmox Virtual Environment (PVE). Create and configure LXC containers with a guided wizard — no manual intervention required.

## Table of Contents

- [Overview](#overview)
- [Supported Applications](#supported-applications)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [CLI Flags](#cli-flags)
- [Directory Structure](#directory-structure)
- [Adding a New Application](#adding-a-new-application)
- [Advanced Configuration](#advanced-configuration)
- [Application Notes](#application-notes)
- [CI/CD](#cicd)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

This project eliminates the manual steps of creating LXC containers and installing applications in Proxmox. The wizard handles:

- Container creation (OS, CPU, RAM, disk)
- Network configuration (DHCP, static IP, VLAN, MTU, DNS)
- Application installation and systemd service setup
- Security hardening (credentials generation, SSH control)
- Post-install cleanup

Supported OS targets: **Debian 11/12**, **Ubuntu 20.04/22.04/24.04**, **Alpine Linux**.

---

## Supported Applications

| Application | OS | Type | CPU | RAM | Disk | Port(s) |
|---|---|---|---|---|---|---|
| **Docker** + Portainer | Debian 12 | Unprivileged | 2 | 2 GB | 4 GB | 9443 (Portainer), 9001 (Agent) |
| **Gitea** | Debian 12 | Unprivileged | 2 | 1 GB | 8 GB | 3000 |
| **Keycloak** | Debian 12 | Unprivileged | 2 | 2 GB | 6 GB | 8080 |
| **Nginx Proxy Manager** | Debian 12 | **Privileged** | 2 | 512 MB | 4 GB | 80, 81 (admin), 443 |
| **OpenClaw** | Ubuntu 24.04 | **Privileged** | 2 | 4 GB | 10 GB | 18789 |
| **Pi-hole** | Debian 12 | Unprivileged | 1 | 512 MB | 4 GB | 80, 53 (DNS) |
| **Uptime Kuma** | Debian 12 | Unprivileged | 1 | 512 MB | 4 GB | 3001 |
| **Vaultwarden** | Debian 12 | **Privileged** | 1 | 512 MB | 4 GB | 8080 |
| **Empty** | Debian 12 | Unprivileged | 2 | 2 GB | 4 GB | — |

> Privileged containers are required for Docker-based apps (Vaultwarden, Nginx Proxy Manager) and OpenClaw.

---

## Prerequisites

- **Proxmox VE 8.1 or later**
- **Root access** on the Proxmox host (direct shell or SSH)
- **Network connectivity** to download OS templates and packages
- **amd64 architecture** (ARM not supported in this repo)

### Minimum host resources

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Storage | 20 GB | 50+ GB |

---

## Quick Start

Run from the Proxmox shell (not SSH — see note below):

```bash
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/start.sh)"
```

The wizard will:
1. Let you select an application from the list
2. Offer default settings or advanced configuration
3. Create the LXC container and run the install script inside it

> **SSH note**: The script can be run over SSH but the Proxmox shell is recommended to avoid terminal variable issues.

### Direct install for a specific app

Each application also has a standalone runner:

```bash
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/docker.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/gitea.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/keycloak.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/nginx-proxy-manager.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/openclaw.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/pi-hole.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/uptime-kuma.sh)"
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/vaultwarden.sh)"
```

### Updating an existing container

From the **Proxmox host**, trigger an update inside a running container by ID:

```bash
wget -qO start.sh https://github.com/Configurations/Proxmox/raw/main/runs/start.sh
bash start.sh --update 102
```

Or from **inside the container** directly:

```bash
/usr/bin/update
```

---

## CLI Flags

`runs/start.sh` accepts the following flags:

| Flag | Description |
|---|---|
| `--dry-run` / `-n` | Show the planned container configuration without creating anything |
| `--update <CTID>` | Trigger the update routine inside an existing container (Proxmox host only) |

### Dry-run example

```bash
wget -qO start.sh https://github.com/Configurations/Proxmox/raw/main/runs/start.sh
bash start.sh --dry-run
```

Output:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [DRY RUN] Container would be created with:
  App:      gitea
  OS:       debian 12
  Type:     Unprivileged
  CPU:      2 core(s)
  RAM:      1024 MB
  Disk:     8 GB
  Network:  dhcp
  Bridge:   vmbr0
  SSH root: no
  Script:   Installs/gitea.sh
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Directory Structure

```
Proxmox/
├── .github/
│   └── workflows/
│       ├── ci.yml              # 4-job CI pipeline (syntax, shellcheck, sync, structure)
│       └── autogen.yml         # Auto-regenerate applications.txt on Installs/ changes
├── Installs/
│   ├── _Empty.sh               # Minimal base container
│   ├── _Template.sh            # Reference template for new scripts (excluded from menu)
│   ├── docker.sh               # Docker + Portainer + Compose
│   ├── gitea.sh                # Gitea Git hosting
│   ├── keycloak.sh             # Keycloak IAM
│   ├── nginx-proxy-manager.sh  # Nginx Proxy Manager (Docker-based)
│   ├── openclaw.sh             # OpenClaw automation framework
│   ├── pi-hole.sh              # Pi-hole + optional Unbound
│   ├── uptime-kuma.sh          # Uptime Kuma monitoring
│   └── vaultwarden.sh          # Vaultwarden password manager (Docker-based)
├── runs/
│   ├── start.sh                # Interactive wizard (all apps, supports --dry-run / --update)
│   ├── docker.sh               # Docker runner + updater
│   ├── gitea.sh                # Gitea runner + updater
│   ├── keycloak.sh             # Keycloak runner + updater
│   ├── nginx-proxy-manager.sh  # NPM runner + updater
│   ├── openclaw.sh             # OpenClaw runner + updater
│   ├── pi-hole.sh              # Pi-hole runner + updater
│   ├── uptime-kuma.sh          # Uptime Kuma runner + updater
│   └── vaultwarden.sh          # Vaultwarden runner + updater
├── scripts/
│   ├── build.func              # Main function library (sourced by all runs/ scripts)
│   ├── install.func            # Debian/Ubuntu install-time functions
│   ├── alpine-install.func     # Alpine install-time functions
│   ├── create_lxc.sh           # LXC container creation
│   ├── check-sync.sh           # CI: applications.txt vs Installs/ sync
│   ├── check-structure.sh      # CI: required sections in Installs/ scripts
│   └── post-pbs-install.sh     # Post-installation tasks
├── applications.txt            # Semicolon-separated list of available apps (auto-generated)
├── generate_install.sh         # Regenerate applications.txt — Linux/macOS
├── generate_install.ps1        # Regenerate applications.txt — Windows (PowerShell)
└── .shellcheckrc               # ShellCheck project-wide configuration
```

---

## Adding a New Application

### 1. Create the install script

Copy `Installs/_Template.sh` to `Installs/myapp.sh`. The template documents all required sections and available runtime variables.

**Required sections** (enforced by CI's structure check):

```bash
# Standalone execution guard
if [[ ! -v FUNCTIONS_FILE_PATH ]]; then
  source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION:-main}/scripts/build.func")
else
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
fi

color; verb_ip6; catch_errors          # initialisation
setting_up_container; network_check    # container setup
update_os                              # OS packages update

# ... your install logic ...

motd_ssh; customize                    # finalisation + cleanup
```

**Available runtime variables:**

| Variable | Description |
|---|---|
| `$APPLICATION` | Display name (e.g. `"Gitea"`) |
| `$app` | Lowercase name (e.g. `"gitea"`) |
| `$STD` | `""` (verbose) or `"silent"` (quiet) |
| `$PASSWORD` | Root password (empty = auto-login) |
| `$SSH_ROOT` | `"yes"` or `"no"` |
| `$DISABLEIPV6` | `"yes"` or `"no"` |
| `$VERBOSE` | `"yes"` or `"no"` |

**Alpine support pattern** (if applicable):

```bash
if command -v apk &>/dev/null; then
  install_pkg() { $STD apk add --no-cache "$@"; }
  cleanup_pkg() { $STD apk cache clean; }
else
  install_pkg() { $STD apt-get install -y "$@"; }
  cleanup_pkg() { $STD apt-get -y autoremove; $STD apt-get -y autoclean; }
fi
```

If Alpine is not supported:

```bash
if command -v apk &>/dev/null; then
  msg_error "MyApp does not support Alpine Linux. Use Debian or Ubuntu."
  exit 1
fi
```

### 2. Create the runner script

Copy an existing `runs/*.sh` (e.g. `runs/gitea.sh`) to `runs/myapp.sh`. Update:

- `APP="myapp"` — must match the `Installs/` filename
- `var_disk`, `var_cpu`, `var_ram`, `var_os`, `var_version` — default resources
- `CT_TYPE` in `default_settings()` — `"0"` privileged or `"1"` unprivileged
- `update_script()` — app-specific update logic (binary download, `docker compose pull`, etc.)

### 3. Regenerate `applications.txt`

```bash
# Linux / macOS
bash generate_install.sh

# Windows (PowerShell)
.\generate_install.ps1
```

`applications.txt` is also auto-regenerated by CI whenever `Installs/*.sh` changes on `main`.

### 4. Validate locally

```bash
bash scripts/check-sync.sh       # applications.txt in sync, runs/ scripts exist
bash scripts/check-structure.sh  # all required sections present
```

---

## Advanced Configuration

When the wizard prompts, choose **Advanced** to configure:

| Setting | Options |
|---|---|
| Distribution | Debian 11/12, Ubuntu 20.04/22.04/24.04, Alpine |
| Container type | Privileged / Unprivileged |
| Root password | Custom or automatic login |
| Container ID | Auto-assigned or manual |
| Hostname | Derived from app name or custom |
| CPU cores | Custom count |
| RAM | Custom (MiB) |
| Disk | Custom (GB) |
| Network | DHCP or static CIDR + gateway |
| Bridge | Default `vmbr0` or custom |
| IPv6 | Enable / Disable |
| MTU | Custom or default |
| DNS | Custom search domain and server |
| VLAN | Tag or none |
| MAC address | Auto or custom |
| SSH root access | Yes / No (requires password) |
| Verbose mode | Yes / No |
| APT-Cacher | IP for local package caching |

---

## Application Notes

### Docker

After installation, the wizard prompts to install Portainer and/or Docker Compose.

| Component | URL |
|---|---|
| Portainer UI | `https://<ip>:9443` |
| Portainer Agent | `<ip>:9001` |

### Gitea

Complete initial configuration at `http://<ip>:3000` on first access (database, admin account).

### Keycloak

Admin credentials are generated once and displayed at install time. **Save them immediately.**

```
Username: temp-admin
Password: <randomly generated>
```

To reset credentials:
```bash
pct exec <CTID> -- systemctl stop keycloak.service
pct exec <CTID> -- /opt/keycloak/bin/kc.sh bootstrap-admin user \
  --bootstrap-admin-username admin --bootstrap-admin-password newpassword
pct exec <CTID> -- systemctl start keycloak.service
```

### Nginx Proxy Manager

| URL | Description |
|---|---|
| `http://<ip>:81` | Admin panel |
| `http://<ip>:80` | HTTP proxy |
| `https://<ip>:443` | HTTPS proxy |

Default login: `admin@example.com` / `changeme` — change on first login.
Requires a **privileged** container (Docker inside LXC).

### OpenClaw

After installation, run the onboarding wizard once to configure API keys and channels:

```bash
openclaw onboard --install-daemon
systemctl start openclaw-gateway
```

Dashboard: `http://<ip>:18789`

### Pi-hole

Web interface: `http://<ip>/admin`. Admin password shown at install time.
Optional Unbound recursive resolver is configured on port 5335.

> Pi-hole only supports Debian/Ubuntu. Alpine is blocked at install time.

### Uptime Kuma

Dashboard: `http://<ip>:3001`. Create your admin account on first access.

### Vaultwarden

| URL | Description |
|---|---|
| `http://<ip>:8080` | Web vault |
| `http://<ip>:8080/admin` | Admin panel |

Bitwarden clients require HTTPS — use Nginx Proxy Manager as a reverse proxy.
Requires a **privileged** container (Docker inside LXC).

---

## CI/CD

### CI pipeline (`.github/workflows/ci.yml`)

Runs on every push and pull request to `main`.

| Job | Tool | Checks |
|---|---|---|
| `syntax` | `bash -n` | Parse errors in all `.sh` files |
| `shellcheck` | ShellCheck `--severity=warning` | Shell anti-patterns (see `.shellcheckrc`) |
| `sync` | `scripts/check-sync.sh` | `applications.txt` matches `Installs/`, every app has a `runs/` script |
| `structure` | `scripts/check-structure.sh` | Every `Installs/*.sh` contains the 8 required template sections |

Run the checks locally:

```bash
bash scripts/check-sync.sh
bash scripts/check-structure.sh
```

### Auto-generation (`.github/workflows/autogen.yml`)

Triggers when `Installs/*.sh` files change on `main`. Regenerates and commits `applications.txt` if the content changed. Uses `[skip ci]` to avoid re-triggering CI.

---

## Troubleshooting

**"This version of Proxmox Virtual Environment is not supported"**
```bash
apt update && apt dist-upgrade
```

**"Please run this script as root"**
```bash
sudo bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/runs/start.sh)"
```

**"Unable to detect a valid Container Storage location"**
```bash
pvesm status -content rootdir
pvesm status -content vztmpl
```

**Container has no network after creation**
```bash
ip addr show vmbr0                  # Check bridge on host
pct exec <CTID> -- ip addr          # Check IP inside container
pct exec <CTID> -- ping 1.1.1.1     # Test connectivity
```

**"Not enough resources"**
```bash
pvesm status    # Check available storage
free -h         # Check available RAM
```

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/myapp`
3. Add `Installs/myapp.sh` following `Installs/_Template.sh`
4. Add `runs/myapp.sh` following an existing runner
5. Run `bash generate_install.sh` to update `applications.txt`
6. Validate: `bash scripts/check-sync.sh && bash scripts/check-structure.sh`
7. Open a pull request — CI validates automatically on push

---

## License

MIT — see [LICENSE](LICENSE).

---

*Based on original work by [tteck](https://github.com/tteck/Proxmox). Extended and maintained by [black beard](https://github.com/Configurations/Proxmox).*
