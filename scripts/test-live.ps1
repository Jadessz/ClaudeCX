#Requires -Version 7.2
<#
.SYNOPSIS
Opt-in live smoke test of the ClaudeCX bridge against the real Claude Code CLI.

.DESCRIPTION
WARNING: this contacts Claude and consumes account usage. It runs
skill\claudecx\scripts\test-claude-bridge.ps1, which makes several Claude calls
(initial write, commit-denial probe, resume, forced max-turns failure). The
-MaxBudgetUsd cap is forwarded to, and applies to, each individual Claude call,
so total spend can reach a few multiples of the cap.

The test creates disposable Git repositories under -ScratchRoot, which must not
exist yet and must be outside this repository. Bridge handoff state for those
repositories is written under %LOCALAPPDATA%\CodexClaude\handoffs.

Requires Claude Code to be installed and authenticated (`claude auth status`).

.EXAMPLE
pwsh -NoProfile -File .\scripts\test-live.ps1 -ScratchRoot "$env:TEMP\claudecx-live-1" -AcknowledgeUsage
#>
[CmdletBinding()]
param(
    # Fresh directory for disposable test repositories. Must not exist yet.
    [Parameter(Mandatory = $true)]
    [string]$ScratchRoot,

    # USD budget cap forwarded to each Claude call.
    [ValidateRange(0.01, 20.0)]
    [decimal]$MaxBudgetUsd = 1.00,

    # Required acknowledgement that this test contacts Claude and consumes usage.
    [switch]$AcknowledgeUsage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'test-live.ps1 contacts Claude and consumes account usage.'
Write-Warning "Each Claude call is capped at USD $MaxBudgetUsd; the smoke test makes several calls."

if (-not $AcknowledgeUsage) {
    throw 'Live test not started. Re-run with -AcknowledgeUsage to confirm that contacting Claude and consuming usage is intended.'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratch) {
    throw "ScratchRoot already exists; choose a fresh path: $scratch"
}
$repoPrefix = $repoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($scratch.Equals($repoRoot.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -or
    $scratch.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ScratchRoot must be outside the ClaudeCX repository: $scratch"
}

foreach ($command in @('git', 'claude')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command was not found on PATH."
    }
}

$smokeTest = Join-Path $repoRoot 'skill\claudecx\scripts\test-claude-bridge.ps1'
$arguments = @(
    '-NoProfile', '-File', $smokeTest,
    '-ScratchRoot', $scratch,
    '-MaxBudgetUsd', $MaxBudgetUsd.ToString([Globalization.CultureInfo]::InvariantCulture)
)
& pwsh @arguments
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host "Live bridge smoke test failed (exit code $exitCode). Inspect $scratch and the handoff logs." -ForegroundColor Red
}
exit $exitCode
