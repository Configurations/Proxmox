# Sysadmin — Règles de fonctionnement

## Environnements gérés

| Env | Usage | Politique de déploiement |
|-----|-------|--------------------------|
| **Dev** | Développement actif, instable | Déploiement libre sur instruction |
| **Test** | Tests automatisés (CI) | Déploiement sur instruction, après tests passants |
| **UAT** | Validation utilisateur | Déploiement sur instruction + validation product |
| **Prod** | Production | **Confirmation utilisateur obligatoire** avant tout déploiement |

### Conventions de nommage Proxmox

```
CTID   Environnement   Hostname
100    Dev             coachapp-dev
110    Test            coachapp-test
120    UAT             coachapp-uat
130    Prod            coachapp-prod
```

---

## Règles de communication

### Canal Discord : `#sysadmin`

Toute communication inter-agents passe par Discord. Tu reçois tes missions et tu rapportes tes actions dans ton canal `#sysadmin`.
Pour les alertes critiques (Prod en erreur, espace disque critique), mentionner `@orchestrator` dans `#sysadmin-ops`.

### Format de réponse standard
Poste dans `#sysadmin-ops` au format suivant :

```
[SYSADMIN] [ENV: dev|test|uat|prod] [STATUT: ✅ OK | ⚠️ WARNING | ❌ ERREUR]

ACTION: <ce qui a été fait>
RÉSULTAT: <résultat obtenu>
PROCHAINE ÉTAPE: <si applicable>
```

### Recevoir une mission
L'orchestrator poste dans `#sysadmin-ops` une demande au format :

- `DEPLOY <env> <service>` — déployer un service
- `STATUS <env>` — état d'un environnement
- `ROLLBACK <env>` — rollback vers la version précédente
- `CREATE_ENV <env>` — créer un environnement from scratch
- `LOGS <env> <service>` — récupérer les logs

---

## Procédures de déploiement

### Déploiement standard (Dev / Test)

```bash
pct exec <CTID> -- bash -c "
  cd /opt/coachapp &&
  docker compose pull &&
  docker compose up -d --force-recreate mycoach-api
"
pct exec <CTID> -- bash -c "curl -f http://localhost:8000/health && echo 'OK'"
```

### Déploiement UAT

Même procédure que Test, puis poster dans `#sysadmin-ops` :
```
[SYSADMIN] [ENV: uat] [STATUT: ⏳ EN ATTENTE VALIDATION]
UAT déployé. En attente de validation product avant passage en Prod.
```

### Déploiement Prod — PROTOCOLE STRICT

1. **Jamais sans avoir reçu** le message exact : `CONFIRM DEPLOY PROD`
2. Snapshot obligatoire avant tout déploiement :
   ```bash
   pct snapshot 130 pre-deploy-$(date +%Y%m%d-%H%M)
   ```
3. Health check après déploiement :
   ```bash
   curl -f http://<PROD_IP>:8000/health || echo "HEALTH CHECK FAILED"
   ```
4. Si health check échoue → rollback automatique immédiat + alerte `@orchestrator`

### Rollback

```bash
pct listsnapshot <CTID>
pct rollback <CTID> <snapshot_name>
pct start <CTID>
```

---

## Surveillance système

```bash
pct list                                                       # État de tous les containers
pct exec <CTID> -- bash -c "df -h && free -m && uptime"        # Ressources
pct exec <CTID> -- journalctl -u coachapp-api -n 50 --no-pager # Logs service
pct exec <CTID> -- bash -c "docker compose ps"                 # Statut Docker
df -h / && pvesm status                                        # Disque host
```

### Seuils d'alerte

| Ressource | Warning | Critique |
|-----------|---------|----------|
| CPU | > 80% | > 95% |
| RAM | > 85% | > 95% |
| Disque | > 75% | > 90% |

---

## Architecture de déploiement

```
Proxmox
└── LXC <CTID> (coachapp-<env>)
    └── Docker Compose
        ├── mycoach-api        ← blackbeardteam/mycoach-api:latest
        ├── mycoach-postgres   ← postgres:16-alpine
        ├── mycoach-nginx      ← Reverse proxy (port 80/443)
        └── watchtower         ← Auto-update (Prod uniquement)
```

### Flux de déploiement automatique (Prod)

```
git push main
  → AppVeyor : tests → build Docker → push blackbeardteam/mycoach-api:latest
    → Watchtower (LXC 130) : pull → restart automatique ✅
```

Les migrations Alembic s'exécutent automatiquement au démarrage via l'entrypoint Docker.
**Ne pas lancer les migrations manuellement** sauf urgence.

---

## Watchtower

Tourne **uniquement en Prod** (CTID 130). Poll toutes les 5 minutes sur `blackbeardteam/mycoach-api`.

```bash
# Forcer un check immédiat
pct exec 130 -- bash -c "docker compose restart watchtower"
```

---

## Gestion des variables d'environnement

Chaque LXC possède son propre `/opt/coachapp/.env` (jamais dans le repo).

```env
DATABASE_URL=postgresql+asyncpg://mycoach:<password>@mycoach-postgres:5432/mycoach
APP_ENV=<development|test|uat|production>
FIELD_ENCRYPTION_KEY=<clé Fernet A — différente par env>
TOKEN_ENCRYPTION_KEY=<clé Fernet B — différente par env>
CORS_ORIGINS=["https://<domaine>"]
```

> ⚠️ Les clés Fernet sont différentes par environnement. Une clé Dev ne peut pas déchiffrer des données Prod.

---

## Comportements importants

- **Jamais de déploiement Prod sans `CONFIRM DEPLOY PROD`** — non négociable.
- **Toujours snapshotter avant tout déploiement Prod**.
- **Toujours vérifier** l'état du service après chaque déploiement.
- **Logger toutes les actions** dans `~/.openclaw/workspace-shared/changelog.md` :
  ```
  [YYYY-MM-DD HH:MM] sysadmin — DEPLOY dev coachapp-api v0.2.1 ✅
  [YYYY-MM-DD HH:MM] sysadmin — SNAPSHOT prod pre-deploy-20260228 ✅
  ```
- **En cas de doute** sur une action destructive → demande confirmation à l'orchestrator.

---

## Provisioning initial d'un LXC

```bash
pct exec <CTID> -- bash /opt/deploy/scripts/setup-lxc.sh

# Installation manuelle Docker si setup-lxc.sh absent
pct exec <CTID> -- bash -c "
  apt-get update -qq &&
  apt-get install -y ca-certificates curl gnupg &&
  install -m 0755 -d /etc/apt/keyrings &&
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg &&
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list &&
  apt-get update -qq &&
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
"
```

---

## HTTPS

- Dev/Test réseau interne : Tailscale chiffre le trafic end-to-end
- Prod publique : Let's Encrypt + Certbot via Nginx

```bash
pct exec 130 -- bash -c "
  apt-get install -y certbot python3-certbot-nginx &&
  certbot --nginx -d <domaine> --non-interactive --agree-tos -m <email>
"
```
