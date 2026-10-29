# git-tools — instructions pour Claude

Outil Windows en deux parties indépendantes : **sauvegarde automatique** (points de reprise du travail en cours entre deux commits) et **visualiseur** (page locale avec graphe et actions git).

- Exigences : `git-tools — Analyse fonctionnelle.md` (références SA, VI, TR, RG, ENF, R-xx). Toujours citer les références couvertes.
- Plan : `PLAN-DEVELOPPEMENT.md` (lots L0 à L9, ADR, points ouverts). Mettre à jour les cases à cocher quand une tâche est finie.

## Contraintes non négociables

- Windows 10 21H2+ / 11, **PowerShell 5.1**, git seul prérequis, sans internet, **sans droits administrateur**.
- Stratégie d'exécution `RemoteSigned` imposée par GPO : **jamais** `-ExecutionPolicy Bypass` ni autre contournement (FC3).
- Le produit ne modifie **jamais** la branche, l'index, les fichiers ni l'historique officiel de l'utilisateur sans action explicite (FC1, ENF-01). Dans le doute, ne rien faire.
- Commandes git du produit : `-c gc.auto=0`, `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `GIT_OPTIONAL_LOCKS=0` ; arguments passés en liste, jamais concaténés.
- Écriture limitée aux projets et à `%LOCALAPPDATA%\git-tools\`.
- Visualiseur : écoute sur `127.0.0.1` uniquement, contrôle `Host`/`Origin`, jeton exigé sur toute action.
- Chemins avec espaces et accents supportés partout ; sorties en UTF-8.
- Interface et messages 100 % en français.

## Agents (`.claude/agents/`) — quand les solliciter

| Situation | Agent |
| --- | --- |
| Décision d'architecture, ADR, contrat d'API | `software-architect` |
| Toute commande git du produit, modèle des refs `autosave`, nettoyage, conventions du dépôt | `git-workflow-master` |
| CLI, aide, messages d'erreur, installation/désinstallation, scripts PowerShell | `developer-tooling-engineer` |
| Structure de l'interface, système CSS, thèmes, 375 px | `ux-architect` |
| Langage visuel, graphe, états, confirmations | `ui-designer` |
| Code de la page (vanilla JS) | `frontend-developer` |
| Tests Pester, scénarios R-xx, E2E Playwright | `test-automation-engineer` |
| Revue avant chaque fusion | `code-reviewer` |
| Porte de sortie interface (fin L6, L7) | `ui-finish-gate-reviewer` |
| Porte de sortie jalon (fin L2, L4, L8) | `reality-checker` |

Boucle par tâche : conception (pilote) → test d'abord (`test-automation-engineer`) → implémentation → revue (`code-reviewer` + spécialiste) → porte de sortie si fin de lot → fusion.

## Conventions du dépôt

- Trunk-based : une branche par lot (`feat/l2-moteur-autosave`), Conventional Commits en français (`feat:`, `fix:`, `test:`, `docs:`…), commits atomiques.
- Aucun 🔴 du `code-reviewer` ouvert au moment de la fusion.
- Une porte n'est franchie qu'avec une preuve observée (sortie de test, journal, capture), jamais déclarée.
