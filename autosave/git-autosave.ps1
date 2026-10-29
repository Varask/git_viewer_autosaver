<#
  git autosave — points de reprise automatiques du travail en cours.
  Lot L3 : SA-07, SA-09 à SA-12, TR-03, TR-04. Ce fichier doit rester en UTF-8 avec BOM.
  Codes de sortie : 0 succès, 1 commande ou valeur invalide, 2 hors projet git, 3 échec.
#>
param(
    [Parameter(Position = 0)] [string] $Command = '',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitAutosave.psm1') -DisableNameChecking
Initialize-GTConsole

$Flags = @($Rest | Where-Object { $_ -like '--*' })
$Args2 = @($Rest | Where-Object { $_ -notlike '--*' })
$Quiet = $Flags -contains '--quiet' -or $Flags -contains '--scheduled'

function Say([string] $Text) { if (-not $Quiet) { Write-Host $Text } }
function Fail([string] $Text, [int] $Code = 3) { [Console]::Error.WriteLine("Erreur : $Text"); exit $Code }

function Resolve-UserPath([string] $Path) {
    # Avec « git autosave … », git se place à la racine et donne le sous-dossier d'origine dans GIT_PREFIX.
    $here = (Get-Location).ProviderPath
    if ($env:GIT_PREFIX) { $here = Join-Path $here $env:GIT_PREFIX }
    if (-not $Path) { return $here }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $here $Path)
}

function Get-TargetRepo([string] $Path) {
    $p = Resolve-UserPath $Path
    $root = Get-GTRepoRoot $p
    if (-not $root) { Fail "« $p » n'est pas dans un projet git. Placez-vous dans le projet ou indiquez son chemin." 2 }
    return $root
}

function Format-When($Date) {
    if (-not $Date) { return '—' }
    return $Date.ToString('dd/MM/yyyy HH:mm:ss')
}

function Show-Help {
    $cfg = Get-GTConfig
    $sched = Get-AutosaveSchedule
    $projects = @(Get-GTProjects)
    $etat = if ($sched.Active) { "active — prochain passage $(Format-When $sched.NextRun)" } else { 'inactive (relancez install.ps1)' }
    $onoff = @{ $true = 'oui'; $false = 'non' }
    Write-Host @"
git autosave — points de reprise automatiques du travail en cours

UTILISATION
  git autosave <commande> [options]        (ou « git-autosave <commande> »)

PROJETS
  add [chemin]          Suivre le projet (dossier courant par défaut)
  remove [chemin]       Ne plus suivre le projet (ses points de reprise sont conservés)
  list                  Projets suivis et nombre de séries

SAUVEGARDE
  run                   Forcer un passage maintenant sur tous les projets suivis
  status [chemin]       Points de reprise de la branche courante
  restore [n|id]        Remettre les fichiers dans l'état d'un point de reprise
                        (le dernier par défaut ; --yes pour ne pas confirmer)
  log [nombre]          Dernières lignes du journal (20 par défaut)

RÉGLAGES
  interval [minutes]    Intervalle entre deux passages, de 5 à 240      actuel : $($cfg.intervalMin) min
  keep on|off           Conserver les séries après un commit manuel      actuel : $($onoff[[bool]$cfg.keepSeries])
  share on|off          Envoyer les points de reprise sur le distant     actuel : $($onoff[[bool]$cfg.shareRemote])
  autotrack on|off      Suivre tout projet ouvert dans le visualiseur    actuel : $($onoff[[bool]$cfg.autoTrack])
  launcher conhost|wscript  Lanceur sans fenêtre de la tâche planifiée   actuel : $($cfg.launcher)

ÉTAT
  Sauvegarde périodique : $etat
  Projets suivis        : $($projects.Count)
  Journal               : $(Join-Path (Get-GTDataDir) 'logs\autosave.log')
"@
}

function Set-OnOff([string] $Name, [string] $Label) {
    $v = if ($Args2.Count) { $Args2[0].ToLowerInvariant() } else { '' }
    if ($v -notin @('on', 'off')) { Fail "Valeur attendue : on ou off (git autosave $($Command) on)." 1 }
    [void](Set-GTConfigValue $Name ($v -eq 'on'))
    Say "$Label : $(if ($v -eq 'on') { 'activé' } else { 'désactivé' })."
}

try {
    switch ($Command.ToLowerInvariant()) {

        'add' {
            $root = Get-TargetRepo ($Args2 | Select-Object -First 1)
            $added = Add-GTProject $root
            $hook = Install-AutosaveHook $root
            Say $(if ($added) { "Projet suivi : $root" } else { "Déjà suivi : $root" })
            if ($hook -eq 'existing') {
                Say "  Le projet a déjà son propre hook post-commit : il n'est pas modifié. Le nettoyage aura lieu au passage suivant."
            }
            if (-not (Get-GitValue $root @('rev-parse', '-q', '--verify', 'HEAD'))) {
                Say "  Le projet n'a encore aucun commit : il sera sauvegardé après le premier."
            }
            # Retirer un projet de l'exclusion d'inscription automatique
            $cfg = Get-GTConfig
            $excl = @($cfg.autoTrackExclude | Where-Object { -not (Test-GTSamePath $_ $root) })
            if ($excl.Count -ne @($cfg.autoTrackExclude).Count) { [void](Set-GTConfigValue 'autoTrackExclude' $excl) }
            Write-GTLog autosave INFO $root 'Projet ajouté au suivi.'
        }

        'remove' {
            $p = Resolve-UserPath ($Args2 | Select-Object -First 1)
            $root = Get-GTRepoRoot $p
            if (-not $root) { $root = (Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).ProviderPath }
            if (-not $root) { $root = $p }
            if (Remove-GTProject $root) {
                if (Test-Path -LiteralPath $root) { [void](Uninstall-AutosaveHook $root) }
                Say "Projet retiré du suivi : $root"
                Say '  Ses points de reprise existants sont conservés.'
                if ($Flags -contains '--no-autotrack') {
                    $cfg = Get-GTConfig
                    [void](Set-GTConfigValue 'autoTrackExclude' (@($cfg.autoTrackExclude) + $root))
                    Say "  Il ne sera plus réinscrit automatiquement par le visualiseur."
                }
                Write-GTLog autosave INFO $root 'Projet retiré du suivi.'
            } else {
                Say "Ce projet n'était pas suivi : $root"
            }
        }

        'list' {
            $items = @(Get-GTProjects)
            if (-not $items.Count) { Say 'Aucun projet suivi. Ajoutez-en un avec « git autosave add » dans le projet.'; break }
            foreach ($p in $items) {
                if (-not (Test-Path -LiteralPath $p)) { Write-Host "  [introuvable] $p"; continue }
                $n = @(Get-AutosaveSeries $p).Count
                Write-Host ("  {0}   ({1} série(s), hook : {2})" -f $p, $n, (Test-AutosaveHook $p))
            }
        }

        'run' {
            $results = @(Invoke-AutosavePass -Scheduled:($Flags -contains '--scheduled'))
            if (-not $Quiet) {
                if (-not $results.Count) { Write-Host 'Aucun projet traité (aucun projet suivi, ou passage déjà en cours).' }
                foreach ($r in $results) {
                    $tag = switch ($r.Result) { 'Saved' { 'sauvegardé' } 'Unchanged' { 'inchangé' } 'Skipped' { 'ignoré' } default { 'ERREUR' } }
                    Write-Host ("  {0,-11} {1} — {2}" -f $tag, $r.Project, $r.Message)
                }
            }
            if (@($results | Where-Object { $_.Result -eq 'Error' }).Count) { exit 3 }
        }

        'cleanup' {
            # Appelé par le hook post-commit.
            $root = Get-GTRepoRoot (Resolve-UserPath ($Args2 | Select-Object -First 1))
            if ($root) { [void](Invoke-AutosaveCleanup $root) }
        }

        'status' {
            $root = Get-TargetRepo ($Args2 | Select-Object -First 1)
            $branch = Get-GitValue $root @('symbolic-ref', '-q', '--short', 'HEAD')
            $head = Get-GitValue $root @('rev-parse', '-q', '--verify', 'HEAD')
            Write-Host "Projet  : $root $(if (Test-GTProjectTracked $root) { '(suivi)' } else { '(non suivi)' })"
            Write-Host "Branche : $(if ($branch) { $branch } else { 'aucune (HEAD détaché)' })"
            $sched = Get-AutosaveSchedule
            Write-Host "Prochain passage : $(if ($sched.Active) { Format-When $sched.NextRun } else { 'inactif' })"
            $all = @(Get-AutosaveSeries $root)
            $cur = @($all | Where-Object { $_.Branch -eq $branch -and $_.Base -eq $head })
            if ($cur.Count) {
                Write-Host 'Points de reprise depuis le dernier commit :'
                foreach ($pt in Get-AutosavePoints $root $cur[0]) {
                    Write-Host ("  {0:D2}  {1}  {2}" -f $pt.Number, $pt.Sha.Substring(0, 8), (Format-When $pt.Date))
                }
            } else {
                Write-Host 'Aucun point de reprise depuis le dernier commit.'
            }
            $other = $all.Count - $cur.Count
            if ($other -gt 0) { Write-Host "$other autre(s) série(s) conservée(s) (autres branches ou bases)." }
        }

        'restore' {
            $root = Get-TargetRepo ''
            $target = if ($Args2.Count) { $Args2[0] } else { 'latest' }
            $sha = Resolve-AutosavePoint $root $target
            $subject = Get-GitValue $root @('log', '-1', '--format=%s', $sha)
            if ($Flags -notcontains '--yes') {
                Write-Host "Les fichiers du projet vont reprendre l'état de : $subject ($($sha.Substring(0,8)))."
                Write-Host "Votre travail actuel sera d'abord sauvegardé dans un point de reprise. La branche ne change pas."
                $answer = Read-Host 'Confirmer ? (o/N)'
                if ($answer -notmatch '^(o|oui|y|yes)$') { Say 'Restauration annulée.'; break }
            }
            $res = Restore-GTCommitFiles $root $sha
            Say "Fichiers restaurés depuis : $subject."
            if ($res.Safety) { Say "Votre état précédent est conservé dans le point $($res.Safety.Substring(0,8))." }
        }

        'log' {
            $n = 20
            if ($Args2.Count) {
                if ($Args2[0] -notmatch '^\d+$') { Fail 'Nombre de lignes attendu, par exemple : git autosave log 50' 1 }
                $n = [int]$Args2[0]
            }
            $file = Join-Path (Get-GTDataDir) 'logs\autosave.log'
            if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Tail $n -Encoding UTF8 }
            else { Say 'Journal vide.' }
        }

        'interval' {
            if (-not $Args2.Count) { Write-Host "Intervalle : $((Get-GTConfig).intervalMin) min"; break }
            $v = $Args2[0]
            if ($v -notmatch '^\d+$' -or [int]$v -lt 5 -or [int]$v -gt 240) {
                Fail "Intervalle invalide « $v » : nombre entier de minutes entre 5 et 240." 1
            }
            $cfg = Set-GTConfigValue 'intervalMin' ([int]$v)
            if (Get-AutosaveTask) { Register-AutosaveTask $cfg }
            Say "Intervalle réglé à $v min. Prochain passage : $(Format-When (Get-GTNextRun))."
        }

        'launcher' {
            $v = if ($Args2.Count) { $Args2[0].ToLowerInvariant() } else { '' }
            if ($v -notin @('conhost', 'wscript')) { Fail 'Valeur attendue : conhost ou wscript.' 1 }
            $cfg = Set-GTConfigValue 'launcher' $v
            if (Get-AutosaveTask) { Register-AutosaveTask $cfg }
            Say "Lanceur de la tâche planifiée : $v."
        }

        'keep'     { Set-OnOff 'keepSeries' 'Conservation des séries après commit' }
        'share'    { Set-OnOff 'shareRemote' 'Partage des points de reprise sur le distant' }
        'autotrack' { Set-OnOff 'autoTrack' 'Inscription automatique par le visualiseur' }

        { $_ -in @('', 'help', '--help', '-h', 'aide') } { Show-Help }

        default {
            [Console]::Error.WriteLine("Commande inconnue : « $Command ».")
            Show-Help
            exit 1
        }
    }
    exit 0
} catch {
    Write-GTLog autosave ERROR '' "$Command : $($_.Exception.Message)"
    Fail $_.Exception.Message 3
}
