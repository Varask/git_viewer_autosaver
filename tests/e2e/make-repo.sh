#!/bin/bash
# Dépôt de démonstration : branches, fusion, tag, points de reprise, travail en cours, accents.
set -e
R="$1"; rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b main; git config user.name "Guillaume"; git config user.email "g@example.com"
c() { mkdir -p "$(dirname "$1")"; echo "$2" >> "$1"; git add -A; GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git commit -qm "$4"; }
c README.md "# Démo" "2026-10-20T09:00:00" "Initialisation du projet"
c src/app.ps1 "Write-Host 1" "2026-10-20T10:00:00" "Ajout du script principal"
git switch -qc feature/graphe
c src/graph.js "// graphe" "2026-10-21T09:00:00" "Graphe : disposition des colonnes"
c src/graph.js "// courbes" "2026-10-21T11:00:00" "Graphe : courbes de Bézier"
git switch -q main
c docs/guide.md "Guide" "2026-10-22T09:00:00" "Docs : guide d'installation"
GIT_AUTHOR_DATE="2026-10-23T09:00:00" GIT_COMMITTER_DATE="2026-10-23T09:00:00" git merge -q --no-ff feature/graphe -m "Fusion de feature/graphe"
git tag v0.9
git switch -qc fix/accents
c "src/données é.txt" "café" "2026-10-24T09:00:00" "Correction : chemins accentués"
git switch -q main
c src/app.ps1 "Write-Host 2" "2026-10-25T09:00:00" "Sauvegarde : nettoyage au commit"
git switch -qc experiment
c notes.txt "idée" "2026-10-26T09:00:00" "Essai non fusionné"
git switch -q main
# points de reprise sur main
H=$(git rev-parse HEAD)
P=$H
for n in 1 2; do
  echo "wip $n" >> src/app.ps1
  T=$(GIT_INDEX_FILE="$R/../.idx-$$" git read-tree HEAD && GIT_INDEX_FILE="$R/../.idx-$$" git add -A && GIT_INDEX_FILE="$R/../.idx-$$" git write-tree)
  P=$(GIT_COMMITTER_NAME="git-tools autosave" GIT_COMMITTER_EMAIL=autosave@git-tools.local GIT_COMMITTER_DATE="2026-10-29T1$n:00:00" GIT_AUTHOR_DATE="2026-10-29T1$n:00:00" git commit-tree $T -p $P -m "Autosave 0$n — 29/10/2026 1$n:00")
done
git update-ref refs/autosave/main/$H $P
rm -f "$R/../.idx-$$"
echo "nouveau" > "nouveau fichier.txt"
echo "staged" >> README.md; git add README.md
