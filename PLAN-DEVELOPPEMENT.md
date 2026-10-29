# git-tools — Plan de développement V1

> Source : `git-tools — Analyse fonctionnelle.md` (exigences SA, VI, TR, RG, ENF, scénarios R-xx).
> Agents : `.claude/agents/*.md`. Chaque lot indique l'agent **pilote** (qui produit) et les **relecteurs** (qui valident).
> Principe directeur repris de l'AF §8 : *dans le doute, le système n'agit pas.*

---

## 1. Rôle des agents dans le projet

| Agent | Rôle sur git-tools | Intervient sur |
| --- | --- | --- |
| 🏛️ Software Architect | ADR, découpage en modules, contrats d'API du visualiseur, sens des dépendances | L0, L1, L5, arbitrages |
| 🌿 Git Workflow Master | Modèle de stockage des points de reprise (refs, séries, nettoyage, push), commandes git sûres, conventions du dépôt git-tools lui-même | L0, L2, L3, L7 |
| 🛠️ Developer Tooling Engineer | CLI `git autosave` / `git viewer`, aide, codes de sortie, messages d'erreur qui donnent la solution, installation/désinstallation idempotentes | L3, L4, L5 |
| 📐 UX Architect | Architecture de l'interface, système CSS (variables, thèmes clair/sombre, 375 px), hiérarchie de l'information | L6 |
| 🎨 UI Designer | Langage visuel : graphe, distinction points de reprise / commits, états, confirmations | L6, L7 |
| 🖥️ Frontend Developer | Implémentation de la page (vanilla JS, sans build ni CDN), rendu du graphe, appels API | L6, L7 |
| 👁️ Code Reviewer | Revue de chaque lot avant fusion (🔴 / 🟡 / 💭) — sécurité, robustesse, chemins avec accents | Tous les lots |
| 🎭 Test Automation Engineer | Tests unitaires Pester, scénarios R-xx automatisés, E2E Playwright du visualiseur | L2 → L8 |
| 🧱 UI Finish-Gate Reviewer | Porte de sortie de l'interface : rien de « générique », contrat de design respecté | Fin de L6 et L7 |
| 🧐 Reality Checker | Porte de sortie de chaque jalon : statut « NEEDS WORK » tant que la preuve (journal, capture, sortie de test) manque | Fin de L2, L4, L8 |
| 🖥️ Terminal Integration Specialist | **Non utilisé** : spécialisé SwiftTerm/Swift, hors sujet pour un outil Windows/PowerShell | — |

### Ajustements à faire sur les agents avant de démarrer

- [x] Le champ `name` contient des espaces et des majuscules (`UI Designer`, `Code Reviewer`…). Claude Code attend un identifiant en minuscules avec tirets : renommer en `ui-designer`, `code-reviewer`, etc. (le nom de fichier sans le préfixe convient).
- [x] **Frontend Developer** pousse React/Vue/Angular par défaut : préciser dans le brief « HTML/CSS/JS vanilla, aucun framework, aucune étape de build, aucun CDN » (ENF-05, sans internet).
- [ ] **UX Architect** impose déjà un sélecteur de thème clair/sombre/système : cohérent avec ENF-11, à garder.
- [ ] **Reality Checker** exige des captures : les fournir via Playwright (L8) et les journaux de recette.
- [x] **Terminal Integration Specialist** déplacé dans `.claude/agents-desactives/`.

---

## 2. Architecture cible (proposition à valider en L0)

**Contraintes structurantes** : Windows 10 21H2+ / 11, git seul prérequis, sans internet, sans droits admin, stratégie PowerShell `RemoteSigned` imposée par GPO (MachinePolicy) — donc **aucun `-ExecutionPolicy Bypass`** (ce serait un contournement, FC3).

**Choix proposé** : PowerShell 5.1 (présent sur tous les postes) + page HTML locale servie par le visualiseur. Pas d'exécutable compilé (risque AppLocker / programmes non signés, point ouvert §11).

```
git-tools/
├─ install.ps1 / uninstall.ps1           # TR-01, TR-06, TR-07 (idempotents)
├─ common/GitTools.Common.psm1           # appel git (UTF-8, sans invite), config, chemins, journal 1 Mo
├─ autosave/
│  ├─ GitAutosave.psm1                   # moteur : passage, série, nettoyage, restauration
│  ├─ git-autosave.cmd                   # point d'entrée « git autosave » (sur le PATH utilisateur)
│  └─ hooks/post-commit                  # nettoyage immédiat (SA-05) si aucun hook existant (RG-09)
├─ viewer/
│  ├─ GitViewer.psm1 / server.ps1        # serveur 127.0.0.1, API JSON, instance unique
│  ├─ git-viewer.cmd
│  └─ www/ index.html app.js graph.js styles.css
├─ tests/  unit/ (Pester 3.4)  scenarios/ (R-xx)  e2e/ (Playwright, poste de dev)
└─ docs/GUIDE.md                          # TR-09, 7 thèmes
```

**Données utilisateur** : `%LOCALAPPDATA%\git-tools\` → `config.json`, `projects.json`, `recent.json`, `logs\autosave.log`, `logs\viewer.log`, `viewer.lock`. Rien d'autre n'est écrit hors de cet emplacement et des projets (ENF-15).

### Décisions techniques clés (ADR à rédiger — Software Architect + Git Workflow Master)

| ADR | Sujet | Proposition | Exigences |
| --- | --- | --- | --- |
| ADR-01 | Stockage des points de reprise | Refs cachées `refs/autosave/<branche>/<sha-base>` plutôt que des branches : n'apparaissent pas dans `git branch`, ne gênent pas l'utilisateur. Chaque point = commit dont le parent est le point précédent (ou la base). Message `Autosave 01 — 29/10/2026 14:30`. | SA-03, RG-01, FC1 |
| ADR-02 | Capture sans toucher l'index | Index temporaire : `GIT_INDEX_FILE=<tmp>` → `read-tree HEAD` → `add -A` → `write-tree` → `commit-tree` → `update-ref`. L'index, la branche et les fichiers réels ne sont jamais écrits. `add -A` respecte `.gitignore`. | SA-01, SA-04, RG-07, ENF-01 |
| ADR-03 | « Rien n'a changé » | Comparer l'arbre obtenu à l'arbre du dernier point de la série (ou de la base) : identique → aucun commit. | SA-02 |
| ADR-04 | Ne pas gêner l'utilisateur | Toutes les commandes git du produit avec `-c gc.auto=0`, `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `GIT_OPTIONAL_LOCKS=0` ; jamais de verrou sur l'index réel. | ENF-03, ENF-08 |
| ADR-05 | Planification | Tâche planifiée utilisateur (`Register-ScheduledTask`, sans élévation), `MultipleInstances = IgnoreNew` + mutex nommé `Local\git-tools-autosave`. Lanceur sans fenêtre : à trancher en L1. | FC2, RG-10, ENF-02 |
| ADR-06 | Nettoyage | Hook `post-commit` installé seulement si absent (et en tenant compte de `core.hooksPath`) ; sinon nettoyage au passage suivant. Série obsolète = branche avancée ou disparue. | SA-05, SA-06, RG-02, RG-03, RG-09 |
| ADR-07 | Restauration | `git restore --source=<point> --worktree -- .` ; **avant** de restaurer, prendre un point de reprise de l'état courant (filet de sécurité). Branche et index inchangés. | SA-08, VI-16, ENF-01 |
| ADR-08 | Serveur du visualiseur | Écoute sur `127.0.0.1` uniquement (TcpListener, pas d'ACL d'URL à réserver) ; contrôle de l'en-tête `Host` (anti-DNS-rebinding) et de l'`Origin` ; jeton aléatoire injecté dans la page et exigé sur toute action. | FC5, ENF-07, ENF-15 |
| ADR-09 | Instance unique | Mutex `Local\git-tools-viewer` + `viewer.lock` (port, PID). Un 2ᵉ lancement envoie `POST /api/open` à l'instance existante puis se termine. Un onglet n'est ouvert que si aucune page n'a donné signe de vie depuis quelques secondes. | VI-31, RG-27, R-10 |
| ADR-10 | Rafraîchissement | La page interroge `/api/state` (empreinte : HEAD, refs, index, statut) toutes les 1 s au premier plan, 5 s en arrière-plan ; rechargement ciblé si l'empreinte change. Plus simple et plus robuste que des notifications poussées en PowerShell. | VI-08, VI-06, ENF-04 |
| ADR-11 | Graphe | `git log --all --date-order -n 400 --parents --format=…` ; disposition des colonnes calculée côté navigateur, branche principale à gauche, refs `autosave` masquables. | VI-01, VI-02, ENF-13 |

---

## 3. Lots de développement

Ordre : **L0 → L1 → (L2 ∥ L5) → L3 → L4 → L6 → L7 → L8 → L9**. L8 (tests) avance en continu, sa partie finale clôt la V1.

### L0 — Reprise et cadrage
**Pilote** : Software Architect · **Relecteurs** : Git Workflow Master, Reality Checker

- [ ] Récupérer le code existant (`E:\PROJETS\Git-tools\git-tools`) dans ce dossier, premier commit « état de reprise ».
- [ ] Code Reviewer + Reality Checker : **matrice de couverture** exigence par exigence (fait / partiel / absent / non conforme) sur l'existant → décide de ce qu'on garde.
- [ ] Rédiger ADR-01 à ADR-11 (`docs/adr/`).
- [ ] Trancher les points ouverts bloquants (§5).
- [ ] Git Workflow Master : conventions du dépôt git-tools (trunk-based, une branche par lot `feat/l2-moteur-autosave`, Conventional Commits, tag `v1.0.0`).

**Sortie** : ADR validés, matrice de couverture, backlog ordonné.

### L1 — Levées de risque (spikes, ~1 j chacun, sur poste réel Orano)
**Pilote** : Developer Tooling Engineer · **Relecteurs** : Software Architect, Reality Checker

| Spike | Question | Options |
| --- | --- | --- |
| S1 | Lancer PowerShell **sans aucune fenêtre** depuis le planificateur | `conhost.exe --headless`, lanceur `wscript` + `.vbs` (VBScript en voie de retrait par Microsoft), tâche « exécuter même si l'utilisateur n'est pas connecté » (demande le mot de passe — à éviter) |
| S2 | Détacher le visualiseur du terminal (VI-30 : fermer le terminal sans effet) | `Start-Process` caché, `Win32_Process.Create` via CIM, `conhost --headless` |
| S3 | Écoute HTTP sans droits admin | `TcpListener 127.0.0.1` vs `HttpListener http://localhost:port/` |
| S4 | Fichiers téléchargés bloqués (Mark-of-the-Web + RemoteSigned) | Message clair + procédure `Unblock-File` documentée (R-18) |
| S5 | Encodage et chemins | Sortie git UTF-8 en PS 5.1, chemins avec espaces et accents (ENF-14), `core.quotepath=false` |
| S6 | Tâche planifiée et PATH utilisateur sans élévation | `Register-ScheduledTask` utilisateur courant, `HKCU\Environment` (R-19) |

**Sortie** : une note par spike (résultat observé, capture), choix reporté dans les ADR.

### L2 — Moteur de sauvegarde automatique
**Pilote** : Git Workflow Master (conception) + Developer Tooling Engineer (code) · **Tests** : Test Automation Engineer · **Revue** : Code Reviewer

Exigences : SA-01 à SA-06, SA-08, RG-01 à RG-08, RG-11, ENF-01, ENF-03, ENF-09.

- [ ] Module commun : appel git encapsulé (env. ADR-04, UTF-8, codes de retour), journal tournant 1 Mo (ENF-10).
- [ ] Passage sur un projet : garde-fous RG-04 (fusion/rebase/cherry-pick/revert en cours), RG-05 (HEAD détaché), RG-06 (aucun commit), RG-08 (projet disparu).
- [ ] Capture par index temporaire (ADR-02), détection « rien n'a changé » (ADR-03), numérotation 01, 02… (SA-03).
- [ ] Nettoyage des séries obsolètes + option de conservation (SA-05, SA-06, RG-02).
- [ ] Restauration avec filet de sécurité (ADR-07).
- [ ] Isolation des erreurs : un projet en échec n'empêche pas les autres (ENF-09).
- [ ] Tests Pester (unitaires sur dépôts temporaires) + scénarios **R-01 à R-06, R-08** automatisés.

**Porte** : Reality Checker sur la sortie des scénarios et un `git status` / `git diff --cached` identiques avant/après.

### L3 — CLI et planification de la sauvegarde
**Pilote** : Developer Tooling Engineer · **Relecteurs** : Git Workflow Master, Code Reviewer

Exigences : SA-07, SA-09 à SA-12, TR-03, TR-04, RG-09, RG-10, ENF-02, ENF-08.

- [ ] Commandes : `git autosave add | remove | list | run | restore | interval | keep | share | status | log | help` (noms à valider), appelables avec ou sans préfixe `git` (`git-autosave.cmd` sur le PATH utilisateur = sous-commande git).
- [ ] Aide affichée sans argument ou sur commande inconnue, avec l'état courant (TR-04, R-16).
- [ ] Recherche de la racine du projet depuis n'importe quel sous-dossier (SA-09).
- [ ] Tâche planifiée + lanceur sans fenêtre (choix S1), intervalle 5–240 min (SA-11).
- [ ] Hook `post-commit` (ADR-06) ; partage sur le distant `refs/autosave/*` et retrait au nettoyage (SA-07), sans jamais attendre une saisie d'identifiants (ENF-08).
- [ ] Codes de sortie distincts, messages d'erreur qui donnent l'action à faire.

### L4 — Installation, réinstallation, désinstallation
**Pilote** : Developer Tooling Engineer · **Relecteurs** : Code Reviewer, Reality Checker

Exigences : TR-01, TR-02, TR-06, TR-07, TR-08, ENF-05, ENF-06, ENF-12, ENF-15.

- [ ] `install.ps1` : les deux outils ou un seul (`-Only autosave|viewer`), < 2 min, idempotent (0 doublon PATH / tâche / hook).
- [ ] `uninstall.ps1` par outil : retire PATH, tâche, hooks posés par le produit, arrête le visualiseur ; **conserve** `projects.json` et les refs `autosave` (TR-08).
- [ ] Détection du blocage (fichier téléchargé, stratégie) → message + renvoi au guide (ENF-06).
- [ ] Vérification Windows 10 21H2 / Windows 11 ; mode de repli documenté pour les versions plus anciennes (ENF-12).

**Porte** : Reality Checker sur R-17 et R-19 joués sur un compte standard.

### L5 — Serveur du visualiseur (peut démarrer en parallèle de L2 après L1)
**Pilote** : Software Architect (contrat d'API) → Developer Tooling Engineer (implémentation) · **Revue** : Code Reviewer (sécurité en priorité)

Exigences : VI-30, VI-31, VI-33, VI-34, VI-35, RG-26 à RG-29, ENF-04, ENF-07, ENF-09.

- [ ] Contrat d'API JSON documenté (`docs/api.md`) : `state`, `graph`, `commit/:sha`, `diff`, `projects`, `open`, `actions/*`, `settings`, `shutdown`.
- [ ] Sécurité ADR-08 ; validation des noms de branche (`git check-ref-format`) et des SHA avant toute commande (RG-29) ; arguments passés en liste, jamais concaténés en chaîne shell.
- [ ] Instance unique et bascule de projet (ADR-09) ; reprise du dernier projet (VI-33) ; 15 récents + projets suivis (VI-32).
- [ ] Inscription automatique à la sauvegarde à l'ouverture, désactivable (VI-34, RG-26) — **appel au module autosave, sans dépendance obligatoire** (TR-02 : le visualiseur fonctionne sans lui).
- [ ] Relance propre après arrêt brutal : verrou périmé détecté via le PID (ENF-09).

### L6 — Interface : consultation
**Pilote** : UX Architect (structure, CSS) → UI Designer (visuel) → Frontend Developer (code) · **Porte** : UI Finish-Gate Reviewer

Exigences : VI-01 à VI-08, VI-32, ENF-11, ENF-13.

- [ ] UX Architect : contrat de design (zones : en-tête d'état, graphe, panneau de détail, liste des fichiers / diff), variables CSS, thèmes clair/sombre, mise en page à 375 px.
- [ ] UI Designer : codage visuel des points de reprise (forme ou trait distinct, pas seulement la couleur — VI-02), entrée « travail en cours » (VI-03), compte à rebours et états « non suivi » / « inactif » (VI-07).
- [ ] Frontend Developer : rendu du graphe (SVG ou canvas) < 2 s pour 400 commits, détail de commit, diff, rafraîchissement ADR-10, interface 100 % en français.
- [ ] Revue accessibilité (contrastes, clavier).

### L7 — Interface : actions sur le dépôt
**Pilote** : Frontend Developer + Developer Tooling Engineer (côté serveur) · **Conseil** : Git Workflow Master (commande git exacte pour chaque action) · **Porte** : UI Finish-Gate Reviewer

Exigences : VI-10 à VI-17, VI-20 à VI-22, VI-35, RG-20 à RG-25.

| Action | Commande proposée (à valider par Git Workflow Master) |
| --- | --- |
| Indexer / désindexer | `git add -- <f>` / `git restore --staged -- <f>` |
| Annuler un fichier | `git restore --worktree --source=HEAD -- <f>` ; nouveau fichier : suppression |
| Committer / modifier le dernier | `git commit [-a] [--amend] -m` |
| Annuler le dernier commit | `git reset --soft HEAD~1` (modifs indexées, R-13) |
| Stash | `git stash push -u` / `git stash pop` |
| Branches | `switch`, `switch -c`, `merge --no-ff`, `branch -d` puis `-D` après 2ᵉ confirmation (RG-21) |
| Restaurer un commit | `git restore --source=<sha> --worktree -- .` + point de reprise préalable |
| Se placer sur un commit | `git switch --detach <sha>` |
| Distant | `fetch`, `pull --ff-only` (RG-22), `push` avec cause d'échec affichée |

- [ ] Boîte de confirmation unique réutilisée pour toutes les actions RG-20, double confirmation pour RG-21.
- [ ] Réinitialisation complète à chaque changement de projet, tous onglets synchronisés (RG-25).

### L8 — Recette, durcissement
**Pilote** : Test Automation Engineer · **Porte finale** : Reality Checker

- [ ] Scénarios automatisés : R-01 à R-06, R-08, R-12, R-13, R-15, R-16, R-17 (PowerShell + Pester sur dépôts temporaires).
- [ ] E2E Playwright du visualiseur (poste de dev) : R-09 à R-14, R-20 (V2), sélecteurs par rôle et libellé, aucune attente fixe, captures pour le Reality Checker.
- [ ] Recette manuelle sur poste Orano réel : R-07 (1 h, aucune fenêtre), R-18 (fichiers bloqués), R-19 (compte standard) et ENF-02 sur une journée de 8 h.
- [ ] Écrire les scénarios manquants (point ouvert) : SA-07, SA-09, VI-20 à VI-22, ENF-07 (requête depuis une autre page web refusée), ENF-09 (projet en erreur, arrêt brutal), ENF-14 (chemins accentués).
- [ ] Code Reviewer : revue globale finale.

**Porte V1** : Reality Checker — 100 % des R-xx V1 passés avec preuve, 0 🔴 ouvert.

### L9 — Documentation
**Pilote** : Developer Tooling Engineer · **Relecteur** : Reality Checker (le guide suffit-il à un utilisateur seul ?)

- [ ] `docs/GUIDE.md` : installation, usage, réglages, restauration, désinstallation, dépannage, blocage par les règles du poste (TR-09, R-18).
- [ ] Note DSI : ce que fait le produit, où il écrit, ce qu'il ne fait pas (aucune élévation, aucun réseau sortant).

### V2 (après la V1)
TR-05, TR-10, TR-11 (paramétrage centralisé, réglages depuis le visualiseur, application à chaud, R-20) puis les évolutions §11 de l'AF : comparer deux points de reprise, restaurer un seul fichier, pause par projet, journal dans le visualiseur.

---

## 4. Boucle de travail par tâche

1. **Conception** — l'agent pilote rédige l'approche (ADR ou note courte) en citant les exigences couvertes.
2. **Test d'abord** quand c'est possible — Test Automation Engineer écrit le scénario R-xx ou le test Pester.
3. **Implémentation** — branche `feat/…`, commits atomiques.
4. **Revue** — Code Reviewer (🔴 bloquant avant fusion) + relecteur spécialiste du lot.
5. **Porte** — Reality Checker (L2, L4, L8) ou UI Finish-Gate Reviewer (L6, L7) : preuve observée, pas déclarée.
6. **Fusion** sur `main`, mise à jour de la matrice de couverture.

---

## 5. Points ouverts à trancher en L0

| Point (AF §11) | Recommandation | Bloquant pour |
| --- | --- | --- |
| Dates des jalons V1 / V2 | À fixer par Guillaume | Grille SMART |
| Seuils (5–240 min, 2/5/10 s, 1 Mo, 375 px) | Garder tels quels, revoir après la recette réelle | L3, L5, L8 |
| Limite des séries conservées | V1 sans limite, avertissement au-delà de N séries ; limite configurable en V2 | L2 |
| Intervalle par projet ou commun | Commun en V1 (une seule tâche planifiée = plus simple, RG-10) | L3 |
| Exclure durablement un projet de l'inscription auto | Oui, liste d'exclusion dans `config.json` — petit coût, évite de contredire RG-26 | L5 |
| Deux projets côte à côte | Non en V1 (contredit VI-31) | — |
| Poste n'acceptant que des programmes signés | Signature des `.ps1` par un certificat fourni par la DSI ; procédure dans la note DSI | L4, L9 |
| Guide unique ou scindé | Unique en V1, sections bien séparées | L9 |
| Refs cachées vs branches pour les points de reprise | Refs cachées (ADR-01) | L2 |
