# logs-stack — Loki + Grafana sur LXC 116

Stack centralisée d'observabilité (logs) déployée sur le LXC `agflow-logs` (CTID 116). Reçoit les logs de tous les agents Alloy du homelab, les indexe via Loki, et les expose via Grafana.

## Vue d'ensemble

| Composant | Rôle | Port |
|-----------|------|------|
| **Loki** | Stockage et indexation des logs | `3100` (API) |
| **Grafana** | UI de visualisation et requêtes LogQL | `3000` (web) |
| **Caddy** | Reverse proxy HTTPS local + Cloudflare Tunnel | `80` |

```
                        Internet (via Cloudflare Tunnel)
                                    │
                                    ▼
                    ┌────────── LXC 116 ──────────┐
                    │  ┌─────────────────────┐    │
                    │  │      Caddy          │    │
                    │  │  reverse proxy      │    │
                    │  └──────────┬──────────┘    │
                    │             │               │
                    │       ┌─────┴─────┐         │
                    │       ▼           ▼         │
                    │  ┌─────────┐ ┌─────────┐    │
                    │  │ Grafana │ │  Loki   │    │
                    │  │  :3000  │ │  :3100  │    │
                    │  └─────────┘ └────▲────┘    │
                    └────────────────────┼────────┘
                                         │
                              push HTTP (Alloy agents)
                                         │
                          ┌──────────────┴──────────┐
                          │                         │
                     LXC 101, 102, ... 300 (avec Alloy)
```

## Pré-requis

- LXC 116 créé via `../00-create-lxc-swarm.sh 116 agflow-logs` (sans `--swarm`)
- Docker et Docker Compose plugin installés (gérés par `01-install-docker.sh`)
- DNS résolvant `logs.example.org` (ou un nom équivalent) vers le tunnel Cloudflare
- Tunnel Cloudflare configuré pour pointer vers `http://<IP_LXC_116>:80`

## Structure du dossier

```
logs-stack/
├── docker-compose.yml      # Stack complète (Caddy + Loki + Grafana)
├── Caddyfile               # Config reverse proxy local
├── .env.template           # Template des variables d'env (à copier en .env)
├── README.md               # Ce fichier
├── loki/
│   ├── loki-config.yaml    # Configuration Loki (storage, retention, limits)
│   └── data/               # Volume persistant (logs indexés)
└── grafana/
    ├── provisioning/       # Datasources et dashboards préconfigurés
    └── data/               # Volume persistant (config utilisateur)
```

## Déploiement

### Première installation

```bash
# 1. Cloner le repo dans le LXC 116
pct enter 116
cd /opt
git clone https://github.com/Configurations/Proxmox.git
cd Proxmox/LXC/logs-stack

# 2. Copier et compléter le .env
cp .env.template .env
vim .env  # remplir les variables (voir section "Variables d'env")

# 3. Démarrer la stack
docker compose up -d

# 4. Vérifier
docker compose ps
docker compose logs --tail 50
```

### Mise à jour

```bash
cd /opt/Proxmox/LXC/logs-stack
git pull
docker compose pull
docker compose up -d
```

### Arrêt / redémarrage

```bash
docker compose stop          # Arrêt sans supprimer
docker compose start          # Redémarrer
docker compose down           # Arrêt + suppression containers (volumes préservés)
docker compose down -v        # Arrêt + suppression containers ET volumes (DESTRUCTIF)
```

## Variables d'environnement

Voir `.env.template` pour la liste complète. Variables principales :

| Variable | Description | Exemple |
|----------|-------------|---------|
| `GRAFANA_ADMIN_USER` | Login admin Grafana | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | Mot de passe admin (à changer) | `<password>` |
| `GRAFANA_DOMAIN` | Domaine public Grafana | `logs.example.org` |
| `LOKI_RETENTION_PERIOD` | Durée de rétention des logs | `720h` (30 jours) |

## Concepts clés

### Pourquoi Loki et pas Elasticsearch / OpenSearch ?

**Loki** indexe uniquement les **labels** (métadonnées : `host`, `job`, `container`, etc.), pas le contenu des logs. Le contenu est stocké compressé dans des chunks. Résultat :

- **Empreinte disque réduite** : ~10x moins que Elasticsearch pour le même volume
- **Empreinte RAM réduite** : pas d'index inversé sur le contenu
- **Requêtes par labels rapides** : LogQL `{host="lxc300"}`
- **Limitation** : recherche full-text (`|=`, `|~`) plus lente qu'Elasticsearch sur de gros volumes

Pour un homelab où on indexe quelques GB par jour avec peu de requêtes full-text, **Loki est largement adapté** et ~10x moins coûteux en ressources.

### Architecture single-binary vs microservices

Loki peut tourner en **monolithic** (un seul binaire), **simple-scalable** (3 services : read/write/backend), ou **microservices** (10+ services). Dans cette stack, **monolithic** est utilisé : suffisant pour < 1 TB/jour, beaucoup plus simple à opérer.

### Storage et rétention

Par défaut, Loki utilise le **filesystem local** pour stocker les chunks et l'index. Pour un homelab, c'est suffisant. La rétention est gérée par le **compactor** qui supprime les chunks plus anciens que `LOKI_RETENTION_PERIOD`.

Pour scaler ou avoir de la haute dispo, on passerait à un object storage (S3, MinIO) — non nécessaire ici.

### Dashboards Grafana

Le dossier `grafana/provisioning/` contient des dashboards préconfigurés (provisionning automatique au premier démarrage de Grafana). Pour ajouter un dashboard :

1. Créer le dashboard dans l'UI Grafana
2. Exporter en JSON (Settings → JSON Model → Copy)
3. Sauvegarder dans `grafana/provisioning/dashboards/<name>.json`
4. Commit dans git

Les dashboards provisionnés sont **read-only dans l'UI** (modifiable seulement en éditant le JSON et en redémarrant Grafana).

## Caddy reverse proxy

Caddy gère le reverse proxy interne :
- Accès à Grafana via `http://logs.example.org/` → routé vers `grafana:3000`
- Accès à Loki API via `http://logs.example.org/loki/` → routé vers `loki:3100`

Le **TLS est terminé chez Cloudflare** (Cloudflare Tunnel), donc Caddy écoute en HTTP simple sur le port 80. Pas de certificat à gérer localement.

Le `Caddyfile` dans le dossier est la config minimale ; le `Caddyfile.prod` au niveau parent est pour l'instance de production avec règles avancées.

## Sécurité

### Authentification

- **Grafana** : login admin obligatoire via `GRAFANA_ADMIN_USER` + `GRAFANA_ADMIN_PASSWORD`
- **Loki** : pas d'authentification par défaut (acceptable car accessible uniquement sur le réseau privé)
- **Cloudflare Access** : ajouter une policy si Grafana est exposé sur internet

### Tokens API Grafana

Pour permettre à des outils externes (Alloy, scripts) d'écrire dans Loki ou de lire dans Grafana, créer des **service accounts** plutôt que d'utiliser le compte admin :

```
Grafana → Administration → Service accounts → New
```

### Backup

Les volumes Loki (chunks + index) et Grafana (config) sont à backuper :

```bash
# Backup périodique (cron côté Proxmox)
pct exec 116 -- tar czf /tmp/logs-stack-backup-$(date +%Y%m%d).tar.gz \
  /opt/Proxmox/LXC/logs-stack/loki/data \
  /opt/Proxmox/LXC/logs-stack/grafana/data

# Récupérer côté Proxmox
scp pve:/tmp/logs-stack-backup-*.tar.gz /backups/
```

## Troubleshooting

### Loki rejette des logs

Symptôme : Alloy log "rate limit exceeded" ou "out of order entries".

```bash
# Dans le LXC 116
docker compose logs loki --tail 100 | grep -iE "error|reject"
```

Causes courantes :
- **Rate limit atteint** : augmenter `ingestion_rate_mb` et `ingestion_burst_size_mb` dans `loki-config.yaml`
- **Logs out of order** : timestamps incorrects côté agent (vérifier l'horloge des LXC source)
- **Cardinalité explosée** : trop de valeurs uniques pour un label (ex: `request_id` en label, NE JAMAIS faire ça)

### Grafana ne se connecte pas à Loki

```bash
# Tester depuis le container Grafana
docker compose exec grafana wget -qO- http://loki:3100/ready
```

Devrait afficher `ready`. Sinon vérifier que Loki est démarré (`docker compose ps`).

### Disque saturé dans le LXC 116

Loki accumule les chunks. Vérifier la rétention :

```bash
# Taille actuelle
docker compose exec loki du -sh /loki/

# Forcer la compaction
docker compose exec loki curl -X POST http://localhost:3100/loki/api/v1/delete?query={...}
```

Réduire `LOKI_RETENTION_PERIOD` si nécessaire et redémarrer Loki.

### Dashboard Grafana cassé après upgrade

Les dashboards provisionnés peuvent être incompatibles avec une nouvelle version de Grafana. Vérifier :

```bash
docker compose logs grafana --tail 100 | grep -iE "error.*dashboard"
```

Mettre à jour les JSON dashboards depuis [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards/).

## Roadmap

- [ ] Migration vers object storage (MinIO local) pour scaler la rétention
- [ ] Ajout de Prometheus + Mimir pour les métriques (en plus des logs)
- [ ] Ajout de Tempo pour les traces distribuées (utile pour ag.flow Swarm)
- [ ] Dashboards homelab préconfigurés : santé LXC, charge Docker, latences inter-services

## Références

- [Documentation Loki](https://grafana.com/docs/loki/latest/)
- [Documentation Grafana](https://grafana.com/docs/grafana/latest/)
- [LogQL : langage de requête Loki](https://grafana.com/docs/loki/latest/query/)
- [Caddy reverse proxy](https://caddyserver.com/docs/quick-starts/reverse-proxy)
