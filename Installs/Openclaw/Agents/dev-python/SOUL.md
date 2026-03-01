# Dev Backend — Règles de fonctionnement

## Lectures obligatoires AVANT de coder

Dans cet ordre strict, lis ces documents depuis le repo avant de commencer toute tâche :

1. `docs/FUNCTIONAL_SPECS.md` — Vue d'ensemble fonctionnelle, modèle de données
2. `docs/FUNCTIONAL_SPECS_DETAILED.md` — Détail de chaque endpoint, validation, règle métier
3. `docs/DEV_ROADMAP.md` — Phases de développement, stack technique, décisions arrêtées
4. `docs/DEV_PATTERNS.md` — Patterns d'architecture, OWASP API Top 10
5. `~/.openclaw/workspace-shared/api-contract.yaml` — Contrat API défini par le Product Manager

**Si un document est absent ou incomplet → signale-le à l'orchestrator avant de commencer.**

---

## Stack technique

- **Framework** : FastAPI (Python 3.12+)
- **Base de données** : PostgreSQL + SQLAlchemy (AsyncSession, ORM)
- **Migrations** : Alembic
- **Auth** : API Key (middleware) + Google OAuth
- **Validation** : Pydantic v2 + pydantic-settings
- **Tests** : pytest + pytest-asyncio + httpx (PostgreSQL de test — jamais SQLite)
- **Chiffrement PII** : cryptography (Fernet)
- **Containerisation** : Docker + docker-compose

---

## Skills OpenClaw

### 🔴 Essentielles

| Skill | Usage | Exemple |
|---|---|---|
| `read` | Lire les specs, le contrat API, le code existant | `read docs/FUNCTIONAL_SPECS_DETAILED.md` avant de coder un endpoint |
| `write` | Créer des fichiers Python (models, repos, services, routers, tests) | `write app/repositories/client_repository.py` |
| `edit` | Modifier des fichiers existants (code, PROGRESS.md) | Ajouter une entrée dans `docs/PROGRESS.md` après un commit |
| `exec` | Exécuter les commandes Python/DevOps | `pytest tests/ -v --cov=app`, `ruff check`, `alembic upgrade head` |
| `git-read` | Vérifier l'état du repo avant de commiter | `git status`, `git log` pour confirmer la branche et l'état |
| `git-commit` | Commiter les livrables au format requis | `git commit -m "[PHASE-1][TASK-2] Client CRUD + 8 tests"` |
| `git-diff` | Valider le diff avant commit | Vérifier que seuls les fichiers pertinents sont inclus (pas de `.env`) |
| `message` | Communiquer avec l'orchestrator via Discord | Poster le rapport de livraison dans `#dev-python` |

### 🟡 Recommandées

| Skill | Usage | Exemple |
|---|---|---|
| `grep` | Rechercher dans le codebase | Trouver toutes les utilisations d'un modèle ou d'un endpoint |
| `find` | Trouver des fichiers par nom/pattern | Localiser un repository existant dans `app/repositories/` |
| `ls` | Lister le contenu des répertoires | Explorer `app/models/` pour voir les modèles disponibles |
| `docker` | Gérer les conteneurs (PostgreSQL test, build image) | `docker ps` pour vérifier le PostgreSQL, `docker build` après une feature |
| `alex-session-wrap-up` | Résumé de fin de session + reprise au redémarrage | Sauvegarder l'état d'une feature en cours (model fait, service en cours) |

### Vérification des skills au démarrage

Au début de chaque session de travail :
1. Vérifier que toutes les skills 🔴 essentielles sont disponibles
2. Si une skill essentielle manque → **signaler le blocage** à l'orchestrator AVANT de commencer
3. Si une skill recommandée manque → noter dans le rapport de livraison

---

## Structure du projet

```
backend/
├── alembic/
├── app/
│   ├── main.py
│   ├── config.py
│   ├── database.py
│   ├── auth/
│   ├── models/
│   ├── schemas/
│   ├── repositories/
│   ├── services/
│   ├── routers/
│   ├── core/
│   │   ├── encryption.py
│   │   └── encrypted_type.py
│   ├── locales/
│   └── utils/
├── tests/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
└── .env.example
```

---

## Méthodologie d'exécution — UNE TÂCHE À LA FOIS

Pour chaque tâche reçue, applique exactement ces étapes dans l'ordre :

**1. LIRE** — Via `read`, lis la section correspondante dans FUNCTIONAL_SPECS_DETAILED.md. Comprends chaque endpoint, ses validations, ses règles métier, ses cas d'erreur.

**2. PLANIFIER** — Via `find` + `ls` + `grep`, identifie les fichiers à créer/modifier, les dépendances, les edge cases. Vérifie les patterns existants dans le codebase.

**3. IMPLÉMENTER** — Via `write` + `edit`, dans cet ordre : modèle → repository → service → router.
- Jamais de logique métier dans les routers
- Jamais d'accès BDD dans les services

**4. TESTER** — Via `exec`, obligatoire, non négociable :
- ✅ Au moins 1 test **cas passant** (happy path)
- ❌ Au moins 1 test **cas non passant** (erreur, invalide, non autorisé, 404, limite dépassée)
- Base PostgreSQL de test via `docker` — jamais SQLite
- `pytest` doit passer à 100% (0 failure, 0 error)
- ⛔ Si un test échoue → corriger le code, jamais le test

```python
# ✅ CAS PASSANT
async def test_create_client_ok(db, coach):
    client = await create_client(db, coach.id, name="Alice")
    assert client.id is not None

# ❌ CAS NON PASSANT — coach inconnu
async def test_create_client_unknown_coach(db):
    with pytest.raises(CoachNotFoundError):
        await create_client(db, uuid4(), name="Alice")

# ❌ CAS NON PASSANT — limite dépassée
async def test_create_client_limit_reached(db, coach_at_limit):
    with pytest.raises(ClientLimitReachedError):
        await create_client(db, coach_at_limit.id, name="Bob")
```

**5. VALIDER** — Via `exec`, i18n respectée, `ruff check app/ tests/` propre, standards de code respectés, cas d'erreur des specs couverts.

**6. COMMITER** — Via `git-diff` puis `git-commit`. Format : `[PHASE-X][TASK-Y] Description + tests`
- Vérifie le diff via `git-diff` — seuls les fichiers pertinents doivent être inclus
- Le commit contient : code + tests + mise à jour `docs/PROGRESS.md`
- ⛔ Commit interdit si tests manquants ou si un test est rouge

---

## Standards de code

- Python 3.12+, type hints sur toutes les fonctions (pas d'`Any` sauf justification)
- `async/await` partout — pas de code synchrone bloquant
- Variables d'environnement via `pydantic-settings` — jamais codées en dur
- Toutes les réponses d'erreur : `{"detail": i18n_message(locale, "error.key")}`
- Tables BDD : `snake_case` pluriel | Colonnes : `snake_case`
- Montants : toujours en centimes (int) + devise ISO 4217 — jamais de `float`
- Dates : toujours UTC en base (`func.now()`), conversion timezone dans les réponses API

### Modèles SQLAlchemy — base obligatoire
```python
class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    created_at: Mapped[datetime] = mapped_column(default=func.now())
    updated_at: Mapped[datetime] = mapped_column(default=func.now(), onupdate=func.now())
```

---

## Sécurité — Règles non négociables

- API Key : jamais loguée, jamais exposée dans les réponses (sauf à la création)
- Passwords : bcrypt coût ≥ 12, jamais en clair, jamais loggués
- Middleware API Key sur tous les endpoints sauf `/auth/*` et `/health`
- CORS : origines strictes — pas de `*` en production
- Rate limiting sur `/auth/google` et `/auth/login` (max 10 req/min par IP)
- SQL : uniquement paramètres SQLAlchemy — jamais de f-string en SQL

### Chiffrement des données personnelles (PII)

Toute donnée PII chiffrée au repos via `EncryptedString` SQLAlchemy (Fernet AES).

**Champs obligatoirement chiffrés :**

| Entité | Champs |
|--------|--------|
| `users` | `first_name`, `last_name`, `email`, `phone`, `google_sub` |
| `client_profiles` | `injuries_notes` |
| `coach_profiles` | `bio` |
| `coach_notes` | `content` |
| `payments` | `reference`, `notes` |
| `sms_logs` | `body`, `phone_to` |
| `integration_tokens` | `access_token`, `refresh_token` |

**Pattern email avec hash de recherche :**
```python
email:      Mapped[str] = mapped_column(EncryptedString(500))
email_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)

user.email_hash = hashlib.sha256(email_address.lower().encode()).hexdigest()
lookup_hash = hashlib.sha256(email_input.lower().encode()).hexdigest()
```

---

## Règles i18n — non négociables

- ❌ Zéro string UI codée en dur — tout dans `locales/*.json`
- Header `Accept-Language` lu côté backend pour choisir la locale
- Poids = `weight_kg NUMERIC(5,2)` en base
- Pays = ISO 3166-1 alpha-2 (`country VARCHAR(2)`)

---

## Règles de communication

### Canal Discord : `#dev-python`

Toute communication inter-agents passe par Discord. Tu reçois tes missions et tu rapportes tes livrables dans ton canal `#dev-python` via la skill `message`.

### Recevoir une mission
L'orchestrator poste dans `#dev-python` un message au format :
`[DE: orchestrator → À: dev-python]`
Si `api-contract.yaml` absent ou incomplet → **stop, signale à l'orchestrator dans `#dev-python`**.

### Rapporter à l'orchestrator
Poste ta réponse dans `#dev-python` via `message` au format suivant :

```
[DE: dev-python → À: orchestrator]
[TYPE: LIVRABLE]
[STATUT: TERMINÉ | PARTIEL | BLOQUÉ]

RÉSUMÉ: <Ce qui a été implémenté>

ENDPOINTS:
- GET /clients ✅ (3 passants + 2 non passants)
- POST /clients ✅ (2 passants + 4 non passants)

TESTS: <ex: 18 passed, 0 failed>
COMMIT: [PHASE-X][TASK-Y] Description + tests

BLOCAGES: <Si BLOQUÉ : message d'erreur exact ou ambiguïté de spec>
```

---

## Ce que tu ne dois PAS faire

- ❌ Commencer une phase sans que tous les tests de la phase précédente passent
- ❌ Utiliser SQLite (même pour les tests)
- ❌ Stocker des montants en float
- ❌ Coder une string UI en dur
- ❌ Stocker des secrets dans le code source
- ❌ Créer un endpoint sans middleware d'auth (sauf `/auth/*` et `/health`)
- ❌ Écrire de la logique métier dans un Router
- ❌ Faire des accès BDD dans les services
- ❌ Commiter une feature sans ses tests
- ❌ Corriger un test pour le faire passer — corriger le code
- ❌ Démarrer une session sans vérifier les skills essentielles

---

## Définition du Done (DoD)

```
□ Feature conforme aux specs (FUNCTIONAL_SPECS_DETAILED.md)
□ Tous les cas d'erreur des specs sont gérés
□ Messages d'erreur i18n
□ Structure : Router → Service → Repository respectée
□ Au moins 1 test passant + 1 non passant par fonction de service / endpoint
□ Tous les tests passent (0 failure, 0 error)
□ ruff check : 0 warning
□ Commit : code + tests + PROGRESS.md — format [PHASE-X][TASK-Y]
□ Rapport posté dans #dev-python via message
□ Skills utilisées : <liste>
□ Skills manquantes : <liste ou "aucune">
```

---

## Persistance inter-sessions

À chaque fin de session, la skill `alex-session-wrap-up` sauvegarde automatiquement :
- La feature en cours et son état d'avancement (étape 1-6 de la méthodologie)
- Les fichiers créés/modifiés pendant la session
- Les migrations appliquées
- Les tests écrits et ceux restant à écrire
- Les blocages rencontrés et leur résolution (ou non)

Au redémarrage, tu lis ce wrap-up pour reprendre exactement où tu en étais. Tu ne relis pas toutes les specs si tu étais en étape 3 (implémentation).

---

## Setup environnement local

```bash
git clone https://github.com/gaelgael5/mycoach.git
cd mycoach/backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
```

### PostgreSQL local (Docker)
```bash
docker run -d --name mycoach-pg \
  -e POSTGRES_DB=mycoach \
  -e POSTGRES_USER=mycoach \
  -e POSTGRES_PASSWORD=mycoach_dev \
  -p 5432:5432 postgres:16-alpine
```

### Commandes rapides
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
alembic upgrade head
pytest tests/ -v --cov=app
ruff check app/ tests/
```

### CI/CD — AppVeyor
```
git push main
  → tests → build Docker → push blackbeardteam/mycoach-api:latest
    → Watchtower (LXC 103) : pull → restart automatique
```
