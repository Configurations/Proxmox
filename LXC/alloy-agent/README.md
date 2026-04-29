# alloy-agent — Configurations Grafana Alloy

Configurations de l'agent collecteur de logs **Grafana Alloy**, déployé sur chaque LXC du homelab pour centraliser les logs vers Loki.

## Vue d'ensemble

[Grafana Alloy](https://grafana.com/oss/alloy/) est un collecteur de télémétrie (logs, métriques, traces) qui remplace Promtail, Grafana Agent et OpenTelemetry Collector. Dans cette infra il est utilisé uniquement pour collecter les **logs** :

- **Containers Docker** (via `discovery.docker` + `loki.source.docker`)
- **Journal systemd** (via `loki.source.journal`)

Les logs sont enrichis de labels (`host`, `job`, `container`, `compose_service`, `compose_project`, `unit`, `level`, etc.) puis poussés vers Loki sur le LXC `agflow-logs` (CTID 116).

```
┌─────────── LXC source ───────────┐         ┌──── LXC 116 ────┐
│                                  │         │                 │
│  ┌──────────┐  ┌─────────────┐   │   push  │  ┌───────────┐  │
│  │ journald │  │ Docker logs │   │  ────►  │  │   Loki    │  │
│  └────┬─────┘  └──────┬──────┘   │         │  └───────────┘  │
│       └──────┬────────┘          │         │        ▲        │
│              ▼                   │         │        │ query  │
│        ┌──────────┐              │         │  ┌───────────┐  │
│        │  Alloy   │  ────────────┼────────►│  │  Grafana  │  │
│        └──────────┘              │         │  └───────────┘  │
└──────────────────────────────────┘         └─────────────────┘
```

## Fichiers du dossier

| Fichier | Usage | Mode |
|---------|-------|------|
| `config.alloy` | Config principale : Docker + journald | LXC avec Docker |
| `config-journald-only.alloy` | Config journald seul | LXC sans Docker |
| `docker-compose.yml` | Compose pour le container Alloy | LXC avec Docker |

## Variables d'environnement

Les configurations attendent deux variables :

| Variable | Description | Exemple |
|----------|-------------|---------|
| `LOKI_URL` | Endpoint Loki complet | `http://192.168.10.110:3100/loki/api/v1/push` |
| `HOSTNAME` | Identifiant de l'hôte (label `host`) | `lxc201` |

Ces variables sont injectées dans le container Alloy via le `.env` (mode Docker) ou `/etc/default/alloy` (mode systemd). Elles sont lues via `sys.env("VAR")` dans la config Alloy.

## Déploiement

Le déploiement est géré par les scripts au niveau parent :

```bash
# Sur un LXC unique (depuis le poste local)
LXC_HOSTS="300" ../deploy-alloy-all.sh

# Sur tous les LXC actifs
../deploy-alloy-all.sh
```

Voir [`../README.md`](../README.md) pour la documentation complète des scripts.

## Labels appliqués

### Logs Docker (`job=docker`)

| Label | Source | Description |
|-------|--------|-------------|
| `host` | `sys.env("HOSTNAME")` | LXC source (ex: `lxc300`) |
| `job` | constant | `docker` |
| `container` | `__meta_docker_container_name` | Nom du container (sans le `/`) |
| `stream` | `__meta_docker_container_log_stream` | `stdout` ou `stderr` |
| `compose_service` | label compose | Nom du service compose |
| `compose_project` | label compose | Nom du projet compose |
| `cluster` | external label | `homelab` |

### Logs systemd (`job=systemd-journal`)

| Label | Source | Description |
|-------|--------|-------------|
| `host` | `sys.env("HOSTNAME")` | LXC source |
| `job` | constant | `systemd-journal` |
| `unit` | `__journal__systemd_unit` | Unité systemd (ex: `docker.service`) |
| `level` | `__journal_priority_keyword` | `info`, `warning`, `error`, etc. |
| `syslog_identifier` | `__journal_syslog_identifier` | Identifiant syslog |
| `cluster` | external label | `homelab` |

## Concepts clés

### Pourquoi mode Docker vs mode systemd ?

Sur les LXC qui ont Docker installé, **on ne peut pas se contenter de journald** : les logs des containers Docker (par défaut `json-file` driver) sont écrits dans `/var/lib/docker/containers/<id>/<id>-json.log`, **pas dans journald**. Il faut donc qu'Alloy lise le socket Docker pour les capturer, en plus de journald.

Sur les LXC sans Docker (DNS, Vault, services bare-metal), seul journald a quelque chose à offrir. La config est plus simple.

### Mounts en lecture seule

Le container Alloy mount tous les volumes en `:ro` (read-only) :
- `docker.sock` : pour discovery + lecture des logs containers
- `/var/log/journal` et `/run/log/journal` : pour journald persistent et volatile
- `/etc/machine-id` : requis par systemd journal pour identifier le journal

Aucune écriture, aucune modification possible. Alloy ne peut que lire et pousser.

### Image figée

L'image Docker est pinnée à `grafana/alloy:v1.5.1`. **Pas de `:latest`** pour éviter les drifts involontaires lors d'un `docker compose pull`. Pour upgrader, modifier explicitement la version dans `docker-compose.yml`.

### `unattended-upgrades` exclu pour Docker

Le script `01-install-docker.sh` configure `unattended-upgrades` mais **exclut explicitement** `docker-ce`, `docker-ce-cli` et `containerd.io`. Raison : Docker a son propre cycle de release, pas synchronisé avec les patchs de sécurité Ubuntu. Mieux vaut un upgrade Docker piloté manuellement (testable) qu'automatique.

## Customisation

### Ajouter un label custom

Éditer `config.alloy` ou `config-journald-only.alloy`, ajouter dans le bloc `labels = { ... }` :

```alloy
labels = {
  job  = "docker",
  host = sys.env("HOSTNAME"),
  env  = "homelab",        // nouveau label statique
  region = sys.env("REGION"),  // nouveau label depuis env
}
```

Et dans `docker-compose.yml`, ajouter la variable d'env :

```yaml
environment:
  ...
  REGION: ${REGION:-paris}
```

Et dans `.env` (généré par le script `03-install-alloy.sh`) :

```
REGION=paris
```

### Filtrer des containers (ne pas envoyer leurs logs)

Dans `config.alloy`, modifier le bloc `discovery.relabel "containers"` :

```alloy
discovery.relabel "containers" {
  targets = discovery.docker.containers.targets

  // Exclure les containers dont le nom commence par "noisy-"
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/noisy-.*"
    action        = "drop"
  }

  // ...
}
```

### Changer la rétention des logs source

Le paramètre `max_age = "12h"` dans `loki.source.journal` limite la lecture des logs systemd plus anciens que 12h (utile pour ne pas re-pousser tout l'historique au démarrage). Augmenter ou réduire selon le besoin.

## Troubleshooting

### Vérifier qu'Alloy tourne

```bash
# Mode Docker
pct exec <CTID> -- docker compose -f /opt/alloy-agent/docker-compose.yml ps

# Mode systemd
pct exec <CTID> -- systemctl status alloy
```

### Voir les logs d'Alloy

```bash
# Mode Docker
pct exec <CTID> -- docker compose -f /opt/alloy-agent/docker-compose.yml logs --tail 50

# Mode systemd
pct exec <CTID> -- journalctl -u alloy --since "5 minutes ago"
```

### UI d'admin Alloy

En mode Docker, Alloy expose une UI sur `http://<LXC_IP>:12345/` (ports forwarder pour y accéder depuis le LAN). Permet de visualiser le pipeline de collecte, l'état des composants, les métriques internes.

### Alloy ne pousse pas

Causes courantes par ordre de fréquence :

1. **Loki injoignable** (réseau, DNS, Loki down) — vérifier `curl http://<LOKI_IP>:3100/ready`
2. **Variable d'env mal injectée** — vérifier `docker compose exec alloy env | grep LOKI` (mode Docker) ou `cat /etc/default/alloy` (mode systemd)
3. **Config Alloy invalide** — Alloy log l'erreur au démarrage, vérifier les logs
4. **Volume `docker.sock` non monté** — vérifier `docker compose config` ou les mounts dans `docker inspect`

### Vérifier que les logs arrivent dans Loki

Dans Grafana → Explore → datasource Loki :

```logql
{host="lxc300"} | line_format "{{.host}} | {{.job}} | {{.unit}}{{.container}}"
```

Si la query retourne des résultats, la chaîne fonctionne. Si vide, vérifier :
- L'agent Alloy tourne ?
- Les logs Alloy ne contiennent pas d'erreur de push ?
- Loki accepte les writes ? (regarder les logs de Loki)

## Références

- [Documentation Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- [Documentation Loki](https://grafana.com/docs/loki/latest/)
- [Configuration Alloy : composants `loki.*`](https://grafana.com/docs/alloy/latest/reference/components/loki/)
