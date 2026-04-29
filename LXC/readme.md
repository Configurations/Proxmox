# LXC — Proxmox provisioning scripts

This folder contains scripts to provision Ubuntu LXC containers on Proxmox, with Docker (optionally Docker Swarm) and Grafana Alloy as the observability agent.

All scripts are **idempotent** — safe to run multiple times. They run from the **Proxmox host** (not from inside the container), except where noted.

## Available scripts

| Script | Where | Purpose |
|---|---|---|
| `00-create-lxc.sh` | Proxmox host | Create or reconfigure an Ubuntu LXC, install Docker, optionally Swarm-ready |
| `01-install-docker.sh` | Inside LXC | Install Docker Engine + Compose. Called automatically by `00-create-lxc.sh`, but can be run standalone |
| `02-init-swarm.sh` | Proxmox host | Initialize a **new** Swarm cluster on a swarm-ready LXC (first manager) |
| `02-join-swarm.sh` | Proxmox host | Make an existing LXC **join** an existing Swarm cluster (worker or manager) |
| `03-install-alloy.sh` | Inside LXC | Install Grafana Alloy as a logs/metrics collector |
| `deploy-alloy-all.sh` | Proxmox host | Deploy Alloy on a list of LXCs in one command |

`02-init-swarm.sh` and `02-join-swarm.sh` are **alternatives**, not a sequence — use one or the other depending on whether you're starting a new cluster or extending one.

## Quick start

### Single Docker LXC (no Swarm)

```bash
# On the Proxmox host
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 200 my-docker-lxc
```

The script auto-selects the storage with the most free space, creates the LXC, installs Docker, and creates an `agflow` user with sudo + SSH key.

### New Swarm cluster (one manager)

```bash
# 1. Create the LXC, swarm-ready (kernel modules, /dev/net/tun, sysctls)
STORAGE=extended-lvm DISK_SIZE=50 \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm

# 2. Initialize the Swarm cluster on this LXC
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-init-swarm.sh)" _ 300
```

### Adding more nodes to an existing Swarm

Once you have a Swarm running, you can add **workers** (run services) or **managers** (HA control plane).

#### Getting the join command from an existing manager

From any existing manager, you can ask Swarm for the exact `docker swarm join` command, including the token:

```bash
# On the LXC 300 (existing manager)
docker swarm join-token worker
# Prints:
# docker swarm join --token SWMTKN-1-xxx... 192.168.10.115:2377

docker swarm join-token manager
# Prints:
# docker swarm join --token SWMTKN-1-yyy... 192.168.10.115:2377
```

You can copy-paste that command directly inside another LXC to join the cluster manually. The `02-join-swarm.sh` script automates this end-to-end from the Proxmox host.

#### Automated join with the script

```bash
# 1. Create the new LXC, swarm-ready
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 301 swarm-2 --swarm

# 2. Get the join token and manager IP from an existing manager
TOKEN=$(pct exec 300 -- docker swarm join-token worker -q)
MANAGER_IP=$(pct exec 300 -- docker info --format '{{.Swarm.NodeAddr}}')

# 3. Join as worker
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-join-swarm.sh)" _ 301 "${MANAGER_IP}" "${TOKEN}"
```

For an additional **manager** (HA), use `--manager` and the manager token:

```bash
TOKEN_MGR=$(pct exec 300 -- docker swarm join-token manager -q)
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-join-swarm.sh)" _ 302 "${MANAGER_IP}" "${TOKEN_MGR}" --manager
```

Verify from the manager:

```bash
pct exec 300 -- docker node ls
```

### Deploying Alloy across multiple LXCs

```bash
LXC_HOSTS="101 102 200 300" \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"
```

The script auto-detects the Loki endpoint, copies Alloy configs, runs the install in each LXC, and skips containers that are already up to date.

## Key design choices

### Privileged LXCs

These scripts create **privileged** LXCs (`unprivileged: 0`) because Docker Swarm overlay networks need `/dev/net/tun` and certain kernel capabilities that are restrictive in unprivileged containers. This trades some isolation for full Docker Swarm compatibility.

If you only need plain Docker (no Swarm), unprivileged would also work, but the scripts here standardize on privileged for simplicity.

### Docker network address pool

`01-install-docker.sh` configures Docker with `172.30.0.0/16` as the default pool for bridges (`docker0`, `docker_gwbridge`, custom networks).

This avoids conflicts with:
- The Swarm ingress default range (`10.0.0.0/8`)
- The Swarm overlay pool used by `02-init-swarm.sh` (`10.20.0.0/16`)
- Common homelab LANs (`192.168.x.x`, `10.x.x.x`)

Override with `DOCKER_ADDR_POOL=...` if needed.

### live-restore disabled

Docker's `live-restore: true` is **incompatible with Swarm**. The default in `01-install-docker.sh` is `false`. Override with `LIVE_RESTORE=1` only if running plain Docker without Swarm.

### Storage selection

`00-create-lxc.sh` defaults to `STORAGE=auto`: it shows a dashboard of all Proxmox storages, picks the one with the most free space (among those supporting `rootdir`), and verifies space before `pct create`. Override with `STORAGE=<name>`.

## Common variables

These work across most scripts:

| Variable | Default | Description |
|---|---|---|
| `STORAGE` | `auto` | Proxmox storage for rootfs (`auto` = pick best) |
| `DISK_SIZE` | `30` | LXC rootfs size in GB |
| `CORES` | `4` | CPU cores |
| `MEMORY` | `8192` | RAM in MB |
| `BRIDGE` | `vmbr0` | Network bridge |
| `SSH_KEY_DIR` | `/root/.ssh/lxc-keys` | Where to store generated SSH keys |
| `REPO_RAW_URL` | GitHub raw URL | Override to use a fork or branch |

## Output format

All scripts emit a final JSON line with a status summary, suitable for piping into automation:

```json
{"status":"ok","ctid":"300","ip":"192.168.10.115","docker":"Docker version 27.x","swarm_ready":true}
```

Exit codes:
- `0` — Success
- `1` — Hard failure (LXC creation, Swarm init, etc.)
- `2` — Partial (LXC created but Docker not operational)

## Troubleshooting

### "BASH_SOURCE[0]: unbound variable"

Old version of `00-create-lxc.sh`. Pull the latest from this repo.

### Stack timeout, port not reachable, but service shows "running"

If you have `172.20.0.0/16` in `/etc/docker/daemon.json`, the bridge pool conflicts with Swarm ingress. Recreate the LXC with the latest scripts (now using `172.30.0.0/16`).

### Disk full during install

LXCs default to 30 GB. For Swarm managers running stacks, prefer 50+ GB:

```bash
DISK_SIZE=50 ./00-create-lxc.sh ...
```

To resize an existing LXC:

```bash
pct resize <CTID> rootfs +10G
```

### Alloy reports "Cannot connect to Docker daemon"

Alloy in Docker mode mounts `/var/run/docker.sock` from the host. If the LXC has Docker installed but the daemon is stopped or socket permissions are wrong:

```bash
pct exec <CTID> -- systemctl status docker
pct exec <CTID> -- ls -la /var/run/docker.sock
```

## Related

- [stacks/README.md](../stacks/README.md) — Application stacks deployed on the Swarm cluster (separate repo: `ag-flow/Configurations`)

---

🇫🇷 Pour la version française, voir [README-fr.md](README-fr.md).