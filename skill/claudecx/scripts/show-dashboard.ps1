#Requires -Version 7.2
<#
.SYNOPSIS
Local ClaudeCX dashboard server (loopback only).

.DESCRIPTION
Serves the packaged dashboard and a fixed, token-protected API for one bridge turn on
127.0.0.1 with an OS-assigned port. The access token is read from the
CLAUDECX_DASHBOARD_TOKEN environment variable and removed from the environment at once.
Readiness is reported by writing dashboard-endpoint.json (port and PID only) into the
turn directory. The server exits when the bridge disappears without completing, after a
bounded interval once the run has completed, or at its maximum lifetime. Closing the
browser never stops Claude; only POST /api/stop asks the bridge to stop.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MetadataPath,

    [ValidateRange(60, 172800)]
    [int]$MaxLifetimeSeconds = 7200,

    # How long the server stays up after the run completes.
    [ValidateRange(1, 86400)]
    [int]$CompletionLingerSeconds = 900,

    # After completion, exit sooner if the browser stops polling for this long.
    [ValidateRange(1, 86400)]
    [int]$CompletionIdleSeconds = 180,

    # Exit this long after the bridge disappears without a completion marker.
    [ValidateRange(0, 600)]
    [int]$OrphanGraceSeconds = 3,

    [ValidateRange(1024, 67108864)]
    [int]$MaxDiffBytes = 2097152
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Dashboard.psm1') -Force

$tokenVariable = Get-ClaudeCXDashboardTokenVariable
$token = [Environment]::GetEnvironmentVariable($tokenVariable)
[Environment]::SetEnvironmentVariable($tokenVariable, [NullString]::Value)
if (-not $token -or $token.Length -lt 43) {
    [Console]::Error.WriteLine('ClaudeCX dashboard: no valid access token was provided.')
    exit 2
}

$metadata = Read-ClaudeCXDashboardMetadata -MetadataPath $MetadataPath
$paths = Get-ClaudeCXDashboardPaths -TurnDirectory ([string]$metadata.run_directory)
$assetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dashboard'))
foreach ($asset in @('index.html', 'styles.css', 'app.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $assetRoot $asset) -PathType Leaf)) {
        [Console]::Error.WriteLine("ClaudeCX dashboard: packaged asset is missing: $asset")
        exit 2
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Server.ExclusiveAddressUse = $true
try {
    $listener.Start(16)
}
catch {
    [Console]::Error.WriteLine("ClaudeCX dashboard: could not listen on 127.0.0.1 ($($_.Exception.Message)).")
    exit 3
}
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$context = New-ClaudeCXDashboardContext -Metadata $metadata -Token $token -AssetRoot $assetRoot -Port $port -MaxDiffBytes $MaxDiffBytes
$token = $null

$endpoint = [ordered]@{
    port = $port
    pid = $PID
    started_at = [DateTimeOffset]::Now.ToString('o')
} | ConvertTo-Json -Compress
Write-ClaudeCXAtomicFile -Path $paths.Endpoint -Content $endpoint

$lifetime = [Diagnostics.Stopwatch]::StartNew()
$completedAt = $null
$orphanedAt = $null
$nextCheck = [TimeSpan]::Zero
$exitReason = 'lifetime'
try {
    while ($lifetime.Elapsed.TotalSeconds -lt $MaxLifetimeSeconds) {
        if ($lifetime.Elapsed -ge $nextCheck) {
            $nextCheck = $lifetime.Elapsed.Add([TimeSpan]::FromMilliseconds(500))
            $now = [DateTimeOffset]::UtcNow
            if ($null -eq $completedAt -and [IO.File]::Exists($paths.Done)) {
                $completedAt = $now
            }
            if ($null -ne $completedAt) {
                $sinceDone = ($now - $completedAt).TotalSeconds
                $sinceApi = ($now - $context.LastApiRequest).TotalSeconds
                if ($sinceDone -ge $CompletionLingerSeconds -or ($sinceDone -ge $CompletionIdleSeconds -and $sinceApi -ge $CompletionIdleSeconds)) {
                    $exitReason = 'completed'
                    break
                }
            }
            elseif (-not (Test-ClaudeCXBridgeAlive -Metadata $metadata)) {
                if ($null -eq $orphanedAt) { $orphanedAt = $now }
                if (($now - $orphanedAt).TotalSeconds -ge $OrphanGraceSeconds) {
                    $exitReason = 'bridge-gone'
                    break
                }
            }
        }
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 25
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            Invoke-ClaudeCXDashboardConnection -Client $client -Context $context
        }
        catch { }
        finally {
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
    try { Remove-Item -LiteralPath $paths.Endpoint -Force -ErrorAction SilentlyContinue } catch { }
}
[Console]::Error.WriteLine("ClaudeCX dashboard stopped ($exitReason).")
exit 0
