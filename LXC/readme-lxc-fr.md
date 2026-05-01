# LXC — Provisioning & Déploiement

Scripts pour provisionner des **containers LXC Proxmox** prêts pour
Docker / Docker Swarm, installer un collecteur de logs Grafana Alloy,
et déployer la stack **ag.flow** sur le LXC de production.

> 🇬🇧 For the English version, see [readme-lxc.md](readme-lxc.md).
> 🖥️ Pour la version VM (Proxmox QEMU), voir [readme-vm-fr.md](readme-vm-fr.md).

> **Tous les scripts sont publiés** dans ce repo
> (`https://github.com/Configurations/Proxmox`, branche `main`). Les
> commandes ci-dessous les téléchargent à la volée depuis GitHub raw —
> pas besoin de cloner.

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"
```

Trois cibles d'exécution — chaque script précise dans son en-tête où
il doit tourner :

| Cible | Scripts |
|---|---|
| Hôte Proxmox (root) | `create-lxc.sh` |
| Dans le LXC (root) | `03-install-alloy.sh` |
| Poste local (via alias SSH `pve`) | `deploy-alloy-all.sh` |

---

## `create-lxc.sh` *(hôte Proxmox)* — point d'entrée principal

Un script unique autonome qui **crée ou reconfigure** un LXC privileged
Docker-ready et, selon les flags, installe Docker, prépare Swarm,
initialise un cluster ou en rejoint un. Remplace les anciens
`00-create-lxc.sh` + `00-create-lxc-swarm.sh` + `01-install-docker.sh`
+ `02-init-swarm.sh` + `02-join-swarm.sh`.

### Modes & flags

| Flag | Effet |
|---|---|
| *(aucun)* | LXC nu — pas de Docker, pas de permissions Swarm dans la conf LXC |
| `--docker` | Installe Docker + permissions LXC (apparmor unconfined, cgroup2, mount, /sys/kernel/security) |
| `--swarm` | Prépare le LXC swarm-ready (modules kernel hôte, `/dev/net/tun`, sysctls, tag `swarm-ready`) |
| `--init-swarm` | Initialise un nouveau cluster Swarm (implique `--docker` + `--swarm`) |
| `--join-swarm --manager-ip <IP> --token <TOKEN> [--as-manager]` | Rejoint un cluster existant (implique `--docker` + `--swarm`) |

`--init-swarm` et `--join-swarm` sont mutuellement exclusifs.

### Comportements automatiques

- **Détection auto du mode** — container absent → création; container
  existant → reconfiguration (backup de la conf, conversion
  `unprivileged → privileged` avec remapping UID/GID
  `100000-165535 → 0-65535` si nécessaire).
- **Sélection storage** (`STORAGE=auto` par défaut) — tableau de bord
  des storages compatibles rootfs, choix de celui avec le plus
  d'espace libre, vérification **avant** `pct create`, refus si pas
  assez (suggère une alternative). Marge ajustable via
  `SAFETY_MARGIN_GB=5`.
- **Détection auto du template Ubuntu** — `ubuntu-24` d'abord, fallback
  `ubuntu-22`.
- **Vérification Docker post-install** — échec clair si l'install
  s'est plantée en cours de route (ex : pool saturé).
- **Auto-fix live-restore** — `--init-swarm` détecte et corrige
  `live-restore=true` (incompatible Swarm) si `AUTO_FIX=1` (défaut).
- **Sortie JSON** — un seul bloc final agrégé :
  `{"status", "exit_code", "machine":{...}, "docker":{...}, "swarm":{...}}`.
  Bloc `docker` présent uniquement avec `--docker`, bloc `swarm`
  uniquement avec `--init-swarm`/`--join-swarm`.

### Artefacts générés

- Paire de clefs SSH ed25519 stockée sur l'hôte :
  `/root/.ssh/lxc-keys/id_ed25519_lxc<CTID>` (root) +
  `/root/.ssh/lxc-keys/id_ed25519_agflow_lxc<CTID>` (`agflow`).
- Utilisateur `agflow` (sudo NOPASSWD, mot de passe aléatoire 24
  caractères, membre du groupe `docker` quand `--docker` est actif).
- Pour `--init-swarm` : tokens persistés dans
  `/root/.ssh/lxc-keys/swarm-tokens-<CTID>.json` (chmod 600).

### Variables (défauts)

| Var | Défaut | Rôle |
|---|---|---|
| `CORES` | `4` | cœurs CPU |
| `MEMORY` | `8192` | RAM (MB) |
| `SWAP` | `1024` | swap (MB) |
| `DISK_SIZE` | `30` | rootfs (GB) |
| `STORAGE` | `auto` | pool rootfs (ou pool nommé) |
| `BRIDGE` | `vmbr0` | bridge réseau |
| `SAFETY_MARGIN_GB` | `5` | marge libre minimale dans le pool |
| `SSH_KEY_DIR` | `/root/.ssh/lxc-keys` | dossier des clefs SSH |
| `LIVE_RESTORE` | `0` | Docker live-restore (0=false, compatible Swarm) |
| `DOCKER_ADDR_POOL` | `172.30.0.0/16` | pool d'IPs des bridges Docker |
| `POOL_OVERLAY` | `10.20.0.0/16` | pool overlay Swarm (init-swarm) |
| `POOL_MASK` | `24` | taille des sous-réseaux overlay |
| `NODE_LABELS` | `role=control,tenant=agflow` | labels du node Swarm |
| `FORCE` | `0` | reset du Swarm avant re-init (**destructif**) |
| `FORCE_LEAVE` | `no` | quitte le Swarm courant avant join |
| `AUTO_FIX` | `1` | corrige automatiquement `live-restore=true` |

### Pré-requis (création)

Un template Ubuntu disponible localement :

```bash
pveam update && pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

### Exemples

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

# 1) LXC nu (juste provisionné, pas de Docker)
mkdir -p /root/lxc && cd /root/lxc && \
  curl -fsSL -o create-lxc.sh "$BASE/create-lxc.sh" && chmod +x create-lxc.sh && \
  ./create-lxc.sh 200 ag-base

# 2) LXC + Docker
./create-lxc.sh 201 ag-docker --docker

# 3) Manager Swarm (init d'un nouveau cluster)
./create-lxc.sh 300 ag-swarm-mgr --init-swarm

# 4) Worker rejoignant un cluster existant
./create-lxc.sh 301 ag-worker-1 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-xxxxxxxxx

# 5) Manager additionnel (HA)
./create-lxc.sh 302 ag-mgr-2 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-yyyyyyyyy \
    --as-manager

# 6) Tuning ressources + storage
STORAGE=extended-lvm DISK_SIZE=80 CORES=8 MEMORY=16384 \
    ./create-lxc.sh 400 ag-data --init-swarm
```

---

## `create-lxc.json` — manifeste UI

Manifeste qui décrit les arguments collectés par l'UI d'orchestration
avant l'exécution du script. Conforme à
`script-manifest.schema.json`.

Champs : `LXC_ID` (integer), `LXC_NAME` (string), `MODE` (select:
`bare`/`docker`/`swarm`/`init-swarm`/`join-swarm`), `STORAGE`,
`DISK_SIZE`, `CORES`, `MEMORY`, `SWAP`, `BRIDGE`, `MANAGER_IP`,
`JOIN_TOKEN`, `JOIN_AS_MANAGER`, `POOL_OVERLAY`, `NODE_LABELS`.

Le champ `command` traduit `MODE` en flags via un `case`, ajoute
`--as-manager` si demandé, puis lance `create-lxc.sh` avec toutes les
variables d'environnement nommées.

---

## Scripts auxiliaires (côté LXC, inchangés)

### `03-install-alloy.sh` *(dans le LXC, root)*

Installe **Grafana Alloy** comme collecteur de logs (Docker +
journald) qui pousse vers Loki. Auto-détection :

- Docker présent → `docker-compose.yml` (image `grafana/alloy`,
  fichiers attendus dans `/tmp/alloy-agent/`)
- Docker absent → paquet Debian + service systemd, conf dans
  `/etc/alloy/config.alloy`

**Env requises** : `LOKI_URL`, `HOSTNAME` (label `host` du LXC).

```bash
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc201" \
    bash -c "$(curl -fsSL "$BASE/03-install-alloy.sh")"
```

### `deploy-alloy-all.sh` *(poste local)*

Déploie Alloy sur **tous** les LXCs actifs du homelab via l'hôte
Proxmox (alias SSH `pve`) utilisé comme bastion. Suppose le repo
**ag.flow** cloné (chemins `../..`).

| Var | Défaut |
|---|---|
| `PVE_HOST` | `pve` |
| `LOKI_URL` | *(requis)* |
| `LXC_HOSTS` | `101 102 108 111 112 113 114 115 116 117 201` |

### `Caddyfile.prod`, `.env.prod.example`, `.env.deploy`

Configuration Caddy de prod + templates env pour la stack **ag.flow**
sur le LXC 203. `Caddyfile.prod` écoute sur `:80` (TLS upstream via
Cloudflare Tunnel), reverse-proxy `/api/*` vers le backend `:8000` et
sert le SPA depuis `/opt/agflow/frontend/dist`. `.env.deploy` doit
être **gitignoré** (contient `KEYCLOAK_CLIENT_SECRET`).

---

## Pipeline (cas d'usage)

### Cas A — LXC Docker mono-node (stack ag.flow prod)

```bash
# 1) Provisionner le LXC + Docker
mkdir -p /root/lxc && cd /root/lxc && \
  curl -fsSL -o create-lxc.sh "$BASE/create-lxc.sh" && chmod +x create-lxc.sh && \
  ./create-lxc.sh 203 agflow-prod --docker

# 2) (optionnel) Collecteur Alloy dans le LXC
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc203" \
    bash -c "$(curl -fsSL "$BASE/03-install-alloy.sh")"

# 3) Depuis le poste local, dans le repo ag.flow cloné
./infra/deploy.sh
```

### Cas B — Cluster Docker Swarm

```bash
# 1) Premier manager
./create-lxc.sh 300 ag-swarm-mgr --init-swarm

# Les tokens sont persistés dans /root/.ssh/lxc-keys/swarm-tokens-300.json
WORKER_TOKEN=$(jq -r .worker_token /root/.ssh/lxc-keys/swarm-tokens-300.json)
MANAGER_IP=$(jq -r .manager_ip /root/.ssh/lxc-keys/swarm-tokens-300.json)

# 2) Worker
./create-lxc.sh 301 ag-worker-1 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$WORKER_TOKEN"

# 3) Manager additionnel (HA)
MANAGER_TOKEN=$(jq -r .manager_token /root/.ssh/lxc-keys/swarm-tokens-300.json)
./create-lxc.sh 302 ag-mgr-2 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$MANAGER_TOKEN" --as-manager
```

---

## ⚠️ Limitations — IPVS en LXC privileged

Le routing mesh de Docker Swarm et les VIPs de service utilisent
**IPVS** dans un namespace réseau caché. En LXC privileged, les règles
IPVS sont correctement installées mais **le forwarding ne traverse pas
correctement le namespace imbriqué**. Conséquence : tout trafic TCP
qui passe par une VIP Swarm timeout silencieusement. ICMP marche, TCP
non.

### 1. Routing mesh ingress

Le port publishing par défaut (`mode: ingress`) est cassé en LXC. Le
service est `Up X minutes (healthy)` mais `curl localhost:<port>`
timeout.

**Workaround — `mode: host` sur chaque port publié** :

```yaml
ports:
  - target: 8080
    published: 8080
    mode: host        # contourne l'ingress, fonctionne en LXC
```

Trade-off : pas de load-balancing entre les nodes, le port est publié
sur le node qui héberge le replica.

### 2. VIP de service (trafic inter-services)

Même sur le même overlay, `nc -zv postgres 5432` timeout quand on
passe par la VIP. Le DNS résout, ICMP marche, mais TCP non.

**Workaround — `endpoint_mode: dnsrr` obligatoire sur chaque service** :

```yaml
services:
  postgres:
    image: postgres:16-alpine
    deploy:
      replicas: 1
      endpoint_mode: dnsrr   # ← OBLIGATOIRE en LXC, sinon timeout TCP
```

### Vrai fix

**Migrer vers une VM Proxmox** — voir [`readme-vm-fr.md`](readme-vm-fr.md)
et le script `create-vm.sh` associé. Le routing mesh Swarm fonctionne
correctement en VM (kernel propre, IPVS natif). Garder le LXC est un
trade-off explicite pour économiser les ressources du homelab.

---

## Variables (résumé)

| Var | Rôle |
|---|---|
| `CTID` (arg 1) | ID du container |
| `CT_NAME` (arg 2) | hostname (défaut `agflow-docker`) |
| `--docker`, `--swarm`, `--init-swarm`, `--join-swarm` | mode opératoire |
| `--manager-ip`, `--token`, `--as-manager` | params join-swarm |
| `CORES`, `MEMORY`, `SWAP`, `DISK_SIZE`, `STORAGE`, `BRIDGE`, `SAFETY_MARGIN_GB`, `SSH_KEY_DIR` | ressources |
| `LIVE_RESTORE`, `DOCKER_ADDR_POOL`, `DOCKER_ADDR_POOL_SIZE`, `MIN_FREE_MB` | tuning Docker |
| `POOL_OVERLAY`, `POOL_MASK`, `NODE_LABELS`, `TOKEN_DIR`, `FORCE`, `AUTO_FIX` | init-swarm |
| `ADVERTISE_ADDR`, `LISTEN_ADDR`, `FORCE_LEAVE` | join-swarm |
| `LOKI_URL`, `HOSTNAME` | `03-install-alloy.sh` |
| `PVE_HOST`, `LXC_HOSTS` | `deploy-alloy-all.sh` |
| `KEYCLOAK_CLIENT_SECRET` | `deploy.sh` (via `.env.deploy`) |
