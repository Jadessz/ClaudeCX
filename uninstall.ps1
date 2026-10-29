#Requires -Version 7.2
<#
.SYNOPSIS
Removes the ClaudeCX skill from Codex, and with -RemoveData everything ClaudeCX created.

.DESCRIPTION
Targets only <CodexHome>\skills\claudecx, where Codex home is resolved from
-CodexHome, then CODEX_HOME, then %USERPROFILE%\.codex. By default the skill is
moved to a timestamped backup under <CodexHome>\claudecx-backups so it can be
restored. -Permanent deletes it instead.

The control center is stopped and its Start menu and sign-in shortcuts are
removed. Without -RemoveData, run logs, your ClaudeCX settings, Claude settings,
and other Codex skills are never touched.

-RemoveData (implies -Permanent) also deletes everything else ClaudeCX created:
run logs in every log folder (including the copies Windows redirects for
packaged apps such as the Codex desktop app), brief drafts in the temporary
folder, your ClaudeCX settings (%USERPROFILE%\.claudecx), old versions kept in
<CodexHome>\claudecx-backups, and the Claude settings backups that
-DisableClaudeAttribution made. Nothing can be restored afterwards. It refuses
while a run is in progress.

Without -Yes the script asks for confirmation, which fails in non-interactive
sessions. Pass -Yes to confirm non-interactively.

.EXAMPLE
pwsh -NoProfile -File .\uninstall.ps1 -Yes

.EXAMPLE
pwsh -NoProfile -File .\uninstall.ps1 -Yes -Permanent

.EXAMPLE
pwsh -NoProfile -File .\uninstall.ps1 -RemoveData
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Codex home directory. Defaults to CODEX_HOME, then %USERPROFILE%\.codex.
    [string]$CodexHome,

    # Confirm removal without prompting.
    [switch]$Yes,

    # Delete the skill instead of moving it to a recoverable backup.
    [switch]$Permanent,

    # Also delete every log, setting, backup, and draft ClaudeCX created. Cannot be undone.
    [switch]$RemoveData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'scripts\ClaudeCX.Common.psm1') -Force

$skillName = Get-ClaudeCXSkillName
$codexHomeFull = Resolve-ClaudeCXCodexHome -CodexHome $CodexHome
$destination = Join-Path (Join-Path $codexHomeFull 'skills') $skillName
if ($RemoveData) { $Permanent = $true }

$installed = Test-Path -LiteralPath $destination
if (-not $installed -and -not $RemoveData) {
    Write-Host "ClaudeCX is not installed at $destination; nothing to remove."
    return
}
if ($installed) {
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
}

# The installed copy's helpers when present, otherwise the ones packaged with this repository.
$settingsModule = Join-Path $destination 'scripts\ClaudeCX.Settings.psm1'
if (-not (Test-Path -LiteralPath $settingsModule -PathType Leaf)) {
    $settingsModule = Join-Path (Get-ClaudeCXPackagedSkillRoot) 'scripts\ClaudeCX.Settings.psm1'
}
Import-Module $settingsModule -Force

$dataItems = @()
if ($RemoveData) {
    $roots = @(Get-ClaudeCXStateRoots)
    if (Test-ClaudeCXRunActive -Roots $roots) {
        throw 'A ClaudeCX run is in progress. Wait for it to finish, or stop it, before removing its data.'
    }
    $dataItems = @(Get-ClaudeCXDataInventory -Roots $roots -SkillRoot $destination | Where-Object { $_.id -ne 'app' -and $_.exists })
}

$action = if ($RemoveData) { 'Permanently delete ClaudeCX and all of its data' } elseif ($Permanent) { 'Permanently delete' } else { 'Move to a recoverable backup' }
if (-not $Yes) {
    if ($RemoveData) {
        Write-Host 'This permanently deletes:'
        if ($installed) { Write-Host "  - the ClaudeCX skill: $destination" }
        foreach ($item in $dataItems) {
            Write-Host "  - $($item.label): $($item.paths -join ', ')"
            if ($item.warning) { Write-Host "    $($item.warning)" }
        }
    }
    $confirmed = $false
    try {
        $confirmed = $PSCmdlet.ShouldContinue("$action$(if ($installed) { " at $destination" })?", 'Uninstall ClaudeCX')
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

if (Stop-ClaudeCXRunningControlCenter -SettingsModulePath $settingsModule) {
    Write-Host 'Stopped the ClaudeCX control center.'
}
$removedShortcuts = @()
try { $removedShortcuts = @(Remove-ClaudeCXShortcutFiles) } catch { Write-Host "Shortcuts were not checked: $($_.Exception.Message)" }
foreach ($removedShortcut in $removedShortcuts) {
    Write-Host "Removed shortcut $removedShortcut"
}

if ($RemoveData) {
    foreach ($result in @(Remove-ClaudeCXData -Ids @($dataItems | ForEach-Object { $_.id }) -Roots @(Get-ClaudeCXStateRoots) -SkillRoot $destination)) {
        Write-Host "Deleted $($result.label)"
        foreach ($problem in $result.errors) { Write-Host "  could not delete $problem" -ForegroundColor Yellow }
    }
    $home_ = Get-ClaudeCXHome
    if (Test-Path -LiteralPath $home_) {
        Remove-ClaudeCXPathSafely -Path $home_
        Write-Host "Deleted $home_"
    }
}

if ($installed) {
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
}
if ($RemoveData) {
    Write-Host 'ClaudeCX and everything it created are gone. Restart Codex to refresh its skill list.'
}
else {
    Write-Host 'Run logs, ClaudeCX settings, and Claude settings were not changed. Restart Codex to refresh its skill list.'
    Write-Host 'To delete those too, run: pwsh -NoProfile -File .\uninstall.ps1 -RemoveData'
}
