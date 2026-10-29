# git-tools — sélecteur de dossier (VI-32). Lancé en STA par le serveur ; écrit le chemin choisi sur la sortie.
# Ce fichier doit rester en UTF-8 avec BOM.
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.StartPosition = 'CenterScreen'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Opacity = 0
$owner.Show()
$owner.Activate()
$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
$dlg.Description = 'Choisir le dossier d''un projet git'
$dlg.ShowNewFolderButton = $false
$result = $dlg.ShowDialog($owner)
$owner.Close()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    $out = [Console]::OpenStandardOutput()
    $b = (New-Object System.Text.UTF8Encoding($false)).GetBytes($dlg.SelectedPath)
    $out.Write($b, 0, $b.Length)
    $out.Flush()
}
