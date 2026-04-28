# LXC — Provisionnement & déploiement

Scripts pour provisionner des containers LXC Proxmox prêts pour Docker, y
installer un collecteur de logs Grafana Alloy, et déployer la stack
**ag.flow** sur le LXC de production.

> **Tous les scripts sont publiés** dans ce repo
> (`https://github.com/Configurations/Proxmox`, branche `main`). Les
> commandes ci-dessous les téléchargent à la volée depuis GitHub raw —
> pas besoin de cloner.

```bash
# Base URL utilisée partout :
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"
```

Trois plans d'exécution — chaque script précise dans son en-tête où il
doit tourner :

| Cible | Scripts |
|---|---|
| Hôte Proxmox (root) | `00-create-lxc.sh`, `00-create-lxc-swarm.sh` |
| À l'intérieur du LXC (root) | `01-install-docker.sh`, `02-install-alloy.sh` |
| Poste local (via alias SSH `pve`) | `deploy.sh`, `deploy-alloy-all.sh` |

---

## Fichiers

### `00-create-lxc.sh` *(hôte Proxmox)*

Crée **ou** reconfigure un container LXC privileged prêt pour Docker.
Détecte automatiquement le mode :

- container inexistant → **création** depuis un template Ubuntu
  (`ubuntu-24` puis fallback `ubuntu-22`)
- container existant → **reconfiguration** (backup de la conf, conversion
  unprivileged → privileged avec remappage UID/GID 100000-165535 → 0-65535)

Applique la config Docker-ready (AppArmor unconfined, `nesting=1`,
`keyctl=1`, `cgroup2.devices.allow: a`, montage `/sys/kernel/security`),
configure DHCP sur `eth0`, génère une paire de clefs SSH ed25519 stockée
sur l'hôte (`/root/.ssh/lxc-keys/id_ed25519_lxc<CTID>`), installe
`openssh-server`, crée l'utilisateur **`agflow`** (sudo NOPASSWD, mot de
passe aléatoire 24 chars, clef SSH dédiée), et chaîne sur
`01-install-docker.sh` s'il est trouvé **dans le même dossier**.

Sortie finale en JSON (CTID, IP, distro, user, password, clef SSH,
version Docker).

> ⚠️ Le script cherche `01-install-docker.sh` dans son propre dossier
> (`SCRIPT_DIR`). Le one-liner ci-dessous télécharge donc les **deux**
> fichiers ensemble dans `/root/lxc/` puis lance la création.

**Variables surchargeables** : `CORES=4`, `MEMORY=8192`, `SWAP=1024`,
`DISK_SIZE=30`, `STORAGE=local-lvm`, `BRIDGE=vmbr0`,
`SSH_KEY_DIR=/root/.ssh/lxc-keys`.

**Pré-requis (création)** — un template Ubuntu disponible :

```bash
pveam update && pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

**Lancement (one-liner, sur l'hôte Proxmox en root)** — remplacer `<CTID>` et `<hostname>` :

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc.sh <CTID> <hostname>
```

Avec ressources personnalisées (préfixer les variables) :

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && CORES=8 MEMORY=16384 DISK_SIZE=60 ./00-create-lxc.sh 201 agflow-prod
```

### `00-create-lxc-swarm.sh` *(hôte Proxmox)*

Variante destinée à un nœud Swarm (mêmes paramètres et même
comportement). One-liner :

```bash
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc-swarm.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc-swarm.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc-swarm.sh <CTID> <hostname>
```

### `01-install-docker.sh` *(dans le LXC, root)*

Installe Docker Engine + Compose v2 + buildx, puis Caddy en reverse
proxy. Configure `/etc/docker/daemon.json` pour la production
(`json-file` log driver 10MB×3, `default-address-pools 172.20.0.0/16`,
`storage-driver overlay2`, `live-restore: true`). Caddy écoute sur `:80`
en HTTP — TLS géré par Cloudflare Tunnel en amont. Caddyfile par défaut
renvoie un 404 tant qu'aucun domaine n'est ajouté.

Appelé automatiquement par `00-create-lxc.sh`. Pour le lancer seul,
**dans le LXC en root** :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh)"
```

Ou **depuis l'hôte Proxmox** (push & exec — remplacer `<CTID>`) :

```bash
curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh -o /tmp/01.sh && pct push <CTID> /tmp/01.sh /root/01.sh && pct exec <CTID> -- bash /root/01.sh
```

### `02-install-alloy.sh` *(dans le LXC, root)*

Installe **Grafana Alloy** comme collecteur de logs (Docker + journald)
poussant vers Loki. Détection automatique :

- Docker présent → déploiement via `docker-compose.yml` (image
  `grafana/alloy`, fichiers attendus dans `/tmp/alloy-agent/`)
- Docker absent → paquet Debian + service systemd, config en
  `/etc/alloy/config.alloy`, env en `/etc/default/alloy`

**Variables d'environnement requises** :

| Var | Description |
|---|---|
| `LOKI_URL` | endpoint Loki, ex. `http://192.168.10.<IP_LXC116>:3100/loki/api/v1/push` |
| `HOSTNAME` | label `host` du LXC (défaut : `hostname`) |

**Pré-requis** : `/tmp/alloy-agent/` doit contenir `docker-compose.yml`,
`config.alloy`, `config-journald-only.alloy` (ces fichiers ne sont pas
dans ce dossier — ils vivent dans `infra/alloy-agent/` du repo
**ag.flow**, à pousser au préalable via `pct push` ou `scp`).

**Lancement (one-liner, dans le LXC en root)** une fois les configs en
place — remplacer `<IP_LOKI>` et `<HOSTNAME>` :

```bash
LOKI_URL="http://<IP_LOKI>:3100/loki/api/v1/push" HOSTNAME="<HOSTNAME>" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"
```

Exemple concret :

```bash
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc201" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"
```

### `deploy-alloy-all.sh` *(poste local)*

Déploie Alloy sur **tous** les LXC actifs du homelab via l'hôte Proxmox
(alias SSH `pve`) utilisé en bastion. Pour chaque CTID : vérifie que le
LXC est `running`, copie `infra/alloy-agent/*` + `02-install-alloy.sh`
via `pct push`, exécute le script avec `LOKI_URL` et `HOSTNAME=lxc<CTID>`.

> ⚠️ Ce script suppose une arborescence `infra/alloy-agent/` +
> `scripts/infra/02-install-alloy.sh` à la racine du repo
> **ag.flow** (chemins `../..`) — il ne fonctionne pas en standalone
> depuis un simple téléchargement. Cloner le repo ag.flow, ou adapter
> les chemins en tête du script.

**Variables** :

| Var | Défaut |
|---|---|
| `PVE_HOST` | `pve` (alias SSH du host Proxmox) |
| `LOKI_URL` | *(obligatoire)* |
| `LXC_HOSTS` | `101 102 108 111 112 113 114 115 116 117 201` |

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

# Téléchargement (à placer à l'emplacement attendu par le script) :
curl -fsSL -o ./deploy-alloy-all.sh "$BASE/deploy-alloy-all.sh"
chmod +x ./deploy-alloy-all.sh

# Tous les LXC :
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" \
  ./deploy-alloy-all.sh

# Sous-ensemble :
LXC_HOSTS="201 102" \
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" \
  ./deploy-alloy-all.sh
```

### `deploy.sh` *(poste local)*

Déploie la stack **ag.flow** sur le LXC 203 (`192.168.10.84`) via `pve`
en bastion. Workflow :

1. Build du frontend en local (`npm ci` si besoin, puis `npm run build`)
2. Tar du repo → `ssh pve` → untar dans `/tmp/agflow-deploy/`
   (exclut `.git`, `node_modules`, `.venv`, caches, `.env*`)
3. `rsync` depuis `pve` vers `LXC 203:/opt/agflow/`
4. Sur le LXC : génération de `.env.prod` au premier déploiement
   (`POSTGRES_PASSWORD`, `SESSION_COOKIE_SECRET` auto), copie de
   `Caddyfile.prod` vers `/etc/caddy/Caddyfile`, `systemctl reload caddy`,
   `docker compose -f docker-compose.prod.yml up -d --build`,
   healthcheck `http://127.0.0.1:8000/health`
5. Cleanup du staging sur `pve`

> ⚠️ Ce script ne s'exécute **pas** en standalone : il opère sur le
> repo **ag.flow** entier (frontend, `docker-compose.prod.yml`, etc.).
> Cloner le repo ag.flow puis lancer `./infra/deploy.sh` (ou équivalent
> selon ton arborescence). Le téléchargement direct depuis GitHub raw
> n'a pas de sens ici.

**Pré-requis** :

- alias SSH `pve` dans `~/.ssh/config`
- sur `pve` : clef `/root/.ssh/lxc-keys/id_ed25519_lxc203`
  (générée par `00-create-lxc.sh`)
- en local : `node` + `npm` (build frontend)
- fichier `infra/.env.deploy` (gitignored) avec
  `KEYCLOAK_CLIENT_SECRET=...`

```bash
# Depuis la racine du repo ag.flow cloné en local :
./deploy.sh
# → https://workflow-agflow.yoops.org
```

### `Caddyfile.prod`

Configuration Caddy de production pour LXC 203. Écoute en HTTP sur `:80`
(TLS géré par Cloudflare Tunnel) :

- `/api/*` → `reverse_proxy 127.0.0.1:8000` (avec headers
  `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto https`)
- `/health` → backend (monitoring)
- tout le reste → fichiers statiques `/opt/agflow/frontend/dist` avec
  fallback `try_files {path} /index.html` (SPA React Router)
- compression `zstd gzip`, headers de sécurité (CSP, X-Frame-Options DENY,
  X-Content-Type-Options nosniff, Referrer-Policy)

Copié automatiquement par `deploy.sh` ; pour reload manuel sur le LXC :

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

curl -fsSL -o /etc/caddy/Caddyfile "$BASE/Caddyfile.prod"
systemctl reload caddy
```

### `.env.prod.example`

Template à copier en `/opt/agflow/.env.prod` sur le LXC 203
(`POSTGRES_PASSWORD`, `KEYCLOAK_*`, `SESSION_COOKIE_SECRET`,
`AGFLOW_PUBLIC_BASE_URL`, `LOG_LEVEL`). En pratique, `deploy.sh` le
génère automatiquement au premier run.

```bash
curl -fsSL -o .env.prod "$BASE/.env.prod.example"
# puis remplir POSTGRES_PASSWORD, KEYCLOAK_CLIENT_SECRET, SESSION_COOKIE_SECRET
```

### `.env.deploy`

Variable consommée par `deploy.sh` (`KEYCLOAK_CLIENT_SECRET`).

> ⚠️ **Sécurité** : ce fichier est censé être gitignored
> (`# JAMAIS COMMITER`) mais est actuellement publié dans le repo avec
> un secret en clair. À déplacer hors du dépôt et à rotater côté
> Keycloak avant tout partage.

---

## Pipeline complet (cas d'usage)

```bash
# 1) Sur l'hôte Proxmox, en root — provisionner LXC + Docker (one-liner) :
mkdir -p /root/lxc && cd /root/lxc && curl -fsSL -o 00-create-lxc.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/00-create-lxc.sh && curl -fsSL -o 01-install-docker.sh https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/01-install-docker.sh && chmod +x *.sh && ./00-create-lxc.sh 203 agflow-prod

# 2) (optionnel) Dans le LXC, en root — activer le collecteur Alloy :
#    (les configs /tmp/alloy-agent doivent être copiées au préalable)
LOKI_URL="http://192.168.10.116:3100/loki/api/v1/push" HOSTNAME="lxc203" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC/02-install-alloy.sh)"

# 3) Depuis le poste local, dans le repo ag.flow cloné — déployer la stack :
./infra/deploy.sh
```

## Variables d'environnement (synthèse)

| Var | Script | Rôle |
|---|---|---|
| `CTID` (arg 1) | `00-create-lxc.sh` | ID du container |
| `CT_NAME` (arg 2) | `00-create-lxc.sh` | hostname (défaut `agflow-docker`) |
| `CORES`, `MEMORY`, `SWAP`, `DISK_SIZE` | `00-create-lxc.sh` | ressources |
| `STORAGE`, `BRIDGE` | `00-create-lxc.sh` | défaut `local-lvm`, `vmbr0` |
| `SSH_KEY_DIR` | `00-create-lxc.sh` | défaut `/root/.ssh/lxc-keys` |
| `LOKI_URL` | `02-install-alloy.sh`, `deploy-alloy-all.sh` | endpoint Loki |
| `HOSTNAME` | `02-install-alloy.sh` | label host |
| `PVE_HOST` | `deploy-alloy-all.sh` | alias SSH (défaut `pve`) |
| `LXC_HOSTS` | `deploy-alloy-all.sh` | liste de CTID |
| `KEYCLOAK_CLIENT_SECRET` | `deploy.sh` (via `.env.deploy`) | OIDC |
