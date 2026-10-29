#Requires -Version 7.2
<#
.SYNOPSIS
Opens the ClaudeCX control center, starting it first if it is not running.

.DESCRIPTION
The control center is a small local web page on 127.0.0.1 that stays up between runs: it shows
the run in progress, every past run, your settings, and setup health. This launcher starts the
hidden server (show-control-center.ps1) when needed and opens the page in your default browser.
The Start menu shortcut that install.ps1 creates runs this script.

.EXAMPLE
pwsh -NoProfile -File .\start-control-center.ps1

.EXAMPLE
pwsh -NoProfile -File .\start-control-center.ps1 -NoBrowser

.EXAMPLE
pwsh -NoProfile -File .\start-control-center.ps1 -Stop
#>
[CmdletBinding()]
param(
    # Start the server without opening the browser (used at sign-in).
    [switch]$NoBrowser,

    # Stop the running control center.
    [switch]$Stop,

    # Print whether it is running, as JSON, and change nothing.
    [switch]$Status,

    [ValidateRange(1, 120)]
    [int]$ReadyTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Dashboard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Settings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.ControlCenter.psm1') -Force

$files = Get-ClaudeCXControlCenterPaths
$running = Get-ClaudeCXControlCenter

if ($Status) {
    [ordered]@{ running = ($null -ne $running); port = ${running}?.Port; pid = ${running}?.ProcessId } | ConvertTo-Json -Compress
    exit 0
}

if ($Stop) {
    if ($null -eq $running) {
        Write-Host 'The ClaudeCX control center is not running.'
        exit 0
    }
    try { (Get-Process -Id $running.ProcessId -ErrorAction Stop).Kill($true) } catch { }
    foreach ($path in @($files.Info, $files.Token)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Stopped the ClaudeCX control center.'
    exit 0
}

function Open-CenterPage {
    param([int]$Port)
    $token = [IO.File]::ReadAllText($files.Token).Trim()
    Open-ClaudeCXBrowser -Url "http://127.0.0.1:$Port/#token=$token&view=center"
}

if ($null -ne $running) {
    if (-not $NoBrowser) { Open-CenterPage -Port $running.Port }
    Write-Host "The ClaudeCX control center is running at $($running.Url)"
    exit 0
}

# Start the server hidden, without inherited handles. The token reaches it only through its
# environment and is cleared from this process at once.
$serverScript = Join-Path $PSScriptRoot 'show-control-center.ps1'
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = Get-ClaudeCXPwshPath
$startInfo.UseShellExecute = $true
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
foreach ($argument in @('-NoProfile', '-NoLogo', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $serverScript)) {
    $startInfo.ArgumentList.Add($argument)
}
$tokenVariable = Get-ClaudeCXCenterTokenVariable
[Environment]::SetEnvironmentVariable($tokenVariable, (New-ClaudeCXDashboardToken))
try {
    $server = [Diagnostics.Process]::Start($startInfo)
}
finally {
    [Environment]::SetEnvironmentVariable($tokenVariable, [NullString]::Value)
}
if ($null -eq $server) {
    throw 'The control center server did not start.'
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $running = Get-ClaudeCXControlCenter
    if ($null -ne $running -and $running.ProcessId -eq $server.Id -and [IO.File]::Exists($files.Token)) {
        if (-not $NoBrowser) { Open-CenterPage -Port $running.Port }
        Write-Host "The ClaudeCX control center is running at $($running.Url)"
        exit 0
    }
    if ($server.HasExited) {
        # Another launcher may have won the race; use its instance.
        $running = Get-ClaudeCXControlCenter
        if ($null -ne $running) {
            if (-not $NoBrowser) { Open-CenterPage -Port $running.Port }
            Write-Host "The ClaudeCX control center is running at $($running.Url)"
            exit 0
        }
        throw "The control center server exited during startup (exit code $($server.ExitCode))."
    }
    Start-Sleep -Milliseconds 100
}
try { $server.Kill($true) } catch { }
throw 'The control center server did not report readiness in time.'
