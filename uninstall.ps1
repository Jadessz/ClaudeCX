#Requires -Version 7.2
<#
.SYNOPSIS
Removes the ClaudeCX skill from Codex.

.DESCRIPTION
Targets only <CodexHome>\skills\claudecx, where Codex home is resolved from
-CodexHome, then CODEX_HOME, then %USERPROFILE%\.codex. By default the skill is
moved to a timestamped backup under <CodexHome>\claudecx-backups so it can be
restored. -Permanent deletes it instead.

Handoff logs under %LOCALAPPDATA%\CodexClaude\handoffs, Claude settings, and
other Codex skills are never touched.

Without -Yes the script asks for confirmation, which fails in non-interactive
sessions. Pass -Yes to confirm non-interactively.

.EXAMPLE
pwsh -NoProfile -File .\uninstall.ps1 -Yes

.EXAMPLE
pwsh -NoProfile -File .\uninstall.ps1 -Yes -Permanent
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Codex home directory. Defaults to CODEX_HOME, then %USERPROFILE%\.codex.
    [string]$CodexHome,

    # Confirm removal without prompting.
    [switch]$Yes,

    # Delete the skill instead of moving it to a recoverable backup.
    [switch]$Permanent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'scripts\ClaudeCX.Common.psm1') -Force

$skillName = Get-ClaudeCXSkillName
$codexHomeFull = Resolve-ClaudeCXCodexHome -CodexHome $CodexHome
$destination = Join-Path (Join-Path $codexHomeFull 'skills') $skillName

if (-not (Test-Path -LiteralPath $destination)) {
    Write-Host "ClaudeCX is not installed at $destination; nothing to remove."
    return
}
if (Test-ClaudeCXReparsePoint -Path $destination) {
    throw "Refusing to remove a symbolic link or junction automatically: $destination"
}
if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    throw "Refusing to remove a non-directory at the skill location: $destination"
}
$skillFile = Join-Path $destination 'SKILL.md'
$frontMatter = if (Test-Path -LiteralPath $skillFile -PathType Leaf) { Get-ClaudeCXFrontMatter -Path $skillFile } else { $null }
if ($null -eq $frontMatter -or -not $frontMatter.Contains('name') -or [string]$frontMatter['name'] -cne $skillName) {
    throw "The directory at $destination does not look like the ClaudeCX skill; refusing to remove it."
}

$action = if ($Permanent) { 'Permanently delete' } else { 'Move to a recoverable backup' }
if (-not $Yes) {
    $confirmed = $false
    try {
        $confirmed = $PSCmdlet.ShouldContinue("$action the ClaudeCX skill at ${destination}?", 'Uninstall ClaudeCX')
    }
    catch {
        throw "Confirmation is required. Re-run with -Yes to uninstall non-interactively. ($($_.Exception.Message))"
    }
    if (-not $confirmed) {
        Write-Host 'Uninstall cancelled.'
        return
    }
}

if (-not $PSCmdlet.ShouldProcess($destination, $action)) {
    return
}

if ($Permanent) {
    Remove-Item -LiteralPath $destination -Recurse -Force
    Write-Host "Permanently removed ClaudeCX from $destination"
}
else {
    $backupPath = New-ClaudeCXUniquePath -Parent (Get-ClaudeCXBackupRoot -CodexHome $codexHomeFull) -Prefix 'uninstalled'
    Move-Item -LiteralPath $destination -Destination $backupPath
    Write-Host "Moved ClaudeCX from $destination to $backupPath"
    Write-Host "To restore it, move that folder back to $destination"
}
Write-Host 'Handoff logs and Claude settings were not changed. Restart Codex to refresh its skill list.'
