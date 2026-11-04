<#
  git-tools — désinstallation (lot L4). TR-07, TR-08, R-17.
  Retire tout ce que l'installation a ajouté. CONSERVE la liste des projets et les points de reprise.

    .\uninstall.ps1                  les deux outils
    .\uninstall.ps1 -Only autosave   la sauvegarde seule
    .\uninstall.ps1 -Only viewer     le visualiseur seul

  Ce fichier doit rester en UTF-8 avec BOM.
#>
param([ValidateSet('all', 'autosave', 'viewer')] [string] $Only = 'all')

$ErrorActionPreference = 'Stop'
function Step([string] $t) { Write-Host "  • $t" }

Import-Module (Join-Path $PSScriptRoot 'common\GitTools.Common.psm1') -DisableNameChecking -Force
$data = Get-GTDataDir
$manifestFile = Join-Path $data 'install.json'
$manifest = Read-GTJson $manifestFile
$dest = if ($manifest -and $manifest.destination) { [string]$manifest.destination } else { $PSScriptRoot }
$components = if ($manifest -and $manifest.components) { @($manifest.components) } else { @('autosave', 'viewer') }
$remove = if ($Only -eq 'all') { @('autosave', 'viewer') } else { @($Only) }

Write-Host 'Désinstallation de git-tools'

function Remove-GitAlias([string] $Name) {
    $cur = Get-GitValue $env:USERPROFILE @('config', '--global', '--get', "alias.$Name")
    if ($cur -and $cur -match "git-$Name\.ps1") { [void](Invoke-Git $env:USERPROFILE @('config', '--global', '--unset', "alias.$Name") -AllowFail) }
}

function Remove-Installed([string] $Dir, [string[]] $Names) {
    # Ne supprime que les éléments posés par install.ps1, jamais le dossier entier s'il contient autre chose.
    foreach ($n in $Names) {
        $x = Join-Path $Dir $n
        if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force }
    }
}

if ($remove -contains 'viewer') {
    if (Stop-GTViewer) { Step 'Visualiseur arrêté.' }
    [void](Remove-GTUserPath (Join-Path $dest 'viewer'))
    Remove-GitAlias 'viewer'
    Step 'Commande « git viewer » retirée.'
    if (Uninstall-GTShellMenu) { Step 'Entrée « Ouvrir dans git viewer » retirée du clic droit.' }
    if (Uninstall-GTStartMenu) { Step 'Raccourci « git viewer » retiré du menu Démarrer.' }
}

if ($remove -contains 'autosave') {
    $mod = Join-Path $dest 'autosave\GitAutosave.psm1'
    if (-not (Test-Path -LiteralPath $mod)) { $mod = Join-Path $PSScriptRoot 'autosave\GitAutosave.psm1' }
    if (Test-Path -LiteralPath $mod) {
        Import-Module $mod -DisableNameChecking -Force
        if (Unregister-AutosaveTask) { Step 'Sauvegarde périodique retirée.' }
        $n = 0
        foreach ($p in Get-GTProjects) {
            if (Test-Path -LiteralPath $p) { try { if (Uninstall-AutosaveHook $p) { $n++ } } catch { } }
        }
        Step "$n hook(s) post-commit retiré(s) (les hooks d'autres outils sont laissés intacts)."
    }
    [void](Remove-GTUserPath (Join-Path $dest 'autosave'))
    Remove-GitAlias 'autosave'
    Step 'Commande « git autosave » retirée.'
}

$left = @($components | Where-Object { $_ -notin $remove })
$sourceRun = [string]::Equals([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'), [IO.Path]::GetFullPath($dest).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
# Un dossier source (dépôt de développement, avec tests/ ou .git) n'est jamais supprimé.
$isSourceTree = (Test-Path -LiteralPath (Join-Path $dest 'tests')) -or (Test-Path -LiteralPath (Join-Path $dest '.git'))
$installedHere = (Split-Path -Leaf $dest) -eq 'git-tools' -and (Test-Path -LiteralPath (Join-Path $dest 'install.ps1')) -and -not $isSourceTree
if ($left.Count) {
    if ($installedHere) { Remove-Installed $dest $remove }
    Write-GTJson $manifestFile ([ordered]@{ destination = $dest; components = $left; date = (Get-Date).ToString('o'); version = $(if ($manifest -and $manifest.version) { [string]$manifest.version } else { 'dev' }) })
} else {
    Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
    if ($installedHere -and -not $sourceRun) {
        Remove-Installed $dest @('common', 'autosave', 'viewer', 'docs', 'install.ps1', 'uninstall.ps1', 'VERSION')
        if (-not (Get-ChildItem -LiteralPath $dest -Force)) { Remove-Item -LiteralPath $dest -Force }
        Step "Programme retiré de $dest."
    } elseif ($installedHere) {
        # Le script tourne depuis le dossier installé : suppression différée, limitée aux éléments installés.
        $sys = Join-Path $env:SystemRoot 'System32'
        $items = @('common', 'autosave', 'viewer', 'docs') | ForEach-Object { "rmdir /s /q `"$(Join-Path $dest $_)`"" }
        $cmd = "`"$sys\PING.EXE`" -n 3 127.0.0.1 >nul & " + ($items -join ' & ') +
               " & del /q `"$(Join-Path $dest 'install.ps1')`" `"$(Join-Path $dest 'uninstall.ps1')`" `"$(Join-Path $dest 'VERSION')`" & rmdir `"$dest`""
        Start-Process -FilePath (Join-Path $sys 'cmd.exe') -ArgumentList "/c $cmd" -WindowStyle Hidden -WorkingDirectory $env:SystemRoot
        Step "Programme retiré de $dest (dans quelques secondes)."
    } else {
        Step "Dossier $dest laissé en place : il ne ressemble pas à une installation de git-tools."
    }
}

Write-Host ''
Write-Host 'git-tools est désinstallé.' -ForegroundColor Green
Write-Host "Conservés (TR-08) : la liste des projets et le journal dans $data, et les points de reprise dans chaque projet (refs/autosave)."
Write-Host "Pour tout effacer : supprimez ce dossier et, dans chaque projet, « git for-each-ref --format='delete %(refname)' refs/autosave/ | git update-ref --stdin »."
