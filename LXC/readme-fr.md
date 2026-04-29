# LXC — Scripts de provisioning Proxmox

Ce dossier contient les scripts pour provisionner des containers LXC Ubuntu sur Proxmox, avec Docker (optionnellement Docker Swarm) et Grafana Alloy comme agent d'observabilité.

Tous les scripts sont **idempotents** — sans risque de les relancer plusieurs fois. Ils s'exécutent depuis l'**hôte Proxmox** (pas depuis l'intérieur du container), sauf indication contraire.

## Scripts disponibles

| Script | Où | Rôle |
|---|---|---|
| `00-create-lxc.sh` | Hôte Proxmox | Créer ou reconfigurer un LXC Ubuntu, installer Docker, optionnellement Swarm-ready |
| `01-install-docker.sh` | Dans le LXC | Installer Docker Engine + Compose. Appelé automatiquement par `00-create-lxc.sh`, peut tourner en standalone |
| `02-init-swarm.sh` | Hôte Proxmox | Initialiser un **nouveau** cluster Swarm sur un LXC swarm-ready (1er manager) |
| `02-join-swarm.sh` | Hôte Proxmox | Faire **rejoindre** un LXC existant à un cluster Swarm existant (worker ou manager) |
| `03-install-alloy.sh` | Dans le LXC | Installer Grafana Alloy comme collecteur de logs/metriques |
| `deploy-alloy-all.sh` | Hôte Proxmox | Déployer Alloy sur une liste de LXC en une commande |

`02-init-swarm.sh` et `02-join-swarm.sh` sont des **alternatives**, pas une séquence — utilisez l'un ou l'autre selon que vous démarrez un nouveau cluster ou que vous étendez un cluster existant.

## Démarrage rapide

### LXC Docker simple (sans Swarm)

```bash
# Sur l'hôte Proxmox
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 200 mon-lxc-docker
```

Le script sélectionne automatiquement le storage avec le plus d'espace libre, crée le LXC, installe Docker et crée un utilisateur `agflow` avec sudo + clé SSH.

### Nouveau cluster Swarm (un manager)

```bash
# 1. Créer le LXC, swarm-ready (modules kernel, /dev/net/tun, sysctls)
STORAGE=extended-lvm DISK_SIZE=50 \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 300 swarm-1 --swarm

# 2. Initialiser le cluster Swarm sur ce LXC
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-init-swarm.sh)" _ 300
```

### Ajouter des nodes à un Swarm existant

Une fois un Swarm en place, vous pouvez ajouter des **workers** (qui font tourner les services) ou des **managers** (plan de contrôle HA).

#### Récupérer la commande de join depuis un manager existant

Depuis n'importe quel manager existant, vous pouvez demander à Swarm la commande `docker swarm join` exacte, avec le token :

```bash
# Sur le LXC 300 (manager existant)
docker swarm join-token worker
# Affiche :
# docker swarm join --token SWMTKN-1-xxx... 192.168.10.115:2377

docker swarm join-token manager
# Affiche :
# docker swarm join --token SWMTKN-1-yyy... 192.168.10.115:2377
```

Vous pouvez copier-coller cette commande directement dans un autre LXC pour rejoindre le cluster manuellement. Le script `02-join-swarm.sh` automatise ça de bout en bout depuis l'hôte Proxmox.

#### Join automatisé avec le script

```bash
# 1. Créer le nouveau LXC, swarm-ready
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/00-create-lxc.sh)" _ 301 swarm-2 --swarm

# 2. Récupérer le token de join et l'IP du manager existant
TOKEN=$(pct exec 300 -- docker swarm join-token worker -q)
MANAGER_IP=$(pct exec 300 -- docker info --format '{{.Swarm.NodeAddr}}')

# 3. Faire rejoindre comme worker
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-join-swarm.sh)" _ 301 "${MANAGER_IP}" "${TOKEN}"
```

Pour un **manager** additionnel (HA), utiliser `--manager` et le token de manager :

```bash
TOKEN_MGR=$(pct exec 300 -- docker swarm join-token manager -q)
bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/02-join-swarm.sh)" _ 302 "${MANAGER_IP}" "${TOKEN_MGR}" --manager
```

Vérifier depuis le manager :

```bash
pct exec 300 -- docker node ls
```

### Déployer Alloy sur plusieurs LXC

```bash
LXC_HOSTS="101 102 200 300" \
  bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"
```

Le script détecte automatiquement l'endpoint Loki, copie les configs Alloy, lance l'install dans chaque LXC, et saute les containers déjà à jour.

## Choix de design

### LXC privileged

Ces scripts créent des LXC **privileged** (`unprivileged: 0`) parce que les overlay networks Docker Swarm ont besoin de `/dev/net/tun` et de certaines capabilities kernel restrictives en unprivileged. C'est un compromis entre isolation et compatibilité Docker Swarm complète.

Si vous n'avez besoin que de Docker simple (sans Swarm), unprivileged marcherait aussi, mais les scripts ici standardisent sur privileged pour simplifier.

### Pool d'adresses Docker

`01-install-docker.sh` configure Docker avec `172.30.0.0/16` comme pool par défaut pour les bridges (`docker0`, `docker_gwbridge`, networks custom).

Cela évite les conflits avec :
- Le range ingress par défaut de Swarm (`10.0.0.0/8`)
- Le pool overlay utilisé par `02-init-swarm.sh` (`10.20.0.0/16`)
- Les LAN homelab classiques (`192.168.x.x`, `10.x.x.x`)

Override avec `DOCKER_ADDR_POOL=...` si nécessaire.

### live-restore désactivé

Le `live-restore: true` de Docker est **incompatible avec Swarm**. Le défaut dans `01-install-docker.sh` est `false`. Override avec `LIVE_RESTORE=1` uniquement si vous tournez Docker simple sans Swarm.

### Sélection du storage

`00-create-lxc.sh` utilise `STORAGE=auto` par défaut : il affiche un tableau de bord de tous les storages Proxmox, choisit celui avec le plus d'espace libre (parmi ceux qui supportent `rootdir`), et vérifie l'espace avant `pct create`. Override avec `STORAGE=<nom>`.

## Variables communes

Ces variables fonctionnent dans la plupart des scripts :

| Variable | Défaut | Description |
|---|---|---|
| `STORAGE` | `auto` | Storage Proxmox pour le rootfs (`auto` = meilleur choix) |
| `DISK_SIZE` | `30` | Taille du rootfs LXC en GB |
| `CORES` | `4` | Cœurs CPU |
| `MEMORY` | `8192` | RAM en MB |
| `BRIDGE` | `vmbr0` | Bridge réseau |
| `SSH_KEY_DIR` | `/root/.ssh/lxc-keys` | Où stocker les clés SSH générées |
| `REPO_RAW_URL` | URL raw GitHub | Override pour utiliser un fork ou une branche |

## Format de sortie

Tous les scripts émettent une dernière ligne JSON avec un résumé du statut, exploitable en automatisation :

```json
{"status":"ok","ctid":"300","ip":"192.168.10.115","docker":"Docker version 27.x","swarm_ready":true}
```

Codes de sortie :
- `0` — Succès
- `1` — Échec dur (création LXC, init Swarm, etc.)
- `2` — Partiel (LXC créé mais Docker non opérationnel)

## Dépannage

### "BASH_SOURCE[0]: unbound variable"

Vieille version de `00-create-lxc.sh`. Pullez la dernière version depuis ce repo.

### Timeout de la stack, port inaccessible, mais le service est "running"

Si vous avez `172.20.0.0/16` dans `/etc/docker/daemon.json`, le pool de bridges entre en conflit avec l'ingress Swarm. Recréez le LXC avec les derniers scripts (qui utilisent maintenant `172.30.0.0/16`).

### Disque plein pendant l'install

Les LXC font 30 GB par défaut. Pour les managers Swarm qui font tourner des stacks, préférez 50+ GB :

```bash
DISK_SIZE=50 ./00-create-lxc.sh ...
```

Pour redimensionner un LXC existant :

```bash
pct resize <CTID> rootfs +10G
```

### Alloy rapporte "Cannot connect to Docker daemon"

Alloy en mode Docker mount `/var/run/docker.sock` depuis l'hôte. Si le LXC a Docker installé mais que le daemon est arrêté ou que les permissions du socket sont mauvaises :

```bash
pct exec <CTID> -- systemctl status docker
pct exec <CTID> -- ls -la /var/run/docker.sock
```

## Liens

- [stacks/README.md](../stacks/README.md) — Stacks applicatives déployées sur le cluster Swarm (autre repo : `ag-flow/Configurations`)

---

🇬🇧 For the English version, see [README.md](README.md).