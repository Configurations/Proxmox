# LXC — Proxmox + Docker Swarm + Observability

Standalone scripts to provision Proxmox LXC containers configured for Docker (and optionally Docker Swarm), with centralized log collection via Grafana Alloy + Loki.

> **Note**: This folder is a self-contained side project. It will be split into a dedicated repository later. It does not follow the `Installs/+runs/` convention of the parent repository.

## What this gives you

- **Privileged Docker-ready LXCs** in a single command — AppArmor unconfined, nesting, keyctl, SSH keys, dedicated user
- **Optional Docker Swarm support** — kernel modules, `/dev/net/tun`, sysctls, Swarm-ready tag
- **Centralized log collection** — Grafana Alloy on each LXC, pushing to Loki + Grafana on a dedicated LXC
- **Idempotent procedures** — destroy and recreate as many times as you want, scripts handle reconfiguration

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Proxmox cluster                      │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────┐    │
│  │  LXC 300   │  │  LXC xxx   │  │  LXC 116        │    │
│  │  Swarm     │  │  Service   │  │  Loki+Grafana   │    │
│  │  Manager   │  │  worker    │  │  (logs central) │    │
│  │            │  │            │  │                 │    │
│  │  + Alloy   │  │  + Alloy   │  │  + Alloy local  │    │
│  └────────────┘  └────────────┘  └─────────────────┘    │
│        │              │              ▲                  │
│        └──────────────┴──────────────┘                  │
│              Logs pushed to Loki                        │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- Proxmox VE 8+ on the host
- Ubuntu 24.04 template available (`pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst`)
- Storage with `rootdir` content type (LVM-thin, ZFS pool, or LVM)

## Quick start

All commands run **on the Proxmox host**. No git clone needed — every script is fetched directly via wget.

### Create a Docker-only LXC

```bash
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 200 my-service
```

### Create a Swarm manager (recommended setup)

```bash
# 1. Provision LXC + Docker + Swarm prereqs
STORAGE=extended-lvm DISK_SIZE=50 \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm

# 2. Initialize the Swarm cluster
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-init-swarm.sh)" _ 300
```

The manager is ready. Worker tokens are saved at `/root/.ssh/lxc-keys/swarm-tokens-300.json`.

### Deploy Alloy log collector on all LXCs

The script fetches everything it needs from GitHub and pushes to each LXC. Just run on the Proxmox host:

```bash
# Auto-detects Loki IP from LXC 116, deploys to all active LXCs
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Deploy on a subset
LXC_HOSTS="300 201" bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Strict mode (fail if Loki unreachable)
STRICT_CHECKS=1 bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Force a Loki URL (skip auto-detection)
LOKI_URL="http://10.0.0.50:3100/loki/api/v1/push" \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"
```

## Folder structure

```
LXC/
├── 00-create-lxc.sh                # Provision LXC + Docker (+ Swarm option)
├── 01-install-docker.sh            # Install Docker (called by 00)
├── 02-init-swarm.sh                # Initialize Swarm manager
├── 03-install-alloy.sh             # Install Alloy log collector
├── deploy-alloy-all.sh             # Multi-LXC Alloy orchestrator
├── alloy-agent/                    # Alloy configurations
│   ├── config.alloy                # Docker mode (containers + journald)
│   ├── config-journald-only.alloy  # Systemd mode (journald only)
│   ├── docker-compose.yml          # Compose file for Docker mode
│   └── README.md
└── logs-stack/                     # Centralized Loki + Grafana stack
    ├── docker-compose.yml
    ├── loki/
    ├── grafana/
    └── README.md
```

## Where each script runs

| Script | Runs from | Targets |
|---|---|---|
| `00-create-lxc.sh` | Proxmox host | Proxmox host (creates LXC) |
| `01-install-docker.sh` | Inside LXC (pushed by 00) | LXC |
| `02-init-swarm.sh` | Proxmox host | LXC via `pct exec` |
| `03-install-alloy.sh` | Inside LXC (pushed by deploy-alloy-all) | LXC |
| `deploy-alloy-all.sh` | Proxmox host | Multiple LXCs via `pct push` + `pct exec` |

All scripts can be invoked via `bash -c "$(wget -qLO - ...)"` directly on the Proxmox host.

## Script reference

### `00-create-lxc.sh`

Provisions a privileged Docker-ready LXC, with optional Swarm preparation.

- **Create mode** (default): if the CTID does not exist, creates the LXC
- **Reconfigure mode**: if the CTID exists, updates the configuration

```bash
# Standard creation
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 200 my-lxc

# With Swarm support
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 300 swarm-mgr --swarm

# Reconfigure existing LXC for Swarm
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 200 --swarm
```

Useful environment variables:

| Variable | Default | Description |
|---|---|---|
| `STORAGE` | `auto` | `auto` selects pool with most free space; or force a specific name |
| `DISK_SIZE` | `30` | rootfs size in GB |
| `CORES` | `4` | CPU cores |
| `MEMORY` | `8192` | RAM in MB |
| `SAFETY_MARGIN_GB` | `5` | Minimum free space to keep in the pool |

JSON output (parseable for pipelines):

```json
{"status":"ok","ctid":"300","ip":"192.168.10.114","docker_ok":1,"swarm_mode":1,"swarm_ready":true}
```

### `01-install-docker.sh`

Installs Docker Engine and Compose plugin inside an LXC. Automatically called by `00-create-lxc.sh`.

Notable defaults:

- `live-restore: false` (Swarm-compatible). Set `LIVE_RESTORE=1` for classic Docker bare-metal
- `default-address-pools: 172.20.0.0/16` with /24 subnets
- `unattended-upgrades` configured for Ubuntu security patches (Docker excluded)
- Log rotation: 10 MB per file, 3 files max

### `02-init-swarm.sh`

Initializes a Swarm manager on a `swarm-ready` LXC. Pre-checks the LXC, automatically fixes `live-restore: true` if found.

Useful variables:

| Variable | Default | Description |
|---|---|---|
| `ADVERTISE_ADDR` | auto-detected | Force the advertise IP |
| `POOL_OVERLAY` | `10.20.0.0/16` | Overlay network IP pool |
| `NODE_LABELS` | `role=control,tenant=agflow` | Labels applied to the node |
| `FORCE` | `0` | Reset an existing cluster (DESTRUCTIVE) |
| `AUTO_FIX` | `1` | Auto-fix `live-restore: true` if found |

Tokens saved to `/root/.ssh/lxc-keys/swarm-tokens-<CTID>.json`.

### `03-install-alloy.sh`

Installs Grafana Alloy in an LXC. Detects mode automatically:

- Docker present → container mode (compose)
- Docker absent → systemd mode (Debian package)

Required variables: `LOKI_URL`, `HOSTNAME`. Optional `STRICT_CHECKS=1` makes it fail if Loki is unreachable.

Usually invoked via `deploy-alloy-all.sh`, but can be run standalone inside an LXC.

See [`alloy-agent/README.md`](alloy-agent/README.md) for configuration details.

### `deploy-alloy-all.sh`

Runs on the Proxmox host. Downloads all required Alloy files from GitHub into `/tmp/alloy-files/`, then pushes them to each LXC via `pct push` and runs `03-install-alloy.sh` via `pct exec`.

| Variable | Default | Description |
|---|---|---|
| `LOKI_URL` | auto-detected from LXC 116 | Force the Loki endpoint |
| `LXC_HOSTS` | active LXCs with Docker | Space-separated CTID list |
| `LOKI_LXC` | `116` | CTID of the LXC hosting Loki |
| `LOKI_PORT` | `3100` | Loki port |
| `STRICT_CHECKS` | `0` | Fail if Loki unreachable from inside an LXC |
| `REPO_BRANCH` | `main` | GitHub branch to fetch from |

Special case: when deploying to the LXC that hosts Loki itself (CTID 116), the script uses `localhost` instead of the network IP to avoid a roundtrip and break the circular dependency.

## Key concepts

### Privileged vs unprivileged LXC

Docker inside an unprivileged LXC requires fragile capability and user-namespace mapping setups. For a homelab where the LXC sits on a trusted private network, **privileged + AppArmor unconfined** is the simplest and most stable route.

Trade-off: a compromised Docker container in a privileged LXC has more capabilities than in unprivileged. Acceptable for homelab, worth challenging for multi-tenant production.

### Why Docker Swarm and not Kubernetes (k3s)?

**Swarm**:
- Same Docker images, same socket, same `docker compose` syntax
- Single-command init, no separate control plane to deploy
- Native "service global" pattern — automatically deploys a container per node
- Sweet spot for 1 to 5 nodes, single operator

**k3s**:
- Richer ecosystem (Helm, operators, CRDs)
- But requires separate containerd, so local images need a registry rebuild
- Higher operational complexity

For homelab use, Swarm wins on simplicity and Docker-native integration.

### Overlay address pool

Docker Swarm uses `10.0.0.0/8` by default for overlay networks, which collides with private LANs in `10.x.x.x`. `02-init-swarm.sh` configures `10.20.0.0/16` (overridable via `POOL_OVERLAY=`).

### Alloy modes

Alloy runs in two modes depending on Docker presence in the LXC:

| Mode | When | Sources collected | Deployment |
|------|------|-------------------|------------|
| **Docker** | LXC with Docker | Containers + journald | `docker compose up` |
| **systemd** | LXC without Docker (DNS, Vault, etc.) | journald only | Debian package + service |

See [`alloy-agent/README.md`](alloy-agent/README.md).

### Static IP vs DHCP for the Swarm manager

The Swarm manager's advertise IP is baked into the cluster config. **If the IP changes, workers can no longer reach the manager.**

Solutions in order of robustness:

1. **DHCP reservation** in your router/DHCP server (recommended)
2. **Internal DNS** + advertise via hostname instead of IP
3. **Static IP** in the LXC config (`pct set <CTID> -net0 ...,ip=<IP>/24,gw=<GW>`)

## Troubleshooting

### `docker swarm init` fails with "live-restore is incompatible"

`02-init-swarm.sh` detects and auto-fixes this. Manual fix:

```bash
pct exec 300 -- sed -i 's/"live-restore": true/"live-restore": false/' /etc/docker/daemon.json
pct exec 300 -- systemctl restart docker
```

### Storage pool full during install

`00-create-lxc.sh` checks free space before `pct create` and suggests an alternative. Recreate on a different storage:

```bash
STORAGE=extended-lvm bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm
```

### Alloy not pushing to Loki

```bash
# View container logs
pct exec <CTID> -- docker compose -f /opt/alloy-agent/docker-compose.yml logs --tail 50

# Test connectivity to Loki from inside the LXC
pct exec <CTID> -- curl -v http://192.168.10.110:3100/ready
```

### LXC is on DHCP and the IP changed

For critical services (Swarm manager, Loki), reserve the IP on your DHCP server or switch to static:

```bash
pct stop <CTID>
pct set <CTID> -net0 name=eth0,bridge=vmbr0,firewall=1,ip=192.168.10.200/24,gw=192.168.10.1,type=veth
pct start <CTID>
```

## Roadmap

- [ ] `04-join-swarm.sh` to automatically add a worker to the cluster
- [ ] Multi-arch (ARM) support for future nodes
- [ ] Unified `bootstrap-lxc.sh` orchestrating 00 + 02 + 03 with flags
- [ ] Automatic DHCP reservation via DHCP/DNS server API
- [ ] Automated backup of Swarm tokens + SSH keys
- [ ] **Split this folder into a dedicated repository**

## License

See [LICENSE](../LICENSE) at the repo root.

---

🇫🇷 Pour la version française, voir [README-fr.md](README-fr.md).
