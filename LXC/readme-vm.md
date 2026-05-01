# VM — Provisioning & Deployment

Scripts to provision **Proxmox QEMU VMs** ready for Docker / Docker
Swarm via cloud-init. Companion of `create-lxc.sh` — **same flag
interface, same JSON output**, but targets a full VM (own kernel)
instead of an LXC container.

> 🇫🇷 Pour la version française, voir [readme-vm-fr.md](readme-vm-fr.md).
> 📦 Pour la version LXC, voir [readme-lxc.md](readme-lxc.md).

> **Why a VM rather than an LXC?** A VM has its own kernel, so
> Docker Swarm's IPVS-based routing mesh and service VIPs work
> natively (the privileged-LXC IPVS bug documented in
> [readme-lxc.md](readme-lxc.md#-limitations--ipvs-in-privileged-lxc)
> does not apply). Trade-off: higher RAM/CPU footprint, slightly
> slower boot.

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"
```

---

## `create-vm.sh` *(Proxmox host)* — main entry point

A self-contained script that **creates or reconfigures** a Proxmox VM
from an Ubuntu cloud-init image and, depending on the flags, installs
Docker, prepares Swarm, initializes a cluster or joins one.

Bootstrap pattern:

1. **`qm create`** + `qm importdisk` of an Ubuntu cloud-init image
2. **Cloud-init** injects the root SSH key + DHCP network
3. **qemu-guest-agent** (preinstalled in cloud images) is used to
   detect the VM IP after boot
4. The rest (apt update, agflow user, sysctl, Docker install,
   init/join Swarm) is executed via **SSH** as root

### Modes & flags — same as `create-lxc.sh`

| Flag | Effect |
|---|---|
| *(none)* | Bare VM — no Docker, no Swarm |
| `--docker` | Installs Docker (no LXC perms needed: VM has its own kernel) |
| `--swarm` | Prepares the VM swarm-ready (sysctls + tag — no `/dev/net/tun` bind, no host kernel modules: VM is self-contained) |
| `--init-swarm` | Initializes a new Swarm cluster (implies `--docker` + `--swarm`) |
| `--join-swarm --manager-ip <IP> --token <TOKEN> [--as-manager]` | Joins an existing cluster (implies `--docker` + `--swarm`) |

`--init-swarm` and `--join-swarm` are mutually exclusive.

### Differences vs `create-lxc.sh`

| Aspect | LXC | VM |
|---|---|---|
| PVE tool | `pct` | `qm` |
| In-machine exec | `pct exec` | `ssh root@<IP>` (cloud-init key) |
| Bootstrap | Ubuntu `.tar.zst` template | Ubuntu cloud-init `.img` (auto-downloaded) |
| Host kernel modules | required for `--swarm` | ❌ N/A (VM has own kernel) |
| LXC perms (apparmor/cgroup2) | required for `--docker` | ❌ N/A |
| `/dev/net/tun` bind | required for `--swarm` | ❌ native in the VM |
| `--swarm` reduces to | host modules + `/dev/net/tun` + sysctl + tag | sysctl + tag |
| IPVS for Swarm | broken — needs `mode: host` + `endpoint_mode: dnsrr` | works natively |
| JSON `type` | `"lxc"` | `"vm"` (extra `cloud_init` block) |

### Auto behaviors

- **Mode auto-detection** — VM missing → creation; VM exists →
  reconfiguration (config backup, tag/description update).
- **Storage selection** (`STORAGE=auto` by default) — picks the pool
  with the most free space among those supporting `content=images`,
  pre-checks space (with `SAFETY_MARGIN_GB=5`).
- **Cloud-init image auto-download** — Ubuntu 24.04 server cloud
  image fetched to `/var/lib/vz/template/iso` if missing
  (override with `CLOUD_IMG_NAME`/`CLOUD_IMG_URL`).
- **Boot waiters**:
  - guest agent ping (timeout 180s)
  - DHCP IP via guest agent (timeout 120s)
  - SSH availability (timeout `SSH_BOOT_TIMEOUT=180s`)
- **Live-restore auto-fix** — `--init-swarm` detects and corrects
  `live-restore=true` (incompatible with Swarm) when `AUTO_FIX=1`.
- **JSON output** — single aggregated block:
  `{"status", "exit_code", "machine":{...,"cloud_init":{...}}, "docker":{...}, "swarm":{...}}`.

### Generated artifacts

- ed25519 SSH key pair stored on the host:
  `/root/.ssh/vm-keys/id_ed25519_vm<VMID>` (root, injected via
  cloud-init) +
  `/root/.ssh/vm-keys/id_ed25519_agflow_vm<VMID>` (`agflow`).
- `agflow` user (sudo NOPASSWD, random 24-char password, member of
  `docker` group when `--docker` is on).
- For `--init-swarm`: tokens persisted to
  `/root/.ssh/vm-keys/swarm-tokens-vm<VMID>.json` (chmod 600).
- A random root password is set via cloud-init for **console
  access** (key-only otherwise).

### Variables (defaults)

| Var | Default | Role |
|---|---|---|
| `CORES` | `4` | CPU cores |
| `MEMORY` | `8192` | RAM (MB) — balloon disabled |
| `DISK_SIZE` | `30` | scsi0 disk (GB) |
| `STORAGE` | `auto` | VM disk pool |
| `BRIDGE` | `vmbr0` | network bridge (virtio) |
| `SAFETY_MARGIN_GB` | `5` | min free margin in pool |
| `SSH_KEY_DIR` | `/root/.ssh/vm-keys` | SSH keys folder |
| `SSH_BOOT_TIMEOUT` | `180` | SSH wait after boot (sec) |
| `CLOUD_IMG_DIR` | `/var/lib/vz/template/iso` | cloud-init image folder |
| `CLOUD_IMG_NAME` | `ubuntu-24.04-server-cloudimg-amd64.img` | image filename |
| `CLOUD_IMG_URL` | `https://cloud-images.ubuntu.com/releases/24.04/release/<name>` | download URL |
| `LIVE_RESTORE` | `0` | Docker live-restore (0=false, Swarm-compatible) |
| `DOCKER_ADDR_POOL` | `172.30.0.0/16` | Docker bridges IP pool |
| `POOL_OVERLAY` | `10.20.0.0/16` | Swarm overlay pool (init-swarm) |
| `POOL_MASK` | `24` | overlay subnets size |
| `NODE_LABELS` | `role=control,tenant=agflow` | Swarm node labels |
| `FORCE` | `0` | reset Swarm before re-init (**destructive**) |
| `FORCE_LEAVE` | `no` | leave current Swarm before joining |
| `AUTO_FIX` | `1` | auto-fix live-restore=true |

### Prerequisites

- `wget` available on the Proxmox host (used to fetch the cloud
  image if missing)
- `ssh` client on the Proxmox host (used to enter the VM after boot)
- Network connectivity on the host to reach
  `cloud-images.ubuntu.com` (image download, first run only)

### Examples

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

# 1) Bare VM
mkdir -p /root/vm && cd /root/vm && \
  curl -fsSL -o create-vm.sh "$BASE/create-vm.sh" && chmod +x create-vm.sh && \
  ./create-vm.sh 100 ag-base

# 2) VM + Docker
./create-vm.sh 101 ag-docker --docker

# 3) Swarm manager
./create-vm.sh 200 ag-swarm-mgr --init-swarm

# 4) Worker joining an existing cluster
./create-vm.sh 201 ag-worker-1 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-xxxxxxxxx

# 5) Additional manager (HA)
./create-vm.sh 202 ag-mgr-2 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-yyyyyyyyy \
    --as-manager

# 6) Tuning resources + storage
STORAGE=local-lvm DISK_SIZE=80 CORES=8 MEMORY=16384 \
    ./create-vm.sh 203 ag-data --init-swarm
```

---

## `create-vm.json` — UI manifest

Manifest describing arguments collected by the orchestration UI before
running the script. Conforms to `script-manifest.schema.json`.

Fields: `VM_ID` (integer), `VM_NAME` (string), `MODE` (select:
`bare`/`docker`/`swarm`/`init-swarm`/`join-swarm`), `STORAGE`,
`DISK_SIZE`, `CORES`, `MEMORY`, `BRIDGE`, `CLOUD_IMG_NAME`,
`CLOUD_IMG_URL`, `MANAGER_IP`, `JOIN_TOKEN`, `JOIN_AS_MANAGER`,
`POOL_OVERLAY`, `NODE_LABELS`.

The `command` field rewrites `MODE` to flags via a `case`, adds
`--as-manager` if requested, then runs `create-vm.sh` with all the
named env vars.

---

## Pipeline (use cases)

### Case A — Single-node Docker VM

```bash
mkdir -p /root/vm && cd /root/vm && \
  curl -fsSL -o create-vm.sh "$BASE/create-vm.sh" && chmod +x create-vm.sh && \
  ./create-vm.sh 100 agflow-prod --docker
```

### Case B — Docker Swarm cluster (no IPVS workaround needed)

```bash
# 1) First manager
./create-vm.sh 200 ag-swarm-mgr --init-swarm

WORKER_TOKEN=$(jq -r .worker_token /root/.ssh/vm-keys/swarm-tokens-vm200.json)
MANAGER_IP=$(jq -r .manager_ip /root/.ssh/vm-keys/swarm-tokens-vm200.json)

# 2) Worker
./create-vm.sh 201 ag-worker-1 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$WORKER_TOKEN"

# 3) Additional manager (HA)
MANAGER_TOKEN=$(jq -r .manager_token /root/.ssh/vm-keys/swarm-tokens-vm200.json)
./create-vm.sh 202 ag-mgr-2 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$MANAGER_TOKEN" --as-manager
```

> ✅ Unlike LXC, your `docker-compose.yml` files do **not** need
> `mode: host` or `endpoint_mode: dnsrr`. Default `ingress` and VIP
> work as expected.

---

## Variables (summary)

| Var | Role |
|---|---|
| `VMID` (arg 1) | VM ID |
| `VM_NAME` (arg 2) | hostname (default `agflow-vm`) |
| `--docker`, `--swarm`, `--init-swarm`, `--join-swarm` | operating mode |
| `--manager-ip`, `--token`, `--as-manager` | join-swarm params |
| `CORES`, `MEMORY`, `DISK_SIZE`, `STORAGE`, `BRIDGE`, `SAFETY_MARGIN_GB`, `SSH_KEY_DIR`, `SSH_BOOT_TIMEOUT` | resources / boot |
| `CLOUD_IMG_DIR`, `CLOUD_IMG_NAME`, `CLOUD_IMG_URL` | cloud-init image |
| `LIVE_RESTORE`, `DOCKER_ADDR_POOL`, `DOCKER_ADDR_POOL_SIZE`, `MIN_FREE_MB` | Docker tuning |
| `POOL_OVERLAY`, `POOL_MASK`, `NODE_LABELS`, `TOKEN_DIR`, `FORCE`, `AUTO_FIX` | init-swarm |
| `ADVERTISE_ADDR`, `LISTEN_ADDR`, `FORCE_LEAVE` | join-swarm |

---

## Troubleshooting

### Guest agent never starts (timeout 180s)

Cause: cloud-init didn't run, or qemu-guest-agent is not in the
chosen image. Check via the serial console:

```bash
qm terminal <VMID>
```

Use Ubuntu cloud-init images (qemu-guest-agent preinstalled and
enabled). Generic ISOs without cloud-init won't work with this
script.

### SSH never connects after boot (timeout)

Cause: cloud-init didn't inject the SSH key. Common reasons:
- `--sshkeys` was not applied (try
  `qm set <VMID> --sshkeys /root/.ssh/vm-keys/id_ed25519_vm<VMID>.pub`
  and reboot)
- the `ide2` cloud-init drive is missing
  (`qm config <VMID> | grep ide2`)
- the `ciuser` is not `root`
  (`qm config <VMID> | grep ciuser`)

### IP not detected via guest agent

The DHCP lease may take more than 120s on slow networks. Increase
the timeout by editing the `120` constant in `create-vm.sh`, or
force a static IP via `qm set <VMID> --ipconfig0 ip=<IP>/CIDR,gw=<GW>`
before running the script in reconfigure mode.
