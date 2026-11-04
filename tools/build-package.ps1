<#
  git-tools — construction du paquet de distribution (lot L10).

      .\tools\build-package.ps1 -Version 1.1.0      →  dist\git-tools-1.1.0.zip  et  .zip.sha256

  Lancé par la CI (.github/workflows/ci.yml) à chaque étiquette vX.Y.Z ; utilisable à la main sous
  Windows PowerShell 5.1. Le zip contient un dossier git-tools-<version> : « Extraire tout », puis
  double-clic sur install.cmd. Ni tests, ni documents de conception dans le paquet.
  Ce fichier doit rester en UTF-8 avec BOM.
#>
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')] [string] $Version,
    [string] $OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$name = "git-tools-$Version"
$stage = Join-Path ([IO.Path]::GetTempPath()) ("$name-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$pkg = Join-Path $stage $name
$utf8 = New-Object System.Text.UTF8Encoding($false)

$items = @('install.cmd', 'install.ps1', 'uninstall.ps1', 'README.md', 'common', 'autosave', 'viewer')
$docs = @('GUIDE.md', 'NOTE-DSI.md')

try {
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    foreach ($i in $items) {
        $src = Join-Path $root $i
        if (-not (Test-Path -LiteralPath $src)) { throw "Élément manquant dans le dépôt : $i" }
        Copy-Item -LiteralPath $src -Destination $pkg -Recurse
    }
    New-Item -ItemType Directory -Path (Join-Path $pkg 'docs') | Out-Null
    foreach ($d in $docs) { Copy-Item -LiteralPath (Join-Path $root "docs\$d") -Destination (Join-Path $pkg 'docs') }
    [IO.File]::WriteAllText((Join-Path $pkg 'VERSION'), $Version, $utf8)

    # Contrôles avant publication : BOM des scripts (accents sous PowerShell 5.1), CRLF des scripts Windows.
    $files = @(Get-ChildItem -LiteralPath $pkg -Recurse -File)
    $noBom = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Where-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    })
    if ($noBom.Count) { throw "Scripts sans BOM UTF-8 : $(($noBom | ForEach-Object Name) -join ', ')" }
    $lf = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cmd', '.vbs' } | Where-Object {
        [IO.File]::ReadAllText($_.FullName) -match '(?<!\r)\n'
    })
    if ($lf.Count) { throw "Fins de ligne LF au lieu de CRLF : $(($lf | ForEach-Object Name) -join ', ')" }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zip = Join-Path $OutDir "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($pkg, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n", $utf8)
    Write-Host "Paquet   : $zip ($([math]::Round((Get-Item -LiteralPath $zip).Length / 1KB)) Ko, $($files.Count) fichiers)"
    Write-Host "SHA-256  : $hash"
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
