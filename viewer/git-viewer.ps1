<#
  git viewer — ouvre le visualiseur sur le projet courant (lot L5).
  VI-30 (rend la main), VI-31 (instance unique), VI-33 (dernier projet), VI-35 (arrêt), TR-04 (aide).
  Codes de sortie : 0 succès, 1 commande invalide, 2 hors projet git, 3 échec.
  Ce fichier doit rester en UTF-8 avec BOM.
#>
param(
    [Parameter(Position = 0)] [string] $Command = '',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'common\GitTools.Common.psm1') -DisableNameChecking
Initialize-GTConsole

function Fail([string] $Text, [int] $Code = 3) { [Console]::Error.WriteLine("Erreur : $Text"); exit $Code }

function Resolve-UserPath([string] $Path) {
    $here = (Get-Location).ProviderPath
    if ($env:GIT_PREFIX) { $here = Join-Path $here $env:GIT_PREFIX }
    if (-not $Path) { return $here }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $here $Path)
}

function Show-Help {
    $lock = Get-GTViewerLock
    $etat = if ($lock -and (Test-GTViewerAlive $lock)) { "en marche — http://127.0.0.1:$($lock.port)/" } else { 'arrêté' }
    Write-Host @"
git viewer — graphe et gestion du projet git dans le navigateur

UTILISATION
  git viewer [chemin]     Ouvrir le visualiseur sur le projet (dossier courant par défaut ;
                          hors projet : dernier projet consulté)
  git viewer stop         Arrêter le visualiseur
  git viewer help         Cette aide

Le visualiseur fonctionne en arrière-plan : vous pouvez fermer ce terminal.
Une seule instance tourne ; relancer la commande depuis un autre projet bascule la page ouverte.

ÉTAT
  Visualiseur : $etat
  Journal     : $(Join-Path (Get-GTDataDir) 'logs\viewer.log')
"@
}

function Start-Server([string] $Root) {
    $server = Join-Path $PSScriptRoot 'server.ps1'
    $a = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $server)
    if ($Root) { $a += @('-Project', $Root) }
    Start-Process -FilePath (Get-GTPowerShellExe) -ArgumentList (ConvertTo-GTArgString $a) -WindowStyle Hidden `
        -WorkingDirectory $env:SystemRoot | Out-Null
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        $lock = Get-GTViewerLock
        if ($lock -and (Test-GTViewerAlive $lock)) { return $lock }
    }
    return $null
}

try {
    switch ($Command.ToLowerInvariant()) {
        'stop' {
            if (Stop-GTViewer) { Write-Host 'Visualiseur arrêté.' } else { Write-Host "Le visualiseur n'était pas lancé." }
            exit 0
        }
        { $_ -in @('help', '--help', '-h', 'aide', '/?') } { Show-Help; exit 0 }
    }
    if ($Command.StartsWith('-')) {
        [Console]::Error.WriteLine("Option inconnue : « $Command ».")
        Show-Help
        exit 1
    }

    # Projet demandé (RG-28 : un dossier qui n'est pas un projet git est refusé)
    $root = $null
    if ($Command) {
        $p = Resolve-UserPath $Command
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { Fail "Dossier introuvable : $p" 2 }
        $root = Get-GTRepoRoot $p
        if (-not $root) { Fail "« $p » n'est pas un projet git." 2 }
    } else {
        $root = Get-GTRepoRoot (Resolve-UserPath '')
    }

    $lock = Get-GTViewerLock
    if (-not ($lock -and (Test-GTViewerAlive $lock))) {
        $lock = Start-Server $root
        if (-not $lock) {
            Fail "Le visualiseur n'a pas démarré. Consultez le journal : $(Join-Path (Get-GTDataDir) 'logs\viewer.log')"
        }
    }
    $body = @{ path = $(if ($root) { $root } else { '' }); launch = $true }
    $r = Invoke-GTLocalRequest -Port ([int]$lock.port) -Token ([string]$lock.token) -Method POST -Path '/api/open' -Body $body -TimeoutMs 8000
    if (-not $r -or $r.Status -ne 200) {
        $m = if ($r -and $r.Body) { $r.Body.message } else { 'pas de réponse' }
        Fail "Ouverture du projet impossible : $m"
    }
    $url = "http://127.0.0.1:$($lock.port)/"
    if ($r.Body.project) { Write-Host "Visualiseur : $url — projet $($r.Body.project)" }
    else { Write-Host "Visualiseur : $url — aucun projet récent, choisissez-en un dans la page." }
    if ($r.Body.tracked) { Write-Host '  Projet inscrit à la sauvegarde automatique.' }
    if (-not $r.Body.tabOpened) { Write-Host '  La page déjà ouverte affiche ce projet.' }
    exit 0
} catch {
    Fail $_.Exception.Message
}
