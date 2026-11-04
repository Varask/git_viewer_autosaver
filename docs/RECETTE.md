# Recette git-tools V1

## Ce qui est automatisé

| Suite | Commande | Couvre |
| --- | --- | --- |
| Moteur + logique du visualiseur (Windows) | `.\tests\Run-Tests.ps1` | R-01 à R-06, R-08, R-12, R-13, R-15, R-16, RG-04 à RG-11, RG-21 à RG-29, VI-01 à VI-06, VI-10 à VI-15, VI-20 à VI-22, ENF-07, ENF-09, ENF-10, ENF-14 |
| Processus réels (Windows) | `.\tests\Run-Tests.ps1 -Integration` | + SA-05 (hook < 10 s), R-09/VI-30, R-10/VI-31 (lancements simultanés), ENF-07 sur le serveur réel, VI-35, ENF-09 (arrêt brutal) |
| Interface (navigateur, tout OS avec Node + Playwright) | `node --test tests/e2e/viewer.e2e.test.js` | R-11, R-12, R-13, R-15, RG-21, RG-23 à RG-25, RG-28, VI-02 à VI-08, ENF-11 (375 px, thème sombre) |

Le rapport de la dernière exécution Windows est écrit dans `tests\derniere-recette.txt`.

## À faire à la main sur le poste réel

Ces scénarios touchent l'installation réelle (PATH, tâche planifiée, alias) ou demandent d'observer l'écran.

| N° | Étapes | Attendu | Résultat |
| --- | --- | --- | --- |
| R-07 / ENF-02 | Installer, `git autosave add` dans un projet, `git autosave interval 5`, travailler 15 min en modifiant un fichier | 3 passages dans `git autosave log`, **aucune fenêtre** apparue, aucune perte de focus | ☐ |
| R-14 / VI-07 / VI-34 | `git autosave remove` dans un projet, puis l'ouvrir via la liste ou le champ chemin du visualiseur | Projet suivi, compte à rebours affiché, écart < 5 s avec l'heure du passage dans le journal | ☐ |
| R-17 / TR-07 / TR-08 | `uninstall.ps1` | `git autosave` et `git viewer` inconnus dans un nouveau terminal ; tâche absente ; visualiseur arrêté ; `%LOCALAPPDATA%\git-tools\projects.json` et `refs/autosave/*` intacts | ☐ |
| R-18 / ENF-06 | Télécharger le zip depuis la Release GitHub (navigateur), *Extraire tout*, double-clic sur `install.cmd` ; répondre `N`, relancer, répondre `O` ; puis sur un compte en *Restricted* | `N` : rien n'est modifié. `O` : fichiers débloqués puis installation réussie. *Restricted* : refus clair avec `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` | ☐ |
| R-20 / TR-10 / TR-11 | Visualiseur → ⚙ Réglages : intervalle 30 → 15, puis saisir 3 ; *Rétablir les valeurs par défaut* | Compte à rebours sur 15 min sans autre manipulation, `Get-ScheduledTask git-tools-autosave` répété toutes les 15 min ; 3 refusé avec « de 5 à 240 » ; tout revient à 30 min (automatisé aussi : `Run-Tests.ps1` et E2E) | ☐ |
| R-19 / ENF-15 | Compte standard : installer, ajouter un projet, attendre un passage, ouvrir le visualiseur, désinstaller | Aucune demande d'élévation à aucune étape | ☐ |
| TR-01 | Chronométrer `install.ps1` | < 2 min ; commandes reconnues dans un nouveau terminal | ☐ |
| TR-06 | Relancer `install.ps1` deux fois | Une seule entrée PATH par outil (`$env:Path -split ';'`), une seule tâche, liste des projets identique | ☐ |
| VI-32 | Bouton *Parcourir…* | Sélecteur de dossier Windows au premier plan ; projet ouvert | ☐ |
| L10 | Clic droit sur le dossier d'un projet, sur un sous-dossier, dans le fond d'un dossier ouvert, puis sur un dossier qui n'est pas un projet ; raccourci du menu Démarrer | Page ouverte sur le projet en 10 s, **aucune fenêtre de console** ; dossier hors projet : boîte « … n'est pas un projet git » ; menu Démarrer : dernier projet. Windows 11 : entrée sous « Afficher plus d'options ». Après `uninstall.ps1` : entrée et raccourci disparus | ☐ |
| ENF-12 | Windows 10 21H2 **et** Windows 11 | Recette automatisée verte sur les deux | ☐ |

## Spikes encore ouverts (lot L1)

| Spike | Statut | Ce qui le ferme |
| --- | --- | --- |
| S1 lanceur sans fenêtre | `conhost --headless` par défaut, repli `wscript` codé | R-07 réussi sur le poste Orano |
| S2 détachement du visualiseur | `Start-Process -WindowStyle Hidden` | R-09 : fermer le terminal, la page reste vivante |
| S3 écoute sans admin | `TcpListener` 127.0.0.1 | `-Integration` vert |
| S4 fichiers téléchargés | Détection codée | R-18 |
| S5 encodage et chemins | Tests en chemins accentués | Recette automatisée verte |
| S6 tâche et PATH sans élévation | Codé | R-19 |
