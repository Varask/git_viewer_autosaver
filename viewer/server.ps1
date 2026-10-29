<#
  git-tools — serveur du visualiseur (lot L5). Lancé caché par git-viewer.ps1, jamais directement.
  Écoute 127.0.0.1 uniquement (ADR-08), instance unique (ADR-09), requêtes en parallèle (pool de runspaces).
  Ce fichier doit rester en UTF-8 avec BOM.
#>
param(
    [string] $Project = '',
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'GitViewer.psm1'
Import-Module $module -DisableNameChecking

# ---------------------------------------------------------------- instance unique
$mutex = New-Object System.Threading.Mutex($false, 'Local\git-tools-viewer')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

$lockFile = Join-Path (Get-GTDataDir) 'viewer.lock'
$listener = $null
$pool = $null
$jobs = New-Object System.Collections.ArrayList
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })

    $Shared = [hashtable]::Synchronized(@{
        token       = $token
        port        = $port
        project     = ''
        projectSeq  = 1
        lastSeen    = [datetime]::MinValue
        lastTabOpen = [datetime]::MinValue
        presence    = 0
        stop        = $false
        noBrowser   = ([bool]$NoBrowser -or $env:GITTOOLS_NOBROWSER -eq '1')   # tests automatisés
    })

    # Projet initial : celui demandé, sinon le dernier consulté (VI-33).
    $root = $null
    if ($Project) { try { $root = Resolve-ViewerProject $Project } catch { } }
    if (-not $root) { $root = Get-ViewerLastProject }
    if ($root) { [void](Set-ViewerProject $root $Shared) }

    Write-GTJson $lockFile ([ordered]@{ port = $port; pid = $PID; token = $token; started = (Get-Date).ToString('o') })
    Write-GTLog viewer INFO '' "Visualiseur démarré sur 127.0.0.1:$port (PID $PID)."

    # ---------------------------------------------------------------- pool de traitement
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule(@($module))
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('GTShared', $Shared, '')))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 10, $iss, $Host)
    $pool.Open()

    $handler = {
        param($Client)
        $S = $GTShared
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $reasons = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed';
                      409 = 'Conflict'; 500 = 'Internal Server Error'; 503 = 'Service Unavailable' }
        try {
            $Client.ReceiveTimeout = 10000
            $Client.SendTimeout = 10000
            $stream = $Client.GetStream()

            # --- lecture des en-têtes
            $ms = New-Object System.IO.MemoryStream
            $chunk = New-Object byte[] 8192
            $sep = -1
            while ($sep -lt 0) {
                $n = $stream.Read($chunk, 0, $chunk.Length)
                if ($n -le 0) { return }
                $ms.Write($chunk, 0, $n)
                $ascii = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
                $sep = $ascii.IndexOf("`r`n`r`n")
                if ($sep -lt 0 -and $ms.Length -gt 65536) { return }
            }
            $lines = $ascii.Substring(0, $sep).Split(@("`r`n"), [System.StringSplitOptions]::None)
            $first = $lines[0].Split(' ')
            if ($first.Count -lt 3) { return }
            $method = $first[0].ToUpperInvariant()
            $target = $first[1]
            $headers = @{}
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $c = $lines[$i].IndexOf(':')
                if ($c -gt 0) { $headers[$lines[$i].Substring(0, $c).Trim().ToLowerInvariant()] = $lines[$i].Substring($c + 1).Trim() }
            }
            $qi = $target.IndexOf('?')
            $path = if ($qi -ge 0) { $target.Substring(0, $qi) } else { $target }
            $query = if ($qi -ge 0) { $target.Substring($qi + 1) } else { '' }

            # --- corps
            $len = 0
            [void][int]::TryParse([string]$headers['content-length'], [ref]$len)
            if ($len -gt 1MB) { return }
            $all = $ms.ToArray()
            $bodyBytes = New-Object System.IO.MemoryStream
            $bodyBytes.Write($all, $sep + 4, $all.Length - $sep - 4)
            while ($bodyBytes.Length -lt $len) {
                $n = $stream.Read($chunk, 0, $chunk.Length)
                if ($n -le 0) { break }
                $bodyBytes.Write($chunk, 0, $n)
            }
            $body = $utf8.GetString($bodyBytes.ToArray(), 0, [math]::Min($len, [int]$bodyBytes.Length))

            # --- flux de présence (onglet ouvert) : EventSource ne permet pas d'en-tête, jeton en paramètre
            if ($method -eq 'GET' -and $path -eq '/api/presence') {
                $q = @{}
                foreach ($pair in $query.Split('&')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $q[$kv[0]] = [System.Uri]::UnescapeDataString($kv[1]) } }
                $hostOk = ($headers['host'] -eq "127.0.0.1:$($S.port)" -or $headers['host'] -eq "localhost:$($S.port)")
                $site = [string]$headers['sec-fetch-site']
                if (-not $hostOk -or $q['t'] -ne $S.token -or ($site -and $site -notin @('same-origin', 'none'))) {
                    $b = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($b, 0, $b.Length); return
                }
                if ([int]$S.presence -ge 6) {
                    $b = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 503 Service Unavailable`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($b, 0, $b.Length); return
                }
                [System.Threading.Monitor]::Enter($S.SyncRoot); try { $S.presence = [int]$S.presence + 1 } finally { [System.Threading.Monitor]::Exit($S.SyncRoot) }
                try {
                    $b = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nCache-Control: no-store`r`nConnection: keep-alive`r`n`r`nretry: 2000`n`n")
                    $stream.Write($b, 0, $b.Length); $stream.Flush()
                    $seq = -1; $tick = 0
                    while (-not $S.stop) {
                        if ([int]$S.projectSeq -ne $seq) {
                            $seq = [int]$S.projectSeq
                            $b = $utf8.GetBytes("event: project`ndata: $seq`n`n")
                            $stream.Write($b, 0, $b.Length); $stream.Flush()
                        }
                        if ($tick % 10 -eq 0) { $b = [System.Text.Encoding]::ASCII.GetBytes(": ping`n`n"); $stream.Write($b, 0, $b.Length); $stream.Flush() }
                        $tick++
                        Start-Sleep -Milliseconds 500
                    }
                } catch { } finally {
                    [System.Threading.Monitor]::Enter($S.SyncRoot); try { $S.presence = [int]$S.presence - 1 } finally { [System.Threading.Monitor]::Exit($S.SyncRoot) }
                }
                return
            }

            # --- requête ordinaire
            $req = @{ method = $method; path = $path; query = $query; headers = $headers; body = $body }
            $resp = Invoke-ViewerRequest -Request $req -Shared $S
            $status = [int]$resp.status
            $reason = if ($reasons.ContainsKey($status)) { $reasons[$status] } else { 'OK' }
            $hdr = "HTTP/1.1 $status $reason`r`nContent-Type: $($resp.type)`r`nContent-Length: $($resp.body.Length)`r`n" +
                   "Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`n" +
                   "X-Frame-Options: DENY`r`nCross-Origin-Resource-Policy: same-origin`r`n"
            if ($resp.type -like 'text/html*') {
                $hdr += "Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`r`n"
            }
            $hdr += "Connection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
            $stream.Write($hb, 0, $hb.Length)
            if ($resp.body.Length) { $stream.Write($resp.body, 0, $resp.body.Length) }
            $stream.Flush()
        } catch {
            try { Write-GTLog viewer ERROR '' "Requête : $($_.Exception.Message)" } catch { }
        } finally {
            $Client.Close()
        }
    }.ToString()

    # ---------------------------------------------------------------- boucle principale
    while (-not $Shared.stop) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($handler).AddArgument($client)
            [void]$jobs.Add(@{ ps = $ps; handle = $ps.BeginInvoke() })
        } else {
            Start-Sleep -Milliseconds 15
        }
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            $j = $jobs[$i]
            if ($j.handle.IsCompleted) {
                try { [void]$j.ps.EndInvoke($j.handle) } catch { Write-GTLog viewer ERROR '' $_.Exception.Message }
                $j.ps.Dispose()
                $jobs.RemoveAt($i)
            }
        }
    }
    Write-GTLog viewer INFO '' 'Visualiseur arrêté.'
} catch {
    Write-GTLog viewer ERROR '' "Arrêt sur erreur : $($_.Exception.Message)"
} finally {
    if ($listener) { $listener.Stop() }
    $deadline = (Get-Date).AddSeconds(3)
    foreach ($j in $jobs) {
        while (-not $j.handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        try { $j.ps.Stop(); $j.ps.Dispose() } catch { }
    }
    if ($pool) { $pool.Close() }
    $lock = Read-GTJson $lockFile
    if ($lock -and [int]$lock.pid -eq $PID) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit 0
