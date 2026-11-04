<#
  git-tools — recette automatisée (lot L8). À lancer sur le poste Windows, dans Windows PowerShell 5.1 :

      cd <dossier git-tools>
      .\tests\Run-Tests.ps1                 tests du moteur et de la logique du visualiseur
      .\tests\Run-Tests.ps1 -Integration    + serveur réel, instance unique, hook post-commit (≈ 1 min)

  N'utilise que des dossiers temporaires (données isolées via GITTOOLS_DATA) : aucun effet sur
  l'installation ni sur vos projets. Code de sortie = nombre d'échecs.
  Ce fichier doit rester en UTF-8 avec BOM.
#>
param([switch] $Integration, [switch] $KeepTemp)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Root = Split-Path -Parent $PSScriptRoot
$TmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("git-tools tests é " + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $TmpBase -Force | Out-Null
$env:GITTOOLS_DATA = Join-Path $TmpBase 'données'
$env:GITTOOLS_NOBROWSER = '1'
$env:GITTOOLS_NOTASK = '1'      # un réglage modifié par les tests ne réenregistre jamais la vraie tâche planifiée

Import-Module (Join-Path $Root 'viewer\GitViewer.psm1') -DisableNameChecking -Force
Initialize-GTConsole

$Results = New-Object System.Collections.ArrayList
function Test-Case([string] $Name, [scriptblock] $Body) {
    $t0 = Get-Date
    try {
        & $Body
        [void]$Results.Add([pscustomobject]@{ Ok = $true; Name = $Name; Detail = ''; Ms = [int]((Get-Date) - $t0).TotalMilliseconds })
        Write-Host ("  OK    {0}" -f $Name) -ForegroundColor Green
    } catch {
        $line = $_.InvocationInfo.ScriptLineNumber
        [void]$Results.Add([pscustomobject]@{ Ok = $false; Name = $Name; Detail = "$($_.Exception.Message) (ligne $line)"; Ms = 0 })
        Write-Host ("  ÉCHEC {0}`n        {1} (ligne {2})" -f $Name, $_.Exception.Message, $line) -ForegroundColor Red
    }
}
function Assert-True($Cond, [string] $Msg) { if (-not $Cond) { throw $Msg } }
function Assert-Equal($Actual, $Expected, [string] $Msg) {
    if ($Actual -ne $Expected) { throw "$Msg — attendu « $Expected », obtenu « $Actual »" }
}
function G([string] $Repo, [string[]] $A) { return (Invoke-Git $Repo $A).Out.Trim() }
function Write-File([string] $Repo, [string] $Rel, [string] $Text) {
    $f = Join-Path $Repo $Rel
    $d = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Write-GTText $f $Text
}
$script:RepoN = 0
function New-TestRepo([string] $Name = 'projet été') {
    $script:RepoN++
    $r = Join-Path $TmpBase "$Name $($script:RepoN)"
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    [void](Invoke-Git $r @('init', '-q'))
    [void](Invoke-Git $r @('symbolic-ref', 'HEAD', 'refs/heads/main'))
    [void](Invoke-Git $r @('config', 'user.name', 'Testeur'))
    [void](Invoke-Git $r @('config', 'user.email', 'test@example.com'))
    [void](Invoke-Git $r @('config', 'core.autocrlf', 'false'))
    Write-File $r 'a.txt' "un`n"
    Write-File $r 'docs/données.md' "café`n"
    Write-File $r '.gitignore' "*.log`n"
    [void](Invoke-Git $r @('add', '-A'))
    [void](Invoke-Git $r @('commit', '-q', '-m', 'premier'))
    return $r
}
function Get-Snapshot([string] $Repo) {
    # FC1 : ce qui ne doit jamais changer lors d'un passage.
    $idx = Join-Path $Repo '.git\index'
    [pscustomobject]@{
        Branch = G $Repo @('symbolic-ref', '-q', 'HEAD')
        Head   = G $Repo @('rev-parse', 'HEAD')
        Status = G $Repo @('status', '--porcelain=v1', '--untracked-files=all')
        Staged = G $Repo @('diff', '--cached', '--name-status')
        Index  = (Get-FileHash -LiteralPath $idx -Algorithm SHA256).Hash
        Files  = (Get-ChildItem -LiteralPath $Repo -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
                  ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join ';'
    }
}
function Assert-Unchanged($Before, $After) {
    foreach ($p in 'Branch', 'Head', 'Status', 'Staged', 'Index', 'Files') {
        Assert-Equal $After.$p $Before.$p "FC1 : $p modifié par le produit"
    }
}
function Get-Series([string] $Repo) { @(Get-AutosaveSeries $Repo) }
function Set-Projects([string[]] $P) { Set-GTList 'projects' $P }

Write-Host "git-tools — recette automatisée ($($PSVersionTable.PSVersion), git $((Invoke-Git $TmpBase @('--version')).Out.Trim()))"
Write-Host "Dossier temporaire : $TmpBase"
Write-Host ''
Write-Host 'Sauvegarde automatique' -ForegroundColor Cyan

$cfg = Get-GTConfig

Test-Case 'R-01 / SA-01 / SA-04 : point de reprise complet, sans rien modifier' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "un`ndeux`n"
    Write-File $r 'nouveau é.txt' "nouveau`n"
    Remove-Item -LiteralPath (Join-Path $r 'docs\données.md')
    Write-File $r 'trace.log' "ignoré`n"
    [void](Invoke-Git $r @('add', 'a.txt'))   # un fichier indexé : l'index ne doit pas bouger
    $before = Get-Snapshot $r
    $res = Invoke-AutosaveProject -Repo $r -Config $cfg
    $after = Get-Snapshot $r
    Assert-Equal $res.Result 'Saved' 'résultat du passage'
    Assert-Unchanged $before $after
    $s = Get-Series $r
    Assert-Equal $s.Count 1 'nombre de séries'
    $files = @((Invoke-Git $r @('ls-tree', '-r', '--name-only', $s[0].Tip)).Lines)
    Assert-True ($files -contains 'nouveau é.txt') 'nouveau fichier (accentué) absent du point'
    Assert-True (-not ($files -contains 'docs/données.md')) 'fichier supprimé encore présent'
    Assert-True (-not ($files -contains 'trace.log')) 'RG-07 : fichier ignoré sauvegardé'
    Assert-Equal (G $r @('show', "$($s[0].Tip):a.txt")) "un`ndeux" 'contenu modifié'
    Assert-True ((G $r @('log', '-1', '--format=%s', $s[0].Tip)) -match '^Autosave 01 — \d\d/\d\d/\d{4} \d\d:\d\d$') 'libellé Autosave 01'
}

Test-Case 'R-02 / SA-02 : passage sans modification → aucun point' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "modifié`n"
    [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    $tip = (Get-Series $r)[0].Tip
    $res = Invoke-AutosaveProject -Repo $r -Config $cfg
    Assert-Equal $res.Result 'Unchanged' 'second passage'
    Assert-Equal (Get-Series $r)[0].Tip $tip 'la série a bougé'
    $r2 = New-TestRepo
    Assert-Equal (Invoke-AutosaveProject -Repo $r2 -Config $cfg).Result 'Unchanged' 'projet propre'
    Assert-Equal (Get-Series $r2).Count 0 'série créée sur un projet propre'
}

Test-Case 'R-03 / SA-03 : Autosave 02 à la suite du 01, même série' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "v1`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    $p1 = (Get-Series $r)[0].Tip
    Write-File $r 'a.txt' "v2`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    $s = Get-Series $r
    Assert-Equal $s.Count 1 'une seule série'
    Assert-Equal $s[0].Count 2 'deux points'
    Assert-Equal (G $r @('rev-parse', "$($s[0].Tip)^")) $p1 'parent du 02'
    Assert-True ((G $r @('log', '-1', '--format=%s', $s[0].Tip)) -like 'Autosave 02*') 'numéro 02'
    Assert-Equal $s[0].Base (G $r @('rev-parse', 'HEAD')) 'base = dernier commit manuel'
    Assert-Equal $s[0].Branch 'main' 'branche de la série'
}

Test-Case 'R-04 / SA-05 / RG-02 : commit manuel → série supprimée au nettoyage' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "x`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    [void](Invoke-Git $r @('commit', '-qam', 'manuel'))
    Assert-Equal (Invoke-AutosaveCleanup -Repo $r) 1 'séries supprimées'
    Assert-Equal (Get-Series $r).Count 0 'série restante'
    Assert-True ((Get-Content -LiteralPath (Join-Path (Get-GTLogDir) 'autosave.log') -Raw -Encoding UTF8) -match 'CLEAN') 'SA-12 : suppression non journalisée'
}

Test-Case 'R-05 / SA-06 : conservation activée → série gardée' {
    $r = New-TestRepo
    $keep = Get-GTConfig; $keep.keepSeries = $true
    Write-File $r 'a.txt' "x`n"; [void](Invoke-AutosaveProject -Repo $r -Config $keep)
    [void](Invoke-Git $r @('commit', '-qam', 'manuel'))
    [void](Remove-AutosaveObsolete -Repo $r -Config $keep)
    Assert-Equal (Get-Series $r).Count 1 'série conservée'
}

Test-Case 'R-06 / SA-08 : restaurer un point après avoir cassé un fichier' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "bon contenu`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    $point = (Get-Series $r)[0].Tip
    Write-File $r 'a.txt' "CASSÉ`n"
    $branch = G $r @('symbolic-ref', 'HEAD')
    $res = Restore-GTCommitFiles $r $point
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $r 'a.txt'))) "bon contenu`n" 'contenu restauré'
    Assert-Equal (G $r @('symbolic-ref', 'HEAD')) $branch 'branche changée'
    Assert-True $res.Safety 'filet de sécurité absent'
    Assert-Equal (G $r @('show', "$($res.Safety):a.txt")) 'CASSÉ' "l'état cassé n'a pas été sauvegardé avant restauration"
    Assert-Equal (Resolve-AutosavePoint $r '1') $point 'résolution du point n° 1'
}

Test-Case 'R-08 / RG-04 : fusion en conflit → projet ignoré et journalisé' {
    $r = New-TestRepo
    [void](Invoke-Git $r @('switch', '-q', '-c', 'autre'))
    Write-File $r 'a.txt' "autre`n"; [void](Invoke-Git $r @('commit', '-qam', 'autre'))
    [void](Invoke-Git $r @('switch', '-q', 'main'))
    Write-File $r 'a.txt' "main`n"; [void](Invoke-Git $r @('commit', '-qam', 'main'))
    [void](Invoke-Git $r @('merge', 'autre') -AllowFail)
    $res = Invoke-AutosaveProject -Repo $r -Config $cfg
    Assert-Equal $res.Result 'Skipped' 'résultat'
    Assert-True ($res.Message -match 'fusion') 'raison'
    Assert-True ((Get-Content -LiteralPath (Join-Path (Get-GTLogDir) 'autosave.log') -Raw -Encoding UTF8) -match 'Ignoré : fusion en cours') 'journal'
}

Test-Case 'RG-05 / RG-06 : hors branche et projet vide → aucun point' {
    $r = New-TestRepo
    [void](Invoke-Git $r @('switch', '-q', '--detach', 'HEAD'))
    Write-File $r 'a.txt' "x`n"
    Assert-Equal (Invoke-AutosaveProject -Repo $r -Config $cfg).Result 'Skipped' 'HEAD détaché'
    $e = Join-Path $TmpBase 'vide é'
    New-Item -ItemType Directory -Path $e | Out-Null
    [void](Invoke-Git $e @('init', '-q'))
    Write-File $e 'x.txt' 'x'
    Assert-Equal (Invoke-AutosaveProject -Repo $e -Config $cfg).Result 'Skipped' 'projet sans commit'
}

Test-Case 'RG-08 / ENF-09 / SA-10 : un projet introuvable n''empêche pas les autres' {
    $a = New-TestRepo; $b = New-TestRepo
    Write-File $a 'a.txt' "A`n"; Write-File $b 'a.txt' "B`n"
    Set-Projects @($a, (Join-Path $TmpBase 'disparu'), $b)
    $res = @(Invoke-AutosavePass)
    Assert-Equal $res.Count 3 'projets traités'
    Assert-Equal $res[1].Result 'Skipped' 'projet introuvable'
    Assert-Equal $res[0].Result 'Saved' 'premier projet'
    Assert-Equal $res[2].Result 'Saved' 'troisième projet'
    Assert-True (Test-Path -LiteralPath (Join-Path (Get-GTDataDir) 'state.json')) 'heure du dernier passage'
}

Test-Case 'RG-10 : un passage ne démarre pas pendant un autre' {
    $m = New-Object System.Threading.Mutex($false, 'Local\git-tools-autosave')
    [void]$m.WaitOne()
    try {
        $job = Start-Job -ScriptBlock {
            param($mod, $data)
            $env:GITTOOLS_DATA = $data
            Import-Module $mod -DisableNameChecking
            @(Invoke-AutosavePass -Scheduled).Count
        } -ArgumentList (Join-Path $Root 'autosave\GitAutosave.psm1'), $env:GITTOOLS_DATA
        $n = Receive-Job -Job $job -Wait -AutoRemoveJob
        Assert-Equal $n 0 'le second passage aurait dû être annulé'
    } finally { $m.ReleaseMutex(); $m.Dispose() }
}

Test-Case 'RG-09 / RG-11 : hook tiers intact ; retirer conserve les points' {
    $r = New-TestRepo
    $hook = Get-AutosaveHookPath $r
    Write-GTText $hook "#!/bin/sh`necho tiers`n"
    Assert-Equal (Install-AutosaveHook $r) 'existing' 'hook tiers'
    Assert-Equal ([System.IO.File]::ReadAllText($hook)) "#!/bin/sh`necho tiers`n" 'hook tiers modifié'
    $r2 = New-TestRepo
    Assert-Equal (Install-AutosaveHook $r2) 'installed' 'hook git-tools'
    Write-File $r2 'a.txt' "x`n"; [void](Invoke-AutosaveProject -Repo $r2 -Config $cfg)
    Set-Projects @($r2)
    [void](Remove-GTProject $r2); [void](Uninstall-AutosaveHook $r2)
    Assert-Equal (Test-AutosaveHook $r2) 'absent' 'hook retiré'
    Assert-Equal (Get-Series $r2).Count 1 'points conservés'
}

Test-Case 'Revue 🔴1 : réécrire un fichier de données existant (réglages, projets, récents)' {
    [void](Set-GTConfigValue 'intervalMin' 20)
    [void](Set-GTConfigValue 'intervalMin' 25)
    Assert-Equal (Get-GTConfig).intervalMin 25 'réglage réécrit'
    $a = New-TestRepo 'deux'; $b = New-TestRepo 'deux'
    Set-Projects @()
    [void](Add-GTProject $a); [void](Add-GTProject $b)
    Assert-Equal @(Get-GTProjects).Count 2 'deuxième projet'
    Add-GTRecent $a; Add-GTRecent $b
    Assert-Equal @(Get-GTList 'recent')[0] $b 'récents'
    Assert-Equal @(Get-ChildItem -LiteralPath (Get-GTDataDir) -Filter '*.tmp-*').Count 0 'fichiers temporaires restants'
    [void](Set-GTConfigValue 'intervalMin' 30)
    Set-Projects @()
}

Test-Case 'Revue 🔴2 : restauration refusée si le travail ne peut pas être sauvegardé (HEAD détaché)' {
    $r = New-TestRepo
    Write-File $r 'a.txt' "v1`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    $point = (Get-Series $r)[0].Tip
    [void](Invoke-Git $r @('switch', '-q', '--detach', 'HEAD'))
    Write-File $r 'a.txt' "précieux`n"
    $err = $null
    try { [void](Restore-GTCommitFiles $r $point) } catch { $err = $_.Exception.Message }
    Assert-True ($err -match 'Restauration refusée') "aucune erreur : $err"
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $r 'a.txt'))) "précieux`n" 'travail écrasé'
}

Test-Case 'Revue 🔴4 : git et powershell lancés par chemin complet' {
    Assert-True ([System.IO.Path]::IsPathRooted((Get-GTGitExe))) 'git'
    Assert-True ([System.IO.Path]::IsPathRooted((Get-GTPowerShellExe))) 'powershell'
    $r = New-TestRepo 'piège'
    Write-GTText (Join-Path $r 'git.cmd') "@echo PIEGE"
    Push-Location -LiteralPath $r
    try { Assert-True ((Invoke-Git $r @('--version')).Out -match '^git version') 'un git du dossier courant a été lancé' } finally { Pop-Location }
}

Test-Case 'Revue 🟡1 : série conservée après un reset (branche réécrite, pas avancée)' {
    $r = New-TestRepo
    Write-File $r 'b.txt' "b`n"; [void](Invoke-Git $r @('add', '-A')); [void](Invoke-Git $r @('commit', '-qm', 'deuxième'))
    Write-File $r 'a.txt' "travail`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
    [void](Invoke-Git $r @('reset', '-q', '--hard', 'HEAD~1'))
    [void](Remove-AutosaveObsolete -Repo $r -Config $cfg)
    Assert-Equal (Get-Series $r).Count 1 'série supprimée après reset --hard'
}

Test-Case 'Revue 🟡2 : core.hooksPath → aucun hook écrit' {
    $r = New-TestRepo
    [void](Invoke-Git $r @('config', 'core.hooksPath', '.githooks'))
    Assert-Equal (Install-AutosaveHook $r) 'existing' 'résultat'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $r '.githooks'))) 'hook écrit dans les fichiers du projet'
}

Test-Case 'Revue 🔴3 : le hook n''utilise pas -WindowStyle et lance tout par chemin complet' {
    $r = New-TestRepo
    [void](Install-AutosaveHook $r)
    $h = [System.IO.File]::ReadAllText((Get-AutosaveHookPath $r))
    Assert-True ($h -notmatch 'WindowStyle') 'WindowStyle présent'
    Assert-True ($h -match 'conhost\.exe" --headless "[A-Za-z]:/') 'lanceur sans fenêtre absent'
}

Test-Case 'ENF-10 : journal limité à 1 Mo' {
    $line = 'x' * 1000
    1..1200 | ForEach-Object { Write-GTLog autosave INFO 'test' $line }
    $size = (Get-Item -LiteralPath (Join-Path (Get-GTLogDir) 'autosave.log')).Length
    Assert-True ($size -le 1MB) "journal de $size octets"
}

Test-Case 'R-16 / TR-04 : aide avec l''état, sans commande ou commande inconnue' {
    $ps1 = Join-Path $Root 'autosave\git-autosave.ps1'
    # PowerShell 5.1 : avec « Stop », une ligne d'erreur d'un programme redirigée par 2>&1 interrompt le test.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -File $ps1 2>&1 | Out-String
    Assert-Equal $LASTEXITCODE 0 'code de sortie sans commande'
    Assert-True ($out -match 'ÉTAT' -and $out -match 'Projets suivis') "aide sans état : $out"
    $out2 = & powershell.exe -NoProfile -File $ps1 inconnue 2>&1 | Out-String
    Assert-Equal $LASTEXITCODE 1 'code de sortie commande inconnue'
    Assert-True ($out2 -match 'Commande inconnue') 'message commande inconnue'
    $out3 = & powershell.exe -NoProfile -File $ps1 interval 3 2>&1 | Out-String
    Assert-Equal $LASTEXITCODE 1 'SA-11 : intervalle hors bornes accepté'
}

Test-Case 'L10 / ENF-15 / TR-06 / TR-07 : clic droit et menu Démarrer posés, idempotents, retirés sans toucher au reste' {
    # Clés sous une racine de test jetable : le vrai HKCU\Software\Classes n'est jamais touché.
    $testRoot = 'Software\git-tools-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $classes = "$testRoot\Classes"
    $dir = Join-Path $TmpBase 'Menu Démarrer'
    $ps1 = Join-Path $TmpBase 'dossier à espaces\viewer\git-viewer.ps1'
    $hk = [Microsoft.Win32.Registry]::CurrentUser
    $hk.CreateSubKey("$classes\Directory\shell\autre-outil").Close()
    try {
        Install-GTShellMenu $ps1 'x.ico' -ClassesKey $classes
        Install-GTShellMenu $ps1 'x.ico' -ClassesKey $classes
        foreach ($parent in @('Directory\shell', 'Directory\Background\shell')) {
            $verbs = @($hk.OpenSubKey("$classes\$parent").GetSubKeyNames() | Where-Object { $_ -eq 'git-tools.viewer' })
            Assert-Equal $verbs.Count 1 "entrée unique sous $parent"
            $k = $hk.OpenSubKey("$classes\$parent\git-tools.viewer\command")
            Assert-True ($k) "commande absente sous $parent"
            $v = [string]$k.GetValue(''); $k.Close()
            Assert-True ($v -like '*\conhost.exe" --headless "*powershell.exe" -NoProfile -NonInteractive -File *') "lancement sans fenêtre attendu : $v"
            Assert-True ($v.EndsWith('"' + $ps1 + '" --explorer "%V"')) "commande inattendue : $v"
        }
        Install-GTStartMenu $ps1 'x.ico' -Dir $dir
        Install-GTStartMenu $ps1 'x.ico' -Dir $dir
        Assert-Equal @(Get-ChildItem -LiteralPath $dir).Count 1 'un seul raccourci'
        Assert-True (Uninstall-GTShellMenu -ClassesKey $classes) 'retrait non signalé'
        Assert-True (-not (Uninstall-GTShellMenu -ClassesKey $classes)) 'second retrait : rien ne devait rester'
        Assert-True (-not ($hk.OpenSubKey("$classes\Directory\shell").GetSubKeyNames() -contains 'git-tools.viewer')) 'clé git-tools restante'
        Assert-True ($hk.OpenSubKey("$classes\Directory\shell").GetSubKeyNames() -contains 'autre-outil') 'entrée d''un autre logiciel supprimée'
        Assert-True (Uninstall-GTStartMenu -Dir $dir) 'raccourci non retiré'
        Assert-True (-not (Test-Path -LiteralPath $dir)) 'dossier du menu Démarrer vide laissé en place'
    } finally {
        $hk.DeleteSubKeyTree($testRoot, $false)
    }
}

Write-Host ''
Write-Host 'Visualiseur (logique et sécurité, sans réseau)' -ForegroundColor Cyan

$Shared = [hashtable]::Synchronized(@{ token = 'jeton-test'; port = 4242; project = ''; projectSeq = 1;
    lastSeen = [datetime]::MinValue; lastTabOpen = [datetime]::MinValue; presence = 0; stop = $false; noBrowser = $true })
function Req([string] $Method, [string] $Path, $Body = $null, [hashtable] $Headers = $null) {
    $h = @{ host = '127.0.0.1:4242'; 'x-gittools-token' = 'jeton-test' }
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    $q = ''; $p = $Path
    if ($Path.Contains('?')) { $p = $Path.Substring(0, $Path.IndexOf('?')); $q = $Path.Substring($Path.IndexOf('?') + 1) }
    $b = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Compress -Depth 5 } else { '' }
    $resp = Invoke-ViewerRequest -Request @{ method = $Method; path = $p; query = $q; headers = $h; body = $b } -Shared $Shared
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($resp.body)
    $obj = $null
    if ($resp.type -like 'application/json*') { $obj = $text | ConvertFrom-Json }
    return [pscustomobject]@{ Status = $resp.status; Body = $obj; Text = $text }
}
function Act([string] $Name, $A = @{}) { return (Req 'POST' '/api/action' @{ name = $Name; args = $A }) }

$V = New-TestRepo 'visualiseur'
[void](Set-ViewerProject $V $Shared)

Test-Case 'ENF-07 / FC5 : hôte, jeton et origine contrôlés' {
    Assert-Equal (Req 'GET' '/api/state' $null @{ host = 'evil.example:4242' }).Status 403 'hôte étranger (DNS rebinding)'
    Assert-Equal (Req 'GET' '/api/state' $null @{ 'x-gittools-token' = 'faux' }).Status 403 'jeton faux'
    Assert-Equal (Req 'POST' '/api/action' @{ name = 'stageAll' } @{ 'sec-fetch-site' = 'cross-site' }).Status 403 'requête inter-sites'
    Assert-Equal (Req 'POST' '/api/action' @{ name = 'stageAll' } @{ origin = 'http://evil.example' }).Status 403 'origine étrangère'
    Assert-Equal (Req 'GET' '/api/state').Status 200 'requête légitime'
    Assert-Equal (Req 'GET' '/api/state' $null @{ 'x-gittools-token' = 'JETON-TEST' }).Status 403 'jeton comparé sans la casse'
    $page = Req 'GET' '/'
    Assert-Equal $page.Status 200 'page'
    Assert-True ($page.Text -notmatch 'jeton-test') 'le jeton ne doit jamais être écrit dans la page servie'
}

Test-Case 'R-20 / TR-05 / TR-10 / TR-11 : réglages listés, modifiés, refusés avec les bornes, rétablis' {
    $g = Req 'GET' '/api/settings'
    Assert-Equal $g.Status 200 'lecture des réglages'
    $keys = @($g.Body.items | ForEach-Object { $_.key }) -join ','
    Assert-Equal $keys 'intervalMin,keepSeries,shareRemote,autoTrack,autoTrackExclude,launcher,graphLimit' 'TR-05 : tous les réglages, dans l''ordre'
    foreach ($i in $g.Body.items) { Assert-True ($i.label -and $i.help) "explication manquante : $($i.key)" }
    Assert-Equal (@($g.Body.items | Where-Object key -eq 'intervalMin'))[0].default 30 'défaut de l''intervalle'

    $r = Req 'POST' '/api/settings' @{ key = 'intervalMin'; value = 15 }
    Assert-Equal $r.Status 200 'intervalle 15 accepté'
    Assert-Equal ([int](Get-GTConfig).intervalMin) 15 'intervalle enregistré'
    Assert-Equal ([int](Get-ViewerState $V).autosave.intervalMin) 15 'R-20 : le compte à rebours reflète 15 min'
    foreach ($bad in @(3, 241, '15 min', 12.5, $true)) {
        $x = Req 'POST' '/api/settings' @{ key = 'intervalMin'; value = $bad }
        Assert-Equal $x.Status 400 "valeur « $bad » acceptée"
        Assert-True ($x.Body.message -match 'de 5 à 240') "message sans les valeurs acceptées : $($x.Body.message)"
    }
    Assert-Equal ([int](Get-GTConfig).intervalMin) 15 'une valeur refusée ne change rien'
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'launcher'; value = 'cmd' }).Status 400 'lanceur inconnu accepté'
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'keepSeries'; value = 'oui' }).Status 400 'booléen texte accepté'
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'scheduleStart'; value = 'x' }).Status 400 'réglage interne modifiable'
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'keepSeries'; value = $true }).Status 200 'booléen'
    [void](Set-GTConfigValue 'autoTrackExclude' @('C:\a', 'D:\projet été'))
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'autoTrackExclude'; value = @('D:\projet été') }).Status 200 'retrait d''une exclusion'
    Assert-Equal (@((Get-GTConfig).autoTrackExclude) -join '|') 'D:\projet été' 'liste d''exclusion'
    Assert-Equal (Req 'POST' '/api/settings' @{ key = 'autoTrackExclude'; value = @() }).Status 200 'liste vidée'
    Assert-Equal @((Get-GTConfig).autoTrackExclude).Count 0 'liste vide'

    $z = Req 'POST' '/api/settings' @{ reset = $true }
    Assert-Equal $z.Status 200 'rétablir'
    $c = Get-GTConfig
    Assert-True ([int]$c.intervalMin -eq 30 -and -not $c.keepSeries) 'TR-10 : valeurs par défaut en 1 action'
}

Test-Case 'VI-03 / VI-04 : état conforme au projet' {
    Write-File $V 'a.txt' "modifié`n"; Write-File $V 'nouveau é.txt' "n`n"
    $s = (Req 'GET' '/api/state').Body
    Assert-Equal $s.branch 'main' 'branche'
    Assert-Equal @($s.changes).Count 2 'nombre de modifications'
    Assert-True (@($s.changes | Where-Object { $_.path -eq 'nouveau é.txt' -and $_.untracked }).Count -eq 1) 'nouveau fichier accentué'
    Assert-Equal $s.autosave.tracked $true 'VI-34 : inscrit à la sauvegarde à l''ouverture'
}

Test-Case 'VI-06 : l''empreinte change quand un fichier déjà modifié change encore' {
    $f1 = (Req 'GET' '/api/state').Body.fingerprint
    Start-Sleep -Milliseconds 50
    Write-File $V 'a.txt' "modifié encore`n"
    $f2 = (Req 'GET' '/api/state').Body.fingerprint
    Assert-True ($f1 -ne $f2) 'empreinte identique'
}

Test-Case 'VI-01 / VI-02 : graphe avec points de reprise distincts et masquables' {
    [void](Invoke-AutosaveProject -Repo $V -Config $cfg)
    $g = (Req 'GET' '/api/graph?limit=400&autosave=1').Body
    Assert-True (@($g.commits | Where-Object { $_.auto }).Count -eq 1) 'point de reprise marqué'
    Assert-Equal $g.main.ref 'refs/heads/main' 'branche principale'
    $g2 = (Req 'GET' '/api/graph?limit=400&autosave=0').Body
    Assert-Equal @($g2.commits | Where-Object { $_.auto }).Count 0 'points de reprise masqués'
}

Test-Case 'R-12 / VI-10 / VI-12 : indexer un fichier, committer l''index' {
    $r = Act 'stage' @{ paths = @('a.txt') }
    Assert-True $r.Body.ok $r.Body.message
    $c = Act 'commit' @{ message = 'Seulement a.txt'; all = $false; amend = $false }
    Assert-True $c.Body.ok $c.Body.message
    Assert-Equal (G $V @('show', '--name-only', '--format=', 'HEAD')) 'a.txt' 'fichiers du commit'
    Assert-True ((G $V @('status', '--porcelain')) -match 'nouveau é\.txt') 'le nouveau fichier doit rester en cours'
}

Test-Case 'RG-23 / RG-24 : message vide ou index vide refusés' {
    Assert-Equal (Act 'commit' @{ message = '  '; all = $true }).Status 400 'message vide'
    Assert-Equal (Act 'commit' @{ message = 'x'; all = $false }).Status 400 'index vide'
}

Test-Case 'R-13 / VI-13 : annuler le dernier commit, modifications indexées' {
    $parent = G $V @('rev-parse', 'HEAD~1')
    Assert-True (Act 'undoCommit').Body.ok 'annulation'
    Assert-Equal (G $V @('rev-parse', 'HEAD')) $parent 'HEAD'
    Assert-Equal (G $V @('diff', '--cached', '--name-only')) 'a.txt' 'modifications indexées'
}

Test-Case 'VI-11 : annuler un fichier ; nouveau fichier supprimé' {
    Assert-True (Act 'discard' @{ path = 'a.txt' }).Body.ok 'annulation'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $V 'a.txt'))) "un`n" 'contenu HEAD'
    $d = Act 'discard' @{ path = 'nouveau é.txt' }
    Assert-True $d.Body.ok "suppression : $($d.Body.message)"
    $left = Test-Path -LiteralPath (Join-Path $V 'nouveau é.txt')
    Assert-True (-not $left) ("fichier encore présent — réponse « $($d.Body.message) », état :`n" + (G $V @('status', '--porcelain', '--untracked-files=all')) +
        "`nHEAD : " + (G $V @('ls-tree', '-r', '--name-only', 'HEAD')))
}

Test-Case 'VI-14 : mettre de côté et réappliquer, nouveaux fichiers inclus' {
    Write-File $V 'stash é.txt' "s`n"
    Assert-True (Act 'stash').Body.ok 'stash'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $V 'stash é.txt'))) 'nouveau fichier non mis de côté'
    Assert-True (Act 'stashPop').Body.ok 'pop'
    Assert-True (Test-Path -LiteralPath (Join-Path $V 'stash é.txt')) 'nouveau fichier non réappliqué'
    Remove-Item -LiteralPath (Join-Path $V 'stash é.txt')
}

Test-Case 'R-15 / RG-21 / VI-15 : branches ; suppression non fusionnée en deux temps' {
    Assert-True (Act 'createBranch' @{ branch = 'essai' }).Body.ok 'création'
    Write-File $V 'e.txt' "e`n"; [void](Invoke-Git $V @('add', '-A')); [void](Invoke-Git $V @('commit', '-qm', 'essai'))
    Assert-True (Act 'switch' @{ branch = 'main' }).Body.ok 'bascule'
    $d = Act 'deleteBranch' @{ branch = 'essai' }
    Assert-True ((-not $d.Body.ok) -and $d.Body.needsForce) 'première demande doit exiger une confirmation'
    Assert-True (G $V @('branch', '--list', 'essai')) 'branche supprimée trop tôt'
    Assert-True (Act 'deleteBranch' @{ branch = 'essai'; force = $true }).Body.ok 'suppression forcée'
    Assert-Equal (G $V @('branch', '--list', 'essai')) '' 'branche encore là'
}

Test-Case 'Revue 🟡4 : indexer « [ab].txt » n''indexe que lui' {
    Write-File $V '[ab].txt' "x`n"; Write-File $V 'b.txt' "y`n"
    Assert-True (Act 'stage' @{ paths = @('[ab].txt') }).Body.ok 'indexation'
    Assert-Equal (G $V @('diff', '--cached', '--name-only')) '[ab].txt' 'fichiers indexés'
    [void](Act 'unstageAll')
    Remove-Item -LiteralPath (Join-Path $V '[ab].txt'), (Join-Path $V 'b.txt')
}

Test-Case 'Revue 🟡5 : fusion refusée avec un travail non committé' {
    [void](Invoke-Git $V @('branch', 'pour-fusion'))
    Write-File $V 'a.txt' "en cours`n"
    $r = Act 'merge' @{ branch = 'pour-fusion' }
    Assert-Equal $r.Status 409 'statut'
    [void](Act 'discard' @{ path = 'a.txt' })
    [void](Invoke-Git $V @('branch', '-D', 'pour-fusion'))
}

Test-Case 'RG-29 : noms de branche, identifiants et chemins invalides refusés' {
    Assert-Equal (Act 'createBranch' @{ branch = 'a b' }).Status 400 'espace'
    Assert-Equal (Act 'switch' @{ branch = '--orphan' }).Status 400 'option déguisée'
    Assert-Equal (Act 'deleteBranch' @{ branch = '@{-1}' }).Status 400 'raccourci @{-1}'
    Assert-Equal (Act 'checkoutCommit' @{ sha = 'HEAD;rm' }).Status 400 'identifiant'
    Assert-Equal (Act 'stage' @{ paths = @('..\..\Windows\win.ini') }).Status 400 'chemin hors projet'
    Assert-Equal (Act 'discard' @{ path = 'C:\Windows\win.ini' }).Status 400 'chemin absolu'
    Assert-Equal (Req 'GET' '/api/diff?path=..%2F..%2Fsecret&mode=worktree').Status 400 'diff hors projet'
}

Test-Case 'RG-22 / VI-20 / VI-21 / VI-22 : distant — récupérer, tirage sans fusion, pousser' {
    $bare = Join-Path $TmpBase 'distant é.git'
    [void](Invoke-Git $TmpBase @('init', '-q', '--bare', $bare))
    [void](Invoke-Git $V @('remote', 'add', 'origin', $bare))
    $p = Act 'push'
    Assert-True $p.Body.ok "premier envoi : $($p.Body.message)"
    $clone = Join-Path $TmpBase 'clone é'
    [void](Invoke-Git $TmpBase @('clone', '-q', $bare, $clone))
    [void](Invoke-Git $clone @('config', 'user.name', 'B')); [void](Invoke-Git $clone @('config', 'user.email', 'b@b'))
    Write-File $clone 'distant.txt' "d`n"; [void](Invoke-Git $clone @('add', '-A')); [void](Invoke-Git $clone @('commit', '-qm', 'distant'))
    [void](Invoke-Git $clone @('push', '-q'))
    $before = Get-Snapshot $V
    Assert-True (Act 'fetch').Body.ok 'récupération'
    $after = Get-Snapshot $V
    Assert-Equal $after.Head $before.Head 'VI-20 : branche locale modifiée par la récupération'
    Assert-Equal $after.Files $before.Files 'VI-20 : fichiers modifiés par la récupération'
    Write-File $V 'local.txt' "l`n"; [void](Invoke-Git $V @('add', '-A')); [void](Invoke-Git $V @('commit', '-qm', 'local'))
    $headLocal = G $V @('rev-parse', 'HEAD')
    $pull = Act 'pull'
    Assert-True (-not $pull.Body.ok) 'le tirage divergent doit être refusé'
    Assert-True ($pull.Body.message -match 'divergé') $pull.Body.message
    Assert-Equal (G $V @('rev-parse', 'HEAD')) $headLocal 'RG-22 : une fusion a été créée'
    $push = Act 'push'
    Assert-True ((-not $push.Body.ok) -and $push.Body.message) 'cause de l''échec de l''envoi'
}

Test-Case 'RG-28 : dossier non git refusé, projet courant conservé' {
    $not = Join-Path $TmpBase 'pas git'
    New-Item -ItemType Directory -Path $not -Force | Out-Null
    $r = Req 'POST' '/api/open' @{ path = $not }
    Assert-Equal $r.Status 400 'statut'
    Assert-True (Test-GTSamePath $Shared.project $V) 'projet courant changé'
}

Test-Case 'RG-25 / VI-32 / RG-26 : changer de projet incrémente la séquence ; exclusion respectée' {
    $seq = [int]$Shared.projectSeq
    $o = New-TestRepo 'autre'
    $cfgX = Set-GTConfigValue 'autoTrackExclude' @($o)
    $r = Req 'POST' '/api/open' @{ path = $o }
    Assert-Equal $r.Status 200 'ouverture'
    Assert-Equal ([int]$Shared.projectSeq) ($seq + 1) 'séquence'
    Assert-True (-not (Test-GTProjectTracked $o)) 'projet exclu réinscrit'
    $list = (Req 'GET' '/api/projects').Body
    Assert-True (@($list.items | Where-Object { Test-GTSamePath $_.path $o }).Count -eq 1) 'liste des récents'
    [void](Set-GTConfigValue 'autoTrackExclude' @())
    [void](Set-ViewerProject $V $Shared)
}

if ($Integration) {
    Write-Host ''
    Write-Host 'Intégration (processus réels)' -ForegroundColor Cyan

    Test-Case 'SA-05 : le hook post-commit nettoie en moins de 10 s' {
        $r = New-TestRepo 'hook'
        [void](Install-AutosaveHook $r)
        Write-File $r 'a.txt' "x`n"; [void](Invoke-AutosaveProject -Repo $r -Config $cfg)
        Assert-Equal (Get-Series $r).Count 1 'série avant commit'
        $t0 = Get-Date
        [void](Invoke-Git $r @('commit', '-qam', 'manuel'))
        while ((Get-Series $r).Count -gt 0 -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 250 }
        Assert-Equal (Get-Series $r).Count 0 "série encore présente après $([int]((Get-Date) - $t0).TotalSeconds) s"
    }

    $viewerPs1 = Join-Path $Root 'viewer\git-viewer.ps1'
    Test-Case 'R-09 / VI-30 : le lanceur rend la main en moins de 5 s' {
        $a = New-TestRepo 'lanceur A'
        $t0 = Get-Date
        $out = & powershell.exe -NoProfile -File $viewerPs1 $a 2>&1 | Out-String
        $secs = ((Get-Date) - $t0).TotalSeconds
        Assert-Equal $LASTEXITCODE 0 "code de sortie : $out"
        Assert-True ($secs -lt 5) "main rendue en $([math]::Round($secs,1)) s"
        $lock = Get-GTViewerLock
        Assert-True ($lock -and (Test-GTViewerAlive $lock)) 'serveur non joignable'
        $script:FirstPid = [int]$lock.pid
        $s = Invoke-GTLocalRequest -Port ([int]$lock.port) -Token ([string]$lock.token) -Path '/api/state'
        Assert-True (Test-GTSamePath $s.Body.project $a) 'projet affiché'
    }

    Test-Case 'R-10 / VI-31 : relancer depuis un autre projet → même instance, projet basculé' {
        $b = New-TestRepo 'lanceur B'
        $jobs = 1..3 | ForEach-Object { Start-Job -ScriptBlock { param($p, $d, $t) $env:GITTOOLS_DATA = $d; $env:GITTOOLS_NOBROWSER = '1'; & powershell.exe -NoProfile -File $p $t | Out-Null } -ArgumentList $viewerPs1, $env:GITTOOLS_DATA, $b }
        $jobs | Wait-Job -Timeout 30 | Remove-Job -Force
        $lock = Get-GTViewerLock
        Assert-Equal ([int]$lock.pid) $script:FirstPid 'une seconde instance a démarré'
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*server.ps1*' })
        Assert-Equal $procs.Count 1 'nombre de serveurs'
        $s = Invoke-GTLocalRequest -Port ([int]$lock.port) -Token ([string]$lock.token) -Path '/api/state'
        Assert-True (Test-GTSamePath $s.Body.project $b) 'projet non basculé'
    }

    Test-Case 'ENF-07 : serveur réel — hôte étranger et absence de jeton refusés' {
        $lock = Get-GTViewerLock
        $bad = Invoke-GTLocalRequest -Port ([int]$lock.port) -Token 'faux' -Path '/api/state'
        Assert-Equal $bad.Status 403 'jeton faux'
        $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$lock.port)
        $st = $c.GetStream()
        $q = [System.Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nHost: evil.example`r`nConnection: close`r`n`r`n")
        $st.Write($q, 0, $q.Length)
        $rd = New-Object System.IO.StreamReader($st)
        $first = $rd.ReadLine(); $c.Close()
        Assert-True ($first -match ' 403 ') "réponse : $first"
        $listen = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$lock.port) -ErrorAction SilentlyContinue)
        if ($listen.Count) { Assert-True (@($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) 'écoute hors 127.0.0.1' }
    }

    Test-Case 'VI-35 / ENF-09 : arrêt complet, puis relance après arrêt brutal' {
        $out = & powershell.exe -NoProfile -File $viewerPs1 stop 2>&1 | Out-String
        Start-Sleep -Milliseconds 500
        Assert-True (-not (Get-Process -Id $script:FirstPid -ErrorAction SilentlyContinue)) "processus restant : $out"
        $a = New-TestRepo 'relance'
        & powershell.exe -NoProfile -File $viewerPs1 $a | Out-Null
        $lock = Get-GTViewerLock
        Stop-Process -Id ([int]$lock.pid) -Force
        Start-Sleep -Milliseconds 300
        & powershell.exe -NoProfile -File $viewerPs1 $a | Out-Null
        Assert-Equal $LASTEXITCODE 0 'relance après arrêt brutal'
        Assert-True (Test-GTViewerAlive) 'serveur relancé injoignable'
        [void](Stop-GTViewer)
    }
}

# ---------------------------------------------------------------- bilan
$fail = @($Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("Bilan : {0} réussi(s), {1} échec(s) sur {2}." -f ($Results.Count - $fail.Count), $fail.Count, $Results.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
$report = Join-Path $Root 'tests\derniere-recette.txt'
$lines = @("git-tools — recette du $(Get-Date -Format 'dd/MM/yyyy HH:mm') — PowerShell $($PSVersionTable.PSVersion) — Windows $([Environment]::OSVersion.Version)")
$lines += $Results | ForEach-Object { "{0}  {1}{2}" -f $(if ($_.Ok) { 'OK   ' } else { 'ÉCHEC' }), $_.Name, $(if ($_.Detail) { " — $($_.Detail)" } else { '' }) }
[System.IO.File]::WriteAllLines($report, $lines, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Rapport : $report"
if (-not $KeepTemp) {
    try { [void](Stop-GTViewer) } catch { }
    Remove-Item -LiteralPath $TmpBase -Recurse -Force -ErrorAction SilentlyContinue
}
exit $fail.Count
