## 1. Contexte et objectifs

git-tools doit garantir qu'aucun travail en cours sur un projet versionné n'est perdu entre deux commits, et donner une vue claire et pilotable de l'état de ce projet. Le tout sans changer la façon de travailler du développeur.

**Constat de départ.** Un développeur peut passer plusieurs heures sans committer. Pendant ce temps, son travail n'existe que dans ses fichiers : une erreur de manipulation, un fichier écrasé ou une modification regrettée ne peuvent pas être annulés. Committer plus souvent « pour sauvegarder » pollue l'historique du projet.

**Objectifs.**

1. Conserver automatiquement des points de reprise du travail en cours, à intervalle régulier, sans action de l'utilisateur.
2. Garder l'historique officiel du projet propre : les points de reprise sont séparés des commits manuels et peuvent disparaître une fois le travail committé.
3. Rester totalement transparent : l'utilisateur ne voit pas ses fichiers, sa branche ou sa sélection de fichiers à committer modifiés par le système.
4. Offrir une vue graphique de l'historique du projet, mise à jour en continu, avec les actions courantes de gestion du dépôt.
5. Rendre l'adoption simple : une installation unique, puis une seule commande pour ajouter un projet.

## 2. Périmètre, acteurs et environnement

Le produit se compose de deux outils indépendants mais complémentaires : **la sauvegarde automatique** et **le visualiseur**. Chacun doit pouvoir être utilisé sans l'autre.

**Dans le périmètre**

- Projets versionnés sous git, sur le poste de travail de l'utilisateur.
- Plusieurs projets suivis en parallèle par la sauvegarde automatique.
- Un poste de travail Windows, y compris un poste géré par une DSI avec des restrictions d'exécution.
- Les opérations courantes sur le dépôt local et les échanges simples avec le dépôt distant.

**Hors périmètre**

- La sauvegarde de fichiers hors d'un projet git, ou ignorés par le projet.
- Les opérations git avancées : résolution de conflits, rebase interactif, réécriture d'historique.
- Le travail à plusieurs sur un même poste, et l'accès au visualiseur depuis une autre machine.
- La gestion des identifiants d'accès aux dépôts distants.

**Acteurs**

| Acteur | Rôle vis-à-vis du produit |
| --- | --- |
| Développeur (utilisateur principal) | Installe les outils, ajoute ses projets, consulte et pilote ses dépôts, restaure un point de reprise |
| Planificateur du système | Déclenche la sauvegarde automatique à intervalle régulier, sans l'utilisateur |
| Projet git | Objet sauvegardé et visualisé ; son historique officiel ne doit pas être altéré |
| Dépôt distant | Reçoit ou fournit des commits (récupération, envoi) ; peut recevoir les points de reprise si l'utilisateur le demande |
| Administrateur du poste (DSI) | Fixe les règles d'exécution que le produit doit respecter, sans les contourner |

## 3. Glossaire

| Terme | Définition |
| --- | --- |
| Commit manuel | Commit fait volontairement par l'utilisateur. Il fait partie de l'historique officiel du projet. |
| Point de reprise (autosave) | Instantané du travail en cours enregistré automatiquement. Il ne fait pas partie de l'historique officiel. |
| Base | Dernier commit manuel de la branche courante. Les points de reprise en partent. |
| Série de points de reprise | Suite ordonnée des points de reprise d'une même base (Autosave 01, 02…). |
| Projet suivi | Projet inscrit à la sauvegarde automatique. |
| Passage | Exécution périodique de la sauvegarde sur tous les projets suivis. |
| Intervalle | Durée entre deux passages (30 min par défaut). |
| Travail en cours | Ensemble des modifications non committées : fichiers modifiés, ajoutés, supprimés, nouveaux. |
| Index | Sélection des modifications qui entreront dans le prochain commit (« fichiers indexés »). |
| Graphe | Représentation de l'historique : commits, branches, fusions. |
| Instance | Exemplaire du visualiseur en fonctionnement. Une seule à la fois. |
| Projets récents | Liste des derniers projets ouverts dans le visualiseur. |

## 4. Besoin fondamental et fonctions de service

Le produit sert au développeur à ne jamais perdre son travail en cours et à garder la maîtrise de ses projets, sans changer sa façon de travailler.

**Bête à cornes**

- **À qui rend-il service ?** Au développeur.
- **Sur quoi agit-il ?** Sur ses projets versionnés sous git.
- **Dans quel but ?** Ne jamais perdre son travail en cours et connaître et piloter l'état de ses projets, sans alourdir l'historique ni ses habitudes.

**Diagramme pieuvre**

&#91;embedded content: diagramme pieuvre · 3 fonctions principales, 7 contraintes\]

Les fonctions principales relient deux éléments à travers le produit ; les contraintes relient le produit à un seul élément.

| Réf. | Fonction | Éléments | Critère et niveau |
| --- | --- | --- | --- |
| FP1 | Permettre au développeur de retrouver à tout moment son travail en cours sur un projet | Développeur, projet | Perte maximale : un intervalle (30 min par défaut) |
| FP2 | Permettre au développeur de voir et piloter l'état de ses projets | Développeur, projet | Changement visible en 2 s environ ; actions courantes sans ligne de commande |
| FP3 | Permettre au développeur d'échanger ses commits avec le dépôt distant | Développeur, dépôt distant | Récupérer, tirer sans divergence, pousser |
| FC1 | Ne jamais altérer l'historique officiel, la branche, l'index ni les fichiers | Projet | Aucune modification non demandée |
| FC2 | Fonctionner seul, au rythme choisi | Temps | Intervalle réglable ; pas de chevauchement de passages |
| FC3 | Respecter les règles d'exécution du poste | Poste de travail | Aucun contournement ; procédure documentée en cas de blocage |
| FC4 | Ne pas déranger le développeur | Développeur | Aucune fenêtre, aucun terminal bloqué, aucune gêne sur ses commandes |
| FC5 | Rester confidentiel au poste | Réseau | Inaccessible depuis une autre machine ou une autre page web |
| FC6 | Être simple à installer, utiliser et retirer | Développeur | Une installation, une commande par projet, désinstallation propre |
| FC7 | Fonctionner sur le poste tel qu'il est | Poste de travail | Windows 10 et 11, rien à installer en plus de git, sans internet, sans droits d'administrateur |

## 5. Fonctions détaillées : sauvegarde automatique

La sauvegarde automatique enregistre le travail en cours de chaque projet suivi à intervalle régulier, à côté de l'historique officiel, et nettoie ces enregistrements quand l'utilisateur committe.

**Grille SMART des sections 5 à 9.** Chaque exigence est **spécifique** (un seul comportement par ligne), **mesurable** (critère chiffré ou vérifiable, avec le scénario de recette R-xx quand il existe), **atteignable** (seuils compatibles avec le poste de travail visé), **pertinente** (rattachée à une fonction de service FP/FC de la section 4) et **datée** (jalon V1 = reprise du projet, V2 = version suivante ; dates en points ouverts). Les règles de gestion de la section 8 précisent ces exigences et ne sont pas reprises dans la grille.

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| SA-01 | Enregistrer un point de reprise du travail en cours | À chaque passage, 100 % des fichiers modifiés, ajoutés, supprimés et nouveaux (non ignorés) d'un projet suivi sont présents dans le point de reprise (R-01) | FP1 | V1 |
| SA-02 | Ne sauvegarder que ce qui a changé | 0 point de reprise créé par un passage sans modification depuis le précédent (R-02) | FP1, FC1 | V1 |
| SA-03 | Rattacher les points de reprise à leur base | Chaque point porte un numéro d'ordre (01, 02…) et sa date ; la série part du dernier commit manuel de la branche courante (R-03) | FP1 | V1 |
| SA-04 | Être transparent pendant un passage | Branche, index et contenu des fichiers identiques avant et après le passage ; 0 fenêtre affichée (R-01, R-07) | FC1, FC4 | V1 |
| SA-05 | Nettoyer au commit manuel | Série de l'ancienne base supprimée moins de 10 s après le commit manuel ; au plus tard au passage suivant si le projet a son propre déclencheur (R-04) | FC1 | V1 |
| SA-06 | Conserver les séries à la demande | Réglage activé : 100 % des séries conservées après un commit manuel (R-05) | FP1 | V1 |
| SA-07 | Partager les points de reprise à la demande | Réglage activé : chaque point de reprise est présent sur le distant à la fin du passage et en est retiré au nettoyage | FP1, FP3 | V1 |
| SA-08 | Restaurer un point de reprise | Fichiers restaurés identiques à ceux du point de reprise ; branche inchangée ; 1 commande ou 1 clic + 1 confirmation (R-06) | FP1 | V1 |
| SA-09 | Gérer la liste des projets suivis | Ajouter, retirer, lister : 1 commande chacune, depuis n'importe quel dossier du projet | FC6 | V1 |
| SA-10 | Forcer un passage | 1 commande ; tous les projets suivis traités et consignés au journal à la fin de la commande | FP1 | V1 |
| SA-11 | Régler l'intervalle | Intervalle réglable de 5 à 240 min par pas de 1 min, 30 min par défaut (R-07) | FC2 | V1 |
| SA-12 | Tracer l'activité | 100 % des sauvegardes, suppressions, projets ignorés et erreurs consignés avec date, heure et projet (R-08) | FC2 | V1 |

## 6. Fonctions détaillées : visualisation et gestion du dépôt

Le visualiseur montre en continu l'état d'un projet et permet d'agir dessus sans passer par la ligne de commande.

**Consulter**

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| VI-01 | Afficher le graphe de l'historique | 100 % des commits des branches locales, distantes et tags parmi les 400 plus récents (nombre réglable) ; fusions tracées ; branche principale dans la colonne de gauche | FP2 | V1 |
| VI-02 | Distinguer les points de reprise | Différenciables des commits manuels sans lire leur libellé ; masquables en 1 clic | FP2 | V1 |
| VI-03 | Montrer le travail en cours | Entrée en tête du graphe dès 1 modification, avec leur nombre exact | FP2 | V1 |
| VI-04 | Résumer l'état du projet | Branche, avance et retard sur le distant, nombre de modifications et de stash visibles sans clic et conformes à l'état réel | FP2 | V1 |
| VI-05 | Détailler un commit | Message, auteur, date et fichiers touchés affichés en 1 clic | FP2 | V1 |
| VI-06 | Afficher les différences d'un fichier | Différences indexées ou non (ou contenu d'un nouveau fichier) en 1 clic ; mises à jour en 2 s au plus après modification du fichier | FP2 | V1 |
| VI-07 | Indiquer la prochaine sauvegarde | Compte à rebours à la seconde, écart de 5 s au plus avec l'heure réelle du passage ; état « non suivi » ou « inactif » affiché sinon (R-14) | FP1, FP2 | V1 |
| VI-08 | Se mettre à jour seul | Toute évolution du projet, y compris faite ailleurs, visible en 2 s au plus sans recharger (R-11) | FP2 | V1 |

**Agir sur le dépôt local**

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| VI-10 | Indexer et désindexer | 1 clic par fichier ; 1 clic pour la totalité (R-12) | FP2 | V1 |
| VI-11 | Annuler les modifications d'un fichier | 1 clic + 1 confirmation ; fichier revenu à sa dernière version connue, ou supprimé s'il est nouveau | FP2 | V1 |
| VI-12 | Committer | Index seul ou tout le travail en cours en 2 actions (message, bouton) ; option de modification du dernier commit (R-12) | FP2 | V1 |
| VI-13 | Annuler le dernier commit | 1 clic + 1 confirmation ; 0 modification perdue, toutes prêtes à être recommittées (R-13) | FP2 | V1 |
| VI-14 | Mettre de côté et réappliquer | 1 clic chacun ; fichiers nouveaux inclus | FP2 | V1 |
| VI-15 | Gérer les branches | Changer, créer, fusionner, supprimer : 2 clics au plus, + confirmation pour fusion et suppression (R-15) | FP2 | V1 |
| VI-16 | Restaurer les fichiers d'un commit | 1 clic + 1 confirmation ; fichiers identiques à ceux du commit ; branche inchangée (R-06) | FP1 | V1 |
| VI-17 | Se placer sur un commit | 1 clic + 1 confirmation ; aucune branche modifiée | FP2 | V1 |

**Agir avec le distant**

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| VI-20 | Récupérer l'état du distant | 1 clic ; 0 modification du travail local ni des branches locales | FP3 | V1 |
| VI-21 | Tirer les commits distants | 1 clic ; en cas de divergence, refus avec message et 0 fusion créée | FP3 | V1 |
| VI-22 | Pousser les commits locaux | 1 clic ; résultat affiché : succès ou cause de l'échec | FP3 | V1 |

**Piloter le visualiseur**

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| VI-30 | Lancer sans bloquer | Main rendue au terminal en 5 s au plus ; page ouverte sur le projet en 10 s au plus ; le terminal peut être fermé sans effet (R-09) | FC4 | V1 |
| VI-31 | N'avoir qu'une instance | 1 seul exemplaire actif après n lancements, y compris simultanés ; 0 onglet supplémentaire si une page est déjà ouverte (R-10) | FC4 | V1 |
| VI-32 | Ouvrir un autre projet | 2 clics au plus depuis la liste (15 récents + projets suivis) ; aussi par saisie d'un chemin ou par sélecteur de dossier (R-14) | FP2 | V1 |
| VI-33 | Reprendre le dernier projet | Lancé hors d'un projet, rouvre le dernier projet consulté dans 100 % des cas où il existe encore | FC6 | V1 |
| VI-34 | Inscrire à la sauvegarde | Projet ouvert présent dans la liste des projets suivis en 5 s au plus, sauf option contraire (R-14) | FP1 | V1 |
| VI-35 | Arrêter le visualiseur | 1 clic + 1 confirmation, ou 1 commande ; 0 processus restant | FC6 | V1 |

## 7. Fonctions transverses

Ces fonctions encadrent le cycle de vie des deux outils, de l'installation au retrait complet.

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| TR-01 | Installer les deux outils en une fois | 1 opération de 2 min au plus ; les deux commandes reconnues dans un nouveau terminal, depuis tout dossier | FC6 | V1 |
| TR-02 | Installer chaque outil séparément | Chaque outil fonctionne en l'absence de l'autre | FC6 | V1 |
| TR-03 | Appeler les commandes depuis n'importe où | Commandes reconnues depuis 100 % des dossiers ; sauvegarde appelable avec ou sans préfixe git | FC6 | V1 |
| TR-04 | Afficher l'aide | Sans commande ou avec une commande inconnue : aide affichée en 2 s au plus, avec les commandes, les réglages et l'état (R-16) | FC6 | V1 |
| TR-05 | Regrouper le paramétrage | 100 % des réglages des deux outils listés à un seul endroit, chacun avec une phrase d'explication et sa valeur par défaut | FC6 | V2 |
| TR-06 | Réinstaller sans dommage | Après réinstallation : liste des projets identique ; 0 doublon de commande, de déclencheur ou de sauvegarde périodique | FC6 | V1 |
| TR-07 | Désinstaller proprement | 1 opération par outil ; 0 élément ajouté par l'installation restant ; visualiseur arrêté (R-17) | FC6 | V1 |
| TR-08 | Conserver les données à la désinstallation | Liste des projets et points de reprise intacts après désinstallation (R-17) | FP1 | V1 |
| TR-09 | Documenter le produit | Guide couvrant les 7 thèmes : installation, usage, réglages, restauration, désinstallation, dépannage, blocage par les règles du poste (R-18) | FC3, FC6 | V1 |
| TR-10 | Accéder facilement au paramétrage | Chaque réglage consultable et modifiable en 3 clics au plus depuis le visualiseur, ou en 1 commande ; 0 fichier à éditer ; retour aux valeurs par défaut en 1 action (R-20) | FC6 | V2 |
| TR-11 | Appliquer un réglage sans démarche supplémentaire | Effet en 5 s au plus, sans réinstallation ni redémarrage ; 100 % des valeurs invalides refusées avec les valeurs acceptées (R-20) | FC6 | V2 |

## 8. Règles de gestion et cas particuliers

Le principe directeur : en cas de doute, le système n'agit pas plutôt que de risquer d'altérer le travail de l'utilisateur.

**Sauvegarde automatique**

| Règle | Comportement attendu |
| --- | --- |
| RG-01 Une série par base | Une série est identifiée par la branche et le commit manuel dont elle part. Deux branches ont des séries distinctes. |
| RG-02 Obsolescence | Une série est obsolète dès que sa branche a avancé (nouveau commit) ou n'existe plus. Elle est alors supprimée, sauf réglage de conservation. |
| RG-03 Moment du nettoyage | Le nettoyage a lieu immédiatement après le commit manuel ; à défaut, au passage suivant. |
| RG-04 Opération en cours | Si une fusion, un rebase, un cherry-pick ou un revert est en cours, le projet est ignoré pour ce passage. |
| RG-05 Position hors branche | Si l'utilisateur n'est sur aucune branche, aucun point de reprise n'est créé. |
| RG-06 Projet vide | Un projet sans aucun commit n'est pas sauvegardé. |
| RG-07 Fichiers ignorés | Les fichiers que le projet déclare ignorer ne sont jamais sauvegardés. |
| RG-08 Projet introuvable | Un projet suivi qui n'existe plus est signalé dans le journal et sauté, sans bloquer les autres. |
| RG-09 Déclencheur existant | Si le projet possède déjà son propre déclencheur après commit, il n'est pas modifié ; le nettoyage se fait au passage suivant. |
| RG-10 Passages qui se chevauchent | Un passage ne démarre pas tant que le précédent n'est pas terminé. |
| RG-11 Retrait d'un projet | Retirer un projet arrête son suivi mais conserve ses points de reprise existants. |

**Visualiseur**

| Règle | Comportement attendu |
| --- | --- |
| RG-20 Confirmation | Toute action qui perd des données ou change l'état de façon notable demande une confirmation : suppression de fichier ou de branche, annulation, restauration, fusion, position hors branche, modification du dernier commit en y ajoutant tout. |
| RG-21 Suppression de branche | Une branche non fusionnée n'est supprimée qu'après une seconde confirmation explicite. |
| RG-22 Tirage | Le tirage est refusé s'il obligerait à fusionner des historiques divergents. |
| RG-23 Message de commit | Un commit sans message est refusé, sauf modification du dernier commit (l'ancien message est alors conservé). |
| RG-24 Commit de l'index | Committer l'index est impossible s'il est vide, sauf modification du dernier commit. |
| RG-25 Changement de projet | Changer de projet réinitialise la sélection, le message en cours et les détails affichés. Tous les onglets ouverts suivent. |
| RG-26 Inscription automatique | Un projet retiré de la sauvegarde y est réinscrit à sa prochaine ouverture, sauf si l'inscription automatique est désactivée. |
| RG-27 Nouvel onglet | Un nouveau lancement n'ouvre un onglet que si aucune page du visualiseur n'est déjà affichée. |
| RG-28 Projet invalide | Ouvrir un dossier qui n'est pas un projet git est refusé avec un message ; le projet courant reste affiché. |
| RG-29 Validation des saisies | Noms de branche et identifiants de commit invalides sont refusés avant toute action. |

## 9. Exigences non fonctionnelles

Ces exigences décrivent la qualité attendue, sans préjuger de la façon de l'obtenir.

| Réf. | Exigence | Critère mesurable | Lien | Jalon |
| --- | --- | --- | --- | --- |
| ENF-01 | Ne pas altérer le travail de l'utilisateur | 0 modification de l'historique officiel, de la branche, de l'index ou des fichiers sans action explicite, sur l'ensemble de la recette | FC1 | V1 |
| ENF-02 | Rester discret | 0 fenêtre, message ou perte de focus pendant une journée de travail de 8 h avec un intervalle de 30 min (R-07) | FC4 | V1 |
| ENF-03 | Ne pas gêner les commandes de l'utilisateur | 0 échec d'une commande git de l'utilisateur causé par le produit pendant la recette | FC4 | V1 |
| ENF-04 | Être réactif | Changement du projet visible en 2 s au plus ; page en arrière-plan : interrogation au plus toutes les 5 s (R-11) | FP2 | V1 |
| ENF-05 | Être autonome | Fonctionne sans connexion internet, avec git comme seul logiciel prérequis | FC7 | V1 |
| ENF-06 | Respecter les règles du poste | 0 contournement ; en cas de blocage, message clair et procédure du guide suffisante pour aboutir (R-18) | FC3 | V1 |
| ENF-07 | Rester confidentiel | Visualiseur injoignable depuis une autre machine ; 100 % des actions déclenchées par une autre page web refusées | FC5 | V1 |
| ENF-08 | Ne jamais attendre une saisie invisible | 0 attente de saisie d'identifiants ; en cas d'identifiants manquants, échec signalé avec sa cause | FP3, FC4 | V1 |
| ENF-09 | Être robuste | 1 projet en erreur : 100 % des autres sauvegardés ; après arrêt brutal du visualiseur, relance réussie du premier coup | FC2 | V1 |
| ENF-10 | Tracer l'activité | 1 journal par outil, de 1 Mo au plus, consultable par l'utilisateur | FC2 | V1 |
| ENF-11 | Être lisible | Interface 100 % en français ; thèmes clair et sombre ; utilisable à 375 px de large sans défilement horizontal ; 0 accent mal affiché | FC6 | V1 |
| ENF-12 | Être compatible | Fonctionne sur Windows 10 (version 21H2 et suivantes) et Windows 11 ; mode de repli documenté pour les versions antérieures | FC7 | V1 |
| ENF-13 | Supporter la volumétrie | 400 commits affichés par défaut (réglable) ; graphe affiché en 2 s au plus pour 400 commits | FP2 | V1 |
| ENF-14 | Accepter tous les chemins | 100 % des fonctions opérantes avec des espaces et des accents dans les chemins | FC7 | V1 |
| ENF-15 | Fonctionner avec des droits limités | 100 % des étapes (installer, utiliser, mettre à jour, désinstaller) réussies avec un compte standard ; 0 demande d'élévation ; écriture limitée aux emplacements de l'utilisateur ; 0 réglage commun à la machine modifié (R-19) | FC7 | V1 |

## 10. Critères d'acceptation et scénarios de recette

Chaque scénario part d'un projet git de test avec au moins un commit, suivi par la sauvegarde automatique. Il est accepté si le résultat observé correspond exactement au résultat attendu.

| N° | Scénario | Résultat attendu | Couvre |
| --- | --- | --- | --- |
| R-01 | Modifier un fichier, créer un fichier, forcer un passage | Un point « Autosave 01 » existe et contient les deux fichiers. La branche, l'index et le statut du projet sont inchangés. | SA-01, SA-04 |
| R-02 | Forcer un second passage sans rien modifier | Aucun nouveau point de reprise. | SA-02 |
| R-03 | Modifier à nouveau, forcer un passage | « Autosave 02 » apparaît à la suite du 01, sur la même série. | SA-03 |
| R-04 | Faire un commit manuel | La série précédente disparaît sans attendre le passage suivant. | SA-05, RG-03 |
| R-05 | Même scénario avec conservation activée | La série précédente est conservée. | SA-06 |
| R-06 | Restaurer un point de reprise après avoir cassé un fichier | Le fichier retrouve son contenu du point de reprise ; la branche n'a pas changé. | SA-08, VI-16 |
| R-07 | Laisser tourner une heure avec intervalle de 30 min | Deux passages, aucune fenêtre apparue. | SA-11, ENF-02 |
| R-08 | Lancer une fusion en conflit puis forcer un passage | Le projet est ignoré et le journal l'indique. | RG-04, SA-12 |
| R-09 | Lancer le visualiseur depuis un terminal | Le terminal rend la main aussitôt, la page s'ouvre sur le projet. | VI-30 |
| R-10 | Relancer le visualiseur depuis un autre projet | Pas de second exemplaire, pas de nouvel onglet ; la page bascule sur le nouveau projet. | VI-31, RG-27 |
| R-11 | Committer depuis un terminal, page ouverte | Le graphe montre le commit en moins de 2 secondes environ, sans recharger. | VI-08, ENF-04 |
| R-12 | Indexer un fichier, committer l'index | Seul ce fichier est committé ; les autres restent en cours. | VI-10, VI-12 |
| R-13 | Annuler le dernier commit | Le commit disparaît ; ses modifications sont indexées. | VI-13 |
| R-14 | Ouvrir un projet non suivi depuis le visualiseur | Il apparaît dans la liste des projets suivis ; le compte à rebours s'affiche. | VI-32, VI-34, VI-07 |
| R-15 | Supprimer une branche non fusionnée | Deux confirmations sont demandées avant la suppression. | RG-20, RG-21 |
| R-16 | Lancer la sauvegarde sans commande | L'aide s'affiche avec l'état courant. | TR-04 |
| R-17 | Désinstaller | Commandes, sauvegarde périodique et déclencheurs retirés, visualiseur arrêté ; liste des projets et points de reprise intacts. | TR-07, TR-08 |
| R-18 | Installer sur un poste qui bloque les fichiers téléchargés | L'installation échoue avec un message clair ; la procédure du guide permet de la réussir. | ENF-06, TR-09 |
| R-19 | Sur un compte sans droits d'administrateur : installer, ajouter un projet, laisser passer une sauvegarde, ouvrir le visualiseur, désinstaller | Chaque étape réussit sans demande d'élévation de droits ; aucun autre compte de la machine n'est affecté. | ENF-15, FC7 |
| R-20 | Depuis le visualiseur, passer l'intervalle de 30 à 15 min, puis saisir une valeur invalide | Le compte à rebours reflète 15 min sans autre manipulation ; la valeur invalide est refusée avec un message clair. | TR-10, TR-11 |

## 11. Points ouverts et évolutions envisageables

Ces points n'ont pas été tranchés ; ils sont à décider avant ou pendant la reprise du projet.

**Points ouverts**

- [ ] La recette sur poste réel reste à faire : le fonctionnement sans fenêtre, le sélecteur de dossier et le compte à rebours n'ont pas encore été vérifiés en situation.
- [ ] Faut-il une limite de durée ou de nombre aux séries conservées quand la conservation est activée ?
- [ ] L'intervalle doit-il être réglable par projet, ou rester commun à tous ?
- [ ] Faut-il un moyen d'exclure un projet de l'inscription automatique par le visualiseur, de façon durable ?
- [ ] Faut-il afficher deux projets côte à côte, ce que l'instance unique empêche aujourd'hui ?
- [ ] Sur un poste qui n'accepte que des programmes signés, quelle démarche suivre auprès de la DSI ?
- [ ] Le guide doit-il rester unique, ou être scindé en guide utilisateur et guide d'installation ?
- [ ] Fixer les dates des jalons V1 (reprise) et V2, pour rendre chaque exigence datée.
- [ ] Valider les seuils proposés : bornes de l'intervalle (5 à 240 min), délais (2 s, 5 s, 10 s), taille du journal (1 Mo), largeur minimale (375 px).
- [ ] Créer les scénarios de recette manquants pour les exigences sans R-xx (SA-07, SA-09, VI-20 à VI-22, ENF-07, ENF-09…).

**Évolutions envisageables**

- Comparer deux points de reprise, ou un point de reprise et le travail en cours, depuis le visualiseur.
- Restaurer un seul fichier d'un point de reprise depuis l'interface.
- Mettre en pause la sauvegarde d'un projet sans le retirer.
- Afficher le journal de la sauvegarde dans le visualiseur.
- Signaler visuellement un passage récent ou une sauvegarde en erreur.
- Permettre la résolution simple de conflits de fusion.
