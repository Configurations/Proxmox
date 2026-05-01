# VM — Provisioning & Déploiement

Scripts pour provisionner des **VMs Proxmox QEMU** prêtes pour Docker
/ Docker Swarm via cloud-init. Pendant de `create-lxc.sh` — **même
interface de flags, même sortie JSON** — mais cible une VM complète
(kernel propre) au lieu d'un container LXC.

> 🇬🇧 For the English version, see [readme-vm.md](readme-vm.md).
> 📦 Pour la version LXC, voir [readme-lxc-fr.md](readme-lxc-fr.md).

> **Pourquoi une VM plutôt qu'un LXC ?** Une VM a son propre kernel,
> donc le routing mesh IPVS de Docker Swarm et les VIPs de service
> fonctionnent nativement (le bug IPVS du LXC privileged documenté
> dans [readme-lxc-fr.md](readme-lxc-fr.md#%EF%B8%8F-limitations--ipvs-en-lxc-privileged)
> ne s'applique pas). Trade-off : empreinte RAM/CPU plus élevée, boot
> légèrement plus lent.

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"
```

---

## `create-vm.sh` *(hôte Proxmox)* — point d'entrée principal

Un script autonome qui **crée ou reconfigure** une VM Proxmox à partir
d'une image cloud-init Ubuntu et, selon les flags, installe Docker,
prépare Swarm, initialise un cluster ou en rejoint un.

Pattern de bootstrap :

1. **`qm create`** + `qm importdisk` d'une image cloud-init Ubuntu
2. **Cloud-init** injecte la clef SSH root + DHCP réseau
3. **qemu-guest-agent** (préinstallé dans les cloud images) sert à
   détecter l'IP de la VM après boot
4. Le reste (apt update, user agflow, sysctl, install Docker,
   init/join Swarm) s'exécute via **SSH** en root

### Modes & flags — identiques à `create-lxc.sh`

| Flag | Effet |
|---|---|
| *(aucun)* | VM nue — pas de Docker, pas de Swarm |
| `--docker` | Installe Docker (pas de perms LXC nécessaires : la VM a son propre kernel) |
| `--swarm` | Prépare la VM swarm-ready (sysctls + tag — pas de bind `/dev/net/tun`, pas de modules kernel hôte : la VM est autonome) |
| `--init-swarm` | Initialise un nouveau cluster Swarm (implique `--docker` + `--swarm`) |
| `--join-swarm --manager-ip <IP> --token <TOKEN> [--as-manager]` | Rejoint un cluster existant (implique `--docker` + `--swarm`) |

`--init-swarm` et `--join-swarm` sont mutuellement exclusifs.

### Différences vs `create-lxc.sh`

| Aspect | LXC | VM |
|---|---|---|
| Outil PVE | `pct` | `qm` |
| Exec dans la machine | `pct exec` | `ssh root@<IP>` (clef cloud-init) |
| Bootstrap | Template Ubuntu `.tar.zst` | Image cloud-init Ubuntu `.img` (auto-téléchargée) |
| Modules kernel hôte | requis pour `--swarm` | ❌ N/A (kernel propre à la VM) |
| Perms LXC (apparmor/cgroup2) | requis pour `--docker` | ❌ N/A |
| Bind `/dev/net/tun` | requis pour `--swarm` | ❌ natif dans la VM |
| `--swarm` se réduit à | modules hôte + `/dev/net/tun` + sysctl + tag | sysctl + tag |
| IPVS pour Swarm | cassé — nécessite `mode: host` + `endpoint_mode: dnsrr` | fonctionne nativement |
| `type` JSON | `"lxc"` | `"vm"` (bloc `cloud_init` en plus) |

### Comportements automatiques

- **Détection auto du mode** — VM absente → création; VM existante →
  reconfiguration (backup conf, mise à jour tags/description).
- **Sélection storage** (`STORAGE=auto` par défaut) — choix du pool
  avec le plus d'espace libre parmi ceux qui supportent
  `content=images`, vérification d'espace préalable (avec
  `SAFETY_MARGIN_GB=5`).
- **Auto-téléchargement de l'image cloud** — image cloud Ubuntu 24.04
  server récupérée dans `/var/lib/vz/template/iso` si absente
  (override via `CLOUD_IMG_NAME`/`CLOUD_IMG_URL`).
- **Attentes au boot** :
  - ping guest agent (timeout 180s)
  - IP DHCP via guest agent (timeout 120s)
  - disponibilité SSH (timeout `SSH_BOOT_TIMEOUT=180s`)
- **Auto-fix live-restore** — `--init-swarm` détecte et corrige
  `live-restore=true` (incompatible Swarm) si `AUTO_FIX=1`.
- **Sortie JSON** — un seul bloc agrégé :
  `{"status", "exit_code", "machine":{...,"cloud_init":{...}}, "docker":{...}, "swarm":{...}}`.

### Artefacts générés

- Paire de clefs SSH ed25519 stockée sur l'hôte :
  `/root/.ssh/vm-keys/id_ed25519_vm<VMID>` (root, injectée via
  cloud-init) +
  `/root/.ssh/vm-keys/id_ed25519_agflow_vm<VMID>` (`agflow`).
- Utilisateur `agflow` (sudo NOPASSWD, mot de passe aléatoire 24
  caractères, membre du groupe `docker` quand `--docker` est actif).
- Pour `--init-swarm` : tokens persistés dans
  `/root/.ssh/vm-keys/swarm-tokens-vm<VMID>.json` (chmod 600).
- Un mot de passe root aléatoire est défini via cloud-init pour
  l'**accès console** (sinon clef SSH uniquement).

### Variables (défauts)

| Var | Défaut | Rôle |
|---|---|---|
| `CORES` | `4` | cœurs CPU |
| `MEMORY` | `8192` | RAM (MB) — balloon désactivé |
| `DISK_SIZE` | `30` | disque scsi0 (GB) |
| `STORAGE` | `auto` | pool du disque VM |
| `BRIDGE` | `vmbr0` | bridge réseau (virtio) |
| `SAFETY_MARGIN_GB` | `5` | marge libre minimale dans le pool |
| `SSH_KEY_DIR` | `/root/.ssh/vm-keys` | dossier des clefs SSH |
| `SSH_BOOT_TIMEOUT` | `180` | attente SSH après boot (sec) |
| `CLOUD_IMG_DIR` | `/var/lib/vz/template/iso` | dossier des images cloud |
| `CLOUD_IMG_NAME` | `ubuntu-24.04-server-cloudimg-amd64.img` | nom de l'image |
| `CLOUD_IMG_URL` | `https://cloud-images.ubuntu.com/releases/24.04/release/<name>` | URL de téléchargement |
| `LIVE_RESTORE` | `0` | Docker live-restore (0=false, compatible Swarm) |
| `DOCKER_ADDR_POOL` | `172.30.0.0/16` | pool d'IPs des bridges Docker |
| `POOL_OVERLAY` | `10.20.0.0/16` | pool overlay Swarm (init-swarm) |
| `POOL_MASK` | `24` | taille des sous-réseaux overlay |
| `NODE_LABELS` | `role=control,tenant=agflow` | labels du node Swarm |
| `FORCE` | `0` | reset du Swarm avant re-init (**destructif**) |
| `FORCE_LEAVE` | `no` | quitte le Swarm courant avant join |
| `AUTO_FIX` | `1` | corrige automatiquement `live-restore=true` |

### Pré-requis

- `wget` disponible sur l'hôte Proxmox (utilisé pour récupérer
  l'image cloud si absente)
- Client `ssh` sur l'hôte Proxmox (utilisé pour entrer dans la VM
  après boot)
- Connectivité réseau sur l'hôte vers `cloud-images.ubuntu.com`
  (téléchargement de l'image, premier run uniquement)

### Exemples

```bash
BASE="https://raw.githubusercontent.com/Configurations/Proxmox/main/LXC"

# 1) VM nue
mkdir -p /root/vm && cd /root/vm && \
  curl -fsSL -o create-vm.sh "$BASE/create-vm.sh" && chmod +x create-vm.sh && \
  ./create-vm.sh 100 ag-base

# 2) VM + Docker
./create-vm.sh 101 ag-docker --docker

# 3) Manager Swarm
./create-vm.sh 200 ag-swarm-mgr --init-swarm

# 4) Worker rejoignant un cluster existant
./create-vm.sh 201 ag-worker-1 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-xxxxxxxxx

# 5) Manager additionnel (HA)
./create-vm.sh 202 ag-mgr-2 \
    --join-swarm \
    --manager-ip 192.168.10.115 \
    --token SWMTKN-1-yyyyyyyyy \
    --as-manager

# 6) Tuning ressources + storage
STORAGE=local-lvm DISK_SIZE=80 CORES=8 MEMORY=16384 \
    ./create-vm.sh 203 ag-data --init-swarm
```

---

## `create-vm.json` — manifeste UI

Manifeste qui décrit les arguments collectés par l'UI d'orchestration
avant l'exécution du script. Conforme à
`script-manifest.schema.json`.

Champs : `VM_ID` (integer), `VM_NAME` (string), `MODE` (select:
`bare`/`docker`/`swarm`/`init-swarm`/`join-swarm`), `STORAGE`,
`DISK_SIZE`, `CORES`, `MEMORY`, `BRIDGE`, `CLOUD_IMG_NAME`,
`CLOUD_IMG_URL`, `MANAGER_IP`, `JOIN_TOKEN`, `JOIN_AS_MANAGER`,
`POOL_OVERLAY`, `NODE_LABELS`.

Le champ `command` traduit `MODE` en flags via un `case`, ajoute
`--as-manager` si demandé, puis lance `create-vm.sh` avec toutes les
variables d'environnement nommées.

---

## Pipeline (cas d'usage)

### Cas A — VM Docker mono-node

```bash
mkdir -p /root/vm && cd /root/vm && \
  curl -fsSL -o create-vm.sh "$BASE/create-vm.sh" && chmod +x create-vm.sh && \
  ./create-vm.sh 100 agflow-prod --docker
```

### Cas B — Cluster Docker Swarm (sans workaround IPVS)

```bash
# 1) Premier manager
./create-vm.sh 200 ag-swarm-mgr --init-swarm

WORKER_TOKEN=$(jq -r .worker_token /root/.ssh/vm-keys/swarm-tokens-vm200.json)
MANAGER_IP=$(jq -r .manager_ip /root/.ssh/vm-keys/swarm-tokens-vm200.json)

# 2) Worker
./create-vm.sh 201 ag-worker-1 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$WORKER_TOKEN"

# 3) Manager additionnel (HA)
MANAGER_TOKEN=$(jq -r .manager_token /root/.ssh/vm-keys/swarm-tokens-vm200.json)
./create-vm.sh 202 ag-mgr-2 \
    --join-swarm --manager-ip "$MANAGER_IP" --token "$MANAGER_TOKEN" --as-manager
```

> ✅ Contrairement au LXC, vos `docker-compose.yml` n'ont **pas
> besoin** de `mode: host` ou `endpoint_mode: dnsrr`. Les modes
> `ingress` et VIP par défaut fonctionnent comme prévu.

---

## Variables (résumé)

| Var | Rôle |
|---|---|
| `VMID` (arg 1) | ID de la VM |
| `VM_NAME` (arg 2) | hostname (défaut `agflow-vm`) |
| `--docker`, `--swarm`, `--init-swarm`, `--join-swarm` | mode opératoire |
| `--manager-ip`, `--token`, `--as-manager` | params join-swarm |
| `CORES`, `MEMORY`, `DISK_SIZE`, `STORAGE`, `BRIDGE`, `SAFETY_MARGIN_GB`, `SSH_KEY_DIR`, `SSH_BOOT_TIMEOUT` | ressources / boot |
| `CLOUD_IMG_DIR`, `CLOUD_IMG_NAME`, `CLOUD_IMG_URL` | image cloud-init |
| `LIVE_RESTORE`, `DOCKER_ADDR_POOL`, `DOCKER_ADDR_POOL_SIZE`, `MIN_FREE_MB` | tuning Docker |
| `POOL_OVERLAY`, `POOL_MASK`, `NODE_LABELS`, `TOKEN_DIR`, `FORCE`, `AUTO_FIX` | init-swarm |
| `ADVERTISE_ADDR`, `LISTEN_ADDR`, `FORCE_LEAVE` | join-swarm |

---

## Troubleshooting

### Le guest agent ne démarre jamais (timeout 180s)

Cause : cloud-init n'a pas tourné, ou qemu-guest-agent n'est pas dans
l'image choisie. Vérifier via la console série :

```bash
qm terminal <VMID>
```

Utiliser des images cloud-init Ubuntu (qemu-guest-agent préinstallé et
activé). Les ISOs génériques sans cloud-init ne marcheront pas avec ce
script.

### SSH ne se connecte jamais après le boot (timeout)

Cause : cloud-init n'a pas injecté la clef SSH. Raisons fréquentes :
- `--sshkeys` n'a pas été appliqué (essayer
  `qm set <VMID> --sshkeys /root/.ssh/vm-keys/id_ed25519_vm<VMID>.pub`
  et rebooter)
- le drive cloud-init `ide2` est absent
  (`qm config <VMID> | grep ide2`)
- le `ciuser` n'est pas `root`
  (`qm config <VMID> | grep ciuser`)

### IP non détectée via le guest agent

Le bail DHCP peut prendre plus de 120s sur réseau lent. Augmenter le
timeout en éditant la constante `120` dans `create-vm.sh`, ou forcer
une IP statique via
`qm set <VMID> --ipconfig0 ip=<IP>/CIDR,gw=<GW>` avant de relancer le
script en mode reconfigure.
