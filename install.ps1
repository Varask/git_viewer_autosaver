<#
  git-tools — installation (lot L4). TR-01, TR-02, TR-06, ENF-05, ENF-06, ENF-12, ENF-15.
  Sans droits administrateur. Réinstallable sans doublon.

  Utilisation (dans PowerShell, depuis le dossier git-tools) :
    .\install.ps1                  les deux outils
    .\install.ps1 -Only autosave   la sauvegarde seule
    .\install.ps1 -Only viewer     le visualiseur seul

  Ce fichier doit rester en UTF-8 avec BOM.
#>
param(
    [ValidateSet('all', 'autosave', 'viewer')] [string] $Only = 'all',
    [string] $Destination = (Join-Path $env:LOCALAPPDATA 'Programs\git-tools')
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$started = Get-Date

function Step([string] $t) { Write-Host "  • $t" }
function Stop-Install([string] $t) {
    Write-Host ''
    Write-Host "Installation interrompue : $t" -ForegroundColor Red
    Write-Host "Aide : docs\GUIDE.md, section « Dépannage »." -ForegroundColor Red
    exit 1
}

Write-Host 'Installation de git-tools'

# ---------------------------------------------------------------- vérifications (FC7, ENF-05, ENF-12)
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Stop-Install "PowerShell 5.1 ou plus récent est nécessaire (version actuelle : $($PSVersionTable.PSVersion))."
}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Stop-Install "PowerShell est en mode de langage restreint ($($ExecutionContext.SessionState.LanguageMode)) sur ce poste : git-tools ne peut pas fonctionner. Transmettez docs\NOTE-DSI.md à votre service informatique."
}
$gitOk = $false
$gitCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
try { if ($gitCmd) { $gv = & $gitCmd.Source --version 2>$null; $gitOk = ($LASTEXITCODE -eq 0) } } catch { }
if (-not $gitOk) { Stop-Install "git est introuvable. Installez Git for Windows (sans droits administrateur : option « Only for me »), puis rouvrez PowerShell." }
if ($gv -match '(\d+)\.(\d+)') {
    if ([int]$Matches[1] -lt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -lt 25)) {
        Stop-Install "git 2.25 ou plus récent est nécessaire ($gv). Mettez Git for Windows à jour."
    }
}
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19044) {
    Write-Host "  ! Windows build $build : version antérieure à Windows 10 21H2, non garantie. Voir le guide, « Mode de repli »." -ForegroundColor Yellow
}

# ENF-06 / R-18 : fichiers marqués « téléchargés » (bloqués par la stratégie RemoteSigned)
$blocked = @(Get-ChildItem -LiteralPath $src -Recurse -File -Include *.ps1, *.psm1 | Where-Object {
    Get-Item -LiteralPath $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
})
if ($blocked.Count) {
    Write-Host ''
    Write-Host "$($blocked.Count) fichier(s) sont marqués comme téléchargés d'internet et seront refusés par la stratégie d'exécution du poste :" -ForegroundColor Red
    $blocked | Select-Object -First 5 | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Si vous faites confiance à ces fichiers, débloquez-les puis relancez l''installation :' -ForegroundColor Yellow
    Write-Host "    Get-ChildItem -LiteralPath '$src' -Recurse | Unblock-File" -ForegroundColor Yellow
    Write-Host "Si votre poste l'interdit, transmettez la note docs\NOTE-DSI.md à votre service informatique." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- dossier cible
# Toujours un dossier dédié nommé « git-tools » : la désinstallation ne doit jamais pouvoir
# supprimer autre chose que ce qu'elle a installé.
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ((Split-Path -Leaf $Destination) -ne 'git-tools') { $Destination = Join-Path $Destination 'git-tools' }

# ---------------------------------------------------------------- copie des fichiers
$parts = @('common')
if ($Only -in @('all', 'autosave')) { $parts += 'autosave' }
if ($Only -in @('all', 'viewer')) { $parts += 'viewer' }

$sameDir = [string]::Equals([IO.Path]::GetFullPath($src).TrimEnd('\'), [IO.Path]::GetFullPath($Destination).TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase)
if (-not $sameDir) {
    # Arrêter le visualiseur avant de remplacer ses fichiers (TR-06).
    $commonOld = Join-Path $Destination 'common\GitTools.Common.psm1'
    if (Test-Path -LiteralPath $commonOld) {
        Import-Module $commonOld -DisableNameChecking -Force
        if (Stop-GTViewer) { Step 'Visualiseur en cours arrêté pour la mise à jour.' }
        Remove-Module GitTools.Common -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($p in $parts) {
        $target = Join-Path $Destination $p
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $src $p) -Destination $target -Recurse -Force
    }
    foreach ($f in @('uninstall.ps1', 'install.ps1')) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $Destination -Force }
    if (Test-Path -LiteralPath (Join-Path $src 'docs')) {
        Copy-Item -LiteralPath (Join-Path $src 'docs') -Destination $Destination -Recurse -Force
    }
}
Step "Fichiers installés dans $Destination"

Import-Module (Join-Path $Destination 'common\GitTools.Common.psm1') -DisableNameChecking -Force
$data = Get-GTDataDir
Step "Données utilisateur : $data"

# ---------------------------------------------------------------- commandes (TR-01, TR-03)
function Set-GitAlias([string] $Name, [string] $Ps1) {
    # Passage par Invoke-Git : citation maîtrisée, chemins avec espaces corrects sous PowerShell 5.1 (ENF-14).
    $psExe = (Get-GTPowerShellExe).Replace('\', '/')
    $value = '!"' + $psExe + '" -NoProfile -NoLogo -File "' + $Ps1.Replace('\', '/') + '"'
    $cur = Get-GitValue $env:USERPROFILE @('config', '--global', '--get', "alias.$Name")
    if ($cur -and $cur -notmatch "git-$Name\.ps1") {
        Write-Host "  ! L'alias git « $Name » existe déjà et n'appartient pas à git-tools : il n'est pas modifié. Utilisez « git-$Name »." -ForegroundColor Yellow
        return
    }
    [void](Invoke-Git $env:USERPROFILE @('config', '--global', "alias.$Name", $value))
}

$installed = @()
if ($parts -contains 'autosave') {
    $dir = Join-Path $Destination 'autosave'
    [void](Add-GTUserPath $dir)
    Set-GitAlias 'autosave' (Join-Path $dir 'git-autosave.ps1')
    Import-Module (Join-Path $dir 'GitAutosave.psm1') -DisableNameChecking -Force
    try {
        Register-AutosaveTask
        $sched = Get-AutosaveSchedule
        $first = if ($sched.NextRun) { " (premier passage à $($sched.NextRun.ToString('HH:mm')))" } else { '' }
        Step "Sauvegarde périodique toutes les $($sched.IntervalMin) min$first."
    } catch {
        Write-Host "  ! Tâche planifiée impossible à créer : $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    La sauvegarde reste utilisable avec « git autosave run ». Voir le guide, « Dépannage ».' -ForegroundColor Yellow
    }
    # TR-06 : remettre à jour les hooks des projets déjà suivis (nouveau chemin éventuel)
    $n = 0
    foreach ($p in Get-GTProjects) {
        if (Test-Path -LiteralPath $p) { try { if ((Install-AutosaveHook $p) -ne 'existing') { $n++ } } catch { } }
    }
    $count = @(Get-GTProjects).Count
    Step "Commande « git autosave » prête ($count projet(s) suivi(s), $n hook(s) à jour)."
    $installed += 'autosave'
}
if ($parts -contains 'viewer') {
    $dir = Join-Path $Destination 'viewer'
    [void](Add-GTUserPath $dir)
    Set-GitAlias 'viewer' (Join-Path $dir 'git-viewer.ps1')
    Step 'Commande « git viewer » prête.'
    $installed += 'viewer'
}

# Manifeste pour la désinstallation (TR-07) : fusion avec une installation précédente.
$manifestFile = Join-Path $data 'install.json'
$prev = Read-GTJson $manifestFile
$components = @($installed)
if ($prev -and $prev.components) { $components = @(@($prev.components) + $installed | Select-Object -Unique) }
Write-GTJson $manifestFile ([ordered]@{
    destination = $Destination
    components  = $components
    date        = (Get-Date).ToString('o')
    version     = '1.0.0'
})

$secs = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
Write-Host "git-tools est installé ($secs s)." -ForegroundColor Green
Write-Host 'Ouvrez un NOUVEAU terminal, puis dans un projet :'
if ($installed -contains 'autosave') { Write-Host '    git autosave add      suivre ce projet' }
if ($installed -contains 'viewer') { Write-Host '    git viewer            ouvrir le visualiseur' }
