#Requires -Version 7.2
<#
.SYNOPSIS
Read-only ClaudeCX progress monitor.

.DESCRIPTION
Tails the human-readable progress log written by invoke-claude.ps1 and exits when
the bridge writes its completion marker or the bridge process disappears. It never
has a handle to Claude's standard input, so nothing typed here reaches Claude.
Closing this window does not stop or fail the Claude run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProgressPath,

    [Parameter(Mandatory = $true)]
    [string]$DonePath,

    [string]$Title = 'ClaudeCX',

    [string]$RepositoryName = '',

    [string]$SessionId = '',

    [int]$BridgeProcessId = 0,

    [ValidateRange(0, 3600)]
    [int]$SuccessCloseSeconds = 5,

    [ValidateRange(0, 86400)]
    [int]$FailureCloseSeconds = 300,

    [ValidateRange(50, 5000)]
    [int]$PollMilliseconds = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$controlPattern = [Regex]::new('\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)?|[@-Z\\-_])|[\p{Cc}\p{Cf}  ]')

function Get-DisplayText {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxLength = 400)

    if ($null -eq $Text) { return '' }
    $value = $controlPattern.Replace($Text, ' ').TrimEnd()
    if ($value.Length -gt $MaxLength) {
        $value = $value.Substring(0, $MaxLength - 3) + '...'
    }
    return $value
}

function Write-ProgressLine {
    param([string]$Line)

    $display = Get-DisplayText -Text $Line
    if (-not $display) { return }
    $color = if ($display -match '(?i)\b(error|failed|denied|timeout)\b') { 'Red' }
    elseif ($display -match '(?i)finished successfully|finished: success') { 'Green' }
    else { 'Gray' }
    Write-Host $display -ForegroundColor $color
}

function Test-KeyPressed {
    try {
        if ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
            return $true
        }
    }
    catch { }
    return $false
}

function Test-BridgeAlive {
    if ($BridgeProcessId -le 0) { return $true }
    return $null -ne (Get-Process -Id $BridgeProcessId -ErrorAction SilentlyContinue)
}

try { $Host.UI.RawUI.WindowTitle = Get-DisplayText -Text $Title -MaxLength 120 } catch { }

Write-Host (Get-DisplayText -Text $Title -MaxLength 120) -ForegroundColor Cyan
if ($RepositoryName) { Write-Host "Repository: $(Get-DisplayText -Text $RepositoryName -MaxLength 120)" }
if ($SessionId) { Write-Host "Session:    $(Get-DisplayText -Text $SessionId -MaxLength 60)" }
Write-Host 'Read-only progress view. Typing here is not sent to Claude. Closing this window does not stop the run.' -ForegroundColor DarkGray
Write-Host ''

$reader = $null
$pending = [Text.StringBuilder]::new()
$buffer = [char[]]::new(4096)

function Read-NewProgress {
    if ($null -eq $script:reader) {
        if (-not (Test-Path -LiteralPath $ProgressPath -PathType Leaf)) { return }
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($ProgressPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $script:reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
    }
    while (($count = $script:reader.Read($script:buffer, 0, $script:buffer.Length)) -gt 0) {
        $null = $script:pending.Append($script:buffer, 0, $count)
    }
    $text = $script:pending.ToString()
    $lastBreak = $text.LastIndexOf("`n")
    if ($lastBreak -lt 0) { return }
    foreach ($line in $text.Substring(0, $lastBreak).Split("`n")) {
        Write-ProgressLine -Line $line
    }
    $null = $script:pending.Clear().Append($text.Substring($lastBreak + 1))
}

$status = $null
$message = ''
try {
    while ($true) {
        Read-NewProgress
        if (Test-Path -LiteralPath $DonePath -PathType Leaf) {
            Start-Sleep -Milliseconds 100
            Read-NewProgress
            try {
                $marker = Get-Content -Raw -LiteralPath $DonePath | ConvertFrom-Json
                $status = [string]$marker.status
                $message = [string]$marker.message
            }
            catch {
                $status = 'failed'
                $message = 'The completion marker could not be read.'
            }
            break
        }
        if (-not (Test-BridgeAlive)) {
            Start-Sleep -Milliseconds 200
            if (Test-Path -LiteralPath $DonePath -PathType Leaf) { continue }
            Read-NewProgress
            $status = 'failed'
            $message = 'The bridge process exited without signalling completion.'
            break
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    if ($script:pending.Length -gt 0) {
        Write-ProgressLine -Line $script:pending.ToString()
    }
}
finally {
    if ($null -ne $script:reader) { $script:reader.Dispose() }
}

Write-Host ''
if ($status -eq 'success') {
    Write-Host 'ClaudeCX run complete. Codex is reviewing the result.' -ForegroundColor Green
    $wait = $SuccessCloseSeconds
}
else {
    Write-Host "ClaudeCX run FAILED: $(Get-DisplayText -Text $message -MaxLength 500)" -ForegroundColor Red
    $wait = $FailureCloseSeconds
}
if ($wait -gt 0) {
    Write-Host "This window closes in $wait seconds. Press any key to close it now." -ForegroundColor DarkGray
    $deadline = [DateTime]::UtcNow.AddSeconds($wait)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-KeyPressed) { break }
        Start-Sleep -Milliseconds 200
    }
}
exit $(if ($status -eq 'success') { 0 } else { 1 })
