#Requires -Version 7.2
<#
.SYNOPSIS
The always-on ClaudeCX control center server (loopback only). Start it with start-control-center.ps1.

.DESCRIPTION
Serves the packaged dashboard in control-center mode on 127.0.0.1 with an OS-assigned port: live
runs, history from every log folder, settings, and setup health. The access token is read from the
CLAUDECX_CENTER_TOKEN environment variable and removed from the environment at once. The port, PID,
and start time go to control-center.json and the token to control-center.token in the ClaudeCX home,
so the launcher can reopen the page later. One instance runs per user. It stops on request from the
page, when its files are replaced by another instance, or when the process is ended.
#>
[CmdletBinding()]
param(
    # Seconds between scans for newly started runs.
    [ValidateRange(1, 60)]
    [int]$ScanSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Dashboard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Settings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.ControlCenter.psm1') -Force

$tokenVariable = Get-ClaudeCXCenterTokenVariable
$token = [Environment]::GetEnvironmentVariable($tokenVariable)
[Environment]::SetEnvironmentVariable($tokenVariable, [NullString]::Value)
if (-not $token -or $token.Length -lt 43) {
    [Console]::Error.WriteLine('ClaudeCX control center: no valid access token was provided.')
    exit 2
}

$files = Get-ClaudeCXControlCenterPaths
$mutex = [Threading.Mutex]::new($false, $files.Mutex)
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    [Console]::Error.WriteLine('ClaudeCX control center: another instance is already running.')
    exit 4
}

$skillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assetRoot = Join-Path $skillRoot 'dashboard'
foreach ($asset in @('index.html', 'styles.css', 'app.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $assetRoot $asset) -PathType Leaf)) {
        [Console]::Error.WriteLine("ClaudeCX control center: packaged asset is missing: $asset")
        exit 2
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Server.ExclusiveAddressUse = $true
try {
    $listener.Start(32)
}
catch {
    [Console]::Error.WriteLine("ClaudeCX control center: could not listen on 127.0.0.1 ($($_.Exception.Message)).")
    exit 3
}
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$context = New-ClaudeCXCenterContext -Token $token -AssetRoot $assetRoot -Port $port -SkillRoot $skillRoot

[IO.Directory]::CreateDirectory((Split-Path -Parent $files.Info)) | Out-Null
$startedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
Write-ClaudeCXAtomicFile -Path $files.Token -Content $token
Write-ClaudeCXAtomicFile -Path $files.Info -Content ([ordered]@{ port = $port; pid = $PID; started_at = $startedAt } | ConvertTo-Json -Compress)
$token = $null

$nextScan = [DateTimeOffset]::MinValue
$exitReason = 'stopped'
try {
    while (-not $context.QuitRequested) {
        $now = [DateTimeOffset]::UtcNow
        if ($now -ge $nextScan) {
            $nextScan = $now.AddSeconds($ScanSeconds)
            # Another instance took over (its files replaced ours): stop quietly.
            $current = Get-ClaudeCXControlCenter
            if ($null -eq $current -or $current.ProcessId -ne $PID) {
                $exitReason = 'replaced'
                break
            }
            try {
                $newRuns = @(Find-ClaudeCXNewRuns -Context $context)
                $settings = Read-ClaudeCXUserSettings
                $pageOpen = ($now - $context.LastApiRequest).TotalSeconds -lt 6
                if ($newRuns.Count -gt 0 -and -not $pageOpen -and $settings.Values['open_center_on_new_run'] -eq $true) {
                    $tokenText = [IO.File]::ReadAllText($files.Token).Trim()
                    Open-ClaudeCXBrowser -Url "http://127.0.0.1:$port/#token=$tokenText&view=center&run=$([Uri]::EscapeDataString([string]$newRuns[0].id))"
                    $context.LastApiRequest = $now
                }
            }
            catch { }
        }
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 25
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            Invoke-ClaudeCXCenterConnection -Client $client -Context $context
        }
        catch { }
        finally {
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
    $current = $null
    try { $current = [IO.File]::ReadAllText($files.Info) | ConvertFrom-Json } catch { }
    if ($null -ne $current -and [int]$current.pid -eq $PID) {
        Remove-Item -LiteralPath $files.Info -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $files.Token -Force -ErrorAction SilentlyContinue
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
[Console]::Error.WriteLine("ClaudeCX control center stopped ($exitReason).")
exit 0
