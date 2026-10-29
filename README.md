# git-tools

Deux outils Windows pour les projets git, utilisables séparément :

- **`git autosave`** — enregistre toutes les 30 minutes un point de reprise du travail non committé de chaque projet suivi, à côté de l'historique officiel, et le nettoie dès que vous committez.
- **`git viewer`** — page locale qui affiche le graphe du projet en continu et permet les actions courantes (indexer, committer, branches, récupérer / tirer / pousser, restaurer).

Windows 10 21H2+ / 11, Git for Windows, aucun droit administrateur, aucune connexion internet.

```powershell
.\install.cmd          # vérifie la stratégie d'exécution puis installe ; ensuite, dans un nouveau terminal :
git autosave add
git viewer
```

| Document | Contenu |
| --- | --- |
| [docs/GUIDE.md](docs/GUIDE.md) | Installation, usage, réglages, restauration, désinstallation, dépannage, poste verrouillé |
| [docs/NOTE-DSI.md](docs/NOTE-DSI.md) | Empreinte exacte sur le poste, pour le service informatique |
| [docs/RECETTE.md](docs/RECETTE.md) | Tests automatisés et scénarios à jouer à la main |
| [docs/adr.md](docs/adr.md) | Décisions d'architecture |
| [git-tools — Analyse fonctionnelle.md](git-tools%20—%20Analyse%20fonctionnelle.md) | Exigences |
| [PLAN-DEVELOPPEMENT.md](PLAN-DEVELOPPEMENT.md) | Plan et avancement |

## Structure

```
install.ps1 / uninstall.ps1
common/GitTools.Common.psm1     appel de git, réglages, journal, PATH, client local
autosave/                        moteur, commande git-autosave, lanceur sans fenêtre
viewer/                          serveur 127.0.0.1, commande git-viewer, page (www/)
tests/Run-Tests.ps1              recette Windows (moteur, logique, intégration)
tests/e2e/                       tests de l'interface (Node + Playwright)
```

Les fichiers `.ps1` et `.psm1` doivent rester en **UTF-8 avec BOM** (sinon Windows PowerShell 5.1 lit mal les accents) : `node tests/check-encoding.js` le vérifie.
