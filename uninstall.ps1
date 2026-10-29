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
    $cur = & git config --global --get "alias.$Name" 2>$null
    if ($cur -and $cur -match 'git-tools') { & git config --global --unset "alias.$Name" }
}

if ($remove -contains 'viewer') {
    if (Stop-GTViewer) { Step 'Visualiseur arrêté.' }
    [void](Remove-GTUserPath (Join-Path $dest 'viewer'))
    Remove-GitAlias 'viewer'
    Step 'Commande « git viewer » retirée.'
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
if ($left.Count) {
    foreach ($c in $remove) {
        $d = Join-Path $dest $c
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    Write-GTJson $manifestFile ([ordered]@{ destination = $dest; components = $left; date = (Get-Date).ToString('o'); version = '1.0.0' })
} else {
    Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
    $inside = $PSScriptRoot.StartsWith($dest, [StringComparison]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $dest) {
        if ($inside) {
            # Le script tourne depuis le dossier installé : suppression différée une fois PowerShell terminé.
            $cmd = "ping -n 3 127.0.0.1 >nul & rmdir /s /q `"$dest`""
            Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmd" -WindowStyle Hidden
        } else {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
    }
    Step "Programme retiré de $dest."
}

Write-Host ''
Write-Host 'git-tools est désinstallé.' -ForegroundColor Green
Write-Host "Conservés (TR-08) : la liste des projets et le journal dans $data, et les points de reprise dans chaque projet (refs/autosave)."
Write-Host "Pour tout effacer : supprimez ce dossier et, dans chaque projet, « git for-each-ref --format='delete %(refname)' refs/autosave/ | git update-ref --stdin »."
