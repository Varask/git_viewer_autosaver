# git-tools — logique du visualiseur (lots L5 et L7)
# Lecture de l'état (VI-01 à VI-08), actions (VI-10 à VI-22), routage HTTP et sécurité (ADR-08).
# Aucune dépendance réseau : Invoke-ViewerRequest est testable sans serveur.
# Ce fichier doit rester en UTF-8 avec BOM.

Set-StrictMode -Version 2.0
$script:Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:Root 'common\GitTools.Common.psm1') -DisableNameChecking -Global

# TR-02 : la sauvegarde est facultative.
$script:AutosaveModule = Join-Path $script:Root 'autosave\GitAutosave.psm1'
$script:HasAutosave = Test-Path -LiteralPath $script:AutosaveModule
if ($script:HasAutosave) { Import-Module $script:AutosaveModule -DisableNameChecking -Global }

$script:Www = Join-Path $PSScriptRoot 'www'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:DiffMax = 300KB
$script:AutosaveEmail = 'autosave@git-tools.local'
$script:RS = [string][char]0x1e   # séparateur d'enregistrements (git %x1e)
$script:US = [string][char]0x1f   # séparateur de champs (git %x1f)

class ViewerError : System.Exception {
    [int] $Status
    ViewerError([string] $message, [int] $status) : base($message) { $this.Status = $status }
}

function Throw-Viewer([string] $Message, [int] $Status = 400) { throw [ViewerError]::new($Message, $Status) }

# ---------------------------------------------------------------- validation (RG-29)

function Assert-Sha([string] $Sha) {
    if ($Sha -notmatch '^[0-9a-f]{7,64}$') { Throw-Viewer "Identifiant de commit invalide : « $Sha »." }
}

function Assert-BranchName([string] $Repo, [string] $Name) {
    if (-not $Name -or $Name.StartsWith('-')) { Throw-Viewer "Nom de branche invalide : « $Name »." }
    $r = Invoke-Git $Repo @('check-ref-format', '--branch', $Name) -AllowFail
    if ($r.ExitCode -ne 0) { Throw-Viewer "Nom de branche invalide : « $Name » (espaces, ~ ^ : ? * [ \ et .. interdits)." }
}

function Assert-RelPath([string] $Repo, [string] $Path) {
    if (-not $Path -or $Path.Contains([char]0) -or [System.IO.Path]::IsPathRooted($Path) -or
        ($Path -split '[\\/]' -contains '..') -or $Path.StartsWith('-') -or $Path.StartsWith(':')) {
        Throw-Viewer "Chemin de fichier invalide : « $Path »."
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Repo $Path))
    $rootFull = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-Viewer "Le fichier « $Path » est hors du projet."
    }
    return $full
}

function Get-Prop($Obj, [string] $Name, $Default = $null) {
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [hashtable]) { if ($Obj.ContainsKey($Name)) { return $Obj[$Name] } else { return $Default } }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

# ---------------------------------------------------------------- état (VI-03, VI-04, VI-07, VI-08)

function Get-ViewerStatusEntries {
    param([string] $Raw)
    $parts = $Raw.Split([char]0)
    $list = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $parts.Count) {
        $e = $parts[$i]; $i++
        if ($e.Length -lt 4) { continue }
        $x = $e.Substring(0, 1); $y = $e.Substring(1, 1); $path = $e.Substring(3)
        $orig = $null
        if ($x -eq 'R' -or $x -eq 'C') { $orig = $parts[$i]; $i++ }
        [void]$list.Add([ordered]@{
            path      = $path
            orig      = $orig
            x         = $x
            y         = $y
            staged    = ($x -ne ' ' -and $x -ne '?')
            unstaged  = ($y -ne ' ')
            untracked = ($x -eq '?')
            conflict  = ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D'))
        })
    }
    return , $list.ToArray()
}

function Get-ViewerFingerprint {
    param([string] $Repo, [string] $Head, [string] $StatusRaw, $Entries)
    $refs = (Invoke-Git $Repo @('for-each-ref', '--format=%(refname) %(objectname)') -AllowFail).Out
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Head).Append('|').Append($refs).Append('|').Append($StatusRaw)
    foreach ($e in $Entries) {
        # Un fichier déjà modifié qui change encore ne change pas le statut : on ajoute taille et date (VI-06).
        $f = Join-Path $Repo $e.path
        try {
            $fi = New-Object System.IO.FileInfo($f)
            if ($fi.Exists) { [void]$sb.Append("|$($e.path):$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)") }
        } catch { }
    }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash($script:Utf8.GetBytes($sb.ToString()))
    return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
}

function Get-ViewerAutosaveInfo {
    param([string] $Repo, [string] $Branch, [string] $Head)
    if (-not $script:HasAutosave) {
        return [ordered]@{ installed = $false; tracked = $false; active = $false; nextRun = $null; intervalMin = $null; points = 0 }
    }
    $sched = Get-AutosaveSchedule
    $tracked = Test-GTProjectTracked $Repo
    $points = 0
    if ($Branch -and $Head) {
        $tip = Get-GitValue $Repo @('rev-parse', '-q', '--verify', "refs/autosave/$Branch/$Head")
        if ($tip) { $c = Get-GitValue $Repo @('rev-list', '--count', "$Head..$tip"); if ($c) { $points = [int]$c } }
    }
    $next = $null
    if ($sched.Active -and $sched.NextRun) { $next = $sched.NextRun.ToUniversalTime().ToString('o') }
    return [ordered]@{
        installed   = $true
        tracked     = $tracked
        active      = [bool]$sched.Active
        nextRun     = $next
        intervalMin = $sched.IntervalMin
        points      = $points
    }
}

function Get-ViewerState {
    param([Parameter(Mandatory)] [string] $Repo)
    $branch = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
    $head = Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD^{commit}')
    $upstream = $null; $ahead = 0; $behind = 0
    if ($branch -and $head) {
        $upstream = Get-GitValue $Repo @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
        if ($upstream) {
            $lr = Get-GitValue $Repo @('rev-list', '--left-right', '--count', 'HEAD...@{u}')
            if ($lr) { $n = $lr -split '\s+'; $ahead = [int]$n[0]; $behind = [int]$n[1] }
        }
    }
    $statusRaw = (Invoke-Git $Repo @('status', '--porcelain=v1', '-z', '--untracked-files=all')).Out
    $entries = Get-ViewerStatusEntries $statusRaw
    $stash = @((Invoke-Git $Repo @('stash', 'list', '--format=%H') -AllowFail).Lines).Count
    $gitDir = Get-GitValue $Repo @('rev-parse', '--absolute-git-dir')
    $busy = $null
    if ($gitDir -and $script:HasAutosave) { $busy = Get-AutosaveBusyReason (ConvertTo-GTNativePath $gitDir) }
    $remotes = @((Invoke-Git $Repo @('remote') -AllowFail).Lines)
    return [ordered]@{
        project     = $Repo
        name        = Split-Path -Leaf $Repo
        branch      = $branch
        head        = $head
        detached    = (-not $branch -and [bool]$head)
        empty       = (-not $head)
        upstream    = $upstream
        ahead       = $ahead
        behind      = $behind
        hasRemote   = ($remotes.Count -gt 0)
        changes     = $entries
        stashCount  = $stash
        busy        = $busy
        autosave    = Get-ViewerAutosaveInfo $Repo $branch $head
        fingerprint = Get-ViewerFingerprint $Repo $head $statusRaw $entries
        serverTime  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------- graphe (VI-01, VI-02, ADR-11)

function Get-ViewerMainRef {
    param([string] $Repo, [string] $Branch)
    $o = Get-GitValue $Repo @('symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
    $candidates = @()
    if ($o) { $candidates += ('refs/heads/' + ($o -replace '^refs/remotes/origin/', '')); $candidates += $o }
    $candidates += @('refs/heads/main', 'refs/heads/master', 'refs/heads/develop')
    if ($Branch) { $candidates += "refs/heads/$Branch" }
    foreach ($c in $candidates) {
        $sha = Get-GitValue $Repo @('rev-parse', '-q', '--verify', "$c^{commit}")
        if ($sha) { return [ordered]@{ ref = $c; sha = $sha } }
    }
    return $null
}

function Get-ViewerGraph {
    param([Parameter(Mandatory)] [string] $Repo, [int] $Limit = 400, [bool] $Autosave = $true)
    if ($Limit -lt 50) { $Limit = 50 }
    if ($Limit -gt 5000) { $Limit = 5000 }
    $branch = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
    if (-not (Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD^{commit}')) -and
        -not (Invoke-Git $Repo @('for-each-ref', '--count=1', 'refs/heads/') -AllowFail).Out) {
        return [ordered]@{ commits = @(); main = $null; limit = $Limit; truncated = $false }
    }
    $gargs = @('log', '--date-order', '-n', ($Limit + 1), '--decorate=full',
        '--decorate-refs=refs/heads/', '--decorate-refs=refs/remotes/', '--decorate-refs=refs/tags/',
        '--format=%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%ce%x1f%s%x1e',
        '--exclude=refs/stash', '--exclude=refs/remotes/*/HEAD')
    if ($Autosave) { $gargs += '--decorate-refs=refs/autosave/' } else { $gargs += '--exclude=refs/autosave/*' }
    $gargs += @('--all', 'HEAD')
    $r = Invoke-Git $Repo $gargs
    $commits = New-Object System.Collections.ArrayList
    foreach ($rec in ($r.Out.Split($script:RS))) {
        $rec = $rec.Trim("`r", "`n")
        if (-not $rec) { continue }
        $f = $rec.Split($script:US)
        if ($f.Count -lt 7) { continue }
        $refs = @()
        foreach ($d in ($f[2] -split ', ')) {
            if (-not $d) { continue }
            $d = $d -replace '^tag: ', ''
            $type = switch -Wildcard ($d) {
                'refs/heads/*'    { 'head' }
                'refs/remotes/*'  { 'remote' }
                'refs/tags/*'     { 'tag' }
                'refs/autosave/*' { 'autosave' }
                default           { 'other' }
            }
            $name = $d -replace '^refs/(heads|remotes|tags)/', ''
            if ($type -eq 'autosave') { $name = ($d -replace '^refs/autosave/', '') -replace '/[0-9a-f]{40,64}$', '' }
            $refs += [ordered]@{ name = $name; type = $type; full = $d }
        }
        [void]$commits.Add([ordered]@{
            h    = $f[0]
            p    = @($f[1] -split ' ' | Where-Object { $_ })
            refs = $refs
            an   = $f[3]
            at   = [long]$f[4]
            auto = ($f[5] -eq $script:AutosaveEmail)
            s    = $f[6]
        })
    }
    $truncated = $commits.Count -gt $Limit
    if ($truncated) { $commits.RemoveAt($commits.Count - 1) }
    return [ordered]@{
        commits   = $commits.ToArray()
        main      = Get-ViewerMainRef $Repo $branch
        limit     = $Limit
        truncated = $truncated
    }
}

# ---------------------------------------------------------------- détail et différences (VI-05, VI-06)

function Get-ViewerCommit {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Sha)
    Assert-Sha $Sha
    $r = Invoke-Git $Repo @('show', '-s', '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%B', $Sha) -AllowFail
    if ($r.ExitCode -ne 0) { Throw-Viewer "Commit introuvable : $Sha" 404 }
    $f = $r.Out.Split([char[]]$script:US, 8)
    $parents = @($f[1] -split ' ' | Where-Object { $_ })
    $diffArgs = if ($parents.Count) { @('diff-tree', '-r', '-M', '--name-status', '-z', $parents[0], $f[0]) }
                else { @('diff-tree', '-r', '--root', '--name-status', '-z', $f[0]) }
    $d = (Invoke-Git $Repo $diffArgs).Out -split "`0"
    $files = @()
    $i = 0
    if (-not $parents.Count -and $d.Count -and $d[0] -match '^[0-9a-f]{40}') { $i = 1 }
    while ($i -lt $d.Count) {
        $st = $d[$i]; $i++
        if (-not $st) { continue }
        $code = $st.Substring(0, 1)
        if ($code -eq 'R' -or $code -eq 'C') {
            $files += [ordered]@{ status = $code; orig = $d[$i]; path = $d[$i + 1] }; $i += 2
        } else {
            $files += [ordered]@{ status = $code; orig = $null; path = $d[$i] }; $i++
        }
    }
    return [ordered]@{
        sha      = $f[0]
        parents  = $parents
        author   = $f[2]
        email    = $f[3]
        date     = [long]$f[4]
        auto     = ($f[6] -eq $script:AutosaveEmail)
        message  = $f[7].TrimEnd()
        files    = $files
    }
}

function Limit-ViewerText([string] $Text) {
    if ($Text.Length -gt $script:DiffMax) {
        return [ordered]@{ text = $Text.Substring(0, $script:DiffMax); truncated = $true }
    }
    return [ordered]@{ text = $Text; truncated = $false }
}

function Get-ViewerDiff {
    param([Parameter(Mandatory)] [string] $Repo, [string] $Path, [string] $Mode = 'worktree', [string] $Sha = '')
    $full = Assert-RelPath $Repo $Path
    $kind = 'diff'
    if ($Mode -eq 'commit') {
        Assert-Sha $Sha
        $parents = @((Get-GitValue $Repo @('show', '-s', '--format=%P', $Sha)) -split ' ' | Where-Object { $_ })
        if ($parents.Count) { $out = (Invoke-Git $Repo @('diff', '-M', $parents[0], $Sha, '--', $Path)).Out }
        else { $out = (Invoke-Git $Repo @('show', '--format=', $Sha, '--', $Path)).Out }
    } elseif ($Mode -eq 'staged') {
        $out = (Invoke-Git $Repo @('diff', '--cached', '-M', '--', $Path)).Out
    } else {
        $tracked = Get-GitValue $Repo @('ls-files', '--', $Path)
        if (-not $tracked) {
            # Nouveau fichier : afficher son contenu.
            $kind = 'new'
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $out = '' }
            else {
                $fs = [System.IO.File]::OpenRead($full)
                try {
                    $len = [int][math]::Min($fs.Length, $script:DiffMax + 1)
                    $buf = New-Object byte[] $len
                    [void]$fs.Read($buf, 0, $len)
                } finally { $fs.Dispose() }
                if ([Array]::IndexOf($buf, [byte]0) -ge 0) { $kind = 'binary'; $out = '' }
                else { $out = $script:Utf8.GetString($buf) }
            }
        } else {
            $out = (Invoke-Git $Repo @('diff', '--', $Path)).Out
        }
    }
    if ($kind -eq 'diff' -and $out -match '(?m)^Binary files ') { $kind = 'binary' }
    $res = Limit-ViewerText $out
    $res['kind'] = $kind
    $res['path'] = $Path
    $res['mode'] = $Mode
    return $res
}

# ---------------------------------------------------------------- projets (VI-32, VI-33, VI-34, RG-26, RG-28)

function Get-ViewerProjects {
    param([string] $Current)
    $tracked = @(Get-GTProjects)
    $recent = @(Get-GTList 'recent')
    $items = @()
    $seen = @{}
    foreach ($p in ($recent + $tracked)) {
        $key = (ConvertTo-GTNativePath $p).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $isTracked = $false
        foreach ($t in $tracked) { if (Test-GTSamePath $t $p) { $isTracked = $true } }
        $items += [ordered]@{
            path    = $p
            name    = Split-Path -Leaf $p
            exists  = (Test-Path -LiteralPath $p)
            tracked = $isTracked
            recent  = [bool](@($recent | Where-Object { Test-GTSamePath $_ $p }).Count)
        }
    }
    return [ordered]@{ current = $Current; items = $items; autosaveInstalled = $script:HasAutosave }
}

function Resolve-ViewerProject {
    # Valide un dossier ; renvoie la racine du projet ou lève une erreur (RG-28).
    param([string] $Path)
    if (-not $Path) { Throw-Viewer 'Indiquez le chemin d''un dossier.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Throw-Viewer "Dossier introuvable : $Path" }
    $root = Get-GTRepoRoot $Path
    if (-not $root) { Throw-Viewer "« $Path » n'est pas un projet git. Le projet affiché reste inchangé." }
    return $root
}

function Register-ViewerProject {
    # Ajoute aux récents et inscrit à la sauvegarde si autorisé (VI-34, RG-26).
    param([string] $Root)
    Add-GTRecent $Root
    $tracked = $false
    if ($script:HasAutosave) {
        $cfg = Get-GTConfig
        $excluded = @($cfg.autoTrackExclude | Where-Object { Test-GTSamePath $_ $Root }).Count -gt 0
        if ($cfg.autoTrack -and -not $excluded -and -not (Test-GTProjectTracked $Root)) {
            [void](Add-GTProject $Root)
            try { [void](Install-AutosaveHook $Root) } catch { }
            Write-GTLog viewer INFO $Root 'Projet inscrit à la sauvegarde automatique.'
            $tracked = $true
        }
    }
    return $tracked
}

function Get-ViewerLastProject {
    foreach ($p in Get-GTList 'recent') {
        if (Test-Path -LiteralPath $p) { $root = Get-GTRepoRoot $p; if ($root) { return $root } }
    }
    return $null
}

# ---------------------------------------------------------------- actions (VI-10 à VI-22, RG-20 à RG-24)

function New-ActionResult([bool] $Ok, [string] $Message, [hashtable] $Extra = @{}) {
    $r = [ordered]@{ ok = $Ok; message = $Message }
    foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
    return $r
}

function Get-GitError([object] $Res) {
    $t = if ($Res.Err) { $Res.Err } else { $Res.Out }
    $t = ($t -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^hint:' }) -join ' '
    return $t.Trim()
}

function Invoke-GitAction {
    param([string] $Repo, [string[]] $Arguments, [string] $Success, [int] $TimeoutSec = 120)
    $r = Invoke-Git $Repo $Arguments -TimeoutSec $TimeoutSec -AllowFail
    if ($r.ExitCode -eq 0) { return New-ActionResult $true $Success }
    return New-ActionResult $false ("Échec : " + (Get-GitError $r))
}

function Get-ActionPaths($Data, [string] $Repo) {
    $paths = @(Get-Prop $Data 'paths' @())
    if (-not $paths.Count) { $p = Get-Prop $Data 'path'; if ($p) { $paths = @($p) } }
    if (-not $paths.Count) { Throw-Viewer 'Aucun fichier indiqué.' }
    foreach ($p in $paths) { [void](Assert-RelPath $Repo ([string]$p)) }
    return [string[]]$paths
}

function Invoke-ViewerAction {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Name, $Data)
    $hasHead = [bool](Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD^{commit}'))
    switch ($Name) {

        'stage' {
            $paths = Get-ActionPaths $Data $Repo
            return Invoke-GitAction $Repo (@('add', '-A', '--') + $paths) 'Fichier(s) indexé(s).'
        }
        'stageAll' { return Invoke-GitAction $Repo @('add', '-A') 'Toutes les modifications sont indexées.' }
        'unstage' {
            $paths = Get-ActionPaths $Data $Repo
            if ($hasHead) { return Invoke-GitAction $Repo (@('restore', '--staged', '--') + $paths) 'Fichier(s) désindexé(s).' }
            return Invoke-GitAction $Repo (@('rm', '--cached', '-r', '-q', '--') + $paths) 'Fichier(s) désindexé(s).'
        }
        'unstageAll' {
            if ($hasHead) { return Invoke-GitAction $Repo @('restore', '--staged', '--', ':/') 'Index vidé.' }
            return Invoke-GitAction $Repo @('rm', '--cached', '-r', '-q', '--', ':/') 'Index vidé.'
        }

        'discard' {
            # VI-11 : revenir à la dernière version connue, ou supprimer un nouveau fichier.
            $path = [string](Get-Prop $Data 'path')
            $full = Assert-RelPath $Repo $path
            $inHead = $hasHead -and [bool](Get-GitValue $Repo @('ls-tree', '--name-only', 'HEAD', '--', $path))
            if ($inHead) {
                return Invoke-GitAction $Repo @('restore', '--source=HEAD', '--staged', '--worktree', '--', $path) "Modifications annulées : $path"
            }
            $inIndex = [bool](Get-GitValue $Repo @('ls-files', '--', $path))
            if ($inIndex) { [void](Invoke-Git $Repo @('rm', '--cached', '-q', '--', $path) -AllowFail) }
            if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
            return New-ActionResult $true "Nouveau fichier supprimé : $path"
        }

        'commit' {
            # VI-12, RG-23, RG-24
            $message = [string](Get-Prop $Data 'message' '')
            $all = [bool](Get-Prop $Data 'all' $false)
            $amend = [bool](Get-Prop $Data 'amend' $false)
            if ($amend -and -not $hasHead) { Throw-Viewer 'Aucun commit à modifier.' }
            if (-not $message.Trim() -and -not $amend) { Throw-Viewer 'Le message du commit est obligatoire.' }
            if ($all) {
                $a = Invoke-Git $Repo @('add', '-A') -AllowFail
                if ($a.ExitCode -ne 0) { return New-ActionResult $false ("Échec de l'indexation : " + (Get-GitError $a)) }
            } elseif (-not $amend) {
                $staged = Invoke-Git $Repo @('diff', '--cached', '--quiet') -AllowFail
                if ($hasHead -and $staged.ExitCode -eq 0) { Throw-Viewer 'Aucun fichier indexé : indexez des fichiers ou choisissez « tout committer ».' }
                if (-not $hasHead -and -not (Get-GitValue $Repo @('ls-files'))) { Throw-Viewer 'Aucun fichier indexé.' }
            }
            $gargs = @('commit')
            if ($amend) { $gargs += '--amend' }
            $tmp = $null
            if ($message.Trim()) {
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("git-tools-msg-" + [guid]::NewGuid().ToString('N'))
                Write-GTText $tmp $message
                $gargs += @('-F', $tmp, '--cleanup=strip')
            } else {
                $gargs += '--no-edit'
            }
            if ($amend -and $all -eq $false) { $gargs += '--allow-empty' }
            try {
                $res = Invoke-GitAction $Repo $gargs $(if ($amend) { 'Dernier commit modifié.' } else { 'Commit créé.' }) 300
            } finally {
                if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
            return $res
        }

        'undoCommit' {
            # VI-13 : modifications conservées et indexées.
            if (-not $hasHead) { Throw-Viewer 'Aucun commit à annuler.' }
            if (-not (Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'HEAD~1'))) {
                Throw-Viewer 'Le premier commit du projet ne peut pas être annulé ici.'
            }
            return Invoke-GitAction $Repo @('reset', '--soft', 'HEAD~1') 'Dernier commit annulé : ses modifications sont indexées.'
        }

        'stash' {
            $r = Invoke-Git $Repo @('stash', 'push', '-u', '-m', ('git-tools ' + (Get-Date).ToString('dd/MM/yyyy HH:mm'))) -AllowFail
            if ($r.ExitCode -ne 0) { return New-ActionResult $false ("Échec : " + (Get-GitError $r)) }
            if ($r.Out -match 'No local changes') { return New-ActionResult $false 'Rien à mettre de côté.' }
            return New-ActionResult $true 'Modifications mises de côté.'
        }
        'stashPop' {
            if (-not (Get-GitValue $Repo @('rev-parse', '-q', '--verify', 'refs/stash'))) { Throw-Viewer 'Rien n''a été mis de côté.' }
            return Invoke-GitAction $Repo @('stash', 'pop') 'Modifications réappliquées.'
        }

        'switch' {
            $b = [string](Get-Prop $Data 'branch')
            Assert-BranchName $Repo $b
            return Invoke-GitAction $Repo @('switch', $b) "Branche courante : $b"
        }
        'createBranch' {
            $b = [string](Get-Prop $Data 'branch')
            Assert-BranchName $Repo $b
            if (Get-GitValue $Repo @('rev-parse', '-q', '--verify', "refs/heads/$b")) { Throw-Viewer "La branche $b existe déjà." }
            return Invoke-GitAction $Repo @('switch', '-c', $b) "Branche $b créée."
        }
        'merge' {
            $b = [string](Get-Prop $Data 'branch')
            Assert-BranchName $Repo $b
            $r = Invoke-Git $Repo @('merge', '--no-edit', $b) -TimeoutSec 300 -AllowFail
            if ($r.ExitCode -eq 0) { return New-ActionResult $true "Branche $b fusionnée." }
            $gitDir = ConvertTo-GTNativePath (Get-GitValue $Repo @('rev-parse', '--absolute-git-dir'))
            if (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) {
                [void](Invoke-Git $Repo @('merge', '--abort') -AllowFail)
                return New-ActionResult $false "Conflit avec $b : la fusion a été annulée, rien n'a changé. Résolvez-la en ligne de commande."
            }
            return New-ActionResult $false ("Échec : " + (Get-GitError $r))
        }
        'deleteBranch' {
            # RG-21 : seconde confirmation pour une branche non fusionnée.
            $b = [string](Get-Prop $Data 'branch')
            Assert-BranchName $Repo $b
            $current = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
            if ($b -eq $current) { Throw-Viewer 'Impossible de supprimer la branche courante.' }
            $force = [bool](Get-Prop $Data 'force' $false)
            $r = Invoke-Git $Repo @('branch', $(if ($force) { '-D' } else { '-d' }), $b) -AllowFail
            if ($r.ExitCode -eq 0) { return New-ActionResult $true "Branche $b supprimée." }
            if ($r.Err -match 'not fully merged') {
                return New-ActionResult $false "La branche $b n'est pas fusionnée : ses commits seront perdus." @{ needsForce = $true }
            }
            return New-ActionResult $false ("Échec : " + (Get-GitError $r))
        }

        'restoreCommit' {
            # VI-16 / SA-08
            $sha = [string](Get-Prop $Data 'sha')
            Assert-Sha $sha
            if ($script:HasAutosave) {
                $r = Restore-GTCommitFiles $Repo $sha
                $msg = 'Fichiers restaurés.'
                if ($r.Safety) { $msg += " L'état précédent est conservé dans le point $($r.Safety.Substring(0,8))." }
                return New-ActionResult $true $msg
            }
            return Invoke-GitAction $Repo @('restore', "--source=$sha", '--worktree', '--', ':/') 'Fichiers restaurés.'
        }
        'checkoutCommit' {
            # VI-17 : aucune branche modifiée.
            $sha = [string](Get-Prop $Data 'sha')
            Assert-Sha $sha
            return Invoke-GitAction $Repo @('switch', '--detach', $sha) "Positionné sur $($sha.Substring(0,8)) (hors branche)."
        }

        'fetch' { return Invoke-GitAction $Repo @('fetch', '--all', '--prune') 'État du distant récupéré.' 300 }
        'pull' {
            # RG-22 : jamais de fusion implicite.
            $r = Invoke-Git $Repo @('pull', '--ff-only') -TimeoutSec 300 -AllowFail
            if ($r.ExitCode -eq 0) { return New-ActionResult $true 'Commits distants récupérés.' }
            $e = Get-GitError $r
            if ($e -match 'Not possible to fast-forward|diverg|non-fast-forward') {
                return New-ActionResult $false 'Tirage refusé : votre branche et le distant ont divergé. Aucune fusion n''a été faite.'
            }
            return New-ActionResult $false ("Échec : $e")
        }
        'push' {
            $branch = Get-GitValue $Repo @('symbolic-ref', '-q', '--short', 'HEAD')
            if (-not $branch) { Throw-Viewer 'Hors branche : rien à pousser.' }
            $up = Get-GitValue $Repo @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if ($up) { $gargs = @('push') }
            else {
                $remotes = @((Invoke-Git $Repo @('remote') -AllowFail).Lines)
                if (-not $remotes.Count) { Throw-Viewer 'Aucun dépôt distant configuré.' }
                $remote = if ($remotes -contains 'origin') { 'origin' } else { $remotes[0] }
                $gargs = @('push', '-u', $remote, $branch)
            }
            $r = Invoke-Git $Repo $gargs -TimeoutSec 300 -AllowFail
            if ($r.ExitCode -eq 0) { return New-ActionResult $true 'Commits envoyés.' }
            $e = Get-GitError $r
            if ($e -match 'Authentication|could not read Username|terminal prompts disabled|Permission denied') {
                return New-ActionResult $false "Échec : identifiants manquants ou refusés pour le distant. Configurez-les en ligne de commande (git push) puis réessayez. Détail : $e"
            }
            if ($e -match 'rejected|fetch first|non-fast-forward') {
                return New-ActionResult $false 'Envoi refusé : le distant contient des commits que vous n''avez pas. Récupérez-les d''abord (Tirer).'
            }
            return New-ActionResult $false ("Échec : $e")
        }

        'autosaveNow' {
            if (-not $script:HasAutosave) { Throw-Viewer 'La sauvegarde automatique n''est pas installée.' }
            $r = Invoke-AutosaveProject -Repo $Repo
            $msg = switch ($r.Result) {
                'Saved' { "$($r.Message) créé." }
                'Unchanged' { 'Rien de nouveau à sauvegarder.' }
                default { "Sauvegarde ignorée : $($r.Message)." }
            }
            return New-ActionResult ($r.Result -ne 'Error') $msg
        }
        'track' {
            if (-not $script:HasAutosave) { Throw-Viewer 'La sauvegarde automatique n''est pas installée.' }
            [void](Add-GTProject $Repo); [void](Install-AutosaveHook $Repo)
            $cfg = Get-GTConfig
            $excl = @($cfg.autoTrackExclude | Where-Object { -not (Test-GTSamePath $_ $Repo) })
            [void](Set-GTConfigValue 'autoTrackExclude' $excl)
            return New-ActionResult $true 'Projet suivi par la sauvegarde automatique.'
        }
        'untrack' {
            if (-not $script:HasAutosave) { Throw-Viewer 'La sauvegarde automatique n''est pas installée.' }
            [void](Remove-GTProject $Repo); [void](Uninstall-AutosaveHook $Repo)
            if ([bool](Get-Prop $Data 'exclude' $false)) {
                $cfg = Get-GTConfig
                [void](Set-GTConfigValue 'autoTrackExclude' (@($cfg.autoTrackExclude) + $Repo))
            }
            return New-ActionResult $true 'Projet retiré de la sauvegarde. Ses points de reprise sont conservés.'
        }

        default { Throw-Viewer "Action inconnue : $Name" 404 }
    }
}

# ---------------------------------------------------------------- HTTP : routage et sécurité (ADR-08)

function New-ViewerResponse([int] $Status, [string] $ContentType, $Body) {
    if ($Body -is [string]) { $Body = $script:Utf8.GetBytes($Body) }
    return [ordered]@{ status = $Status; type = $ContentType; body = [byte[]]$Body; headers = @{} }
}

function New-JsonResponse([int] $Status, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress
    return New-ViewerResponse $Status 'application/json; charset=utf-8' $json
}

function Test-ViewerHost([hashtable] $Headers, [int] $Port) {
    $h = [string]$Headers['host']
    return ($h -eq "127.0.0.1:$Port" -or $h -eq "localhost:$Port")
}

function Test-ViewerApiAccess([hashtable] $Headers, $Shared) {
    # Jeton obligatoire, requêtes inter-sites refusées (ENF-07).
    $port = [int]$Shared.port
    if ([string]$Headers['x-gittools-token'] -ne [string]$Shared.token) { return $false }
    $site = [string]$Headers['sec-fetch-site']
    if ($site -and $site -notin @('same-origin', 'none')) { return $false }
    $origin = [string]$Headers['origin']
    if ($origin -and $origin -notin @("http://127.0.0.1:$port", "http://localhost:$port")) { return $false }
    return $true
}

function Get-ViewerStatic([string] $Path, $Shared) {
    $map = @{
        '/'            = @('index.html', 'text/html; charset=utf-8')
        '/index.html'  = @('index.html', 'text/html; charset=utf-8')
        '/app.js'      = @('app.js', 'text/javascript; charset=utf-8')
        '/graph.js'    = @('graph.js', 'text/javascript; charset=utf-8')
        '/styles.css'  = @('styles.css', 'text/css; charset=utf-8')
        '/favicon.svg' = @('favicon.svg', 'image/svg+xml')
    }
    if (-not $map.ContainsKey($Path)) { return $null }
    $file = Join-Path $script:Www $map[$Path][0]
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $text = [System.IO.File]::ReadAllText($file, $script:Utf8)
    if ($map[$Path][0] -eq 'index.html') { $text = $text.Replace('__GITTOOLS_TOKEN__', [string]$Shared.token) }
    return New-ViewerResponse 200 $map[$Path][1] $text
}

function ConvertFrom-Query([string] $Query) {
    $q = @{}
    if (-not $Query) { return $q }
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $k = [System.Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
        $q[$k] = $v
    }
    return $q
}

function Get-ViewerCurrentProject($Shared) {
    $p = [string]$Shared.project
    if (-not $p) { Throw-Viewer 'Aucun projet ouvert. Choisissez un projet.' 409 }
    if (-not (Test-Path -LiteralPath $p)) { Throw-Viewer "Le projet $p n'existe plus. Choisissez-en un autre." 409 }
    return $p
}

function Set-ViewerProject([string] $Root, $Shared) {
    $changed = -not (Test-GTSamePath $Root ([string]$Shared.project))
    $Shared.project = $Root
    if ($changed) { $Shared.projectSeq = [int]$Shared.projectSeq + 1 }
    $tracked = Register-ViewerProject $Root
    Write-GTLog viewer INFO $Root 'Projet ouvert.'
    return $tracked
}

function Test-ViewerPageAlive($Shared) {
    if ([int]$Shared.presence -gt 0) { return $true }
    return (([datetime]::UtcNow - [datetime]$Shared.lastSeen).TotalSeconds -lt 7)
}

function Open-ViewerTabIfNeeded($Shared, [switch] $Force) {
    # RG-27 / VI-31 : un onglet seulement si aucune page n'est affichée.
    if (-not $Force -and (Test-ViewerPageAlive $Shared)) { return $false }
    if (([datetime]::UtcNow - [datetime]$Shared.lastTabOpen).TotalSeconds -lt 10) { return $false }
    $Shared.lastTabOpen = [datetime]::UtcNow
    if ($Shared.ContainsKey('noBrowser') -and $Shared.noBrowser) { return $true }
    try { Start-Process "http://127.0.0.1:$($Shared.port)/" | Out-Null } catch {
        Write-GTLog viewer WARN '' "Navigateur impossible à ouvrir : $($_.Exception.Message)"
    }
    return $true
}

function Invoke-ViewerPickFolder {
    # Sélecteur de dossier (VI-32) dans un processus STA séparé.
    $picker = Join-Path $PSScriptRoot 'pick-folder.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ConvertTo-GTArgString @('-NoProfile', '-NonInteractive', '-STA', '-File', $picker)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $path = $out.Trim()
    if (-not $path) { return $null }
    return $path
}

function Invoke-ViewerRequest {
    <#
      Point d'entrée unique du serveur. $Request : { method; path; query; headers (minuscules); body (string) }.
      $Shared : table synchronisée { token; port; project; projectSeq; lastSeen; lastTabOpen; presence; stop }.
    #>
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $Shared)
    $h = $Request.headers
    try {
        if (-not (Test-ViewerHost $h ([int]$Shared.port))) { return New-ViewerResponse 403 'text/plain; charset=utf-8' 'Hôte refusé.' }
        $path = $Request.path
        if (-not $path.StartsWith('/api/')) {
            if ($Request.method -ne 'GET') { return New-ViewerResponse 405 'text/plain; charset=utf-8' 'Méthode refusée.' }
            $static = Get-ViewerStatic $path $Shared
            if ($static) { return $static }
            return New-ViewerResponse 404 'text/plain; charset=utf-8' 'Introuvable.'
        }
        if (-not (Test-ViewerApiAccess $h $Shared)) { return New-JsonResponse 403 @{ ok = $false; message = 'Accès refusé.' } }

        $q = ConvertFrom-Query $Request.query
        $data = $null
        if ($Request.body) {
            try { $data = $Request.body | ConvertFrom-Json } catch { Throw-Viewer 'Requête illisible.' }
        }
        $route = "$($Request.method) $path"
        switch ($route) {
            'GET /api/ping' { return New-JsonResponse 200 @{ ok = $true; pid = $PID; project = $Shared.project } }
            'GET /api/state' {
                $Shared.lastSeen = [datetime]::UtcNow
                $repo = [string]$Shared.project
                $base = [ordered]@{ projectSeq = [int]$Shared.projectSeq }
                if (-not $repo -or -not (Test-Path -LiteralPath $repo)) {
                    $base['project'] = $null
                    return New-JsonResponse 200 $base
                }
                $st = Get-ViewerState $repo
                $st['projectSeq'] = [int]$Shared.projectSeq
                return New-JsonResponse 200 $st
            }
            'GET /api/graph' {
                $repo = Get-ViewerCurrentProject $Shared
                $limit = 0
                if (-not [int]::TryParse([string]$q['limit'], [ref]$limit)) { $limit = [int](Get-GTConfig).graphLimit }
                $auto = ([string]$q['autosave']) -ne '0'
                return New-JsonResponse 200 (Get-ViewerGraph $repo $limit $auto)
            }
            'GET /api/commit' {
                $repo = Get-ViewerCurrentProject $Shared
                return New-JsonResponse 200 (Get-ViewerCommit $repo ([string]$q['sha']))
            }
            'GET /api/diff' {
                $repo = Get-ViewerCurrentProject $Shared
                return New-JsonResponse 200 (Get-ViewerDiff $repo ([string]$q['path']) ([string]$q['mode']) ([string]$q['sha']))
            }
            'GET /api/branches' {
                $repo = Get-ViewerCurrentProject $Shared
                $loc = @((Invoke-Git $repo @('for-each-ref', '--format=%(refname:short)', 'refs/heads/')).Lines)
                $rem = @((Invoke-Git $repo @('for-each-ref', '--format=%(refname:short)', 'refs/remotes/')).Lines |
                        Where-Object { $_ -notmatch '/HEAD$' -and $_ -match '/' })
                return New-JsonResponse 200 @{ local = $loc; remote = $rem }
            }
            'GET /api/projects' { return New-JsonResponse 200 (Get-ViewerProjects ([string]$Shared.project)) }
            'POST /api/open' {
                # VI-32, VI-33, RG-28 ; appelé aussi par un nouveau lancement (VI-31).
                $p = [string](Get-Prop $data 'path' '')
                if ($p) { $root = Resolve-ViewerProject $p }
                elseif ($Shared.project) { $root = [string]$Shared.project }
                else { $root = Get-ViewerLastProject }
                $tracked = $false
                if ($root) { $tracked = Set-ViewerProject $root $Shared }
                $tab = $false
                if ([bool](Get-Prop $data 'launch' $false)) { $tab = Open-ViewerTabIfNeeded $Shared }
                return New-JsonResponse 200 @{ ok = $true; project = $root; tracked = $tracked; tabOpened = $tab; projectSeq = [int]$Shared.projectSeq }
            }
            'POST /api/browse' {
                $picked = Invoke-ViewerPickFolder
                if (-not $picked) { return New-JsonResponse 200 @{ ok = $false; message = 'Aucun dossier choisi.' } }
                $root = Resolve-ViewerProject $picked
                $tracked = Set-ViewerProject $root $Shared
                return New-JsonResponse 200 @{ ok = $true; project = $root; tracked = $tracked; projectSeq = [int]$Shared.projectSeq }
            }
            'POST /api/action' {
                $repo = Get-ViewerCurrentProject $Shared
                $name = [string](Get-Prop $data 'name' '')
                $res = Invoke-ViewerAction $repo $name (Get-Prop $data 'args')
                Write-GTLog viewer $(if ($res.ok) { 'INFO' } else { 'WARN' }) $repo "$name : $($res.message)"
                return New-JsonResponse 200 $res
            }
            'POST /api/shutdown' {
                $Shared.stop = $true
                return New-JsonResponse 200 @{ ok = $true; message = 'Visualiseur arrêté.' }
            }
            default { return New-JsonResponse 404 @{ ok = $false; message = "Route inconnue : $route" } }
        }
    } catch [ViewerError] {
        return New-JsonResponse $_.Exception.Status @{ ok = $false; message = $_.Exception.Message }
    } catch {
        Write-GTLog viewer ERROR ([string]$Shared.project) "$($Request.method) $($Request.path) : $($_.Exception.Message)"
        return New-JsonResponse 500 @{ ok = $false; message = $_.Exception.Message }
    }
}

Export-ModuleMember -Function Invoke-ViewerRequest, Invoke-ViewerAction, Get-Viewer*, Resolve-ViewerProject,
    Set-ViewerProject, Open-ViewerTabIfNeeded, Test-ViewerPageAlive
