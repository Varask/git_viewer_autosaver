# git-tools — module commun
# Appel de git (ADR-04), configuration, listes de projets, journal (ENF-10).
# Compatible Windows PowerShell 5.1 et PowerShell 7. Ce fichier doit rester en UTF-8 avec BOM.

Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LogMaxBytes = 1MB

$script:DefaultConfig = [ordered]@{
    intervalMin       = 30      # SA-11 : 5 à 240 min
    keepSeries        = $false  # SA-06
    shareRemote       = $false  # SA-07
    autoTrack         = $true   # VI-34 / RG-26
    autoTrackExclude  = @()     # projets à ne jamais réinscrire automatiquement
    graphLimit        = 400     # VI-01 / ENF-13
    launcher          = 'conhost' # ADR-05 : conhost | wscript
    scheduleStart     = $null   # ADR-05 : départ de la tâche planifiée (ISO 8601)
}

# ---------------------------------------------------------------- emplacements

function Get-GTDataDir {
    # Données utilisateur : %LOCALAPPDATA%\git-tools (ENF-15). GITTOOLS_DATA permet aux tests d'isoler.
    if ($env:GITTOOLS_DATA) { $dir = $env:GITTOOLS_DATA }
    elseif ($env:LOCALAPPDATA) { $dir = Join-Path $env:LOCALAPPDATA 'git-tools' }
    else { $dir = Join-Path $HOME '.git-tools' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GTLogDir {
    $dir = Join-Path (Get-GTDataDir) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GTInstallDir {
    # Dossier du produit : parent du dossier « common ».
    return (Split-Path -Parent $PSScriptRoot)
}

# ---------------------------------------------------------------- fichiers JSON

function Read-GTJson {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Invoke-GTRetry {
    # Quelques tentatives espacées : un autre processus peut lire le fichier au même instant.
    param([scriptblock] $Action, [int] $Tries = 5)
    for ($i = 1; $i -le $Tries; $i++) {
        try { return (& $Action) } catch { if ($i -eq $Tries) { throw }; Start-Sleep -Milliseconds (40 * $i) }
    }
}

function Write-GTJson {
    # Écriture atomique : fichier temporaire unique puis remplacement.
    # Attention : $null passé à un paramètre string .NET devient "" en PowerShell → [NullString]::Value.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 6
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    try {
        Invoke-GTRetry {
            if ([System.IO.File]::Exists($Path)) {
                [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value)
            } else {
                [System.IO.File]::Move($tmp, $Path)
            }
        }
    } finally {
        if ([System.IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Use-GTDataLock {
    # Sérialise lecture + modification + écriture des fichiers de données entre CLI, tâche et serveur.
    param([Parameter(Mandatory)] [scriptblock] $Action)
    $m = New-Object System.Threading.Mutex($false, 'Local\git-tools-data')
    $own = $false
    try {
        try { $own = $m.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $own = $true }
        return (& $Action)
    } finally {
        if ($own) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Write-GTText {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# ---------------------------------------------------------------- configuration

function Get-GTConfig {
    $cfg = [ordered]@{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    $file = Read-GTJson (Join-Path (Get-GTDataDir) 'config.json')
    if ($file) {
        foreach ($p in $file.PSObject.Properties) {
            if ($cfg.Contains($p.Name)) {
                if ($p.Name -eq 'autoTrackExclude') { $cfg[$p.Name] = @($p.Value | Where-Object { $_ }) }
                else { $cfg[$p.Name] = $p.Value }
            }
        }
    }
    # Valeurs éditées à la main : bornées plutôt que de faire échouer le produit.
    $iv = 30
    if (-not [int]::TryParse([string]$cfg.intervalMin, [ref]$iv)) { $iv = 30 }
    $cfg.intervalMin = [math]::Min(240, [math]::Max(5, $iv))
    $gl = 400
    if (-not [int]::TryParse([string]$cfg.graphLimit, [ref]$gl)) { $gl = 400 }
    $cfg.graphLimit = [math]::Min(5000, [math]::Max(50, $gl))
    return $cfg
}

function Set-GTConfigValue {
    param([Parameter(Mandatory)] [string] $Name, $Value)
    if (-not $script:DefaultConfig.Contains($Name)) { throw "Réglage inconnu : $Name" }
    return Use-GTDataLock {
        $cfg = Get-GTConfig
        $cfg[$Name] = $Value
        Write-GTJson (Join-Path (Get-GTDataDir) 'config.json') $cfg
        $cfg
    }
}

# ---------------------------------------------------------------- journal (SA-12, ENF-10)

function Write-GTLog {
    param(
        [Parameter(Mandatory)] [ValidateSet('autosave', 'viewer')] [string] $Tool,
        [ValidateSet('INFO', 'SAVE', 'CLEAN', 'SKIP', 'WARN', 'ERROR')] [string] $Level = 'INFO',
        [string] $Project = '',
        [Parameter(Mandatory)] [string] $Message
    )
    try {
        $file = Join-Path (Get-GTLogDir) "$Tool.log"
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $proj = if ($Project) { " [$Project]" } else { '' }
        $line = "$stamp $($Level.PadRight(5))$proj $Message`r`n"
        Invoke-GTRetry { [System.IO.File]::AppendAllText($file, $line, $script:Utf8NoBom) } 8
        $info = New-Object System.IO.FileInfo($file)
        if ($info.Length -gt $script:LogMaxBytes) { Limit-GTLog $file }
    } catch {
        # Le journal ne doit jamais faire échouer un passage.
    }
}

function Limit-GTLog {
    # Garde la seconde moitié du journal, coupée sur une fin de ligne.
    param([string] $File)
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $keep = [int]($script:LogMaxBytes / 2)
    $start = $bytes.Length - $keep
    while ($start -lt $bytes.Length -and $bytes[$start] -ne 10) { $start++ }
    $start++
    $tail = New-Object byte[] ($bytes.Length - $start)
    [Array]::Copy($bytes, $start, $tail, 0, $tail.Length)
    [System.IO.File]::WriteAllBytes($File, $tail)
}

# ---------------------------------------------------------------- appel de git (ADR-04)

function ConvertTo-GTArgString {
    # Cite chaque argument selon les règles de CommandLineToArgvW.
    param([string[]] $Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($null -eq $a) { $a = '' }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $bs++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"')
            } else {
                if ($bs) { [void]$sb.Append('\' * $bs) }
                [void]$sb.Append($ch)
            }
            $bs = 0
        }
        if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

$script:GitExe = $null
function Get-GTGitExe {
    # Chemin complet de git, résolu par le PATH uniquement : un git.exe déposé dans un dépôt cloné
    # (dossier courant) n'est jamais exécuté (classe CVE-2020-27955).
    if (-not $script:GitExe) {
        $c = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $c) { throw 'git est introuvable. Installez Git for Windows puis rouvrez le terminal.' }
        $script:GitExe = $c.Source
    }
    return $script:GitExe
}

function Get-GTPowerShellExe {
    # Windows PowerShell 5.1 par son chemin complet (même raison).
    if ($env:SystemRoot) {
        $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $c = Get-Command powershell, pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    throw 'Windows PowerShell est introuvable.'
}

function Invoke-Git {
    <#
      Lance git sans fenêtre, sans invite, sortie en UTF-8.
      Renvoie un objet { ExitCode; Out; Err; Lines }.
      Lève une exception si git échoue, sauf avec -AllowFail.
    #>
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [hashtable] $Environment = @{},
        [int] $TimeoutSec = 120,
        [switch] $AllowFail
    )
    $base = @('-c', 'core.quotepath=false', '-c', 'gc.auto=0', '-c', 'credential.interactive=false',
              '-c', 'i18n.logOutputEncoding=UTF-8', '-c', 'color.ui=false')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-GTGitExe
    $psi.Arguments = ConvertTo-GTArgString ($base + $Arguments)
    $psi.WorkingDirectory = $Repo
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $envs = @{
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE     = 'never'
        GIT_OPTIONAL_LOCKS  = '0'
        GIT_ASKPASS         = ''
        SSH_ASKPASS         = ''
        LC_ALL              = 'C'   # messages git en anglais : analyse stable
    }
    # ssh ne connaît pas GIT_TERMINAL_PROMPT : sans BatchMode il attendrait une saisie invisible (ENF-08).
    if ($Arguments.Count -and $Arguments[0] -in @('push', 'fetch', 'pull', 'ls-remote', 'clone') -and
        -not $env:GIT_SSH_COMMAND -and -not $env:GIT_SSH) {
        $sshCfg = $null
        try {
            $q = New-Object System.Diagnostics.ProcessStartInfo
            $q.FileName = Get-GTGitExe; $q.Arguments = 'config --get core.sshCommand'; $q.WorkingDirectory = $Repo
            $q.UseShellExecute = $false; $q.CreateNoWindow = $true; $q.RedirectStandardOutput = $true
            $qp = [System.Diagnostics.Process]::Start($q); $sshCfg = $qp.StandardOutput.ReadToEnd().Trim(); $qp.WaitForExit()
        } catch { }
        if (-not $sshCfg) { $envs['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes' }
    }
    foreach ($k in $Environment.Keys) { $envs[$k] = $Environment[$k] }
    foreach ($k in $envs.Keys) {
        if ($null -eq $envs[$k]) { $psi.EnvironmentVariables.Remove($k) }
        else { $psi.EnvironmentVariables[$k] = [string]$envs[$k] }
    }

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw "Impossible de lancer git : $($_.Exception.Message)"
    }
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "git $($Arguments[0]) a dépassé $TimeoutSec s et a été interrompu."
    }
    $p.WaitForExit()
    $res = [pscustomobject]@{
        ExitCode = $p.ExitCode
        Out      = $outTask.Result
        Err      = $errTask.Result.Trim()
    }
    $res | Add-Member -NotePropertyName Lines -NotePropertyValue @(
        $res.Out -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($res.ExitCode -ne 0 -and -not $AllowFail) {
        $msg = if ($res.Err) { $res.Err } else { $res.Out.Trim() }
        throw "git $($Arguments[0]) : $msg"
    }
    return $res
}

function Get-GitValue {
    # Première ligne de sortie, ou $null si git échoue.
    param([string] $Repo, [string[]] $Arguments)
    $r = Invoke-Git -Repo $Repo -Arguments $Arguments -AllowFail
    if ($r.ExitCode -ne 0) { return $null }
    $v = $r.Out.Trim()
    if ($v -eq '') { return $null }
    return $v
}

# ---------------------------------------------------------------- projets

function ConvertTo-GTNativePath {
    param([string] $Path)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $p = $Path.Replace('/', $sep).Replace('\', $sep)
    if ($p.Length -gt 3) { $p = $p.TrimEnd($sep) }
    return $p
}

function Get-GTRepoRoot {
    # Racine du projet git contenant $Path, ou $null.
    param([string] $Path = (Get-Location).ProviderPath)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $top = Get-GitValue -Repo $Path -Arguments @('rev-parse', '--show-toplevel')
    if (-not $top) { return $null }
    return (ConvertTo-GTNativePath $top)
}

function Test-GTSamePath {
    param([string] $A, [string] $B)
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals((ConvertTo-GTNativePath $A), (ConvertTo-GTNativePath $B),
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-GTListFile { param([string] $Name) Join-Path (Get-GTDataDir) "$Name.json" }

function Get-GTList {
    param([ValidateSet('projects', 'recent')] [string] $Name)
    $o = Read-GTJson (Get-GTListFile $Name)
    if (-not $o -or -not ($o.PSObject.Properties.Name -contains 'items')) { return @() }
    return @($o.items | Where-Object { $_ })
}

function Set-GTList {
    param([ValidateSet('projects', 'recent')] [string] $Name, [string[]] $Items)
    Write-GTJson (Get-GTListFile $Name) ([ordered]@{ items = @($Items) })
}

function Get-GTProjects { return Get-GTList 'projects' }

function Add-GTProject {
    param([Parameter(Mandatory)] [string] $Root)
    return Use-GTDataLock {
        $items = @(Get-GTProjects)
        $known = $false
        foreach ($i in $items) { if (Test-GTSamePath $i $Root) { $known = $true } }
        if (-not $known) { Set-GTList 'projects' ($items + $Root) }
        -not $known
    }
}

function Remove-GTProject {
    param([Parameter(Mandatory)] [string] $Root)
    return Use-GTDataLock {
        $items = @(Get-GTProjects)
        $kept = @($items | Where-Object { -not (Test-GTSamePath $_ $Root) })
        Set-GTList 'projects' $kept
        $kept.Count -ne $items.Count
    }
}

function Test-GTProjectTracked {
    param([string] $Root)
    foreach ($i in Get-GTProjects) { if (Test-GTSamePath $i $Root) { return $true } }
    return $false
}

function Add-GTRecent {
    # 15 derniers projets ouverts dans le visualiseur (VI-32).
    param([Parameter(Mandatory)] [string] $Root)
    Use-GTDataLock {
        $items = @($Root) + @(Get-GTList 'recent' | Where-Object { -not (Test-GTSamePath $_ $Root) })
        Set-GTList 'recent' @($items | Select-Object -First 15)
    } | Out-Null
}

# ---------------------------------------------------------------- divers

function Get-GTNextRun {
    # Prochain passage calculé depuis le départ de la tâche (ADR-05). $null si non planifié.
    param($Config = (Get-GTConfig))
    if (-not $Config.scheduleStart) { return $null }
    $start = [datetime]::Parse([string]$Config.scheduleStart, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    $interval = [int]$Config.intervalMin
    $now = Get-Date
    if ($now -lt $start) { return $start }
    $k = [math]::Ceiling(($now - $start).TotalMinutes / $interval)
    $next = $start.AddMinutes($k * $interval)
    if ($next -le $now) { $next = $next.AddMinutes($interval) }
    return $next
}

# ---------------------------------------------------------------- visualiseur : verrou et client local (ADR-09)

function Get-GTViewerLock {
    $o = Read-GTJson (Join-Path (Get-GTDataDir) 'viewer.lock')
    if (-not $o -or -not $o.port -or -not $o.token) { return $null }
    return $o
}

function Invoke-GTLocalRequest {
    <#
      Requête HTTP minimale vers le visualiseur, sans proxy système (127.0.0.1 uniquement).
      Renvoie { Status; Body } ou $null si le serveur ne répond pas.
    #>
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $Token,
        [string] $Method = 'GET',
        [string] $Path = '/api/ping',
        $Body = $null,
        [int] $TimeoutMs = 5000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(1500)) { return $null }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $payload = [byte[]]@()
        if ($null -ne $Body) { $payload = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $Body -Depth 5 -Compress)) }
        $head = "$Method $Path HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nX-GitTools-Token: $Token`r`n" +
                "Content-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $all = $ms.ToArray()
        $ascii = [System.Text.Encoding]::ASCII.GetString($all)
        $sep = $ascii.IndexOf("`r`n`r`n")
        if ($sep -lt 0) { return $null }
        $status = [int](($ascii.Substring(0, $ascii.IndexOf("`r`n")) -split ' ')[1])
        $text = $script:Utf8NoBom.GetString($all, $sep + 4, $all.Length - $sep - 4)
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ Status = $status; Body = $obj; Text = $text }
    } catch {
        return $null
    } finally {
        $client.Close()
    }
}

function Test-GTViewerAlive {
    # Verrou valide = processus vivant ET serveur qui répond (ENF-09).
    param($Lock = (Get-GTViewerLock))
    if (-not $Lock) { return $false }
    $proc = Get-Process -Id ([int]$Lock.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    $r = Invoke-GTLocalRequest -Port ([int]$Lock.port) -Token ([string]$Lock.token) -TimeoutMs 3000
    return ($r -and $r.Status -eq 200)
}

function Stop-GTViewer {
    # VI-35 : arrêt propre, puis arrêt forcé si besoin. Renvoie $true si un visualiseur tournait.
    $lock = Get-GTViewerLock
    if (-not $lock) { return $false }
    $id = [int]$lock.pid
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($proc) {
        [void](Invoke-GTLocalRequest -Port ([int]$lock.port) -Token ([string]$lock.token) -Method POST -Path '/api/shutdown' -Body @{})
        if (-not $proc.WaitForExit(5000)) { try { $proc.Kill() } catch { } }
    }
    $f = Join-Path (Get-GTDataDir) 'viewer.lock'
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return [bool]$proc
}

# ---------------------------------------------------------------- PATH utilisateur (TR-01, TR-07, ENF-15)

function Get-GTUserPathEntries {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        $v = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $key.Close() }
    return @(([string]$v).Split(';') | Where-Object { $_ })
}

function Set-GTUserPathEntries {
    param([string[]] $Entries)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $key.SetValue('Path', ($Entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    # Prévenir les autres programmes (nouveaux terminaux) du changement, sans compiler de code.
    [Environment]::SetEnvironmentVariable('GITTOOLS_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('GITTOOLS_PATH_REFRESH', $null, 'User')
}

function Add-GTUserPath {
    param([Parameter(Mandatory)] [string] $Dir)
    $entries = @(Get-GTUserPathEntries)
    foreach ($e in $entries) { if (Test-GTSamePath $e $Dir) { return $false } }
    Set-GTUserPathEntries ($entries + $Dir)
    return $true
}

function Remove-GTUserPath {
    param([Parameter(Mandatory)] [string] $Dir)
    $entries = @(Get-GTUserPathEntries)
    $kept = @($entries | Where-Object { -not (Test-GTSamePath $_ $Dir) })
    if ($kept.Count -eq $entries.Count) { return $false }
    Set-GTUserPathEntries $kept
    return $true
}

function Initialize-GTConsole {
    # Accents corrects dans la console (ENF-11).
    try { [Console]::OutputEncoding = $script:Utf8NoBom } catch { }
}

Export-ModuleMember -Function *-GT*, Invoke-Git, Get-GitValue, ConvertTo-GTArgString, Get-GTDataDir, Get-GTGitExe, Get-GTPowerShellExe
