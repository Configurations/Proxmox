# LXC — Provisioning Proxmox + Docker Swarm + Observabilité

Scripts et configurations pour provisionner des conteneurs LXC sur Proxmox avec Docker, Docker Swarm et collecte de logs centralisée via Grafana Alloy + Loki.

## Vue d'ensemble

Cette infrastructure homelab repose sur trois couches :

**Provisioning LXC** — Création de conteneurs Proxmox configurés pour Docker (privileged, AppArmor unconfined, nesting activé), avec installation automatisée de Docker et clés SSH. Optionnellement préparés pour Docker Swarm (`/dev/net/tun`, sysctls réseau, modules kernel hôte).

**Orchestration Docker Swarm** — Mode cluster sur un ou plusieurs LXC pour déployer des stacks multi-services avec routing mesh, overlay networks chiffrés, et placement automatique. Le LXC manager initialise le cluster et distribue les tokens worker/manager.

**Observabilité centralisée** — Un agent Grafana Alloy est déployé sur chaque LXC pour collecter les logs Docker (containers) et journald (système), puis pousser vers Loki sur le LXC `agflow-logs`. Grafana fournit l'interface de visualisation et de requête.

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
│              Logs vers Loki                             │
└─────────────────────────────────────────────────────────┘
```

## Pré-requis

- **Proxmox VE 8+** sur l'hôte
- **Template Ubuntu 24.04** dans le storage `local` (`pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst`)
- **Storage avec rootfs** disponible (LVM-thin, ZFS pool, ou LVM classique avec `content rootdir`)
- **Accès SSH root** depuis le poste local vers l'hôte Proxmox (alias SSH `pve` recommandé pour `deploy-alloy-all.sh`)

## Structure du dossier

```
LXC/
├── 00-create-lxc.sh                # Provisioning LXC + Docker (+ Swarm en option)
├── 01-install-docker.sh            # Install Docker (appelé par 00)
├── 02-init-swarm.sh                # Init manager Swarm
├── 03-install-alloy.sh             # Install collecteur Alloy
├── deploy-alloy-all.sh             # Orchestration Alloy multi-LXC
├── alloy-agent/                    # Configurations Alloy
│   ├── config.alloy                # Mode Docker (containers + journald)
│   ├── config-journald-only.alloy  # Mode systemd (journald seul)
│   └── docker-compose.yml          # Compose pour le mode Docker
└── logs-stack/                     # Stack Loki + Grafana centralisée
    ├── docker-compose.yml
    ├── loki/
    ├── grafana/
    └── README.md
```

## Workflow type

### Provisionner un nouveau LXC Docker simple

```bash
# Sur l'hôte Proxmox, depuis le dossier LXC/
./00-create-lxc.sh 200 mon-service

# Le script :
# - Affiche un tableau de bord des storages disponibles
# - Sélectionne le storage avec le plus d'espace libre (STORAGE=auto par défaut)
# - Crée le LXC privileged avec Docker
# - Configure SSH + utilisateur agflow
# - Renvoie un JSON avec IP, password, clés SSH
```

### Provisionner un manager Swarm

```bash
# 1. Création + Docker (avec préparation Swarm)
STORAGE=extended-lvm DISK_SIZE=50 ./00-create-lxc.sh 300 swarm-1 --swarm

# 2. Initialisation du cluster
./02-init-swarm.sh 300

# Le manager est prêt. Tokens sauvegardés dans :
#   /root/.ssh/lxc-keys/swarm-tokens-300.json
```

### Ajouter Alloy à un LXC existant

```bash
# Depuis le poste local, dans le repo
cd LXC/

# Sur un LXC unique (auto-detect IP de Loki)
LXC_HOSTS="300" ./deploy-alloy-all.sh

# Sur tous les LXC actifs
./deploy-alloy-all.sh

# En mode strict (échec si Loki injoignable)
STRICT_CHECKS=1 ./deploy-alloy-all.sh
```

## Référence des scripts

### `00-create-lxc.sh`

Provisionne un LXC privileged Docker-ready, avec option Swarm.

**Mode auto** (création) : si le CTID n'existe pas, crée le LXC.
**Mode reconfiguration** : si le CTID existe, met à jour la config (utile pour migrer un LXC unprivileged → privileged, ou ajouter le support Swarm).

```bash
# Création standard
./00-create-lxc.sh 200 mon-lxc

# Avec Swarm
./00-create-lxc.sh 300 swarm-mgr --swarm

# Reconfigurer un LXC existant pour ajouter Swarm
./00-create-lxc.sh 200 --swarm

# Variables d'environnement utiles
STORAGE=auto              # Sélection auto (défaut)
STORAGE=extended-lvm      # Force un storage spécifique
DISK_SIZE=50              # GB rootfs (défaut 30)
CORES=8 MEMORY=16384      # Specs CPU/RAM
SAFETY_MARGIN_GB=10       # Marge minimale dans le pool
```

**Sortie JSON** (parsable pour pipelines) :
```json
{"status":"ok","ctid":"300","ip":"...","docker_ok":1,"swarm_mode":1,"swarm_ready":true}
```

### `01-install-docker.sh`

Installe Docker Engine + Compose plugin dans un LXC. **Appelé automatiquement par `00`**, mais utilisable seul si besoin.

Configurations notables :
- `live-restore: false` par défaut (compatible Swarm). Variable `LIVE_RESTORE=1` pour Docker classique.
- `default-address-pools: 172.20.0.0/16` (subnets /24) — évite les conflits LAN
- `unattended-upgrades` configuré pour les patchs de sécurité Ubuntu (Docker exclu, géré séparément)
- Log rotation : 10 MB par fichier, 3 fichiers max

### `02-init-swarm.sh`

Initialise le premier manager Swarm sur un LXC `swarm-ready`. Vérifie les pré-requis, détecte et corrige automatiquement `live-restore: true` si présent.

```bash
# Init standard
./02-init-swarm.sh 300

# Variables utiles
ADVERTISE_ADDR=192.168.10.114    # Force l'IP advertise
POOL_OVERLAY=10.20.0.0/16        # Pool d'IPs overlay (défaut)
NODE_LABELS="role=control,zone=paris"
FORCE=1                          # Reset un cluster existant
```

**Tokens sauvegardés** dans `/root/.ssh/lxc-keys/swarm-tokens-<CTID>.json`.

### `03-install-alloy.sh`

Installe l'agent Alloy dans un LXC. Détection automatique :
- Docker présent → mode container (compose)
- Docker absent → mode systemd (paquet Debian)

```bash
# Variables requises
LOKI_URL="http://192.168.10.110:3100/loki/api/v1/push"
HOSTNAME="lxc300"

# Variables optionnelles
STRICT_CHECKS=1                  # Échec si Loki injoignable

bash 03-install-alloy.sh
```

Voir [`alloy-agent/README.md`](alloy-agent/README.md) pour les détails de configuration.

### `deploy-alloy-all.sh`

Orchestre `03-install-alloy.sh` sur plusieurs LXC depuis le poste local. Utilise SSH vers l'hôte Proxmox + `pct push` / `pct exec`.

```bash
# Tous les LXC actifs (auto-detect IP Loki)
./deploy-alloy-all.sh

# Sous-ensemble
LXC_HOSTS="300 201" ./deploy-alloy-all.sh

# IP Loki forcée
LOKI_URL="http://10.0.0.50:3100/loki/api/v1/push" ./deploy-alloy-all.sh
```

Le script gère un **cas spécial pour le LXC 116** (qui héberge Loki lui-même) : utilise `localhost` au lieu de l'IP réseau pour éviter un aller-retour et casser une dépendance circulaire.

## Concepts clés

### LXC privileged vs unprivileged

Docker dans un LXC unprivileged demande des capabilities et un user namespace mapping fragiles. Pour une infra de homelab où le LXC est dans un réseau privé de confiance, **privileged + AppArmor unconfined** est la voie la plus simple et stable.

**Trade-off** : un container Docker compromis dans un LXC privileged a plus de capabilities qu'en unprivileged. Acceptable en homelab, à challenger pour de la prod multi-tenant.

### Pourquoi Docker Swarm et pas Kubernetes (k3s) ?

**Swarm** :
- Mêmes images Docker, même socket, même `docker compose` syntax
- Init en 1 commande, pas de plan de contrôle séparé
- Pattern "service global" déploie un container par node automatiquement
- Idéal pour 1-5 nodes, un seul opérateur

**k3s** :
- Écosystème plus riche (Helm, opérateurs, CRDs)
- Mais demande containerd séparé, donc rebuild des images locales
- Plus de complexité opérationnelle

Choix homelab : **Swarm** pour son intégration Docker native et sa simplicité.

### Pool d'adresses overlay

Docker Swarm utilise par défaut `10.0.0.0/8` pour les overlay networks, ce qui crée des conflits avec les LAN privés en `10.x.x.x`. `02-init-swarm.sh` configure `10.20.0.0/16` (overridable via `POOL_OVERLAY=`).

Pour éviter les conflits avec :
- Bridge Docker classique : `172.20.0.0/16` (configuré dans `daemon.json`)
- LAN homelab : `192.168.10.0/24`

### Modes Alloy

L'agent Alloy a deux modes selon la présence de Docker dans le LXC :

| Mode | Quand | Sources collectées | Déploiement |
|------|-------|--------------------|--------------|
| **Docker** | LXC avec Docker | Containers + journald | `docker compose up` |
| **systemd** | LXC sans Docker (DNS, Vault, etc.) | journald uniquement | Paquet Debian + service |

Voir [`alloy-agent/README.md`](alloy-agent/README.md).

### IP fixe vs DHCP pour le manager Swarm

L'IP advertise du manager Swarm est gravée dans la config du cluster. **Si l'IP change, les workers ne peuvent plus joindre le manager.**

Solutions par ordre de robustesse :
1. **Réservation DHCP** dans le routeur (recommandée)
2. **DNS interne** + advertise hostname plutôt qu'IP
3. **IP statique** dans la config LXC (`pct set <CTID> -net0 ...,ip=<IP>/24,gw=<GW>`)

## Troubleshooting

### `docker swarm init` échoue avec "live-restore is incompatible"

Le script `02-init-swarm.sh` détecte et corrige automatiquement (`AUTO_FIX=1` par défaut). Pour désactiver : `AUTO_FIX=0 ./02-init-swarm.sh 300`.

Manuellement :
```bash
pct exec 300 -- sed -i 's/"live-restore": true/"live-restore": false/' /etc/docker/daemon.json
pct exec 300 -- systemctl restart docker
```

### Pool storage saturé en cours d'install

`00-create-lxc.sh` vérifie l'espace disponible avant `pct create` et propose une alternative. Si le pool sature pendant l'install Docker (cas rare), recréer sur un autre storage :

```bash
STORAGE=extended-lvm ./00-create-lxc.sh 300 swarm-1 --swarm
```

### Alloy ne pousse pas vers Loki

```bash
# Voir les logs du container
pct exec <CTID> -- docker compose -f /opt/alloy-agent/docker-compose.yml logs --tail 50

# Tester la connectivité Loki depuis le LXC
pct exec <CTID> -- curl -v http://192.168.10.110:3100/ready
```

Causes courantes :
- Loki en cours de redémarrage → Alloy retentera automatiquement
- Réseau cassé entre le LXC et Loki → vérifier les bridges Proxmox
- IP Loki obsolète (DHCP a changé) → relancer `deploy-alloy-all.sh`

### Le LXC est en DHCP et l'IP a changé

Pour les services critiques (manager Swarm, Loki), réserver l'IP côté DHCP serveur ou passer en IP statique :

```bash
pct stop <CTID>
pct set <CTID> -net0 name=eth0,bridge=vmbr0,firewall=1,ip=192.168.10.200/24,gw=192.168.10.1,type=veth
pct start <CTID>
```

## Roadmap / améliorations possibles

- [ ] Script `04-join-swarm.sh` pour ajouter automatiquement un worker au cluster
- [ ] Support multi-arch (ARM) pour les futurs nodes
- [ ] Bootstrap unifié (`bootstrap-lxc.sh`) qui orchestre 00 + 02 + 03 selon les flags
- [ ] Réservation DHCP automatique côté serveur DHCP/DNS
- [ ] Backup automatisé des tokens Swarm + clés SSH

## Licence

Voir le fichier [`LICENSE`](../LICENSE) à la racine du repo.
