# git-tools — moteur de sauvegarde automatique (lot L2)
# SA-01 à SA-08, SA-10, SA-12, RG-01 à RG-11. Décisions : docs/adr.md (ADR-01 à ADR-07).
# Ce fichier doit rester en UTF-8 avec BOM.

Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'common\GitTools.Common.psm1') -DisableNameChecking -Global

$script:RefPrefix = 'refs/autosave/'
$script:HookMarker = 'git-tools-autosave-hook'
$script:CommitterEnv = @{
    GIT_COMMITTER_NAME  = 'git-tools autosave'
    GIT_COMMITTER_EMAIL = 'autosave@git-tools.local'
}
$script:TaskName = 'git-tools-autosave'
$script:MutexName = 'Local\git-tools-autosave'

# ---------------------------------------------------------------- lecture de l'état du projet

function Get-AutosaveGitDir {
    param([string] $Repo)
    $d = Get-GitValue $Repo @('rev-parse', '--absolute-git-dir')
    if ($d) { return (ConvertTo-GTNativePath $d) }
    return $null
}

function Get-AutosaveBusyReason {
    # RG-04 : opération git en cours → projet ignoré.
    param([string] $GitDir)
    $checks = [ordered]@{
        'MERGE_HEAD'       = 'fusion en cours'
        'rebase-merge'     = 'rebase en cours'
        'rebase-apply'     = 'rebase ou application de patch en cours'
        'CHERRY_PICK_HEAD' = 'cherry-pick en cours'
        'REVERT_HEAD'      = 'revert en cours'
    }
    foreach ($k in $checks.Keys) {
        if (Test-Path -LiteralPath (Join-Path $GitDir $k)) { return $checks[$k] }
    }
    return $null
}

function Get-AutosaveSeriesRef {
    param([string] $Branch, [string] $Base)
    return "$script:RefPrefix$Branch/$Base"
}

function Get-AutosaveSeries {
    # Toutes les séries du projet : { Ref; Branch; Base; Tip; Count }.
    param([Parameter(Mandatory)] [string] $Repo)
    $r = Invoke-Git $Repo @('for-each-ref', '--format=%(refname)%09%(objectname)', $script:RefPrefix) -AllowFail
    $list = @()
    foreach ($line in $r.Lines) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $ref = $parts[0]
        $rest = $ref.Substring($script:RefPrefix.Length)
        $i = $rest.LastIndexOf('/')
        if ($i -lt 1) { continue }
        $base = $rest.Substring($i + 1)
        if ($base -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { continue }
        $count = Get-GitValue $Repo @('rev-list', '--count', "$base..$($parts[1])")
        $list += [pscustomobject]@{
            Ref    = $ref
            Branch = $rest.Substring(0, $i)
            Base   = $base
            Tip    = $parts[1]
            Count  = if ($count) { [int]$count } else { 0 }
        }
    }
    return $list
}

function Get-AutosavePoints {
    # Points d'une série, du plus récent au plus ancien : { Sha; Number; Date; Subject }.
    param([string] $Repo, $Series)
    $r = Invoke-Git $Repo @('log', '--format=%H%x09%ct%x09%s', "$($Series.Base)..$($Series.Tip)") -AllowFail
    $n = $Series.Count
    $points = @()
    foreach ($line in $r.Lines) {
        $p = $line -split "`t", 3
        $points += [pscustomobject]@{
            Sha     = $p[0]
            Number  = $n
            Date    = [DateTimeOffset]::FromUnixTimeSeconds([long]$p[1]).LocalDateTime
            Subject = $p[2]
        }
        $n--
    }
    return $points
}

function Get-AutosaveRemote {
    # Distant de la branche, sinon « origin » s'il existe.
    param([string] $Repo, [string] $Branch)
    $remote = Get-GitValue $Repo @('config', '--get', "branch.$Branch.remote")
    if ($remote -and $remote -ne '.') { return $remote }
    $remotes = (Invoke-Git $Repo @('remote') -AllowFail).Lines
    if ($remotes -contains 'origin') { return 'origin' }
    return $null
}

# ---------------------------------------------------------------- nettoyage (SA-05, SA-06, RG-02, RG-03)

function Remove-AutosaveObsolete {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        $Config = (Get-GTConfig),
        [switch] $Quiet
    )
    $removed = 0
    if ($Config.keepSeries) { return $removed }
    foreach ($s in Get-AutosaveSeries $Repo) {
        $tip = Get-GitValue $Repo @('rev-parse', '-q', '--verify', "refs/heads/$($s.Branch)^{commit}")
        if ($tip -eq $s.Base) { continue }
        $r = Invoke-Git $Repo @('update-ref', '-d', $s.Ref, $s.Tip) -AllowFail
        if ($r.ExitCode -ne 0) {
            Write-GTLog autosave WARN $Repo "Suppression impossible de la série $($s.Branch) : $($r.Err)"
            continue
        }
        $removed++
        $why = if ($tip) { 'commit manuel' } else { 'branche supprimée' }
        Write-GTLog autosave CLEAN $Repo "Série $($s.Branch)@$($s.Base.Substring(0,7)) supprimée ($($s.Count) point(s), $why)"
        if ($Config.shareRemote) {
            $remote = Get-AutosaveRemote $Repo $s.Branch
            if ($remote) {
                $p = Invoke-Git $Repo @('push', '--quiet', $remote, ":$($s.Ref)") -TimeoutSec 60 -AllowFail
                if ($p.ExitCode -ne 0) {
                    Write-GTLog autosave WARN $Repo "Série non retirée du distant $remote : $($p.Err)"
                }
            }
        }
    }
    return $removed
}

# ---------------------------------------------------------------- passage sur un projet

function New-AutosaveResult {
    param([string] $Project, [string] $Result, [string] $Message, [string] $Point = $null)
    [pscustomobject]@{ Project = $Project; Result = $Result; Message = $Message; Point = $Point }
}

function Invoke-AutosaveProject {
    <#
      Un passage sur un projet. Ne touche ni l'index, ni la branche, ni les fichiers (ADR-02).
      Result : Saved | Unchanged | Skipped | Error
    #>
    param(
        [Parameter(Mandatory)] [string] $Repo,
        $Config = (Get-GTConfig)
    )
    # RG-08 : projet introuvable
    if (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
        Write-GTLog autosave SKIP $Repo 'Projet introuvable : ignoré.'
        return New-AutosaveResult $Repo 'Skipped' 'projet introuvable'
    }
    $gitDir = Get-AutosaveGitDir $Repo
    if (-not $gitDir) {
        Write-GTLog autosave SKIP $Repo "Ce dossier n'est plus un projet git : ignoré."
        return New-AutosaveResult $Repo 'Skipped' "n'est plus un projet git"
    }
    # RG-06 : projet sans commit
    $head = Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD^{commit}')
    if (-not $head) {
        Write-GTLog autosave SKIP $Repo 'Projet sans aucun commit : rien à sauvegarder.'
        return New-AutosaveResult $Repo 'Skipped' 'aucun commit'
    }
    # RG-04 : opération en cours
    $busy = Get-AutosaveBusyReason $gitDir
    if ($busy) {
        Write-GTLog autosave SKIP $Repo "Ignoré : $busy."
        return New-AutosaveResult $Repo 'Skipped' $busy
    }
    # RG-03 : nettoyage au passage (si le hook n'a pas pu le faire)
    [void](Remove-AutosaveObsolete -Repo $Repo -Config $Config)

    # RG-05 : hors branche
    $branch = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
    if (-not $branch) {
        Write-GTLog autosave SKIP $Repo 'Hors branche (HEAD détaché) : aucun point de reprise.'
        return New-AutosaveResult $Repo 'Skipped' 'hors branche'
    }

    $ref = Get-AutosaveSeriesRef $branch $head
    $last = Get-GitValue $Repo @('rev-parse', '-q', '--verify', "$ref^{commit}")

    # ADR-02 : index temporaire
    $tmpIndex = Join-Path ([System.IO.Path]::GetTempPath()) ("git-tools-index-" + [guid]::NewGuid().ToString('N'))
    try {
        $realIndex = Get-GitValue $Repo @('rev-parse', '--git-path', 'index')
        if ($realIndex -and -not [System.IO.Path]::IsPathRooted($realIndex)) { $realIndex = Join-Path $Repo $realIndex }
        $envIdx = @{ GIT_INDEX_FILE = $tmpIndex }
        $copied = $false
        if ($realIndex -and (Test-Path -LiteralPath $realIndex)) {
            try { Copy-Item -LiteralPath $realIndex -Destination $tmpIndex -Force; $copied = $true } catch { }
        }
        if (-not $copied) { [void](Invoke-Git $Repo @('read-tree', 'HEAD') -Environment $envIdx) }

        $add = Invoke-Git $Repo @('add', '-A', '--ignore-errors', '--', ':/') -Environment $envIdx -TimeoutSec 600 -AllowFail
        if ($add.ExitCode -ne 0) {
            if ($add.Err -match 'unable to (index|stat)|error:') {
                Write-GTLog autosave WARN $Repo "Certains fichiers n'ont pas pu être lus : $($add.Err -replace '\s+', ' ')"
            } else {
                throw "git add : $($add.Err)"
            }
        }
        $tree = (Invoke-Git $Repo @('write-tree') -Environment $envIdx).Out.Trim()
    } finally {
        foreach ($f in @($tmpIndex, "$tmpIndex.lock")) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    # ADR-03 / SA-02 : rien n'a changé
    $compareTo = if ($last) { $last } else { $head }
    $prevTree = Get-GitValue $Repo @('rev-parse', "$compareTo^{tree}")
    if ($tree -eq $prevTree) {
        return New-AutosaveResult $Repo 'Unchanged' 'aucune modification depuis le dernier point'
    }

    # SA-03 : numéro d'ordre et date
    $number = 1
    if ($last) {
        $c = Get-GitValue $Repo @('rev-list', '--count', "$head..$last")
        if ($c) { $number = [int]$c + 1 }
    }
    $label = 'Autosave {0:D2} — {1}' -f $number, (Get-Date).ToString('dd/MM/yyyy HH:mm')
    $msgFile = Join-Path ([System.IO.Path]::GetTempPath()) ("git-tools-msg-" + [guid]::NewGuid().ToString('N'))
    try {
        Write-GTText $msgFile ($label + "`n`nPoint de reprise créé par git-tools sur la branche $branch.`n")
        $envC = @{} + $script:CommitterEnv
        if (-not (Get-GitValue $Repo @('config', 'user.name'))) {
            $envC['GIT_AUTHOR_NAME'] = $script:CommitterEnv.GIT_COMMITTER_NAME
            $envC['GIT_AUTHOR_EMAIL'] = $script:CommitterEnv.GIT_COMMITTER_EMAIL
        }
        $parent = if ($last) { $last } else { $head }
        $commit = (Invoke-Git $Repo @('commit-tree', $tree, '-p', $parent, '-F', $msgFile) -Environment $envC).Out.Trim()
    } finally {
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    }
    # Mise à jour conditionnelle : échoue si la série a bougé entre-temps.
    $old = if ($last) { $last } else { '0' * 40 }
    [void](Invoke-Git $Repo @('update-ref', '-m', 'git-tools autosave', $ref, $commit, $old))
    Write-GTLog autosave SAVE $Repo "$label sur $branch ($($commit.Substring(0,7)))"

    # SA-07 : partage sur le distant
    if ($Config.shareRemote) {
        $remote = Get-AutosaveRemote $Repo $branch
        if ($remote) {
            $p = Invoke-Git $Repo @('push', '--quiet', $remote, "+$($ref):$($ref)") -TimeoutSec 60 -AllowFail
            if ($p.ExitCode -ne 0) { Write-GTLog autosave WARN $Repo "Partage sur $remote impossible : $($p.Err)" }
        } else {
            Write-GTLog autosave WARN $Repo 'Partage demandé mais aucun dépôt distant configuré.'
        }
    }
    return New-AutosaveResult $Repo 'Saved' $label $commit
}

# ---------------------------------------------------------------- passage sur tous les projets (SA-10, RG-10, ENF-09)

function Invoke-AutosavePass {
    param([switch] $Scheduled)
    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne($(if ($Scheduled) { 0 } else { 30000 })) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            Write-GTLog autosave SKIP '' 'Un passage est déjà en cours : celui-ci est annulé.'
            return @()
        }
        $config = Get-GTConfig
        $projects = @(Get-GTProjects)
        Write-GTLog autosave INFO '' ("Passage {0} : {1} projet(s)." -f $(if ($Scheduled) { 'planifié' } else { 'manuel' }), $projects.Count)
        $results = @()
        foreach ($p in $projects) {
            try {
                $results += Invoke-AutosaveProject -Repo $p -Config $config
            } catch {
                Write-GTLog autosave ERROR $p $_.Exception.Message
                $results += New-AutosaveResult $p 'Error' $_.Exception.Message
            }
        }
        Set-AutosaveLastRun
        return $results
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Set-AutosaveLastRun {
    $f = Join-Path (Get-GTDataDir) 'state.json'
    Write-GTJson $f ([ordered]@{ lastRun = (Get-Date).ToString('o') })
}

function Invoke-AutosaveCleanup {
    # Appelé par le hook post-commit (SA-05) : nettoyage seul, en arrière-plan.
    param([Parameter(Mandatory)] [string] $Repo)
    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(8000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return 0 }
        return Remove-AutosaveObsolete -Repo $Repo
    } catch {
        Write-GTLog autosave ERROR $Repo "Nettoyage : $($_.Exception.Message)"
        return 0
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# ---------------------------------------------------------------- restauration (SA-08, VI-16, ADR-07)

function Resolve-AutosavePoint {
    # « latest », un numéro (série courante) ou un identifiant de commit.
    param([string] $Repo, [string] $Target = 'latest')
    $branch = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
    $head = Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD^{commit}')
    if ($Target -match '^[0-9a-f]{7,40}$' -and $Target -notmatch '^\d{1,3}$') {
        $sha = Get-GitValue $Repo @('rev-parse', '-q', '--verify', "$Target^{commit}")
        if (-not $sha) { throw "Aucun commit ne correspond à « $Target »." }
        return $sha
    }
    if (-not $branch) { throw "Vous n'êtes sur aucune branche : précisez l'identifiant du point de reprise." }
    $series = Get-AutosaveSeries $Repo | Where-Object { $_.Branch -eq $branch -and $_.Base -eq $head }
    if (-not $series) { throw "Aucun point de reprise pour la branche $branch depuis le dernier commit." }
    $points = Get-AutosavePoints $Repo $series
    if ($Target -eq 'latest') { return $points[0].Sha }
    if ($Target -match '^\d{1,3}$') {
        $pt = $points | Where-Object { $_.Number -eq [int]$Target }
        if (-not $pt) { throw "Le point de reprise n° $Target n'existe pas (1 à $($series.Count))." }
        return $pt.Sha
    }
    throw "Point de reprise « $Target » non reconnu : utilisez un numéro, un identifiant ou rien."
}

function Restore-GTCommitFiles {
    <#
      Remet les fichiers dans l'état de $Sha, sans changer la branche ni l'index.
      Un point de reprise de l'état courant est pris avant (filet de sécurité).
    #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Sha)
    $safety = $null
    try {
        $r = Invoke-AutosaveProject -Repo $Repo
        if ($r.Result -eq 'Saved') { $safety = $r.Point }
    } catch {
        Write-GTLog autosave WARN $Repo "Filet de sécurité impossible avant restauration : $($_.Exception.Message)"
    }
    [void](Invoke-Git $Repo @('restore', "--source=$Sha", '--worktree', '--', ':/'))
    Write-GTLog autosave INFO $Repo "Fichiers restaurés depuis $($Sha.Substring(0,7))."
    return [pscustomobject]@{ Restored = $Sha; Safety = $safety }
}

# ---------------------------------------------------------------- hook post-commit (ADR-06, RG-09)

function Get-AutosaveHookPath {
    param([string] $Repo)
    $dir = Get-GitValue $Repo @('rev-parse', '--git-path', 'hooks')
    if (-not $dir) { return $null }
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $Repo $dir }
    return (Join-Path (ConvertTo-GTNativePath $dir) 'post-commit')
}

function Install-AutosaveHook {
    # Renvoie : installed | updated | existing (hook tiers laissé intact)
    param([Parameter(Mandatory)] [string] $Repo)
    $hook = Get-AutosaveHookPath $Repo
    if (-not $hook) { return 'existing' }
    $state = 'installed'
    if (Test-Path -LiteralPath $hook) {
        $content = [System.IO.File]::ReadAllText($hook)
        if ($content -notmatch [regex]::Escape($script:HookMarker)) { return 'existing' }
        $state = 'updated'
    }
    $dir = Split-Path -Parent $hook
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entry = (Join-Path $PSScriptRoot 'git-autosave.ps1').Replace('\', '/')
    $text = @"
#!/bin/sh
# $($script:HookMarker) — installé par git-tools, retiré par « git autosave remove ».
# Supprime en arrière-plan les points de reprise devenus obsolètes après ce commit (SA-05).
root="`$(git rev-parse --show-toplevel)"
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File "$entry" cleanup "`$root" </dev/null >/dev/null 2>&1 &
exit 0
"@
    Write-GTText $hook ($text -replace "`r`n", "`n")
    return $state
}

function Uninstall-AutosaveHook {
    param([Parameter(Mandatory)] [string] $Repo)
    $hook = Get-AutosaveHookPath $Repo
    if ($hook -and (Test-Path -LiteralPath $hook)) {
        $content = [System.IO.File]::ReadAllText($hook)
        if ($content -match [regex]::Escape($script:HookMarker)) {
            Remove-Item -LiteralPath $hook -Force
            return $true
        }
    }
    return $false
}

function Test-AutosaveHook {
    param([string] $Repo)
    $hook = Get-AutosaveHookPath $Repo
    if (-not $hook -or -not (Test-Path -LiteralPath $hook)) { return 'absent' }
    if ([System.IO.File]::ReadAllText($hook) -match [regex]::Escape($script:HookMarker)) { return 'git-tools' }
    return 'tiers'
}

# ---------------------------------------------------------------- planification (ADR-05, FC2, SA-11)

function Get-AutosaveTask {
    try { return Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop } catch { return $null }
}

function Register-AutosaveTask {
    param($Config = (Get-GTConfig))
    $ps1 = Join-Path $PSScriptRoot 'git-autosave.ps1'
    $psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$ps1`" run --scheduled"
    if ($Config.launcher -eq 'wscript') {
        $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$vbs`" `"$ps1`""
    } else {
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $psArgs"
    }
    $start = (Get-Date).AddMinutes(1)
    $start = $start.AddSeconds(-$start.Second).AddMilliseconds(-$start.Millisecond)
    $trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes ([int]$Config.intervalMin))
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'git-tools : points de reprise automatiques des projets suivis (git autosave).'
    Register-ScheduledTask -TaskName $script:TaskName -InputObject $task -Force | Out-Null
    [void](Set-GTConfigValue 'scheduleStart' $start.ToUniversalTime().ToString('o'))
}

function Unregister-AutosaveTask {
    if (Get-AutosaveTask) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        return $true
    }
    return $false
}

function Get-AutosaveSchedule {
    # État pour l'aide et le visualiseur (VI-07) : active ; nextRun ; intervalMin.
    $cfg = Get-GTConfig
    $task = Get-AutosaveTask
    $active = $false
    if ($task) { $active = ($task.State -ne 'Disabled') }
    $next = $null
    if ($active) { $next = Get-GTNextRun $cfg }
    return [pscustomobject]@{ Active = $active; NextRun = $next; IntervalMin = [int]$cfg.intervalMin }
}

Export-ModuleMember -Function *-Autosave*, Restore-GTCommitFiles
