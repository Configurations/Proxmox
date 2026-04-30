# LXC — Provisioning & Deployment

Scripts to provision Proxmox LXC containers ready for Docker, install a Grafana
Alloy log collector, and deploy the **ag.flow** stack on the production LXC.

> **All scripts are published** in this repo
> (`https://github.com/Configurations/Proxmox`, `main` branch). The
> commands below download them on the fly from GitHub raw — no need to
> clone.

```bash
# Base URL used everywhere:
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"
```

Three execution targets — each script states in its header where it
should run:

| Target | Scripts |
|---|---|
| Proxmox host (root) | `00-create-lxc.sh`, `00-create-lxc-swarm.sh`, `02-init-swarm.sh` |
| Inside the LXC (root) | `01-install-docker.sh`, `02-install-alloy.sh` |
| Local workstation (via SSH alias `pve`) | `deploy.sh`, `deploy-alloy-all.sh` |

---

## Files

### `00-create-lxc.sh` *(Proxmox host)*

Creates **or** reconfigures a Docker-ready privileged LXC container.
Automatically detects the mode:

- container missing → **creation** from an Ubuntu template
  (`ubuntu-24` then fallback `ubuntu-22`)
- container exists → **reconfiguration** (config backup, conversion
  unprivileged → privileged with UID/GID remapping 100000-165535 → 0-65535)

Applies Docker-ready config (AppArmor unconfined, `nesting=1`,
`keyctl=1`, `cgroup2.devices.allow: a`, mounting `/sys/kernel/security`),
configures DHCP on `eth0`, generates an ed25519 SSH key pair stored
on the host (`/root/.ssh/lxc-keys/id_ed25519_lxc<CTID>`), installs
`openssh-server`, creates the **`agflow`** user (sudo NOPASSWD, random
24-char password, dedicated SSH key), and chains to
`01-install-docker.sh` if found **in the same folder**.

Final output as JSON (CTID, IP, distro, user, password, SSH key,
Docker version).

> ⚠️ The script looks for `01-install-docker.sh` in its own directory
> (`SCRIPT_DIR`). The one-liner below downloads **both** files together
> in `/root/lxc/` and then runs the creation.

**Overridable variables**: `CORES=4`, `MEMORY=8192`, `SWAP=1024`,
`DISK_SIZE=30`, `STORAGE=local-lvm`, `BRIDGE=vmbr0`,
`SSH_KEY_DIR=/root/.ssh/lxc-keys`.

**Prerequisites (creation)** — an Ubuntu template available:

```bash
pveam update && pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

**Run (one-liner, on the Proxmox host as root)** — replace `<CTID>` and `<hostname>`:

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc.sh <CTID> <hostname>
```

With custom resources (prefix the variables):

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && CORES=8 MEMORY=16384 DISK_SIZE=60 ./00-create-lxc.sh 201 agflow-prod
```

### `00-create-lxc-swarm.sh` *(Proxmox host)*

Superset of `00-create-lxc.sh` adding:

- **Automatic storage selection** (`STORAGE=auto` by default):
  displays a dashboard of all storages usable for rootfs, picks the
  one with the most free space, checks available space **before**
  `pct create` and refuses if insufficient (suggesting an alternative).
  Adjustable safety margin via `SAFETY_MARGIN_GB=5`.
- **Post-install Docker check**: fails clearly if the install failed
  midway (e.g. saturated pool).
- **`--swarm` flag**: prepares the LXC to be a Docker Swarm node
  - loads kernel modules `ip_vs` / `overlay` on the host (idempotent)
  - adds `/dev/net/tun` to the container (needed for VXLAN)
  - configures network sysctls inside the container
  - tags the container `swarm-ready`

The Swarm init itself (`docker swarm init`) is done via the separate
`02-init-swarm.sh` script (see below).

**Usage**: `./00-create-lxc-swarm.sh <CTID> [hostname] [--swarm]`

**Overridable variables** (in addition to those of `00-create-lxc.sh`):
`STORAGE=auto` (default, vs. `local-lvm` for `00-create-lxc.sh`),
`SAFETY_MARGIN_GB=5`.

**One-liner — single Docker node**:

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc-swarm.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc-swarm.sh <CTID> <hostname>
```

**One-liner — Swarm node** (optionally forcing a storage):

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc-swarm.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && STORAGE=extended-lvm DISK_SIZE=50 ./00-create-lxc-swarm.sh 201 agflow-swarm-mgr --swarm
```

### `02-init-swarm.sh` *(Proxmox host)*

Initializes the **first manager** of a Docker Swarm cluster on a
`swarm-ready` LXC (created via `00-create-lxc-swarm.sh ... --swarm`).
Idempotent — refuses if Swarm is already active unless `FORCE=1`
(destructive).

Steps:

1. **Pre-checks** — LXC exists, running, tag `swarm-ready`,
   `/dev/net/tun` present, Docker operational, Swarm not already active.
2. **Advertise IP detection** — auto via the LXC's `eth0` (override with
   `ADVERTISE_ADDR`), validation ping from the host.
3. **Overlay pool check** — alerts on overlap with the LXC's subnet
   (asks for interactive confirmation).
4. **`docker swarm init`** — `--advertise-addr`, `--listen-addr :2377`,
   `--default-addr-pool` (default `10.20.0.0/16` mask /24, chosen to
   avoid conflicts with LAN 192.168/10.x and with the Docker bridge
   pool `172.20.0.0/16` of `01-install-docker.sh`).
5. **Token retrieval** worker + manager → JSON saved in
   `/root/.ssh/lxc-keys/swarm-tokens-<CTID>.json` (chmod 600).
6. **Node labels** — default `role=control,tenant=agflow`.

Final output as JSON (CTID, manager IP, port 2377, hostname, pool,
labels, tokens file path) + `docker swarm join` commands to copy
to add workers/managers.

**Usage**: `./02-init-swarm.sh <CTID>`

**Overridable variables**:

| Var | Default | Role |
|---|---|---|
| `ADVERTISE_ADDR` | auto (LXC's eth0) | force the manager's advertise IP |
| `POOL_OVERLAY` | `10.20.0.0/16` | IP pool for overlay networks |
| `POOL_MASK` | `24` | size of the subnets carved out of the pool |
| `NODE_LABELS` | `role=control,tenant=agflow` | Swarm node labels (CSV) |
| `TOKEN_DIR` | `/root/.ssh/lxc-keys` | where tokens are saved |
| `FORCE` | `0` | if `1`, `swarm leave --force` then re-init (**destructive**) |

**Run (one-liner, on the Proxmox host as root)** — replace
`<CTID>` with the CTID of the future first manager:

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 02-init-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-init-swarm.sh && chmod +x 02-init-swarm.sh && ./02-init-swarm.sh <CTID>
```

With a custom overlay pool:

```bash
POOL_OVERLAY=172.30.0.0/16 ./02-init-swarm.sh 300
```

> ⚠️ The script references a future `03-join-swarm.sh <CTID_worker>
> <CTID_manager>` to add workers automatically — it is not yet present
> in this folder. Meanwhile, use the `docker swarm join --token ...`
> command displayed by the final summary (or read from
> `swarm-tokens-<CTID>.json`).

### `01-install-docker.sh` *(inside the LXC, root)*

Installs Docker Engine + Compose v2 + buildx, then Caddy as reverse
proxy. Configures `/etc/docker/daemon.json` for production
(`json-file` log driver 10MB×3, `default-address-pools 172.20.0.0/16`,
`storage-driver overlay2`, `live-restore: true`). Caddy listens on `:80`
in HTTP — TLS handled by Cloudflare Tunnel upstream. Default Caddyfile
returns a 404 until a domain is added.

Called automatically by `00-create-lxc.sh`. To run it standalone,
**inside the LXC as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh)"
```

Or **from the Proxmox host** (push & exec — replace `<CTID>`):

```bash
curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh -o /tmp/01.sh && pct push <CTID> /tmp/01.sh /root/01.sh && pct exec <CTID> -- bash /root/01.sh
```

### `02-install-alloy.sh` *(inside the LXC, root)*

Installs **Grafana Alloy** as log collector (Docker + journald)
pushing to Loki. Automatic detection:

- Docker present → deployment via `docker-compose.yml` (image
  `grafana/alloy`, expected files in `/tmp/alloy-agent/`)
- Docker absent → Debian package + systemd service, config in
  `/etc/alloy/config.alloy`, env in `/etc/default/alloy`

**Required environment variables**:

| Var | Description |
|---|---|
| `LOKI_URL` | Loki endpoint, e.g. `http://192.168.10.<IP_LXC116>:3100/loki/api/v1/push` |
| `HOSTNAME` | LXC `host` label (default: `hostname`) |

**Prerequisites**: `/tmp/alloy-agent/` must contain `docker-compose.yml`,
`config.alloy`, `config-journald-only.alloy` (these files are not in
this folder — they live in `infra/alloy-agent/` of the **ag.flow**
repo, to be pushed beforehand via `pct push` or `scp`).

**Run (one-liner, inside the LXC as root)** once configs are in
place — replace `<LOKI_IP>` and `<HOSTNAME>`:

```bash
LOKI_URL="http://<LOKI_IP>:3100/loki/api/v1/push" HOSTNAME="<HOSTNAME>" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"
```

Concrete example:

```bash
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc201" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"
```

### `deploy-alloy-all.sh` *(local workstation)*

Deploys Alloy on **all** active homelab LXCs via the Proxmox host
(SSH alias `pve`) used as a bastion. For each CTID: checks that the
LXC is `running`, copies `infra/alloy-agent/*` + `02-install-alloy.sh`
via `pct push`, runs the script with `LOKI_URL` and
`HOSTNAME=lxc<CTID>`.

> ⚠️ This script assumes a tree `infra/alloy-agent/` +
> `scripts/infra/02-install-alloy.sh` at the root of the **ag.flow**
> repo (paths `../..`) — it does not work standalone from a simple
> download. Clone the ag.flow repo, or adapt the paths at the top of
> the script.

**Variables**:

| Var | Default |
|---|---|
| `PVE_HOST` | `pve` (Proxmox host SSH alias) |
| `LOKI_URL` | *(required)* |
| `LXC_HOSTS` | `101 102 108 111 112 113 114 115 116 117 201` |

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

# Download (place at the location the script expects):
curl -fsSL -o ./deploy-alloy-all.sh "$BASE/deploy-alloy-all.sh"
chmod +x ./deploy-alloy-all.sh

# All LXCs:
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" \
  ./deploy-alloy-all.sh

# Subset:
LXC_HOSTS="201 102" \
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" \
  ./deploy-alloy-all.sh
```

### `deploy.sh` *(local workstation)*

Deploys the **ag.flow** stack on LXC 203 (`192.168.10.84`) via `pve`
as a bastion. Workflow:

1. Build the frontend locally (`npm ci` if needed, then `npm run build`)
2. Tar the repo → `ssh pve` → untar in `/tmp/agflow-deploy/`
   (excludes `.git`, `node_modules`, `.venv`, caches, `.env*`)
3. `rsync` from `pve` to `LXC 203:/opt/agflow/`
4. On the LXC: generate `.env.prod` on first deploy
   (`POSTGRES_PASSWORD`, `SESSION_COOKIE_SECRET` auto), copy
   `Caddyfile.prod` to `/etc/caddy/Caddyfile`, `systemctl reload caddy`,
   `docker compose -f docker-compose.prod.yml up -d --build`,
   healthcheck `http://127.0.0.1:8000/health`
5. Cleanup of the staging on `pve`

> ⚠️ This script does **not** run standalone: it operates on the
> entire **ag.flow** repo (frontend, `docker-compose.prod.yml`, etc.).
> Clone the ag.flow repo then run `./infra/deploy.sh` (or equivalent
> depending on your tree). Direct download from GitHub raw makes no
> sense here.

**Prerequisites**:

- SSH alias `pve` in `~/.ssh/config`
- on `pve`: key `/root/.ssh/lxc-keys/id_ed25519_lxc203`
  (generated by `00-create-lxc.sh`)
- locally: `node` + `npm` (frontend build)
- file `infra/.env.deploy` (gitignored) with
  `KEYCLOAK_CLIENT_SECRET=...`

```bash
# From the root of the locally cloned ag.flow repo:
./deploy.sh
# → https://workflow-agflow.yoops.org
```

### `Caddyfile.prod`

Production Caddy configuration for LXC 203. Listens on HTTP at `:80`
(TLS handled by Cloudflare Tunnel):

- `/api/*` → `reverse_proxy 127.0.0.1:8000` (with headers
  `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto https`)
- `/health` → backend (monitoring)
- everything else → static files `/opt/agflow/frontend/dist` with
  fallback `try_files {path} /index.html` (SPA React Router)
- `zstd gzip` compression, security headers (CSP, X-Frame-Options DENY,
  X-Content-Type-Options nosniff, Referrer-Policy)

Copied automatically by `deploy.sh`; for a manual reload on the LXC:

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

curl -fsSL -o /etc/caddy/Caddyfile "$BASE/Caddyfile.prod"
systemctl reload caddy
```

### `.env.prod.example`

Template to copy as `/opt/agflow/.env.prod` on LXC 203
(`POSTGRES_PASSWORD`, `KEYCLOAK_*`, `SESSION_COOKIE_SECRET`,
`AGFLOW_PUBLIC_BASE_URL`, `LOG_LEVEL`). In practice, `deploy.sh`
generates it automatically on first run.

```bash
curl -fsSL -o .env.prod "$BASE/.env.prod.example"
# then fill POSTGRES_PASSWORD, KEYCLOAK_CLIENT_SECRET, SESSION_COOKIE_SECRET
```

### `.env.deploy`

Variable consumed by `deploy.sh` (`KEYCLOAK_CLIENT_SECRET`).

> ⚠️ **Security**: this file is supposed to be gitignored
> (`# NEVER COMMIT`) but is currently published in the repo with a
> cleartext secret. Move it outside the repo and rotate it on the
> Keycloak side before any sharing.

---

## Complete pipeline (use cases)

### Case A — Single-node Docker LXC (ag.flow prod stack)

```bash
# 1) On the Proxmox host, as root — provision LXC + Docker (one-liner):
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc.sh 203 agflow-prod

# 2) (optional) Inside the LXC, as root — enable the Alloy collector:
#    (the /tmp/alloy-agent configs must be copied beforehand)
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc203" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"

# 3) From the local workstation, in the cloned ag.flow repo — deploy the stack:
./infra/deploy.sh
```

### Case B — Docker Swarm cluster (first manager)

```bash
# 1) On the Proxmox host, as root — provision swarm-ready LXC + Docker:
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc-swarm.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc-swarm.sh 300 agflow-swarm-mgr --swarm

# 2) Still on the Proxmox host — initialize the first Swarm manager:
curl -fsSL -o /root/lxc/02-init-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-init-swarm.sh && chmod +x /root/lxc/02-init-swarm.sh && /root/lxc/02-init-swarm.sh 300

# 3) To add other nodes: create each LXC with --swarm, then
#    grab the join command from /root/.ssh/lxc-keys/swarm-tokens-300.json
#    and run it inside the worker LXC (via pct exec).
```

## Limitations

### 1. Swarm routing mesh in privileged LXC: IPVS does not forward correctly (ingress)

When you publish a port with the default `mode: ingress` in a Swarm
stack, requests stay stuck and end up timing out — even though the
service is `Running` and the container responds correctly to its
internal HTTP healthcheck.

**Symptoms:**
- `docker service ls` shows `1/1` replicas
- `docker ps` shows the container `Up X minutes (healthy)`
- `curl localhost:<port>` times out
- Pinging the container's IP works (ICMP), but TCP connections do not succeed

**Root cause:**
Docker Swarm's routing mesh uses IPVS (IP Virtual Server) in a hidden
network namespace called `ingress_sbox`. In a privileged LXC container,
the IPVS rules are correctly created (verifiable with
`nsenter --net=/var/run/docker/netns/ingress_sbox ipvsadm -L -n`), but
the forwarding through the VXLAN overlay network does not correctly
traverse the nested namespace. Result: connections show up as
`ActiveConn` in IPVS but never reach the target container.

This is a kernel interaction between LXC namespaces and IPVS that
does not happen on bare-metal or in a VM.

**Workaround: use `mode: host` for published ports**

In your `docker-compose.yml` for Swarm stacks, change:

```yaml
ports:
  - target: 8080
    published: 8080
    mode: ingress    # default — broken in LXC
```

to:

```yaml
ports:
  - target: 8080
    published: 8080
    mode: host       # bypasses the routing mesh, works in LXC
```

**Trade-off:** with `mode: host`, the port is published directly on
the node where the container runs, with no load balancing across
nodes. For a single-node Swarm (1 LXC = 1 node), it's equivalent.
For a multi-node Swarm, you lose the ability to reach a service from
any node — you have to hit the IP of the specific node hosting the
replica.

### 2. Swarm inter-service routing in privileged LXC: IPVS does not forward internally either

Beyond the ingress issue described above, **the same IPVS bug also
affects inter-service Swarm traffic** on overlay networks. When a
service tries to reach another service by name (Swarm DNS), the
resolution returns a **VIP (Virtual IP)** which must be forwarded via
IPVS to the container's real IP — and this forwarding fails silently
in LXC.

**Symptoms:**
- Postgres deployed as a Swarm service, healthy locally
  (`docker exec postgres pg_isready` returns OK)
- Another service on the same overlay tries to connect via
  `host=postgres`: TCP timeout
- DNS resolves correctly (`getent hosts postgres` returns an IP)
- `ping` toward this IP works (ICMP)
- But `nc -zv postgres 5432` times out
- Directly on the container's real IP (not the VIP), the connection works

**Reproducible diagnostic:**

```bash
# See container IP vs service VIP
docker network inspect <network> --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}'
# Example: postgres_postgres.1.xxx : 10.20.2.3/24

docker service inspect <service> --format '{{json .Endpoint}}'
# Example: {"Spec":{"Mode":"vip"},"VirtualIPs":[{"Addr":"10.20.2.2/24"}]}

# Test from another container
docker run --rm --network <network> alpine sh -c "nc -zv 10.20.2.2 5432"   # VIP: timeout
docker run --rm --network <network> alpine sh -c "nc -zv 10.20.2.3 5432"   # Real IP: OK
```

**Root cause:**
Same as the previous limitation — IPVS does not work in a privileged
LXC namespace. This time the issue does not affect the LAN ingress
port, but the **service VIP** created by default for each Swarm
service on its overlay networks.

**Mandatory workaround: `endpoint_mode: dnsrr` on every service**

With DNSRR (DNS Round Robin) mode, Swarm no longer creates a VIP. DNS
resolves directly to the IPs of the service's containers, with no
IPVS in the chain.

```yaml
services:
  postgres:
    image: postgres:16-alpine
    # ...
    deploy:
      mode: replicated
      replicas: 1
      endpoint_mode: dnsrr   # ← MANDATORY in LXC, otherwise TCP timeout
      placement:
        constraints:
          - node.role == manager
```

**Trade-off:** with DNSRR on a multi-replica service, the client must
handle round-robin itself (most HTTP, gRPC, asyncpg libs do this
natively). For `replicas: 1`, no practical difference.

**Practical rule:** **all** Swarm services deployed in these LXCs
must use `endpoint_mode: dnsrr`. To be added in every compose, no
exception. Document it in the compose for the future
(`# MANDATORY in LXC: IPVS workaround`).

**To diagnose a new service that fails to reach another:**

```bash
# 1. Check the service mode
docker service inspect <service> --format '{{.Spec.EndpointSpec.Mode}}'
# If "vip" or empty -> needs to switch to dnsrr

# 2. Compare DNS resolution and real IPs
docker run --rm --network <network> alpine sh -c \
    "getent hosts <service_name>; ping -c 2 <service_name>"
docker network inspect <network> --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}'
```

### Real fix for both IPVS limitations

Migrate to a Proxmox VM instead of an LXC. Swarm's routing mesh
(ingress + overlay VIP) works correctly in a VM. Keeping the LXC is
an explicit trade-off to save homelab resources.

## Environment variables (summary)

| Var | Script | Role |
|---|---|---|
| `CTID` (arg 1) | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` | container ID |
| `CT_NAME` (arg 2) | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` | hostname (default `agflow-docker`) |
| `--swarm` (flag) | `00-create-lxc-swarm.sh` | enables Swarm node prep |
| `CORES`, `MEMORY`, `SWAP`, `DISK_SIZE` | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` | resources |
| `STORAGE` | `00-create-lxc.sh` (default `local-lvm`) / `00-create-lxc-swarm.sh` (default `auto`) | rootfs storage pool |
| `BRIDGE` | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` | default `vmbr0` |
| `SAFETY_MARGIN_GB` | `00-create-lxc-swarm.sh` | min free margin in the pool (default 5) |
| `SSH_KEY_DIR` | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` | default `/root/.ssh/lxc-keys` |
| `ADVERTISE_ADDR` | `02-init-swarm.sh` | force the manager's advertise IP (default auto eth0) |
| `POOL_OVERLAY`, `POOL_MASK` | `02-init-swarm.sh` | default `10.20.0.0/16` mask /24 |
| `NODE_LABELS` | `02-init-swarm.sh` | default `role=control,tenant=agflow` |
| `TOKEN_DIR` | `02-init-swarm.sh` | default `/root/.ssh/lxc-keys` |
| `FORCE` | `02-init-swarm.sh` | if `1`, reset Swarm before init (**destructive**) |
| `LOKI_URL` | `02-install-alloy.sh`, `deploy-alloy-all.sh` | Loki endpoint |
| `HOSTNAME` | `02-install-alloy.sh` | host label |
| `PVE_HOST` | `deploy-alloy-all.sh` | SSH alias (default `pve`) |
| `LXC_HOSTS` | `deploy-alloy-all.sh` | list of CTIDs |
| `KEYCLOAK_CLIENT_SECRET` | `deploy.sh` (via `.env.deploy`) | OIDC |

---

🇫🇷 Pour la version française, voir [readme-fr.md](readme-fr.md).