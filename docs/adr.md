# Décisions d'architecture (ADR)

Statut : **acceptées pour la V1**, à revoir après la recette sur poste réel (L8).
Chaque décision cite les exigences de l'analyse fonctionnelle qu'elle sert.

## ADR-00 — Socle technique

- **Contexte** : Windows 10 21H2+ / 11, git seul prérequis, sans internet, sans droits admin, stratégie `RemoteSigned` imposée par GPO, programmes non signés potentiellement bloqués (FC3, FC7, ENF-05, ENF-15).
- **Décision** : Windows PowerShell 5.1 (présent sur tous les postes) pour la sauvegarde et le serveur du visualiseur ; page HTML/CSS/JS sans framework ni ressource externe pour l'interface. Compatible PowerShell 7 sans être requis.
- **Rejeté** : exécutable compilé (C#, Rust, Go) — risque AppLocker / signature ; Node ou Python — prérequis supplémentaire.
- **Conséquences** : pas d'`Add-Type` (compilation C# à la volée, refusée en mode de langage restreint) ; fichiers `.ps1`/`.psm1` enregistrés en UTF-8 **avec BOM** (sinon PowerShell 5.1 lit les accents en ANSI) ; aucune option `-ExecutionPolicy`.

## ADR-01 — Stockage des points de reprise : refs cachées

- **Décision** : une série = une ref `refs/autosave/<branche>/<sha-base>`. Chaque point de reprise est un commit dont le parent est le point précédent, ou la base pour le premier. Message : `Autosave NN — jj/mm/aaaa hh:mm`. Committer : `git-tools autosave`.
- **Pourquoi** : invisibles dans `git branch`, jamais poussées par `git push` ordinaire, faciles à lister et supprimer. La branche et la base sont lisibles dans le nom (RG-01).
- **Compromis** : visibles dans `git log --all` et dans les outils qui montrent toutes les refs — c'est voulu pour le visualiseur (VI-02).

## ADR-02 — Capture sans toucher l'index

- **Décision** : copie de l'index réel dans un fichier temporaire (`GIT_INDEX_FILE`), puis `git add -A` → `git write-tree` → `git commit-tree` → `git update-ref <ref> <nouveau> <ancien>`. Si la copie échoue : `git read-tree HEAD` sur l'index temporaire.
- **Pourquoi** : l'index, la branche et les fichiers réels ne sont jamais écrits (FC1, SA-04, ENF-01). `add -A` applique `.gitignore` (RG-07). La copie de l'index réutilise ses informations de cache : le passage reste rapide sur un gros projet. git remplace l'index par renommage atomique, la copie est donc toujours cohérente.
- **Compromis** : des objets sont écrits dans `.git/objects` ; ils disparaissent au ramasse-miettes après nettoyage de la série.

## ADR-03 — « Rien n'a changé »

- **Décision** : comparer l'arbre obtenu à celui du dernier point de la série, ou à celui de la base. Égal → aucun commit (SA-02).

## ADR-04 — Ne pas gêner l'utilisateur

- **Décision** : toute commande git du produit passe par une seule fonction (`Invoke-Git`) qui impose `-c core.quotepath=false -c gc.auto=0 -c credential.interactive=false`, les variables `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `GIT_OPTIONAL_LOCKS=0`, `GIT_ASKPASS=` vide, aucune fenêtre (`CreateNoWindow`), sortie lue en UTF-8 et arguments cités selon les règles Windows (ENF-03, ENF-08, ENF-14). Les messages de commit passent par un fichier temporaire (`-F`), jamais par la ligne de commande.

## ADR-05 — Planification

- **Décision** : une tâche planifiée de l'utilisateur courant (`git-tools autosave`), sans élévation, répétée toutes les N minutes, `MultipleInstances = IgnoreNew`, plus un mutex nommé `Local\git-tools-autosave` (RG-10).
- **Lanceur sans fenêtre** : `conhost.exe --headless powershell.exe …` par défaut ; repli `wscript.exe` + `run-hidden.vbs` (réglage `launcher`). À confirmer par le spike S1 sur le poste Orano (ENF-02, R-07).
- **Compte à rebours** : l'heure de départ de la tâche est enregistrée dans `config.json` ; prochain passage = départ + k × intervalle. Calcul local, sans interroger le planificateur à chaque rafraîchissement (VI-07).

## ADR-06 — Nettoyage

- **Décision** : hook `post-commit` installé dans le dossier renvoyé par `git rev-parse --git-path hooks` (respecte `core.hooksPath`), **uniquement s'il n'existe pas** ; il porte le marqueur `git-tools-autosave-hook` et lance le nettoyage en arrière-plan. Sinon nettoyage au passage suivant (RG-09).
- Série obsolète = la branche n'existe plus ou son sommet n'est plus la base (RG-02). Suppression par `update-ref -d <ref> <ancien>` ; sur le distant si le partage est actif (SA-07).

## ADR-07 — Restauration

- **Décision** : avant toute restauration, un passage de sauvegarde est forcé sur le projet (filet de sécurité). Puis `git restore --source=<commit> --worktree -- :/`. Branche et index inchangés (SA-08, VI-16, R-06).

## ADR-08 — Serveur du visualiseur

- **Décision** : `System.Net.Sockets.TcpListener` sur `127.0.0.1`, port libre choisi par le système (pas de réservation d'URL, pas d'élévation — ENF-15). Chaque requête est traitée dans un pool de runspaces (4) pour qu'un `push` lent ne bloque pas le rafraîchissement.
- **Sécurité (FC5, ENF-07)** : en-tête `Host` obligatoirement `127.0.0.1:<port>` ou `localhost:<port>` (anti-DNS-rebinding) ; toute route `/api/` exige l'en-tête `X-GitTools-Token` (jeton aléatoire de 32 octets injecté dans la page) ; `Sec-Fetch-Site: cross-site` refusé ; aucun en-tête CORS ; `Origin` étranger refusé.
- **Validation (RG-29)** : noms de branche via `git check-ref-format --branch`, identifiants via `^[0-9a-f]{7,40}$`, chemins de fichier relatifs sans `..` et vérifiés dans le projet.

## ADR-09 — Instance unique

- **Décision** : mutex `Local\git-tools-viewer` + fichier `viewer.lock` (port, PID, jeton). Le lanceur interroge l'instance existante (`/api/ping`), lui envoie `/api/open`, et c'est **le serveur** qui décide d'ouvrir un onglet : seulement si aucune page ne l'a interrogé depuis 7 s et qu'il n'en a pas ouvert depuis 10 s (VI-31, RG-27, R-10). Verrou périmé (PID mort ou ping sans réponse) ignoré (ENF-09).
- Le serveur est lancé par `Start-Process -WindowStyle Hidden` : il a sa propre console et survit à la fermeture du terminal (VI-30).

## ADR-10 — Rafraîchissement

- **Décision** : la page interroge `/api/state` toutes les 1 s au premier plan, 5 s en arrière-plan (ENF-04). `state` renvoie une empreinte (HEAD, refs, statut) ; graphe et détails ne sont rechargés que si elle change (VI-08, VI-06).

## ADR-11 — Graphe

- **Décision** : `git log --date-order -n <limite> --parents` sur toutes les refs sauf `refs/stash` (et `refs/autosave/*` si masquées). Disposition en colonnes côté navigateur ; la chaîne des premiers parents de la branche principale (`origin/HEAD`, sinon `main`, `master`, `develop`, sinon branche courante) occupe la colonne 0 (VI-01).
