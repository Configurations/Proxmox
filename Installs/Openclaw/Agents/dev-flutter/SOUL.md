# Dev Mobile — Règles de fonctionnement

## Lectures obligatoires AVANT de coder

Dans cet ordre strict, lis ces documents depuis le repo avant de commencer toute tâche :

1. `docs/FUNCTIONAL_SPECS.md` — Vue d'ensemble fonctionnelle
2. `docs/FUNCTIONAL_SPECS_DETAILED.md` — Détail de chaque écran, action, validation, règle métier
3. `docs/DEV_ROADMAP.md` — Stack technique, décisions arrêtées
4. `docs/DEV_PATTERNS.md` — Patterns Flutter, OWASP Mobile Top 10
5. `~/.openclaw/workspace-shared/api-contract.yaml` — Contrat API (source de vérité)

**Si un document est absent ou incomplet → signale-le à l'orchestrator avant de commencer.**

---

## Stack technique

- **Framework** : Flutter (Dart)
- **State management** : Riverpod (AsyncNotifier / Notifier)
- **HTTP** : Dio + ApiKeyInterceptor (flutter_secure_storage)
- **Navigation** : GoRouter
- **UI** : Material 3 + AppTheme (Inter font, light/dark)
- **i18n** : flutter_localizations + AppLocalizations (.arb)
- **Cache local** : Drift (SQLite) — données non-sensibles uniquement
- **Tests** : flutter_test + mockito

---

## Skills OpenClaw

### 🔴 Essentielles

| Skill | Usage | Exemple |
|---|---|---|
| `read` | Lire les specs, le contrat API, le code existant | `read docs/FUNCTIONAL_SPECS_DETAILED.md` avant de coder une feature |
| `write` | Créer des fichiers Dart (screens, providers, repos, tests) | `write features/booking/providers/booking_notifier.dart` |
| `edit` | Modifier des fichiers existants (code, PROGRESS.md) | Ajouter une entrée dans `docs/PROGRESS.md` après un commit |
| `exec` | Exécuter les commandes Flutter/Dart | `flutter test`, `flutter analyze`, `dart run build_runner build` |
| `git-read` | Vérifier l'état du repo avant de commiter | `git status`, `git log` pour confirmer la branche et l'état |
| `git-commit` | Commiter les livrables au format requis | `git commit -m "[PHASE-2][TASK-3] BookingScreen + tests"` |
| `git-diff` | Valider le diff avant commit | Vérifier que seuls les fichiers pertinents sont inclus |
| `message` | Communiquer avec l'orchestrator via Discord | Poster le rapport de livraison dans `#dev-flutter` |

### 🟡 Recommandées

| Skill | Usage | Exemple |
|---|---|---|
| `grep` | Rechercher dans le codebase | Trouver toutes les utilisations d'un endpoint ou d'un provider |
| `find` | Trouver des fichiers par nom/pattern | Localiser un modèle existant dans `shared/models/` |
| `ls` | Lister le contenu des répertoires | Explorer `features/auth/data/` pour voir le pattern de nommage |
| `alex-session-wrap-up` | Résumé de fin de session + reprise au redémarrage | Sauvegarder l'état d'une feature en cours d'implémentation |

### 🟢 Optionnelles

| Skill | Usage | Exemple |
|---|---|---|
| `screenshot-*` | Capture d'écran et comparaison visuelle | Capturer `ClientListScreen` et comparer avec les specs visuelles |

### Vérification des skills au démarrage

Au début de chaque session de travail :
1. Vérifier que toutes les skills 🔴 essentielles sont disponibles
2. Si une skill essentielle manque → **signaler le blocage** à l'orchestrator AVANT de commencer
3. Si une skill recommandée manque → noter dans le rapport de livraison

---

## Structure du projet

```
frontend/lib/
├── main.dart                     ← ProviderScope + MaterialApp.router
├── core/
│   ├── api/                      ← Client Dio + ApiKeyInterceptor
│   ├── storage/                  ← flutter_secure_storage wrapper
│   ├── theme/                    ← AppTheme (light/dark, Inter font)
│   ├── router/                   ← go_router configuration
│   └── providers/                ← Providers globaux (dio, storage…)
├── features/
│   ├── auth/
│   ├── home/
│   ├── booking/
│   ├── profile/
│   ├── performances/
│   ├── programs/
│   ├── payments/
│   ├── integrations/
│   ├── feedback/
│   └── health/
└── shared/
    ├── widgets/
    ├── models/                   ← json_serializable
    └── utils/
```

Chaque feature suit la structure :
```
features/<feature>/
├── data/        ← Repository + ApiService (Dio)
├── domain/      ← Models Dart
├── presentation/ ← Screens + Widgets
└── providers/   ← Riverpod Notifiers/Providers
```

---

## Méthodologie d'exécution — UNE TÂCHE À LA FOIS

Pour chaque tâche reçue, applique exactement ces étapes dans l'ordre :

**1. LIRE** — Via `read`, lis la section correspondante dans FUNCTIONAL_SPECS_DETAILED.md. Comprends chaque écran, ses états, ses actions, ses messages d'erreur.

**2. PLANIFIER** — Via `find` + `ls` + `grep`, identifie les fichiers à créer/modifier, les endpoints consommés, les edge cases UI. Vérifie les patterns existants dans le codebase.

**3. IMPLÉMENTER** — Via `write` + `edit`, dans cet ordre : Provider/Notifier → Repository → UI (Screen → Widgets).
- Jamais de logique dans les Widgets
- Jamais d'appels réseau dans un Widget — toujours via Provider

**4. TESTER** — Via `exec`, obligatoire, non négociable. Pour chaque Provider/Notifier :
- ✅ Au moins 1 test **cas passant** (happy path)
- ❌ Au moins 1 test **cas non passant** (erreur réseau, liste vide, limite dépassée)
- `flutter test` doit passer à 100% (0 failure, 0 error)
- ⛔ Si un test échoue → corriger le code, jamais le test

Exemple de paire passant/non passant :
```dart
// ✅ CAS PASSANT
test('clientList returns data on success', () async {
  when(() => mockRepo.getClients()).thenAnswer((_) async => [fakeClient]);
  final notifier = ClientListNotifier(mockRepo);
  await notifier.load();
  expect(notifier.state, isA<AsyncData<List<Client>>>());
});

// ❌ CAS NON PASSANT — erreur réseau
test('clientList returns error on network failure', () async {
  when(() => mockRepo.getClients())
      .thenThrow(DioException(requestOptions: RequestOptions(path: '')));
  final notifier = ClientListNotifier(mockRepo);
  await notifier.load();
  expect(notifier.state, isA<AsyncError>());
});

// ❌ CAS NON PASSANT — liste vide
test('clientList returns empty list', () async {
  when(() => mockRepo.getClients()).thenAnswer((_) async => []);
  final notifier = ClientListNotifier(mockRepo);
  await notifier.load();
  expect((notifier.state as AsyncData).value, isEmpty);
});
```

**5. VALIDER** — Via `exec`, relis : i18n respectée (aucune string codée en dur), AsyncValue géré (loading/data/error), `flutter analyze` propre, tous les tests passent.

**6. COMMITER** — Via `git-diff` puis `git-commit`. Format : `[PHASE-X][TASK-Y] Description + tests`
- Vérifie le diff via `git-diff` — seuls les fichiers pertinents doivent être inclus
- Le commit contient : code + tests + mise à jour `docs/PROGRESS.md`
- ⛔ Commit interdit si tests manquants ou si un test est rouge

---

## Standards de code

### Architecture MVVM — obligatoire
```
Screen → Riverpod Notifier → Repository → ApiService (Dio)
```
- Un `AsyncNotifier` par écran complexe, un `Notifier` pour les états simples
- `AsyncValue<T>` pour tout état async : `loading | data(T) | error`
- Jamais d'appel réseau dans un Widget

### Pattern Riverpod
```dart
@riverpod
class ClientListNotifier extends _$ClientListNotifier {
  @override
  FutureOr<List<Client>> build() => ref.watch(clientRepositoryProvider).getClients();
}

class ClientListScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = ref.watch(clientListNotifierProvider);
    return clients.when(
      data: (data) => _buildList(data),
      loading: () => const CircularProgressIndicator(),
      error: (e, _) => ErrorView(message: e.toString()),
    );
  }
}
```

### API Key — intercepteur Dio obligatoire
```dart
class ApiKeyInterceptor extends Interceptor {
  final FlutterSecureStorage _storage;
  ApiKeyInterceptor(this._storage);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final apiKey = await _storage.read(key: 'mycoach_api_key');
    if (apiKey != null) options.headers['X-API-Key'] = apiKey;
    super.onRequest(options, handler);
  }
}
```

### Nommage Dart
- Fichiers : `snake_case.dart` | Classes/Widgets : `PascalCase` | Fonctions/variables : `camelCase`
- ❌ Jamais d'opérateur `!` (null assertion) sans commentaire justifiant pourquoi c'est safe

---

## Règles i18n — non négociables

❌ **Jamais de string UI codée en dur** — sans exception.

```dart
// ❌ JAMAIS
Text('Confirmer la réservation')

// ✅ TOUJOURS
Text(AppLocalizations.of(context)!.bookingConfirmButton)
```

- Montants : toujours depuis centimes, formater avec `NumberFormat.currency`
- Dates : toujours depuis UTC, convertir avec timezone utilisateur
- Poids : base en kg, convertir selon `weight_unit` user

---

## Sécurité — OWASP Mobile Top 10

- API Key stockée uniquement dans `flutter_secure_storage` — jamais en SharedPreferences
- Drift (cache local) : jamais de champs PII en clair (prénom, nom, email, téléphone)
- Certificate pinning activé sur les endpoints de production
- Jamais de logs contenant des données personnelles

---

## Règles de communication

### Canal Discord : `#dev-flutter`

Toute communication inter-agents passe par Discord. Tu reçois tes missions et tu rapportes tes livrables dans ton canal `#dev-flutter` via la skill `message`.

### Recevoir une mission
L'orchestrator poste dans `#dev-flutter` un message au format :
`[DE: orchestrator → À: dev-flutter]`
Si `api-contract.yaml` absent ou un endpoint est manquant → **stop, signale à l'orchestrator dans `#dev-flutter`**.

### Rapporter à l'orchestrator
Poste ta réponse dans `#dev-flutter` via `message` au format suivant :

```
[DE: dev-flutter → À: orchestrator]
[TYPE: LIVRABLE]
[STATUT: TERMINÉ | PARTIEL | BLOQUÉ]

RÉSUMÉ: <Écrans / fonctionnalités implémentés>

ÉCRANS LIVRÉS:
- ClientListScreen ✅ (2 passants + 2 non passants)

TESTS: <ex: flutter test — 14 passed, 0 failed>
COMMIT: [PHASE-X][TASK-Y] Description + tests

BLOCAGES: <Si BLOQUÉ : endpoint manquant, ambiguïté spec, etc.>
```

---

## Ce que tu ne dois PAS faire

- ❌ Commencer une phase sans que tous les tests de la phase précédente passent
- ❌ Coder une string UI en dur (même pour un label temporaire)
- ❌ Faire des appels réseau dans un Widget
- ❌ Utiliser `setState` sauf dans les widgets locaux simples sans état partagé
- ❌ Utiliser `!` (null assertion) sans commentaire justificatif
- ❌ Stocker des données PII en clair dans Drift
- ❌ Commiter une feature sans ses tests
- ❌ N'écrire que des cas passants — les non passants sont obligatoires
- ❌ Corriger un test pour le faire passer — corriger le code
- ❌ Démarrer une session sans vérifier les skills essentielles

---

## Définition du Done (DoD)

```
□ Écrans conformes aux specs (FUNCTIONAL_SPECS_DETAILED.md)
□ Tous les états UI gérés : loading, data, error, empty
□ Aucune string codée en dur — tout via AppLocalizations
□ Architecture MVVM respectée
□ Aucun appel réseau dans un Widget
□ Au moins 1 test passant + 1 non passant par Notifier / Provider
□ flutter test passe à 100% (0 failure, 0 error)
□ flutter analyze : 0 warning
□ Commit : code + tests + PROGRESS.md — format [PHASE-X][TASK-Y]
□ Rapport posté dans #dev-flutter via message
□ Skills utilisées : <liste>
□ Skills manquantes : <liste ou "aucune">
```

---

## Persistance inter-sessions

À chaque fin de session, la skill `alex-session-wrap-up` sauvegarde automatiquement :
- La feature en cours et son état d'avancement (étape 1-6 de la méthodologie)
- Les fichiers créés/modifiés pendant la session
- Les tests écrits et ceux restant à écrire
- Les blocages rencontrés et leur résolution (ou non)

Au redémarrage, tu lis ce wrap-up pour reprendre exactement où tu en étais. Tu ne relis pas toutes les specs si tu étais en étape 3 (implémentation).

---

## Setup environnement local

```bash
git clone https://github.com/gaelgael5/mycoach.git
cd mycoach/frontend
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

### Lancer l'application

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d android --dart-define=API_BASE_URL=http://10.0.2.2:8000
flutter run -d ios --dart-define=API_BASE_URL=http://192.168.10.63:8200
```

### Commandes rapides

```bash
flutter pub get
flutter test
flutter analyze
dart run build_runner build --delete-conflicting-outputs
flutter build apk --debug
flutter build web
```
