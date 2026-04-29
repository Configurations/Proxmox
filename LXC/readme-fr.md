# LXC — Proxmox + Docker Swarm + Observabilité

Scripts autonomes pour provisionner des conteneurs Proxmox LXC configurés pour Docker (et optionnellement Docker Swarm), avec collecte centralisée des logs via Grafana Alloy + Loki.

> **Note** : ce dossier est un sous-projet autonome qui sera déplacé dans un repo dédié plus tard. Il ne suit pas la convention `Installs/+runs/` du repo parent.

## Ce que tu obtiens

- **LXC privilégiés Docker-ready** en une commande — AppArmor unconfined, nesting, keyctl, clés SSH, utilisateur dédié
- **Support Docker Swarm optionnel** — modules kernel, `/dev/net/tun`, sysctls, tag `swarm-ready`
- **Collecte de logs centralisée** — Grafana Alloy sur chaque LXC, push vers Loki + Grafana sur un LXC dédié
- **Procédures idempotentes** — détruis et recrée autant de fois que tu veux, les scripts gèrent la reconfiguration

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Cluster Proxmox                      │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────┐    │
│  │  LXC 300   │  │  LXC xxx   │  │  LXC 116        │    │
│  │  Manager   │  │  Worker    │  │  Loki+Grafana   │    │
│  │  Swarm     │  │  service   │  │  (logs central) │    │
│  │            │  │            │  │                 │    │
│  │  + Alloy   │  │  + Alloy   │  │  + Alloy local  │    │
│  └────────────┘  └────────────┘  └─────────────────┘    │
│        │              │              ▲                  │
│        └──────────────┴──────────────┘                  │
│              Push des logs vers Loki                    │
└─────────────────────────────────────────────────────────┘
```

## Pré-requis

- Proxmox VE 8+ sur l'hôte
- Template Ubuntu 24.04 disponible (`pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst`)
- Storage avec contenu `rootdir` (LVM-thin, pool ZFS, ou LVM)

## Démarrage rapide

Toutes les commandes se lancent **sur l'hôte Proxmox**. Pas besoin de cloner le repo — chaque script est récupéré directement via wget.

### Créer un LXC Docker simple

```bash
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 200 mon-service
```

### Créer un manager Swarm (setup recommandé)

```bash
# 1. Provisionner le LXC + Docker + pré-requis Swarm
STORAGE=extended-lvm DISK_SIZE=50 \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm

# 2. Initialiser le cluster Swarm
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-init-swarm.sh)" _ 300
```

Le manager est prêt. Les tokens worker sont sauvegardés dans `/root/.ssh/lxc-keys/swarm-tokens-300.json`.

### Déployer le collecteur Alloy sur tous les LXC

Le script récupère tout ce dont il a besoin depuis GitHub et pousse à chaque LXC. Il suffit de l'exécuter sur l'hôte Proxmox :

```bash
# Auto-détection de l'IP Loki via le LXC 116, déploie sur tous les LXC actifs
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Déploiement sur un sous-ensemble
LXC_HOSTS="300 201" bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Mode strict (échec si Loki injoignable)
STRICT_CHECKS=1 bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"

# Forcer une URL Loki (skip auto-détection)
LOKI_URL="http://10.0.0.50:3100/loki/api/v1/push" \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"
```

## Structure du dossier

```
LXC/
├── 00-create-lxc.sh                # Provisionnement LXC + Docker (+ Swarm en option)
├── 01-install-docker.sh            # Installation Docker (appelé par 00)
├── 02-init-swarm.sh                # Initialisation manager Swarm
├── 03-install-alloy.sh             # Installation collecteur Alloy
├── deploy-alloy-all.sh             # Orchestrateur Alloy multi-LXC
├── alloy-agent/                    # Configurations Alloy
│   ├── config.alloy                # Mode Docker (containers + journald)
│   ├── config-journald-only.alloy  # Mode systemd (journald uniquement)
│   ├── docker-compose.yml          # Compose pour le mode Docker
│   └── README.md
└── logs-stack/                     # Stack Loki + Grafana centralisée
    ├── docker-compose.yml
    ├── loki/
    ├── grafana/
    └── README.md
```

## Où s'exécute chaque script

| Script | S'exécute depuis | Cible |
|---|---|---|
| `00-create-lxc.sh` | Hôte Proxmox | Hôte Proxmox (crée le LXC) |
| `01-install-docker.sh` | Dans le LXC (poussé par 00) | LXC |
| `02-init-swarm.sh` | Hôte Proxmox | LXC via `pct exec` |
| `03-install-alloy.sh` | Dans le LXC (poussé par deploy-alloy-all) | LXC |
| `deploy-alloy-all.sh` | Hôte Proxmox | Plusieurs LXC via `pct push` + `pct exec` |

Tous les scripts peuvent être invoqués via `bash -c "$(wget -qLO - ...)"` directement sur l'hôte Proxmox.

## Référence des scripts

### `00-create-lxc.sh`

Provisionne un LXC privilégié Docker-ready, avec préparation Swarm optionnelle.

- **Mode création** (défaut) : si le CTID n'existe pas, crée le LXC
- **Mode reconfiguration** : si le CTID existe, met à jour la config

```bash
# Création standard
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 200 mon-lxc

# Avec support Swarm
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 300 swarm-mgr --swarm

# Reconfigurer un LXC existant pour Swarm
bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 200 --swarm
```

Variables d'environnement utiles :

| Variable | Défaut | Description |
|---|---|---|
| `STORAGE` | `auto` | `auto` sélectionne le pool avec le plus d'espace libre, ou force un nom spécifique |
| `DISK_SIZE` | `30` | Taille rootfs en GB |
| `CORES` | `4` | Cœurs CPU |
| `MEMORY` | `8192` | RAM en MB |
| `SAFETY_MARGIN_GB` | `5` | Marge minimale à laisser libre dans le pool |

Sortie JSON (parsable pour pipelines) :

```json
{"status":"ok","ctid":"300","ip":"192.168.10.114","docker_ok":1,"swarm_mode":1,"swarm_ready":true}
```

### `01-install-docker.sh`

Installe Docker Engine et le plugin Compose dans un LXC. Appelé automatiquement par `00-create-lxc.sh`.

Configurations notables :

- `live-restore: false` (compatible Swarm). `LIVE_RESTORE=1` pour Docker classique bare-metal
- `default-address-pools: 172.20.0.0/16` avec subnets /24
- `unattended-upgrades` configuré pour les patchs de sécurité Ubuntu (Docker exclu)
- Rotation des logs : 10 MB par fichier, 3 fichiers max

### `02-init-swarm.sh`

Initialise un manager Swarm sur un LXC `swarm-ready`. Vérifie les pré-requis, corrige automatiquement `live-restore: true` si présent.

Variables utiles :

| Variable | Défaut | Description |
|---|---|---|
| `ADVERTISE_ADDR` | auto-détecté | Force l'IP advertise |
| `POOL_OVERLAY` | `10.20.0.0/16` | Pool d'IPs pour les overlay networks |
| `NODE_LABELS` | `role=control,tenant=agflow` | Labels appliqués au node |
| `FORCE` | `0` | Réinitialise un cluster existant (DESTRUCTIF) |
| `AUTO_FIX` | `1` | Correction auto de `live-restore: true` |

Tokens sauvegardés dans `/root/.ssh/lxc-keys/swarm-tokens-<CTID>.json`.

### `03-install-alloy.sh`

Installe Grafana Alloy dans un LXC. Détection automatique du mode :

- Docker présent → mode container (compose)
- Docker absent → mode systemd (paquet Debian)

Variables requises : `LOKI_URL`, `HOSTNAME`. `STRICT_CHECKS=1` optionnel : fait échouer le script si Loki est injoignable.

Habituellement invoqué via `deploy-alloy-all.sh`, mais utilisable seul à l'intérieur d'un LXC.

Voir [`alloy-agent/README.md`](alloy-agent/README.md) pour les détails de configuration.

### `deploy-alloy-all.sh`

S'exécute sur l'hôte Proxmox. Télécharge les fichiers Alloy nécessaires depuis GitHub vers `/tmp/alloy-files/`, puis les pousse à chaque LXC via `pct push` et lance `03-install-alloy.sh` via `pct exec`.

| Variable | Défaut | Description |
|---|---|---|
| `LOKI_URL` | auto-détecté depuis LXC 116 | Force l'endpoint Loki |
| `LXC_HOSTS` | LXC actifs avec Docker | Liste de CTID séparés par espaces |
| `LOKI_LXC` | `116` | CTID du LXC qui héberge Loki |
| `LOKI_PORT` | `3100` | Port Loki |
| `STRICT_CHECKS` | `0` | Échec si Loki injoignable depuis un LXC |
| `REPO_BRANCH` | `main` | Branche GitHub à utiliser |

Cas spécial : quand on déploie sur le LXC qui héberge Loki lui-même (CTID 116), le script utilise `localhost` au lieu de l'IP réseau pour éviter un aller-retour et casser la dépendance circulaire.

## Concepts clés

### LXC privileged vs unprivileged

Docker dans un LXC unprivileged demande des capabilities et un user namespace mapping fragiles. Pour un homelab où le LXC est dans un réseau privé de confiance, **privileged + AppArmor unconfined** est la voie la plus simple et stable.

Compromis : un container Docker compromis dans un LXC privileged a plus de capabilities qu'en unprivileged. Acceptable en homelab, à challenger pour de la prod multi-tenant.

### Pourquoi Docker Swarm et pas Kubernetes (k3s) ?

**Swarm** :
- Mêmes images Docker, même socket, même syntaxe `docker compose`
- Init en une commande, pas de plan de contrôle séparé à déployer
- Pattern "service global" natif — déploie automatiquement un container par node
- Sweet spot pour 1 à 5 nodes, opérateur unique

**k3s** :
- Écosystème plus riche (Helm, opérateurs, CRDs)
- Mais demande un containerd séparé, donc rebuild des images locales nécessaire
- Plus de complexité opérationnelle

Pour un homelab, Swarm gagne sur la simplicité et l'intégration native Docker.

### Pool d'adresses overlay

Docker Swarm utilise par défaut `10.0.0.0/8` pour les overlay networks, ce qui crée des conflits avec les LAN privés en `10.x.x.x`. `02-init-swarm.sh` configure `10.20.0.0/16` (overridable via `POOL_OVERLAY=`).

### Modes Alloy

Alloy a deux modes selon la présence de Docker dans le LXC :

| Mode | Quand | Sources collectées | Déploiement |
|------|-------|--------------------|--------------|
| **Docker** | LXC avec Docker | Containers + journald | `docker compose up` |
| **systemd** | LXC sans Docker (DNS, Vault, etc.) | journald uniquement | Paquet Debian + service |

Voir [`alloy-agent/README.md`](alloy-agent/README.md).

### IP fixe vs DHCP pour le manager Swarm

L'IP advertise du manager Swarm est gravée dans la config du cluster. **Si l'IP change, les workers ne peuvent plus joindre le manager.**

Solutions par ordre de robustesse :

1. **Réservation DHCP** dans ton routeur/serveur DHCP (recommandée)
2. **DNS interne** + advertise via hostname plutôt qu'IP
3. **IP statique** dans la config LXC (`pct set <CTID> -net0 ...,ip=<IP>/24,gw=<GW>`)

## Troubleshooting

### `docker swarm init` échoue avec "live-restore is incompatible"

`02-init-swarm.sh` détecte et corrige automatiquement. Correction manuelle :

```bash
pct exec 300 -- sed -i 's/"live-restore": true/"live-restore": false/' /etc/docker/daemon.json
pct exec 300 -- systemctl restart docker
```

### Pool storage saturé en cours d'install

`00-create-lxc.sh` vérifie l'espace disponible avant `pct create` et propose une alternative :

```bash
STORAGE=extended-lvm bash -c "$(wget -qLO - .../LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm
```

### Alloy ne pousse pas vers Loki

```bash
# Voir les logs du container
pct exec <CTID> -- docker compose -f /opt/alloy-agent/docker-compose.yml logs --tail 50

# Tester la connectivité Loki depuis le LXC
pct exec <CTID> -- curl -v http://192.168.10.110:3100/ready
```

### Le LXC est en DHCP et l'IP a changé

Pour les services critiques (manager Swarm, Loki), réserver l'IP côté serveur DHCP ou passer en IP statique :

```bash
pct stop <CTID>
pct set <CTID> -net0 name=eth0,bridge=vmbr0,firewall=1,ip=192.168.10.200/24,gw=192.168.10.1,type=veth
pct start <CTID>
```

## Roadmap

- [ ] `04-join-swarm.sh` pour ajouter automatiquement un worker au cluster
- [ ] Support multi-arch (ARM) pour les futurs nodes
- [ ] `bootstrap-lxc.sh` unifié orchestrant 00 + 02 + 03 selon les flags
- [ ] Réservation DHCP automatique via API du serveur DHCP/DNS
- [ ] Backup automatisé des tokens Swarm + clés SSH
- [ ] **Splitter ce dossier dans un repo dédié**

## Licence

Voir [LICENSE](../LICENSE) à la racine du repo.

---

🇬🇧 For the English version, see [README.md](README.md).
