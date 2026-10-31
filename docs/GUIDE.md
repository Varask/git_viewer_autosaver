# git-tools — Guide

git-tools garde des **points de reprise** de votre travail en cours entre deux commits, et affiche votre projet dans un **visualiseur** local (graphe, différences, actions courantes). Les deux outils sont indépendants.

- Prérequis : Windows 10 (21H2 ou plus récent) ou Windows 11, **Git for Windows**. Rien d'autre : ni droits administrateur, ni internet.
- Rien n'est modifié dans vos projets sans action de votre part : ni branche, ni index, ni fichiers, ni historique.

---

## 1. Installation

1. Copiez le dossier `git-tools` où vous voulez (par exemple dans vos Documents).
2. Double-cliquez sur **`install.cmd`** (ou lancez `.\install.cmd` dans un terminal ouvert dans ce dossier).

   Pour un seul outil : `.\install.cmd -Only autosave` ou `.\install.cmd -Only viewer`.

   `install.cmd` vérifie d'abord que PowerShell accepte les scripts. Sur un PC personnel, Windows les refuse par défaut (stratégie *Restricted*, message « running scripts is disabled on this system ») : `install.cmd` affiche alors la commande à lancer une fois, **pour votre compte seulement, sans droits administrateur** :

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

   *RemoteSigned* autorise les scripts présents sur le disque et refuse ceux téléchargés d'internet non débloqués. C'est la stratégie qu'imposent la plupart des postes d'entreprise. git-tools ne la contourne jamais lui-même. Si la commande est refusée, votre poste est géré par une DSI : voir [§ 7](#7-poste-verrouillé-par-la-dsi).
3. Si vous préférez PowerShell directement : `.\install.ps1` (mêmes options).

4. **Ouvrez un nouveau terminal** : les commandes `git autosave` et `git viewer` y sont reconnues, depuis n'importe quel dossier.

L'installation copie le programme dans `%LOCALAPPDATA%\Programs\git-tools`, ajoute ce dossier à *votre* PATH, crée deux alias git (`autosave`, `viewer`) et une tâche planifiée à votre nom (`git-tools-autosave`). Vos réglages, la liste des projets et les journaux sont dans `%LOCALAPPDATA%\git-tools`.

Réinstaller (par exemple après une mise à jour) se fait de la même façon : rien n'est dupliqué et la liste des projets est conservée.

Si l'installation affiche que des fichiers sont « marqués comme téléchargés », voir [§ 7](#7-poste-verrouillé-par-la-dsi).

---

## 2. Usage

### Sauvegarde automatique

Dans un projet :

```powershell
git autosave add          # suivre ce projet
```

C'est tout. Toutes les 30 minutes (réglable), chaque projet suivi qui a changé reçoit un point de reprise : *Autosave 01*, *Autosave 02*… rattachés à votre dernier commit. Quand vous committez, ces points disparaissent automatiquement (en quelques secondes).

| Commande | Effet |
| --- | --- |
| `git autosave add [chemin]` | Suivre le projet |
| `git autosave remove [chemin]` | Ne plus le suivre (les points existants sont conservés). `--no-autotrack` : ne plus le réinscrire depuis le visualiseur |
| `git autosave list` | Projets suivis |
| `git autosave run` | Forcer un passage maintenant |
| `git autosave status` | Points de reprise de la branche courante |
| `git autosave restore [n]` | Restaurer un point (voir § 4) |
| `git autosave log [n]` | Dernières lignes du journal |
| `git autosave` | Aide et état |

Les commandes marchent aussi sans le préfixe : `git-autosave run`.

**Ce qui n'est pas sauvegardé** : les fichiers ignorés par le projet (`.gitignore`), les projets sans aucun commit, et un projet pendant une fusion, un rebase, un cherry-pick ou un revert (il est repris au passage suivant). Hors branche (HEAD détaché), aucun point n'est créé.

Les points de reprise sont des refs git cachées (`refs/autosave/<branche>/<commit>`) : ils n'apparaissent pas dans `git branch` et ne partent pas avec un `git push` ordinaire.

### Visualiseur

```powershell
git viewer                # dans un projet, ou n'importe où pour rouvrir le dernier projet
git viewer C:\autre\projet
git viewer stop
```

La commande rend la main tout de suite ; la page s'ouvre dans votre navigateur. Vous pouvez fermer le terminal. Une seule instance tourne : relancer depuis un autre projet fait basculer la page déjà ouverte, sans nouvel onglet.

Dans la page :

- **En haut** : projet (cliquez pour en changer), branche (cliquez pour gérer les branches), avance/retard sur le distant, nombre de modifications, compte à rebours de la prochaine sauvegarde, boutons Récupérer / Tirer / Pousser, menu ⋯ (sauvegarder maintenant, suivre ou ne plus suivre, mettre de côté, arrêter le visualiseur).
- **Historique** : toutes les branches et tags. Les points de reprise sont des **losanges orange en pointillés** ; la case *Points de reprise* les masque. La ligne *Travail en cours* apparaît dès qu'un fichier change.
- **Panneau de droite** : le travail en cours (indexer, désindexer, annuler un fichier, committer) ou le détail d'un commit (fichiers, différences, restaurer, se placer dessus, annuler le dernier commit).

Toute action qui peut perdre des données demande une confirmation ; supprimer une branche non fusionnée en demande deux. Le tirage refuse de créer une fusion si votre branche et le distant ont divergé.

Le visualiseur n'est joignable que depuis votre poste (adresse `127.0.0.1`) et refuse toute action venant d'une autre page web.

---

## 3. Réglages

| Réglage | Commande | Défaut | Effet |
| --- | --- | --- | --- |
| Intervalle | `git autosave interval 15` | 30 min | Durée entre deux passages, de 5 à 240 min |
| Conservation | `git autosave keep on` | off | Garder les séries après un commit manuel |
| Partage | `git autosave share on` | off | Envoyer aussi les points de reprise sur le distant (et les y retirer au nettoyage) |
| Inscription auto. | `git autosave autotrack off` | on | Tout projet ouvert dans le visualiseur est suivi |
| Lanceur | `git autosave launcher wscript` | conhost | Programme qui lance la sauvegarde sans fenêtre (voir § 6) |
| Commits affichés | liste *Afficher* dans le visualiseur | 400 | Taille de l'historique chargé |

Un réglage prend effet immédiatement. Ils sont tous stockés dans `%LOCALAPPDATA%\git-tools\config.json`.

---

## 4. Restaurer

**Depuis le terminal**, dans le projet :

```powershell
git autosave status        # liste les points : 01, 02…
git autosave restore       # le plus récent
git autosave restore 2     # le n° 2
git autosave restore 1a2b3c4d
```

**Depuis le visualiseur** : cliquez sur un point de reprise (ou n'importe quel commit) → *Restaurer*.

Dans les deux cas : vos fichiers reprennent l'état du point choisi, la branche ne change pas, l'index non plus. **Avant de restaurer, votre état actuel est lui-même sauvegardé** dans un nouveau point : une restauration se défait donc en restaurant ce point.

---

## 5. Désinstallation

```powershell
& "$env:LOCALAPPDATA\Programs\git-tools\uninstall.ps1"
```

(ou `-Only autosave` / `-Only viewer`). Sont retirés : commandes, alias, entrées du PATH, tâche planifiée, hooks posés par git-tools ; le visualiseur est arrêté. **Sont conservés** : la liste des projets, les journaux et les points de reprise. Pour tout effacer ensuite, supprimez `%LOCALAPPDATA%\git-tools` et, dans chaque projet :

```powershell
git for-each-ref --format="delete %(refname)" refs/autosave/ | git update-ref --stdin
```

---

## 6. Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| « running scripts is disabled on this system » | Stratégie *Restricted* (défaut Windows) | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, voir § 1 |
| `git autosave` inconnu | Terminal ouvert avant l'installation | Ouvrir un nouveau terminal |
| « Sauvegarde : inactive » dans le visualiseur | Tâche planifiée absente ou désactivée | Relancer `install.ps1` ; vérifier `git-tools-autosave` dans le Planificateur de tâches |
| Une fenêtre noire apparaît à chaque passage | `conhost --headless` non supporté par ce Windows | `git autosave launcher wscript` |
| Aucun point de reprise créé | Projet non suivi, rien n'a changé, ou opération git en cours | `git autosave list`, puis `git autosave log` |
| La série ne disparaît pas après un commit | Le projet a son propre hook post-commit | Normal : nettoyage au passage suivant |
| Le visualiseur ne s'ouvre pas | Instance bloquée | `git viewer stop`, puis `git viewer` ; voir `%LOCALAPPDATA%\git-tools\logs\viewer.log` |
| « identifiants manquants » à l'envoi | Le distant demande un mot de passe | Faire une fois `git push` dans un terminal pour enregistrer les identifiants |
| Accents mal affichés dans le terminal | Police ou page de code de la console | Utiliser Windows Terminal ; le journal et la page sont en UTF-8 |

Journaux : `%LOCALAPPDATA%\git-tools\logs\autosave.log` et `viewer.log` (1 Mo maximum chacun), consultables aussi par `git autosave log`.

**Mode de repli (Windows antérieur à 10 21H2)** : l'installation avertit mais continue. Si la tâche planifiée ne peut pas être créée, `git autosave run` reste utilisable à la main ; si une fenêtre apparaît à chaque passage, passer au lanceur `wscript`.

---

## 7. Poste verrouillé par la DSI

git-tools respecte les règles du poste et ne les contourne jamais (aucune option `-ExecutionPolicy`).

**Fichiers marqués comme téléchargés.** Si vous avez récupéré git-tools depuis internet ou une messagerie, Windows marque les fichiers et la stratégie `RemoteSigned` les refuse. L'installation le détecte et s'arrête avec ce message. Si vous faites confiance à ces fichiers :

```powershell
Get-ChildItem -LiteralPath "C:\chemin\vers\git-tools" -Recurse | Unblock-File
.\install.ps1
```

**Scripts non signés interdits (`AllSigned`) ou PowerShell restreint.** Débloquer ne suffit pas : transmettez [NOTE-DSI.md](NOTE-DSI.md) à votre service informatique. Elle décrit exactement ce que fait le produit et ce qu'il faut autoriser (signature des scripts par un certificat interne, ou exception sur le dossier d'installation).

**Tâches planifiées interdites.** La sauvegarde reste utilisable à la main (`git autosave run`) et le visualiseur fonctionne normalement.
