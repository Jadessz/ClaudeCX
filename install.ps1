#Requires -Version 7.2
<#
.SYNOPSIS
Installs the ClaudeCX skill into Codex.

.DESCRIPTION
Validates the packaged skill under skill\claudecx, then copies it to
<CodexHome>\skills\claudecx. Codex home is resolved from -CodexHome, then the
CODEX_HOME environment variable, then %USERPROFILE%\.codex.

An existing installation is never overwritten unless -Force is supplied. With
-Force, the existing copy is first moved to a timestamped backup under
<CodexHome>\claudecx-backups.

-DisableClaudeAttribution optionally sets attribution.commit, attribution.pr, and
attribution.sessionUrl in a Claude settings file (default: the global
%USERPROFILE%\.claude\settings.json, or CLAUDE_CONFIG_DIR\settings.json) while
preserving every other key. The original file is backed up first. Claude settings
are never changed unless this switch is supplied.

.EXAMPLE
pwsh -NoProfile -File .\install.ps1

.EXAMPLE
pwsh -NoProfile -File .\install.ps1 -Force

.EXAMPLE
pwsh -NoProfile -File .\install.ps1 -DisableClaudeAttribution
#>
[CmdletBinding()]
param(
    # Codex home directory. Defaults to CODEX_HOME, then %USERPROFILE%\.codex.
    [string]$CodexHome,

    # Replace an existing installation after backing it up.
    [switch]$Force,

    # Disable Claude commit/PR/session attribution in a Claude settings file.
    [switch]$DisableClaudeAttribution,

    # Claude settings file used with -DisableClaudeAttribution.
    [string]$ClaudeSettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'ClaudeCX requires PowerShell 7.2 or later (pwsh).'
}
if ($ClaudeSettingsPath -and -not $DisableClaudeAttribution) {
    throw '-ClaudeSettingsPath is only used together with -DisableClaudeAttribution.'
}

Import-Module (Join-Path $PSScriptRoot 'scripts\ClaudeCX.Common.psm1') -Force

$skillName = Get-ClaudeCXSkillName
$source = Join-Path $PSScriptRoot (Join-Path 'skill' $skillName)

# 1. Validate the packaged skill before touching the destination.
$problems = @(Get-ClaudeCXSkillProblems -SkillRoot $source)
if ($problems.Count -gt 0) {
    throw "The packaged ClaudeCX skill failed validation; nothing was installed:`n - $($problems -join "`n - ")"
}

$codexHomeFull = Resolve-ClaudeCXCodexHome -CodexHome $CodexHome
$skillsDir = Join-Path $codexHomeFull 'skills'
$destination = Join-Path $skillsDir $skillName

# 2. Validate the optional Claude settings target before making any change.
$settingsPath = $null
if ($DisableClaudeAttribution) {
    $settingsPath = Resolve-ClaudeCXClaudeSettingsPath -ClaudeSettingsPath $ClaudeSettingsPath
    $null = Read-ClaudeCXSettingsNode -Path $settingsPath
}

# 3. Refuse to overwrite unless explicitly asked.
$existing = Test-Path -LiteralPath $destination
if ($existing) {
    if (Test-ClaudeCXReparsePoint -Path $destination) {
        throw "Destination is a symbolic link or junction; remove it manually before installing: $destination"
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw "Destination exists and is not a directory; remove it manually before installing: $destination"
    }
    if (-not $Force) {
        throw "ClaudeCX is already installed at $destination. Re-run with -Force to update it (the current copy is backed up first)."
    }
}

# 4. Stage and verify a complete copy beside the skills folder.
[IO.Directory]::CreateDirectory($skillsDir) | Out-Null
$staging = Join-Path $codexHomeFull ".claudecx-staging-$([Guid]::NewGuid().ToString('N'))"
$backupPath = $null
try {
    Copy-Item -LiteralPath $source -Destination $staging -Recurse
    if (-not (Test-ClaudeCXTreeEqual -Expected $source -Actual $staging)) {
        throw "Staged copy does not match the packaged skill: $staging"
    }

    # 5. Back up the existing installation, then move the staged copy into place.
    if ($existing) {
        $backupPath = New-ClaudeCXUniquePath -Parent (Get-ClaudeCXBackupRoot -CodexHome $codexHomeFull) -Prefix 'skill'
        Move-Item -LiteralPath $destination -Destination $backupPath
    }
    try {
        Move-Item -LiteralPath $staging -Destination $destination
    }
    catch {
        if ($backupPath -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backupPath -Destination $destination
            $backupPath = $null
        }
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

# 6. Verify the installed copy.
if (-not (Test-ClaudeCXTreeEqual -Expected $source -Actual $destination)) {
    throw "Installed copy does not match the packaged skill: $destination"
}
$installedProblems = @(Get-ClaudeCXSkillProblems -SkillRoot $destination)
if ($installedProblems.Count -gt 0) {
    throw "Installed skill failed validation:`n - $($installedProblems -join "`n - ")"
}

Write-Host "Installed ClaudeCX to $destination"
if ($backupPath) {
    Write-Host "Previous installation backed up to $backupPath"
}

# 7. Optional attribution change.
if ($DisableClaudeAttribution) {
    $change = Set-ClaudeCXAttributionDisabled -Path $settingsPath
    if ($change.Changed) {
        Write-Host "Disabled Claude attribution in $settingsPath"
        if ($change.BackupPath) {
            Write-Host "Original Claude settings backed up to $($change.BackupPath)"
        }
    }
    else {
        Write-Host "Claude attribution was already disabled in $settingsPath; no change made."
    }
}

Write-Host ''
Write-Host 'Next step: open a new Codex chat (restart Codex if it was already running) and invoke $claudecx, for example:'
Write-Host '  $claudecx Add input validation to the signup form and its unit tests.'
