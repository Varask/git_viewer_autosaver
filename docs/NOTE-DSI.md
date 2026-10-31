# git-tools — Note à l'attention du service informatique

Outil interne d'aide au développement : sauvegarde périodique du travail git non committé et visualiseur local de l'historique. Cette note décrit précisément son empreinte sur le poste, pour décider d'une autorisation.

## Ce qui est installé

| Élément | Emplacement | Droits |
| --- | --- | --- |
| Scripts PowerShell (`.ps1`, `.psm1`), page HTML/CSS/JS | `%LOCALAPPDATA%\Programs\git-tools` | utilisateur |
| Données : réglages, liste de projets, journaux (≤ 1 Mo chacun) | `%LOCALAPPDATA%\git-tools` | utilisateur |
| Entrée du PATH **utilisateur** | `HKCU\Environment\Path` | utilisateur |
| Deux alias git globaux (`autosave`, `viewer`) | `%USERPROFILE%\.gitconfig` | utilisateur |
| Tâche planifiée `git-tools-autosave`, compte de l'utilisateur, niveau *Limited*, ouverture de session interactive | Planificateur de tâches, racine | utilisateur |
| Hook `post-commit` (uniquement s'il n'en existe pas déjà) | dossier `.git/hooks` des projets suivis | utilisateur |

Aucune élévation de droits, aucun service, aucune clé `HKLM`, aucun pilote, aucun binaire compilé, aucune modification de la stratégie d'exécution.

## Ce qui s'exécute

- `powershell.exe` (Windows PowerShell 5.1 du système) et `git.exe` (Git for Windows).
- Lanceur sans fenêtre de la tâche planifiée : `conhost.exe --headless`, ou à défaut `wscript.exe` avec un script `.vbs` de 6 lignes fourni.
- Le visualiseur : un processus `powershell.exe` caché qui écoute en TCP sur **127.0.0.1 uniquement**, port choisi par le système. Il refuse toute requête dont l'en-tête `Host` n'est pas local, toute requête d'API sans jeton aléatoire (32 octets, renouvelé à chaque démarrage) et toute requête provenant d'une autre origine web.
- Le sélecteur de dossier du visualiseur : un `powershell.exe -STA` éphémère qui affiche la boîte de dialogue Windows standard.

Aucune connexion sortante, sauf les commandes git `fetch` / `pull` / `push` déclenchées explicitement par l'utilisateur vers les dépôts distants qu'il a déjà configurés (et `push` des points de reprise si l'utilisateur active ce réglage).

## Ce qu'il faut éventuellement autoriser

1. **Stratégie `RemoteSigned`** (cas le plus courant) : rien, une fois les fichiers débloqués par l'utilisateur (`Unblock-File`).
2. **Stratégie `AllSigned`** : signer les fichiers `.ps1` et `.psm1` avec un certificat de signature de code interne (`Set-AuthenticodeSignature`). Liste : `install.ps1`, `uninstall.ps1`, `common\GitTools.Common.psm1`, `autosave\GitAutosave.psm1`, `autosave\git-autosave.ps1`, `viewer\GitViewer.psm1`, `viewer\git-viewer.ps1`, `viewer\server.ps1`, `viewer\pick-folder.ps1`.
3. **AppLocker / WDAC** en mode script : autoriser ces fichiers par éditeur (après signature) ou par chemin `%LOCALAPPDATA%\Programs\git-tools\*`. Le mode de langage restreint de PowerShell n'est pas pris en charge.
4. **Création de tâches planifiées bloquée** : facultatif ; sans tâche, la sauvegarde reste lançable à la main.
5. **Pare-feu** : aucune règle nécessaire (écoute en boucle locale uniquement).

## Retrait

`uninstall.ps1` retire tout ce qui est listé ci-dessus, à l'exception des données utilisateur (`%LOCALAPPDATA%\git-tools`) et des refs `refs/autosave/*` dans les projets, conservées volontairement.
